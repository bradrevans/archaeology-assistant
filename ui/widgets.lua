-- ui/widgets.lua
-- Reusable UI component factories (PrettyUI 9-slice content frames, RS3 tab buttons,
-- toolbar buttons, sync badges, and table row builders) extracted from ui/window.lua
-- to keep UI modules modular, DRY, and strictly powered by PrettyUI's component/sprite system.

local Utils = require("core/utils")
local Theme = require("ui/theme")

local Widgets = {}

local function getPrettyUI()
    return prettyui or Theme.prettyui
end

local function getSprites()
    local p = getPrettyUI()
    return (p and p.Sprites) or Theme.Sprites
end

--- Creates a single-line or multi-line UI text component with standard Museo Sans 15pt styling.
function Widgets.createText(parent, colour, x, y, w, h, content, relX, relY, relW, relH)
    local txt = ui.Text.new(parent)
    txt.font = id.Font.MUSEO_SANS_15PT_REGULAR
    txt.colour = colour or Theme.COL_WHITE
    txt.maxLines = 1
    txt.clickthrough = true
    if content then
        txt.content = content
    end
    txt:SetPos(x or 0, y or 0, relX or 0, relY or 0)
    txt:SetSize(w or 50, h or 20, relW or 0, relH or 0)
    return txt
end

--- Creates a wrapping multi-line text component for summary banners.
function Widgets.createWrappingText(parent, colour, x, y)
    local txt = ui.Text.new(parent)
    txt.font = id.Font.MUSEO_SANS_15PT_REGULAR
    txt.colour = colour
    txt.maxLines = 0
    if ui.AlignMode then
        pcall(function()
            txt.alignHorizontal = ui.AlignMode.TOPLEFT
            txt.alignVertical = ui.AlignMode.CENTRE
        end)
    end
    txt:SetPos(x, y)
    txt:SetSize(-28, 20, 1.0, 0)
    return txt
end

--- Creates a PrettyUI 9-slice RS3 content frame (`Sprites.CONTENT_FRAME` = `RS3_CONTENT_FRAME_0..8`)
--- with relative sizing so calling `frame:SetPos` / `frame:SetSize` automatically scales all 9 slices.
function Widgets.createContentFrame(parent, x, y, w, h, relW, relH, clickthrough)
    local root = ui.Layer.new(parent)
    root.clickthrough = (clickthrough == true)
    root:SetPos(x or 0, y or 0)
    root:SetSize(w or 100, h or 40, relW or 0, relH or 0)

    local Sprites = getSprites()
    local cf = Sprites and Sprites.CONTENT_FRAME
    local centreSprite = cf and (cf.centre or cf.center)
    if cf and centreSprite then
        local b = cf.BORDER_SIZE or 10
        local function slice(spriteId, sx, sy, sw, sh, rx, ry, rw, rh, tiled)
            local s = ui.Sprite.new(root)
            s.spriteID = spriteId
            s.isTiling = (tiled == true)
            s.clickthrough = true
            s:SetPos(sx, sy, rx or 0, ry or 0)
            s:SetSize(sw, sh, rw or 0, rh or 0)
            return s
        end

        slice(centreSprite,   b,  b, -b * 2, -b * 2, 0,   0,   1.0, 1.0, true)
        slice(cf.top,         b,  0, -b * 2,  b,     0,   0,   1.0, 0,   true)
        slice(cf.bottom,      b, -b, -b * 2,  b,     0,   1.0, 1.0, 0,   true)
        slice(cf.left,        0,  b,  b,     -b * 2, 0,   0,   0,   1.0, true)
        slice(cf.right,      -b,  b,  b,     -b * 2, 1.0, 0,   0,   1.0, true)
        slice(cf.topLeft,     0,  0,  b,      b,     0,   0,   0,   0,   false)
        slice(cf.topRight,   -b,  0,  b,      b,     1.0, 0,   0,   0,   false)
        slice(cf.bottomLeft,  0, -b,  b,      b,     0,   1.0, 0,   0,   false)
        slice(cf.bottomRight,-b, -b,  b,      b,     1.0, 1.0, 0,   0,   false)

        return root
    end

    local fallback = ui.Rectangle.new(root)
    fallback.colour = Theme.COL_BG_CARD
    fallback.fill = true
    fallback.clickthrough = true
    fallback:SetPos(0, 0)
    fallback:SetSize(0, 0, 1.0, 1.0)
    return root
end

--- Creates a PrettyUI horizontal divider (`prettyui.Divider` or `Sprites.DIVIDER`).
function Widgets.createDivider(parent, x, y, w, relW)
    local pui = getPrettyUI()
    local Sprites = getSprites()
    if pui and pui.Divider and pui.Divider.new then
        local ok, div = pcall(function()
            return pui.Divider.new(parent, {
                x = x or 8,
                y = y or 32,
                width = w or -16,
                widthAnchor = relW or 1.0
            })
        end)
        if ok and div and div.root then
            return div.root
        end
    end
    if Sprites and Sprites.DIVIDER then
        local s = ui.Sprite.new(parent)
        s.spriteID = Sprites.DIVIDER
        s.isTiling = true
        s.clickthrough = true
        s:SetPos(x or 8, y or 32)
        s:SetSize(w or -16, 4, relW or 1.0, 0)
        return s
    end
    local r = ui.Rectangle.new(parent)
    r.colour = Theme.COL_GOLD
    r.fill = true
    r.clickthrough = true
    r:SetPos(x or 8, y or 32)
    r:SetSize(w or -16, 1, relW or 1.0, 0)
    return r
end

--- Creates a PrettyUI `SimpleButton` (`RS3_BTN_ICON_RESIZABLE_*`) for top view tabs (`Collections`, `Artefacts`, `Materials`).
function Widgets.createTabButton(parent, label, tooltipText, onClick, onWheelFn)
    local btn = Widgets.createToolbarButton(parent, label, tooltipText, true, onClick, onWheelFn)
    local origSetActive = btn.setActive
    btn.setActive = function(active)
        origSetActive(active)
        if btn.widget and btn.widget.content then
            btn.widget.content.colour = active and Theme.COL_GOLD or Theme.COL_CREAM
        end
    end
    return btn
