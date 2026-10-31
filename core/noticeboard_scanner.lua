-- core/noticeboard_scanner.lua
-- Single-responsibility module for scanning Interface 657 (Collector Information Noticeboard)
-- and syncing completed collections/artefacts via RS3's config.Achievement API.

local Artefacts   = require("data/artefacts")
local Collections = require("data/collections")
local Utils       = require("core/utils")
local DB          = require("core/db")

local NoticeboardScanner = {}

local COLLECTORS_LOOKUP = nil
local COLLECTIONS_LOOKUP = nil
local ARTEFACT_COLLECTIONS = nil

--- Builds and caches O(1) lookup tables for collector names and collection names.
local function getCollectorLookups()
    if not COLLECTORS_LOOKUP then
        COLLECTORS_LOOKUP = {}
        COLLECTIONS_LOOKUP = {}
        for _, col in ipairs((Collections and Collections.LIST) or {}) do
            if col.collector then
                local cNorm = Utils.normalizeName(col.collector)
                COLLECTORS_LOOKUP[cNorm] = col.collector
                for word in string.gmatch(cNorm, "[%w']+") do
                    if #word >= 4 and not COLLECTORS_LOOKUP[word] then
                        COLLECTORS_LOOKUP[word] = col.collector
                    end
                end
            end
            if col.name then
                local nNorm = Utils.normalizeName(col.name)
                COLLECTIONS_LOOKUP[nNorm] = col
            end
        end
    end
    return COLLECTORS_LOOKUP, COLLECTIONS_LOOKUP
end

--- Builds and caches a map of lower(artefactName) -> list of { colName, collector }.
local function getArtefactCollectionsMap()
    if not ARTEFACT_COLLECTIONS then
        ARTEFACT_COLLECTIONS = {}
        for _, col in ipairs((Collections and Collections.LIST) or {}) do
            for _, artName in ipairs(col.artefacts or {}) do
                local artLower = string.lower(artName)
                ARTEFACT_COLLECTIONS[artLower] = ARTEFACT_COLLECTIONS[artLower] or {}
                table.insert(ARTEFACT_COLLECTIONS[artLower], { colName = col.name, collector = col.collector })
            end
        end
    end
    return ARTEFACT_COLLECTIONS
end

--- Safely extracts text from an RS3 UI component.
local function getCompText(c)
    if not c then return nil end
    local t = nil
    pcall(function()
        t = c.content or c.text or (c.GetText and c:GetText()) or c.textFormatted or c.rawText
    end)
    if t and type(t) ~= "string" then
        t = tostring(t)
    end
    return t
end

--- Safely extracts child component from IterateStaticComponents / IterateDynamicComponents callback args.
local function safeExtractChild(a, b)
    if type(a) == "table" or type(a) == "userdata" then
        return a
    elseif type(b) == "table" or type(b) == "userdata" then
        return b
    end
    return nil
end

--- Checks if a hex colour tag in raw text indicates a green completed state.
local function hasGreenColTag(txt)
    if not txt then return false end
    for hex in string.gmatch(txt, "<col=([0-9a-fA-F]+)>") do
        if #hex >= 6 then
            local r = tonumber(string.sub(hex, 1, 2), 16) or 0
            local g = tonumber(string.sub(hex, 3, 4), 16) or 0
            local b = tonumber(string.sub(hex, 5, 6), 16) or 0
            if g > 140 and g > (r + 30) and g > (b + 30) then
                return true
            end
        end
    end
    return false
end

--- Checks if an Interface 657 component is rendered in full colour (handed in) vs dark silhouette (not handed in).
local function isInterface657FullColor(comp)
    local rgbaVal = nil
    pcall(function() rgbaVal = comp.rgba end)
    local alphaVal = nil
    pcall(function() alphaVal = comp.alpha end)
    local colVal = nil
    pcall(function() colVal = comp.colour or comp.color end)

    if rgbaVal and type(rgbaVal) == "number" and (rgbaVal == 4294967295 or rgbaVal == -1 or rgbaVal > 4000000000) then
        return true
    elseif alphaVal and type(alphaVal) == "number" and alphaVal >= 0.98 then
        if type(colVal) == "table" and (colVal.x or colVal.r) then
            local r = colVal.x or colVal.r or 0
            if r > 0.8 then return true end
        else
            return true
        end
    end
    return false
