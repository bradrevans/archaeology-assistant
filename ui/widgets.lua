-- ui/widgets.lua
-- Reusable UI component factories (toolbar buttons, sync badges, table headers, row builders,
-- and window resize handles) extracted from ui/window.lua to keep UI modules modular and DRY.

local Utils = require("core/utils")
local Theme = require("ui/theme")

local Widgets = {}

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

--- Creates a PrettyUI or native fallback toolbar button with scroll-wheel passthrough.
function Widgets.createToolbarButton(parent, label, tooltipText, toggleable, onClick, onWheelFn)
    if prettyui and prettyui.SimpleButton then
        local btn = prettyui.SimpleButton.new(parent, label, function()
            if onClick then onClick() end
        end, {
            x = 0,
            y = 6,
            width = 90,
            height = 26,
            toggleable = toggleable == true,
            tooltip = tooltipText,
            _onScrollWheel = onWheelFn
        })
        return {
            isPretty = true,
            widget = btn,
            root = btn.root,
            setLabel = function(newText)
                if btn.content and btn.content.content ~= newText then
                    btn.content.content = newText
                end
            end,
            setActive = function(active)
                if btn.SetActive then
                    btn:SetActive(active == true)
                end
            end,
            setHidden = function(hidden)
                if btn.root then
                    btn.root.hidden = (hidden == true)
                end
            end,
            setBounds = function(x, y, w, h)
                btn.root:SetPos(x, y)
                btn.root:SetSize(w, h)
            end
        }
    end

    local btn = ui.Button.new(parent)
    btn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    btn:SetPos(0, 6)
    btn:SetSize(90, 26)
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
        setHidden = function(hidden)
            btn.hidden = (hidden == true)
        end,
        setBounds = function(x, y, w, h)
            btn:SetPos(x, y)
            btn:SetSize(w, h)
        end
    }
end

--- Creates a compact Storage or Bank sync status badge with an item sprite and status indicator dot.
function Widgets.createSyncBadge(container, fallbackLabel, iconObjId, bindRowHover, onHoverFn, onClickFn)
    local root = ui.Layer.new(container)
    root.clickthrough = false
    root:SetPos(0, 36)
    root:SetSize(Theme.BADGE_W, 26)

    local border = ui.Rectangle.new(root)
    border.colour = Theme.COL_RED
    border.fill = true
    border.clickthrough = true
    border:SetPos(0, 0)
    border:SetSize(0, 0, 1.0, 1.0)

    local bg = ui.Rectangle.new(root)
    bg.colour = Theme.COL_SYNC_MISSING
    bg.fill = true
    bg.clickthrough = (onClickFn == nil)
    bg:SetPos(2, 2)
    bg:SetSize(-4, -4, 1.0, 1.0)

    if onClickFn and ui and ui.Hook and ui.Hook.ONCLICK then
        bg:Subscribe(ui.Hook.ONCLICK, function()
            onClickFn()
            return false
        end)
        root:Subscribe(ui.Hook.ONCLICK, function()
            onClickFn()
            return false
        end)
    end

    local icon = ui.Sprite.new(root)
    icon.clickthrough = true
    icon:SetPos(4, 1)
    icon:SetSize(28, 24)
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
    dotOutline:SetPos(-13, 3, 1.0, 0)
    dotOutline:SetSize(10, 10)

    local dot = ui.Rectangle.new(root)
    dot.colour = Theme.COL_RED
    dot.fill = true
    dot.clickthrough = true
    dot:SetPos(-12, 4, 1.0, 0)
    dot:SetSize(8, 8)

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
        bg = bg,
        setIcon = setIcon,
        setBounds = function(x, y, w, h)
            root:SetPos(x, y)
            root:SetSize(w, h)
        end,
        setState = function(state)
            local alpha = 1.0
            if state == "ignored" then
                border.colour = Theme.COL_MUTED
                bg.colour = Theme.COL_BG_CARD
                dot.colour = Theme.COL_MUTED
                txt.colour = Theme.COL_MUTED
                alpha = 0.4
            elseif state == "synced" then
                border.colour = Theme.COL_GREEN
                bg.colour = Theme.COL_SYNC_READY
                dot.colour = Theme.COL_GREEN
                txt.colour = Theme.COL_GREEN
            elseif state == "cached" then
                border.colour = Theme.COL_AMBER
                bg.colour = Theme.COL_SYNC_CACHED
                dot.colour = Theme.COL_AMBER
                txt.colour = Theme.COL_AMBER
            else
                border.colour = Theme.COL_RED
                bg.colour = Theme.COL_SYNC_MISSING
                dot.colour = Theme.COL_RED
                txt.colour = Theme.COL_RED
            end
            pcall(function() icon.alpha = alpha end)
        end
    }
