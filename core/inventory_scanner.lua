-- core/inventory_scanner.lua
-- Single-responsibility module for scanning RS3 inventories (Backpack, Bank, Material Storage)
-- while isolating Area Loot and artefact restoration recipe preview containers.

local Materials = require("data/materials")
local Artefacts = require("data/artefacts")
local DB        = require("core/db")

local InventoryScanner = {}

--- Counts positive numeric entries in a { [key] = count } map.
function InventoryScanner.countMapEntries(map)
    if type(map) ~= "table" then return 0 end
    local n = 0
    for _, v in pairs(map) do
        if (tonumber(v) or 0) > 0 then
            n = n + 1
        end
    end
    return n
end

--- Safely retrieves an RS3 Inventory instance by InvRef or numeric ID.
function InventoryScanner.findInventory(invRef)
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

--- Safely extracts the slot array from an RS3 Inventory object.
function InventoryScanner.getInventorySlots(inv)
    if not inv then return {} end
    local ok, slots = pcall(function() return inv:GetSlots() end)
    if ok and type(slots) == "table" then
        return slots
    end
    return {}
end

--- Safely extracts item object, stack count, and item name from an RS3 InvSlot.
function InventoryScanner.getSlotItemInfo(slot)
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

--- Determines if a container's contents match an artefact restoration recipe preview.
--- Artefact inspection/restoration dialogs in RS3 hold <= 5 materials for the inspected artefact
--- and must never be mistaken for the player's Material Storage container.
function InventoryScanner.isArtefactRecipeContainer(matCounts, archKinds)
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

--- Scans an RS3 inventory in a single pass and returns:
---   matCounts, archMatKinds, nonMatSlots, artCounts, restoredCounts, totalSlots
function InventoryScanner.extractMaterialsFromInv(inv)
    local matCounts = {}
    local artCounts = {}
    local restoredCounts = {}
    local archMatKinds = 0
    local nonMatSlots = 0

    local slots = InventoryScanner.getInventorySlots(inv)
    local totalSlots = #slots

    for _, slot in ipairs(slots) do
        local _, count, rawName = InventoryScanner.getSlotItemInfo(slot)
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

--- Reconciles items leaving the backpack (restorations at a workbench vs deposits into Bank/Storage).
local function reconcileBackpackMaterialAndArtefactDeltas(tracker, bagMats, bagArts, bagRestored)
    if not tracker.prevBackpackMaterials then
        return
    end

    local artsRestored = {}
    for artName, prevArtCount in pairs(tracker.prevBackpackArtefacts or {}) do
        local currentArtCount = bagArts[artName] or 0
        if currentArtCount < prevArtCount then
            local diff = prevArtCount - currentArtCount
            local artDef = Artefacts.findByName(artName)
            local isActuallyRestored = false

            if artDef and artDef.name then
                local prevR = (tracker.prevBackpackRestored and tracker.prevBackpackRestored[artDef.name]) or 0
                local currR = (bagRestored and bagRestored[artDef.name]) or 0
                if currR > prevR then
                    isActuallyRestored = true
                end
            end
            if tracker.lastAction == "restore" then
                isActuallyRestored = true
            end

            if isActuallyRestored and tracker.lastAction ~= "drop" and tracker.lastAction ~= "bank" and tracker.lastAction ~= "loot" then
                artsRestored[artName] = diff
            elseif tracker.lastAction == "bank" then
                tracker.bankArtefacts[artName] = (tracker.bankArtefacts[artName] or 0) + diff
                DB.set("arch_bank_artefacts", DB.serializeCountMap(tracker.bankArtefacts))
            end
        end
    end

    local consumedMats = {}
    for artName, countRestored in pairs(artsRestored) do
        if tracker.isPinned and tracker.pinnedArtefactCounts and tracker.pinnedArtefactCounts[artName] then
            tracker.pinnedArtefactCounts[artName] = math.max(0, tracker.pinnedArtefactCounts[artName] - countRestored)
            if tracker.pinnedArtefactCounts[artName] == 0 then
                tracker.pinnedArtefactCounts[artName] = nil
            end
            DB.set("arch_pinned_artefacts", DB.serializeCountMap(tracker.pinnedArtefactCounts))
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

    -- Deduct materials consumed by restoring an artefact from Material Storage
    for matName, consumedCount in pairs(consumedMats) do
        local remainingToConsume = consumedCount
        local prevBag = tracker.prevBackpackMaterials[matName] or 0
        local currBag = bagMats[matName] or 0
        local bagLost = math.max(0, prevBag - currBag)
        local consumedFromBag = math.min(bagLost, remainingToConsume)
        remainingToConsume = remainingToConsume - consumedFromBag

        if remainingToConsume > 0 then
            local currentStor = tracker.storageMaterials[matName] or 0
            local storDeduct = math.min(currentStor, remainingToConsume)
            if storDeduct > 0 then
                tracker.storageMaterials[matName] = currentStor - storDeduct
                storageChanged = true
            end
        end
    end

    -- Credit deposited materials to Bank or Material Storage based on lastAction
    for matName, prevCount in pairs(tracker.prevBackpackMaterials) do
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

            if tracker.lastAction == "drop" or tracker.lastAction == "loot" then
                -- Dropping or area looting resources does not credit Bank or Storage
            elseif tracker.lastAction == "bank" then
                if depositedCount > 0 then
                    tracker.bankMaterials[matName] = (tracker.bankMaterials[matName] or 0) + depositedCount
                    bankChanged = true
                end
            elseif tracker.lastAction == "storage" then
                if depositedCount > 0 then
                    tracker.storageMaterials[matName] = (tracker.storageMaterials[matName] or 0) + depositedCount
                    storageChanged = true
                end
            end
        end
    end

    if storageChanged then
        DB.set("arch_storage_materials", DB.serializeCountMap(tracker.storageMaterials))
    end
    if bankChanged then
        DB.set("arch_bank_materials", DB.serializeCountMap(tracker.bankMaterials))
    end

    tracker.lastAction = nil
