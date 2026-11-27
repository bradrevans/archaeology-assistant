-- core/nav_memory.lua
-- Lightweight PersistentDB cache of newly discovered hotspot / material cache coordinates.
-- Ensures even brand-new dig sites added in future RS3 updates self-populate exact world
-- coordinates as soon as the player walks past them once.

local DB = require("core/db")

local NavMemory = {}

local SPOTS_KEY   = "arch_nav_spots_v1"
local MAX_PER_KEY = 8
local SPOT_DEDUPE = 6

local spots         = nil
local dirty         = false
local loadedAccount = nil

local function sanitize(s)
    return (string.gsub(tostring(s or ""), "[|=;,]", " "))
end

local function load()
    local acct = DB.getActiveAccount and DB.getActiveAccount() or nil
    if spots and loadedAccount == acct then return end
    loadedAccount = acct
    spots = {}

    local raw = DB.get(SPOTS_KEY, "")
    if type(raw) == "string" and raw ~= "" then
        for entry in string.gmatch(raw, "[^|]+") do
            local key, list = string.match(entry, "^(.-)=(.*)$")
            if key and key ~= "" and list then
                local arr = {}
                for x, z, l in string.gmatch(list, "(-?%d+),(-?%d+),(-?%d+)") do
                    arr[#arr + 1] = { x = tonumber(x), z = tonumber(z), level = tonumber(l) }
                end
                if #arr > 0 then spots[key] = arr end
            end
        end
    end
end

function NavMemory.rememberSpot(key, x, z, level)
    if not key or key == "" or not x or not z then return end
    load()
    key = sanitize(key)
    level = level or 0
    local arr = spots[key]
    if not arr then
        arr = {}
        spots[key] = arr
    end
    for _, c in ipairs(arr) do
        if (c.level or 0) == level
            and math.abs(c.x - x) <= SPOT_DEDUPE
            and math.abs(c.z - z) <= SPOT_DEDUPE then
            return
        end
    end
    arr[#arr + 1] = { x = x, z = z, level = level }
    while #arr > MAX_PER_KEY do table.remove(arr, 1) end
    dirty = true
end

function NavMemory.getSpotsForKeys(keySet)
    if not keySet then return nil end
    load()
    local out = nil
    for k in pairs(keySet) do
        local arr = spots[sanitize(k)]
        if arr then
            out = out or {}
            for _, c in ipairs(arr) do out[#out + 1] = c end
        end
    end
    return out
end

function NavMemory.flush()
    if not dirty or not spots then return end
    dirty = false
    local parts = {}
    for key, arr in pairs(spots) do
        local coords = {}
        for _, c in ipairs(arr) do
            coords[#coords + 1] = string.format("%d,%d,%d", c.x, c.z, c.level or 0)
        end
        if #coords > 0 then
            parts[#parts + 1] = key .. "=" .. table.concat(coords, ";")
        end
    end
    table.sort(parts)
    DB.set(SPOTS_KEY, table.concat(parts, "|"))
end

function NavMemory.isDirty()
    return dirty
end

return NavMemory
