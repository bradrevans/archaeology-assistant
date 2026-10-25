-- tracker.lua
-- Core state, inventory scanning, material source resolution, duplicate filtering,
-- and pinned target tracking for the Archaeology Assistant plugin.

local Materials = require("data/materials")
local Artefacts = require("data/artefacts")
local Collections = require("data/collections")

local Tracker = {}
Tracker.__index = Tracker

-- Supported material ownership source modes (cycled via UI button)
-- Defaults to index 1: ALL (Bag + Storage + Bank)
Tracker.SOURCE_MODES = {
    {
        id = "ALL",
        label = "Bag + Storage + Bank",
        shortLabel = "Src: All",
        useBag = true,
        useStorage = true,
        useBank = true
    },
    {
        id = "BAG_STORAGE",
        label = "Bag + Storage",
        shortLabel = "Src: Bag+Stor",
        useBag = true,
        useStorage = true,
        useBank = false
    },
    {
        id = "STORAGE_ONLY",
        label = "Storage Only",
        shortLabel = "Src: Storage",
        useBag = false,
        useStorage = true,
        useBank = false
    },
    {
        id = "BAG_ONLY",
        label = "Backpack Only",
        shortLabel = "Src: Bag Only",
        useBag = true,
        useStorage = false,
        useBank = false
    },
    {
        id = "BAG_BANK",
        label = "Bag + Bank",
        shortLabel = "Src: Bag+Bank",
        useBag = true,
        useStorage = false,
        useBank = true
    }
}

-- Simple string serializer/deserializer for key=integer maps so PersistentDB only stores primitive strings/numbers
local function serializeCountMap(map)
    if type(map) ~= "table" then
        return ""
    end
    local parts = {}
    for k, v in pairs(map) do
        local num = tonumber(v) or 0
        if k and k ~= "" and num > 0 then
            local safeKey = string.gsub(tostring(k), "[;=]", "")
            table.insert(parts, safeKey .. "=" .. tostring(math.floor(num)))
        end
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

local function deserializeCountMap(serialized)
    local map = {}
    if type(serialized) ~= "string" or serialized == "" then
        return map
    end
    for entry in string.gmatch(serialized, "([^;]+)") do
        local k, v = string.match(entry, "^(.-)=(%-?%d+)$")
        if k and v then
            map[k] = tonumber(v) or 0
        end
    end
    return map
end

local function serializeSubmittedMap(map)
    if not map then return "" end
    local parts = {}
    for colName, arts in pairs(map) do
        for artName, v in pairs(arts) do
            if v then
                table.insert(parts, string.format("%s::%s", colName, artName))
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function parseSubmittedMap(str)
    local map = {}
    if not str or str == "" then return map end
    for entry in string.gmatch(str, "[^|]+") do
        local colName, artName = string.match(entry, "^(.-)::(.+)$")
        if colName and artName then
            if not map[colName] then map[colName] = {} end
            map[colName][artName] = true
        end
    end
    return map
end

local function safeDbGet(key, defaultVal)
    if PersistentDB then
        local ok, val = pcall(function() return PersistentDB:Get(key) end)
        if ok and val ~= nil then
            return val
        end
    end
    return defaultVal
end

local function safeDbSet(key, val)
    if PersistentDB then
        pcall(function() PersistentDB:Set(key, val) end)
    end
end

local function countMapEntries(map)
    if type(map) ~= "table" then return 0 end
    local n = 0
    for _, v in pairs(map) do
        if (tonumber(v) or 0) > 0 then
            n = n + 1
        end
    end
    return n
end

-- Helper to determine if a container's contents match an artefact restoration recipe.
-- Artefact inspection/restoration dialogs in RS3 hold the exact material requirements (<= 5 materials)
-- for the inspected artefact, which must NEVER be mistaken for the player's Material Storage box.
local function isArtefactRecipeContainer(matCounts, archKinds)
    if not matCounts or not archKinds or archKinds <= 0 or archKinds > 5 then
        return false
    end
    local arts = (Artefacts and Artefacts.LIST) or {}
    for _, art in ipairs(arts) do
        if art.materials and #art.materials == archKinds then
            local allMatch = true
            for _, req in ipairs(art.materials) do
                if not matCounts[req.name] then
                    allMatch = false
                    break
                end
            end
            if allMatch then
                return true
            end
        end
    end
    return false
end

function Tracker.new()
    local self = setmetatable({}, Tracker)

    -- All filter/source toggles default to "All" (Src: All, Dupes: All, Show: All)
    self.sourceModeIndex = 1
    self.includeMode = safeDbGet("arch_include_mode", "ALL") -- "ALL" | "ONE" | "ZERO"
    self.includeDuplicates = (self.includeMode == "ALL")
    self.artefactFilter = safeDbGet("arch_art_filter", "ALL") -- "ALL" | "TARGETED" | "OWNED"
    self.shortOnly = false

    local savedPinned = safeDbGet("arch_is_pinned", 0)
    self.isPinned = (savedPinned == 1 or savedPinned == true)

    -- Excluded specific artefacts (damagedName -> 1)
    self.excludedArtefacts = deserializeCountMap(safeDbGet("arch_excluded_artefacts", ""))

    -- Custom per-artefact included quantity overrides (damagedName -> count)
    self.customArtefactCounts = deserializeCountMap(safeDbGet("arch_custom_art_counts", ""))

    -- Pinned artefacts map (damagedName -> count)
    self.pinnedArtefactCounts = deserializeCountMap(safeDbGet("arch_pinned_artefacts", ""))

    -- Cached damaged artefact counts in Backpack and Bank
    self.backpackArtefacts = {}
    self.bankArtefacts = deserializeCountMap(safeDbGet("arch_bank_artefacts", ""))

    -- Cached restored artefact counts in Backpack and Bank
    self.backpackRestored = {}
    self.bankRestored = deserializeCountMap(safeDbGet("arch_bank_restored", ""))

    -- Collections tracking
    self.completedCollections = deserializeCountMap(safeDbGet("arch_completed_collections", ""))
    self.targetedCollections = deserializeCountMap(safeDbGet("arch_targeted_collections", ""))
    self.submittedArtefacts = parseSubmittedMap(safeDbGet("arch_submitted_artefacts", ""))

    -- Clean out falsely auto-populated repeatable collection submissions from previous sessions
    if Collections and Collections.LIST then
        local cleaned = false
        for _, col in ipairs(Collections.LIST) do
            if col.isRepeatable and self.submittedArtefacts[col.name] then
                -- If all artefacts were marked as submitted, this was from the old achievement bug; prune it!
                local allSub = true
                local count = 0
                for _, artName in ipairs(col.artefacts or {}) do
                    count = count + 1
                    if not self.submittedArtefacts[col.name][artName] then
                        allSub = false
                        break
                    end
                end
                if allSub and count > 0 then
                    self.submittedArtefacts[col.name] = nil
                    cleaned = true
                end
            end
        end
        if cleaned then
            safeDbSet("arch_submitted_artefacts", serializeSubmittedMap(self.submittedArtefacts))
        end
    end

    -- Cached material counts by canonical material name
    self.backpackMaterials = {}
    self.storageMaterials = deserializeCountMap(safeDbGet("arch_storage_materials", ""))
    self.bankMaterials = deserializeCountMap(safeDbGet("arch_bank_materials", ""))

    local storEntries = countMapEntries(self.storageMaterials)
    local bankEntries = countMapEntries(self.bankMaterials) + countMapEntries(self.bankArtefacts)

    self.storageInvId = -1
    self.bankInvId = tonumber(safeDbGet("arch_bank_inv_id", -1)) or -1
    safeDbSet("arch_storage_inv_id", -1)

    -- Guard against cached storage corruption caused by inspecting a damaged artefact or false bank deposits in a previous session
    if storEntries > 0 and storEntries <= 5 then
        if isArtefactRecipeContainer(self.storageMaterials, storEntries) or (safeDbGet("arch_storage_synced", 0) == 0 and bankEntries > 0) then
            self.storageMaterials = {}
            storEntries = 0
            safeDbSet("arch_storage_materials", "")
            safeDbSet("arch_storage_synced", 0)
        end
    end

    self.storageIconObjId = 49429
    self.bankIconObjId = 995
    self.storageSyncedLive = false
    self.bankSyncedLive = false
    self.boardSyncedLive = false

    -- If storage was falsely populated with an exact duplicate copy of Bank, purge it
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
        safeDbSet("arch_storage_materials", "")
        safeDbSet("arch_storage_synced", 0)
    end

    self.storageHasCache = (storEntries > 0)
    self.bankHasCache = (bankEntries > 0)
    self.boardHasCache = (countMapEntries(self.completedCollections) > 0)
    self.lastAction = nil

    -- Computed state for UI consumption
    self.lastResult = {
        artefacts = {},
        materials = {},
        filteredMaterials = {},
        totalArtefacts = 0,
        uniqueArtefacts = 0,
        restorableArtefacts = 0,
        totalXp = 0,
        totalChronotes = 0,
        distinctMaterialsRequired = 0,
        distinctMaterialsShort = 0,
        totalMaterialsShort = 0
    }

    -- Check if achievements are already available for free sync
    pcall(function() self:syncCollectionsDoneStatus() end)

    return self
