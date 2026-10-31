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
    local hadBackpackDelta = false
    for artName, countRestored in pairs(artsRestored) do
        hadBackpackDelta = true
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
            hadBackpackDelta = true
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

    if hadBackpackDelta then
        tracker.lastAction = nil
    end
end

--- Scans the Bank inventory if open/available and updates cached bank counts.
local function scanBankContainer(tracker, triggerInvType)
    local checkedBank = false
    local bankInv = nil
    local triggeredByBank = (triggerInvType ~= nil and config.Inv.BANK and triggerInvType == config.Inv.BANK)
        or (tracker.lastAction == "bank")

    if tracker.cacheCleared and not triggeredByBank then
        if config.Inv.BANK then
            bankInv = InventoryScanner.findInventory(config.Inv.BANK)
        end
        return false, bankInv
    end

    if config.Inv.BANK then
        bankInv = InventoryScanner.findInventory(config.Inv.BANK)
        if bankInv then
            local bankMats, archKinds, nonMatSlots, bankArts, bankRestored = tracker:extractMaterialsFromInv(bankInv)
            if triggeredByBank or archKinds > 0 or nonMatSlots > 0 then
                tracker.bankMaterials = bankMats
                tracker.bankArtefacts = bankArts
                tracker.bankRestored = bankRestored or {}
                tracker.bankSyncedLive = true
                tracker.cacheCleared = false
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
        return false
    end
    local isBag = (config.Inv.INV and triggerInvType == config.Inv.INV)
    local isBank = (config.Inv.BANK and triggerInvType == config.Inv.BANK)
    local isWorn = (config.Inv.WORN and triggerInvType == config.Inv.WORN)
    if isBag or isBank or isWorn then
        return false
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
        return false
    end

    local customInv = InventoryScanner.findInventory(triggerInvType)
    if not customInv or customInv == bagInv or customInv == bankInv then
        return false
    end

    local mats, archKinds, nonMatSlots, _, _, totalSlots = tracker:extractMaterialsFromInv(customInv)
    local isInspect = (totalSlots > 0 and totalSlots < 15)
        or InventoryScanner.isArtefactRecipeContainer(mats, archKinds)

    local isStorageAction = (tracker.lastAction == "storage") or ((tracker.storageActionTicks or 0) > 0)
    local isStorage = (isStorageAction or (totalSlots >= 29 and archKinds >= 1) or (totalSlots >= 20 and archKinds >= 4))
        and (archKinds >= 1 or (isStorageAction and totalSlots >= 25))
        and totalSlots <= 90
        and nonMatSlots == 0
        and not isInspect

    local currentStorCount = InventoryScanner.countMapEntries(tracker.storageMaterials)
    if isStorage and (isStorageAction or archKinds >= math.min(5, currentStorCount)) then
        tracker.storageMaterials = mats
        tracker.storageSyncedLive = true
        tracker.storageHasCache = true
        tracker.lastAction = nil
        tracker.storageActionTicks = 0
        tracker.pendingJournalStorageScan = false
        local okId, invId = pcall(function() return triggerInvType.id end)
        if okId and type(invId) == "number" and invId >= 0 then
            tracker.storageInvId = invId
            tracker._knownStorageInvId = invId
            DB.set("arch_storage_inv_id", invId)
        end
        DB.set("arch_storage_synced", 1)
        DB.set("arch_storage_materials", DB.serializeCountMap(tracker.storageMaterials))
        return true
    end
    return false
end

