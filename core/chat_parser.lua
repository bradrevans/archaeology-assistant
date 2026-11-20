-- core/chat_parser.lua
-- Single-responsibility parser for in-game RS3 chat messages (Sign of the Porter, Grace of the Elves,
-- collector artefact hand-ins, collection/achievement completions, and excavation discoveries).

local Materials   = require("data/materials")
local Artefacts   = require("data/artefacts")
local Collections = require("data/collections")
local Utils       = require("core/utils")
local DB          = require("core/db")

local ChatParser = {}

--- Parses Sign of the Porter / Grace of the Elves / Material Cart storage transfer messages.
local function parsePorterTransport(clean, lower)
    local transported = string.match(clean, "material storage:%s*([^%.!]+)")
        or string.match(clean, "storage:%s*([^%.!]+)")

    local mat = nil
    local qty = 1

    if transported then
        local trimmed = Utils.trim(transported)
        local qStr, nameOnly = string.match(trimmed, "^(%d+)%s*[xX]%s*(.+)$")
        if not qStr then
            qStr, nameOnly = string.match(trimmed, "^(%d+)%s+(.+)$")
        end
        if qStr and nameOnly then
            qty = tonumber(qStr) or 1
            mat = Materials.get(nameOnly)
        else
            mat = Materials.get(trimmed)
        end
    end

    if not mat and (
        string.find(lower, "material storage", 1, true)
        or string.find(lower, "porter", 1, true)
        or string.find(lower, "grace of the elves", 1, true)
        or string.find(lower, "transport", 1, true)
        or string.find(lower, "imp-souled", 1, true)
        or string.find(lower, "premier artefact", 1, true)
    ) then
        local bestMat = nil
        local bestLow = nil
        local bestLen = 0
        for _, m in ipairs(Materials.LIST or {}) do
            local mLow = string.lower(m.name)
            if #mLow > bestLen and string.find(lower, mLow, 1, true) then
                bestMat = m
                bestLow = mLow
                bestLen = #mLow
            end
        end
        if bestMat and bestLow then
            local esc = Utils.escapePattern(bestLow)
            local qMatch = string.match(lower, "(%d+)%s*[xX]%s*" .. esc)
                or string.match(lower, "(%d+)%s+" .. esc)
                or string.match(lower, esc .. "%s*[xX]%s*(%d+)")
            if qMatch and tonumber(qMatch) and tonumber(qMatch) > 0 and tonumber(qMatch) <= 10000 then
                qty = tonumber(qMatch)
            end
            mat = bestMat
        end
    end

    return mat, qty
end

--- Parses collector artefact hand-in chat messages.
local function handleCollectorHandIn(tracker, lower)
    if not (
        string.find(lower, "hand")
        or string.find(lower, "contribut")
        or string.find(lower, "give")
        or string.find(lower, "donat")
        or string.find(lower, "turn in")
        or string.find(lower, "turned in")
    ) then
        return false
    end

    local foundArt = false
    local matchedCollector = nil
    for _, col in ipairs((Collections and Collections.LIST) or {}) do
        if col.collector and string.find(lower, string.lower(col.collector), 1, true) then
            matchedCollector = col.collector
            break
        end
    end

    for artLower, artObj in pairs((Artefacts and Artefacts.BY_BASE_LOWER) or {}) do
        if string.find(lower, artLower, 1, true) then
            local artName = artObj.name or artLower
            for _, col in ipairs(Collections.LIST or {}) do
                if (not matchedCollector or col.collector == matchedCollector) and col.artefacts then
                    for _, cArt in ipairs(col.artefacts) do
                        if string.lower(cArt) == string.lower(artName) then
                            tracker.submittedArtefacts[col.name] = tracker.submittedArtefacts[col.name] or {}
                            tracker.submittedArtefacts[col.name][cArt] = true
                            foundArt = true
                        end
                    end
                end
            end
        end
    end

    if foundArt then
        tracker.boardSyncedLive = true
        tracker.boardHasCache = true
        DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(tracker.submittedArtefacts))
        for colName, _ in pairs(tracker.submittedArtefacts) do
            tracker:isCollectionCompleted(colName)
        end
        tracker:syncCollectionsDoneStatus(false)
        tracker:recalculate()
        return true
    end
    return false
end

