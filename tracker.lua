-- tracker.lua
-- Core state coordinator for Archaeology Assistant.
-- Delegates persistence, inventory scanning, Interface 657 noticeboard scanning, and chat parsing
-- to single-responsibility modules under core/.

local Materials          = require("data/materials")
local Artefacts          = require("data/artefacts")
local Collections        = require("data/collections")
local DB                 = require("core/db")
local Utils              = require("core/utils")
local InventoryScanner   = require("core/inventory_scanner")
local NoticeboardScanner = require("core/noticeboard_scanner")
local ChatParser         = require("core/chat_parser")

local Tracker = {}
Tracker.__index = Tracker

Tracker.SOURCE_MODES = {
    { id = "ALL",        label = "All (Bag + Storage + Bank)", shortLabel = "Src: All",      useBag = true,  useStorage = true,  useBank = true  },
    { id = "BAG_STOR",   label = "Backpack + Storage",         shortLabel = "Src: Bag+Stor", useBag = true,  useStorage = true,  useBank = false },
    { id = "STOR_ONLY",  label = "Material Storage Only",      shortLabel = "Src: Storage",  useBag = false, useStorage = true,  useBank = false },
    { id = "BAG_ONLY",   label = "Backpack Only",              shortLabel = "Src: Backpack", useBag = true,  useStorage = false, useBank = false },
}

local countMapEntries = InventoryScanner.countMapEntries

function Tracker.new()
    local self = setmetatable({}, Tracker)

    self.sourceModeIndex = 1
    self.includeMode = DB.get("arch_include_mode", "ALL") -- "ALL" | "ONE" | "ZERO"
    self.includeDuplicates = (self.includeMode == "ALL")
    self.artefactFilter = DB.get("arch_art_filter", "ALL") -- "ALL" | "TARGETED" | "OWNED"
    self.shortOnly = false

    -- Individual container source toggles
    self.srcBag       = DB.getBool("arch_src_bag", true)
    self.srcStorage   = DB.getBool("arch_src_storage", true)
    self.srcBank      = DB.getBool("arch_src_bank", true)
    self.srcWorkbench = DB.getBool("arch_src_workbench", true)

    -- Level requirement filtering (defaults to Level Met)
    if DB.get("arch_filter_by_level_init", nil) == nil then
        self.filterByLevel = true
        DB.setBool("arch_filter_by_level", true)
        DB.set("arch_filter_by_level_init", 1)
    else
        self.filterByLevel = DB.getBool("arch_filter_by_level", true)
    end
    self.playerArchLevel = tonumber(DB.get("arch_player_level", 0)) or 0

    local savedPinned = DB.get("arch_is_pinned", 0)
    self.isPinned = (savedPinned == 1 or savedPinned == true)

    self.excludedArtefacts    = DB.deserializeCountMap(DB.get("arch_excluded_artefacts", ""))
    self.customArtefactCounts = DB.deserializeCountMap(DB.get("arch_custom_art_counts", ""))
    self.pinnedArtefactCounts = DB.deserializeCountMap(DB.get("arch_pinned_artefacts", ""))

    self.backpackArtefacts = {}
    self.bankArtefacts     = DB.deserializeCountMap(DB.get("arch_bank_artefacts", ""))

    -- Archaeologist's workbench damaged artefact storage
    self.workbenchArtefacts  = DB.deserializeCountMap(DB.get("arch_workbench_artefacts", ""))
    self.workbenchInvId      = tonumber(DB.get("arch_workbench_inv_id", -1)) or -1
    self.workbenchSyncedLive = false
    self.workbenchHasCache   = countMapEntries(self.workbenchArtefacts) > 0
        or (tonumber(DB.get("arch_workbench_synced", 0)) or 0) == 1

    self.backpackRestored = {}
    self.bankRestored     = DB.deserializeCountMap(DB.get("arch_bank_restored", ""))

    self.completedCollections        = DB.deserializeCountMap(DB.get("arch_completed_collections", ""))
    self.targetedCollections         = DB.deserializeCountMap(DB.get("arch_targeted_collections", ""))
    self.collectionRememberedCounts  = DB.deserializeCountMap(DB.get("arch_col_remembered_counts", ""))
    self.submittedArtefacts          = DB.deserializeSubmittedMap(DB.get("arch_submitted_artefacts", ""))
    self.scannedCollectors     = DB.deserializeCountMap(DB.get("arch_scanned_collectors", ""))
    self.liveScannedCollectors = {}

    self.backpackMaterials = {}
    self.storageMaterials  = DB.deserializeCountMap(DB.get("arch_storage_materials", ""))
    self.bankMaterials     = DB.deserializeCountMap(DB.get("arch_bank_materials", ""))

    local storEntries = countMapEntries(self.storageMaterials)
    local bankEntries = countMapEntries(self.bankMaterials) + countMapEntries(self.bankArtefacts)

    self.storageInvId = tonumber(DB.get("arch_storage_inv_id", -1)) or -1
    self.bankInvId    = tonumber(DB.get("arch_bank_inv_id", -1)) or -1
    self.storageActionTicks        = 0
    self.pendingJournalStorageScan = false

    -- Guard against cached storage corruption caused by inspecting a damaged artefact in an older session
    if storEntries > 0 and storEntries <= 5 then
        if InventoryScanner.isArtefactRecipeContainer(self.storageMaterials, storEntries)
            or (DB.get("arch_storage_synced", 0) == 0 and bankEntries > 0) then
            self.storageMaterials = {}
            storEntries = 0
            DB.set("arch_storage_materials", "")
            DB.set("arch_storage_synced", 0)
        end
    end

    local itemTbl = id and (id.Item or id.Obj or id.Object)
    self.storageIconObjId  = itemTbl and itemTbl.ARCH_JOURNAL or nil
    self.bankIconObjId     = itemTbl and itemTbl.COINS or nil
    self.storageSyncedLive = false
    self.bankSyncedLive    = false
    self.boardSyncedLive   = false

    -- Purge storage if it was falsely populated with an exact duplicate copy of Bank
    local isBankDuplicate = (storEntries > 0 and bankEntries > 0)
    if isBankDuplicate then
        for matName, storCount in pairs(self.storageMaterials) do
            if (self.bankMaterials[matName] or 0) ~= storCount then
                isBankDuplicate = false
                break
            end
        end
    end
    if isBankDuplicate then
        self.storageMaterials = {}
        storEntries = 0
        DB.set("arch_storage_materials", "")
        DB.set("arch_storage_synced", 0)
    end

    self.storageHasCache = (storEntries > 0)
    self.bankHasCache    = (bankEntries > 0)

    local hasSubmissions = false
    for _, colSub in pairs(self.submittedArtefacts or {}) do
        for _, v in pairs(colSub or {}) do
            if v then hasSubmissions = true; break end
        end
        if hasSubmissions then break end
    end
    local savedBoardCache = (tonumber(DB.get("arch_board_has_cache", 0)) or 0) == 1
    self.boardHasCache = savedBoardCache or hasSubmissions
    self.lastAction    = nil

    self.lastResult = {
        artefacts                 = {},
        materials                 = {},
        filteredMaterials         = {},
        totalArtefacts            = 0,
        uniqueArtefacts           = 0,
        restorableArtefacts       = 0,
        totalXp                   = 0,
        totalChronotes            = 0,
        distinctMaterialsRequired = 0,
        distinctMaterialsShort    = 0,
        totalMaterialsShort       = 0,
    }

    pcall(function() self:syncCollectionsDoneStatus() end)
    return self
end

-- =========================================================================
-- Source Modes, Filters, Exclusions, Custom Quantities, and Pins
-- =========================================================================

function Tracker:getSourceMode()
    local b = self.srcBag ~= false
    local s = self.srcStorage ~= false
    local k = self.srcBank ~= false
    if b and s and k then
        return { id = "ALL", label = "All (Bag + Storage + Bank)", shortLabel = "Src: All", useBag = true, useStorage = true, useBank = true }
    elseif b and s and not k then
        return { id = "BAG_STOR", label = "Backpack + Storage", shortLabel = "Src: Bag+Stor", useBag = true, useStorage = true, useBank = false }
    elseif not b and s and not k then
        return { id = "STOR_ONLY", label = "Material Storage Only", shortLabel = "Src: Storage", useBag = false, useStorage = true, useBank = false }
    elseif b and not s and not k then
        return { id = "BAG_ONLY", label = "Backpack Only", shortLabel = "Src: Backpack", useBag = true, useStorage = false, useBank = false }
    else
        local parts = {}
        if b then table.insert(parts, "Bag") end
        if s then table.insert(parts, "Stor") end
        if k then table.insert(parts, "Bank") end
        local shortStr = #parts > 0 and ("Src: " .. table.concat(parts, "+")) or "Src: None"
        return { id = "CUSTOM", label = shortStr, shortLabel = shortStr, useBag = b, useStorage = s, useBank = k }
    end
end

function Tracker:getWorkbenchArtefactTotal()
    local total = 0
    for _, v in pairs(self.workbenchArtefacts or {}) do
        total = total + (tonumber(v) or 0)
    end
    return total
end

