-- tracker.lua
-- Core state, inventory scanning, material source resolution, duplicate filtering,
-- and pinned target tracking for the Archaeology Assistant plugin.

local Materials = require("data/materials")
local Artefacts = require("data/artefacts")

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

function Tracker.new()
    local self = setmetatable({}, Tracker)

    -- All three filter/source toggles default to "All" (Src: All, Dupes: All, Show: All)
    self.sourceModeIndex = 1
    self.includeDuplicates = true
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

    -- Cached material counts by canonical material name
    self.backpackMaterials = {}
    self.storageMaterials = deserializeCountMap(safeDbGet("arch_storage_materials", ""))
    self.bankMaterials = deserializeCountMap(safeDbGet("arch_bank_materials", ""))

    local storEntries = countMapEntries(self.storageMaterials)
    local bankEntries = countMapEntries(self.bankMaterials) + countMapEntries(self.bankArtefacts)

    self.storageIconObjId = 49429
    self.bankIconObjId = 995
    self.storageSyncedLive = false
    self.bankSyncedLive = false
    self.storageHasCache = (safeDbGet("arch_storage_synced", 0) == 1) or (storEntries > 0)
    self.bankHasCache = (safeDbGet("arch_bank_synced", 0) == 1) or (bankEntries > 0)
    self.storageInvId = tonumber(safeDbGet("arch_storage_inv_id", -1)) or -1
    self.bankInvId = tonumber(safeDbGet("arch_bank_inv_id", -1)) or -1

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

    return self
end

function Tracker:getSourceMode()
    return Tracker.SOURCE_MODES[self.sourceModeIndex] or Tracker.SOURCE_MODES[1]
end

-- Returns structured sync status for Material Storage and Bank icon badges/tooltips
function Tracker:getSyncStatus()
    local mode = self:getSourceMode()
    local storEntries = countMapEntries(self.storageMaterials)
    local bankMatEntries = countMapEntries(self.bankMaterials)
    local bankArtEntries = countMapEntries(self.bankArtefacts)

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

function Tracker:toggleDuplicates()
    if self:hasCustomCounts() then
        -- Reset any per-artefact +/- overrides back to clean All mode
        self.customArtefactCounts = {}
        self.includeDuplicates = true
    else
        self.includeDuplicates = not self.includeDuplicates
        self.customArtefactCounts = {}
    end
    safeDbSet("arch_include_dupes", self.includeDuplicates and 1 or 0)
    safeDbSet("arch_custom_art_counts", "")
    return self:recalculate()
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
    local defaultQty = self.includeDuplicates and math.max(1, tonumber(rawCount) or 1) or 1
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

function Tracker:savePersistentState()
    safeDbSet("arch_source_mode_idx", self.sourceModeIndex)
    safeDbSet("arch_include_dupes", self.includeDuplicates and 1 or 0)
    safeDbSet("arch_short_only", self.shortOnly and 1 or 0)
    safeDbSet("arch_is_pinned", self.isPinned and 1 or 0)
    safeDbSet("arch_pinned_artefacts", serializeCountMap(self.pinnedArtefactCounts))
    safeDbSet("arch_excluded_artefacts", serializeCountMap(self.excludedArtefacts))
    safeDbSet("arch_custom_art_counts", serializeCountMap(self.customArtefactCounts))
    safeDbSet("arch_bank_artefacts", serializeCountMap(self.bankArtefacts))
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
--   artCounts ({ [damagedArtefactName] = totalCount })
function Tracker:extractMaterialsFromInv(inv)
    local matCounts = {}
    local artCounts = {}
    local archMatKinds = 0
    local nonMatSlots = 0
    local firstArchObjId = nil

    local slots = getInventorySlots(inv)
    for _, slot in ipairs(slots) do
        local obj, count, rawName = getSlotItemInfo(slot)
        if rawName and count > 0 then
            local mat = Materials.get(rawName)
            if mat then
                matCounts[mat.name] = (matCounts[mat.name] or 0) + count
                if mat.isArchMaterial then
                    archMatKinds = archMatKinds + 1
                    if not firstArchObjId and obj then
                        local okId, idVal = pcall(function() return obj.id or (obj.type and obj.type.id) end)
                        if okId and tonumber(idVal) and tonumber(idVal) > 0 then
                            firstArchObjId = tonumber(idVal)
                        end
                    end
                end
            else
                nonMatSlots = nonMatSlots + 1
                local art = Artefacts.findByName(rawName)
                if art then
                    artCounts[art.damagedName] = (artCounts[art.damagedName] or 0) + count
                end
            end
        end
    end

    return matCounts, archMatKinds, nonMatSlots, artCounts, firstArchObjId
