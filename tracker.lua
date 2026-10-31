-- tracker.lua
-- Core state coordinator for Archaeology Assistant.
-- Delegates persistence, inventory scanning, Interface 657 noticeboard scanning, and chat parsing
-- to single-responsibility modules under core/.

local Materials          = require("data/materials")
local Artefacts          = require("data/artefacts")
local Collections        = require("data/collections")
local DB                 = require("core/db")
local InventoryScanner   = require("core/inventory_scanner")
local NoticeboardScanner = require("core/noticeboard_scanner")
local ChatParser         = require("core/chat_parser")

local Tracker = {}
Tracker.__index = Tracker

Tracker.SOURCE_MODES = {
    { id = "ALL",        label = "Src: All",      useBag = true,  useStorage = true,  useBank = true  },
    { id = "BAG_STOR",   label = "Src: Bag+Stor", useBag = true,  useStorage = true,  useBank = false },
    { id = "STOR_ONLY",  label = "Src: Storage",  useBag = false, useStorage = true,  useBank = false },
    { id = "BAG_ONLY",   label = "Src: Backpack", useBag = true,  useStorage = false, useBank = false },
}

local countMapEntries = InventoryScanner.countMapEntries

function Tracker.new()
    local self = setmetatable({}, Tracker)

    self.sourceModeIndex = 1
    self.includeMode = DB.get("arch_include_mode", "ALL") -- "ALL" | "ONE" | "ZERO"
    self.includeDuplicates = (self.includeMode == "ALL")
    self.artefactFilter = DB.get("arch_art_filter", "ALL") -- "ALL" | "TARGETED" | "OWNED"
    self.shortOnly = false

    local savedPinned = DB.get("arch_is_pinned", 0)
    self.isPinned = (savedPinned == 1 or savedPinned == true)

    self.excludedArtefacts    = DB.deserializeCountMap(DB.get("arch_excluded_artefacts", ""))
    self.customArtefactCounts = DB.deserializeCountMap(DB.get("arch_custom_art_counts", ""))
    self.pinnedArtefactCounts = DB.deserializeCountMap(DB.get("arch_pinned_artefacts", ""))

    self.backpackArtefacts = {}
    self.bankArtefacts     = DB.deserializeCountMap(DB.get("arch_bank_artefacts", ""))

    self.backpackRestored = {}
    self.bankRestored     = DB.deserializeCountMap(DB.get("arch_bank_restored", ""))

    self.completedCollections = DB.deserializeCountMap(DB.get("arch_completed_collections", ""))
    self.targetedCollections  = DB.deserializeCountMap(DB.get("arch_targeted_collections", ""))
    self.submittedArtefacts   = DB.deserializeSubmittedMap(DB.get("arch_submitted_artefacts", ""))
    self.scannedCollectors    = DB.deserializeCountMap(DB.get("arch_scanned_collectors", ""))

    self.backpackMaterials = {}
    self.storageMaterials  = DB.deserializeCountMap(DB.get("arch_storage_materials", ""))
    self.bankMaterials     = DB.deserializeCountMap(DB.get("arch_bank_materials", ""))

    local storEntries = countMapEntries(self.storageMaterials)
    local bankEntries = countMapEntries(self.bankMaterials) + countMapEntries(self.bankArtefacts)

    self.storageInvId = -1
    self.bankInvId    = tonumber(DB.get("arch_bank_inv_id", -1)) or -1
    DB.set("arch_storage_inv_id", -1)

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

    self.storageIconObjId  = 49429
    self.bankIconObjId     = 995
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
    return Tracker.SOURCE_MODES[self.sourceModeIndex] or Tracker.SOURCE_MODES[1]
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
            enabled  = mode.useStorage == true,
            matTypes = storEntries,
        },
        bank = {
            synced   = self.bankSyncedLive == true,
            cached   = (not self.bankSyncedLive) and (self.bankHasCache or (bankMatEntries + bankArtEntries) > 0),
            enabled  = (mode.useBank == true) or (mode.id ~= "BAG_ONLY"),
            matTypes = bankMatEntries,
            artTypes = bankArtEntries,
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

function Tracker:cycleSourceMode()
    self.sourceModeIndex = (self.sourceModeIndex % #Tracker.SOURCE_MODES) + 1
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
    self.storageMaterials         = {}
    self.bankMaterials            = {}
    self.bankArtefacts            = {}
    self.bankRestored             = {}
    self.targetedCollections      = {}
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
    self.lastCollectorScanSummary = nil

    DB.set("arch_storage_materials", "")
    DB.set("arch_storage_synced", 0)
    DB.set("arch_storage_inv_id", -1)
    DB.set("arch_bank_materials", "")
    DB.set("arch_bank_artefacts", "")
    DB.set("arch_bank_restored", "")
    DB.set("arch_bank_inv_id", -1)
    DB.set("arch_targeted_collections", "")
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

function Tracker:toggleCollectionTargeted(colName)
    if not colName then return self.lastResult end
    if self:isCollectionTargeted(colName) then
        self.targetedCollections[colName] = nil
    else
        self.targetedCollections[colName] = 1
    end
    DB.set("arch_targeted_collections", DB.serializeCountMap(self.targetedCollections))
    return self:recalculate()
end

function Tracker:clearTargetedCollections()
    self.targetedCollections = {}
    DB.set("arch_targeted_collections", "")
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

        local bagRestored   = self.backpackRestored[artName] or 0
        local bankRestored  = self.bankRestored[artName] or 0
        local totalRestored = bagRestored + bankRestored

        local damagedName   = artName .. " (damaged)"
        local bagDamaged    = self.backpackArtefacts[damagedName] or 0
        local bankDamaged   = self.bankArtefacts[damagedName] or 0
        local totalDamaged  = bagDamaged + bankDamaged

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
            isReady       = isReady,
        })
    end

    return {
        readyCount        = readyCount,
        damagedCount      = damagedCount,
        submittedCount    = submittedCount,
        restoredOnlyCount = restoredOnlyCount,
        damagedOnlyCount  = damagedOnlyCount,
        haveCount         = haveCount,
        totalCount        = total,
        isReady           = (readyCount >= total and total > 0),
        isCompleted       = isCompleted,
        isTargeted        = self:isCollectionTargeted(col.name),
        artefacts         = artStatuses,
    }