end

--- Scans the Bank inventory if open/available and updates cached bank counts.
local function scanBankContainer(tracker, triggerInvType)
    local checkedBank = false
    local bankInv = nil

    if config.Inv.BANK then
        bankInv = InventoryScanner.findInventory(config.Inv.BANK)
        if bankInv then
            local bankMats, archKinds, nonMatSlots, bankArts, bankRestored = tracker:extractMaterialsFromInv(bankInv)
            local triggeredByBank = (triggerInvType ~= nil and triggerInvType == config.Inv.BANK)
            if triggeredByBank or archKinds > 0 or nonMatSlots > 0 then
                tracker.bankMaterials = bankMats
                tracker.bankArtefacts = bankArts
                tracker.bankRestored = bankRestored or {}
                tracker.bankSyncedLive = true
                checkedBank = true
                local okId, invId = pcall(function() return config.Inv.BANK.id end)
                if okId and type(invId) == "number" then
                    tracker.bankInvId = invId
                    DB.set("arch_bank_inv_id", invId)
                end
                DB.set("arch_bank_synced", 1)
                DB.set("arch_bank_materials", DB.serializeCountMap(tracker.bankMaterials))
                DB.set("arch_bank_artefacts", DB.serializeCountMap(tracker.bankArtefacts))
                DB.set("arch_bank_restored", DB.serializeCountMap(tracker.bankRestored))
            end
        end
    end

    if not checkedBank and tracker.bankInvId and tracker.bankInvId >= 0 then
        local fallbackBankInv = InventoryScanner.findInventory(tracker.bankInvId)
        if fallbackBankInv then
            bankInv = fallbackBankInv
            local bankMats, archKinds, nonMatSlots, bankArts, bankRestored = tracker:extractMaterialsFromInv(fallbackBankInv)
            if archKinds > 0 or nonMatSlots > 0 then
                tracker.bankMaterials = bankMats
                tracker.bankArtefacts = bankArts
                tracker.bankRestored = bankRestored or {}
                tracker.bankSyncedLive = true
                checkedBank = true
                DB.set("arch_bank_synced", 1)
                DB.set("arch_bank_materials", DB.serializeCountMap(tracker.bankMaterials))
                DB.set("arch_bank_artefacts", DB.serializeCountMap(tracker.bankArtefacts))
                DB.set("arch_bank_restored", DB.serializeCountMap(tracker.bankRestored))
            end
        end
    end

    return checkedBank, bankInv
end