end

function Tracker:getSourceMode()
    return Tracker.SOURCE_MODES[self.sourceModeIndex] or Tracker.SOURCE_MODES[1]
end

-- Returns structured sync status for Material Storage, Bank, and Collector Board icon badges/tooltips
function Tracker:getSyncStatus()
    local mode = self:getSourceMode()
    local storEntries = countMapEntries(self.storageMaterials)
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
            synced = self.storageSyncedLive == true,
            cached = (not self.storageSyncedLive) and (self.storageHasCache or storEntries > 0),
            enabled = mode.useStorage == true,
            matTypes = storEntries
        },
        bank = {
            synced = self.bankSyncedLive == true,
            cached = (not self.bankSyncedLive) and (self.bankHasCache or (bankMatEntries + bankArtEntries) > 0),
            enabled = (mode.useBank == true) or (mode.id ~= "BAG_ONLY"),
            matTypes = bankMatEntries,
            artTypes = bankArtEntries
        },
        board = {
            synced = self.boardSyncedLive == true,
            cached = (not self.boardSyncedLive) and (self.boardHasCache or submittedCount > 0 or completedCount > 0),
            enabled = true,
            completedCount = completedCount,
            submittedCount = submittedCount
        }
    }
end

function Tracker:cycleSourceMode()
    self.sourceModeIndex = (self.sourceModeIndex % #Tracker.SOURCE_MODES) + 1
    safeDbSet("arch_source_mode_idx", self.sourceModeIndex)
    return self:recalculate()
end

function Tracker:hasCustomCounts()
    return countMapEntries(self.customArtefactCounts) > 0
end

-- Cycles inclusion mode: Dupes: All -> Dupes: 1x -> Include: 0 -> Dupes: All
-- Switching to All or 1x cleanly re-includes previously excluded artefacts
function Tracker:cycleDuplicates()
    if self:hasCustomCounts() or countMapEntries(self.excludedArtefacts) > 0 then
        -- Reset any custom +/- overrides or manual exclusions back to clean All mode
        self.includeMode = "ALL"
        self.includeDuplicates = true
        self.excludedArtefacts = {}
        self.customArtefactCounts = {}
    elseif self.includeMode == "ALL" then
        self.includeMode = "ONE"
        self.includeDuplicates = false
        self.excludedArtefacts = {}
        self.customArtefactCounts = {}
    elseif self.includeMode == "ONE" then
        self.includeMode = "ZERO"
        self.includeDuplicates = false
        self.excludedArtefacts = {}
        self.customArtefactCounts = {}
    else
        self.includeMode = "ALL"
        self.includeDuplicates = true
        self.excludedArtefacts = {}
        self.customArtefactCounts = {}
    end
    safeDbSet("arch_include_mode", self.includeMode)
    safeDbSet("arch_include_dupes", self.includeDuplicates and 1 or 0)
    safeDbSet("arch_excluded_artefacts", "")
    safeDbSet("arch_custom_art_counts", "")
    return self:recalculate()
end

function Tracker:toggleDuplicates()
    return self:cycleDuplicates()
end

-- Cycles Artefact source filter: All -> Targeted Only -> Owned Only -> All
function Tracker:cycleArtefactFilter()
    if self.artefactFilter == "ALL" then
        self.artefactFilter = "TARGETED"
    elseif self.artefactFilter == "TARGETED" then
        self.artefactFilter = "OWNED"
    else
        self.artefactFilter = "ALL"
    end
    safeDbSet("arch_art_filter", self.artefactFilter)
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
    safeDbSet("arch_short_only", self.shortOnly and 1 or 0)
    return self:recalculate()
end

function Tracker:toggleArtefactExcluded(damagedName)
    if not damagedName then return self.lastResult end
    if self.excludedArtefacts[damagedName] then
        self.excludedArtefacts[damagedName] = nil
        if (self.customArtefactCounts[damagedName] or 0) <= 0 then
            self.customArtefactCounts[damagedName] = nil
            safeDbSet("arch_custom_art_counts", serializeCountMap(self.customArtefactCounts))
        end
    else
        self.excludedArtefacts[damagedName] = 1
    end
    safeDbSet("arch_excluded_artefacts", serializeCountMap(self.excludedArtefacts))
    return self:recalculate()
end

function Tracker:adjustArtefactCount(damagedName, delta, rawCount)
    if not damagedName then return self.lastResult end
    local defaultQty
    if self.includeMode == "ZERO" then
        defaultQty = 0
    elseif self.includeMode == "ONE" or not self.includeDuplicates then
        defaultQty = 1
    else
        defaultQty = math.max(1, tonumber(rawCount) or 1)
    end

    local currentQty
    if self.excludedArtefacts[damagedName] then
        currentQty = 0
    else
        currentQty = self.customArtefactCounts[damagedName] or defaultQty
    end

    local newQty = math.max(0, currentQty + (tonumber(delta) or 0))
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

    safeDbSet("arch_excluded_artefacts", serializeCountMap(self.excludedArtefacts))
    safeDbSet("arch_custom_art_counts", serializeCountMap(self.customArtefactCounts))
    return self:recalculate()
end

-- Completely wipes all persistent storage caches, custom counts, exclusions, and pins back to pristine state
-- Note: Completed collections (achievements) are permanent account milestones and preserved.
function Tracker:clearAllCache()
    self.storageMaterials = {}
    self.bankMaterials = {}
    self.bankArtefacts = {}
    self.bankRestored = {}
    self.targetedCollections = {}
    self.excludedArtefacts = {}
    self.customArtefactCounts = {}
    self.pinnedArtefactCounts = {}
    self.isPinned = false
    self.storageSyncedLive = false
    self.bankSyncedLive = false
    self.storageHasCache = false
    self.bankHasCache = false

    safeDbSet("arch_storage_materials", "")
    safeDbSet("arch_storage_synced", 0)
    safeDbSet("arch_storage_inv_id", -1)
    safeDbSet("arch_bank_materials", "")
    safeDbSet("arch_bank_artefacts", "")
    safeDbSet("arch_bank_restored", "")
    safeDbSet("arch_bank_inv_id", -1)
    safeDbSet("arch_targeted_collections", "")
    safeDbSet("arch_excluded_artefacts", "")
    safeDbSet("arch_custom_art_counts", "")
    safeDbSet("arch_pinned_artefacts", "")
    safeDbSet("arch_is_pinned", 0)

    return self:recalculate()
end

-- Pins or unpins the currently detected artefact list so the player can lock a specific set
function Tracker:togglePin()
    if self.isPinned then
        self.isPinned = false
        self.pinnedArtefactCounts = {}
        safeDbSet("arch_is_pinned", 0)
        safeDbSet("arch_pinned_artefacts", "")
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
        safeDbSet("arch_is_pinned", self.isPinned and 1 or 0)
        safeDbSet("arch_pinned_artefacts", serializeCountMap(self.pinnedArtefactCounts))
    end
    return self:recalculate()
end

-- =========================================================================
-- Collections Management (Completion, Targeting, Progress)
-- =========================================================================

function Tracker:isCollectionCompleted(colName)
    if not colName then return false end
    return (self.completedCollections[colName] or 0) > 0
end

function Tracker:toggleCollectionCompleted(colName)
    if not colName then return self.lastResult end
    if self:isCollectionCompleted(colName) then
        self.completedCollections[colName] = nil
    else
        self.completedCollections[colName] = 1
    end
    safeDbSet("arch_completed_collections", serializeCountMap(self.completedCollections))
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
    safeDbSet("arch_targeted_collections", serializeCountMap(self.targetedCollections))
    return self:recalculate()
end

function Tracker:clearTargetedCollections()
    self.targetedCollections = {}
    safeDbSet("arch_targeted_collections", "")
    return self:recalculate()
end

function Tracker:getTargetedCount()
    return countMapEntries(self.targetedCollections)
end

function Tracker:hasTargetedCollections()
    return self:getTargetedCount() > 0
end

function Tracker:isArtefactSubmitted(colName, artName)
    if not colName or not artName then return false end
    if self.submittedArtefacts and self.submittedArtefacts[colName] and self.submittedArtefacts[colName][artName] then
        return true
    end
    if self:isCollectionCompleted(colName) then
        local col = Collections and Collections.BY_NAME and Collections.BY_NAME[colName]
        if col and not col.isRepeatable then
            return true
        end
    end
    return false
end

function Tracker:toggleArtefactSubmitted(colName, artName)
    if not colName or not artName then return self.lastResult end
    if not self.submittedArtefacts then self.submittedArtefacts = {} end
    if not self.submittedArtefacts[colName] then
        self.submittedArtefacts[colName] = {}
    end
    if self.submittedArtefacts[colName][artName] then
        self.submittedArtefacts[colName][artName] = nil
    else
        self.submittedArtefacts[colName][artName] = true
    end
    safeDbSet("arch_submitted_artefacts", serializeSubmittedMap(self.submittedArtefacts))
    return self:recalculate()
end

function Tracker:clearRepeatableSubmissions(colName)
    if colName then
        if self.submittedArtefacts then
            self.submittedArtefacts[colName] = nil
        end
    else
        for _, col in ipairs(Collections and Collections.LIST or {}) do
            if col.isRepeatable and self.submittedArtefacts then
                self.submittedArtefacts[col.name] = nil
            end
        end
    end
    safeDbSet("arch_submitted_artefacts", serializeSubmittedMap(self.submittedArtefacts))
    return self:recalculate()
end

function Tracker:getCollectionProgress(col)
    if not col or not col.artefacts then
        return { readyCount = 0, damagedCount = 0, totalCount = 0, isReady = false, isCompleted = false, isTargeted = false, artefacts = {} }
    end

    local total = #col.artefacts
    local readyCount = 0
    local damagedCount = 0
    local artStatuses = {}

    for _, artName in ipairs(col.artefacts) do
        local isSubmitted = self:isArtefactSubmitted(col.name, artName)
        local bagRestored = self.backpackRestored[artName] or 0
        local bankRestored = self.bankRestored[artName] or 0
        local totalRestored = bagRestored + bankRestored

        local damagedName = artName .. " (damaged)"
        local bagDamaged = self.backpackArtefacts[damagedName] or 0
        local bankDamaged = self.bankArtefacts[damagedName] or 0
        local totalDamaged = bagDamaged + bankDamaged

        local isReady = isSubmitted or (totalRestored > 0)
        if isReady then
            readyCount = readyCount + 1
        elseif totalDamaged > 0 then
            damagedCount = damagedCount + 1
        end

        table.insert(artStatuses, {
            name = artName,
            isSubmitted = isSubmitted,
            restoredCount = totalRestored,
            damagedCount = totalDamaged,
            isReady = isReady
        })
    end

    local isCompleted = self:isCollectionCompleted(col.name)
    local isTargeted = self:isCollectionTargeted(col.name)

    return {
        readyCount = readyCount,
        damagedCount = damagedCount,
        totalCount = total,
        isReady = (readyCount >= total and total > 0),
        isCompleted = isCompleted,
        isTargeted = isTargeted,
        artefacts = artStatuses
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
                    -- If the artefact has already been submitted to the collector,
                    -- it does NOT need to be excavated or restored for this collection!
                    local isSubmitted = self:isArtefactSubmitted(col.name, artName)
                    if not isSubmitted then
                        local damagedName = artName .. " (damaged)"
                        if not requirements[damagedName] then
                            requirements[damagedName] = {
                                artName = artName,
                                damagedName = damagedName,
                                count = 1,
                                collections = { col.name }
                            }
                        else
                            requirements[damagedName].count = requirements[damagedName].count + 1
                            table.insert(requirements[damagedName].collections, col.name)
                        end
                    end
                end
            end
        end
    end

    for _, req in pairs(requirements) do
        local bagRestored = self.backpackRestored[req.artName] or 0
        local bankRestored = self.bankRestored[req.artName] or 0
        local totalRestored = bagRestored + bankRestored
        req.ownedRestored = totalRestored
        req.neededToRestore = math.max(0, req.count - totalRestored)
    end

    return requirements
end

-- Returns how many copies of an artefact are still needed to be collected from excavation spots
function Tracker:getArtefactNeededCount(damagedName, artName)
    if not damagedName then return 0 end
    artName = artName or string.gsub(damagedName, "%s*%(damaged%)", "")

    local targetQty = 0
    local colTargets = self:getTargetedArtefactRequirements()
    local targetInfo = colTargets[damagedName]
    if targetInfo and targetInfo.count then
        targetQty = targetInfo.count
    end

    if targetQty == 0 and self.lastResult and self.lastResult.artefacts then
        for _, item in ipairs(self.lastResult.artefacts) do
            if item.artefact and item.artefact.damagedName == damagedName then
                if not item.excluded and (item.effectiveCount or 0) > 0 then
                    targetQty = item.effectiveCount
                end
                break
            end
        end
    end

    if targetQty <= 0 then
        return 0
    end

    local inBagDamaged = self.backpackArtefacts[damagedName] or 0
    local inBankDamaged = self.bankArtefacts[damagedName] or 0
    local inBagRestored = self.backpackRestored[artName] or 0
    local inBankRestored = self.bankRestored[artName] or 0
    local totalOwned = inBagDamaged + inBankDamaged + inBagRestored + inBankRestored

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

    local totalCount = #Collections.LIST
    local completedTotal = 0
    local readyTotal = 0
    local targetedTotal = 0

    for _, col in ipairs(Collections.LIST) do
        local progress = self:getCollectionProgress(col)
        if progress.isCompleted then
            completedTotal = completedTotal + 1
        end
        if progress.isReady then
            readyTotal = readyTotal + 1
        end
        if progress.isTargeted then
            targetedTotal = targetedTotal + 1
        end

        local include = true
        if filterMode == "incomplete" then
            include = not progress.isCompleted
        elseif filterMode == "targeted" then
            include = progress.isTargeted
        elseif filterMode == "powers" then
            include = (col.benefitType == "relic" or col.benefitType == "weapon" or col.benefitType == "mystery")
        end

        if include then
            table.insert(list, {
                data = col,
                progress = progress
            })
        end
    end

    return list, totalCount, completedTotal, targetedTotal, readyTotal
end

function Tracker:savePersistentState()
    safeDbSet("arch_source_mode_idx", self.sourceModeIndex)
    safeDbSet("arch_include_dupes", self.includeDuplicates and 1 or 0)
    safeDbSet("arch_short_only", self.shortOnly and 1 or 0)
    safeDbSet("arch_is_pinned", self.isPinned and 1 or 0)
    safeDbSet("arch_pinned_artefacts", serializeCountMap(self.pinnedArtefactCounts))
    safeDbSet("arch_excluded_artefacts", serializeCountMap(self.excludedArtefacts))
    safeDbSet("arch_custom_art_counts", serializeCountMap(self.customArtefactCounts))
    safeDbSet("arch_bank_artefacts", serializeCountMap(self.bankArtefacts))
    safeDbSet("arch_bank_restored", serializeCountMap(self.bankRestored))
    safeDbSet("arch_completed_collections", serializeCountMap(self.completedCollections))
    safeDbSet("arch_targeted_collections", serializeCountMap(self.targetedCollections))
    safeDbSet("arch_submitted_artefacts", serializeSubmittedMap(self.submittedArtefacts))
    safeDbSet("arch_storage_materials", serializeCountMap(self.storageMaterials))
    safeDbSet("arch_bank_materials", serializeCountMap(self.bankMaterials))
    safeDbSet("arch_storage_synced", self.storageSyncedLive and 1 or 0)
    safeDbSet("arch_bank_synced", self.bankSyncedLive and 1 or 0)
    if self.storageInvId and self.storageInvId >= 0 then
        safeDbSet("arch_storage_inv_id", self.storageInvId)
    end
    if self.bankInvId and self.bankInvId >= 0 then
        safeDbSet("arch_bank_inv_id", self.bankInvId)
    end
end

-- Helper to safely retrieve an Inventory instance
local function findInventory(invRef)
    if not Inventory or not Inventory.Find or not invRef then
        return nil
    end
    local ok, inv = pcall(function() return Inventory.Find(invRef) end)
    if ok and inv then
        local validOk, isValid = pcall(function() return inv.isValid end)
        if not validOk or isValid then
            return inv
        end
    end
    local okId, refId = pcall(function() return invRef.id end)
    if okId and type(refId) == "number" then
        local okById, invById = pcall(function() return Inventory.Find(refId) end)
        if okById and invById then
            local validOk, isValid = pcall(function() return invById.isValid end)
            if not validOk or isValid then
                return invById
            end
        end
    end
    return nil
end

-- Safely extracts slots from an Inv object
local function getInventorySlots(inv)
    if not inv then return {} end
    local ok, slots = pcall(function() return inv:GetSlots() end)
    if ok and type(slots) == "table" then
        return slots
    end
    return {}
end

-- Safely extracts item name and count from an InvSlot
local function getSlotItemInfo(slot)
    if not slot then return nil, 0 end
    local okCount, count = pcall(function() return slot.count end)
    if not okCount or not count or count <= 0 then
        return nil, 0
    end
    local okObj, obj = pcall(function() return slot.obj end)
    if not okObj or not obj then
        return nil, 0
    end
    local okName, name = pcall(function() return obj.name end)
    if not okName or not name or name == "" or name == "nil" then
        return nil, 0
    end
    return obj, count, name
end

-- Scans an inventory in a single pass and returns:
--   matCounts ({ [canonicalMaterialName] = totalCount }),
--   archMatKinds (number of slots containing archaeology materials),
--   nonMatSlots (number of slots containing non-material items),
--   artCounts ({ [damagedArtefactName] = totalCount }),
--   restoredCounts ({ [restoredArtefactName] = totalCount }),
--   totalSlots (number of total slots in the container)
function Tracker:extractMaterialsFromInv(inv)
    local matCounts = {}
    local artCounts = {}
    local restoredCounts = {}
    local archMatKinds = 0
    local nonMatSlots = 0

    local slots = getInventorySlots(inv)
    local totalSlots = #slots

    for _, slot in ipairs(slots) do
        local obj, count, rawName = getSlotItemInfo(slot)
        if rawName and count > 0 then
            local mat = Materials.get(rawName)
            if mat then
                matCounts[mat.name] = (matCounts[mat.name] or 0) + count
                if mat.isArchMaterial then
                    archMatKinds = archMatKinds + 1
                end
            else
                nonMatSlots = nonMatSlots + 1
                local art, isDamaged = Artefacts.findByName(rawName)
                if art then
                    if isDamaged ~= false then
                        artCounts[art.damagedName] = (artCounts[art.damagedName] or 0) + count
                    else
                        restoredCounts[art.name] = (restoredCounts[art.name] or 0) + count
                    end
                end
            end
        end
    end

    return matCounts, archMatKinds, nonMatSlots, artCounts, restoredCounts, totalSlots
end

-- Scans the player's Backpack, Bank, and any known/candidate Material Storage containers
function Tracker:scanAllInventories(triggerInvType)
    if not config or not config.Inv then
        return
    end

    -- 1. Always scan Backpack (config.Inv.INV) for both materials and damaged artefacts
    local bagInv = findInventory(config.Inv.INV)
    if bagInv then
        local bagMats, _, _, bagArts, bagRestored = self:extractMaterialsFromInv(bagInv)
        self.backpackRestored = bagRestored or {}

        -- If materials left the backpack, they were deposited (e.g. into a Material Cart or deposit box).
        -- Retain player progress by crediting them to Material Storage, excluding materials consumed by restoring an artefact.
        if self.prevBackpackMaterials then
            local artsRestored = {}
            for artName, prevArtCount in pairs(self.prevBackpackArtefacts or {}) do
                local currentArtCount = bagArts[artName] or 0
                if currentArtCount < prevArtCount then
                    artsRestored[artName] = prevArtCount - currentArtCount
                end
            end

            local consumedMats = {}
            for artName, countRestored in pairs(artsRestored) do
                -- If pinned, decrement the pinned target count so the restored artefact is removed from tracking
                if self.isPinned and self.pinnedArtefactCounts and self.pinnedArtefactCounts[artName] then
                    self.pinnedArtefactCounts[artName] = math.max(0, self.pinnedArtefactCounts[artName] - countRestored)
                    if self.pinnedArtefactCounts[artName] == 0 then
                        self.pinnedArtefactCounts[artName] = nil
                    end
                    safeDbSet("arch_pinned_artefacts", serializeCountMap(self.pinnedArtefactCounts))
                end

                local artDef = Artefacts.findByName(artName)
                if artDef and artDef.materials then
                    for _, req in ipairs(artDef.materials) do
                        consumedMats[req.name] = (consumedMats[req.name] or 0) + (req.count * countRestored)
                    end
                end
            end

            local storageChanged = false
            local bankChanged = false

            -- Deduct materials consumed by restoring an artefact from Material Storage (where workbench pulls from)
            for matName, consumedCount in pairs(consumedMats) do
                local remainingToConsume = consumedCount
                local prevBag = self.prevBackpackMaterials[matName] or 0
                local currBag = bagMats[matName] or 0
                local bagLost = math.max(0, prevBag - currBag)
                local consumedFromBag = math.min(bagLost, remainingToConsume)
                remainingToConsume = remainingToConsume - consumedFromBag

                if remainingToConsume > 0 then
                    local currentStor = self.storageMaterials[matName] or 0
                    local storDeduct = math.min(currentStor, remainingToConsume)
                    if storDeduct > 0 then
                        self.storageMaterials[matName] = currentStor - storDeduct
                        storageChanged = true
                    end
                end
            end
            for matName, prevCount in pairs(self.prevBackpackMaterials) do
                local currentCount = bagMats[matName] or 0
                local delta = currentCount - prevCount
                if delta < 0 then
                    local removedCount = -delta
                    local consumed = consumedMats[matName] or 0
                    local depositedCount = removedCount
                    if consumed > 0 then
                        local consumedFromBag = math.min(depositedCount, consumed)
                        depositedCount = depositedCount - consumedFromBag
                        consumedMats[matName] = consumed - consumedFromBag
                    end

                    -- If the player explicitly dropped the item, do not credit to storage or bank
                    if self.lastAction == "drop" then
                        -- Dropping resources decreases the total naturally
                    elseif self.lastAction == "bank" then
                        -- Deposited into Bank (bank chest, bank booth, deposit box): credit to bankMaterials!
                        if depositedCount > 0 then
                            self.bankMaterials[matName] = (self.bankMaterials[matName] or 0) + depositedCount
                            bankChanged = true
                        end
                    else
                        -- Deposited into Material Storage (Material Cart, storage box): credit to storageMaterials!
                        if depositedCount > 0 then
                            self.storageMaterials[matName] = (self.storageMaterials[matName] or 0) + depositedCount
                            storageChanged = true
                        end
                    end
                end
            end

            if storageChanged then
                safeDbSet("arch_storage_materials", serializeCountMap(self.storageMaterials))
            end
            if bankChanged then
                safeDbSet("arch_bank_materials", serializeCountMap(self.bankMaterials))
            end

            self.lastAction = nil
        end

        self.backpackMaterials = bagMats
        self.backpackArtefacts = bagArts
        self.prevBackpackMaterials = bagMats
        self.prevBackpackArtefacts = bagArts
    end

    -- 2. Check Bank (config.Inv.BANK or bankInvId) if available for both materials and damaged artefacts
    local checkedBank = false
    if config.Inv.BANK then
        local bankInv = findInventory(config.Inv.BANK)
        if bankInv then
            local bankMats, archKinds, nonMatSlots, bankArts, bankRestored = self:extractMaterialsFromInv(bankInv)
            local triggeredByBank = (triggerInvType ~= nil and triggerInvType == config.Inv.BANK)
            if triggeredByBank or archKinds > 0 or nonMatSlots > 0 then
                self.bankMaterials = bankMats
                self.bankArtefacts = bankArts
                self.bankRestored = bankRestored or {}
                self.bankSyncedLive = true
                checkedBank = true
                local okId, invId = pcall(function() return config.Inv.BANK.id end)
                if okId and type(invId) == "number" then
                    self.bankInvId = invId
                    safeDbSet("arch_bank_inv_id", invId)
                end
                safeDbSet("arch_bank_synced", 1)
                safeDbSet("arch_bank_materials", serializeCountMap(self.bankMaterials))
                safeDbSet("arch_bank_artefacts", serializeCountMap(self.bankArtefacts))
                safeDbSet("arch_bank_restored", serializeCountMap(self.bankRestored))
            end
        end
    end

    if not checkedBank and self.bankInvId and self.bankInvId >= 0 then
        local bankInv = findInventory(self.bankInvId)
        if bankInv then
            local bankMats, archKinds, nonMatSlots, bankArts, bankRestored = self:extractMaterialsFromInv(bankInv)
            if archKinds > 0 or nonMatSlots > 0 then
                self.bankMaterials = bankMats
                self.bankArtefacts = bankArts
                self.bankRestored = bankRestored or {}
                self.bankSyncedLive = true
                safeDbSet("arch_bank_synced", 1)
                safeDbSet("arch_bank_materials", serializeCountMap(self.bankMaterials))
                safeDbSet("arch_bank_artefacts", serializeCountMap(self.bankArtefacts))
                safeDbSet("arch_bank_restored", serializeCountMap(self.bankRestored))
            end
        end
    end

    -- 3. Check if triggerInvType is the Material Storage container
    if triggerInvType then
        local isBag = (config.Inv.INV and triggerInvType == config.Inv.INV)
        local isBank = (config.Inv.BANK and triggerInvType == config.Inv.BANK)
        local isWorn = (config.Inv.WORN and triggerInvType == config.Inv.WORN)
        if not isBag and not isBank and not isWorn then
            local customInv = findInventory(triggerInvType)
            if customInv and customInv ~= bagInv and customInv ~= bankInv then
                local mats, archKinds, nonMatSlots, _, _, totalSlots = self:extractMaterialsFromInv(customInv)
                local isInspect = (totalSlots > 0 and totalSlots < 15) or isArtefactRecipeContainer(mats, archKinds)
                -- Material Storage holds exclusively Archaeology materials and has large capacity (>= 20 slots)
                local isStorage = (self.lastAction == "storage" or totalSlots >= 20)
                    and archKinds >= 1
                    and nonMatSlots == 0
                    and not isInspect

                if isStorage then
                    self.storageMaterials = mats
                    self.storageSyncedLive = true
                    self.storageHasCache = true
                    safeDbSet("arch_storage_synced", 1)
                    safeDbSet("arch_storage_materials", serializeCountMap(self.storageMaterials))
                end
            end
        end
    end
end

-- Scans any currently open Collector Information or Archaeology journal interface components
function Tracker:scanCollectorInterface()
    if not ui or not ui.Interfaces or not id or not id.Component then return false end
    local detected = false

    local function inspectComp(comp, depth)
        if not comp or depth > 8 then return end
        local txt = nil
        pcall(function() txt = comp.content or comp.text end)
        if txt and type(txt) == "string" and txt ~= "" then
            local txtLower = string.lower(txt)
            for artName, _ in pairs(Artefacts.ALL or {}) do
                local artLower = string.lower(artName)
                if string.find(txtLower, artLower, 1, true) then
                    local isDone = false
                    if string.find(txtLower, "1/1") or string.find(txtLower, "handed in")
                        or string.find(txtLower, "turned in") or string.find(txtLower, "submitted")
                        or string.find(txtLower, "complete") or string.find(txtLower, "contributed")
                        or string.find(txtLower, "done") or string.find(txtLower, "yes") then
                        isDone = true
                    end

                    -- Check green text colour (indicates turned-in / complete in RS3 UI)
                    if not isDone and comp.colour then
                        pcall(function()
                            local colVal = comp.colour
                            if type(colVal) == "table" and colVal.y and colVal.x and colVal.z then
                                if colVal.y > 0.6 and colVal.y > colVal.x and colVal.y > colVal.z then
                                    isDone = true
                                end
                            elseif type(colVal) == "number" then
                                local r = math.floor(colVal / 16777216) % 256
                                local g = math.floor(colVal / 65536) % 256
                                local b = math.floor(colVal / 256) % 256
                                if g > 150 and g > (r + 40) and g > (b + 40) then
                                    isDone = true
                                end
                            end
                        end)
                    end

                    if isDone then
                        for _, col in ipairs(Collections.LIST or {}) do
                            if col.artefacts then
                                for _, colArt in ipairs(col.artefacts) do
                                    if colArt == artName then
                                        self.submittedArtefacts[col.name] = self.submittedArtefacts[col.name] or {}
                                        if not self.submittedArtefacts[col.name][artName] then
                                            self.submittedArtefacts[col.name][artName] = true
                                            detected = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if comp.IterateStaticComponents then
            pcall(comp.IterateStaticComponents, comp, function(child, visible)
                inspectComp(child, depth + 1)
            end)
        end
        if comp.IterateDynamicComponents then
            pcall(comp.IterateDynamicComponents, comp, function(child, visible)
                inspectComp(child, depth + 1)
            end)
        end
    end

    pcall(function()
        local root = nil
        if id.Component.TOPLEVEL_V2__ROOT then
            root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__ROOT)
        end
        if not root and id.Component.TOPLEVEL_V2__GAME_AREA then
            root = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
        end
        if root then
            inspectComp(root, 1)
        end
    end)

    if detected then
        self.boardSyncedLive = true
        self.boardHasCache = true
        safeDbSet("arch_submitted_artefacts", serializeSubmittedMap(self.submittedArtefacts))
        self:recalculate()
    end
    return detected
end

function Tracker:onLogicTick()
    if self.scanTicksRemaining and self.scanTicksRemaining > 0 then
        self.scanTicksRemaining = self.scanTicksRemaining - 1
        if self:scanCollectorInterface() then
            self.scanTicksRemaining = 0
            return true
        end
    end
    return false
end

-- Synchronizes completed collections and submitted artefacts from in-game achievements
function Tracker:syncCollectionsDoneStatus()
    local syncedCount = 0
    if not Collections or not Collections.LIST then return 0 end

    local hasValidAchievementData = false
    local submittedChanged = false

    for _, col in ipairs(Collections.LIST) do
        local achId = col.achievementId
        if achId and achId > 0 then
            if config and config.Achievement and config.Achievement.FromID then
                local ok, ach = pcall(config.Achievement.FromID, achId)
                if ok and ach and type(ach.progress) == "number" then
                    hasValidAchievementData = true
                    -- AchievementProgressType.COMPLETE is -2 (or 1 in some boolean states)
                    if ach.progress == -2 or ach.progress == 1 then
                        if not self.completedCollections[col.name] then
                            self.completedCollections[col.name] = 1
                            syncedCount = syncedCount + 1
                        end
                        -- Non-repeatable collections are permanently submitted once the achievement is complete.
                        -- For repeatable collections, achievements in RS3 stay -2 forever; we do NOT auto-mark
                        -- all artefacts as submitted for the current repeatable run!
                        if not col.isRepeatable then
                            if not self.submittedArtefacts[col.name] then
                                self.submittedArtefacts[col.name] = {}
                            end
                            if col.artefacts then
                                for _, artName in ipairs(col.artefacts) do
                                    if not self.submittedArtefacts[col.name][artName] then
                                        self.submittedArtefacts[col.name][artName] = true
                                        submittedChanged = true
                                    end
                                end
                            end
                        end
                    else
                        -- In-progress collection: check sub-requirements for individual submitted items
                        local reqs = nil
                        pcall(function() reqs = ach.requirements end)
                        if not reqs and type(ach.GetRequirements) == "function" then
                            pcall(function() reqs = ach:GetRequirements() end)
                        end

                        if reqs then
                            local reqCount = 0
                            pcall(function() reqCount = #reqs end)
                            if reqCount and reqCount > 0 then
                                if not self.submittedArtefacts[col.name] then
                                    self.submittedArtefacts[col.name] = {}
                                end
                                for idx = 1, reqCount do
                                    local test = reqs[idx]
                                    if test then
                                        local isDone = false
                                        pcall(function()
                                            if type(test.isComplete) == "boolean" then
                                                isDone = test.isComplete
                                            elseif type(test.isComplete) == "function" then
                                                isDone = test:isComplete()
                                            elseif type(test.progress) == "number" then
                                                isDone = (test.progress == -2 or (test.targetValue and test.progress >= test.targetValue))
                                            end
                                        end)

                                        if isDone then
                                            local matchedName = nil
                                            local desc = nil
                                            pcall(function() desc = test.description or test.name or test.desc end)
                                            if desc and type(desc) == "string" and col.artefacts then
                                                local descLower = string.lower(desc)
                                                for _, artName in ipairs(col.artefacts) do
                                                    if string.find(descLower, string.lower(artName), 1, true) then
                                                        matchedName = artName
                                                        break
                                                    end
                                                end
                                            end
                                            if not matchedName and col.artefacts and col.artefacts[idx] then
                                                matchedName = col.artefacts[idx]
                                            end
                                            if matchedName and not self.submittedArtefacts[col.name][matchedName] then
                                                self.submittedArtefacts[col.name][matchedName] = true
                                                submittedChanged = true
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if hasValidAchievementData then
        self.boardHasCache = true
    end

    if submittedChanged then
        safeDbSet("arch_submitted_artefacts", serializeSubmittedMap(self.submittedArtefacts))
    end

    if syncedCount > 0 or submittedChanged then
        if syncedCount > 0 then
            safeDbSet("arch_completed_collections", serializeCountMap(self.completedCollections))
        end
        self:recalculate()
    end
    return syncedCount
end

-- Forces a live sync of the Collector noticeboard, journal, and active collector interfaces
function Tracker:syncCollectorBoard()
    self.boardSyncedLive = true
    self.boardHasCache = true
    self:syncCollectionsDoneStatus()
    self:scanCollectorInterface()
    return self:recalculate()
end

-- Tracks player actions (e.g. Drop vs Deposit into Bank vs Deposit into Material Cart vs Checking Noticeboard) from in-game MiniMenu clicks
function Tracker:onMiniMenuAction(verb, full)
    local vLower = string.lower(verb or "")
    local fLower = string.lower(full or "")
    if vLower == "drop" or string.find(fLower, "drop") then
        self.lastAction = "drop"
    elseif string.find(fLower, "bank") or string.find(fLower, "chest") or string.find(fLower, "booth") or string.find(fLower, "deposit box") then
        self.lastAction = "bank"
    elseif string.find(fLower, "cart") or string.find(fLower, "material storage") then
        self.lastAction = "storage"
    elseif string.find(fLower, "deposit") then
        self.lastAction = "storage"
    end

    if string.find(fLower, "collector") or string.find(fLower, "noticeboard")
        or string.find(fLower, "journal") or string.find(fLower, "collection")
        or string.find(vLower, "collector") or string.find(fLower, "contribute")
        or string.find(vLower, "contribute") then
        self.scanTicksRemaining = 40
        self:syncCollectorBoard()
    end
end

-- Handles chat messages for Sign of the Porter / Grace of the Elves / Material Cart transfers to Material Storage
function Tracker:onChatMessage(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    local clean = string.gsub(text, "<[^>]+>", "")
    local lower = string.lower(clean)

    -- Match porter / grace of the elves / material storage transport events:
    -- e.g. "Your sign of the porter transports the following item to your material storage: Third Age iron."
    -- "Your Grace of the elves transports the following item to your material storage: Cadmium red."
    if string.find(lower, "porter") or string.find(lower, "grace of the elves") or string.find(lower, "material storage") then
        local found = false
        for matName, matDef in pairs(Materials.ALL or {}) do
            local matLower = string.lower(matName)
            if string.find(lower, matLower, 1, true) then
                local qty = 1
                local qMatch = string.match(clean, "(%d+)%s*[xX]%s*" .. matName)
                    or string.match(clean, matName .. "%s*[xX]%s*(%d+)")
                    or string.match(clean, "(%d+)%s+" .. matName)
                if qMatch and tonumber(qMatch) and tonumber(qMatch) > 0 and tonumber(qMatch) <= 100 then
                    qty = tonumber(qMatch)
                end

                self.storageMaterials[matDef.name] = (self.storageMaterials[matDef.name] or 0) + qty
                found = true
            end
        end

        if found then
            safeDbSet("arch_storage_materials", serializeCountMap(self.storageMaterials))
            self:recalculate()
            return true
        end
    end

    -- Match collector artefact submission / contribution events:
    -- e.g. "You hand over the <artefact> to <collector>."
    if string.find(lower, "hand over") or string.find(lower, "contribute") or string.find(lower, "give") or string.find(lower, "donat") then
        local foundArt = false
        for artName, _ in pairs(Artefacts.ALL or {}) do
            local artLower = string.lower(artName)
            if string.find(lower, artLower, 1, true) then
                for _, col in ipairs(Collections.LIST or {}) do
                    if col.artefacts then
                        for _, cArt in ipairs(col.artefacts) do
                            if cArt == artName then
                                self.submittedArtefacts[col.name] = self.submittedArtefacts[col.name] or {}
                                self.submittedArtefacts[col.name][artName] = true
                                foundArt = true
                            end
                        end
                    end
                end
            end
        end
        if foundArt then
            self.boardSyncedLive = true
            self.boardHasCache = true
            safeDbSet("arch_submitted_artefacts", serializeSubmittedMap(self.submittedArtefacts))
            self:recalculate()
            return true
        end
    end
    return false
end

function Tracker:getOwnedMaterialCount(matName, mode)
    mode = mode or self:getSourceMode()
    local owned = 0
    if mode.useBag then owned = owned + (self.backpackMaterials[matName] or 0) end
    if mode.useStorage then owned = owned + (self.storageMaterials[matName] or 0) end
    if mode.useBank then owned = owned + (self.bankMaterials[matName] or 0) end
    return owned
end

-- Recalculates damaged artefacts (across Backpack & Bank), material requirements, owned counts, and deficits
function Tracker:recalculate(triggerInvType)
    self:scanAllInventories(triggerInvType)

    local mode = self:getSourceMode()

    local combinedArts = {}
    if self.isPinned then
        for damagedName, pinnedCount in pairs(self.pinnedArtefactCounts or {}) do
            if pinnedCount and pinnedCount > 0 then
                combinedArts[damagedName] = {
                    inBag = self.backpackArtefacts[damagedName] or 0,
                    inBank = self.bankArtefacts[damagedName] or 0,
                    rawCount = pinnedCount
                }
            end
        end
    else
        for damagedName, bagCount in pairs(self.backpackArtefacts or {}) do
            if bagCount and bagCount > 0 then
                combinedArts[damagedName] = {
                    inBag = bagCount,
                    inBank = 0,
                    rawCount = bagCount
                }
            end
        end
        for damagedName, bankCount in pairs(self.bankArtefacts or {}) do
            if bankCount and bankCount > 0 then
                local entry = combinedArts[damagedName]
                if entry then
                    entry.inBank = bankCount
                    entry.rawCount = entry.inBag + bankCount
                else
                    combinedArts[damagedName] = {
                        inBag = 0,
                        inBank = bankCount,
                        rawCount = bankCount
                    }
                end
            end
        end
    end

    -- Merge any targeted collections requirements into combinedArts
    local colTargets = self:getTargetedArtefactRequirements()
    for damagedName, targetInfo in pairs(colTargets) do
        local entry = combinedArts[damagedName]
        if entry then
            entry.colTarget = targetInfo.count
            entry.colNames = targetInfo.collections
            entry.ownedRestored = targetInfo.ownedRestored
            entry.neededToRestore = targetInfo.neededToRestore
            if targetInfo.neededToRestore > (entry.rawCount or 0) then
                entry.rawCount = targetInfo.neededToRestore
            end
        else
            combinedArts[damagedName] = {
                inBag = self.backpackArtefacts[damagedName] or 0,
                inBank = self.bankArtefacts[damagedName] or 0,
                rawCount = targetInfo.neededToRestore,
                colTarget = targetInfo.count,
                colNames = targetInfo.collections,
                ownedRestored = targetInfo.ownedRestored,
                neededToRestore = targetInfo.neededToRestore
            }
        end
    end

    local artefactsList = {}
    local requiredByMat = {}
    local totalArtefacts = 0
    local uniqueArtefacts = 0
    local totalXp = 0
    local totalChronotes = 0

    for damagedName, info in pairs(combinedArts) do
        local rawCount = info.rawCount or 0
        local minTarget = (info.neededToRestore and info.neededToRestore > 0) and info.neededToRestore or 0

        -- Apply Artefact Source Filter (All / Tracked / Owned)
        local keep = true
        if self.artefactFilter == "TARGETED" then
            keep = (info.colTarget and info.colTarget > 0)
        elseif self.artefactFilter == "OWNED" then
            keep = ((info.inBag or 0) + (info.inBank or 0)) > 0
        end

        if keep and (rawCount > 0 or minTarget > 0) then
            local art = Artefacts.findByName(damagedName)
            if art then
                uniqueArtefacts = uniqueArtefacts + 1
                local isExcluded = (self.excludedArtefacts[art.damagedName] ~= nil)
                local defaultQty
                if minTarget > 0 then
                    defaultQty = minTarget
                elseif self.includeMode == "ZERO" then
                    defaultQty = 0
                elseif self.includeMode == "ONE" or not self.includeDuplicates then
                    defaultQty = 1
                else
                    defaultQty = math.max(1, rawCount)
                end
                local targetCount = self.customArtefactCounts[art.damagedName] or defaultQty
                local effectiveCount = isExcluded and 0 or targetCount

                totalArtefacts = totalArtefacts + effectiveCount
                totalXp = totalXp + (art.xp * effectiveCount)
                totalChronotes = totalChronotes + (art.chronotes * effectiveCount)

                -- Check how many of this specific artefact could be repaired right now
                -- (Bounded by owned damaged artefacts: you cannot repair an artefact you don't own!)
                local ownedDamaged = (info.inBag or 0) + (info.inBank or 0)
                local matPossibleNow = 999999
                local missingMatTypes = 0
                for _, req in ipairs(art.materials) do
                    if effectiveCount > 0 then
                        requiredByMat[req.name] = (requiredByMat[req.name] or 0) + (req.count * effectiveCount)
                    end
                    local ownedMat = self:getOwnedMaterialCount(req.name, mode)
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
                    artefact = art,
                    inBag = info.inBag or 0,
                    inBank = info.inBank or 0,
                    ownedDamaged = ownedDamaged,
                    rawCount = rawCount,
                    targetCount = targetCount,
                    effectiveCount = effectiveCount,
                    excluded = isExcluded,
                    maxPossibleNow = maxPossibleNow,
                    matPossibleNow = matPossibleNow,
                    missingMatTypes = missingMatTypes,
                    colTarget = info.colTarget or 0,
                    colNames = info.colNames,
                    ownedRestored = info.ownedRestored or 0,
                    neededToRestore = info.neededToRestore or 0
                })
            end
        end
    end

    -- Sort artefacts by level then order
    table.sort(artefactsList, function(a, b)
        if a.artefact.level ~= b.artefact.level then
            return a.artefact.level < b.artefact.level
        end
        return (a.artefact.order or 0) < (b.artefact.order or 0)
    end)

    -- Build material rows
    local materialsList = {}
    local filteredMaterials = {}
    local distinctMaterialsRequired = 0
    local distinctMaterialsShort = 0
    local totalMaterialsShort = 0

    for matName, reqCount in pairs(requiredByMat) do
        if reqCount > 0 then
            distinctMaterialsRequired = distinctMaterialsRequired + 1
            local matDef = Materials.get(matName) or {
                name = matName,
                level = 1,
                culture = "Other",
                isArchMaterial = false,
                caches = {},
                order = 999
            }

            local inBag = self.backpackMaterials[matName] or 0
            local inStorage = self.storageMaterials[matName] or 0
            local inBank = self.bankMaterials[matName] or 0
            local owned = self:getOwnedMaterialCount(matName, mode)

            local short = math.max(0, reqCount - owned)
            local surplus = math.max(0, owned - reqCount)
            if short > 0 then
                distinctMaterialsShort = distinctMaterialsShort + 1
                totalMaterialsShort = totalMaterialsShort + short
            end

            local row = {
                name = matName,
                material = matDef,
                required = reqCount,
                owned = owned,
                ownedBag = inBag,
                ownedStorage = inStorage,
                ownedBank = inBank,
                short = short,
                surplus = surplus,
                isReady = (short == 0)
            }

            table.insert(materialsList, row)
            if not self.shortOnly or short > 0 then
                table.insert(filteredMaterials, row)
            end
        end
    end

    -- Sort materials: missing materials first (lowest level), then ready materials
    local function sortMats(a, b)
        if a.isReady ~= b.isReady then
            return not a.isReady -- short items at the top
        end
        if a.material.level ~= b.material.level then
            return a.material.level < b.material.level
        end
        return a.name < b.name
    end

    table.sort(materialsList, sortMats)
    table.sort(filteredMaterials, sortMats)

    -- Calculate how many individual artefacts can be immediately restored sequentially with current owned pool
    local pool = {}
    for _, row in ipairs(materialsList) do
        pool[row.name] = row.owned
    end

    local restorableArtefacts = 0
    for _, item in ipairs(artefactsList) do
        if not item.excluded and item.effectiveCount > 0 then
            local canMake = 0
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

    self.lastResult = {
        artefacts = artefactsList,
        materials = materialsList,
        filteredMaterials = filteredMaterials,
        totalArtefacts = totalArtefacts,
        uniqueArtefacts = uniqueArtefacts,
        restorableArtefacts = restorableArtefacts,
        totalXp = totalXp,
        totalChronotes = totalChronotes,
        distinctMaterialsRequired = distinctMaterialsRequired,
        distinctMaterialsShort = distinctMaterialsShort,
        totalMaterialsShort = totalMaterialsShort
    }

    return self.lastResult
end

return Tracker
