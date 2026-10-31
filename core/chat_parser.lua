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
        string.find(lower, "material storage")
        or string.find(lower, "porter")
        or string.find(lower, "grace of the elves")
        or string.find(lower, "transport")
    ) then
        for _, m in ipairs(Materials.LIST or {}) do
            local mLow = string.lower(m.name)
            if string.find(lower, mLow, 1, true) then
                local esc = Utils.escapePattern(mLow)
                local qMatch = string.match(lower, "(%d+)%s*[xX]%s*" .. esc)
                    or string.match(lower, "(%d+)%s+" .. esc)
                    or string.match(lower, esc .. "%s*[xX]%s*(%d+)")
                if qMatch and tonumber(qMatch) and tonumber(qMatch) > 0 and tonumber(qMatch) <= 10000 then
                    qty = tonumber(qMatch)
                end
                mat = m
                break
            end
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
        pcall(function() text = textOrEvent.text or textOrEvent.message end)
    end
    if type(text) ~= "string" or text == "" then
        return false
    end

    local clean = Utils.cleanText(text)
    local lower = string.lower(clean)

    -- 1. Sign of the Porter / Grace of the Elves / Material Storage transport
    local mat, qty = parsePorterTransport(clean, lower)
    if mat then
        tracker.storageMaterials[mat.name] = (tracker.storageMaterials[mat.name] or 0) + qty
        tracker.storageHasCache = true
        DB.set("arch_storage_materials", DB.serializeCountMap(tracker.storageMaterials))
        tracker:recalculate()
        print(string.format(
            "[Archaeology Assistant] Transported to Material Storage: +%d %s (Storage total: %d)",
            qty,
            mat.name,
            tracker.storageMaterials[mat.name]
        ))
        return true
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

    return false
end

return ChatParser