--- Parses collection or achievement completion messages.
local function handleCollectionCompletion(tracker, lower)
    if not (
        string.find(lower, "completed the collection")
        or string.find(lower, "collection completed")
        or string.find(lower, "achievement completed")
        or string.find(lower, "completed the achievement")
        or string.find(lower, "achievement unlocked")
        or string.find(lower, "unlocked the achievement")
        or string.find(lower, "collection complete")
        or string.find(lower, "completed collection")
        or string.find(lower, "collection:")
        or string.find(lower, "collection '")
    ) then
        return false
    end

    tracker:syncCollectionsDoneStatus(false)
    local matched = false
    for _, col in ipairs((Collections and Collections.LIST) or {}) do
        if string.find(lower, string.lower(col.name), 1, true) then
            tracker.completedCollections[col.name] = 1
            if tracker.submittedArtefacts and tracker.submittedArtefacts[col.name] then
                tracker.submittedArtefacts[col.name] = nil
            end
            matched = true
        end
    end
    if matched then
        DB.set("arch_completed_collections", DB.serializeCountMap(tracker.completedCollections))
        DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(tracker.submittedArtefacts))
        tracker:recalculate()
        return true
    end
    return false
end

--- Processes an in-game chat message string (or event table) and updates tracker state.
function ChatParser.onChatMessage(tracker, textOrEvent)
    local text = textOrEvent
    if type(textOrEvent) == "table" or type(textOrEvent) == "userdata" then
        pcall(function() text = textOrEvent.chatMessage or textOrEvent.text or textOrEvent.message end)
    end
    if type(text) ~= "string" or text == "" then
        return false
    end

    local clean = Utils.cleanText(text)
    local lower = string.lower(clean)

    -- 0. Archaeology Level-up detection
    local lvlMatch = string.match(clean, "advanced your Archaeology level to (%d+)")
        or string.match(clean, "reached level (%d+) in Archaeology")
        or string.match(clean, "Archaeology level is now (%d+)")
    if lvlMatch then
        local newLvl = tonumber(lvlMatch)
        if newLvl and newLvl >= 1 and newLvl <= 120 then
            tracker:setPlayerArchLevel(newLvl)
            print(string.format("[Archaeology Assistant] Synced Archaeology level from chat: %d", newLvl))
        end
    end

    -- 1a. Boon of Crondis item doubling
    if string.find(lower, "boon of crondis", 1, true) and string.find(lower, "doubled the following item", 1, true) then
        local dest, payload = string.match(clean, "sent it to your ([^:]+):%s*([^%.!]+)")
        if dest and payload then
            local destLower = string.lower(Utils.trim(dest))
            local isStorageDest = string.find(destLower, "material storage", 1, true) ~= nil
            local isBankDest = (not isStorageDest)
                and (destLower == "bank" or string.find(destLower, "bank", 1, true) ~= nil)
                and not string.find(destLower, "metal bank", 1, true)

            if isStorageDest or isBankDest then
                local trimmed = Utils.trim(payload)
                local bQty = 1
                local bName = trimmed
                local qStr, rest = string.match(trimmed, "^(%d+)%s*[xX]%s*(.+)$")
                if not qStr then
                    qStr, rest = string.match(trimmed, "^(%d+)%s+(.+)$")
                end
                if qStr and rest then
                    bQty = tonumber(qStr) or 1
                    bName = Utils.trim(rest)
                end

                local bMat = Materials.get(bName)
                local bArt = (not bMat) and Artefacts.findByName(bName) or nil
                if bMat then
                    if isStorageDest then
                        tracker.storageMaterials[bMat.name] = (tracker.storageMaterials[bMat.name] or 0) + bQty
                        tracker.storageHasCache = true
                        DB.set("arch_storage_materials", DB.serializeCountMap(tracker.storageMaterials))
                    else
                        tracker.bankMaterials[bMat.name] = (tracker.bankMaterials[bMat.name] or 0) + bQty
                        tracker.bankHasCache = true
                        DB.set("arch_bank_materials", DB.serializeCountMap(tracker.bankMaterials))
                    end
                    tracker._skipExternalContainerScan = true
                    local okRecalc, errRecalc = pcall(function() tracker:recalculate() end)
                    tracker._skipExternalContainerScan = false
                    if not okRecalc then
                        error(errRecalc, 0)
                    end
                    return true
                elseif bArt and isBankDest then
                    local dmgKey = bArt.damagedName or (bArt.name .. " (damaged)")
                    tracker.bankArtefacts[dmgKey] = (tracker.bankArtefacts[dmgKey] or 0) + bQty
                    tracker.bankHasCache = true
                    DB.set("arch_bank_artefacts", DB.serializeCountMap(tracker.bankArtefacts))
                    tracker._skipExternalContainerScan = true
                    local okRecalc, errRecalc = pcall(function() tracker:recalculate() end)
                    tracker._skipExternalContainerScan = false
                    if not okRecalc then
                        error(errRecalc, 0)
                    end
                    return true
                end
            end
        end
        return false
    end

    -- 1. Sign of the Porter / Grace of the Elves / Material Storage transport
    local mat, qty = parsePorterTransport(clean, lower)
    if mat then
        tracker.storageMaterials[mat.name] = (tracker.storageMaterials[mat.name] or 0) + qty
        tracker.storageHasCache = true
        tracker.pendingJournalStorageScan = false
        tracker.storageActionTicks = 0
        DB.set("arch_storage_materials", DB.serializeCountMap(tracker.storageMaterials))
        tracker._skipExternalContainerScan = true
        local okRecalc, errRecalc = pcall(function() tracker:recalculate() end)
        tracker._skipExternalContainerScan = false
        if not okRecalc then
            error(errRecalc, 0)
        end
        return true
    end

    -- 1b. Waterfiend / familiar item duplication ("Your familiar has produced an item: <name>.")
    local producedRaw = string.match(clean, "[Ff]amiliar has produced an item:%s*([^%.!]+)")
        or string.match(clean, "[Ff]amiliar has produced:%s*([^%.!]+)")
    if producedRaw then
        local trimmed = Utils.trim(producedRaw)
        local pQty = 1
        local pName = trimmed
        local qStr, rest = string.match(trimmed, "^(%d+)%s*[xX]%s*(.+)$")
        if not qStr then
            qStr, rest = string.match(trimmed, "^(%d+)%s+(.+)$")
        end
        if qStr and rest then
            pQty = tonumber(qStr) or 1
            pName = Utils.trim(rest)
        end

        local fMat = Materials.get(pName)
        local fArt = (not fMat) and Artefacts.findByName(pName) or nil
        if fMat or fArt then
            if tracker.bobInvLive then
                tracker:recalculate()
                return true
            end
            if fMat then
                tracker.bobMaterials[fMat.name] = (tracker.bobMaterials[fMat.name] or 0) + pQty
                DB.set("arch_bob_materials", DB.serializeCountMap(tracker.bobMaterials))
            elseif fArt then
                local dmgKey = fArt.damagedName or (fArt.name .. " (damaged)")
                tracker.bobArtefacts[dmgKey] = (tracker.bobArtefacts[dmgKey] or 0) + pQty
                DB.set("arch_bob_artefacts", DB.serializeCountMap(tracker.bobArtefacts))
            end
            tracker._skipExternalContainerScan = true
            local okRecalc, errRecalc = pcall(function() tracker:recalculate() end)
            tracker._skipExternalContainerScan = false
            if not okRecalc then
                error(errRecalc, 0)
            end
            return true
        end
    end

    -- 1c. Waterfiend Straight Flush scroll banking BoB items
    if (string.find(lower, "straight flush", 1, true)
        or (string.find(lower, "familiar", 1, true) and string.find(lower, "bank", 1, true)))
        and (next(tracker.bobMaterials or {}) ~= nil or next(tracker.bobArtefacts or {}) ~= nil) then
        if tracker:transferBobToBank() then
            tracker._skipExternalContainerScan = true
            local okRecalc, errRecalc = pcall(function() tracker:recalculate() end)
            tracker._skipExternalContainerScan = false
            if not okRecalc then
                error(errRecalc, 0)
            end
            return true
        end
    end

    -- 2. Collector artefact submission
    if handleCollectorHandIn(tracker, lower) then
        return true
    end

    -- 3. Collection / Achievement completion
    if handleCollectionCompletion(tracker, lower) then
        return true
    end

    -- 4. Excavation discovery of damaged artefacts
    if (string.find(lower, "find") or string.find(lower, "found") or string.find(lower, "discover") or string.find(lower, "excavat"))
        and (string.find(lower, "damaged") or string.find(lower, "artefact") or string.find(lower, "artifact")) then
        tracker:recalculate(config and config.Inv and config.Inv.INV)
        return true
    end

    -- 5. Restoration of an artefact at a workbench
    if string.find(lower, "you restore") or string.find(lower, "you have restored") or string.find(lower, "restoring") then
        tracker.lastAction = "restore"
        tracker:recalculate(config and config.Inv and config.Inv.INV)
        return true
    end

    return false
end

return ChatParser