end

--- Creates a PrettyUI `SimpleButton` (`RS3_BTN_ICON_RESIZABLE_*`) or native fallback toolbar button.
function Widgets.createToolbarButton(parent, label, tooltipText, toggleable, onClick, onWheelFn, width, height)
    local pui = getPrettyUI()
    local btnW = width or 90
    local btnH = height or 26
    if pui and pui.SimpleButton then
        local btn = pui.SimpleButton.new(parent, tostring(label or ""), function()
            if onClick then onClick() end
        end, {
            x = 0,
            y = 6,
            width = btnW,
            height = btnH,
            toggleable = toggleable == true,
            tooltip = tooltipText,
            _onScrollWheel = onWheelFn
        })
        return {
            isPretty = true,
            widget = btn,
            root = btn.root,
            setLabel = function(newText)
                local safeText = tostring(newText or "")
                if btn.content and btn.content.content ~= safeText then
                    btn.content.content = safeText
                end
            end,
            setActive = function(active)
                if btn.SetActive then
                    btn:SetActive(active == true)
                end
            end,
            setDisabled = function(disabled)
                if btn.SetDisabled then
                    btn:SetDisabled(disabled == true)
                end
            end,
            setHidden = function(hidden)
                if btn.root then
                    btn.root.hidden = (hidden == true)
                end
            end,
            setBounds = function(x, y, w, h, relX, relY, relW, relH)
                btn.root:SetPos(x, y, relX or 0, relY or 0)
                btn.root:SetSize(w, h, relW or 0, relH or 0)
            end
        }
    end

    local btn = ui.Button.new(parent)
    btn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    btn:SetPos(0, 6)
    btn:SetSize(btnW, btnH)
    btn.label = label
    if onClick then
        btn:Subscribe(ui.Hook.ONBUTTONPRESSED, onClick)
    end
    if onWheelFn and ui and ui.Hook and ui.Hook.ONSCROLLWHEEL then
        btn:Subscribe(ui.Hook.ONSCROLLWHEEL, onWheelFn)
    end
    return {
        isPretty = false,
        widget = btn,
        root = btn,
        setLabel = function(newText)
            btn.label = newText
        end,
        setActive = function() end,
        setDisabled = function(disabled)
            btn.enabled = not (disabled == true)
        end,
        setHidden = function(hidden)
            btn.hidden = (hidden == true)
        end,
        setBounds = function(x, y, w, h, relX, relY, relW, relH)
            btn:SetPos(x, y, relX or 0, relY or 0)
            btn:SetSize(w, h, relW or 0, relH or 0)
        end
    }
end

--- Creates a compact Storage or Bank sync status badge framed with PrettyUI's item slot sprite (`RS3_ICON_SLOT_40PX_0`).
function Widgets.createSyncBadge(container, fallbackLabel, iconObjId, bindRowHover, onHoverFn, onClickFn)
    local Sprites = getSprites()
    local root = ui.Layer.new(container)
    root.clickthrough = false
    root:SetPos(0, 36)
    root:SetSize(Theme.BADGE_W, 26)

    local slotBg = nil
    if Sprites and Sprites.ITEM_SLOT_BACKGROUND then
        slotBg = ui.Sprite.new(root)
        slotBg.spriteID = Sprites.ITEM_SLOT_BACKGROUND
        slotBg.clickthrough = (onClickFn == nil)
        slotBg:SetPos(0, 0)
        slotBg:SetSize(0, 0, 1.0, 1.0)
    else
        slotBg = Widgets.createContentFrame(root, 0, 0, 0, 0, 1.0, 1.0, onClickFn == nil)
    end

    local statusBar = ui.Rectangle.new(root)
    statusBar.colour = Theme.COL_RED
    statusBar.fill = true
    statusBar.clickthrough = true
    statusBar:SetPos(2, -3, 0, 1.0)
    statusBar:SetSize(-4, 2, 1.0, 0)

    if onClickFn and ui and ui.Hook and ui.Hook.ONCLICK then
        root:Subscribe(ui.Hook.ONCLICK, function()
            onClickFn()
            return false
        end)
    end

    local icon = ui.Sprite.new(root)
    icon.clickthrough = true
    icon:SetPos(4, 1)
    icon:SetSize(28, 22)
    icon.hidden = true

    local txt = Widgets.createText(root, Theme.COL_WHITE, 2, 0, -12, 0, fallbackLabel, 0, 0, 1.0, 1.0)
    if ui.AlignMode then
        pcall(function()
            txt.alignHorizontal = ui.AlignMode.CENTRE
            txt.alignVertical = ui.AlignMode.CENTRE
        end)
    end

    local dotOutline = ui.Rectangle.new(root)
    dotOutline.colour = Theme.makeColour(0, 0, 0, 0.9)
    dotOutline.fill = true
    dotOutline.clickthrough = true
    dotOutline:SetPos(-11, 2, 1.0, 0)
    dotOutline:SetSize(9, 9)

    local dot = ui.Rectangle.new(root)
    dot.colour = Theme.COL_RED
    dot.fill = true
    dot.clickthrough = true
    dot:SetPos(-10, 3, 1.0, 0)
    dot:SetSize(7, 7)

    bindRowHover(root, onHoverFn)

    local currentObjId = nil
    local function setIcon(objId)
        objId = tonumber(objId)
        if objId == currentObjId then return end
        local ok = Theme.bindItemSprite(icon, objId, 10000)
        currentObjId = ok and objId or nil
        txt.hidden = ok
    end
    setIcon(iconObjId)

    return {
        root = root,
        bg = slotBg,
        setIcon = setIcon,
        setBounds = function(x, y, w, h)
            root:SetPos(x, y)
            root:SetSize(w, h)
        end,
        setState = function(state)
            local alpha = 1.0
            if state == "ignored" then
                statusBar.colour = Theme.COL_MUTED
                dot.colour = Theme.COL_MUTED
                txt.colour = Theme.COL_MUTED
                alpha = 0.4
            elseif state == "synced" then
                statusBar.colour = Theme.COL_GREEN
                dot.colour = Theme.COL_GREEN
                txt.colour = Theme.COL_GREEN
            elseif state == "cached" then
                statusBar.colour = Theme.COL_AMBER
                dot.colour = Theme.COL_AMBER
                txt.colour = Theme.COL_AMBER
            else
                statusBar.colour = Theme.COL_RED
                dot.colour = Theme.COL_RED
                txt.colour = Theme.COL_RED
            end
            pcall(function() icon.alpha = alpha end)
        end
    }