end

-- Scans the player's Backpack, Bank, and any known/candidate Material Storage containers
function Tracker:scanAllInventories(triggerInvType)
    if not config or not config.Inv then
        return
    end

    -- 1. Always scan Backpack (config.Inv.INV) for both materials and damaged artefacts
    local bagInv = findInventory(config.Inv.INV)
    if bagInv then
        local bagMats, _, _, bagArts = self:extractMaterialsFromInv(bagInv)
        self.backpackMaterials = bagMats
        self.backpackArtefacts = bagArts
    end

    -- 2. Check Bank (config.Inv.BANK or bankInvId) if available for both materials and damaged artefacts
    local checkedBank = false
    if config.Inv.BANK then
        local bankInv = findInventory(config.Inv.BANK)
        if bankInv then
            local bankMats, archKinds, nonMatSlots, bankArts = self:extractMaterialsFromInv(bankInv)
            local triggeredByBank = (triggerInvType ~= nil and triggerInvType == config.Inv.BANK)
            if triggeredByBank or archKinds > 0 or nonMatSlots > 0 then
                self.bankMaterials = bankMats
                self.bankArtefacts = bankArts
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
            end
        end
    end

    if not checkedBank and self.bankInvId and self.bankInvId >= 0 then
        local bankInv = findInventory(self.bankInvId)
        if bankInv then
            local bankMats, archKinds, nonMatSlots, bankArts = self:extractMaterialsFromInv(bankInv)
            if archKinds > 0 or nonMatSlots > 0 then
                self.bankMaterials = bankMats
                self.bankArtefacts = bankArts
                self.bankSyncedLive = true
                safeDbSet("arch_bank_synced", 1)
                safeDbSet("arch_bank_materials", serializeCountMap(self.bankMaterials))
                safeDbSet("arch_bank_artefacts", serializeCountMap(self.bankArtefacts))
            end
        end
    end

    -- 3. Check candidate Material Storage Inv names or previously discovered storageInvId
    local candidateKeys = {
        "ARCHAEOLOGY_MATERIAL_STORAGE",
        "MATERIAL_STORAGE",
        "ARCH_MATERIAL_STORAGE",
        "ARCHAEOLOGY_MATERIALS",
        "ARCHAEOLOGY_STORAGE",
        "MAT_STORAGE"
    }

    local checkedStorage = false
    for _, key in ipairs(candidateKeys) do
        local okRef, ref = pcall(function() return config.Inv[key] end)
        if okRef and ref then
            local storInv = findInventory(ref)
            if storInv then
                local storMats, archKinds, _, _, firstObjId = self:extractMaterialsFromInv(storInv)
                local triggeredByStor = (triggerInvType ~= nil and triggerInvType == ref)
                if triggeredByStor or archKinds > 0 then
                    self.storageMaterials = storMats
                    if firstObjId then self.storageIconObjId = firstObjId end
                    self.storageSyncedLive = true
                    checkedStorage = true
                    safeDbSet("arch_storage_synced", 1)
                    safeDbSet("arch_storage_materials", serializeCountMap(self.storageMaterials))
                    break
                end
            end
        end
    end

    if not checkedStorage and self.storageInvId and self.storageInvId >= 0 then
        local storInv = findInventory(self.storageInvId)
        if storInv then
            local storMats, archKinds, _, _, firstObjId = self:extractMaterialsFromInv(storInv)
            if archKinds > 0 then
                self.storageMaterials = storMats
                if firstObjId then self.storageIconObjId = firstObjId end
                self.storageSyncedLive = true
                checkedStorage = true
                safeDbSet("arch_storage_synced", 1)
                safeDbSet("arch_storage_materials", serializeCountMap(self.storageMaterials))
            end
        end
    end

    -- 4. If an event fired with a specific event.inv that is neither INV nor BANK,
    --    inspect it to see if it is the Archaeology Material Storage container!
    if triggerInvType then
        local isBag = (config.Inv.INV and triggerInvType == config.Inv.INV)
        local isBank = (config.Inv.BANK and triggerInvType == config.Inv.BANK)
        local isWorn = (config.Inv.WORN and triggerInvType == config.Inv.WORN)
        if not isBag and not isBank and not isWorn then
            local customInv = findInventory(triggerInvType)
            if customInv then
                local mats, archKinds, nonMatSlots, _, firstObjId = self:extractMaterialsFromInv(customInv)
                -- Material Storage holds exclusively Archaeology materials
                if archKinds >= 1 and nonMatSlots == 0 then
                    self.storageMaterials = mats
                    if firstObjId then self.storageIconObjId = firstObjId end
                    self.storageSyncedLive = true
                    local okId, invId = pcall(function() return triggerInvType.id end)
                    if okId and type(invId) == "number" then
                        self.storageInvId = invId
                        safeDbSet("arch_storage_inv_id", invId)
                    end
                    safeDbSet("arch_storage_synced", 1)
                    safeDbSet("arch_storage_materials", serializeCountMap(self.storageMaterials))
                end
            end
        end
    end