--- Checks if a triggered inventory event is the player's Material Storage container.
local function scanMaterialStorageTrigger(tracker, triggerInvType, bagInv, bankInv)
    if not triggerInvType then
        return
    end
    local isBag = (config.Inv.INV and triggerInvType == config.Inv.INV)
    local isBank = (config.Inv.BANK and triggerInvType == config.Inv.BANK)
    local isWorn = (config.Inv.WORN and triggerInvType == config.Inv.WORN)
    if isBag or isBank or isWorn then
        return
    end

    local cfgName = ""
    pcall(function()
        cfgName = string.upper(tostring(triggerInvType.configName or ""))
    end)
    local isLoot = string.find(cfgName, "LOOT")
        or string.find(cfgName, "AREA")
        or string.find(cfgName, "GROUND")
        or string.find(cfgName, "DROP")
        or tracker.lastAction == "loot"

    if isLoot then
        return
    end

    local customInv = InventoryScanner.findInventory(triggerInvType)
    if not customInv or customInv == bagInv or customInv == bankInv then
        return
    end

    local mats, archKinds, nonMatSlots, _, _, totalSlots = tracker:extractMaterialsFromInv(customInv)
    local isInspect = (totalSlots > 0 and totalSlots < 15)
        or InventoryScanner.isArtefactRecipeContainer(mats, archKinds)

    local isStorage = (tracker.lastAction == "storage" or (totalSlots >= 35 and archKinds >= 3))
        and archKinds >= 1
        and nonMatSlots == 0
        and not isInspect

    local currentStorCount = InventoryScanner.countMapEntries(tracker.storageMaterials)
    if isStorage and (tracker.lastAction == "storage" or archKinds >= math.min(5, currentStorCount)) then
        tracker.storageMaterials = mats
        tracker.storageSyncedLive = true
        tracker.storageHasCache = true
        DB.set("arch_storage_synced", 1)
        DB.set("arch_storage_materials", DB.serializeCountMap(tracker.storageMaterials))
    end
end

--- Scans the player's Backpack, Bank, and any triggered Material Storage container.
function InventoryScanner.scanAllInventories(tracker, triggerInvType)
    if not config or not config.Inv then
        return
    end

    -- 1. Scan Backpack (config.Inv.INV)
    local bagInv = InventoryScanner.findInventory(config.Inv.INV)
    local bagMats, bagArts, bagRestored
    if bagInv then
        bagMats, _, _, bagArts, bagRestored = tracker:extractMaterialsFromInv(bagInv)
        tracker.backpackRestored = bagRestored or {}
        reconcileBackpackMaterialAndArtefactDeltas(tracker, bagMats, bagArts, bagRestored)
    end

    -- 2. Scan Bank (config.Inv.BANK or bankInvId)
    local checkedBank, bankInv = scanBankContainer(tracker, triggerInvType)

    -- 3. Track restored artefacts leaving the backpack to hand in to collectors
    if bagInv then
        if tracker.prevBackpackRestored then
            for artName, prevCount in pairs(tracker.prevBackpackRestored) do
                local curCount = (bagRestored and bagRestored[artName]) or 0
                if curCount < prevCount then
                    local countHandedIn = prevCount - curCount
                    if not checkedBank and tracker.lastAction ~= "drop" then
                        tracker:onRestoredArtefactSubmitted(artName, countHandedIn)
                    end
                end
            end
        end

        tracker.backpackMaterials = bagMats
        tracker.backpackArtefacts = bagArts
        tracker.backpackRestored = bagRestored or {}
        tracker.prevBackpackMaterials = bagMats
        tracker.prevBackpackArtefacts = bagArts
        tracker.prevBackpackRestored = bagRestored or {}
    end

    -- 4. Check if triggerInvType is the Material Storage container
    scanMaterialStorageTrigger(tracker, triggerInvType, bagInv, bankInv)
end

--- Checks if two count maps differ.
local function countMapsDiffer(mapA, mapB)
    if mapA then
        for k, v in pairs(mapA) do
            if ((mapB and mapB[k]) or 0) ~= v then
                return true
            end
        end
        for k, v in pairs(mapB or {}) do
            if (mapA[k] or 0) ~= v then
                return true
            end
        end
        return false
    end
    return next(mapB or {}) ~= nil
end

--- Lightweight periodic check for whether backpack contents changed since the last scan.
function InventoryScanner.checkBackpackChanged(tracker)
    if not config or not config.Inv or not config.Inv.INV then
        return false
    end
    local bagInv = InventoryScanner.findInventory(config.Inv.INV)
    if not bagInv then
        return false
    end

    local bagMats, _, _, bagArts, bagRestored = tracker:extractMaterialsFromInv(bagInv)
    local changed = countMapsDiffer(tracker.backpackArtefacts, bagArts)
        or countMapsDiffer(tracker.backpackRestored, bagRestored)
        or countMapsDiffer(tracker.backpackMaterials, bagMats)

    if changed then
        tracker:recalculate(config.Inv.INV)
        return true
    end
    return false
end

return InventoryScanner