end

--- Creates the Collections-tab Collector Sync status button (`Collectors: X/13`) using `prettyui.SimpleButton`.
function Widgets.createCollectorSyncPill(container, bindRowHover, onHoverFn, onClickFn, onWheelFn)
    local root = ui.Layer.new(container)
    root.clickthrough = false
    root:SetPos(0, 36)
    root:SetSize(115, 26)

    local btn = Widgets.createToolbarButton(
        root,
        "Collectors",
        nil,
        false,
        onClickFn,
        onWheelFn
    )
    btn.setBounds(0, 0, 115, 26)

    local dotOutline = ui.Rectangle.new(root)
    dotOutline.colour = Theme.makeColour(0.04, 0.04, 0.04, 0.9)
    dotOutline.fill = true
    dotOutline.clickthrough = true
    dotOutline:SetPos(-11, 3, 1.0, 0)
    dotOutline:SetSize(8, 8)

    local dot = ui.Rectangle.new(root)
    dot.colour = Theme.COL_RED
    dot.fill = true
    dot.clickthrough = true
    dot:SetPos(-10, 4, 1.0, 0)
    dot:SetSize(6, 6)

    bindRowHover(root, onHoverFn)
    if btn.root and btn.root ~= root then
        bindRowHover(btn.root, onHoverFn)
    end

    return {
        root = root,
        dot = dot,
        setBounds = function(x, y, w, h)
            root:SetPos(x, y)
            root:SetSize(w, h)
            btn.setBounds(0, 0, w, h)
        end,
        setHidden = function(hidden)
            root.hidden = (hidden == true)
            btn.setHidden(hidden)
        end,
        setStatus = function(syncedCount, totalCount, liveCount)
            btn.setLabel(string.format("Collectors: %d/%d", syncedCount or 0, totalCount or 13))
            if (liveCount or 0) == totalCount and (totalCount or 0) > 0 then
                dot.colour = Theme.COL_GREEN
                if btn.widget and btn.widget.content then
                    btn.widget.content.colour = Theme.COL_GREEN
                end
            elseif (syncedCount or 0) > 0 then
                dot.colour = Theme.COL_AMBER
                if btn.widget and btn.widget.content then
                    btn.widget.content.colour = Theme.COL_AMBER
                end
            else
                dot.colour = Theme.COL_RED
                if btn.widget and btn.widget.content then
                    btn.widget.content.colour = Theme.COL_RED
                end
            end
        end
    }
end

--- Creates a prominent in-UI alert banner for unsynced collectors, Material Storage, or Bank.
function Widgets.createSyncNoticeBanner(container, forwardScrollWheel)
    local root = ui.Layer.new(container)
    root.clickthrough = false
    root:SetPos(8, 66)
    root:SetSize(-16, 48, 1.0, 0)
    root.hidden = true
    if forwardScrollWheel then forwardScrollWheel(root) end

    local bg = ui.Rectangle.new(root)
    bg.colour = Theme.COL_SYNC_MISSING
    bg.fill = true
    bg.clickthrough = true
    bg:SetPos(0, 0)
    bg:SetSize(0, 0, 1.0, 1.0)

    local frame = Widgets.createContentFrame(root, 0, 0, 0, 0, 1.0, 1.0, true)
    if forwardScrollWheel then forwardScrollWheel(frame) end

    local accent = ui.Rectangle.new(root)
    accent.colour = Theme.COL_RED
    accent.fill = true
    accent.clickthrough = true
    accent:SetPos(2, 2)
    accent:SetSize(4, -4, 0, 1.0)

    local title = Widgets.createText(root, Theme.COL_RED, 12, 5, -20, 18, "", 0, 0, 1.0, 0)
    local body = Widgets.createWrappingText(root, Theme.COL_CREAM, 12, 24)
    body.clickthrough = true

    return {
        root = root,
        bg = bg,
        accent = accent,
        title = title,
        body = body,
        update = function(isVisible, severity, titleText, bodyText)
            root.hidden = not isVisible
            if not isVisible then return end
            if severity == "amber" then
                bg.colour = Theme.COL_SYNC_CACHED
                accent.colour = Theme.COL_AMBER
                title.colour = Theme.COL_AMBER
            else
                bg.colour = Theme.COL_SYNC_MISSING
                accent.colour = Theme.COL_RED
                title.colour = Theme.COL_RED
            end
            title.content = titleText or ""
            body.content = bodyText or ""
        end
    }
end

