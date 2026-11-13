-- core/noticeboard_scanner.lua
-- Single-responsibility module for syncing collector completion and turned-in artefact status
-- via RS3's VarPlayer.COLLECTION_* and config.Achievement APIs.

local Collections      = require("data/collections")
local DB               = require("core/db")
local InventoryScanner = require("core/inventory_scanner")

local NoticeboardScanner = {}

--- Returns true if the Collector Information Noticeboard (id.Interface.COLLECTOR_BOARD) is currently open.
function NoticeboardScanner.isNoticeboardOpen()
    if not ui or not ui.Interfaces or not id or not id.Interface then return false end
    local ok2, c2 = pcall(function() return ui.Interfaces:GetComponent(id.Interface.COLLECTOR_BOARD, 2) end)
    if ok2 and c2 ~= nil then return true end
    local ok0, c0 = pcall(function() return ui.Interfaces:GetComponent(id.Interface.COLLECTOR_BOARD, 0) end)
    return (ok0 and c0 ~= nil)
end

--- Synchronizes completed collections and submitted artefacts from in-game achievements (config.Achievement.FromID)
--- strictly for collectors that have already been synced by the user.
local function hasArchaeologyJournal()
    local invRefs = {}
    if config and config.Inv then
        if config.Inv.INV then table.insert(invRefs, config.Inv.INV) end
        if config.Inv.WORN then table.insert(invRefs, config.Inv.WORN) end
    elseif id and id.Inv then
        if id.Inv.INV then table.insert(invRefs, id.Inv.INV) end
        if id.Inv.WORN then table.insert(invRefs, id.Inv.WORN) end
    end
    local journalObjId = (config and config.Obj and config.Obj.ARCH_JOURNAL and config.Obj.ARCH_JOURNAL.id)
        or (id and id.Obj and id.Obj.ARCH_JOURNAL)
    for _, invRef in ipairs(invRefs) do
        local inv = InventoryScanner.findInventory(invRef)
        if inv then
            for _, slot in ipairs(InventoryScanner.getInventorySlots(inv)) do
                local itemId, count, itemName = InventoryScanner.getSlotItemInfo(slot)
                if count > 0 then
                    if (journalObjId and itemId == journalObjId)
                        or (itemName and string.find(string.lower(itemName), "archaeology journal", 1, true)) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function isNearGuildNoticeboard()
    local pCoord = nil
    pcall(function()
        local pEntity = (Player and Player.GetEntity and Player.GetEntity())
            or (PlayerList and PlayerList.Self and PlayerList.Self())
        if pEntity then pCoord = pEntity.coordGrid end
    end)
    if pCoord and pCoord.x and pCoord.z then
        -- Archaeology Guild collector noticeboard sits at (3361, 3397)
        if math.abs(pCoord.x - 3361) <= 32 and math.abs(pCoord.z - 3397) <= 32 then
            return true
        end
    end
    return NoticeboardScanner.isNoticeboardOpen()
end

function NoticeboardScanner.canSyncCollectorVarps()
    return hasArchaeologyJournal() or isNearGuildNoticeboard()
end