end

function Tracker:getTargetedArtefactRequirements()
    local requirements = {}
    if not Collections or not Collections.BY_NAME then
        return requirements
    end

    for colName, _ in pairs(self.targetedCollections) do
        if self:isCollectionTargeted(colName) then
            local col = Collections.BY_NAME[colName]
            if col and col.artefacts then
                for _, artName in ipairs(col.artefacts) do
                    local isSubmitted = self:isArtefactSubmitted(col.name, artName)
                    local damagedName = artName .. " (damaged)"
                    if not requirements[damagedName] then
                        requirements[damagedName] = {
                            artName         = artName,
                            damagedName     = damagedName,
                            count           = isSubmitted and 0 or 1,
                            neededToRestore = isSubmitted and 0 or 1,
                            isSubmitted     = isSubmitted,
                            collections     = { col.name },
                        }
                    else
                        if not isSubmitted then
                            requirements[damagedName].count           = requirements[damagedName].count + 1
                            requirements[damagedName].neededToRestore = requirements[damagedName].neededToRestore + 1
                            requirements[damagedName].isSubmitted     = false
                        end
                        table.insert(requirements[damagedName].collections, col.name)
                    end
                end
            end
        end
    end

    for _, req in pairs(requirements) do
        local bagRestored   = (self.backpackRestored and self.backpackRestored[req.artName]) or 0
        local bankRestored  = (self.bankRestored and self.bankRestored[req.artName]) or 0
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

    local inBagDamaged   = (self.backpackArtefacts and self.backpackArtefacts[damagedName]) or 0
    local inBankDamaged  = (self.bankArtefacts and self.bankArtefacts[damagedName]) or 0
    local inBagRestored  = (self.backpackRestored and self.backpackRestored[artName]) or 0
    local inBankRestored = (self.bankRestored and self.bankRestored[artName]) or 0
    local totalOwned     = inBagDamaged + inBankDamaged + inBagRestored + inBankRestored

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

    local totalCount     = #Collections.LIST
    local completedTotal = 0
    local readyTotal     = 0
    local targetedTotal  = 0

    for _, col in ipairs(Collections.LIST) do
        local progress = self:getCollectionProgress(col)
        if progress.isCompleted then completedTotal = completedTotal + 1 end
        if progress.isReady then readyTotal = readyTotal + 1 end
        if progress.isTargeted then targetedTotal = targetedTotal + 1 end

        local include = true
        if filterMode == "incomplete" then
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

    return list, totalCount, completedTotal, targetedTotal, readyTotal
