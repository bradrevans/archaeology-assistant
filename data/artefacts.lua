-- data/artefacts.lua
-- Base artefact definitions are populated at runtime by core/db_extractor.lua.
-- This file only stores base Chronote values (not present in client DBTables).
-- Re-run `python scripts/update_wiki_data.py` after game updates.

local Utils = require("core/utils")

local Artefacts = {}

Artefacts.LIST = {}

Artefacts.CHRONOTES = {
    ["Venator dagger"] = 206,
    ["Venator light crossbow"] = 206,
    ["Primis Elementis standard"] = 220,
    ["Legionary gladius"] = 220,
    ["Legionary square shield"] = 220,
    ["Zaros effigy"] = 244,
    ["Zarosian training dummy"] = 244,
    ["Teleportation crystal"] = 200,
    ["Drogokishuun hook sword"] = 1004,
    ["Hobgoblin mansticker"] = 1004,
    ["Chaos Elemental trophy"] = 1004,
    ["Virius trophy"] = 1004,
    ["Flat cap"] = 1020,
    ["Night owl flight goggles"] = 1020,
    ["Prototype godbow"] = 1050,
    ["Prototype godstaff"] = 1050,
    ["Prototype godsword"] = 1050,
    ["Xolo hard hat"] = 1066,
    ["Xolo pickaxe"] = 1066,
    ["Portable portal generator"] = 1066,
    ["Warped trinket"] = 1066,
    ["Praetorian hood"] = 1096,
    ["Praetorian robes"] = 1096,
    ["Praetorian staff"] = 1096,
    ["Kal-i-kra chieftain crown"] = 1112,
    ["Kal-i-kra mace"] = 1112,
    ["Kal-i-kra warhorn"] = 1112,
    ["Spear of Annihilation"] = 10730,
    ["Tsutsaroth helm"] = 1142,
    ["Tsutsaroth pauldron"] = 1142,
    ["Tsutsaroth urumi"] = 1142,
    ["Doru spear"] = 1158,
    ["Kontos lance"] = 1158,
    ["Chuluu stone"] = 1174,
    ["Quintessence counter"] = 1174,
    ["Spherical astrolabe"] = 1174,
    ["Ancient globe"] = 1174,
    ["Battle plans"] = 1174,
    ["'Prima Legio' painting"] = 1174,
    ["'Da Boss Man' sculpture"] = 1204,
    ["Horogothgar cooking pot"] = 1204,
    ["Xolo shield"] = 1204,
    ["Xolo spear"] = 1204,
    ["Gold dish"] = 1220,
    ["'Raksha' idol"] = 1220,
}

Artefacts.BY_DAMAGED_LOWER = {}
Artefacts.BY_BASE_LOWER = {}
Artefacts.BY_ID = {}

for idx, art in ipairs(Artefacts.LIST) do
    art.order = idx
    Artefacts.BY_DAMAGED_LOWER[Utils.normalizeName(art.damagedName)] = art
    Artefacts.BY_BASE_LOWER[Utils.normalizeName(art.name)] = art
    if art.id then
        Artefacts.BY_ID[art.id] = art
    end
    if art.damagedId then
        Artefacts.BY_ID[art.damagedId] = art
    end
    if art.restoredId then
        Artefacts.BY_ID[art.restoredId] = art
    end
end

function Artefacts.normalize(name)
    return Utils.normalizeName(name)
end

function Artefacts.findById(id)
    if not id then return nil end
    return Artefacts.BY_ID[id]
end

--- Returns the preferred display object ID for an artefact (defaults to the repaired/restored sprite).
function Artefacts.getDisplayId(art)
    if not art then return nil end
    return art.restoredId or art.id
end

function Artefacts.findByName(rawName)
    if not rawName or rawName == "" then return nil end
    local norm = Utils.normalizeName(rawName)
    local exact = Artefacts.BY_DAMAGED_LOWER[norm]
    if exact then
        return exact, true
    end
    local base, isDamagedSuffix = Utils.extractDamagedBaseName(rawName)
    if isDamagedSuffix then
        local byBase = Artefacts.BY_BASE_LOWER[base]
        if byBase then return byBase, true end
    else
        local byRestored = Artefacts.BY_BASE_LOWER[base]
        if byRestored then return byRestored, false end
    end
    return nil
end

function Artefacts.findRestoredByName(rawName)
    if not rawName or rawName == "" then return nil end
    return Artefacts.BY_BASE_LOWER[Utils.normalizeName(rawName)]
end

function Artefacts.findByObj(obj)
    if not obj then return nil end
    local okName, name = pcall(function() return obj.name end)
    if not okName or not name or name == "" then return nil end
    return Artefacts.findByName(name)
end

return Artefacts