--- Scans known or in-memory Material Storage containers (e.g. when opened via Archaeology Journal's read-only view).
local function scanKnownOrMemoryStorageContainer(tracker, bagInv, bankInv)
    local wornInv = config and config.Inv and config.Inv.WORN and InventoryScanner.findInventory(config.Inv.WORN) or nil

    local function tryApplyStorageInv(inv, candidateId)
        if not inv or inv == bagInv or inv == bankInv or inv == wornInv then
            return false
        end
        local mats, archKinds, nonMatSlots, _, _, totalSlots = tracker:extractMaterialsFromInv(inv)
        local isInspect = (totalSlots > 0 and totalSlots < 15)
            or InventoryScanner.isArtefactRecipeContainer(mats, archKinds)
        if isInspect or nonMatSlots > 0 or totalSlots < 25 or totalSlots > 90 then
            return false
        end
        local isStorageAction = (tracker.lastAction == "storage") or ((tracker.storageActionTicks or 0) > 0) or tracker.pendingJournalStorageScan
        if archKinds >= 1 or isStorageAction then
            local currentStorCount = InventoryScanner.countMapEntries(tracker.storageMaterials)
            if isStorageAction or archKinds >= math.min(5, currentStorCount) then
                tracker.storageMaterials = mats
                tracker.storageSyncedLive = true
                tracker.storageHasCache = true
                tracker.pendingJournalStorageScan = false
                if type(candidateId) == "number" and candidateId >= 0 then
                    tracker.storageInvId = candidateId
                    tracker._knownStorageInvId = candidateId
                    DB.set("arch_storage_inv_id", candidateId)
                end
                DB.set("arch_storage_synced", 1)
                DB.set("arch_storage_materials", DB.serializeCountMap(tracker.storageMaterials))
                return true
            end
        end
        return false
    end

    -- 1. Check known storageInvId or in-memory _knownStorageInvId if already discovered
    local knownId = (tracker.storageInvId and tracker.storageInvId >= 0 and tracker.storageInvId)
        or (tracker._knownStorageInvId and tracker._knownStorageInvId >= 0 and tracker._knownStorageInvId)
    if knownId and knownId ~= tracker.bankInvId then
        local storInv = InventoryScanner.findInventory(knownId)
        if tryApplyStorageInv(storInv, knownId) then
            return true
        end
    end

    -- 2. Check candidate config.Inv keys
    local candidateKeys = {
        "ARCHAEOLOGY_MATERIAL_STORAGE",
        "MATERIAL_STORAGE",
        "ARCH_MATERIAL_STORAGE",
        "ARCH_STORAGE",
        "MAT_STORAGE"
    }
    for _, key in ipairs(candidateKeys) do
        local okRef, ref = pcall(function() return config.Inv[key] end)
        if okRef and ref then
            local storInv = InventoryScanner.findInventory(ref)
            local okId, refId = pcall(function() return ref.id end)
            if tryApplyStorageInv(storInv, okId and refId or nil) then
                return true
            end
        end
    end

    -- 3. If user clicked Archaeology Journal -> Material storage information,
    -- probe loaded client inventories for the 30-50 slot Archaeology Material Storage container.
    if tracker.pendingJournalStorageScan then
        local bagId  = (config.Inv.INV and config.Inv.INV.id) or 93
        local wornId = (config.Inv.WORN and config.Inv.WORN.id) or 94
        local bankId = (config.Inv.BANK and config.Inv.BANK.id) or 95
        for invId = 1, 950 do
            if invId ~= bagId and invId ~= wornId and invId ~= bankId and invId ~= tracker.bankInvId then
                local inv = InventoryScanner.findInventory(invId)
                if inv and tryApplyStorageInv(inv, invId) then
                    return true
                end
            end
        end
    end

    -- 4. Fallback: check Archaeology UI interfaces (650..670) in case the journal view renders via UI components.
    if tracker.pendingJournalStorageScan then
        if InventoryScanner.scanMaterialStorageInterface(tracker) then
            return true
        end
    end

    return false
end

--- Scans open UI interfaces for the Archaeology Journal's "Material storage information" view.
function InventoryScanner.scanMaterialStorageInterface(tracker)
    if not ui or not ui.Interfaces then return false end

    local function getCompText(c)
        if not c then return nil end
        local t = nil
        pcall(function()
            t = c.content or c.text or (c.GetText and c:GetText()) or c.textFormatted or c.rawText
        end)
        if t and type(t) ~= "string" then t = tostring(t) end
        return t
    end

    local function extractChild(a, b)
        if type(a) == "table" or type(a) == "userdata" then return a end
        if type(b) == "table" or type(b) == "userdata" then return b end
        return nil
    end

    local function parsePureCount(rawTxt)
        if not rawTxt or type(rawTxt) ~= "string" then return nil end
        local clean = string.gsub(rawTxt, "<[^>]+>", "")
        clean = string.match(clean, "^%s*([%d,]+)%s*$")
        if clean then
            local num = tonumber((string.gsub(clean, ",", "")))
            if num and num >= 0 and num <= 10000000 then
                return num
            end
        end
        return nil
    end

    local function scanInterfaceId(ifId)
        if ifId == 657 or ifId == 1477 then return false end
        local okIf, iface = pcall(function() return ui.Interfaces:GetInterface(ifId) end)
        if not okIf or not iface then return false end

        local queue = {}
        for rootIdx = 0, 4 do
            local okC, c = pcall(function() return ui.Interfaces:GetComponent(ifId, rootIdx) end)
            if okC and c then
                table.insert(queue, { comp = c, depth = 1 })
            end
        end
        if #queue == 0 then return false end

        local hasStorageTitle = false
        local seenArchMats = {}
        local distinctArchMats = 0
        local matCounts = {}
        local lastMatchedMat = nil
        local qHead = 1

        while qHead <= #queue and qHead < 300 do
            local node = queue[qHead]
            qHead = qHead + 1
            local comp = node.comp
            local depth = node.depth

            local rawTxt = getCompText(comp)
            if rawTxt and rawTxt ~= "" then
                local low = string.lower(rawTxt)
                if string.find(low, "material storage", 1, true) then
                    hasStorageTitle = true
                end
            end

            local objId = nil
            pcall(function() objId = comp.associatedObjectID or comp.objId or comp.itemId or comp.itemID end)
            local propCount = nil
            pcall(function()
                propCount = comp.associatedObjectCount or comp.associatedObjectAmount
                    or comp.itemCount or comp.itemAmount or comp.count or comp.quantity or comp.amount
            end)

            local mat = (objId and objId > 0 and Materials.getById(objId))
                or (rawTxt and #rawTxt >= 4 and Materials.get(rawTxt))

            if mat and mat.isArchMaterial then
                if not seenArchMats[mat.name] then
                    seenArchMats[mat.name] = true
                    distinctArchMats = distinctArchMats + 1
                end
                lastMatchedMat = mat.name

                local resolvedCount = nil
                if type(propCount) == "number" and propCount >= 0 then
                    resolvedCount = propCount
                end
                if resolvedCount == nil and rawTxt then
                    resolvedCount = parsePureCount(rawTxt)
                end

                if resolvedCount == nil and comp.parent then
                    local function checkSibling(a, b)
                        local sib = extractChild(a, b)
                        if sib and sib ~= comp and resolvedCount == nil then
                            local sCount = parsePureCount(getCompText(sib))
                            if sCount ~= nil then
                                resolvedCount = sCount
                            end
                        end
                        return false
                    end
                    if comp.parent.IterateStaticComponents then
                        pcall(comp.parent.IterateStaticComponents, comp.parent, checkSibling)
                    end
                    if comp.parent.IterateDynamicComponents then
                        pcall(comp.parent.IterateDynamicComponents, comp.parent, checkSibling)
                    end
                end

                if resolvedCount and resolvedCount > 0 then
                    matCounts[mat.name] = resolvedCount
                end
            elseif lastMatchedMat and rawTxt then
                local num = parsePureCount(rawTxt)
                if num ~= nil and matCounts[lastMatchedMat] == nil then
                    if num > 0 then
                        matCounts[lastMatchedMat] = num
                    end
                    lastMatchedMat = nil
                end
            end

            if depth < 12 then
                if comp.IterateStaticComponents then
                    pcall(comp.IterateStaticComponents, comp, function(a, b)
                        local child = extractChild(a, b)
                        if child then table.insert(queue, { comp = child, depth = depth + 1 }) end
                        return false
                    end)
                end
                if comp.IterateDynamicComponents then
                    pcall(comp.IterateDynamicComponents, comp, function(a, b)
                        local child = extractChild(a, b)
                        if child then table.insert(queue, { comp = child, depth = depth + 1 }) end
                        return false
                    end)
                end
            end
        end

        if distinctArchMats >= 15 or (hasStorageTitle and distinctArchMats >= 5) then
            tracker.storageMaterials = matCounts
            tracker.storageSyncedLive = true
            tracker.storageHasCache = true
            tracker.pendingJournalStorageScan = false
            tracker.storageActionTicks = 0
            DB.set("arch_storage_synced", 1)
            DB.set("arch_storage_materials", DB.serializeCountMap(tracker.storageMaterials))
            return true
        end
        return false
    end

    for ifId = 650, 670 do
        if scanInterfaceId(ifId) then return true end
    end
    return false
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

    -- 4. Check if triggerInvType is the Material Storage container, or scan known/in-memory storage when explicitly opened
    if triggerInvType then
        scanMaterialStorageTrigger(tracker, triggerInvType, bagInv, bankInv)
    elseif tracker.pendingJournalStorageScan then
        scanKnownOrMemoryStorageContainer(tracker, bagInv, bankInv)
    end
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
