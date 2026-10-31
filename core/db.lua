-- core/db.lua
-- Single-responsibility wrapper around RS3's PersistentDB API and deterministic map serialization.

local DB = {}

--- Safely reads a key from PersistentDB, returning defaultVal if unavailable or unset.
function DB.get(key, defaultVal)
    if PersistentDB then
        local ok, val = pcall(function() return PersistentDB:Get(key) end)
        if ok and val ~= nil then
            return val
        end
    end
    return defaultVal
end

--- Safely writes a key/value pair to PersistentDB.
function DB.set(key, val)
    if PersistentDB then
        pcall(function() PersistentDB:Set(key, val) end)
    end
end

--- Reads a boolean flag from PersistentDB (handles 1/0, true/false, and "true"/"false").
function DB.getBool(key, defaultBool)
    local val = DB.get(key, nil)
    if val == nil then
        return defaultBool == true
    end
    if type(val) == "boolean" then
        return val
    end
    if type(val) == "number" then
        return val ~= 0
    end
    if type(val) == "string" then
        return val == "1" or string.lower(val) == "true"
    end
    return defaultBool == true
end

--- Writes a boolean flag to PersistentDB as 1 or 0.
function DB.setBool(key, boolVal)
    DB.set(key, boolVal and 1 or 0)
end

--- Parses a pipe/comma/newline-delimited string into a boolean set { [key] = true }.
function DB.deserializeSetMap(raw)
    local map = {}
    if type(raw) ~= "string" or raw == "" then
        return map
    end
    for token in string.gmatch(raw, "[^|,\r\n]+") do
        if token ~= "" then
            map[token] = true
        end
    end
    return map
end

--- Serializes a boolean set { [key] = true } into a sorted pipe-delimited string.
function DB.serializeSetMap(map)
    if not map then return "" end
    local list = {}
    for k, v in pairs(map) do
        if v and type(k) == "string" and k ~= "" then
            table.insert(list, k)
        end
    end
    table.sort(list)
    return table.concat(list, "|")
end

--- Parses a semicolon/newline-delimited "key=count;key2=count2" string into { [key] = number }.
function DB.deserializeCountMap(raw)
    local map = {}
    if type(raw) ~= "string" or raw == "" then
        return map
    end
    for token in string.gmatch(raw, "[^;\r\n]+") do
        local k, v = string.match(token, "^([^=]+)=(-?%d+)$")
        if k and v then
            map[k] = tonumber(v) or 0
        end
    end
    return map
end

--- Serializes a { [key] = count } table into a sorted "key=count;key2=count2" string.
function DB.serializeCountMap(map)
    if not map then return "" end
    local list = {}
    for k, v in pairs(map) do
        if type(k) == "string" and type(v) == "number" then
            table.insert(list, k .. "=" .. tostring(math.floor(v)))
        end
    end
    table.sort(list)
    return table.concat(list, ";")
end

--- Parses "colName::artName|colName2::artName2" into a nested map { [colName] = { [artName] = true } }.
function DB.deserializeSubmittedMap(raw)
    local map = {}
    if type(raw) ~= "string" or raw == "" then
        return map
    end
    for token in string.gmatch(raw, "[^|]+") do
        local colName, artName = string.match(token, "^(.-)::(.+)$")
        if colName and artName and colName ~= "" and artName ~= "" then
            if not map[colName] then
                map[colName] = {}
            end
            map[colName][artName] = true
        end
    end
    return map
end

--- Serializes a nested map { [colName] = { [artName] = true } } into "colName::artName|...".
function DB.serializeSubmittedMap(map)
    if not map then return "" end
    local list = {}
    for colName, arts in pairs(map) do
        if type(arts) == "table" then
            for artName, v in pairs(arts) do
                if v then
                    table.insert(list, colName .. "::" .. artName)
                end
            end
        end
    end
    table.sort(list)
    return table.concat(list, "|")
end

return DB
