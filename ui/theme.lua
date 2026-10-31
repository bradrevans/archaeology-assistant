-- ui/theme.lua
-- Shared colour palette, layout constants, font resolution, text measurement,
-- and screen-scaling utilities used across ui/window.lua, ui/overlay.lua, and ui/tooltip.lua.

local Utils = require("core/utils")

local Theme = {}

--- Creates a Vector4 RGBA colour (or fallback table when Vector4 is unavailable).
function Theme.makeColour(r, g, b, a)
    if Vector4 and Vector4.new then
        return Vector4.new(r, g, b, a or 1.0)
    end
    return { r = r, g = g, b = b, a = a or 1.0 }
end

-- Core Text & Accent Colours
Theme.COL_WHITE        = Theme.makeColour(0.95, 0.95, 0.95, 1.0)
Theme.COL_CREAM        = Theme.makeColour(0.91, 0.84, 0.69, 1.0)
Theme.COL_MUTED        = Theme.makeColour(0.72, 0.76, 0.80, 1.0)
Theme.COL_GOLD         = Theme.makeColour(1.00, 0.82, 0.28, 1.0)
Theme.COL_GREEN        = Theme.makeColour(0.30, 0.92, 0.45, 1.0)
Theme.COL_AMBER        = Theme.makeColour(1.00, 0.72, 0.24, 1.0)
Theme.COL_RED          = Theme.makeColour(1.00, 0.40, 0.40, 1.0)
Theme.COL_CYAN         = Theme.makeColour(0.38, 0.86, 1.00, 1.0)

-- Window & Table Backgrounds
Theme.COL_BG_CARD      = Theme.makeColour(0.07, 0.10, 0.14, 0.72)
Theme.COL_BG_HEADER    = Theme.makeColour(0.10, 0.14, 0.19, 0.85)
Theme.COL_BG_ROW       = Theme.makeColour(0.08, 0.11, 0.15, 0.55)
Theme.COL_BG_ALT       = Theme.makeColour(0.13, 0.17, 0.22, 0.55)
Theme.COL_BG_TOOLTIP   = Theme.makeColour(0.05, 0.08, 0.12, 0.96)
Theme.COL_BTN_STEP     = Theme.makeColour(0.18, 0.24, 0.32, 0.90)
Theme.COL_DARK_TEXT    = Theme.makeColour(0.08, 0.08, 0.08, 1.0)

-- Sync Badge Backgrounds
Theme.COL_SYNC_READY   = Theme.makeColour(0.08, 0.24, 0.13, 0.72)
Theme.COL_SYNC_CACHED  = Theme.makeColour(0.28, 0.20, 0.06, 0.78)
Theme.COL_SYNC_MISSING = Theme.makeColour(0.34, 0.11, 0.10, 0.82)

-- 3D World Overlay Palette
Theme.COL_GOLD_OUTLINE  = Theme.makeColour(1.00, 0.82, 0.28, 0.92)
Theme.COL_GOLD_FILL     = Theme.makeColour(1.00, 0.82, 0.28, 0.18)
Theme.COL_CYAN_OUTLINE  = Theme.makeColour(0.22, 0.86, 1.00, 0.95)
Theme.COL_CYAN_FILL     = Theme.makeColour(0.22, 0.86, 1.00, 0.24)
Theme.COL_GREEN_OUTLINE = Theme.makeColour(0.30, 0.92, 0.45, 0.75)
Theme.COL_GREEN_FILL    = Theme.makeColour(0.30, 0.92, 0.45, 0.10)
Theme.COL_CARD_BG       = Theme.makeColour(0.06, 0.09, 0.13, 0.88)

-- Window & Table Sizing Constants
Theme.DEFAULT_X = 32
Theme.DEFAULT_Y = 70
Theme.DEFAULT_W = 600
Theme.DEFAULT_H = 470
Theme.MIN_W     = 540
Theme.MIN_H     = 300

Theme.MAX_MATERIAL_ROWS   = 52
Theme.MAX_ARTEFACT_ROWS   = 45
Theme.MAX_COLLECTION_ROWS = 80
Theme.ROW_HEIGHT          = 24
Theme.BADGE_W             = 42

Theme.BANK_ICON_OBJ_ID    = 995
Theme.STORAGE_ICON_OBJ_ID = 49429
Theme.BOARD_ICON_OBJ_ID   = 49430

-- Font & Text Measurement
local cachedBodyFont = nil
local cachedFontChecked = false

function Theme.getBodyFont()
    if not cachedFontChecked then
        cachedFontChecked = true
        pcall(function()
            if FontType and FontType.Find and id and id.Font then
                cachedBodyFont = FontType.Find(id.Font.MUSEO_SANS_15PT_REGULAR)
            end
            if not cachedBodyFont and config and config.FontType and config.FontType.Find and id and id.Font then
                cachedBodyFont = config.FontType.Find(id.Font.MUSEO_SANS_15PT_REGULAR)
            end
            if not cachedBodyFont and config and config.Font then
                cachedBodyFont = config.Font.MUSEO_SANS_15PT_REGULAR
                    or (config.Font.FromID and id and id.Font and config.Font.FromID(id.Font.MUSEO_SANS_15PT_REGULAR))
                    or (config.Font.Find and id and id.Font and config.Font.Find(id.Font.MUSEO_SANS_15PT_REGULAR))
            end
            if not cachedBodyFont and Font and Font.Find and id and id.Font then
                cachedBodyFont = Font.Find(id.Font.MUSEO_SANS_15PT_REGULAR)
            end
        end)
    end
    return cachedBodyFont
