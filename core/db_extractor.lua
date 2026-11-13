-- core/db_extractor.lua
-- Dynamically extracts and supplements Archaeology materials, artefacts, collections,
-- and excavation hotspots from the RS3 client's config.DBTable / config.DBRow APIs.
-- Falls back seamlessly to static data/* tables when running outside the RS3 client.

local Utils = require("core/utils")

local DBExtractor = {}

local function getCol(row, colIdx)
    if not row or not row.GetColumnValues then return {} end
    local ok, vals = pcall(function() return row:GetColumnValues(colIdx) end)
    if not ok or not vals then return {} end
    local out = {}
    pcall(function()
        for _, v in pairs(vals) do
            table.insert(out, v)
        end
    end)
    return out
end

local function getFirst(row, colIdx)
    local vals = getCol(row, colIdx)
    return vals[1]
end

local function getParamVal(obj, paramObj)
    if not obj or not paramObj or not obj.GetParamValue then return nil end
    local ok, val = pcall(function() return obj:GetParamValue(paramObj) end)
    if ok then return val end
    return nil
end

local function safeObjInfo(obj)
    if not obj then return nil, nil end
    local oid, oname = nil, nil
    pcall(function() oid = obj.id end)
    pcall(function() oname = obj.name end)
    return oid, oname
end

local function extractRecipeMaterials(restoredObj, damagedId)
    local mats = {}
    if not config or not config.Param then return mats end
    for i = 1, 4 do
        local pType = config.Param["RECIPE_INGREDIENT_TYPE_" .. i]
        local pNum  = config.Param["RECIPE_INGREDIENT_NUMBER_" .. i]
        if pType and pNum then
            local ingObj = getParamVal(restoredObj, pType)
            local ingNum = tonumber(getParamVal(restoredObj, pNum))
            if ingObj and ingNum and ingNum > 0 then
                local ingId, ingName = safeObjInfo(ingObj)
                if ingName and ingName ~= "" and ingId ~= damagedId then
                    table.insert(mats, {
                        id    = ingId,
                        name  = ingName,
                        count = ingNum,
                    })
                end
            end
        end
    end
    return mats
end

local function extractRecipeXp(restoredObj)
    if not config or not config.Param or not config.Param.RECIPE_XP_VALUE_1 then return nil end
    local raw = tonumber(getParamVal(restoredObj, config.Param.RECIPE_XP_VALUE_1))
    if raw and raw > 0 then
        return raw / 10
    end
    return nil
end

local function ensureMaterial(Materials, matId, matName, matLevel, isArch)
    if not matName or matName == "" then return nil end
    local existing = (matId and Materials.BY_ID[matId]) or Materials.get(matName)
    if existing then
        if matId and not existing.id then existing.id = matId end
        if matLevel and matLevel > 0 and (not existing.level or existing.level <= 1) then
            existing.level = matLevel
        end
        return existing
    end
    local entry = {
        id             = matId,
        name           = matName,
        level          = matLevel or 1,
        culture        = isArch and "Agnostic" or "Secondary",
        isArchMaterial = isArch == true,
        caches         = {},
    }
    table.insert(Materials.LIST, entry)
    Materials.BY_NAME[matName] = entry
    Materials.BY_LOWER[Utils.normalizeName(matName)] = entry
    if matId then Materials.BY_ID[matId] = entry end
    return entry
end

local function addUniqueString(list, val)
    if not val or val == "" then return end
    for _, existing in ipairs(list) do
        if existing == val then return end
    end
    table.insert(list, val)
end

local function rebuildMaterialIndices(Materials)
    Materials.BY_NAME  = {}
    Materials.BY_LOWER = {}
    Materials.BY_ID    = {}
    for idx, mat in ipairs(Materials.LIST) do
        mat.order = idx
        Materials.BY_NAME[mat.name] = mat
        Materials.BY_LOWER[Utils.normalizeName(mat.name)] = mat
        if mat.id then
            Materials.BY_ID[mat.id] = mat
        end
    end
end

local function rebuildArtefactIndices(Artefacts)
    Artefacts.BY_DAMAGED_LOWER = {}
    Artefacts.BY_BASE_LOWER    = {}
    Artefacts.BY_ID            = {}
    for idx, art in ipairs(Artefacts.LIST) do
        art.order = idx
        if art.damagedName then
            Artefacts.BY_DAMAGED_LOWER[Utils.normalizeName(art.damagedName)] = art
        end
        if art.name then
            Artefacts.BY_BASE_LOWER[Utils.normalizeName(art.name)] = art
        end
        if art.id then Artefacts.BY_ID[art.id] = art end
        if art.damagedId then Artefacts.BY_ID[art.damagedId] = art end
        if art.restoredId then Artefacts.BY_ID[art.restoredId] = art end
    end
end

local function rebuildCollectionIndices(Collections)
    Collections.BY_NAME           = {}
    Collections.BY_LOWER          = {}
    Collections.BY_ARTEFACT_LOWER = {}
    for idx, col in ipairs(Collections.LIST) do
        col.order = idx
        col.location = Collections.getCollectorLocation(col.collector)
        Collections.BY_NAME[col.name] = col
        Collections.BY_LOWER[Utils.normalizeName(col.name)] = col
        for _, artName in ipairs(col.artefacts or {}) do
            local key = Utils.normalizeName(artName)
            if not Collections.BY_ARTEFACT_LOWER[key] then
                Collections.BY_ARTEFACT_LOWER[key] = {}
            end
            table.insert(Collections.BY_ARTEFACT_LOWER[key], col)
        end
    end
end

local function rebuildHotspotIndices(Hotspots)
    Hotspots.BY_LOWER = {}
    for name, data in pairs(Hotspots.BY_NAME) do
        Hotspots.BY_LOWER[Utils.normalizeName(name)] = data
    end
end

function DBExtractor.syncAll(Materials, Artefacts, Collections, Hotspots)
    if not config or not config.DBRow or not id or not id.DBTable then
        return false
    end

    local TID_COLLECTOR   = id.DBTable.COLLECTOR
    local TID_SITE        = id.DBTable.ARCH_SITE
    local TID_EXCAVATION  = id.DBTable.ARCH_EXCAVATION
    local TID_RESTORATION = id.DBTable.ARCH_RESTORATION

    local collectorRows = {}
    local siteRows      = {}
    local excRowsById   = {}
    local restRowsById  = {}

    for _, row in pairs(config.DBRow) do
        local okT, tid = pcall(function() return row.ownerDBTable and row.ownerDBTable.id end)
        if okT and tid then
            if tid == TID_COLLECTOR then
                table.insert(collectorRows, row)
            elseif tid == TID_SITE then
                table.insert(siteRows, row)
            elseif tid == TID_EXCAVATION then
                excRowsById[row.id] = row
            elseif tid == TID_RESTORATION then
                restRowsById[row.id] = row
            end
        end
    end

    local stats = { arts = 0, mats = 0, spots = 0, cols = 0 }

    -- 1. Extract / update Artefacts & Recipe Materials from ARCH_RESTORATION
    local artByRestRowId = {}
    for rowId, row in pairs(restRowsById) do
        local level       = tonumber(getFirst(row, 5))
        local damagedObj  = getFirst(row, 6)
        local restoredObj = getFirst(row, 7)
        local damagedId, damagedName   = safeObjInfo(damagedObj)
        local restoredId, restoredName = safeObjInfo(restoredObj)

        if restoredName and restoredName ~= "" and damagedId then
            local recipeMats = extractRecipeMaterials(restoredObj, damagedId)
            local recipeXp   = extractRecipeXp(restoredObj)

            for _, m in ipairs(recipeMats) do
                ensureMaterial(Materials, m.id, m.name, nil, false)
            end

            local art = Artefacts.findById(damagedId)
                or (restoredId and Artefacts.findById(restoredId))
                or Artefacts.findRestoredByName(restoredName)

            if art then
                art.id          = damagedId
                art.damagedId   = damagedId
                art.restoredId  = restoredId or art.restoredId
                art.name        = restoredName
                art.damagedName = damagedName or art.damagedName or (restoredName .. " (damaged)")
                if level and level > 0 then art.level = level end
                if recipeXp and recipeXp > 0 then art.xp = recipeXp end
                if #recipeMats > 0 then
                    art.materials = {}
                    for _, m in ipairs(recipeMats) do
                        table.insert(art.materials, { name = m.name, count = m.count })
                    end
                end
            else
                local cleanMats = {}
                for _, m in ipairs(recipeMats) do
                    table.insert(cleanMats, { name = m.name, count = m.count })
                end
                art = {
                    id          = damagedId,
                    damagedId   = damagedId,
                    restoredId  = restoredId,
                    name        = restoredName,
                    damagedName = damagedName or (restoredName .. " (damaged)"),
                    level       = level or 1,
                    location    = "Archaeology Dig Site",
                    xp          = recipeXp or 0,
                    chronotes   = 0,
                    materials   = cleanMats,
                }
                table.insert(Artefacts.LIST, art)
                stats.arts = stats.arts + 1
            end
            artByRestRowId[rowId] = art
        end
    end
    rebuildArtefactIndices(Artefacts)

    -- 2. Map ARCH_SITE -> section rows -> hotspots & caches
    local excSiteName = {}
    for _, sRow in ipairs(siteRows) do
        local sName = getFirst(sRow, 3)
        if sName and sName ~= "" then
            local subRows = getCol(sRow, 17)
            for _, sub in ipairs(subRows) do
                if sub and sub.id then
                    excSiteName[sub.id] = sName
                    for _, child in ipairs(getCol(sub, 18)) do
                        if child and child.id and not excSiteName[child.id] then
                            excSiteName[child.id] = sName
                        end
                    end
                end
            end
        end
    end

    -- 3. Extract / update Material Caches & Hotspots from ARCH_EXCAVATION
    for rowId, row in pairs(excRowsById) do
        local kind  = tonumber(getFirst(row, 2))
        local hName = getFirst(row, 3)
        local hLvl  = tonumber(getFirst(row, 5))
        local c16   = getCol(row, 16)
        local c18   = getCol(row, 18)

        if kind == 2 and #c16 > 0 then
            -- Material Cache
            local matObj = c16[1]
            local mId, mName = safeObjInfo(matObj)
            if mName and mName ~= "" then
                local matEntry = ensureMaterial(Materials, mId, mName, hLvl, true)
                if matEntry then
                    matEntry.isArchMaterial = true
                    if hLvl and hLvl > 0 then matEntry.level = hLvl end
                    local sName = excSiteName[rowId]
                    if sName then
                        matEntry.caches = matEntry.caches or {}
                        addUniqueString(matEntry.caches, sName)
                    end
                    stats.mats = stats.mats + 1
                end
            end
        elseif kind == 1 and hName and hName ~= "" then
            -- Excavation Hotspot
            local spotMats = {}
            for _, entry in ipairs(c16) do
                if type(entry) ~= "number" then
                    local mId, mName = safeObjInfo(entry)
                    if mName and mName ~= "" then
                        ensureMaterial(Materials, mId, mName, nil, true)
                        addUniqueString(spotMats, mName)
                    end
                end
            end
            if #spotMats > 0 or not Hotspots.BY_NAME[hName] then
                local existingSpot = Hotspots.BY_NAME[hName]
                Hotspots.BY_NAME[hName] = {
                    level     = hLvl or (existingSpot and existingSpot.level) or 1,
                    materials = (#spotMats > 0) and spotMats or (existingSpot and existingSpot.materials) or {},
                }
                stats.spots = stats.spots + 1
            end

            local sName = excSiteName[rowId]
            for _, item in ipairs(c18) do
                if type(item) ~= "number" and item.id and artByRestRowId[item.id] then
                    local art = artByRestRowId[item.id]
                    if (not art.location or art.location == "" or art.location == "Archaeology Dig Site") then
                        art.location = sName and string.format("%s (%s)", hName, sName) or hName
                    end
                end
            end
        end
    end
    rebuildMaterialIndices(Materials)
    rebuildHotspotIndices(Hotspots)

    -- 4. Extract / update Collectors & Collections from COLLECTOR -> COLLECTION_LOG -> COLLECTION
    for _, cRow in ipairs(collectorRows) do
        local collectorName = getFirst(cRow, 2)
        local collectorLoc  = getFirst(cRow, 6)
        if collectorName and collectorName ~= "" and collectorLoc and collectorLoc ~= "" then
            if not Collections.COLLECTOR_LOCATIONS[collectorName] then
                Collections.COLLECTOR_LOCATIONS[collectorName] = collectorLoc
            end
        end
        local logRow = getFirst(cRow, 8)
        if logRow then
            for _, colRow in ipairs(getCol(logRow, 8)) do
                if tonumber(getFirst(colRow, 3)) == 2 then
                    local colName = getFirst(colRow, 5)
                    if colName and colName ~= "" then
                        local flags = getCol(colRow, 6)
                        local isRepeatable = (flags[2] == true)
                        local oneTimeNote = getFirst(colRow, 7)
                        local achObj = getFirst(colRow, 10)
                        local achId = nil
                        pcall(function() achId = achObj and achObj.id end)

                        local artNames = {}
                        local maxArtLvl = 1
                        for _, artObj in ipairs(getCol(colRow, 14)) do
                            local aId, aName = safeObjInfo(artObj)
                            if aName and aName ~= "" then
                                table.insert(artNames, aName)
                                local artDef = (aId and Artefacts.findById(aId)) or Artefacts.findRestoredByName(aName)
                                if artDef and artDef.level and artDef.level > maxArtLvl then
                                    maxArtLvl = artDef.level
                                end
                            end
                        end

                        local col = Collections.BY_NAME[colName] or Collections.BY_LOWER[Utils.normalizeName(colName)]
                        if col then
                            if collectorName and collectorName ~= "" then col.collector = collectorName end
                            col.isRepeatable = isRepeatable
                            if oneTimeNote and oneTimeNote ~= "" and (not col.oneTimeReward or col.oneTimeReward == "") then
                                col.oneTimeReward = oneTimeNote
                            end
                            if achId then col.achievementId = achId end
                            if #artNames > 0 then col.artefacts = artNames end
                            if maxArtLvl > 1 and (not col.level or col.level <= 1) then
                                col.level = maxArtLvl
                            end
                        else
                            table.insert(Collections.LIST, {
                                order           = #Collections.LIST + 1,
                                name            = colName,
                                level           = maxArtLvl,
                                collector       = collectorName or "Unknown",
                                oneTimeReward   = "",
                                recurringReward = "",
                                chronotes       = "",
                                isRepeatable    = isRepeatable,
                                achievementId   = achId,
                                benefitType     = "",
                                specialBenefit  = "",
                                artefacts       = artNames,
                            })
                            stats.cols = stats.cols + 1
                        end
                    end
                end
            end
        end
    end
    rebuildCollectionIndices(Collections)

    print(string.format(
        "[Archaeology Assistant] Synced game DBTables (%d materials, %d artefacts, %d collections, %d hotspots).",
        #Materials.LIST, #Artefacts.LIST, #Collections.LIST, stats.spots
    ))
    return true
end

return DBExtractor