end

--- Creates the Collections-tab Collector Sync status pill (`Collectors: X/13`).
function Widgets.createCollectorSyncPill(container, bindRowHover, onHoverFn, onClickFn)
    local root = ui.Layer.new(container)
    root.clickthrough = false
    root:SetPos(0, 36)
    root:SetSize(115, 26)

    local border = ui.Rectangle.new(root)
    border.colour = Theme.COL_MUTED
    border.fill = true
    border.clickthrough = true
    border:SetPos(0, 0)
    border:SetSize(0, 0, 1.0, 1.0)

    local bg = ui.Rectangle.new(root)
    bg.colour = Theme.COL_BG_CARD
    bg.fill = true
    bg.clickthrough = true
    bg:SetPos(2, 2)
    bg:SetSize(-4, -4, 1.0, 1.0)

    if onClickFn and ui and ui.Hook then
        if ui.Hook.ONCLICK then
            root:Subscribe(ui.Hook.ONCLICK, function()
                onClickFn()
                return false
            end)
        end
        if ui.Hook.ONMOUSEBUTTONDOWN then
            root:Subscribe(ui.Hook.ONMOUSEBUTTONDOWN, function(_, btnIdx)
                if btnIdx == 0 then
                    onClickFn()
                    return false
                end
            end)
        end
    end

    local txt = Widgets.createText(root, Theme.COL_MUTED, 6, 4, -20, 16, "Collectors", 0, 0, 1.0, 0)

    local dotOutline = ui.Rectangle.new(root)
    dotOutline.colour = Theme.makeColour(0.04, 0.04, 0.04, 0.9)
    dotOutline.fill = true
    dotOutline.clickthrough = true
    dotOutline:SetPos(-13, 3, 1.0, 0)
    dotOutline:SetSize(10, 10)

    local dot = ui.Rectangle.new(root)
    dot.colour = Theme.COL_RED
    dot.fill = true
    dot.clickthrough = true
    dot:SetPos(-12, 4, 1.0, 0)
    dot:SetSize(8, 8)

    bindRowHover(root, onHoverFn)

    return {
        root = root,
        bg = bg,
        border = border,
        txt = txt,
        dot = dot,
        setBounds = function(x, y, w, h)
            root:SetPos(x, y)
            root:SetSize(w, h)
        end,
        setHidden = function(hidden)
            root.hidden = (hidden == true)
        end,
        setStatus = function(syncedCount, totalCount)
            txt.content = string.format("Collectors: %d/%d", syncedCount or 0, totalCount or 13)
            if syncedCount == totalCount and (totalCount or 0) > 0 then
                border.colour = Theme.COL_GREEN
                bg.colour = Theme.COL_SYNC_READY
                dot.colour = Theme.COL_GREEN
                txt.colour = Theme.COL_GREEN
            elseif (syncedCount or 0) > 0 then
                border.colour = Theme.COL_AMBER
                bg.colour = Theme.COL_SYNC_CACHED
                dot.colour = Theme.COL_AMBER
                txt.colour = Theme.COL_AMBER
            else
                border.colour = Theme.COL_RED
                bg.colour = Theme.COL_SYNC_MISSING
                dot.colour = Theme.COL_RED
                txt.colour = Theme.COL_RED
            end
        end
    }
end

