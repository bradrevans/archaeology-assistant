-- core/utils.lua
-- Shared string normalization, text cleaning, table helpers, and UI text utilities.
-- Eliminates duplicate normalization and comparison logic across data, tracker, and UI modules.

local Utils = {}

--- Strips RS3 <col=...> markup and arbitrary HTML/XML-like tags from a string.
function Utils.stripTags(value)
    if not value then return "" end
    local s = tostring(value)
    s = string.gsub(s, "<col=[^>]+>", "")
    s = string.gsub(s, "</col>", "")
    s = string.gsub(s, "<[^>]+>", "")
    return s
end

--- Replaces UTF-8 non-breaking spaces (\194\160 and \160) with standard spaces and collapses runs.
function Utils.cleanSpaces(value)
    if not value then return "" end
    local s = tostring(value)
    s = string.gsub(s, "\194\160", " ")
    s = string.gsub(s, "\160", " ")
    s = string.gsub(s, "%s+", " ")
    return s
end

--- Trims leading and trailing whitespace from a string.
function Utils.trim(value)
    if not value then return "" end
    local s = tostring(value)
    return string.match(s, "^%s*(.-)%s*$") or s
end

--- Cleans tags, non-breaking spaces, and outer whitespace while preserving original casing.
function Utils.cleanText(value)
    if not value then return "" end
    return Utils.trim(Utils.cleanSpaces(Utils.stripTags(value)))
end

--- Canonical case-insensitive normalization for item, material, artefact, collector, and hotspot names.
function Utils.normalizeName(name)
    if not name then return "" end
    return string.lower(Utils.cleanText(name))
end

--- Extracts the base artefact name and whether the name carried a (damaged) or (unpowered) suffix.
function Utils.extractDamagedBaseName(rawName)
    local norm = Utils.normalizeName(rawName)
    local base = string.match(norm, "^(.-)%s*%(damaged%)$")
    if base then
        return Utils.trim(base), true
    end
    local unpowered = string.match(norm, "^(.-)%s*%(unpowered%)$")
    if unpowered then
        return Utils.trim(unpowered), true
    end
    return norm, false
end

--- Escapes Lua pattern magic characters so a literal string can be safely used in string.find/match/gsub.
function Utils.escapePattern(text)
    if not text then return "" end
    return (string.gsub(tostring(text), "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

--- Clamps a numeric value between low and high.
function Utils.clamp(val, low, high)
    if val < low then return low end
    if val > high then return high end
    return val
end

--- Formats a number as a rounded integer with thousands commas (e.g. 12345 -> "12,345").
function Utils.formatInt(n)
    local num = math.floor((tonumber(n) or 0) + 0.5)
    local s = tostring(num)
    local k
    while true do
        s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return s
end

--- Counts how many keys in a { [name] = count } map have a positive numeric count.
function Utils.countMapEntries(map)
    if not map then return 0 end
    local n = 0
    for _, count in pairs(map) do
        if type(count) == "number" and count > 0 then
            n = n + 1
        elseif count == true then
            n = n + 1
        end
    end
    return n
end

--- Compares two { [name] = count } maps for exact positive-value equality.
function Utils.mapsEqual(a, b)
    if a == b then return true end
    if not a or not b then return false end
    for k, v in pairs(a) do
        if v > 0 and (b[k] or 0) ~= v then
            return false
        end
    end
    for k, v in pairs(b) do
        if v > 0 and (a[k] or 0) ~= v then
            return false
        end
    end
    return true
end

--- Creates a shallow copy of a table with positive numeric counts.
function Utils.clonePositiveMap(src)
    local dst = {}
    if not src then return dst end
    for k, v in pairs(src) do
        if type(v) == "number" and v > 0 then
            dst[k] = v
        end
    end
    return dst
end

--- Safely extracts text content from an RS3 UI component across `.text`, `.content`, `.label`, or `.name`.
function Utils.getComponentText(comp)
    if not comp then return "" end
    for _, prop in ipairs({ "text", "content", "label", "name" }) do
        local ok, val = pcall(function() return comp[prop] end)
        if ok and type(val) == "string" and val ~= "" then
            return val
        end
    end
    return ""
end

--- Returns true if a raw UI text string contains strikethrough tags (<str> or <s>).
function Utils.isStrikeText(txt)
    if not txt or txt == "" then return false end
    local lower = string.lower(txt)
    return string.find(lower, "<str", 1, true) ~= nil
        or string.find(lower, "</str>", 1, true) ~= nil
        or string.find(lower, "<s>", 1, true) ~= nil
        or string.find(lower, "</s>", 1, true) ~= nil
end

return Utils
