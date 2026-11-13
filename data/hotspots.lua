-- data/hotspots.lua
-- Runtime-populated by core/db_extractor.lua from RS3 ARCH_EXCAVATION DBTable.

local Utils = require("core/utils")

local Hotspots = {}

Hotspots.BY_NAME = {}

Hotspots.BY_LOWER = {}
for name, data in pairs(Hotspots.BY_NAME) do
    Hotspots.BY_LOWER[Utils.normalizeName(name)] = data
end

function Hotspots.get(name)
    if not name then return nil end
    local direct = Hotspots.BY_NAME[name]
    if direct then return direct end
    local cleaned = Utils.cleanText(name)
    if cleaned ~= name and Hotspots.BY_NAME[cleaned] then
        return Hotspots.BY_NAME[cleaned]
    end
    return Hotspots.BY_LOWER[Utils.normalizeName(cleaned)]
end

function Hotspots.findMatch(rawName)
    if not rawName then return nil end
    local exact = Hotspots.get(rawName)
    if exact then return exact, rawName end
    local cleaned = Utils.cleanText(rawName)
    local lowerClean = Utils.normalizeName(cleaned)
    for name, data in pairs(Hotspots.BY_NAME) do
        local lowerKey = string.lower(name)
        if lowerClean == lowerKey or string.find(lowerClean, lowerKey, 1, true) then
            return data, name
        end
    end
    return nil, cleaned
end

return Hotspots