--- Builds a single row in the Collections table.
function Widgets.buildCollectionRow(colLayer, rowIdx, rowY, bindRowHover, forwardScrollWheel, onHoverRow, onToggleTarget)
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

    local targetBtnBg = ui.Rectangle.new(colLayer)
    targetBtnBg.colour = Theme.COL_BTN_STEP
    targetBtnBg.fill = true
    targetBtnBg.clickthrough = false
    targetBtnBg:SetPos(12, rowY + 2)
    targetBtnBg:SetSize(50, rowH - 6)
    targetBtnBg.hidden = isHidden
    forwardScrollWheel(targetBtnBg)

    local targetBtnTxt = Widgets.createText(colLayer, Theme.COL_MUTED, 12, rowY + 2, 50, rowH - 6, "Track")
    targetBtnTxt.hidden = isHidden

    targetBtnBg:Subscribe(ui.Hook.ONCLICK, function()
        onToggleTarget(rowIdx)
    end)

    local doneTxt = Widgets.createText(colLayer, Theme.COL_MUTED, 66, rowY + 2, 40, rowH - 2, "-")
    doneTxt.hidden = isHidden

    local lvlTxt = Widgets.createText(colLayer, Theme.COL_MUTED, 110, rowY + 2, 32, rowH - 2)
    lvlTxt.hidden = isHidden

    local nameTxt = Widgets.createText(colLayer, Theme.COL_WHITE, 146, rowY + 2, -478, rowH - 2, nil, 0, 0, 1.0, 0)
    nameTxt.hidden = isHidden

    local rewardTxt = Widgets.createText(colLayer, Theme.COL_MUTED, -327, rowY + 2, 230, rowH - 2, nil, 1.0, 0, 0, 0)
    rewardTxt.hidden = isHidden

    local readyTxt = Widgets.createText(colLayer, Theme.COL_MUTED, -93, rowY + 2, 85, rowH - 2, nil, 1.0, 0, 0, 0)
    readyTxt.hidden = isHidden

    return {
        bg = bg,
        targetBtnBg = targetBtnBg,
        targetBtnTxt = targetBtnTxt,
        doneTxt = doneTxt,
        lvlTxt = lvlTxt,
        nameTxt = nameTxt,
        rewardTxt = rewardTxt,
        readyTxt = readyTxt
    }
end

--- Builds a single row in the Artefacts table (including [-] and [+] stepper controls).
function Widgets.buildArtefactRow(artLayer, rowIdx, rowY, bindRowHover, onHoverRow, onStepDelta)
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

    local locTxt = Widgets.createText(artLayer, Theme.COL_MUTED, 202, rowY + 2, -496, rowH - 2, nil, 0, 0, 1.0, 0)
    locTxt.hidden = isHidden

    local ownedTxt = Widgets.createText(artLayer, Theme.COL_MUTED, -288, rowY + 2, 54, rowH - 2, nil, 1.0, 0, 0, 0)
    ownedTxt.hidden = isHidden

    local function makeStepBtn(xOffset, symbol, delta)
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

    local minusBg, minusTxt = makeStepBtn(-228, "-", -1)

    local qtyTxt = Widgets.createText(artLayer, Theme.COL_WHITE, -208, rowY + 2, 24, rowH - 2, nil, 1.0, 0, 0, 0)
    if ui.AlignMode then
        pcall(function()
            qtyTxt.alignHorizontal = ui.AlignMode.CENTRE
            qtyTxt.alignVertical = ui.AlignMode.CENTRE
        end)
    end
    qtyTxt.hidden = isHidden

    local plusBg, plusTxt = makeStepBtn(-182, "+", 1)

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