end

--- Resolves which collections on the noticeboard an artefact belongs to.
local function resolveTargetCollectionsForArtefact(matchedArtName, activeCollectorName, activeCollection)
    local targetCollections = {}
    local artColMap = getArtefactCollectionsMap()
    local entries = (artColMap and artColMap[string.lower(matchedArtName)]) or {}

    if activeCollectorName then
        local aLow = string.lower(activeCollectorName)
        for _, ent in ipairs(entries) do
            if ent.collector and string.lower(ent.collector) == aLow then
                table.insert(targetCollections, ent.colName)
            end
        end
    end
    if #targetCollections == 0 and activeCollection then
        for _, ent in ipairs(entries) do
            if ent.colName == activeCollection then
                table.insert(targetCollections, ent.colName)
            end
        end
    end
    if #targetCollections == 0 then
        for _, ent in ipairs(entries) do
            table.insert(targetCollections, ent.colName)
        end
    end
    return targetCollections
end

--- Returns true if Interface 657 (Collector Information Noticeboard) is currently open.
function NoticeboardScanner.isNoticeboardOpen()
    if not ui or not ui.Interfaces then return false end
    local ok2, c2 = pcall(function() return ui.Interfaces:GetComponent(657, 2) end)
    if ok2 and c2 ~= nil then return true end
    local ok0, c0 = pcall(function() return ui.Interfaces:GetComponent(657, 0) end)
    return (ok0 and c0 ~= nil)
end

--- Lightweight BFS on Interface 657 to detect the currently selected collector name.
function NoticeboardScanner.detectActiveCollector()
    if not ui or not ui.Interfaces then return nil end
    local ok, c2 = pcall(function()
        return ui.Interfaces:GetComponent(657, 2) or ui.Interfaces:GetComponent(657, 0)
    end)
    if not ok or not c2 then return nil end

    local collectorsLookup, collectionsLookup = getCollectorLookups()
    local queue = { { comp = c2, depth = 1 } }
    local qHead = 1

    while qHead <= #queue and qHead < 120 do
        local node = queue[qHead]
        qHead = qHead + 1
        local comp = node.comp

        local rawTxt = getCompText(comp)
        if rawTxt and type(rawTxt) == "string" and #rawTxt >= 3 then
            local norm = Utils.normalizeName(rawTxt)
            if collectorsLookup and collectorsLookup[norm] then
                return collectorsLookup[norm]
            end
            if collectionsLookup and collectionsLookup[norm] and collectionsLookup[norm].collector then
                return collectionsLookup[norm].collector
            end
        end

        if node.depth < 8 then
            if comp.IterateStaticComponents then
                pcall(comp.IterateStaticComponents, comp, function(child)
                    if child and #queue < 120 then
                        table.insert(queue, { comp = child, depth = node.depth + 1 })
                    end
                    return false
                end)
            end
            if comp.IterateDynamicComponents then
                pcall(comp.IterateDynamicComponents, comp, function(child)
                    if child and #queue < 120 then
                        table.insert(queue, { comp = child, depth = node.depth + 1 })
                    end
                    return false
                end)
            end
        end
    end

    return nil
end