end

function Tracker:getTargetedChronotesTotal()
    local total = 0
    if not Collections or not Collections.BY_NAME then return 0 end
    for colName, _ in pairs(self.targetedCollections or {}) do
        if self:isCollectionTargeted(colName) then
            local col = Collections.BY_NAME[colName]
            if col and col.chronotes then
                local numStr = string.gsub(string.match(col.chronotes, "[%d,]+") or "0", ",", "")
                total = total + (tonumber(numStr) or 0)
            end
        end
    end
    return total
end

function Tracker:isCollectorSynced(collectorName)
    if not collectorName or collectorName == "" or collectorName == "Giles" then return true end
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
    if self.completedCollections and Collections and Collections.LIST then
        local hasAny  = false
        local allDone = true
        for _, col in ipairs(Collections.LIST) do
            if col.collector == collectorName then
                hasAny = true
                if not self.completedCollections[col.name] then
                    allDone = false
                    break
                end
            end
        end
        if hasAny and allDone then
            self.scannedCollectors[collectorName] = 1
            DB.set("arch_scanned_collectors", DB.serializeCountMap(self.scannedCollectors))
            return true
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

    local list             = {}
    local totalCollectors  = #order
    local syncedCollectors = 0

    for _, cName in ipairs(order) do
        local ent = map[cName]
        ent.synced = self:isCollectorSynced(cName)
        if ent.synced then syncedCollectors = syncedCollectors + 1 end
        table.insert(list, ent)
    end

    table.sort(list, function(a, b)
        if a.synced ~= b.synced then
            return (a.synced and not b.synced)
        end
        return a.name < b.name
    end)

    return list, syncedCollectors, totalCollectors
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
    DB.set("arch_completed_collections", DB.serializeCountMap(self.completedCollections))
    DB.set("arch_targeted_collections", DB.serializeCountMap(self.targetedCollections))
    DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(self.submittedArtefacts))
    DB.set("arch_scanned_collectors", DB.serializeCountMap(self.scannedCollectors))
    DB.set("arch_storage_materials", DB.serializeCountMap(self.storageMaterials))
    DB.set("arch_bank_materials", DB.serializeCountMap(self.bankMaterials))
    DB.set("arch_storage_synced", self.storageSyncedLive and 1 or 0)
    DB.set("arch_bank_synced", self.bankSyncedLive and 1 or 0)
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
        DB.set("arch_scanned_collectors", DB.serializeCountMap(self.scannedCollectors))
    end
    self:recalculate()
    return self.lastResult
end

function Tracker:onLogicTick()
    self._logicTicks = (self._logicTicks or 0) + 1
    local updated = false

    self._bagCheckTicks = (self._bagCheckTicks or 0) + 1
    if self._bagCheckTicks >= 25 then
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
    elseif string.find(fLower, "cart") or string.find(fLower, "material storage") or string.find(fLower, "storage") then
        self.lastAction = "storage"
    elseif string.find(fLower, "deposit") then
        self.lastAction = "storage"
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
    mode = mode or self:getSourceMode()
    local owned = 0
    if mode.useBag then owned = owned + (self.backpackMaterials[matName] or 0) end
    if mode.useStorage then owned = owned + (self.storageMaterials[matName] or 0) end
    if mode.useBank then owned = owned + (self.bankMaterials[matName] or 0) end
    return owned
end