function Tracker:getSyncStatus()
    local mode           = self:getSourceMode()
    local storEntries    = countMapEntries(self.storageMaterials)
    local bankMatEntries = countMapEntries(self.bankMaterials)
    local bankArtEntries = countMapEntries(self.bankArtefacts)

    local submittedCount = 0
    for _, colSub in pairs(self.submittedArtefacts or {}) do
        for _, v in pairs(colSub or {}) do
            if v then submittedCount = submittedCount + 1 end
        end
    end
    local completedCount = countMapEntries(self.completedCollections)

    return {
        storage = {
            synced   = self.storageSyncedLive == true,
            cached   = (not self.storageSyncedLive) and (self.storageHasCache or storEntries > 0),
            enabled  = self.srcStorage ~= false,
            matTypes = storEntries,
        },
        bank = {
            synced   = self.bankSyncedLive == true,
            cached   = (not self.bankSyncedLive) and (self.bankHasCache or (bankMatEntries + bankArtEntries) > 0),
            enabled  = self.srcBank ~= false,
            matTypes = bankMatEntries,
            artTypes = bankArtEntries,
        },
        workbench = {
            synced   = self.workbenchSyncedLive == true,
            cached   = (not self.workbenchSyncedLive) and (self.workbenchHasCache == true),
            enabled  = self.srcWorkbench ~= false,
            artTypes = countMapEntries(self.workbenchArtefacts),
            artTotal = self:getWorkbenchArtefactTotal(),
        },
        board = {
            synced         = self.boardSyncedLive == true,
            cached         = (not self.boardSyncedLive) and (self.boardHasCache == true),
            enabled        = true,
            completedCount = completedCount,
            submittedCount = submittedCount,
        },
    }
end

function Tracker:toggleSource(sourceName)
    local s = string.lower(tostring(sourceName or ""))
    if s == "bag" or s == "backpack" then
        self.srcBag = not self.srcBag
        DB.setBool("arch_src_bag", self.srcBag)
    elseif s == "storage" or s == "material_storage" then
        self.srcStorage = not self.srcStorage
        DB.setBool("arch_src_storage", self.srcStorage)
    elseif s == "bank" then
        self.srcBank = not self.srcBank
        DB.setBool("arch_src_bank", self.srcBank)
    elseif s == "workbench" or s == "bench" then
        self.srcWorkbench = not self.srcWorkbench
        DB.setBool("arch_src_workbench", self.srcWorkbench)
    end
    return self:recalculate()
end

function Tracker:isSourceEnabled(sourceName)
    local s = string.lower(tostring(sourceName or ""))
    if s == "bag" or s == "backpack" then return self.srcBag ~= false end
    if s == "storage" or s == "material_storage" then return self.srcStorage ~= false end
    if s == "bank" then return self.srcBank ~= false end
    if s == "workbench" or s == "bench" then return self.srcWorkbench ~= false end
    return true
end

function Tracker:toggleFilterByLevel()
    self.filterByLevel = not self.filterByLevel
    DB.setBool("arch_filter_by_level", self.filterByLevel)
    return self:recalculate()
end

function Tracker:detectPlayerArchLevel()
    local detected = nil

    -- 1. Direct RS3 Engine native player skill level API
    pcall(function()
        if Player and Player.GetLevelGameplay then
            local archSkill = (SkillType and (SkillType.ARCHAEOLOGY or SkillType.Archaeology))
                or (SkillType and SkillType.FromID and SkillType.FromID(27))
                or 27
            local lvl = Player.GetLevelGameplay(archSkill)
            if type(lvl) == "number" and lvl >= 1 and lvl <= 120 then
                detected = lvl
            end
        end
    end)

    if detected and detected >= 1 and detected <= 120 then
        if self.playerArchLevel ~= detected then
            self.playerArchLevel = detected
            DB.set("arch_player_level", detected)
            print(string.format("[Archaeology Assistant] Synced player Archaeology level: %d", detected))
        end
        return detected
    end

    -- 2. Fallback: Scan Artefacts across all containers and history
    local maxArtLvl = 1
    local function checkArt(artName)
        if not artName then return end
        local art = Artefacts and Artefacts.findByName and Artefacts.findByName(artName)
        if art and art.level and art.level > maxArtLvl then
            maxArtLvl = art.level
        end
    end

    for artName, count in pairs(self.backpackRestored or {}) do if count > 0 then checkArt(artName) end end
    for artName, count in pairs(self.bankRestored or {}) do if count > 0 then checkArt(artName) end end
    for damagedName, count in pairs(self.backpackArtefacts or {}) do
        if count > 0 then
            local baseName = string.gsub(damagedName, "%s*%(damaged%)", "")
            checkArt(baseName)
        end
    end
    for damagedName, count in pairs(self.bankArtefacts or {}) do
        if count > 0 then
            local baseName = string.gsub(damagedName, "%s*%(damaged%)", "")
            checkArt(baseName)
        end
    end
    for damagedName, count in pairs(self.benchArtefacts or {}) do
        if count > 0 then
            local baseName = string.gsub(damagedName, "%s*%(damaged%)", "")
            checkArt(baseName)
        end
    end

    -- Check submitted artefacts (all 13 collectors)
    for colName, artMap in pairs(self.submittedArtefacts or {}) do
        if type(artMap) == "table" then
            for artName, subbed in pairs(artMap) do
                if subbed then checkArt(artName) end
            end
        end
    end

    -- Check completed collections
    for colName, count in pairs(self.completedCollections or {}) do
        if count and count > 0 then
            local col = Collections and Collections.findByName and Collections.findByName(colName)
            if col and col.level and col.level > maxArtLvl then
                maxArtLvl = col.level
            end
        end
    end

    -- Check material storage materials (excavation level)
    local maxMatLvl = 1
    for matName, count in pairs(self.storageMaterials or {}) do
        if count and count > 0 then
            local mat = Materials and Materials.get and Materials.get(matName)
            if mat and mat.isArchMaterial and mat.level and mat.level > maxMatLvl then
                maxMatLvl = mat.level
            end
        end
    end

    local baseline = math.max(maxArtLvl, maxMatLvl)
    local saved = tonumber(DB.get("arch_player_level", 0)) or 0
    if saved == 120 and baseline < 120 then
        saved = 0
    end

    local finalLvl = math.max(baseline, saved, 1)
    if finalLvl > saved then
        DB.set("arch_player_level", finalLvl)
    end
    self.playerArchLevel = finalLvl
    return finalLvl
end

function Tracker:getPlayerArchLevel()
    if Player and Player.GetLevelGameplay then
        return self:detectPlayerArchLevel()
    end
    if not self.playerArchLevel or self.playerArchLevel <= 1 then
        return self:detectPlayerArchLevel()
    end
    return self.playerArchLevel
end

function Tracker:setPlayerArchLevel(lvl)
    local n = math.max(1, math.min(120, tonumber(lvl) or 1))
    self.playerArchLevel = n
    DB.set("arch_player_level", n)
    return self:recalculate()
end

function Tracker:setSourceMode(modeId)
    local targetId = string.upper(tostring(modeId or ""))
    for idx, mode in ipairs(Tracker.SOURCE_MODES) do
        if string.upper(mode.id) == targetId then
            self.sourceModeIndex = idx
            self.srcBag = mode.useBag
            self.srcStorage = mode.useStorage
            self.srcBank = mode.useBank
            DB.setBool("arch_src_bag", self.srcBag)
            DB.setBool("arch_src_storage", self.srcStorage)
            DB.setBool("arch_src_bank", self.srcBank)
            DB.set("arch_source_mode_idx", self.sourceModeIndex)
            return self:recalculate()
        end
    end
    if targetId == "ALL" then
        self.sourceModeIndex = 1
    elseif targetId == "STORAGE" or targetId == "BAG_STOR" or targetId == "STOR" or targetId == "BANK" then
        self.sourceModeIndex = 2
    elseif targetId == "STOR_ONLY" then
        self.sourceModeIndex = 3
    elseif targetId == "BAG" or targetId == "BAG_ONLY" then
        self.sourceModeIndex = 4
    end
    local mode = Tracker.SOURCE_MODES[self.sourceModeIndex]
    if mode then
        self.srcBag = mode.useBag
        self.srcStorage = mode.useStorage
        self.srcBank = mode.useBank
        DB.setBool("arch_src_bag", self.srcBag)
        DB.setBool("arch_src_storage", self.srcStorage)
        DB.setBool("arch_src_bank", self.srcBank)
    end
    DB.set("arch_source_mode_idx", self.sourceModeIndex)
    return self:recalculate()
end

