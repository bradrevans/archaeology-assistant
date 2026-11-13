-- data/materials.lua
-- Runtime-populated by core/db_extractor.lua from RS3 DBTables & Obj.params.

local Utils = require("core/utils")

local Materials = {}

Materials.LIST = {}

Materials.BY_NAME = {}
Materials.BY_LOWER = {}
Materials.BY_ID = {}

for idx, mat in ipairs(Materials.LIST) do
    mat.order = idx
    Materials.BY_NAME[mat.name] = mat
    Materials.BY_LOWER[Utils.normalizeName(mat.name)] = mat
    if mat.id then
        Materials.BY_ID[mat.id] = mat
    end
end

function Materials.normalize(name)
    return Utils.normalizeName(name)
end

function Materials.get(name)
    if not name then return nil end
    return Materials.BY_NAME[name] or Materials.BY_LOWER[Utils.normalizeName(name)]
end

function Materials.getById(id)
    if not id then return nil end
    return Materials.BY_ID[id]
end

function Materials.isMaterial(name)
    return Materials.get(name) ~= nil
end

function Materials.isArchMaterial(name)
    local m = Materials.get(name)
    return m ~= nil and m.isArchMaterial == true
end

return Materials