--- Builds the combined damaged artefact map across Backpack, Bank, Pins, and Targeted Collections.
local function buildCombinedArtefactsMap(self)
    local combinedArts = {}
    if self.isPinned then
        for damagedName, pinnedCount in pairs(self.pinnedArtefactCounts or {}) do
            if pinnedCount and pinnedCount > 0 then
                combinedArts[damagedName] = {
                    inBag    = self.backpackArtefacts[damagedName] or 0,
                    inBank   = self.bankArtefacts[damagedName] or 0,
                    rawCount = pinnedCount,
                }
            end
        end
    else
        for damagedName, bagCount in pairs(self.backpackArtefacts or {}) do
            if bagCount and bagCount > 0 then
                combinedArts[damagedName] = {
                    inBag    = bagCount,
                    inBank   = 0,
                    rawCount = bagCount,
                }
            end
        end
        for damagedName, bankCount in pairs(self.bankArtefacts or {}) do
            if bankCount and bankCount > 0 then
                local entry = combinedArts[damagedName]
                if entry then
                    entry.inBank   = bankCount
                    entry.rawCount = entry.inBag + bankCount
                else
                    combinedArts[damagedName] = {
                        inBag    = 0,
                        inBank   = bankCount,
                        rawCount = bankCount,
                    }
                end
            end
        end
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
                inBag           = self.backpackArtefacts[damagedName] or 0,
                inBank          = self.bankArtefacts[damagedName] or 0,
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

    for matName, reqCount in pairs(requiredByMat) do
        if reqCount > 0 then
            distinctMaterialsRequired = distinctMaterialsRequired + 1
            local matDef = Materials.get(matName) or {
                name           = matName,
                level          = 1,
                culture        = "Other",
                isArchMaterial = false,
                caches         = {},
                order          = 999,
            }

            local inBag     = self.backpackMaterials[matName] or 0
            local inStorage = self.storageMaterials[matName] or 0
            local inBank    = self.bankMaterials[matName] or 0
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

    local artefactsList   = {}
    local requiredByMat   = {}
    local totalArtefacts  = 0
    local uniqueArtefacts = 0
    local totalXp         = 0
    local totalChronotes  = 0

    for damagedName, info in pairs(combinedArts) do
        local rawCount  = info.rawCount or 0
        local minTarget = (info.neededToRestore and info.neededToRestore > 0) and info.neededToRestore or 0

        local keep = true
        if self.artefactFilter == "TARGETED" then
            keep = info.isTargetedCol or (info.colTarget and info.colTarget > 0)
        elseif self.artefactFilter == "OWNED" then
            keep = ((info.inBag or 0) + (info.inBank or 0)) > 0
        elseif hasTargeted then
            keep = info.isTargetedCol or ((info.inBag or 0) + (info.inBank or 0)) > 0
        end

        if keep and (info.isTargetedCol or rawCount > 0 or minTarget > 0) then
            local art = Artefacts.findByName(damagedName)
            if art then
                uniqueArtefacts = uniqueArtefacts + 1
                local isExcluded     = (self.excludedArtefacts[art.damagedName] ~= nil)
                local defaultQty     = resolveDefaultArtefactQty(self, art, info, rawCount, minTarget)
                local targetCount    = self.customArtefactCounts[art.damagedName] or defaultQty
                local effectiveCount = isExcluded and 0 or targetCount

                totalArtefacts = totalArtefacts + effectiveCount
                totalXp        = totalXp + (art.xp * effectiveCount)
                totalChronotes = totalChronotes + (art.chronotes * effectiveCount)

                local ownedDamaged    = (info.inBag or 0) + (info.inBank or 0)
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

                table.insert(artefactsList, {
                    artefact        = art,
                    inBag           = info.inBag or 0,
                    inBank          = info.inBank or 0,
                    ownedDamaged    = ownedDamaged,
                    rawCount        = rawCount,
                    targetCount     = targetCount,
                    effectiveCount  = effectiveCount,
                    excluded        = isExcluded,
                    maxPossibleNow  = maxPossibleNow,
                    matPossibleNow  = matPossibleNow,
                    missingMatTypes = missingMatTypes,
                    colTarget       = info.colTarget or 0,
                    colNames        = info.colNames,
                    ownedRestored   = info.ownedRestored or 0,
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

    self.lastResult = {
        artefacts                 = artefactsList,
        materials                 = materialsList,
        filteredMaterials         = filteredMaterials,
        totalArtefacts            = totalArtefacts,
        uniqueArtefacts           = uniqueArtefacts,
        restorableArtefacts       = restorableArtefacts,
        totalXp                   = totalXp,
        totalChronotes            = totalChronotes,
        distinctMaterialsRequired = distinctMaterialsRequired,
        distinctMaterialsShort    = distinctMaterialsShort,
        totalMaterialsShort       = totalMaterialsShort,
    }

    return self.lastResult
end

return Tracker