function Tracker:cycleSourceMode()
    self.sourceModeIndex = (self.sourceModeIndex % #Tracker.SOURCE_MODES) + 1
    local mode = Tracker.SOURCE_MODES[self.sourceModeIndex]
    if mode then
        self.srcBag = mode.useBag
        self.srcStorage = mode.useStorage
        self.srcBank = mode.useBank
        DB.setBool("arch_src_bag", self.srcBag)
        DB.setBool("arch_src_storage", self.srcStorage)
        DB.setBool("arch_src_bank", self.srcBank)
    end
    DB.set("arch_source_mode_idx", self.sourceModeIndex)
    return self:recalculate()
end

function Tracker:hasCustomCounts()
    return countMapEntries(self.customArtefactCounts) > 0
end

function Tracker:cycleDuplicates()
    if self:hasCustomCounts() or countMapEntries(self.excludedArtefacts) > 0 then
        self.includeMode = "ALL"
        self.includeDuplicates = true
    elseif self.includeMode == "ALL" then
        self.includeMode = "ONE"
        self.includeDuplicates = false
    elseif self.includeMode == "ONE" then
        self.includeMode = "ZERO"
        self.includeDuplicates = false
    else
        self.includeMode = "ALL"
        self.includeDuplicates = true
    end
    self.excludedArtefacts = {}
    self.customArtefactCounts = {}

    DB.set("arch_include_mode", self.includeMode)
    DB.set("arch_include_dupes", self.includeDuplicates and 1 or 0)
    DB.set("arch_excluded_artefacts", "")
    DB.set("arch_custom_art_counts", "")
    return self:recalculate()
end

function Tracker:toggleDuplicates()
    return self:cycleDuplicates()
end

function Tracker:cycleDuplicatesThreshold()
    return self:cycleDuplicates()
end

function Tracker:togglePinned()
    return self:togglePin()
end

function Tracker:cycleArtefactFilter()
    if self.artefactFilter == "ALL" then
        self.artefactFilter = "TARGETED"
    elseif self.artefactFilter == "TARGETED" then
        self.artefactFilter = "OWNED"
    else
        self.artefactFilter = "ALL"
    end
    DB.set("arch_art_filter", self.artefactFilter)
    return self:recalculate()
end

function Tracker:getArtefactFilterLabel()
    if self.artefactFilter == "TARGETED" then
        return "Show: Tracked"
    elseif self.artefactFilter == "OWNED" then
        return "Show: Owned"
    end
    return "Show: All"
end

function Tracker:getDuplicatesLabel()
    if self:hasCustomCounts() then
        return "Dupes: Custom"
    elseif self.includeMode == "ZERO" then
        return "Include: 0"
    elseif self.includeMode == "ONE" or not self.includeDuplicates then
        return "Dupes: 1x"
    end
    return "Dupes: All"
end

function Tracker:toggleShortOnly()
    self.shortOnly = not self.shortOnly
    DB.set("arch_short_only", self.shortOnly and 1 or 0)
    return self:recalculate()
end

function Tracker:toggleArtefactExcluded(damagedName)
    if not damagedName then return self.lastResult end
    if self.excludedArtefacts[damagedName] then
        self.excludedArtefacts[damagedName] = nil
        if (self.customArtefactCounts[damagedName] or 0) <= 0 then
            self.customArtefactCounts[damagedName] = nil
            DB.set("arch_custom_art_counts", DB.serializeCountMap(self.customArtefactCounts))
        end
    else
        self.excludedArtefacts[damagedName] = 1
    end
    DB.set("arch_excluded_artefacts", DB.serializeCountMap(self.excludedArtefacts))
    return self:recalculate()
end

function Tracker:adjustArtefactCount(damagedName, delta, rawCount)
    if not damagedName then return self.lastResult end
    local colTargets = self:getTargetedArtefactRequirements()
    local targetInfo = colTargets and colTargets[damagedName]
    local minTarget  = (targetInfo and targetInfo.count) or 0

    local defaultQty
    if targetInfo and targetInfo.isSubmitted then
        defaultQty = 0
    elseif targetInfo and targetInfo.neededToRestore then
        defaultQty = targetInfo.neededToRestore
    elseif minTarget > 0 then
        defaultQty = minTarget
    elseif self.includeMode == "ZERO" then
        defaultQty = 0
    elseif self.includeMode == "ONE" or not self.includeDuplicates then
        defaultQty = 1
    else
        defaultQty = math.max(1, tonumber(rawCount) or 1)
    end

    local currentQty = self.excludedArtefacts[damagedName] and 0 or (self.customArtefactCounts[damagedName] or defaultQty)
    local newQty     = math.max(0, currentQty + (tonumber(delta) or 0))

    if newQty <= 0 then
        self.excludedArtefacts[damagedName] = 1
        self.customArtefactCounts[damagedName] = nil
    else
        self.excludedArtefacts[damagedName] = nil
        if newQty == defaultQty then
            self.customArtefactCounts[damagedName] = nil
        else
            self.customArtefactCounts[damagedName] = newQty
        end
    end

    DB.set("arch_excluded_artefacts", DB.serializeCountMap(self.excludedArtefacts))
    DB.set("arch_custom_art_counts", DB.serializeCountMap(self.customArtefactCounts))
    return self:recalculate()
end

function Tracker:clearAllCache()
    print("[Archaeology Assistant] Clearing all cached and saved data...")
    self.storageMaterials         = {}
    self.bankMaterials            = {}
    self.bankArtefacts            = {}
    self.bankRestored             = {}
    self.workbenchArtefacts       = {}
    self.workbenchSyncedLive      = false
    self.workbenchHasCache        = false
    self.targetedCollections      = {}
    self.collectionRememberedCounts = {}
    self.excludedArtefacts        = {}
    self.customArtefactCounts     = {}
    self.pinnedArtefactCounts     = {}
    self.isPinned                 = false
    self.storageSyncedLive        = false
    self.bankSyncedLive           = false
    self.storageHasCache          = false
    self.bankHasCache             = false
    self.boardSyncedLive          = false
    self.boardHasCache            = false
    self.submittedArtefacts       = {}
    self.completedCollections     = {}
    self.scannedCollectors        = {}
    self.liveScannedCollectors    = {}
    self.lastCollectorScanSummary = nil
    if self.storageInvId and self.storageInvId >= 0 then
        self._knownStorageInvId = self.storageInvId
    end
    self.storageInvId             = -1
    self.bankInvId                = -1
    self.workbenchInvId           = -1
    self.lastAction               = nil
    self.storageActionTicks       = 0
    self.workbenchActionTicks     = 0
    self.pendingJournalStorageScan = false
    self.cacheCleared             = true
    self.bankCacheCleared         = true
    self.storageCacheCleared      = true
    self.workbenchCacheCleared    = true

    DB.set("arch_storage_materials", "")
    DB.set("arch_storage_synced", 0)
    DB.set("arch_storage_inv_id", -1)
    DB.set("arch_bank_materials", "")
    DB.set("arch_bank_artefacts", "")
    DB.set("arch_bank_restored", "")
    DB.set("arch_bank_inv_id", -1)
    DB.set("arch_workbench_artefacts", "")
    DB.set("arch_workbench_synced", 0)
    DB.set("arch_workbench_inv_id", -1)
    DB.set("arch_targeted_collections", "")
    DB.set("arch_col_remembered_counts", "")
    DB.set("arch_excluded_artefacts", "")
    DB.set("arch_custom_art_counts", "")
    DB.set("arch_pinned_artefacts", "")
    DB.set("arch_is_pinned", 0)
    DB.set("arch_submitted_artefacts", "")
    DB.set("arch_board_has_cache", 0)
    DB.set("arch_completed_collections", "")
    DB.set("arch_scanned_collectors", "")

    return self:recalculate()
end

function Tracker:togglePin()
    if self.isPinned then
        self.isPinned = false
        self.pinnedArtefactCounts = {}
        DB.set("arch_is_pinned", 0)
        DB.set("arch_pinned_artefacts", "")
    else
        local liveMap = {}
        local hasAny = false
        if self.lastResult and self.lastResult.artefacts then
            for _, item in ipairs(self.lastResult.artefacts) do
                if item.rawCount and item.rawCount > 0 then
                    liveMap[item.artefact.damagedName] = item.rawCount
                    hasAny = true
                end
            end
        end
        self.pinnedArtefactCounts = liveMap
        self.isPinned = hasAny
        DB.set("arch_is_pinned", self.isPinned and 1 or 0)
        DB.set("arch_pinned_artefacts", DB.serializeCountMap(self.pinnedArtefactCounts))
    end
    return self:recalculate()
end

-- =========================================================================
-- Collections Management (Completion, Targeting, Progress)
-- =========================================================================

function Tracker:isCollectionCompleted(colName)
    if not colName then return false end
    local isComp = (self.completedCollections[colName] or 0) > 0

    local col = Collections and Collections.BY_NAME and Collections.BY_NAME[colName]
    if col and col.artefacts and #col.artefacts > 0 and self.submittedArtefacts and self.submittedArtefacts[colName] then
        local allSub = true
        for _, artName in ipairs(col.artefacts) do
            if not self:isArtefactSubmitted(colName, artName, true) then
                allSub = false
                break
            end
        end
        if allSub then
            self.completedCollections[colName] = 1
            DB.set("arch_completed_collections", DB.serializeCountMap(self.completedCollections))
            self.submittedArtefacts[colName] = nil
            DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
            return true
        end
    end

    if isComp and col and not col.isRepeatable and self.submittedArtefacts and self.submittedArtefacts[colName] then
        self.submittedArtefacts[colName] = nil
        DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
    end

    return isComp
end

function Tracker:toggleCollectionCompleted(colName)
    if not colName then return self.lastResult end
    if self:isCollectionCompleted(colName) then
        self.completedCollections[colName] = nil
    else
        self.completedCollections[colName] = 1
        if self.submittedArtefacts and self.submittedArtefacts[colName] then
            self.submittedArtefacts[colName] = nil
            DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
        end
    end
    DB.set("arch_completed_collections", DB.serializeCountMap(self.completedCollections))
    return self:recalculate()
end

function Tracker:isCollectionTargeted(colName)
    if not colName then return false end
    return (self.targetedCollections[colName] or 0) > 0
end

function Tracker:getCollectionTargetCount(colName)
    if not colName then return 0 end
    return tonumber(self.targetedCollections[colName]) or 0
end

function Tracker:getCollectionRememberedCount(colName)
    if not colName then return 1 end
    local rem = self.collectionRememberedCounts and self.collectionRememberedCounts[colName]
    return math.max(1, tonumber(rem) or 1)
end

function Tracker:getCollectionMaxOwned(colName)
    if not colName or not Collections or not Collections.BY_NAME then return 1 end
    local col = Collections.BY_NAME[colName]
    if not col or not col.artefacts then return 1 end
    local maxOwned = 0
    for _, artName in ipairs(col.artefacts) do
        local damagedName = artName .. " (damaged)"
        local bagDamaged = (self.srcBag ~= false) and ((self.backpackArtefacts and self.backpackArtefacts[damagedName]) or 0) or 0
        local bankDamaged = (self.srcBank ~= false) and ((self.bankArtefacts and self.bankArtefacts[damagedName]) or 0) or 0
        local benchDamaged = (self.srcWorkbench ~= false) and ((self.workbenchArtefacts and self.workbenchArtefacts[damagedName]) or 0) or 0
        local totalDamaged = bagDamaged + bankDamaged + benchDamaged

        local bagRestored = (self.srcBag ~= false) and ((self.backpackRestored and self.backpackRestored[artName]) or 0) or 0
        local bankRestored = (self.srcBank ~= false) and ((self.bankRestored and self.bankRestored[artName]) or 0) or 0
        local totalRestored = bagRestored + bankRestored

        local total = totalDamaged + totalRestored
        if total > maxOwned then
            maxOwned = total
        end
    end
    return math.max(1, maxOwned)
end

function Tracker:setCollectionTargetCount(colName, count)
    if not colName then return self.lastResult end
    count = math.max(1, math.floor(tonumber(count) or 1))
    self.collectionRememberedCounts = self.collectionRememberedCounts or {}
    self.collectionRememberedCounts[colName] = count
    DB.set("arch_col_remembered_counts", DB.serializeCountMap(self.collectionRememberedCounts))

    -- Max, Reset, and Stepper do not activate tracking; only update targetedCollections if already tracked
    if self:isCollectionTargeted(colName) then
        self.targetedCollections[colName] = count
        DB.set("arch_targeted_collections", DB.serializeCountMap(self.targetedCollections))
    end
    return self:recalculate()
end

function Tracker:adjustCollectionTargetCount(colName, delta)
    if not colName then return self.lastResult end
    local current = self.targetedCollections[colName]
    if not current or current <= 0 then
        current = self:getCollectionRememberedCount(colName)
    end
    local newCount = math.max(1, current + (delta or 1))
    return self:setCollectionTargetCount(colName, newCount)
end

function Tracker:setCollectionTargetToMax(colName)
    local maxCount = self:getCollectionMaxOwned(colName)
    return self:setCollectionTargetCount(colName, maxCount)
end

function Tracker:resetCollectionTarget(colName)
    return self:setCollectionTargetCount(colName, 1)
end

function Tracker:toggleCollectionTargeted(colName)
    if not colName then return self.lastResult end
    if self:isCollectionTargeted(colName) then
        self.targetedCollections[colName] = nil
        DB.set("arch_targeted_collections", DB.serializeCountMap(self.targetedCollections))
        return self:recalculate()
    else
        local count = self:getCollectionRememberedCount(colName)
        self.targetedCollections[colName] = count
        DB.set("arch_targeted_collections", DB.serializeCountMap(self.targetedCollections))
        return self:recalculate()
    end
end

function Tracker:setAllTrackedToMax()
    local changed = false
    local hasAny = self:hasTargetedCollections()
    if hasAny then
        for colName, _ in pairs(self.targetedCollections) do
            local maxCount = self:getCollectionMaxOwned(colName)
            if maxCount and maxCount > 0 and self.targetedCollections[colName] ~= maxCount then
                self.targetedCollections[colName] = maxCount
                self.collectionRememberedCounts[colName] = maxCount
                changed = true
            end
        end
    end
    if changed then
        DB.set("arch_targeted_collections", DB.serializeCountMap(self.targetedCollections))
        DB.set("arch_col_remembered_counts", DB.serializeCountMap(self.collectionRememberedCounts))
        return self:recalculate()
    end
    return self.lastResult
end

function Tracker:clearTargetedCollections()
    self.targetedCollections = {}
    self.collectionRememberedCounts = {}
    DB.set("arch_targeted_collections", "")
    DB.set("arch_col_remembered_counts", "")
    return self:recalculate()
end

function Tracker:getTargetedCount()
    return countMapEntries(self.targetedCollections)
end

function Tracker:hasTargetedCollections()
    return self:getTargetedCount() > 0
end

function Tracker:hasAnyTargetedCollections()
    if not self.targetedCollections then return false end
    for colName, _ in pairs(self.targetedCollections) do
        if self:isCollectionTargeted(colName) then
            return true
        end
    end
    return false
end

function Tracker:isArtefactSubmitted(colName, artName, _skipColCheck)
    if not colName or not artName then return false end
    if self.submittedArtefacts and self.submittedArtefacts[colName] then
        if self.submittedArtefacts[colName][artName] then
            return true
        end
        local lowerTarget = string.lower(artName)
        for sArt, sVal in pairs(self.submittedArtefacts[colName]) do
            if sVal and string.lower(sArt) == lowerTarget then
                return true
            end
        end
    end
    return false
end

function Tracker:toggleArtefactSubmitted(colName, artName)
    if not colName or not artName then return self.lastResult end
    self.submittedArtefacts = self.submittedArtefacts or {}
    self.submittedArtefacts[colName] = self.submittedArtefacts[colName] or {}
    if self.submittedArtefacts[colName][artName] then
        self.submittedArtefacts[colName][artName] = nil
    else
        self.submittedArtefacts[colName][artName] = true
    end
    DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
    return self:recalculate()
end

function Tracker:clearRepeatableSubmissions(colName)
    if colName then
        if self.submittedArtefacts then
            self.submittedArtefacts[colName] = nil
        end
    else
        for _, col in ipairs((Collections and Collections.LIST) or {}) do
            if col.isRepeatable and self.submittedArtefacts then
                self.submittedArtefacts[col.name] = nil
            end
        end
    end
    DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
    return self:recalculate()
end

function Tracker:getCollectionProgress(col)
    if not col or not col.artefacts then
        return {
            readyCount        = 0,
            damagedCount      = 0,
            submittedCount    = 0,
            restoredOnlyCount = 0,
            damagedOnlyCount  = 0,
            haveCount         = 0,
            totalCount        = 0,
            isReady           = false,
            isCompleted       = false,
            isTargeted        = false,
            artefacts         = {},
        }
    end

    local total             = #col.artefacts
    local isCompleted       = self:isCollectionCompleted(col.name)
    local completedCount    = (self.completedCollections and self.completedCollections[col.name]) or (isCompleted and 1 or 0)
    local readyCount        = 0
    local damagedCount      = 0
    local submittedCount    = 0
    local restoredOnlyCount = 0
    local damagedOnlyCount  = 0
    local haveCount         = 0
    local artStatuses       = {}

    for _, artName in ipairs(col.artefacts) do
        local isSubmitted   = self:isArtefactSubmitted(col.name, artName)
        if isSubmitted then submittedCount = submittedCount + 1 end

        local bagRestored   = (self.srcBag ~= false) and (self.backpackRestored[artName] or 0) or 0
        local bankRestored  = (self.srcBank ~= false) and (self.bankRestored[artName] or 0) or 0
        local totalRestored = bagRestored + bankRestored

        local damagedName   = artName .. " (damaged)"
        local bagDamaged    = (self.srcBag ~= false) and (self.backpackArtefacts[damagedName] or 0) or 0
        local bankDamaged   = (self.srcBank ~= false) and (self.bankArtefacts[damagedName] or 0) or 0
        local benchDamaged  = (self.srcWorkbench ~= false) and ((self.workbenchArtefacts and self.workbenchArtefacts[damagedName]) or 0) or 0
        local totalDamaged  = bagDamaged + bankDamaged + benchDamaged

        local isReady = isSubmitted or (totalRestored > 0)
        if isReady then
            readyCount = readyCount + 1
        elseif totalDamaged > 0 then
            damagedCount = damagedCount + 1
        end

        if isSubmitted then
            haveCount = haveCount + 1
        elseif totalRestored > 0 then
            haveCount = haveCount + 1
            restoredOnlyCount = restoredOnlyCount + 1
        elseif totalDamaged > 0 then
            haveCount = haveCount + 1
            damagedOnlyCount = damagedOnlyCount + 1
        end

        table.insert(artStatuses, {
            name          = artName,
            isSubmitted   = isSubmitted,
            restoredCount = totalRestored,
            bagRestored   = bagRestored,
            bankRestored  = bankRestored,
            damagedCount  = totalDamaged,
            bagDamaged    = bagDamaged,
            bankDamaged   = bankDamaged,
            benchDamaged  = benchDamaged,
            isReady       = isReady,
        })
    end

    local maxOwned = 0
    local setsReady = 999999
    for _, art in ipairs(artStatuses) do
        local totalOwned = (art.damagedCount or 0) + (art.restoredCount or 0)
        if totalOwned > maxOwned then maxOwned = totalOwned end
        local readyCountForArt = (art.restoredCount or 0) + (art.isSubmitted and 1 or 0)
        if readyCountForArt < setsReady then setsReady = readyCountForArt end
    end
    if #artStatuses == 0 or setsReady == 999999 then setsReady = 0 end
    if maxOwned == 0 then maxOwned = 1 end

    local targetCount = self:getCollectionTargetCount(col.name)
    local isTargeted = targetCount > 0
    local effectiveTarget = isTargeted and targetCount or self:getCollectionRememberedCount(col.name)

    return {
        readyCount        = readyCount,
        damagedCount      = damagedCount,
        submittedCount    = submittedCount,
        restoredOnlyCount = restoredOnlyCount,
        damagedOnlyCount  = damagedOnlyCount,
        haveCount         = haveCount,
        totalCount        = total,
        isReady           = (targetCount > 1) and (setsReady >= targetCount) or (readyCount >= total and total > 0),
        isCompleted       = isCompleted,
        completedCount    = completedCount,
        isTargeted        = isTargeted,
        targetCount       = targetCount,
        effectiveTarget   = effectiveTarget,
        setsReady         = setsReady,
        maxOwned          = maxOwned,
        artefacts         = artStatuses,
    }
end

function Tracker:getTargetedArtefactRequirements()
    local requirements = {}
    if not Collections or not Collections.BY_NAME then
        return requirements
    end

    for colName, targetMultiplier in pairs(self.targetedCollections) do
        if self:isCollectionTargeted(colName) then
            local multiplier = math.max(1, tonumber(targetMultiplier) or 1)
            local col = Collections.BY_NAME[colName]
            if col and col.artefacts then
                for _, artName in ipairs(col.artefacts) do
                    local isSubmitted = self:isArtefactSubmitted(col.name, artName)
                    local damagedName = artName .. " (damaged)"
                    local neededForThisCol = isSubmitted and math.max(0, multiplier - 1) or multiplier
                    local isFullySubmitted = (isSubmitted and multiplier == 1)

                    if not requirements[damagedName] then
                        requirements[damagedName] = {
                            artName         = artName,
                            damagedName     = damagedName,
                            count           = neededForThisCol,
                            neededToRestore = neededForThisCol,
                            isSubmitted     = isFullySubmitted,
                            collections     = { col.name },
                        }
                    else
                        requirements[damagedName].count           = requirements[damagedName].count + neededForThisCol
                        requirements[damagedName].neededToRestore = requirements[damagedName].neededToRestore + neededForThisCol
                        if not isFullySubmitted then
                            requirements[damagedName].isSubmitted = false
                        end
                        table.insert(requirements[damagedName].collections, col.name)
                    end
                end
            end
        end
    end

    for _, req in pairs(requirements) do
        local bagRestored   = (self.srcBag ~= false) and ((self.backpackRestored and self.backpackRestored[req.artName]) or 0) or 0
        local bankRestored  = (self.srcBank ~= false) and ((self.bankRestored and self.bankRestored[req.artName]) or 0) or 0
        local totalRestored = bagRestored + bankRestored
        req.ownedRestored   = totalRestored
        req.neededToRestore = (not req.isSubmitted) and math.max(0, req.count - totalRestored) or 0
    end

    return requirements
end

function Tracker:getArtefactNeededCount(damagedName, artName)
    if not damagedName then return 0 end
    artName = artName or string.gsub(damagedName, "%s*%(damaged%)", "")

    if self.excludedArtefacts and self.excludedArtefacts[damagedName] then
        return 0
    end

    local targetQty = nil
    if self.customArtefactCounts and self.customArtefactCounts[damagedName] ~= nil then
        targetQty = tonumber(self.customArtefactCounts[damagedName]) or 0
    end
    if (not targetQty) and self.isPinned and self.pinnedArtefactCounts then
        local pCount = self.pinnedArtefactCounts[damagedName] or self.pinnedArtefactCounts[artName]
        if pCount ~= nil then
            targetQty = tonumber(pCount) or 0
        end
    end
    if not targetQty then
        local colTargets = self:getTargetedArtefactRequirements()
        local targetInfo = colTargets and colTargets[damagedName]
        if targetInfo and targetInfo.count then
            targetQty = targetInfo.count
        end
    end
    if (not targetQty) and self.lastResult and self.lastResult.artefacts then
        for _, item in ipairs(self.lastResult.artefacts) do
            if item.artefact and item.artefact.damagedName == damagedName then
                if not item.excluded and (item.effectiveCount or 0) > 0 then
                    targetQty = item.effectiveCount
                end
                break
            end
        end
    end

    targetQty = targetQty or 0
    if targetQty <= 0 then
        return 0
    end

    local inBagDamaged   = (self.srcBag ~= false) and ((self.backpackArtefacts and self.backpackArtefacts[damagedName]) or 0) or 0
    local inBankDamaged  = (self.srcBank ~= false) and ((self.bankArtefacts and self.bankArtefacts[damagedName]) or 0) or 0
    local inBenchDamaged = (self.srcWorkbench ~= false) and ((self.workbenchArtefacts and self.workbenchArtefacts[damagedName]) or 0) or 0
    local inBagRestored  = (self.srcBag ~= false) and ((self.backpackRestored and self.backpackRestored[artName]) or 0) or 0
    local inBankRestored = (self.srcBank ~= false) and ((self.bankRestored and self.bankRestored[artName]) or 0) or 0
    local totalOwned     = inBagDamaged + inBankDamaged + inBenchDamaged + inBagRestored + inBankRestored

    return math.max(0, targetQty - totalOwned)
end

function Tracker:hasAnyNeededArtefacts()
    local colTargets = self:getTargetedArtefactRequirements()
    for damagedName, targetInfo in pairs(colTargets) do
        if self:getArtefactNeededCount(damagedName, targetInfo.artName) > 0 then
            return true
        end
    end
    if self.lastResult and self.lastResult.artefacts then
        for _, item in ipairs(self.lastResult.artefacts) do
            if not item.excluded and (item.effectiveCount or 0) > 0 then
                if self:getArtefactNeededCount(item.artefact.damagedName, item.artefact.name) > 0 then
                    return true
                end
            end
        end
    end
    return false
end

function Tracker:getCollectionsForDisplay(filterMode)
    local list = {}
    if not Collections or not Collections.LIST then
        return list, 0, 0, 0, 0
    end

    local totalCount         = #Collections.LIST
    local completedTotal     = 0
    local readyAllTotal      = 0
    local readyTargetedTotal = 0
    local targetedTotal      = 0

    for _, col in ipairs(Collections.LIST) do
        local progress = self:getCollectionProgress(col)
        if progress.isCompleted then completedTotal = completedTotal + 1 end
        if progress.isReady then readyAllTotal = readyAllTotal + 1 end
        if progress.isTargeted then
            targetedTotal = targetedTotal + 1
            if progress.isReady then
                readyTargetedTotal = readyTargetedTotal + 1
            end
        end

        local include = true
        local playerLvl = self:getPlayerArchLevel()

        if self.filterByLevel and (col.level or 1) > playerLvl then
            include = false
        elseif filterMode == "incomplete" then
            include = not progress.isCompleted
        elseif filterMode == "targeted" then
            include = progress.isTargeted
        elseif filterMode == "powers" then
            include = (col.benefitType == "relic" or col.benefitType == "weapon" or col.benefitType == "mystery")
        elseif filterMode == "tetra" then
            local rec = string.lower(col.recurringReward or "")
            local one = string.lower(col.oneTimeReward or "")
            local ben = string.lower(col.specialBenefit or "")
            include = (string.find(rec, "tetra", 1, true) ~= nil
                or string.find(one, "tetra", 1, true) ~= nil
                or string.find(ben, "tetra", 1, true) ~= nil)
        elseif filterMode == "unsynced" then
            include = not self:isCollectorSynced(col.collector)
        end

        if include then
            table.insert(list, { data = col, progress = progress })
        end
    end

    local readyTotal = (targetedTotal > 0) and readyTargetedTotal or readyAllTotal
    return list, totalCount, completedTotal, targetedTotal, readyTotal
end

function Tracker:getTargetedChronotesTotal()
    local total = 0
    if not Collections or not Collections.BY_NAME then return 0 end
    for colName, _ in pairs(self.targetedCollections or {}) do
        if self:isCollectionTargeted(colName) then
            local multiplier = math.max(1, tonumber(self.targetedCollections[colName]) or 1)
            local col = Collections.BY_NAME[colName]
            if col and col.chronotes then
                local numStr = string.gsub(string.match(col.chronotes, "[%d,]+") or "0", ",", "")
                local colTotal = tonumber(numStr) or 0
                local submittedChronotes = 0
                local unsubmittedCount = 0
                for _, artName in ipairs(col.artefacts or {}) do
                    if self:isArtefactSubmitted(col.name, artName) then
                        local art = Artefacts and Artefacts.findByName and Artefacts.findByName(artName)
                        if art and art.chronotes then
                            submittedChronotes = submittedChronotes + art.chronotes
                        end
                    else
                        unsubmittedCount = unsubmittedCount + 1
                    end
                end
                local firstPassChronotes = (unsubmittedCount > 0) and math.max(0, colTotal - submittedChronotes) or 0
                local extraPasses = math.max(0, multiplier - 1)
                total = total + firstPassChronotes + (extraPasses * colTotal)
            end
        end
    end
    return total
end

function Tracker:isCollectorSynced(collectorName)
    if not collectorName or collectorName == "" then return true end
    if collectorName == "Giles" then
        return self.scannedCollectors ~= nil and next(self.scannedCollectors) ~= nil
    end
    if self.scannedCollectors and (self.scannedCollectors[collectorName] or 0) > 0 then
        return true
    end
    if self.submittedArtefacts and Collections and Collections.LIST then
        for _, col in ipairs(Collections.LIST) do
            if col.collector == collectorName and self.submittedArtefacts[col.name] then
                for _, done in pairs(self.submittedArtefacts[col.name]) do
                    if done then
                        self.scannedCollectors[collectorName] = 1
                        DB.set("arch_scanned_collectors", DB.serializeCountMap(self.scannedCollectors))
                        return true
                    end
                end
            end
        end
    end
    return false
end

function Tracker:getCollectorSyncStatuses()
    local map   = {}
    local order = {}
    if Collections and Collections.LIST then
        for _, col in ipairs(Collections.LIST) do
            local cName = col.collector or "Unknown"
            if cName ~= "Giles" then
                if not map[cName] then
                    map[cName] = {
                        name                      = cName,
                        collectionsCount          = 0,
                        completedCollectionsCount = 0,
                        submittedCount            = 0,
                        totalArtefacts            = 0,
                        synced                    = false,
                    }
                    table.insert(order, cName)
                end
                local ent = map[cName]
                ent.collectionsCount = ent.collectionsCount + 1
                if self.completedCollections and self.completedCollections[col.name] then
                    ent.completedCollectionsCount = ent.completedCollectionsCount + 1
                end
                if col.artefacts then
                    ent.totalArtefacts = ent.totalArtefacts + #col.artefacts
                    for _, artName in ipairs(col.artefacts) do
                        if self.submittedArtefacts and self.submittedArtefacts[col.name] and self.submittedArtefacts[col.name][artName] then
                            ent.submittedCount = ent.submittedCount + 1
                        end
                    end
                end
            end
        end
    end

    local list              = {}
    local totalCollectors   = #order
    local syncedCollectors  = 0
    local liveCollectors    = 0
    local cachedCollectors  = 0

    for _, cName in ipairs(order) do
        local ent = map[cName]
        local hasAnyData = self:isCollectorSynced(cName)
        local isLive = self.liveScannedCollectors and (self.liveScannedCollectors[cName] or 0) > 0
        ent.synced = isLive
        ent.cached = (not isLive) and hasAnyData
        if hasAnyData then syncedCollectors = syncedCollectors + 1 end
        if isLive then
            liveCollectors = liveCollectors + 1
        elseif ent.cached then
            cachedCollectors = cachedCollectors + 1
        end
        table.insert(list, ent)
    end

    table.sort(list, function(a, b)
        local aState = a.synced and 2 or (a.cached and 1 or 0)
        local bState = b.synced and 2 or (b.cached and 1 or 0)
        if aState ~= bState then
            return aState > bState
        end
        return a.name < b.name
    end)

    return list, syncedCollectors, totalCollectors, liveCollectors, cachedCollectors
end

function Tracker:savePersistentState()
    DB.set("arch_source_mode_idx", self.sourceModeIndex)
    DB.set("arch_include_dupes", self.includeDuplicates and 1 or 0)
    DB.set("arch_short_only", self.shortOnly and 1 or 0)
    DB.set("arch_is_pinned", self.isPinned and 1 or 0)
    DB.set("arch_pinned_artefacts", DB.serializeCountMap(self.pinnedArtefactCounts))
    DB.set("arch_excluded_artefacts", DB.serializeCountMap(self.excludedArtefacts))
    DB.set("arch_custom_art_counts", DB.serializeCountMap(self.customArtefactCounts))
    DB.set("arch_bank_artefacts", DB.serializeCountMap(self.bankArtefacts))
    DB.set("arch_bank_restored", DB.serializeCountMap(self.bankRestored))
    DB.set("arch_workbench_artefacts", DB.serializeCountMap(self.workbenchArtefacts))
    if self.workbenchInvId and self.workbenchInvId >= 0 then
        DB.set("arch_workbench_inv_id", self.workbenchInvId)
    end
    DB.set("arch_completed_collections", DB.serializeCountMap(self.completedCollections))
    DB.set("arch_targeted_collections", DB.serializeCountMap(self.targetedCollections))
    DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
    DB.set("arch_scanned_collectors", DB.serializeCountMap(self.scannedCollectors))
    DB.set("arch_storage_materials", DB.serializeCountMap(self.storageMaterials))
    DB.set("arch_bank_materials", DB.serializeCountMap(self.bankMaterials))
    DB.set("arch_storage_synced", self.storageSyncedLive and 1 or 0)
    DB.set("arch_bank_synced", self.bankSyncedLive and 1 or 0)
    DB.set("arch_workbench_synced", self.workbenchSyncedLive and 1 or 0)
    if self.storageInvId and self.storageInvId >= 0 then
        DB.set("arch_storage_inv_id", self.storageInvId)
    end
    if self.bankInvId and self.bankInvId >= 0 then
        DB.set("arch_bank_inv_id", self.bankInvId)
    end
end

-- =========================================================================
-- Delegated Inventory, Noticeboard, Achievement, MiniMenu & Chat Handlers
-- =========================================================================

function Tracker:extractMaterialsFromInv(inv)
    return InventoryScanner.extractMaterialsFromInv(inv)
end

function Tracker:scanAllInventories(triggerInvType)
    return InventoryScanner.scanAllInventories(self, triggerInvType)
end

function Tracker:checkBackpackChanged()
    return InventoryScanner.checkBackpackChanged(self)
end

function Tracker:scanCollectorInterface(forceLog)
    return NoticeboardScanner.scanCollectorInterface(self, forceLog)
end

function Tracker:isNoticeboardOpen()
    return NoticeboardScanner.isNoticeboardOpen()
end

function Tracker:detectActiveCollector()
    return NoticeboardScanner.detectActiveCollector()
end

function Tracker:syncCollectionsDoneStatus(forceLog)
    return NoticeboardScanner.syncCollectionsDoneStatus(self, forceLog)
end

function Tracker:syncCollectorBoard(forceLog)
    local isForce = (forceLog ~= false)
    self:syncCollectionsDoneStatus(isForce)
    local success, _, collectorScanned = self:scanCollectorInterface(isForce)
    local cScanned = collectorScanned or self:detectActiveCollector()
    if success and cScanned and cScanned ~= "" and cScanned ~= "Noticeboard" then
        self.scannedCollectors[cScanned] = 1
        self.liveScannedCollectors = self.liveScannedCollectors or {}
        self.liveScannedCollectors[cScanned] = 1
        DB.set("arch_scanned_collectors", DB.serializeCountMap(self.scannedCollectors))
    end
    self:recalculate()
    return self.lastResult
end

function Tracker:onLogicTick()
    self._logicTicks = (self._logicTicks or 0) + 1
    local updated = false

    if (self.storageActionTicks or 0) > 0 then
        self.storageActionTicks = self.storageActionTicks - 1
        if self.storageActionTicks == 0 then
            self.pendingJournalStorageScan = false
            if self.lastAction == "storage" then
                self.lastAction = nil
            end
        elseif self.pendingJournalStorageScan and (self.storageActionTicks == 18 or self.storageActionTicks == 6) then
            local wasSynced = self.storageSyncedLive
            local prevCount = countMapEntries(self.storageMaterials)
            self:recalculate()
            if (not wasSynced and self.storageSyncedLive) or countMapEntries(self.storageMaterials) ~= prevCount then
                updated = true
            end
        end
    end

    if (self.workbenchActionTicks or 0) > 0 then
        self.workbenchActionTicks = self.workbenchActionTicks - 1
        if self.workbenchActionTicks == 0 then
            self.pendingWorkbenchScan = false
            if self.lastAction == "workbench_storage" then
                self.lastAction = nil
            end
        elseif self.pendingWorkbenchScan and (self.workbenchActionTicks == 24 or self.workbenchActionTicks == 18 or self.workbenchActionTicks == 12 or self.workbenchActionTicks == 6) then
            local wasSynced = self.workbenchSyncedLive
            local prevTotal = self:getWorkbenchArtefactTotal()
            self:recalculate()
            if (not wasSynced and self.workbenchSyncedLive) or self:getWorkbenchArtefactTotal() ~= prevTotal then
                updated = true
            end
        end
    end

    self._bagCheckTicks = (self._bagCheckTicks or 0) + 1
    if self._bagCheckTicks >= 2 then
        self._bagCheckTicks = 0
        if self:checkBackpackChanged() then
            updated = true
        end
    end

    local isNoticeboardOpen = (self.noticeboardOpenTicks and self.noticeboardOpenTicks > 0)
    local checkInterval = isNoticeboardOpen and 8 or 20
    if (self._logicTicks % checkInterval) ~= 0 then
        return updated
    end

    if self:isNoticeboardOpen() then
        self.noticeboardOpenTicks = (self.noticeboardOpenTicks or 0) + 1
        local activeCollector = self:detectActiveCollector() or "Noticeboard"

        if (not self.noticeboardScanned) or (activeCollector ~= self._lastReportedCollector) then
            self._lastReportedCollector = activeCollector
            self.noticeboardScanned = true

            local success, _, collectorScanned = self:scanCollectorInterface(false)
            if success then
                self.boardSyncedLive = true
                self.boardHasCache = true
                DB.set("arch_board_has_cache", 1)
                local cScanned = collectorScanned or (activeCollector ~= "Noticeboard" and activeCollector)
                if cScanned and cScanned ~= "" then
                    self.scannedCollectors[cScanned] = 1
                    self.liveScannedCollectors = self.liveScannedCollectors or {}
                    self.liveScannedCollectors[cScanned] = 1
                    DB.set("arch_scanned_collectors", DB.serializeCountMap(self.scannedCollectors))
                end
                self:recalculate()
                updated = true
            end
        end
    else
        self.noticeboardScanned = false
        self.noticeboardOpenTicks = 0
        self._lastReportedCollector = nil
    end

    self._achCheckTicks = (self._achCheckTicks or 0) + 1
    if self._achCheckTicks >= 60 then
        self._achCheckTicks = 0
        local synced = self:syncCollectionsDoneStatus(false)
        if synced > 0 then
            updated = true
        end
    end

    return updated
end

function Tracker:onRestoredArtefactSubmitted(artName, _countHandedIn)
    if not artName or not Collections or not Collections.LIST then return end
    local lowerTarget = string.lower(artName)

    for _, col in ipairs(Collections.LIST) do
        if col.artefacts then
            for _, cArt in ipairs(col.artefacts) do
                if string.lower(cArt) == lowerTarget then
                    self.submittedArtefacts[col.name] = self.submittedArtefacts[col.name] or {}
                    self.submittedArtefacts[col.name][cArt] = true

                    local allSub = true
                    for _, reqArt in ipairs(col.artefacts) do
                        if not self:isArtefactSubmitted(col.name, reqArt, true) then
                            allSub = false
                            break
                        end
                    end

                    if allSub then
                        self.completedCollections[col.name] = 1
                        self.submittedArtefacts[col.name] = nil
                        DB.set("arch_completed_collections", DB.serializeCountMap(self.completedCollections))
                        DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
                    else
                        DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
                    end
                end
            end
        end
    end
end

function Tracker:onMiniMenuAction(verb, full)
    local vLower = string.lower(verb or "")
    local fLower = string.lower(full or "")
    if vLower == "drop" or string.find(fLower, "drop") then
        self.lastAction = "drop"
    elseif string.find(fLower, "bank") or string.find(fLower, "chest") or string.find(fLower, "booth") or string.find(fLower, "deposit box") then
        self.lastAction = "bank"
        self.bankCacheCleared = false
    elseif string.find(fLower, "material storage") or string.find(vLower, "material storage") then
        self.lastAction = "storage"
        self.storageActionTicks = 24
        self.pendingJournalStorageScan = true
        self.storageCacheCleared = false
    elseif string.find(vLower, "restore") or string.find(fLower, "restore") then
        self.lastAction = "restore"
        self.workbenchActionTicks = 30
        self.pendingWorkbenchScan = true
        self.workbenchCacheCleared = false
    elseif string.find(fLower, "artefact storage") or string.find(fLower, "artifact storage")
        or string.find(fLower, "damaged artefact") or string.find(fLower, "damaged artifact")
        or (string.find(vLower, "store") and string.find(fLower, "workbench")) then
        self.lastAction = "workbench_storage"
        self.workbenchActionTicks = 30
        self.pendingWorkbenchScan = true
        self.workbenchCacheCleared = false
    elseif string.find(fLower, "workbench") or string.find(vLower, "workbench") then
        -- Interacting with the archaeologist's workbench itself defaults to restoration crafting
        self.lastAction = "restore"
    elseif string.find(fLower, "storage") then
        self.lastAction = "storage"
        self.storageActionTicks = 24
        self.pendingJournalStorageScan = true
        self.storageCacheCleared = false
    elseif string.find(vLower, "excavate", 1, true) then
        self.lastExcavateTarget = Utils.cleanText(string.gsub(full or "", "^[Ee]xcavate%s*", ""))
    elseif string.find(fLower, "cart") or string.find(fLower, "deposit") or string.find(vLower, "store") then
        self.lastAction = "storage"
        self.storageActionTicks = 45
        self.pendingJournalStorageScan = true
        self.storageCacheCleared = false
    elseif string.find(vLower, "loot") or string.find(fLower, "loot")
        or string.find(vLower, "take") or string.find(fLower, "take")
        or string.find(vLower, "pick") or string.find(fLower, "pick") then
        self.lastAction = "loot"
    elseif string.find(vLower, "restore") or string.find(fLower, "restore") or string.find(fLower, "workbench") then
        self.lastAction = "restore"
    end
end

function Tracker:onChatMessage(text)
    return ChatParser.onChatMessage(self, text)
end

-- =========================================================================
-- Material & Artefact Requirement Calculation
-- =========================================================================

function Tracker:getOwnedMaterialCount(matName, mode)
    local owned = 0
    if self.srcBag ~= false then owned = owned + (self.backpackMaterials[matName] or 0) end
    if self.srcStorage ~= false then owned = owned + (self.storageMaterials[matName] or 0) end
    if self.srcBank ~= false then owned = owned + (self.bankMaterials[matName] or 0) end
    return owned
end

--- Builds the combined damaged artefact map across Backpack, Bank, Workbench storage, Pins, and Targeted Collections.
local function buildCombinedArtefactsMap(self)
    local combinedArts = {}
    local benchArts = self.workbenchArtefacts or {}
    if self.isPinned then
        for damagedName, pinnedCount in pairs(self.pinnedArtefactCounts or {}) do
            if pinnedCount and pinnedCount > 0 then
                combinedArts[damagedName] = {
                    inBag    = (self.srcBag ~= false) and (self.backpackArtefacts[damagedName] or 0) or 0,
                    inBank   = (self.srcBank ~= false) and (self.bankArtefacts[damagedName] or 0) or 0,
                    inBench  = (self.srcWorkbench ~= false) and (benchArts[damagedName] or 0) or 0,
                    rawCount = pinnedCount,
                }
            end
        end
    else
        local function addOwned(map, field)
            for damagedName, count in pairs(map or {}) do
                if count and count > 0 then
                    local entry = combinedArts[damagedName]
                    if not entry then
                        entry = { inBag = 0, inBank = 0, inBench = 0, rawCount = 0 }
                        combinedArts[damagedName] = entry
                    end
                    entry[field]   = count
                    entry.rawCount = entry.rawCount + count
                end
            end
        end
        if self.srcBag ~= false then addOwned(self.backpackArtefacts, "inBag") end
        if self.srcBank ~= false then addOwned(self.bankArtefacts, "inBank") end
        if self.srcWorkbench ~= false then addOwned(benchArts, "inBench") end
    end

    local colTargets = self:getTargetedArtefactRequirements()
    for damagedName, targetInfo in pairs(colTargets) do
        local entry = combinedArts[damagedName]
        if entry then
            entry.colTarget       = targetInfo.count
            entry.colNames        = targetInfo.collections
            entry.ownedRestored   = targetInfo.ownedRestored
            entry.neededToRestore = targetInfo.neededToRestore
            entry.isSubmitted     = targetInfo.isSubmitted
            entry.isTargetedCol   = true
            if not self.isPinned then
                entry.rawCount = targetInfo.neededToRestore or 0
            end
        else
            combinedArts[damagedName] = {
                inBag           = (self.srcBag ~= false) and (self.backpackArtefacts[damagedName] or 0) or 0,
                inBank          = (self.srcBank ~= false) and (self.bankArtefacts[damagedName] or 0) or 0,
                inBench         = (self.srcWorkbench ~= false) and (benchArts[damagedName] or 0) or 0,
                rawCount        = targetInfo.neededToRestore or 0,
                colTarget       = targetInfo.count or 0,
                colNames        = targetInfo.collections,
                ownedRestored   = targetInfo.ownedRestored,
                neededToRestore = targetInfo.neededToRestore or 0,
                isSubmitted     = targetInfo.isSubmitted,
                isTargetedCol   = true,
            }
        end
    end

    return combinedArts
end

--- Determines the default included quantity for a damaged artefact row.
local function resolveDefaultArtefactQty(self, art, info, rawCount, minTarget)
    if self.customArtefactCounts[art.damagedName] ~= nil then
        return self.customArtefactCounts[art.damagedName]
    elseif info.isTargetedCol then
        if info.isSubmitted then
            return 0
        elseif (info.neededToRestore or 0) > 0 then
            return info.neededToRestore
        else
            return 0
        end
    elseif minTarget > 0 then
        return minTarget
    elseif self.includeMode == "ZERO" then
        return 0
    elseif self.includeMode == "ONE" or not self.includeDuplicates then
        return 1
    end
    return math.max(1, rawCount)
end

--- Builds the sorted material requirement rows from `requiredByMat`.
local function buildMaterialRows(self, requiredByMat, mode)
    local materialsList             = {}
    local filteredMaterials         = {}
    local distinctMaterialsRequired = 0
    local distinctMaterialsShort    = 0
    local totalMaterialsShort       = 0
    local playerLvl                 = self:getPlayerArchLevel()

    for matName, reqCount in pairs(requiredByMat) do
        if reqCount > 0 then
            local matDef = Materials.get(matName) or {
                name           = matName,
                level          = 1,
                culture        = "Other",
                isArchMaterial = false,
                caches         = {},
                order          = 999,
            }
            if not self.filterByLevel or matDef.isArchMaterial == false or (matDef.level or 1) <= playerLvl then
                distinctMaterialsRequired = distinctMaterialsRequired + 1

                local inBag     = (self.srcBag ~= false) and (self.backpackMaterials[matName] or 0) or 0
                local inStorage = (self.srcStorage ~= false) and (self.storageMaterials[matName] or 0) or 0
                local inBank    = (self.srcBank ~= false) and (self.bankMaterials[matName] or 0) or 0
                local owned     = self:getOwnedMaterialCount(matName, mode)

                local short   = math.max(0, reqCount - owned)
                local surplus = math.max(0, owned - reqCount)
                if short > 0 then
                    distinctMaterialsShort = distinctMaterialsShort + 1
                    totalMaterialsShort    = totalMaterialsShort + short
                end

                local row = {
                    name         = matName,
                    material     = matDef,
                    required     = reqCount,
                    owned        = owned,
                    ownedBag     = inBag,
                    ownedStorage = inStorage,
                    ownedBank    = inBank,
                    short        = short,
                    surplus      = surplus,
                    isReady      = (short == 0),
                }

                table.insert(materialsList, row)
                if not self.shortOnly or short > 0 then
                    table.insert(filteredMaterials, row)
                end
            end
        end
    end

    local function sortMats(a, b)
        if a.isReady ~= b.isReady then
            return not a.isReady
        end
        if a.material.level ~= b.material.level then
            return a.material.level < b.material.level
        end
        return a.name < b.name
    end

    table.sort(materialsList, sortMats)
    table.sort(filteredMaterials, sortMats)

    return materialsList, filteredMaterials, distinctMaterialsRequired, distinctMaterialsShort, totalMaterialsShort
end

--- Simulates sequential restoration across `artefactsList` using the player's owned material pool.
local function computeSequentialRestorableCounts(artefactsList, materialsList)
    local pool = {}
    for _, row in ipairs(materialsList) do
        pool[row.name] = row.owned
    end

    local restorableArtefacts = 0
    for _, item in ipairs(artefactsList) do
        if not item.excluded and item.effectiveCount > 0 then
            local canMake    = 0
            local maxCanMake = math.min(item.effectiveCount, item.ownedDamaged or 0)
            for _ = 1, maxCanMake do
                local enough = true
                for _, req in ipairs(item.artefact.materials) do
                    if (pool[req.name] or 0) < req.count then
                        enough = false
                        break
                    end
                end
                if enough then
                    for _, req in ipairs(item.artefact.materials) do
                        pool[req.name] = (pool[req.name] or 0) - req.count
                    end
                    canMake = canMake + 1
                    restorableArtefacts = restorableArtefacts + 1
                else
                    break
                end
            end
            item.restorableCount = canMake
        else
            item.restorableCount = 0
        end
    end
    return restorableArtefacts
end

function Tracker:recalculate(triggerInvType)
    self:scanAllInventories(triggerInvType)

    local mode         = self:getSourceMode()
    local combinedArts = buildCombinedArtefactsMap(self)
    local hasTargeted  = self:hasAnyTargetedCollections()
    local playerLvl    = self:getPlayerArchLevel()

    local artefactsList   = {}
    local requiredByMat   = {}
    local totalArtefacts  = 0
    local uniqueArtefacts = 0
    local totalXp         = 0
    local totalChronotes  = 0

    for damagedName, info in pairs(combinedArts) do
        local rawCount  = info.rawCount or 0
        local minTarget = (info.neededToRestore and info.neededToRestore > 0) and info.neededToRestore or 0

        local ownedDamagedInfo = (info.inBag or 0) + (info.inBank or 0) + (info.inBench or 0)
        local keep = true
        if self.artefactFilter == "TARGETED" then
            keep = info.isTargetedCol or (info.colTarget and info.colTarget > 0)
        elseif self.artefactFilter == "OWNED" then
            keep = ownedDamagedInfo > 0
        elseif hasTargeted then
            keep = info.isTargetedCol or ownedDamagedInfo > 0
        end

        if keep and (info.isTargetedCol or rawCount > 0 or minTarget > 0) then
            local art = Artefacts.findByName(damagedName)
            if art and (not self.filterByLevel or (art.level or 1) <= playerLvl) then
                uniqueArtefacts = uniqueArtefacts + 1
                local isExcluded     = (self.excludedArtefacts[art.damagedName] ~= nil)
                local defaultQty     = resolveDefaultArtefactQty(self, art, info, rawCount, minTarget)
                local targetCount    = self.customArtefactCounts[art.damagedName] or defaultQty
                local effectiveCount = isExcluded and 0 or targetCount

                totalArtefacts = totalArtefacts + effectiveCount
                totalXp        = totalXp + (art.xp * effectiveCount)
                totalChronotes = totalChronotes + (art.chronotes * effectiveCount)

                local ownedDamaged    = ownedDamagedInfo
                local matPossibleNow  = 999999
                local missingMatTypes = 0
                for _, req in ipairs(art.materials) do
                    if effectiveCount > 0 then
                        requiredByMat[req.name] = (requiredByMat[req.name] or 0) + (req.count * effectiveCount)
                    end
                    local ownedMat     = self:getOwnedMaterialCount(req.name, mode)
                    local copiesForMat = (req.count > 0) and math.floor(ownedMat / req.count) or 999999
                    if copiesForMat < matPossibleNow then
                        matPossibleNow = copiesForMat
                    end
                    if ownedMat < req.count then
                        missingMatTypes = missingMatTypes + 1
                    end
                end
                if matPossibleNow == 999999 then matPossibleNow = 0 end
                local maxPossibleNow = math.min(ownedDamaged, matPossibleNow)

                local bagRestored   = (self.srcBag ~= false) and ((self.backpackRestored and self.backpackRestored[art.name]) or 0) or 0
                local bankRestored  = (self.srcBank ~= false) and ((self.bankRestored and self.bankRestored[art.name]) or 0) or 0
                local ownedRestored = bagRestored + bankRestored

                table.insert(artefactsList, {
                    artefact        = art,
                    inBag           = info.inBag or 0,
                    inBank          = info.inBank or 0,
                    inBench         = info.inBench or 0,
                    ownedDamaged    = ownedDamaged,
                    bagRestored     = bagRestored,
                    bankRestored    = bankRestored,
                    rawCount        = rawCount,
                    targetCount     = targetCount,
                    effectiveCount  = effectiveCount,
                    excluded        = isExcluded,
                    maxPossibleNow  = maxPossibleNow,
                    matPossibleNow  = matPossibleNow,
                    missingMatTypes = missingMatTypes,
                    colTarget       = info.colTarget or 0,
                    colNames        = info.colNames,
                    ownedRestored   = math.max(info.ownedRestored or 0, ownedRestored),
                    neededToRestore = info.neededToRestore or 0,
                    isSubmitted     = info.isSubmitted or false,
                    isTargetedCol   = info.isTargetedCol or false,
                })
            end
        end
    end

    table.sort(artefactsList, function(a, b)
        local aSub = a.isSubmitted and 1 or 0
        local bSub = b.isSubmitted and 1 or 0
        if aSub ~= bSub then return aSub < bSub end
        if a.artefact.level ~= b.artefact.level then return a.artefact.level < b.artefact.level end
        return (a.artefact.order or 0) < (b.artefact.order or 0)
    end)

    local materialsList, filteredMaterials, distinctMaterialsRequired, distinctMaterialsShort, totalMaterialsShort =
        buildMaterialRows(self, requiredByMat, mode)
    local restorableArtefacts = computeSequentialRestorableCounts(artefactsList, materialsList)
    local readyRestoredArtefacts = 0
    for _, item in ipairs(artefactsList) do
        if not item.excluded and not item.isSubmitted and item.effectiveCount == 0 and (item.ownedRestored or 0) > 0 then
            readyRestoredArtefacts = readyRestoredArtefacts + math.min(math.max(1, item.colTarget or 1), item.ownedRestored)
        end
    end

    self.lastResult = {
        artefacts                 = artefactsList,
        materials                 = materialsList,
        filteredMaterials         = filteredMaterials,
        totalArtefacts            = totalArtefacts,
        uniqueArtefacts           = uniqueArtefacts,
        restorableArtefacts       = restorableArtefacts,
        readyRestoredArtefacts    = readyRestoredArtefacts,
        totalXp                   = totalXp,
        totalChronotes            = totalChronotes,
        distinctMaterialsRequired = distinctMaterialsRequired,
        distinctMaterialsShort    = distinctMaterialsShort,
        totalMaterialsShort       = totalMaterialsShort,
    }

    return self.lastResult
end

return Tracker
