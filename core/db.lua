-- core/db.lua
-- Single-responsibility wrapper around RS3's PersistentDB API and deterministic map serialization.

local DB = {}

local GLOBAL_KEYS = {
    arch_win_x = true,
    arch_win_y = true,
    arch_win_w = true,
    arch_win_h = true,
    arch_win_visible = true,
    arch_active_tab = true,
    arch_spots_enabled = true,
    arch_last_error = true,
    arch_legacy_migrated = true,
}

local LEGACY_ACCOUNT_KEYS = {
    "arch_include_mode",
    "arch_art_filter",
    "arch_src_bag",
    "arch_src_storage",
    "arch_src_bank",
    "arch_src_workbench",
    "arch_src_bob",
    "arch_filter_by_level_init",
    "arch_filter_by_level",
    "arch_player_level",
    "arch_is_pinned",
    "arch_excluded_artefacts",
    "arch_custom_art_counts",
    "arch_pinned_artefacts",
    "arch_bank_artefacts",
    "arch_workbench_artefacts",
    "arch_workbench_inv_id",
    "arch_workbench_synced",
    "arch_bank_restored",
    "arch_completed_collections",
    "arch_targeted_collections",
    "arch_col_remembered_counts",
    "arch_submitted_artefacts",
    "arch_scanned_collectors",
    "arch_storage_materials",
    "arch_bank_materials",
    "arch_bob_materials",
    "arch_bob_artefacts",
    "arch_bob_inv_id",
    "arch_storage_inv_id",
    "arch_bank_inv_id",
    "arch_storage_synced",
    "arch_bank_synced",
    "arch_board_has_cache",
    "arch_source_mode_idx",
    "arch_include_dupes",
    "arch_short_only",
}

local activeAccountKey = nil

local function getRaw(key)
    if PersistentDB then
        local ok, val = pcall(function() return PersistentDB:Get(key) end)
        if ok and val ~= nil then
            return val
        end
    end
    return nil
end

local function setRaw(key, val)
    if PersistentDB then
        pcall(function() PersistentDB:Set(key, val) end)
    end
end

function DB.detectAccountKey()
    local rawName = nil
    pcall(function()
        if Player then
            if Player.GetName then
                local n = Player.GetName()
                if type(n) == "string" and n ~= "" then rawName = n end
            end
            if not rawName and Player.GetDisplayName then
                local n = Player.GetDisplayName()
                if type(n) == "string" and n ~= "" then rawName = n end
            end
        end
        if not rawName then
            local pEntity = (Player and Player.GetEntity and Player.GetEntity())
                or (PlayerList and PlayerList.Self and PlayerList.Self())
            if pEntity then
                if type(pEntity.name) == "string" and pEntity.name ~= "" then
                    rawName = pEntity.name
                elseif type(pEntity.displayName) == "string" and pEntity.displayName ~= "" then
                    rawName = pEntity.displayName
                elseif pEntity.GetName then
                    local okN, n = pcall(function() return pEntity:GetName() end)
                    if okN and type(n) == "string" and n ~= "" then rawName = n end
                end
            end
        end
    end)
    if not rawName then return nil end
    local cleaned = string.lower(string.gsub(rawName, "\194\160", " "))
    cleaned = string.gsub(cleaned, "<[^>]+>", "")
    cleaned = string.match(cleaned, "^%s*(.-)%s*$") or cleaned
    cleaned = string.gsub(cleaned, "[^%w]+", "_")
    cleaned = string.gsub(cleaned, "^_+", "")
    cleaned = string.gsub(cleaned, "_+$", "")
    if cleaned == "" then return nil end
    return cleaned
end

local function migrateLegacyDataIfNeeded(acctKey)
    if not acctKey or getRaw("arch_legacy_migrated") ~= nil then
        return
    end
    local hasLegacy = false
    for _, k in ipairs(LEGACY_ACCOUNT_KEYS) do
        local v = getRaw(k)
        if v ~= nil and v ~= "" and v ~= 0 then
            hasLegacy = true
            break
        end
    end
    if hasLegacy then
        local prefix = "acct:" .. acctKey .. ":"
        for _, k in ipairs(LEGACY_ACCOUNT_KEYS) do
            local v = getRaw(k)
            if v ~= nil then
                setRaw(prefix .. k, v)
            end
        end
    end
    setRaw("arch_legacy_migrated", acctKey)
end

function DB.setActiveAccount(acctKey)
    activeAccountKey = acctKey
    if acctKey then
        migrateLegacyDataIfNeeded(acctKey)
    end
    return activeAccountKey
end

function DB.getActiveAccount()
    return activeAccountKey
end

function DB.refreshAccount()
    local detected = DB.detectAccountKey()
    if detected then
        DB.setActiveAccount(detected)
    end
    return activeAccountKey
end

local function resolveStorageKey(key)
    if GLOBAL_KEYS[key] then
        return key
    end
    if not activeAccountKey then
        return nil
    end
    return "acct:" .. activeAccountKey .. ":" .. key
end

--- Safely reads a key from PersistentDB, returning defaultVal if unavailable or unset.
function DB.get(key, defaultVal)
    local storageKey = resolveStorageKey(key)
    if not storageKey then
        return defaultVal
    end
    local val = getRaw(storageKey)
    if val ~= nil then
        return val
    end
    return defaultVal
end

--- Safely writes a key/value pair to PersistentDB.
function DB.set(key, val)
    local storageKey = resolveStorageKey(key)
    if not storageKey then
        return
    end
    setRaw(storageKey, val)
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