--- Creates a structured KPI stat tile with a 9-slice stone frame, top accent strip, centered label, and value.
function Widgets.createStatTile(container, forwardScrollWheel)
    local root = ui.Layer.new(container)
    root.clickthrough = false
    root:SetPos(8, 66)
    root:SetSize(160, 44)
    if forwardScrollWheel then forwardScrollWheel(root) end

    local bg = ui.Rectangle.new(root)
    bg.colour = Theme.COL_BG_CARD
    bg.fill = true
    bg.clickthrough = true
    bg:SetPos(0, 0)
    bg:SetSize(0, 0, 1.0, 1.0)

    local frame = Widgets.createContentFrame(root, 0, 0, 0, 0, 1.0, 1.0, true)
    if forwardScrollWheel then forwardScrollWheel(frame) end

    local accent = ui.Rectangle.new(root)
    accent.colour = Theme.COL_GOLD
    accent.fill = true
    accent.clickthrough = true
    accent:SetPos(3, 2)
    accent:SetSize(-6, 2, 1.0, 0)

    local label = Widgets.createText(root, Theme.COL_MUTED, 4, 5, -8, 16, "", 0, 0, 1.0, 0)
    local value = Widgets.createText(root, Theme.COL_GOLD, 4, 22, -8, 18, "", 0, 0, 1.0, 0)
    if ui.AlignMode then
        pcall(function()
            label.alignHorizontal = ui.AlignMode.CENTRE
            label.alignVertical = ui.AlignMode.CENTRE
            value.alignHorizontal = ui.AlignMode.CENTRE
            value.alignVertical = ui.AlignMode.CENTRE
        end)
    end

    return {
        root = root,
        accent = accent,
        label = label,
        value = value,
        setHidden = function(hidden)
            root.hidden = (hidden == true)
        end,
        setBounds = function(x, y, w, h)
            root:SetPos(x, y)
            root:SetSize(w, h)
        end,
        setData = function(lblText, valText, valColour, accentColour)
            label.content = lblText or ""
            value.content = valText or ""
            value.colour = valColour or Theme.COL_WHITE
            accent.colour = accentColour or valColour or Theme.COL_GOLD
        end
    }
end

--- Creates the subtle page subtitle/context strip shown directly above the table header.
function Widgets.createPageDescStrip(container, forwardScrollWheel)
    local root = ui.Layer.new(container)
    root.clickthrough = false
    root:SetPos(8, 114)
    root:SetSize(-16, 26, 1.0, 0)
    if forwardScrollWheel then forwardScrollWheel(root) end

    local bg = ui.Rectangle.new(root)
    bg.colour = Theme.COL_BG_ALT
    bg.fill = true
    bg.clickthrough = true
    bg:SetPos(0, 0)
    bg:SetSize(0, 0, 1.0, 1.0)

    local accent = ui.Rectangle.new(root)
    accent.colour = Theme.COL_GOLD
    accent.fill = true
    accent.clickthrough = true
    accent:SetPos(0, 0)
    accent:SetSize(3, 0, 0, 1.0)

    local text = Widgets.createWrappingText(root, Theme.COL_CREAM, 10, 3)
    text.clickthrough = true

    return {
        root = root,
        bg = bg,
        accent = accent,
        text = text,
        setContent = function(descText, textCol, accentCol)
            text.content = descText or ""
            text.colour = textCol or Theme.COL_CREAM
            accent.colour = accentCol or textCol or Theme.COL_GOLD
        end
    }
end