--- Attaches right, bottom, and bottom-right corner drag-resize handles to a PrettyUI window.
function Widgets.setupResizeHandles(windowInstance, parent, win)
    local gripLine1 = ui.Rectangle.new(win.root)
    gripLine1.colour = Theme.COL_GOLD
    gripLine1.fill = true
    gripLine1.clickthrough = true
    gripLine1:SetPos(-14, -6, 1.0, 1.0)
    gripLine1:SetSize(10, 2)
    gripLine1:MoveToFront()

    local gripLine2 = ui.Rectangle.new(win.root)
    gripLine2.colour = Theme.COL_GOLD
    gripLine2.fill = true
    gripLine2.clickthrough = true
    gripLine2:SetPos(-6, -14, 1.0, 1.0)
    gripLine2:SetSize(2, 10)
    gripLine2:MoveToFront()

    local function createResizeZone(mode, layoutFn)
        local handle = ui.Layer.new(parent)
        handle.clickthrough = false
        handle:MoveToFront()

        if config and config.Cursor and config.Cursor.TOPLEVEL_V2_MOVE then
            pcall(function()
                local cid = config.Cursor.TOPLEVEL_V2_MOVE.id or config.Cursor.TOPLEVEL_V2_MOVE
                handle.cursorConfig.mouseOverCursor = cid
                handle.opConfig:SetOpCursor(0, cid)
            end)
        end

        local dragState = nil

        local function syncHandlePos()
            if dragState and dragState.expanded then return end
            if not win.root then return end
            layoutFn(handle, win.root.x or 0, win.root.y or 0, win.root.width or Theme.DEFAULT_W, win.root.height or Theme.DEFAULT_H)
        end

        local function stopResize()
            if not dragState then return false end
            dragState = nil
            windowInstance._isResizing = false
            syncHandlePos()
            win:_SyncOverlays(win.root.hidden == true)
            windowInstance:onWindowGeometryChanged()
            return false
        end

        handle:Subscribe(ui.Hook.ONCLICK, function(_, lx, ly)
            windowInstance:hideRowTooltip()
            local mx, my = Theme.getScaledMousePos((handle.x or 0) + (lx or 0), (handle.y or 0) + (ly or 0))
            dragState = {
                startMouseX = mx,
                startMouseY = my,
                startW = win.root.width or Theme.DEFAULT_W,
                startH = win.root.height or Theme.DEFAULT_H,
                expanded = false
            }
            windowInstance._isResizing = true
            win.root:MoveToFront()
            if win.titleDrag then win.titleDrag:MoveToFront() end
            handle:MoveToFront()
            return false
        end)

        handle:Subscribe(ui.Hook.ONHOLD, function(_, lx, ly)
            if not dragState then return false end
            if not dragState.expanded then
                dragState.expanded = true
                handle:SetPos(0, 0)
                handle:SetSize(0, 0, 1.0, 1.0)
                handle:MoveToFront()
            end

            local mx, my = Theme.getScaledMousePos(lx or 0, ly or 0)
            local dx = mx - dragState.startMouseX
            local dy = my - dragState.startMouseY

            local maxW = (parent.width and parent.width > 100) and (parent.width - (win.root.x or 0)) or 1600
            local maxH = (parent.height and parent.height > 100) and (parent.height - (win.root.y or 0)) or 1200

            local newW = dragState.startW
            local newH = dragState.startH
            if mode == "e" or mode == "se" then
                newW = Utils.clamp(math.floor(dragState.startW + dx), Theme.MIN_W, math.max(Theme.MIN_W, maxW))
            end
            if mode == "s" or mode == "se" then
                newH = Utils.clamp(math.floor(dragState.startH + dy), Theme.MIN_H, math.max(Theme.MIN_H, maxH))
            end

            if newW ~= win.root.width or newH ~= win.root.height then
                win:SetSize(newW, newH)
            end
            return false
        end)

        handle:Subscribe(ui.Hook.ONRELEASE, stopResize)
        handle:Subscribe(ui.Hook.ONDRAGCOMPLETE, stopResize)

        win:_RegisterOverlay(handle, function()
            return win.root ~= nil and win.root.hidden ~= true
        end, syncHandlePos)

        syncHandlePos()
        return handle
    end

    windowInstance.resizeRight = createResizeZone("e", function(h, x, y, w, height)
        h:SetPos(x + w - 6, y + 32)
        h:SetSize(10, math.max(20, height - 50))
    end)

    windowInstance.resizeBottom = createResizeZone("s", function(h, x, y, w, height)
        h:SetPos(x + 8, y + height - 6)
        h:SetSize(math.max(20, w - 26), 10)
    end)

    windowInstance.resizeCorner = createResizeZone("se", function(h, x, y, w, height)
        h:SetPos(x + w - 18, y + height - 18)
        h:SetSize(22, 22)
    end)
end

return Widgets