end

-- Handles chat messages for Sign of the Porter / Material Cart transfers to Material Storage
function Tracker:onChatMessage(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    local clean = string.gsub(text, "<[^>]+>", "")
    -- Match Sign of the Porter transporting an item to material storage:
    -- e.g. "Your sign of the porter transports the following item to your material storage: Third Age iron."
    local transported = string.match(clean, "material storage:%s*([^%.!]+)")
    if transported then
        local mat = Materials.get(transported)
        if mat then
            self.storageMaterials[mat.name] = (self.storageMaterials[mat.name] or 0) + 1
            safeDbSet("arch_storage_materials", serializeCountMap(self.storageMaterials))
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
    local includeBankArts = (mode.id ~= "BAG_ONLY")

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
        if includeBankArts then
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
    end

    local artefactsList = {}
    local requiredByMat = {}
    local totalArtefacts = 0
    local uniqueArtefacts = 0
    local totalXp = 0
    local totalChronotes = 0

    for damagedName, info in pairs(combinedArts) do
        local rawCount = info.rawCount or 0
        if rawCount > 0 then
            local art = Artefacts.findByName(damagedName)
            if art then
                uniqueArtefacts = uniqueArtefacts + 1
                local isExcluded = (self.excludedArtefacts[art.damagedName] ~= nil)
                local defaultQty = self.includeDuplicates and rawCount or 1
                local targetCount = self.customArtefactCounts[art.damagedName] or defaultQty
                local effectiveCount = isExcluded and 0 or targetCount

                totalArtefacts = totalArtefacts + effectiveCount
                totalXp = totalXp + (art.xp * effectiveCount)
                totalChronotes = totalChronotes + (art.chronotes * effectiveCount)

                -- Check how many of this specific artefact could be repaired right now
                local maxPossibleNow = 999999
                local missingMatTypes = 0
                for _, req in ipairs(art.materials) do
                    if effectiveCount > 0 then
                        requiredByMat[req.name] = (requiredByMat[req.name] or 0) + (req.count * effectiveCount)
                    end
                    local ownedMat = self:getOwnedMaterialCount(req.name, mode)
                    local copiesForMat = (req.count > 0) and math.floor(ownedMat / req.count) or 999999
                    if copiesForMat < maxPossibleNow then
                        maxPossibleNow = copiesForMat
                    end
                    if ownedMat < req.count then
                        missingMatTypes = missingMatTypes + 1
                    end
                end
                if maxPossibleNow == 999999 then maxPossibleNow = 0 end

                table.insert(artefactsList, {
                    artefact = art,
                    inBag = info.inBag or 0,
                    inBank = info.inBank or 0,
                    rawCount = rawCount,
                    targetCount = targetCount,
                    effectiveCount = effectiveCount,
                    excluded = isExcluded,
                    maxPossibleNow = maxPossibleNow,
                    missingMatTypes = missingMatTypes
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
            for _ = 1, item.effectiveCount do
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