--- Builds a single row in the Collections table using `prettyui.Sprites.CHECKBOX_BUTTON` for `Track`
--- and a read-only `Done` status indicator, plus a left accent bar for tracked/completed rows.
function Widgets.buildCollectionRow(colLayer, rowIdx, rowY, bindRowHover, forwardScrollWheel, onHoverRow, onToggleTarget, onStepDelta, onSetMax, onReset)
    local Sprites = getSprites()
    local rowH = Theme.ROW_HEIGHT
    local isHidden = (rowIdx > 1)

    local bg = ui.Rectangle.new(colLayer)
    bg.colour = (rowIdx % 2 == 1) and Theme.COL_BG_ROW or Theme.COL_BG_ALT
    bg.fill = true
    bg.clickthrough = false
    bg:SetPos(8, rowY)
    bg:SetSize(-16, rowH - 2, 1.0, 0)
    bg.hidden = isHidden
    bindRowHover(bg, function() onHoverRow(rowIdx) end)

    local accentBar = ui.Rectangle.new(colLayer)
    accentBar.colour = Theme.COL_GOLD
    accentBar.fill = true
    accentBar.clickthrough = true
    accentBar:SetPos(8, rowY)
    accentBar:SetSize(3, rowH - 2, 0, 0)
    accentBar.hidden = true

    local trackCheckbox = nil
    local trackFallbackBtn = nil
    local isTrackSelected = false
    local isTrackHovered = false
    local cbSprites = Sprites and Sprites.CHECKBOX_BUTTON

    local FALLBACK_SIMPLE_BUTTON = nil
    if id and id.Sprite and id.Sprite.RS3_BTN_ICON_RESIZABLE_18 then
        FALLBACK_SIMPLE_BUTTON = {
            neutral = {
                topRight = id.Sprite.RS3_BTN_ICON_RESIZABLE_20, topLeft = id.Sprite.RS3_BTN_ICON_RESIZABLE_18, top = id.Sprite.RS3_BTN_ICON_RESIZABLE_19,
                left = id.Sprite.RS3_BTN_ICON_RESIZABLE_21, centre = id.Sprite.RS3_BTN_ICON_RESIZABLE_22, right = id.Sprite.RS3_BTN_ICON_RESIZABLE_23,
                bottomLeft = id.Sprite.RS3_BTN_ICON_RESIZABLE_24, bottom = id.Sprite.RS3_BTN_ICON_RESIZABLE_25, bottomRight = id.Sprite.RS3_BTN_ICON_RESIZABLE_26,
            },
            hovered = {
                topRight = id.Sprite.RS3_BTN_ICON_RESIZABLE_11, topLeft = id.Sprite.RS3_BTN_ICON_RESIZABLE_9, top = id.Sprite.RS3_BTN_ICON_RESIZABLE_10,
                left = id.Sprite.RS3_BTN_ICON_RESIZABLE_12, centre = id.Sprite.RS3_BTN_ICON_RESIZABLE_13, right = id.Sprite.RS3_BTN_ICON_RESIZABLE_14,
                bottomLeft = id.Sprite.RS3_BTN_ICON_RESIZABLE_15, bottom = id.Sprite.RS3_BTN_ICON_RESIZABLE_16, bottomRight = id.Sprite.RS3_BTN_ICON_RESIZABLE_17,
            },
            active = {
                topRight = id.Sprite.RS3_BTN_ICON_RESIZABLE_29, topLeft = id.Sprite.RS3_BTN_ICON_RESIZABLE_27, top = id.Sprite.RS3_BTN_ICON_RESIZABLE_28,
                left = id.Sprite.RS3_BTN_ICON_RESIZABLE_30, centre = id.Sprite.RS3_BTN_ICON_RESIZABLE_31, right = id.Sprite.RS3_BTN_ICON_RESIZABLE_32,
                bottomLeft = id.Sprite.RS3_BTN_ICON_RESIZABLE_33, bottom = id.Sprite.RS3_BTN_ICON_RESIZABLE_34, bottomRight = id.Sprite.RS3_BTN_ICON_RESIZABLE_35,
            },
        }
    end

    if cbSprites and cbSprites.selected and cbSprites.empty then
        trackCheckbox = ui.Sprite.new(colLayer)
        trackCheckbox.spriteID = cbSprites.empty
        trackCheckbox.clickthrough = false
        trackCheckbox:SetPos(22, rowY + 4)
        trackCheckbox:SetSize(16, 16)
        trackCheckbox.hidden = isHidden

        local function refreshCheckboxSprite()
            if isTrackSelected then
                trackCheckbox.spriteID = isTrackHovered and (cbSprites.selectedHovered or cbSprites.selected) or cbSprites.selected
            else
                trackCheckbox.spriteID = isTrackHovered and (cbSprites.emptyHovered or cbSprites.empty) or cbSprites.empty
            end
        end

        if ui and ui.Hook then
            if ui.Hook.ONMOUSEOVER then
                trackCheckbox:Subscribe(ui.Hook.ONMOUSEOVER, function()
                    isTrackHovered = true
                    refreshCheckboxSprite()
                    onHoverRow(rowIdx)
                    return false
                end)
            end
            if ui.Hook.ONMOUSELEAVE then
                trackCheckbox:Subscribe(ui.Hook.ONMOUSELEAVE, function()
                    isTrackHovered = false
                    refreshCheckboxSprite()
                    return false
                end)
            end
            if ui.Hook.ONCLICK then
                trackCheckbox:Subscribe(ui.Hook.ONCLICK, function()
                    onToggleTarget(rowIdx)
                    return false
                end)
            end
        end
        if forwardScrollWheel then forwardScrollWheel(trackCheckbox) end
    else
        trackFallbackBtn = Widgets.createToolbarButton(
            colLayer,
            "Track",
            nil,
            true,
            function() onToggleTarget(rowIdx) end,
            function(comp, delta)
                if forwardScrollWheel then forwardScrollWheel(comp, delta) end
            end,
            40,
            20
        )
        trackFallbackBtn.setBounds(10, rowY + 2, 40, 20)
        trackFallbackBtn.setHidden(isHidden)
        bindRowHover(trackFallbackBtn.root, function() onHoverRow(rowIdx) end)
    end

    local sliderSprites = Sprites and Sprites.SLIDER
    local function makeStepBtn(xOffset, spriteSet, symbol, delta)
        if spriteSet and spriteSet.normal then
            local btnSprite = ui.Sprite.new(colLayer)
            btnSprite.spriteID = spriteSet.normal
            btnSprite.clickthrough = false
            btnSprite:SetPos(xOffset, rowY + 4, 0, 0)
            btnSprite:SetSize(16, 16, 0, 0)
            btnSprite.hidden = isHidden

            if ui and ui.Hook then
                if ui.Hook.ONMOUSEOVER then
                    btnSprite:Subscribe(ui.Hook.ONMOUSEOVER, function()
                        btnSprite.spriteID = spriteSet.hovered or spriteSet.normal
                        onHoverRow(rowIdx)
                        return false
                    end)
                end
                if ui.Hook.ONMOUSELEAVE then
                    btnSprite:Subscribe(ui.Hook.ONMOUSELEAVE, function()
                        btnSprite.spriteID = spriteSet.normal
                        return false
                    end)
                end
                if ui.Hook.ONCLICK then
                    btnSprite:Subscribe(ui.Hook.ONCLICK, function()
                        btnSprite.spriteID = spriteSet.pressed or spriteSet.normal
                        if onStepDelta then onStepDelta(rowIdx, delta) end
                        return false
                    end)
                end
                if ui.Hook.ONRELEASE then
                    btnSprite:Subscribe(ui.Hook.ONRELEASE, function()
                        btnSprite.spriteID = spriteSet.hovered or spriteSet.normal
                        return false
                    end)
                end
            end
            if forwardScrollWheel then forwardScrollWheel(btnSprite) end
            return btnSprite, nil
        end

        local btnBg = ui.Rectangle.new(colLayer)
        btnBg.colour = Theme.COL_BTN_STEP
        btnBg.fill = true
        btnBg.clickthrough = false
        btnBg:SetPos(xOffset, rowY + 2, 0, 0)
        btnBg:SetSize(16, rowH - 4, 0, 0)
        btnBg.hidden = isHidden
        btnBg:Subscribe(ui.Hook.ONCLICK, function()
            if onStepDelta then onStepDelta(rowIdx, delta) end
            return false
        end)
        bindRowHover(btnBg, function() onHoverRow(rowIdx) end)
        if forwardScrollWheel then forwardScrollWheel(btnBg) end

        local btnTxt = Widgets.createText(colLayer, Theme.COL_GOLD, xOffset, rowY + 2, 16, rowH - 4, symbol, 0, 0, 0, 0)
        if ui.AlignMode then
            pcall(function()
                btnTxt.alignHorizontal = ui.AlignMode.CENTRE
                btnTxt.alignVertical = ui.AlignMode.CENTRE
            end)
        end
        btnTxt.hidden = isHidden
        return btnBg, btnTxt
    end

    local minusBg, minusTxt = makeStepBtn(56, sliderSprites and sliderSprites.decrease, "-", -1)

    local targetTxt = Widgets.createText(colLayer, Theme.COL_WHITE, 74, rowY + 2, 24, rowH - 2, "1", 0, 0, 0, 0)
    if ui.AlignMode then
        pcall(function()
            targetTxt.alignHorizontal = ui.AlignMode.CENTRE
            targetTxt.alignVertical = ui.AlignMode.CENTRE
        end)
    end
    targetTxt.hidden = isHidden

    local plusBg, plusTxt = makeStepBtn(100, sliderSprites and sliderSprites.increase, "+", 1)

    local function makeSimpleStyleBtn(xPos, width, label, onClickFn)
        local btnH = 20
        local btnY = rowY + 1
        local cornerW = 8
        local cornerH = 8

        local btnRoot = ui.Layer.new(colLayer)
        btnRoot:SetPos(xPos, btnY, 0, 0)
        btnRoot:SetSize(width, btnH, 0, 0)
        btnRoot.clickthrough = false
        btnRoot.hidden = isHidden

        local simpleSprites = (Sprites and Sprites.SIMPLE_BUTTON) or FALLBACK_SIMPLE_BUTTON

        local function backgroundSprite(tiled)
            local s = ui.Sprite.new(btnRoot)
            s.clickthrough = true
            s.isTiling = (tiled == true)
            return s
        end

        local parts = {
            topLeft     = backgroundSprite(false),
            top         = backgroundSprite(true),
            topRight    = backgroundSprite(false),
            left        = backgroundSprite(true),
            centre      = backgroundSprite(true),
            right       = backgroundSprite(true),
            bottomLeft  = backgroundSprite(false),
            bottom      = backgroundSprite(true),
            bottomRight = backgroundSprite(false),
        }

        parts.topLeft:SetPos(0, 0)
        parts.topLeft:SetSize(cornerW, cornerH)

        parts.top:SetPos(cornerW, 0)
        parts.top:SetSize(-cornerW * 2, cornerH, 1.0, 0)

        parts.topRight:SetPos(-cornerW, 0, 1.0, 0)
        parts.topRight:SetSize(cornerW, cornerH)

        parts.left:SetPos(0, cornerH)
        parts.left:SetSize(cornerW, -cornerH * 2, 0, 1.0)

        parts.centre:SetPos(cornerW, cornerH)
        parts.centre:SetSize(-cornerW * 2, -cornerH * 2, 1.0, 1.0)

        parts.right:SetPos(-cornerW, cornerH, 1.0, 0)
        parts.right:SetSize(cornerW, -cornerH * 2, 0, 1.0)

        parts.bottomLeft:SetPos(0, -cornerH, 0, 1.0)
        parts.bottomLeft:SetSize(cornerW, cornerH)

        parts.bottom:SetPos(cornerW, -cornerH, 0, 1.0)
        parts.bottom:SetSize(-cornerW * 2, cornerH, 1.0, 0)

        parts.bottomRight:SetPos(-cornerW, -cornerH, 1.0, 1.0)
        parts.bottomRight:SetSize(cornerW, cornerH)

        local txt = ui.Text.new(btnRoot)
        txt:SetPos(0, 0, 0, 0)
        txt:SetSize(width, btnH, 0, 0)
        txt.content = label or ""
        txt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        txt.rgba = 0xE8DFD0FF
        txt.isShadowed = true
        if ui.AlignMode then
            pcall(function()
                txt.alignHorizontal = ui.AlignMode.CENTRE
                txt.alignVertical = ui.AlignMode.CENTRE
            end)
        end
        txt.maxLines = 1
        txt.clickthrough = true

        local isHovered = false
        local isPressed = false
        local isActive = false

        local function updateState()
            local state = "neutral"
            if isPressed or isActive then
                state = "active"
            elseif isHovered then
                state = "hovered"
            end

            local s = simpleSprites and simpleSprites[state]
            if s then
                for piece, part in pairs(parts) do
                    if s[piece] then
                        part.spriteID = s[piece]
                    end
                end
            end

            if isHovered or isActive then
                txt.rgba = 0xFFD700FF
            else
                txt.rgba = 0xE8DFD0FF
            end
        end

        updateState()

        if ui and ui.Hook then
            if ui.Hook.ONMOUSEOVER then
                btnRoot:Subscribe(ui.Hook.ONMOUSEOVER, function()
                    isHovered = true
                    updateState()
                    onHoverRow(rowIdx)
                    return false
                end)
            end
            if ui.Hook.ONMOUSELEAVE then
                btnRoot:Subscribe(ui.Hook.ONMOUSELEAVE, function()
                    isHovered = false
                    isPressed = false
                    updateState()
                    return false
                end)
            end
            if ui.Hook.ONCLICK then
                btnRoot:Subscribe(ui.Hook.ONCLICK, function()
                    isPressed = true
                    updateState()
                    if onClickFn then onClickFn(rowIdx) end
                    return false
                end)
            end
            if ui.Hook.ONRELEASE then
                btnRoot:Subscribe(ui.Hook.ONRELEASE, function()
                    isPressed = false
                    updateState()
                    return false
                end)
            end
        end

        if forwardScrollWheel then forwardScrollWheel(btnRoot) end

        return {
            root = btnRoot,
            txt = txt,
            setActive = function(active)
                isActive = (active == true)
                updateState()
            end,
            setHidden = function(hidden)
                btnRoot.hidden = (hidden == true)
            end,
            setLabel = function(lbl)
                txt.content = lbl or ""
            end,
        }
    end

    local maxBtn = makeSimpleStyleBtn(120, 44, "Max", onSetMax)
    local resetBtn = makeSimpleStyleBtn(168, 66, "Reset", onReset)

    local doneTxt = Widgets.createText(colLayer, Theme.COL_MUTED, 238, rowY + 2, 42, rowH - 2, "-")
    doneTxt.hidden = isHidden

    local lvlTxt = Widgets.createText(colLayer, Theme.COL_MUTED, 284, rowY + 2, 26, rowH - 2)
    lvlTxt.hidden = isHidden

    local nameTxt = Widgets.createText(colLayer, Theme.COL_WHITE, 314, rowY + 2, 60, rowH - 2, nil, 0, 0, 0, 0)
    nameTxt.hidden = isHidden

    local rewardTxt = Widgets.createText(colLayer, Theme.COL_MUTED, -156, rowY + 2, 88, rowH - 2, nil, 1.0, 0, 0, 0)
    rewardTxt.hidden = isHidden

    local readyTxt = Widgets.createText(colLayer, Theme.COL_MUTED, -62, rowY + 2, 54, rowH - 2, nil, 1.0, 0, 0, 0)
    readyTxt.hidden = isHidden

    return {
        bg = bg,
        accentBar = accentBar,
        trackCheckbox = trackCheckbox,
        trackFallbackBtn = trackFallbackBtn,
        doneTxt = doneTxt,
        lvlTxt = lvlTxt,
        nameTxt = nameTxt,
        rewardTxt = rewardTxt,
        minusBg = minusBg,
        minusTxt = minusTxt,
        targetTxt = targetTxt,
        plusBg = plusBg,
        plusTxt = plusTxt,
        maxBtn = maxBtn,
        resetBtn = resetBtn,
        readyTxt = readyTxt,
        setTargetState = function(isTargeted)
            isTrackSelected = (isTargeted == true)
            if trackCheckbox and cbSprites then
                if isTrackSelected then
                    trackCheckbox.spriteID = isTrackHovered and (cbSprites.selectedHovered or cbSprites.selected) or cbSprites.selected
                else
                    trackCheckbox.spriteID = isTrackHovered and (cbSprites.emptyHovered or cbSprites.empty) or cbSprites.empty
                end
            elseif trackFallbackBtn then
                trackFallbackBtn.setActive(isTrackSelected)
                trackFallbackBtn.setLabel(isTrackSelected and "On" or "Off")
            end
        end,
        setDoneState = function(isCompleted)
            if isCompleted then
                doneTxt.colour = Theme.COL_GREEN
                doneTxt.content = "Done"
            else
                doneTxt.colour = Theme.COL_MUTED
                doneTxt.content = "-"
            end
        end,
        setRowHidden = function(hidden)
            local h = (hidden == true)
            bg.hidden = h
            if h then accentBar.hidden = true end
            if trackCheckbox then
                trackCheckbox.hidden = h
            elseif trackFallbackBtn then
                trackFallbackBtn.setHidden(h)
            end
            doneTxt.hidden = h
            lvlTxt.hidden = h
            nameTxt.hidden = h
            rewardTxt.hidden = h
            if minusBg then minusBg.hidden = h end
            if minusTxt then minusTxt.hidden = h end
            if targetTxt then targetTxt.hidden = h end
            if plusBg then plusBg.hidden = h end
            if plusTxt then plusTxt.hidden = h end
            if maxBtn then maxBtn.setHidden(h) end
            if resetBtn then resetBtn.setHidden(h) end
            readyTxt.hidden = h
        end
    }