end

local function getCharPxWidth(c)
    local b = string.byte(c)
    if not b then return 8 end
    if b >= 65 and b <= 90 then
        if c == "W" or c == "M" then return 13 end
        if c == "I" or c == "J" then return 5 end
        return 10.5
    elseif b >= 97 and b <= 122 then
        if c == "w" or c == "m" then return 11 end
        if c == "i" or c == "l" or c == "j" or c == "t" or c == "f" then return 4.5 end
        if c == "r" then return 5.5 end
        return 8.0
    elseif b >= 48 and b <= 57 then
        return 8.5
    elseif c == " " then
        return 5.0
    elseif c == "." or c == "," or c == ":" or c == ";" or c == "!" or c == "'" then
        return 3.5
    elseif c == "-" or c == "(" or c == ")" or c == "[" or c == "]" or c == "/" then
        return 5.5
    elseif c == "|" then
        return 4.5
    else
        return 8.0
    end
end

local wordWidthCache = {}

function Theme.getStringPxWidth(str)
    if not str or str == "" then return 0 end
    local cached = wordWidthCache[str]
    if cached then return cached end
    local font = Theme.getBodyFont()
    if font and font.GetStringWidth then
        local ok, w = pcall(function() return font:GetStringWidth(str, false) end)
        if ok and type(w) == "number" and w >= 0 then
            wordWidthCache[str] = w
            return w
        end
    end
    local w = 0
    for i = 1, #str do
        local c = string.sub(str, i, i)
        w = w + getCharPxWidth(c)
    end
    wordWidthCache[str] = w
    return w
end

local cachedLineHeight = nil

function Theme.getLineHeight()
    if cachedLineHeight then return cachedLineHeight end
    cachedLineHeight = 19
    local font = Theme.getBodyFont()
    if font then
        pcall(function()
            local h = font.lineHeight or (font.GetLineHeight and font:GetLineHeight())
            if type(h) == "number" and h >= 12 and h <= 30 then
                cachedLineHeight = math.ceil(h)
            end
        end)
    end
    return cachedLineHeight
end

function Theme.countWrappedLines(text, width)
    local font = Theme.getBodyFont()
    if font and font.GetStringLineCount then
        local ok, count = pcall(font.GetStringLineCount, font, text, width, false, false, false)
        if ok and type(count) == "number" and count >= 1 then
            return math.floor(count)
        end
    end
    local limit = math.max(60, width)
    if Theme.getStringPxWidth(text) <= limit then
        return 1
    end
    local spaceW = 5.0
    local lines, curW = 1, 0
    for word in string.gmatch(text, "%S+") do
        local wordW = Theme.getStringPxWidth(word)
        if curW == 0 then
            curW = wordW
        elseif curW + spaceW + wordW <= limit then
            curW = curW + spaceW + wordW
        else
            lines = lines + 1
            curW = wordW
        end
    end
    return lines
end

local wrapHeightCache = {}

function Theme.measureWrappedTextHeight(text, wrapWidth)
    local lineH = Theme.getLineHeight()
    if type(text) ~= "string" or text == "" then
        return lineH + 4
    end
    local w = math.max(80, math.floor((wrapWidth or 380) / 4) * 4)
    local cacheKey = tostring(w) .. "|" .. text
    local cached = wrapHeightCache[cacheKey]
    if cached then
        return cached
    end
    local h = Theme.countWrappedLines(text, w) * lineH + 4
    wrapHeightCache[cacheKey] = h
    return h
end

function Theme.getInterfaceScale()
    local ok, scale = pcall(function()
        local options = game and game.options
        local interfaceScale = options and options.InterfaceScale
        local percent = interfaceScale and tonumber(interfaceScale.setting) or 100
        if percent <= 0 then percent = 100 end
        return percent / 100
    end)
    if ok and type(scale) == "number" and scale > 0 then
        return scale
    end
    return 1.0
end

function Theme.getScaledMousePos(fallbackX, fallbackY)
    if Mouse and Mouse.GetPosition then
        local ok, raw = pcall(Mouse.GetPosition)
        if ok and raw and type(raw.x) == "number" and type(raw.y) == "number" then
            local scale = Theme.getInterfaceScale()
            return raw.x / scale, raw.y / scale
        end
    end
    return fallbackX or 0, fallbackY or 0
end

function Theme.resolveParent()
    if not ui or not ui.Interfaces or not id or not id.Component then
        return nil
    end
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
        or ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
end

function Theme.setComponentHidden(comp, hidden)
    if not comp then return end
    pcall(function() comp.hidden = hidden end)
end

function Theme.bindItemSprite(iconComp, objId, quantity)
    if not iconComp then return false end
    objId = tonumber(objId)
    if not objId or objId <= 0 then
        iconComp.hidden = true
        return false
    end
    local ok = pcall(function()
        iconComp:SetAssociatedObject(math.tointeger(objId) or objId)
        iconComp.associatedObjectQuantity = quantity or 1
        if ui.ObjectQuantityDisplayMode then
            iconComp.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
        end
    end)
    iconComp.hidden = not ok
    return ok
end

return Theme
