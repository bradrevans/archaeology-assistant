-- data/hotspots.lua
-- Runtime-populated by core/db_extractor.lua from RS3 ARCH_EXCAVATION DBTable.

local Utils = require("core/utils")

local Hotspots = {}

Hotspots.BY_NAME = {}

Hotspots.BY_LOWER = {}
Hotspots._matchCache = {}

function Hotspots.normalizeKey(str)
    if not str then return "" end
    local norm = Utils.normalizeName(str)
    norm = string.gsub(norm, "’", "'")
    norm = string.gsub(norm, "'s%s+", " ")
    norm = string.gsub(norm, "'s$", "")
    return norm
end

for name, data in pairs(Hotspots.BY_NAME) do
    Hotspots.BY_LOWER[Utils.normalizeName(name)] = data
    local normKey = Hotspots.normalizeKey(name)
    Hotspots.BY_LOWER[normKey] = Hotspots.BY_LOWER[normKey] or data
end

function Hotspots.findMatch(rawName)
    if not rawName then return nil end
    local cached = Hotspots._matchCache[rawName]
    if cached ~= nil then
        return cached.data or nil, cached.name
    end
    local function finish(data, matchedName)
        Hotspots._matchCache[rawName] = { data = data or false, name = matchedName }
        return data, matchedName
    end
    local direct = Hotspots.BY_NAME[rawName]
    if direct then return finish(direct, rawName) end
    local cleaned = Utils.cleanText(rawName)
    if cleaned ~= rawName and Hotspots.BY_NAME[cleaned] then
        return finish(Hotspots.BY_NAME[cleaned], cleaned)
    end
    local lowerClean = Utils.normalizeName(cleaned)
    local normClean = Hotspots.normalizeKey(cleaned)
    for name, data in pairs(Hotspots.BY_NAME) do
        local lowerKey = string.lower(name)
        if lowerClean == lowerKey or normClean == Hotspots.normalizeKey(name) then
            return finish(data, name)
        end
    end
    local bestData, bestName, bestLen = nil, nil, 0
    for name, data in pairs(Hotspots.BY_NAME) do
        local lowerKey = string.lower(name)
        local normKey = Hotspots.normalizeKey(name)
        if string.find(lowerClean, lowerKey, 1, true)
            or (normKey ~= "" and string.find(normClean, normKey, 1, true)) then
            if #name > bestLen then
                bestLen = #name
                bestData = data
                bestName = name
            end
        end
    end
    if bestData then
        return finish(bestData, bestName)
    end
    return finish(nil, cleaned)
end

function Hotspots.get(name)
    if not name then return nil end
    local direct = Hotspots.BY_NAME[name]
    if direct then return direct end
    local cleaned = Utils.cleanText(name)
    if cleaned ~= name and Hotspots.BY_NAME[cleaned] then
        return Hotspots.BY_NAME[cleaned]
    end
    local byLower = Hotspots.BY_LOWER[Utils.normalizeName(cleaned)]
        or Hotspots.BY_LOWER[Hotspots.normalizeKey(cleaned)]
    if byLower then return byLower end
    local matched = Hotspots.findMatch(cleaned)
    return matched
end

return Hotspots