end

--- Builds a single row in the Artefacts table using `prettyui.Sprites.SLIDER.decrease` and `increase`
--- official RS3 stepper buttons instead of custom rectangles.
function Widgets.buildArtefactRow(artLayer, rowIdx, rowY, bindRowHover, onHoverRow, onStepDelta)
    local Sprites = getSprites()
    local rowH = Theme.ROW_HEIGHT
    local isHidden = (rowIdx > 1)

    local bg = ui.Rectangle.new(artLayer)
    bg.colour = (rowIdx % 2 == 1) and Theme.COL_BG_ROW or Theme.COL_BG_ALT
    bg.fill = true
    bg.clickthrough = false
    bg:SetPos(8, rowY)
    bg:SetSize(-16, rowH - 2, 1.0, 0)
    bg.hidden = isHidden
    bindRowHover(bg, function() onHoverRow(rowIdx) end)

    local icon = ui.Sprite.new(artLayer)
    icon.clickthrough = true
    icon:SetPos(14, rowY + 2, 0, 0)
    icon:SetSize(18, 18)
    icon.hidden = true

    local nameTxt = Widgets.createText(artLayer, Theme.COL_WHITE, 36, rowY + 2, 132, rowH - 2)
    nameTxt.hidden = isHidden

    local lvlTxt = Widgets.createText(artLayer, Theme.COL_CREAM, 170, rowY + 2, 30, rowH - 2)
    lvlTxt.hidden = isHidden

    local locTxt = Widgets.createText(artLayer, Theme.COL_MUTED, 202, rowY + 2, 100, rowH - 2, nil, 0, 0, 0, 0)
    locTxt.hidden = isHidden

    local ownedTxt = Widgets.createText(artLayer, Theme.COL_MUTED, -316, rowY + 2, 82, rowH - 2, nil, 1.0, 0, 0, 0)
    ownedTxt.hidden = isHidden

    local sliderSprites = Sprites and Sprites.SLIDER
    local function makeStepBtn(xOffset, spriteSet, symbol, delta)
        if spriteSet and spriteSet.normal then
            local btnSprite = ui.Sprite.new(artLayer)
            btnSprite.spriteID = spriteSet.normal
            btnSprite.clickthrough = false
            btnSprite:SetPos(xOffset, rowY + 3, 1.0, 0)
            btnSprite:SetSize(16, 16, 0, 0)
            btnSprite.hidden = true

            if ui and ui.Hook then
                if ui.Hook.ONMOUSEOVER then
                    btnSprite:Subscribe(ui.Hook.ONMOUSEOVER, function()
                        btnSprite.spriteID = spriteSet.hovered or spriteSet.normal
                        onHoverRow(rowIdx)
                        return false
                    end)
                end
                if ui.Hook.ONMOUSELEAVE then
                    btnSprite:Subscribe(ui.Hook.ONMOUSELEAVE, function()
                        btnSprite.spriteID = spriteSet.normal
                        return false
                    end)
                end
                if ui.Hook.ONCLICK then
                    btnSprite:Subscribe(ui.Hook.ONCLICK, function()
                        btnSprite.spriteID = spriteSet.pressed or spriteSet.normal
                        onStepDelta(rowIdx, delta)
                        return false
                    end)
                end
                if ui.Hook.ONRELEASE then
                    btnSprite:Subscribe(ui.Hook.ONRELEASE, function()
                        btnSprite.spriteID = spriteSet.hovered or spriteSet.normal
                        return false
                    end)
                end
            end
            return btnSprite, nil
        end

        local btnBg = ui.Rectangle.new(artLayer)
        btnBg.colour = Theme.COL_BTN_STEP
        btnBg.fill = true
        btnBg.clickthrough = false
        btnBg:SetPos(xOffset, rowY + 2, 1.0, 0)
        btnBg:SetSize(18, rowH - 6, 0, 0)
        btnBg.hidden = true
        btnBg:Subscribe(ui.Hook.ONCLICK, function()
            onStepDelta(rowIdx, delta)
            return false
        end)
        bindRowHover(btnBg, function() onHoverRow(rowIdx) end)

        local btnTxt = Widgets.createText(artLayer, Theme.COL_GOLD, xOffset, rowY + 2, 18, rowH - 6, symbol, 1.0, 0, 0, 0)
        if ui.AlignMode then
            pcall(function()
                btnTxt.alignHorizontal = ui.AlignMode.CENTRE
                btnTxt.alignVertical = ui.AlignMode.CENTRE
            end)
        end
        btnTxt.hidden = true
        return btnBg, btnTxt
    end

    local minusBg, minusTxt = makeStepBtn(-228, sliderSprites and sliderSprites.decrease, "-", -1)

    local qtyTxt = Widgets.createText(artLayer, Theme.COL_WHITE, -208, rowY + 2, 24, rowH - 2, nil, 1.0, 0, 0, 0)
    if ui.AlignMode then
        pcall(function()
            qtyTxt.alignHorizontal = ui.AlignMode.CENTRE
            qtyTxt.alignVertical = ui.AlignMode.CENTRE
        end)
    end
    qtyTxt.hidden = isHidden

    local plusBg, plusTxt = makeStepBtn(-182, sliderSprites and sliderSprites.increase, "+", 1)

    local statusTxt = Widgets.createText(artLayer, Theme.COL_WHITE, -143, rowY + 2, 135, rowH - 2, nil, 1.0, 0, 0, 0)
    statusTxt.hidden = isHidden

    return {
        bg = bg,
        icon = icon,
        nameTxt = nameTxt,
        lvlTxt = lvlTxt,
        locTxt = locTxt,
        ownedTxt = ownedTxt,
        minusBg = minusBg,
        minusTxt = minusTxt,
        qtyTxt = qtyTxt,
        plusBg = plusBg,
        plusTxt = plusTxt,
        statusTxt = statusTxt
    }