--- Scans Interface 657 for active collector, collection progress, and handed-in vs missing artefacts.
function NoticeboardScanner.scanCollectorInterface(tracker)
    if not ui or not ui.Interfaces then return false end

    local detected = false
    local totalVisited = 0
    local maxDepthOverall = 0
    local artsFound = 0
    local activeCollection = nil
    local activeCollectorName = nil
    local collectionProgress = {}

    local collectorsLookup, collectionsLookup = getCollectorLookups()

    local function inspectCompNode(comp, depth, ifId)
        if not comp then return end
        totalVisited = totalVisited + 1
        if depth > maxDepthOverall then maxDepthOverall = depth end

        local rawTxt = getCompText(comp)
        local norm = Utils.normalizeName(rawTxt or "")
        local objId = nil
        pcall(function() objId = comp.associatedObjectID or comp.objId or comp.itemId or comp.itemID end)
        local itemCount = nil
        pcall(function()
            itemCount = comp.itemCount or comp.itemAmount or comp.associatedObjectCount
                or comp.associatedObjectAmount or comp.count or comp.quantity or comp.amount
        end)

        -- 1. Check for Collector Name & Collection Name
        if #norm >= 3 then
            if collectorsLookup and collectorsLookup[norm] then
                activeCollectorName = collectorsLookup[norm]
            end
            if collectionsLookup and collectionsLookup[norm] then
                local colDef = collectionsLookup[norm]
                activeCollection = colDef.name
                if colDef.collector then
                    activeCollectorName = colDef.collector
                end
            end
        end

        -- 2. Check for collection progress string e.g. "0/3", "1/5", "3/3"
        if activeCollection and rawTxt then
            local colDef = Collections and Collections.BY_NAME and Collections.BY_NAME[activeCollection]
            if colDef and colDef.artefacts then
                local pCur, pTot = string.match(norm, "^(%d+)%s*/%s*(%d+)$")
                if not pCur then
                    pCur, pTot = string.match(norm, "(%d+)%s*/%s*(%d+)")
                end
                if pCur and pTot then
                    local nCur = tonumber(pCur)
                    local nTot = tonumber(pTot)
                    if nCur and nTot and nTot == #colDef.artefacts and nCur <= nTot then
                        collectionProgress[activeCollection] = { submitted = nCur, total = nTot }
                    end
                end
            end
        end

        -- 3. Check for Artefact by associatedObjectID or text
        local matchedArtName = nil
        if objId and objId > 0 and Artefacts and Artefacts.BY_ID then
            local artObj = Artefacts.BY_ID[objId] or Artefacts.BY_ID[objId - 1]
            if artObj then
                matchedArtName = artObj.name
            end
        end

        if not matchedArtName and #norm >= 3 and #norm <= 45 and not string.find(norm, "/", 1, true) then
            if Artefacts and Artefacts.BY_BASE_LOWER and Artefacts.BY_BASE_LOWER[norm] then
                matchedArtName = Artefacts.BY_BASE_LOWER[norm].name
            end
        end

        if not matchedArtName then
            return
        end

        artsFound = artsFound + 1
        local isDone = false
        local hasExplicit0 = false

        if rawTxt then
            if string.find(norm, "1/1") or string.find(norm, "1 / 1")
                or string.find(norm, "handed in") or string.find(norm, "turned in")
                or string.find(norm, "submitted") or string.find(norm, "complete")
                or string.find(norm, "contributed") or string.find(norm, "done")
                or string.find(norm, "yes") then
                isDone = true
            elseif string.find(norm, "0/1") or string.find(norm, "0 / 1") then
                hasExplicit0 = true
            end
            if not isDone and (string.find(rawTxt, "<str>") or string.find(rawTxt, "<s>") or hasGreenColTag(rawTxt)) then
                isDone = true
            end
        end

        if not isDone and objId and objId > 0 and type(itemCount) == "number" and itemCount > 0 then
            isDone = true
        end

        if comp.parent then
            local function inspectSibling(a, b)
                local sib = safeExtractChild(a, b)
                if sib and sib ~= comp then
                    local sTxt = getCompText(sib)
                    if sTxt and type(sTxt) == "string" and sTxt ~= "" then
                        local sLow = string.lower(sTxt)
                        if string.find(sLow, "0/1") or string.find(sLow, "0 / 1") then
                            hasExplicit0 = true
                        elseif string.find(sLow, "1/1") or string.find(sLow, "1 / 1")
                            or string.find(sLow, "done") or string.find(sLow, "turned in")
                            or string.find(sLow, "submitted") or string.find(sLow, "handed in")
                            or hasGreenColTag(sTxt) then
                            isDone = true
                        end
                    end
                end
                return false
            end
            if comp.parent.IterateStaticComponents then
                pcall(comp.parent.IterateStaticComponents, comp.parent, inspectSibling)
            end
            if comp.parent.IterateDynamicComponents then
                pcall(comp.parent.IterateDynamicComponents, comp.parent, inspectSibling)
            end
        end

        if ifId == 657 then
            if isInterface657FullColor(comp) then
                isDone = true
            else
                hasExplicit0 = true
                isDone = false
            end
        end

        local prog = activeCollection and collectionProgress[activeCollection]
        local isCollectionFull = prog and prog.submitted and prog.total and prog.submitted == prog.total and prog.total > 0
        if not isDone and isCollectionFull then
            isDone = true
        end
        if hasExplicit0 and not isCollectionFull then
            isDone = false
        end

        local targetCollections = resolveTargetCollectionsForArtefact(matchedArtName, activeCollectorName, activeCollection)
        for _, cName in ipairs(targetCollections) do
            tracker.submittedArtefacts[cName] = tracker.submittedArtefacts[cName] or {}
            if isDone then
                if not tracker.submittedArtefacts[cName][matchedArtName] then
                    tracker.submittedArtefacts[cName][matchedArtName] = true
                    detected = true
                end
            elseif hasExplicit0 then
                if tracker.submittedArtefacts[cName][matchedArtName] then
                    tracker.submittedArtefacts[cName][matchedArtName] = nil
                    detected = true
                end
            end
        end
    end

    local hasNoticeboard657 = false
    local ok657, iface657 = pcall(function() return ui.Interfaces:GetInterface(657) end)
    if (ok657 and iface657)
        or ui.Interfaces:GetComponent(657, 0)
        or ui.Interfaces:GetComponent(657, 24)
        or ui.Interfaces:GetComponent(657, 2) then
        hasNoticeboard657 = true
    end

    if hasNoticeboard657 then
        local queue = {}
        local qHead = 1

        local function enqueue657(comp, depth)
            if comp and depth <= 16 then
                table.insert(queue, { comp = comp, depth = depth })
            end
        end

        local c2 = nil
        pcall(function() c2 = ui.Interfaces:GetComponent(657, 2) end)
        if c2 then enqueue657(c2, 1) end

        local c0 = nil
        pcall(function() c0 = ui.Interfaces:GetComponent(657, 0) end)
        if c0 and not c2 then enqueue657(c0, 1) end

        while qHead <= #queue and qHead < 2500 do
            local node = queue[qHead]
            qHead = qHead + 1
            local comp = node.comp
            local depth = node.depth

            inspectCompNode(comp, depth, 657)

            if depth < 12 then
                if comp.IterateStaticComponents then
                    pcall(comp.IterateStaticComponents, comp, function(a, b)
                        local child = safeExtractChild(a, b)
                        if child then enqueue657(child, depth + 1) end
                        return false
                    end)
                end
                if comp.IterateDynamicComponents then
                    pcall(comp.IterateDynamicComponents, comp, function(a, b)
                        local child = safeExtractChild(a, b)
                        if child then enqueue657(child, depth + 1) end
                        return false
                    end)
                end
            end
        end
    end

    tracker.lastCollectorScanSummary = string.format("%d nodes (depth %d), %d arts on screen", totalVisited, maxDepthOverall, artsFound)

    if artsFound > 0 then
        tracker.boardSyncedLive = true
        tracker.boardHasCache = true
        DB.set("arch_board_has_cache", 1)
        DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(tracker.submittedArtefacts))
        if activeCollectorName and activeCollectorName ~= "" and activeCollectorName ~= "Noticeboard" then
            tracker.scannedCollectors[activeCollectorName] = 1
            tracker.liveScannedCollectors = tracker.liveScannedCollectors or {}
            tracker.liveScannedCollectors[activeCollectorName] = 1
            DB.set("arch_scanned_collectors", DB.serializeCountMap(tracker.scannedCollectors))
        end
        NoticeboardScanner.syncCollectionsDoneStatus(tracker)
        tracker:recalculate()
    end

    return (artsFound > 0), detected, activeCollectorName
end

--- Synchronizes completed collections and submitted artefacts from in-game achievements (config.Achievement.FromID)
--- strictly for collectors that have already been synced by the user.
function NoticeboardScanner.syncCollectionsDoneStatus(tracker)
    local syncedCount = 0
    if not Collections or not Collections.LIST then return 0 end
    if not tracker or not tracker.scannedCollectors or next(tracker.scannedCollectors) == nil then
        return 0
    end
    if not config or not config.Achievement or not config.Achievement.FromID then
        return 0
    end

    local submittedChanged = false

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

    if submittedChanged then
        DB.set("arch_submitted_artefacts", DB.serializeSubmittedMap(tracker.submittedArtefacts))
    end
    if syncedCount > 0 or submittedChanged then
        if syncedCount > 0 then
            DB.set("arch_completed_collections", DB.serializeCountMap(tracker.completedCollections))
        end
        tracker:recalculate()
    end
    return syncedCount
end

return NoticeboardScanner