function NoticeboardScanner.syncCollectionsDoneStatus(tracker)
    local syncedCount = 0
    if not Collections or not Collections.LIST or not tracker then return 0 end

    local submittedChanged = false
    local completedChanged = false
    local scannedChanged = false

    -- Sync via VarPlayer.COLLECTION_* when carrying the Archaeology journal or within 32 tiles of the Guild noticeboard
    if var and var.VarPlayer and NoticeboardScanner.canSyncCollectorVarps() then
        if var.VarPlayer.ARCH_TUTORIAL then
            local okTut, tutVal = pcall(function() return var.VarPlayer.ARCH_TUTORIAL.value end)
            if okTut and type(tutVal) == "number" and tutVal >= 100 then
                if not tracker.completedCollections["Museum - Training Weapons"] then
                    tracker.completedCollections["Museum - Training Weapons"] = 1
                    completedChanged = true
                    syncedCount = syncedCount + 1
                end
            end
        end

        for _, col in ipairs(Collections.LIST) do
            if col.configName then
                local vpComp = var.VarPlayer[col.configName .. "_COMPLETE"]
                local compVal = vpComp and vpComp.value
                if type(compVal) == "number" and compVal > 0 then
                    local prev = tracker.completedCollections[col.name] or 0
                    if compVal > prev then
                        tracker.completedCollections[col.name] = compVal
                        completedChanged = true
                        syncedCount = syncedCount + 1
                    end
                    if not col.isRepeatable and tracker.submittedArtefacts and tracker.submittedArtefacts[col.name] then
                        tracker.submittedArtefacts[col.name] = nil
                        submittedChanged = true
                    end
                end

                if col.artObjConfigs then
                    for artName, artCfg in pairs(col.artObjConfigs) do
                        local vpArt = var.VarPlayer[col.configName .. "_" .. artCfg]
                        local artVal = vpArt and vpArt.value
                        if type(artVal) == "number" then
                            if artVal > 0 then
                                tracker.submittedArtefacts[col.name] = tracker.submittedArtefacts[col.name] or {}
                                if not tracker.submittedArtefacts[col.name][artName] then
                                    tracker.submittedArtefacts[col.name][artName] = true
                                    submittedChanged = true
                                    syncedCount = syncedCount + 1
                                end
                            elseif tracker.submittedArtefacts[col.name] and tracker.submittedArtefacts[col.name][artName] then
                                tracker.submittedArtefacts[col.name][artName] = nil
                                submittedChanged = true
                                syncedCount = syncedCount + 1
                            end
                        end
                    end
                end

                if col.collector and col.collector ~= "" and col.collector ~= "Unknown" then
                    if (tracker.scannedCollectors[col.collector] or 0) == 0 then
                        tracker.scannedCollectors[col.collector] = 1
                        scannedChanged = true
                    end
                    tracker.liveScannedCollectors = tracker.liveScannedCollectors or {}
                    tracker.liveScannedCollectors[col.collector] = 1
                    tracker.boardSyncedLive = true
                    if not tracker.boardHasCache then
                        tracker.boardHasCache = true
                        DB.set("arch_board_has_cache", 1)
                    end
                end
            end
        end
    end

    if scannedChanged then
        DB.set("arch_scanned_collectors", DB.serializeCountMap(tracker.scannedCollectors))
    end

    if tracker.scannedCollectors and next(tracker.scannedCollectors) ~= nil
        and config and config.Achievement and config.Achievement.FromID then

    for _, col in ipairs(Collections.LIST) do
        local isCollectorScanned = (tracker.scannedCollectors[col.collector] or 0) > 0
            or (col.collector == "Giles" and next(tracker.scannedCollectors) ~= nil)
        local achId = isCollectorScanned and col.achievementId or nil
        if achId and achId > 0 then
            local ok, ach = pcall(config.Achievement.FromID, achId)
            if ok and ach and type(ach.progress) == "number" then
                if ach.progress == -2 or ach.progress == 1 then
                    if not tracker.completedCollections[col.name] then
                        tracker.completedCollections[col.name] = 1
                        syncedCount = syncedCount + 1
                    end
                    if not col.isRepeatable and tracker.submittedArtefacts and tracker.submittedArtefacts[col.name] then
                        tracker.submittedArtefacts[col.name] = nil
                        submittedChanged = true
                    end
                else
                    local reqs = nil
                    pcall(function() reqs = ach.requirements end)
                    if not reqs and type(ach.GetRequirements) == "function" then
                        pcall(function() reqs = ach:GetRequirements() end)
                    end
                    if reqs then
                        local reqCount = 0
                        pcall(function() reqCount = #reqs end)
                        if reqCount and reqCount > 0 then
                            tracker.submittedArtefacts[col.name] = tracker.submittedArtefacts[col.name] or {}
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
                                        if matchedName and not tracker.submittedArtefacts[col.name][matchedName] then
                                            tracker.submittedArtefacts[col.name][matchedName] = true
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

    if submittedChanged then
        DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(tracker.submittedArtefacts))
    end
    if syncedCount > 0 or completedChanged or submittedChanged then
        if completedChanged or syncedCount > 0 then
            DB.set("arch_completed_collections", DB.serializeCountMap(tracker.completedCollections))
        end
        tracker:recalculate()
    end
    return syncedCount
end

return NoticeboardScanner