end

--- Builds a single row in the Materials table.
function Widgets.buildMaterialRow(tableLayer, rowIdx, rowY, bindRowHover, onHoverRow)
    local rowH = Theme.ROW_HEIGHT
    local isHidden = (rowIdx > 1)

    local bg = ui.Rectangle.new(tableLayer)
    bg.colour = (rowIdx % 2 == 1) and Theme.COL_BG_ROW or Theme.COL_BG_ALT
    bg.fill = true
    bg.clickthrough = false
    bg:SetPos(8, rowY)
    bg:SetSize(-16, rowH - 2, 1.0, 0)
    bg.hidden = isHidden
    bindRowHover(bg, function() onHoverRow(rowIdx) end)

    local icon = ui.Sprite.new(tableLayer)
    icon.clickthrough = true
    icon:SetPos(14, rowY + 2, 0, 0)
    icon:SetSize(20, 20)
    icon.hidden = true

    local nameTxt = Widgets.createText(tableLayer, Theme.COL_WHITE, 38, rowY + 2, 131, rowH - 2)
    nameTxt.hidden = isHidden

    local lvlTxt = Widgets.createText(tableLayer, Theme.COL_CREAM, 173, rowY + 2, 32, rowH - 2)
    lvlTxt.hidden = isHidden

    local locTxt = Widgets.createText(tableLayer, Theme.COL_MUTED, 209, rowY + 2, -390, rowH - 2, nil, 0, 0, 1.0, 0)
    locTxt.hidden = isHidden

    local progTxt = Widgets.createText(tableLayer, Theme.COL_WHITE, -175, rowY + 2, 100, rowH - 2, nil, 1.0, 0, 0, 0)
    progTxt.hidden = isHidden

    local statusTxt = Widgets.createText(tableLayer, Theme.COL_WHITE, -71, rowY + 2, 63, rowH - 2, nil, 1.0, 0, 0, 0)
    statusTxt.hidden = isHidden

    return {
        bg = bg,
        icon = icon,
        nameTxt = nameTxt,
        lvlTxt = lvlTxt,
        locTxt = locTxt,
        progTxt = progTxt,
        statusTxt = statusTxt
    }
end

--- Renders the bottom-right corner resize grip visual indicator on the window root.
function Widgets.addCornerResizeGrip(winRoot)
    if not winRoot then return end
    local function makeGripBar(x, y, w, h)
        local bar = ui.Rectangle.new(winRoot)
        bar.colour = Theme.COL_GOLD
        bar.fill = true
        bar.clickthrough = true
        bar:SetPos(x, y, 1.0, 1.0)
        bar:SetSize(w, h)
        bar:MoveToFront()
    end
    makeGripBar(-16, -6, 12, 2)
    makeGripBar(-6, -16, 2, 12)
    makeGripBar(-12, -10, 6, 2)
    makeGripBar(-10, -12, 2, 6)
end

return Widgets
