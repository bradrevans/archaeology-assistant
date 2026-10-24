-- ui/window.lua
-- In-game movable, resizable, scrollable UI for the Archaeology Assistant plugin
-- built on PrettyUI (dependency 6398181) with RS3 Ribbon Bar hub integration.

local Window = {}
Window.__index = Window

local DEFAULT_X = 32
local DEFAULT_Y = 70
local DEFAULT_W = 600
local DEFAULT_H = 470
local MIN_W = 540
local MIN_H = 300

-- Enough rows to display every Archaeology material / damaged artefact without pagination
local MAX_MATERIAL_ROWS = 52
local MAX_ARTEFACT_ROWS = 45
local ROW_HEIGHT = 24

-- Sync badge sizing & icons (Coins item icon represents the Bank, Arch Journal represents Storage)
local BADGE_W = 42
local BANK_ICON_OBJ_ID = 995
local STORAGE_ICON_OBJ_ID = 49429


local HUB_EVENT_ID = "arch_assistant_hub"
local MOUNT_EVENT_ID = "arch_assistant_mount"
local RESIZE_EVENT_ID = "arch_assistant_resize"

-- Colours (Vector4 RGBA for native ui.* components)
local function makeColour(r, g, b, a)
    if Vector4 and Vector4.new then
        return Vector4.new(r, g, b, a or 1.0)
    end
    return { r = r, g = g, b = b, a = a or 1.0 }
end

local COL_WHITE        = makeColour(0.95, 0.95, 0.95, 1.0)
local COL_CREAM        = makeColour(0.91, 0.84, 0.69, 1.0)
local COL_MUTED        = makeColour(0.72, 0.76, 0.80, 1.0)
local COL_GOLD         = makeColour(1.00, 0.82, 0.28, 1.0)
local COL_GREEN        = makeColour(0.30, 0.92, 0.45, 1.0)
local COL_AMBER        = makeColour(1.00, 0.72, 0.24, 1.0)
local COL_RED          = makeColour(1.00, 0.40, 0.40, 1.0)
local COL_CYAN         = makeColour(0.38, 0.86, 1.00, 1.0)

local COL_BG_CARD      = makeColour(0.07, 0.10, 0.14, 0.72)
local COL_BG_HEADER    = makeColour(0.10, 0.14, 0.19, 0.85)
local COL_BG_ROW       = makeColour(0.08, 0.11, 0.15, 0.55)
local COL_BG_ALT       = makeColour(0.13, 0.17, 0.22, 0.55)

local COL_BTN_ON       = makeColour(0.12, 0.36, 0.18, 0.92)
local COL_BTN_OFF      = makeColour(0.30, 0.14, 0.14, 0.85)
local COL_BTN_STEP     = makeColour(0.18, 0.24, 0.32, 0.90)

local COL_SYNC_READY   = makeColour(0.08, 0.24, 0.13, 0.72)
local COL_SYNC_CACHED  = makeColour(0.28, 0.20, 0.06, 0.78)
local COL_SYNC_MISSING = makeColour(0.34, 0.11, 0.10, 0.82)

local function safeDbGet(key, defaultVal)
    if PersistentDB then
        local ok, val = pcall(function() return PersistentDB:Get(key) end)
        if ok and val ~= nil then
            return val
        end
    end
    return defaultVal
end

local function safeDbSet(key, val)
    if PersistentDB then
        pcall(function() PersistentDB:Set(key, val) end)
    end
end

local function clamp(val, low, high)
    if val < low then return low end
    if val > high then return high end
    return val
end

local function formatInt(n)
    local num = math.floor((tonumber(n) or 0) + 0.5)
    local s = tostring(num)
    local k
    while true do
        s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return s
end

local function resolveParent()
    if not ui or not ui.Interfaces or not id or not id.Component then
        return nil
    end
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
        or ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
end

local function setComponentHidden(comp, hidden)
    if not comp then return end
    pcall(function() comp.hidden = hidden end)
end

function Window.new(tracker)
    local self = setmetatable({}, Window)
    self.tracker = tracker
    self.mounted = false
    self.activeTab = "artefacts"
    self.materialRows = {}
    self.artefactRows = {}
    self.currentArtefacts = {}
    self.hubParent = nil
    self.hubSummaryText = nil
    self.hubToggleBtn = nil

    local savedVis = safeDbGet("arch_win_visible", 1)
    self.isVisible = (savedVis ~= 0 and savedVis ~= false)

    -- Subscribe to PrettyUI Ribbon Bar Hub content layer
    if Event and Event.ContentLayerReady and Event.ContentLayerReady.Subscribe then
        Event.ContentLayerReady.Subscribe(HUB_EVENT_ID, function(event)
            if event and event.component then
                self:populateRibbonHub(event.component)
            end
        end)
    end

    if not self:tryMount() then
        if Event and Event.Logic and Event.Logic.Subscribe then
            Event.Logic.Subscribe(MOUNT_EVENT_ID, function()
                if self:tryMount() then
                    Event.Logic.Unsubscribe(MOUNT_EVENT_ID)
                    self:refresh()
                end
            end)
        end
    end

    return self
end

function Window:tryMount()
    if self.mounted then
        return true
    end

    local parent = resolveParent()
    if not parent then
        return false
    end
    self.parent = parent

    local savedX = tonumber(safeDbGet("arch_win_x", DEFAULT_X)) or DEFAULT_X
    local savedY = tonumber(safeDbGet("arch_win_y", DEFAULT_Y)) or DEFAULT_Y
    local savedW = math.max(MIN_W, tonumber(safeDbGet("arch_win_w", DEFAULT_W)) or DEFAULT_W)
    local savedH = math.max(MIN_H, tonumber(safeDbGet("arch_win_h", DEFAULT_H)) or DEFAULT_H)

    if parent.width and parent.width > 100 then
        savedW = math.min(savedW, parent.width)
        savedX = clamp(savedX, 0, math.max(0, parent.width - savedW))
    end
    if parent.height and parent.height > 100 then
        savedH = math.min(savedH, parent.height)
        savedY = clamp(savedY, 0, math.max(0, parent.height - savedH))
    end

    if prettyui and prettyui.Window then
        self:buildPrettyWindow(parent, savedX, savedY, savedW, savedH)
    else
        self:buildFallbackWindow(parent, savedX, savedY, savedW, savedH)
    end

    self.mounted = true
    return true
end

function Window:createToolbarButton(parent, label, tooltipText, toggleable, onClick)
    if prettyui and prettyui.SimpleButton then
        local btn = prettyui.SimpleButton.new(parent, label, function()
            if onClick then onClick() end
        end, {
            x = 0,
            y = 6,
            width = 90,
            height = 26,
            toggleable = toggleable == true,
            tooltip = tooltipText
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
    else
        local btn = ui.Button.new(parent)
        btn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        btn:SetPos(0, 6)
        btn:SetSize(90, 26)
        btn.label = label
        if onClick then
            btn:Subscribe(ui.Hook.ONBUTTONPRESSED, onClick)
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
end

function Window:buildPrettyWindow(parent, x, y, w, h)
    local win = prettyui.Window.new(parent, {
        title = "Archaeology Assistant",
        x = x,
        y = y,
        width = w,
        height = h,
        minWidth = MIN_W,
        minHeight = MIN_H,
        resizable = false,
        scrollable = true,
        scrollStep = 28,
        onClose = function()
            self.isVisible = false
            self:hideRowTooltip()
            safeDbSet("arch_win_visible", 0)
            self:refreshHub()
        end
    })

    self.win = win
    self.root = win.root
    self.contentParent = win.content

    self:buildContentComponents(win.content)
    self:buildSharedRowTooltip(parent)
    self:setupResizeHandles(parent, win)
    self:updateToolbarLayout(true)

    -- Hook into PrettyUI's overlay sync & resize events to persist window bounds and reflow toolbar
    local anchor = ui.Layer.new(win.root)
    anchor:SetSize(0, 0)
    win:_RegisterOverlay(anchor, function() return false end, function()
        self:onWindowGeometryChanged()
    end)
    win.root:Subscribe(ui.Hook.ONRESIZE, RESIZE_EVENT_ID, function()
        self:onWindowGeometryChanged()
    end)
    parent:Subscribe(ui.Hook.ONRESIZE, RESIZE_EVENT_ID, function()
        self:onWindowGeometryChanged()
    end)

    if not self.isVisible then
        win:Close()
    end
end

local function getInterfaceScale()
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

local function getScaledMousePos(fallbackX, fallbackY)
    if Mouse and Mouse.GetPosition then
        local ok, raw = pcall(Mouse.GetPosition)
        if ok and raw and type(raw.x) == "number" and type(raw.y) == "number" then
            local scale = getInterfaceScale()
            return raw.x / scale, raw.y / scale
        end
    end
    return fallbackX or 0, fallbackY or 0
end

function Window:setupResizeHandles(parent, win)
    -- Visual resize grip indicator in the bottom-right corner of the window frame
    local gripLine1 = ui.Rectangle.new(win.root)
    gripLine1.colour = COL_GOLD
    gripLine1.fill = true
    gripLine1.clickthrough = true
    gripLine1:SetPos(-14, -6, 1.0, 1.0)
    gripLine1:SetSize(10, 2)
    gripLine1:MoveToFront()

    local gripLine2 = ui.Rectangle.new(win.root)
    gripLine2.colour = COL_GOLD
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
            layoutFn(handle, win.root.x or 0, win.root.y or 0, win.root.width or DEFAULT_W, win.root.height or DEFAULT_H)
        end

        local function stopResize()
            if not dragState then return false end
            dragState = nil
            self._isResizing = false
            syncHandlePos()
            win:_SyncOverlays(win.root.hidden == true)
            self:onWindowGeometryChanged()
            return false
        end

        handle:Subscribe(ui.Hook.ONCLICK, function(_, lx, ly)
            self:hideRowTooltip()
            local mx, my = getScaledMousePos((handle.x or 0) + (lx or 0), (handle.y or 0) + (ly or 0))
            dragState = {
                startMouseX = mx,
                startMouseY = my,
                startW = win.root.width or DEFAULT_W,
                startH = win.root.height or DEFAULT_H,
                expanded = false
            }
            self._isResizing = true
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

            local mx, my = getScaledMousePos(lx or 0, ly or 0)
            local dx = mx - dragState.startMouseX
            local dy = my - dragState.startMouseY

            local maxW = (parent.width and parent.width > 100) and (parent.width - (win.root.x or 0)) or 1600
            local maxH = (parent.height and parent.height > 100) and (parent.height - (win.root.y or 0)) or 1200

            local newW = dragState.startW
            local newH = dragState.startH
            if mode == "e" or mode == "se" then
                newW = clamp(math.floor(dragState.startW + dx), MIN_W, math.max(MIN_W, maxW))
            end
            if mode == "s" or mode == "se" then
                newH = clamp(math.floor(dragState.startH + dy), MIN_H, math.max(MIN_H, maxH))
            end

            if newW ~= win.root.width or newH ~= win.root.height then
                -- win:SetSize triggers _SyncOverlays -> onWindowGeometryChanged automatically
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

    -- Right edge resize bar (10px wide along the right border)
    self.resizeRight = createResizeZone("e", function(h, x, y, w, height)
        h:SetPos(x + w - 6, y + 32)
        h:SetSize(10, math.max(20, height - 50))
    end)

    -- Bottom edge resize bar (10px tall along the bottom border)
    self.resizeBottom = createResizeZone("s", function(h, x, y, w, height)
        h:SetPos(x + 8, y + height - 6)
        h:SetSize(math.max(20, w - 26), 10)
    end)

    -- Bottom-right corner resize grip (20x20px corner box)
    self.resizeCorner = createResizeZone("se", function(h, x, y, w, height)
        h:SetPos(x + w - 18, y + height - 18)
        h:SetSize(22, 22)
    end)
end

function Window:buildFallbackWindow(parent, x, y, w, h)
    local root = ui.GroupBox.new(parent)
    root.stylesheetID = id.StyleSheet.DEFAULT
    root:SetHeaderLayout(0, 0, 0, 0, 0)
    root:SetPos(x, y)
    root:SetSize(w, h)
    self.root = root
    self.contentParent = root

    self:buildContentComponents(root)
    self:buildSharedRowTooltip(parent)
    self:updateToolbarLayout(true)
end

function Window:switchTab(tabName)
    if tabName ~= "artefacts" and tabName ~= "materials" then
        return
    end
    self:hideRowTooltip()
    local changed = (self.activeTab ~= tabName)
    self.activeTab = tabName
    if self.btnTabArtefacts then
        self.btnTabArtefacts.setActive(self.activeTab == "artefacts")
    end
    if self.btnTabMaterials then
        self.btnTabMaterials.setActive(self.activeTab == "materials")
    end
    if not changed then
        return
    end
    if self.win and self.win.SetScrollPosition then
        pcall(function() self.win:SetScrollPosition(0) end)
    end
    self:refresh()
end

function Window:buildContentComponents(container)
    -- 1. Top View Tabs (y = 6, height = 26) — Artefacts first, Materials second
    self.btnTabArtefacts = self:createToolbarButton(
        container,
        "Artefacts",
        "View damaged artefacts in your Backpack & Bank, toggle which ones to track, and set quantities.",
        true,
        function()
            self:switchTab("artefacts")
        end
    )

    self.btnTabMaterials = self:createToolbarButton(
        container,
        "Materials",
        "View required materials, levels, locations, owned counts, and remaining deficits.",
        true,
        function()
            self:switchTab("materials")
        end
    )

    -- 2. Control Toolbar (y = 36, height = 26)
    self.btnSource = self:createToolbarButton(
        container,
        "Src: All",
        "Cycle which containers are counted (Backpack, Material Storage, Bank).",
        false,
        function()
            self.tracker:cycleSourceMode()
            self:refresh()
        end
    )

    self.btnDupes = self:createToolbarButton(
        container,
        "Dupes: All",
        "Toggle default inclusion between all duplicate artefacts or 1x each (resets custom +/- overrides).",
        false,
        function()
            self.tracker:toggleDuplicates()
            self:refresh()
        end
    )

    self.btnFilter = self:createToolbarButton(
        container,
        "Show: All",
        "Toggle between showing all required materials or only materials you are short on.",
        true,
        function()
            self.tracker:toggleShortOnly()
            self:refresh()
        end
    )

    self.btnPin = self:createToolbarButton(
        container,
        "Pin",
        "Pin/lock the current damaged artefact list.",
        true,
        function()
            self.tracker:togglePin()
            self:refresh()
        end
    )

    local function bindRowHover(comp, onOver)
        if ui and ui.Hook and ui.Hook.ONMOUSEOVER then
            comp:Subscribe(ui.Hook.ONMOUSEOVER, function()
                onOver()
                return true
            end)
        end
        if ui and ui.Hook and ui.Hook.ONMOUSELEAVE then
            comp:Subscribe(ui.Hook.ONMOUSELEAVE, function()
                self:hideRowTooltip()
                return true
            end)
        end
    end

    -- 3. Compact Sync Status Icon Badges (Storage & Bank) on the toolbar row.
    -- Each badge shows an in-game item icon, a coloured border and a status dot:
    --   green = synced live this session, amber = cached (resync recommended),
    --   red = never synced, grey = ignored by the current Src mode.
    local function createSyncBadge(fallbackLabel, iconObjId, onHoverFn)
        local root = ui.Layer.new(container)
        root.clickthrough = false
        root:SetPos(0, 36)
        root:SetSize(BADGE_W, 26)

        local border = ui.Rectangle.new(root)
        border.colour = COL_RED
        border.fill = true
        border.clickthrough = true
        border:SetPos(0, 0)
        border:SetSize(0, 0, 1.0, 1.0)

        local bg = ui.Rectangle.new(root)
        bg.colour = COL_SYNC_MISSING
        bg.fill = true
        bg.clickthrough = true
        bg:SetPos(2, 2)
        bg:SetSize(-4, -4, 1.0, 1.0)

        -- Item icon sprite (falls back to a short text label if no icon is available)
        local icon = ui.Sprite.new(root)
        icon.clickthrough = true
        icon:SetPos(4, 1)
        icon:SetSize(28, 24)
        icon.hidden = true

        local txt = ui.Text.new(root)
        txt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        txt.colour = COL_WHITE
        txt.content = fallbackLabel
        txt.maxLines = 1
        txt.clickthrough = true
        if ui.AlignMode then
            pcall(function()
                txt.alignHorizontal = ui.AlignMode.CENTRE
                txt.alignVertical = ui.AlignMode.CENTRE
            end)
        end
        txt:SetPos(2, 0)
        txt:SetSize(-12, 0, 1.0, 1.0)

        -- Status dot (top-right corner) with a dark outline so it reads over any icon
        local dotOutline = ui.Rectangle.new(root)
        dotOutline.colour = makeColour(0, 0, 0, 0.9)
        dotOutline.fill = true
        dotOutline.clickthrough = true
        dotOutline:SetPos(-13, 3, 1.0, 0)
        dotOutline:SetSize(10, 10)

        local dot = ui.Rectangle.new(root)
        dot.colour = COL_RED
        dot.fill = true
        dot.clickthrough = true
        dot:SetPos(-12, 4, 1.0, 0)
        dot:SetSize(8, 8)

        bindRowHover(root, onHoverFn)

        local currentObjId = nil
        local function setIcon(objId)
            objId = tonumber(objId)
            if objId == currentObjId then return end
            local ok = false
            if objId and objId > 0 then
                ok = pcall(function()
                    icon:SetAssociatedObject(math.tointeger(objId) or objId)
                    -- A large quantity makes Coins render as a pile; the number itself is hidden
                    icon.associatedObjectQuantity = 10000
                    if ui.ObjectQuantityDisplayMode then
                        icon.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
                    end
                end)
            end
            currentObjId = ok and objId or nil
            icon.hidden = not ok
            txt.hidden = ok
        end
        setIcon(iconObjId)

        return {
            root = root,
            setIcon = setIcon,
            setBounds = function(x, y, w, h)
                root:SetPos(x, y)
                root:SetSize(w, h)
            end,
            -- state: "synced" | "cached" | "missing" | "ignored"
            setState = function(state)
                local alpha = 1.0
                if state == "ignored" then
                    border.colour = COL_MUTED
                    bg.colour = COL_BG_CARD
                    dot.colour = COL_MUTED
                    txt.colour = COL_MUTED
                    alpha = 0.4
                elseif state == "synced" then
                    border.colour = COL_GREEN
                    bg.colour = COL_SYNC_READY
                    dot.colour = COL_GREEN
                    txt.colour = COL_GREEN
                elseif state == "cached" then
                    border.colour = COL_AMBER
                    bg.colour = COL_SYNC_CACHED
                    dot.colour = COL_AMBER
                    txt.colour = COL_AMBER
                else
                    border.colour = COL_RED
                    bg.colour = COL_SYNC_MISSING
                    dot.colour = COL_RED
                    txt.colour = COL_RED
                end
                pcall(function() icon.alpha = alpha end)
            end
        }
    end

    self.badgeStorage = createSyncBadge("Stor", self.tracker.storageIconObjId or STORAGE_ICON_OBJ_ID, function()
        self:onHoverSyncBadge("storage")
    end)

    self.badgeBank = createSyncBadge("Bank", BANK_ICON_OBJ_ID, function()
        self:onHoverSyncBadge("bank")
    end)

    -- Helper to configure a wrapping multi-line text label
    local function createWrappingText(parent, colour, x, y)
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

    -- 4. Artefact & Deficit Summary Card (compact 2-line card at y = 68)
    local summaryBg = ui.Rectangle.new(container)
    summaryBg.colour = COL_BG_CARD
    summaryBg.fill = true
    summaryBg:SetPos(8, 68)
    summaryBg:SetSize(-16, 46, 1.0, 0)
    self.summaryBg = summaryBg

    self.summaryTitle   = createWrappingText(container, COL_GOLD, 14, 71)
    self.deficitSummary = createWrappingText(container, COL_AMBER, 14, 91)

    -- 5A. ARTEFACTS VIEW LAYER (Tab 1)
    local artLayerH = 26 + (MAX_ARTEFACT_ROWS * ROW_HEIGHT)
    local artLayer = ui.Layer.new(container)
    artLayer.clickthrough = true
    artLayer:SetPos(0, 120)
    artLayer:SetSize(0, artLayerH, 1.0, 0)
    self.artefactTableLayer = artLayer

    local artHeaderBg = ui.Rectangle.new(artLayer)
    artHeaderBg.colour = COL_BG_HEADER
    artHeaderBg.fill = true
    artHeaderBg:SetPos(8, 0)
    artHeaderBg:SetSize(-16, 22, 1.0, 0)

    local colArtUse = ui.Text.new(artLayer)
    colArtUse.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colArtUse.colour = COL_GOLD
    colArtUse.content = "Track"
    colArtUse.maxLines = 1
    colArtUse:SetPos(12, 2, 0, 0)
    colArtUse:SetSize(46, 20, 0, 0)

    local colArtName = ui.Text.new(artLayer)
    colArtName.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colArtName.colour = COL_GOLD
    colArtName.content = "Artefact"
    colArtName.maxLines = 1
    colArtName:SetPos(84, 2, 0, 0)
    colArtName:SetSize(-468, 20, 1.0, 0)

    local colArtLvl = ui.Text.new(artLayer)
    colArtLvl.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colArtLvl.colour = COL_GOLD
    colArtLvl.content = "Lvl"
    colArtLvl.maxLines = 1
    colArtLvl:SetPos(-380, 2, 1.0, 0)
    colArtLvl:SetSize(36, 20, 0, 0)

    local colArtOwned = ui.Text.new(artLayer)
    colArtOwned.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colArtOwned.colour = COL_GOLD
    colArtOwned.content = "Owned"
    colArtOwned.maxLines = 1
    colArtOwned:SetPos(-340, 2, 1.0, 0)
    colArtOwned:SetSize(112, 20, 0, 0)

    local colArtQty = ui.Text.new(artLayer)
    colArtQty.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colArtQty.colour = COL_GOLD
    colArtQty.content = "Include"
    colArtQty.maxLines = 1
    colArtQty:SetPos(-224, 2, 1.0, 0)
    colArtQty:SetSize(96, 20, 0, 0)

    local colArtStatus = ui.Text.new(artLayer)
    colArtStatus.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colArtStatus.colour = COL_GOLD
    colArtStatus.content = "Repair Status"
    colArtStatus.maxLines = 1
    colArtStatus:SetPos(-122, 2, 1.0, 0)
    colArtStatus:SetSize(114, 20, 0, 0)

    local startY = 24
    for i = 1, MAX_ARTEFACT_ROWS do
        local rowIdx = i
        local rowY = startY + (i - 1) * ROW_HEIGHT

        local bg = ui.Rectangle.new(artLayer)
        bg.colour = (i % 2 == 1) and COL_BG_ROW or COL_BG_ALT
        bg.fill = true
        bg.clickthrough = false
        bg:SetPos(8, rowY)
        bg:SetSize(-16, ROW_HEIGHT - 2, 1.0, 0)
        bg.hidden = (i > 1)
        bindRowHover(bg, function()
            self:onHoverArtefactRow(rowIdx)
        end)

        -- On/Off Toggle Pill Button
        local toggleBg = ui.Rectangle.new(artLayer)
        toggleBg.colour = COL_BTN_ON
        toggleBg.fill = true
        toggleBg.clickthrough = false
        toggleBg:SetPos(12, rowY + 2, 0, 0)
        toggleBg:SetSize(44, ROW_HEIGHT - 6, 0, 0)
        toggleBg.hidden = (i > 1)
        toggleBg:Subscribe(ui.Hook.ONCLICK, function()
            local item = self.currentArtefacts and self.currentArtefacts[rowIdx]
            if item and item.artefact then
                self.tracker:toggleArtefactExcluded(item.artefact.damagedName)
                self:refresh()
                self:onHoverArtefactRow(rowIdx)
            end
            return false
        end)
        bindRowHover(toggleBg, function()
            self:onHoverArtefactRow(rowIdx)
        end)

        local toggleTxt = ui.Text.new(artLayer)
        toggleTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        toggleTxt.colour = COL_WHITE
        toggleTxt.content = "On"
        toggleTxt.maxLines = 1
        toggleTxt.clickthrough = true
        if ui.AlignMode then
            pcall(function()
                toggleTxt.alignHorizontal = ui.AlignMode.CENTRE
                toggleTxt.alignVertical = ui.AlignMode.CENTRE
            end)
        end
        toggleTxt:SetPos(12, rowY + 2, 0, 0)
        toggleTxt:SetSize(44, ROW_HEIGHT - 6, 0, 0)
        toggleTxt.hidden = (i > 1)

        local icon = ui.Sprite.new(artLayer)
        icon.clickthrough = true
        icon:SetPos(60, rowY + 2, 0, 0)
        icon:SetSize(20, 20)
        icon.hidden = true

        local nameTxt = ui.Text.new(artLayer)
        nameTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        nameTxt.colour = COL_WHITE
        nameTxt.maxLines = 1
        nameTxt.clickthrough = true
        nameTxt:SetPos(84, rowY + 2, 0, 0)
        nameTxt:SetSize(-468, ROW_HEIGHT - 2, 1.0, 0)
        nameTxt.hidden = (i > 1)

        local lvlTxt = ui.Text.new(artLayer)
        lvlTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        lvlTxt.colour = COL_CREAM
        lvlTxt.maxLines = 1
        lvlTxt.clickthrough = true
        lvlTxt:SetPos(-380, rowY + 2, 1.0, 0)
        lvlTxt:SetSize(36, ROW_HEIGHT - 2, 0, 0)
        lvlTxt.hidden = (i > 1)

        local ownedTxt = ui.Text.new(artLayer)
        ownedTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        ownedTxt.colour = COL_MUTED
        ownedTxt.maxLines = 1
        ownedTxt.clickthrough = true
        ownedTxt:SetPos(-340, rowY + 2, 1.0, 0)
        ownedTxt:SetSize(112, ROW_HEIGHT - 2, 0, 0)
        ownedTxt.hidden = (i > 1)

        -- [-] Stepper Button
        local minusBg = ui.Rectangle.new(artLayer)
        minusBg.colour = COL_BTN_STEP
        minusBg.fill = true
        minusBg.clickthrough = false
        minusBg:SetPos(-224, rowY + 2, 1.0, 0)
        minusBg:SetSize(22, ROW_HEIGHT - 6, 0, 0)
        minusBg.hidden = true
        minusBg:Subscribe(ui.Hook.ONCLICK, function()
            local item = self.currentArtefacts and self.currentArtefacts[rowIdx]
            if item and item.artefact then
                self.tracker:adjustArtefactCount(item.artefact.damagedName, -1, item.rawCount)
                self:refresh()
                self:onHoverArtefactRow(rowIdx)
            end
            return false
        end)
        bindRowHover(minusBg, function()
            self:onHoverArtefactRow(rowIdx)
        end)

        local minusTxt = ui.Text.new(artLayer)
        minusTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        minusTxt.colour = COL_GOLD
        minusTxt.content = "-"
        minusTxt.maxLines = 1
        minusTxt.clickthrough = true
        if ui.AlignMode then
            pcall(function()
                minusTxt.alignHorizontal = ui.AlignMode.CENTRE
                minusTxt.alignVertical = ui.AlignMode.CENTRE
            end)
        end
        minusTxt:SetPos(-224, rowY + 2, 1.0, 0)
        minusTxt:SetSize(22, ROW_HEIGHT - 6, 0, 0)
        minusTxt.hidden = true

        local qtyTxt = ui.Text.new(artLayer)
        qtyTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        qtyTxt.colour = COL_WHITE
        qtyTxt.maxLines = 1
        qtyTxt.clickthrough = true
        if ui.AlignMode then
            pcall(function()
                qtyTxt.alignHorizontal = ui.AlignMode.CENTRE
                qtyTxt.alignVertical = ui.AlignMode.CENTRE
            end)
        end
        qtyTxt:SetPos(-200, rowY + 2, 1.0, 0)
        qtyTxt:SetSize(44, ROW_HEIGHT - 2, 0, 0)
        qtyTxt.hidden = (i > 1)

        -- [+] Stepper Button
        local plusBg = ui.Rectangle.new(artLayer)
        plusBg.colour = COL_BTN_STEP
        plusBg.fill = true
        plusBg.clickthrough = false
        plusBg:SetPos(-154, rowY + 2, 1.0, 0)
        plusBg:SetSize(22, ROW_HEIGHT - 6, 0, 0)
        plusBg:Subscribe(ui.Hook.ONCLICK, function()
            local item = self.currentArtefacts and self.currentArtefacts[rowIdx]
            if item and item.artefact then
                self.tracker:adjustArtefactCount(item.artefact.damagedName, 1, item.rawCount)
                self:refresh()
                self:onHoverArtefactRow(rowIdx)
            end
            return false
        end)
        bindRowHover(plusBg, function()
            self:onHoverArtefactRow(rowIdx)
        end)
        plusBg.hidden = true

        local plusTxt = ui.Text.new(artLayer)
        plusTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        plusTxt.colour = COL_GOLD
        plusTxt.content = "+"
        plusTxt.maxLines = 1
        plusTxt.clickthrough = true
        if ui.AlignMode then
            pcall(function()
                plusTxt.alignHorizontal = ui.AlignMode.CENTRE
                plusTxt.alignVertical = ui.AlignMode.CENTRE
            end)
        end
        plusTxt:SetPos(-154, rowY + 2, 1.0, 0)
        plusTxt:SetSize(22, ROW_HEIGHT - 6, 0, 0)
        plusTxt.hidden = true

        local statusTxt = ui.Text.new(artLayer)
        statusTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        statusTxt.colour = COL_WHITE
        statusTxt.maxLines = 1
        statusTxt.clickthrough = true
        statusTxt:SetPos(-122, rowY + 2, 1.0, 0)
        statusTxt:SetSize(114, ROW_HEIGHT - 2, 0, 0)
        statusTxt.hidden = (i > 1)

        self.artefactRows[i] = {
            bg = bg,
            toggleBg = toggleBg,
            toggleTxt = toggleTxt,
            icon = icon,
            nameTxt = nameTxt,
            lvlTxt = lvlTxt,
            ownedTxt = ownedTxt,
            minusBg = minusBg,
            minusTxt = minusTxt,
            qtyTxt = qtyTxt,
            plusBg = plusBg,
            plusTxt = plusTxt,
            statusTxt = statusTxt
        }
    end
    self._prevVisibleArtRowCount = 1

    -- 5B. MATERIALS VIEW LAYER (Tab 2)
    -- Material Name is locked at 165px wide so 100% of window width expansion goes to Location!
    local tableLayerH = 26 + (MAX_MATERIAL_ROWS * ROW_HEIGHT)
    local tableLayer = ui.Layer.new(container)
    tableLayer.clickthrough = true
    tableLayer:SetPos(0, 172)
    tableLayer:SetSize(0, tableLayerH, 1.0, 0)
    tableLayer.hidden = true
    self.tableLayer = tableLayer

    local tableHeaderBg = ui.Rectangle.new(tableLayer)
    tableHeaderBg.colour = COL_BG_HEADER
    tableHeaderBg.fill = true
    tableHeaderBg:SetPos(8, 0)
    tableHeaderBg:SetSize(-16, 22, 1.0, 0)
    self.tableHeaderBg = tableHeaderBg

    local colHeaderMat = ui.Text.new(tableLayer)
    colHeaderMat.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colHeaderMat.colour = COL_GOLD
    colHeaderMat.content = "Material"
    colHeaderMat.maxLines = 1
    colHeaderMat:SetPos(38, 2, 0, 0)
    colHeaderMat:SetSize(131, 20, 0, 0)
    self.colHeaderMat = colHeaderMat

    local colHeaderLvl = ui.Text.new(tableLayer)
    colHeaderLvl.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colHeaderLvl.colour = COL_GOLD
    colHeaderLvl.content = "Lvl"
    colHeaderLvl.maxLines = 1
    colHeaderLvl:SetPos(173, 2, 0, 0)
    colHeaderLvl:SetSize(32, 20, 0, 0)
    self.colHeaderLvl = colHeaderLvl

    local colHeaderLoc = ui.Text.new(tableLayer)
    colHeaderLoc.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colHeaderLoc.colour = COL_GOLD
    colHeaderLoc.content = "Location"
    colHeaderLoc.maxLines = 1
    colHeaderLoc:SetPos(209, 2, 0, 0)
    colHeaderLoc:SetSize(-390, 20, 1.0, 0)
    self.colHeaderLoc = colHeaderLoc

    local colHeaderProg = ui.Text.new(tableLayer)
    colHeaderProg.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colHeaderProg.colour = COL_GOLD
    colHeaderProg.content = "Owned / Req"
    colHeaderProg.maxLines = 1
    colHeaderProg:SetPos(-175, 2, 1.0, 0)
    colHeaderProg:SetSize(100, 20, 0, 0)
    self.colHeaderProg = colHeaderProg

    local colHeaderShort = ui.Text.new(tableLayer)
    colHeaderShort.font = id.Font.MUSEO_SANS_15PT_REGULAR
    colHeaderShort.colour = COL_GOLD
    colHeaderShort.content = "Short"
    colHeaderShort.maxLines = 1
    colHeaderShort:SetPos(-71, 2, 1.0, 0)
    colHeaderShort:SetSize(63, 20, 0, 0)
    self.colHeaderShort = colHeaderShort

    for i = 1, MAX_MATERIAL_ROWS do
        local rowIdx = i
        local rowY = startY + (i - 1) * ROW_HEIGHT

        local bg = ui.Rectangle.new(tableLayer)
        bg.colour = (i % 2 == 1) and COL_BG_ROW or COL_BG_ALT
        bg.fill = true
        bg.clickthrough = false
        bg:SetPos(8, rowY)
        bg:SetSize(-16, ROW_HEIGHT - 2, 1.0, 0)
        bg.hidden = (i > 1)
        bindRowHover(bg, function()
            self:onHoverMaterialRow(rowIdx)
        end)

        local icon = ui.Sprite.new(tableLayer)
        icon.clickthrough = true
        icon:SetPos(14, rowY + 2, 0, 0)
        icon:SetSize(20, 20)
        icon.hidden = true

        local nameTxt = ui.Text.new(tableLayer)
        nameTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        nameTxt.colour = COL_WHITE
        nameTxt.maxLines = 1
        nameTxt.clickthrough = true
        nameTxt:SetPos(38, rowY + 2, 0, 0)
        nameTxt:SetSize(131, ROW_HEIGHT - 2, 0, 0)
        nameTxt.hidden = (i > 1)

        local lvlTxt = ui.Text.new(tableLayer)
        lvlTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        lvlTxt.colour = COL_CREAM
        lvlTxt.maxLines = 1
        lvlTxt.clickthrough = true
        lvlTxt:SetPos(173, rowY + 2, 0, 0)
        lvlTxt:SetSize(32, ROW_HEIGHT - 2, 0, 0)
        lvlTxt.hidden = (i > 1)

        local locTxt = ui.Text.new(tableLayer)
        locTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        locTxt.colour = COL_MUTED
        locTxt.maxLines = 1
        locTxt.clickthrough = true
        locTxt:SetPos(209, rowY + 2, 0, 0)
        locTxt:SetSize(-390, ROW_HEIGHT - 2, 1.0, 0)
        locTxt.hidden = (i > 1)

        local progTxt = ui.Text.new(tableLayer)
        progTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        progTxt.colour = COL_WHITE
        progTxt.maxLines = 1
        progTxt.clickthrough = true
        progTxt:SetPos(-175, rowY + 2, 1.0, 0)
        progTxt:SetSize(100, ROW_HEIGHT - 2, 0, 0)
        progTxt.hidden = (i > 1)

        local statusTxt = ui.Text.new(tableLayer)
        statusTxt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        statusTxt.colour = COL_WHITE
        statusTxt.maxLines = 1
        statusTxt.clickthrough = true
        statusTxt:SetPos(-71, rowY + 2, 1.0, 0)
        statusTxt:SetSize(63, ROW_HEIGHT - 2, 0, 0)
        statusTxt.hidden = (i > 1)

        self.materialRows[i] = {
            bg = bg,
            icon = icon,
            nameTxt = nameTxt,
            lvlTxt = lvlTxt,
            locTxt = locTxt,
            progTxt = progTxt,
            statusTxt = statusTxt
        }
    end
    self._prevVisibleRowCount = 1
end

local cachedBodyFont = nil
local cachedFontChecked = false
local function getBodyFont()
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

-- Conservative character pixel widths for MUSEO_SANS_15PT_REGULAR when font metrics API is unavailable
local function getCharPxWidth(c)
    local b = string.byte(c)
    if not b then return 8 end
    if b >= 65 and b <= 90 then -- A-Z
        if c == "W" or c == "M" then return 13 end
        if c == "I" or c == "J" then return 5 end
        return 10.5
    elseif b >= 97 and b <= 122 then -- a-z
        if c == "w" or c == "m" then return 11 end
        if c == "i" or c == "l" or c == "j" or c == "t" or c == "f" then return 4.5 end
        if c == "r" then return 5.5 end
        return 8.0
    elseif b >= 48 and b <= 57 then -- 0-9
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
local function getStringPxWidth(str)
    local cached = wordWidthCache[str]
    if cached then return cached end
    local font = getBodyFont()
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

-- Rendered line height of MUSEO_SANS_15PT_REGULAR (queried from the font when available)
local TEXT_LINE_H = nil
local function getLineHeight()
    if TEXT_LINE_H then return TEXT_LINE_H end
    TEXT_LINE_H = 19
    local font = getBodyFont()
    if font then
        pcall(function()
            local h = font.lineHeight or (font.GetLineHeight and font:GetLineHeight())
            if type(h) == "number" and h >= 12 and h <= 30 then
                TEXT_LINE_H = math.ceil(h)
            end
        end)
    end
    return TEXT_LINE_H
end

-- Counts wrapped lines: prefer the client's own wrapping (exactly matches rendering),
-- fall back to conservative word-by-word pixel measurement.
local function countWrappedLines(text, width)
    local font = getBodyFont()
    if font and font.GetStringLineCount then
        local ok, count = pcall(font.GetStringLineCount, font, text, width, false, false, false)
        if ok and type(count) == "number" and count >= 1 then
            return math.floor(count)
        end
    end
    local limit = math.max(60, width - 8)
    if getStringPxWidth(text) <= limit then
        return 1
    end
    local spaceW = 5.0
    local lines, curW = 1, 0
    for word in string.gmatch(text, "%S+") do
        local wordW = getStringPxWidth(word)
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
local function measureWrappedTextHeight(text, wrapWidth)
    local lineH = getLineHeight()
    if type(text) ~= "string" or text == "" then
        return lineH + 4
    end
    -- Floor to 4px steps: cheap to cache while resizing, but never narrower than the real
    -- text box by more than 3px (avoids predicting phantom extra lines)
    local w = math.max(80, math.floor((wrapWidth or 380) / 4) * 4)
    local cacheKey = tostring(w) .. "|" .. text
    local cached = wrapHeightCache[cacheKey]
    if cached then
        return cached
    end
    local h = countWrappedLines(text, w) * lineH + 4
    wrapHeightCache[cacheKey] = h
    return h
end

-- Single shared floating tooltip for table rows and sync badges
function Window:buildSharedRowTooltip(parent)
    local tipRoot = ui.Layer.new(parent)
    tipRoot.clickthrough = true
    tipRoot.hidden = true
    tipRoot:SetSize(380, 90)

    local border = ui.Rectangle.new(tipRoot)
    border.colour = COL_GOLD
    border.fill = true
    border.clickthrough = true
    border:SetPos(0, 0)
    border:SetSize(0, 0, 1.0, 1.0)

    local bg = ui.Rectangle.new(tipRoot)
    bg.colour = makeColour(0.05, 0.08, 0.12, 0.96)
    bg.fill = true
    bg.clickthrough = true
    bg:SetPos(1, 1)
    bg:SetSize(-2, -2, 1.0, 1.0)

    local function makeTipText(colour, yPos)
        local txt = ui.Text.new(tipRoot)
        txt.font = id.Font.MUSEO_SANS_15PT_REGULAR
        txt.colour = colour
        txt.maxLines = 0
        txt.clickthrough = true
        if ui.AlignMode then
            pcall(function()
                txt.alignHorizontal = ui.AlignMode.TOPLEFT
                txt.alignVertical = ui.AlignMode.TOPLEFT
            end)
        end
        txt:SetPos(8, yPos)
        txt:SetSize(-16, 18, 1.0, 0)
        return txt
    end

    self.tooltipRoot = tipRoot
    self.tooltipBorder = border
    self.tooltipTitle = makeTipText(COL_GOLD, 6)
    self.tooltipSub = makeTipText(COL_WHITE, 26)
    self.tooltipDetail = makeTipText(COL_CREAM, 48)
end

function Window:showRowTooltip(titleText, subText, detailText, titleCol)
    if not self.tooltipRoot or not self.isVisible then
        return
    end
    local tipW = 380
    local availTxtW = tipW - 16
    local hTitle  = measureWrappedTextHeight(titleText, availTxtW)
    local hSub    = measureWrappedTextHeight(subText, availTxtW)
    local hDetail = measureWrappedTextHeight(detailText, availTxtW)
    local tipH = 6 + hTitle + 3 + hSub + 3 + hDetail + 6

    self.tooltipBorder.colour = titleCol or COL_GOLD
    self.tooltipTitle.colour = titleCol or COL_GOLD
    self.tooltipTitle.content = titleText
    self.tooltipTitle:SetPos(8, 6)
    self.tooltipTitle:SetSize(-16, hTitle, 1.0, 0)

    local subY = 6 + hTitle + 3
    self.tooltipSub.content = subText
    self.tooltipSub:SetPos(8, subY)
    self.tooltipSub:SetSize(-16, hSub, 1.0, 0)

    local detailY = subY + hSub + 3
    self.tooltipDetail.content = detailText
    self.tooltipDetail:SetPos(8, detailY)
    self.tooltipDetail:SetSize(-16, hDetail, 1.0, 0)

    local mx, my = getScaledMousePos((self.root and self.root.x or 100) + 120, (self.root and self.root.y or 100) + 120)
    local tx = math.floor(mx + 16)
    local ty = math.floor(my + 14)

    if self.parent and self.parent.width and self.parent.height and self.parent.width > 100 then
        if tx + tipW > self.parent.width - 8 then
            tx = math.max(8, math.floor(mx - tipW - 12))
        end
        if ty + tipH > self.parent.height - 8 then
            ty = math.max(8, math.floor(my - tipH - 10))
        end
    end

    self.tooltipRoot:SetPos(tx, ty)
    self.tooltipRoot:SetSize(tipW, tipH)
    self.tooltipRoot.hidden = false
    self.tooltipRoot:MoveToFront()
end

function Window:hideRowTooltip()
    if self.tooltipRoot and not self.tooltipRoot.hidden then
        self.tooltipRoot.hidden = true
    end
end

function Window:onHoverSyncBadge(badgeKind)
    if self._isResizing then return end
    local status = self.tracker:getSyncStatus()
    local mode = self.tracker:getSourceMode()
    local isStorage = (badgeKind == "storage")
    local s = isStorage and status.storage or status.bank
    local name = isStorage and "Material Storage" or "Bank"
    local openHint = isStorage
        and "Open Material Storage (at a workbench) or check Material storage information in your Archaeology journal to sync."
        or "Open your Bank to sync."
    local contents = isStorage
        and string.format("%d material types stored.", s.matTypes or 0)
        or string.format("%d material types, %d damaged artefact types.", s.matTypes or 0, s.artTypes or 0)

    if not s.enabled then
        self:showRowTooltip(
            name .. ": Ignored",
            "Current source mode: " .. mode.label .. ".",
            "Click the Src button to include " .. name .. " in calculations.",
            COL_MUTED
        )
    elseif s.synced then
        self:showRowTooltip(
            name .. ": Synced",
            "Read live this session. " .. contents,
            "Updates automatically while open. Changes made elsewhere (e.g. another device) need a resync.",
            COL_GREEN
        )
    elseif s.cached then
        self:showRowTooltip(
            name .. ": Cached - resync recommended",
            "Using counts saved from a previous session. " .. contents,
            openHint .. " Counts may be out of date if changed on another device.",
            COL_AMBER
        )
    else
        self:showRowTooltip(
            name .. ": Not synced",
            "No data yet - " .. name .. " contents are not being counted.",
            openHint,
            COL_RED
        )
    end
end

function Window:onHoverArtefactRow(rowIdx)
    if self._isResizing then return end
    local item = self.currentArtefacts and self.currentArtefacts[rowIdx]
    if not item or not item.artefact then
        self:hideRowTooltip()
        return
    end
    local art = item.artefact
    local title = string.format("%s (Lv %d) | %s XP | %s Chronotes", art.name, art.level or 1, formatInt(art.xp), formatInt(art.chronotes))
    local sub = string.format(
        "Owned: %d (Bag: %d, Bank: %d) | Included: %d",
        item.rawCount, item.inBag, item.inBank, item.effectiveCount
    )
    local reqParts = {}
    local mult = math.max(1, item.effectiveCount > 0 and item.effectiveCount or 1)
    for _, req in ipairs(art.materials or {}) do
        local owned = self.tracker:getOwnedMaterialCount(req.name)
        local needed = req.count * mult
        table.insert(reqParts, string.format("%s (%s/%s)", req.name, formatInt(owned), formatInt(needed)))
    end
    local detail = string.format("Materials (%dx): %s", mult, table.concat(reqParts, ", "))
    self:showRowTooltip(title, sub, detail, COL_GOLD)
end

function Window:onHoverMaterialRow(rowIdx)
    if self._isResizing then return end
    local item = self.currentMaterials and self.currentMaterials[rowIdx]
    if not item then
        self:hideRowTooltip()
        return
    end
    local mat = item.material
    local lvlStr = (mat and mat.isArchMaterial == false) and "Secondary" or ("Lv " .. tostring((mat and mat.level) or 1))
    local title = string.format("%s (%s)", item.name, lvlStr)
    local locStr = (mat and mat._cachedLoc and mat._cachedLoc ~= "-") and mat._cachedLoc or "None / Secondary"
    local sub = string.format(
        "Owned: %s (Bag: %s, Storage: %s, Bank: %s) | Req: %s | Remaining: %s",
        formatInt(item.owned),
        formatInt(item.ownedBag or 0),
        formatInt(item.ownedStorage or 0),
        formatInt(item.ownedBank or 0),
        formatInt(item.required),
        item.short > 0 and formatInt(item.short) or "Ready"
    )
    local detail = string.format("Locations: %s", locStr)
    self:showRowTooltip(title, sub, detail, COL_GOLD)
end

function Window:getAvailableContentWidth()
    local cw = nil
    if self.win and self.win._scroll and self.win._scroll.contentWidth and self.win._scroll.contentWidth > 100 then
        cw = self.win._scroll.contentWidth - 16
    elseif self.contentParent and self.contentParent.width and self.contentParent.width > 100 then
        cw = self.contentParent.width - 16
    elseif self.root and self.root.width and self.root.width > 100 then
        cw = self.root.width - 28
    end
    local availW = math.max(360, math.floor(cw or 480))
    if self._isResizing then
        availW = math.floor(availW / 8) * 8
    end
    return availW
end

function Window:updateToolbarLayout(forceReflow)
    if self._inLayout or not self.root or not self.btnSource then
        return
    end

    local availW = self:getAvailableContentWidth()
    local isArtTab = (self.activeTab == "artefacts")
    if not forceReflow and self._lastAvailW == availW and self._lastTabLayout == isArtTab then
        return
    end

    self._inLayout = true

    -- Run reflowDynamicContent first so SetContentHeight updates scrollbar visibility and _scroll.contentWidth
    self:reflowDynamicContent(availW, forceReflow)

    -- Re-read availW after SetContentHeight in case the scrollbar appeared or disappeared!
    local updatedAvailW = self:getAvailableContentWidth()
    if updatedAvailW ~= availW then
        availW = updatedAvailW
        self:reflowDynamicContent(availW, true)
    end

    if forceReflow or self._lastAvailW ~= availW or self._lastTabLayout ~= isArtTab then
        self._lastAvailW = availW
        self._lastTabLayout = isArtTab
        local gap = 6

        -- Row 1: Top View Tabs (Artefacts | Materials) at y = 6
        local tabW = math.floor((availW - gap) * 0.5)
        self.btnTabArtefacts.setBounds(8, 6, tabW, 26)
        self.btnTabMaterials.setBounds(8 + tabW + gap, 6, availW - tabW - gap, 26)

        -- Row 2: Contextual 3-Button Control Toolbar + 2 Sync Status Badges at y = 36
        self.btnPin.setHidden(not isArtTab)
        self.btnFilter.setHidden(isArtTab)

        local badgesTotalW = BADGE_W * 2 + gap

        local totalBtnsW = math.max(240, availW - badgesTotalW - (gap * 3))
        local wSource = math.floor(totalBtnsW * 0.37)
        local wDupes  = math.floor(totalBtnsW * 0.34)
        local wThird  = totalBtnsW - (wSource + wDupes)

        local x1 = 8
        local x2 = x1 + wSource + gap
        local x3 = x2 + wDupes + gap
        local xStor = x3 + wThird + gap
        local xBank = xStor + BADGE_W + gap

        self.btnSource.setBounds(x1, 36, wSource, 26)
        self.btnDupes.setBounds(x2, 36, wDupes, 26)
        if isArtTab then
            self.btnPin.setBounds(x3, 36, wThird, 26)
        else
            self.btnFilter.setBounds(x3, 36, wThird, 26)
        end

        if self.badgeStorage then
            self.badgeStorage.setBounds(xStor, 36, BADGE_W, 26)
        end
        if self.badgeBank then
            self.badgeBank.setBounds(xBank, 36, BADGE_W, 26)
        end

    end

    self._inLayout = false
end

function Window:reflowDynamicContent(availW, forceReflow)
    if not self.summaryBg or not self.tableLayer or not self.artefactTableLayer then
        return
    end

    -- Summary text boxes span the container minus 14px padding each side (= availW - 12)
    local textWrapWidth = math.max(160, (availW or 480) - 12)

    -- 1. Measure Summary Card height
    local summaryY = 68
    local hSumTitle = measureWrappedTextHeight(self.summaryTitle.content, textWrapWidth)
    local hDeficit  = measureWrappedTextHeight(self.deficitSummary.content, textWrapWidth)
    local summaryBgH = 5 + hSumTitle + 3 + hDeficit + 5

    local tableHeaderY = summaryY + summaryBgH + 6

    -- Only invoke SetPos/SetSize on summary card & table layers when line-wrap heights actually change!
    if forceReflow
        or self._lastSummaryBgH ~= summaryBgH
        or self._lastTableHeaderY ~= tableHeaderY
    then
        self._lastSummaryBgH = summaryBgH
        self._lastTableHeaderY = tableHeaderY

        self.summaryBg:SetPos(8, summaryY)
        self.summaryBg:SetSize(-16, summaryBgH, 1.0, 0)
        self.summaryTitle:SetPos(14, summaryY + 4)
        self.summaryTitle:SetSize(-28, hSumTitle, 1.0, 0)
        self.deficitSummary:SetPos(14, summaryY + 4 + hSumTitle + 3)
        self.deficitSummary:SetSize(-28, hDeficit, 1.0, 0)

        self.artefactTableLayer:SetPos(0, tableHeaderY)
        self.tableLayer:SetPos(0, tableHeaderY)
    end

    -- Update Scrollable Content Height for the active tab only when it changes
    -- (an empty table is hidden entirely, so it contributes no height)
    local isArt = (self.activeTab == "artefacts")
    local activeRows = isArt and (self.visibleArtRowCount or 0) or (self.visibleRowCount or 0)
    local totalContentHeight
    if activeRows <= 0 then
        totalContentHeight = tableHeaderY + 4
    else
        totalContentHeight = tableHeaderY + 24 + (activeRows * ROW_HEIGHT) + 10
    end
    if self._lastContentHeight ~= totalContentHeight then
        self._lastContentHeight = totalContentHeight
        if self.win and self.win.SetContentHeight then
            self.win:SetContentHeight(totalContentHeight)
        end
    end
end

function Window:onWindowGeometryChanged()
    if self._inLayout or not self.root then return end

    local rx = math.floor(self.root.x or DEFAULT_X)
    local ry = math.floor(self.root.y or DEFAULT_Y)
    local rw = math.floor(self.root.width or DEFAULT_W)
    local rh = math.floor(self.root.height or DEFAULT_H)

    if self.parent and self.parent.width and self.parent.height and self.parent.width > 100 then
        local maxX = math.max(0, self.parent.width - rw)
        local maxY = math.max(0, self.parent.height - rh)
        local clampedX = clamp(rx, 0, maxX)
        local clampedY = clamp(ry, 0, maxY)
        if clampedX ~= rx or clampedY ~= ry then
            rx, ry = clampedX, clampedY
            self.root:SetPos(rx, ry)
        end
    end

    -- Defer disk/DB writes while actively dragging resize handles to prevent frame stutter
    if not self._isResizing then
        if rx ~= self._savedX or ry ~= self._savedY or rw ~= self._savedW or rh ~= self._savedH then
            self._savedX, self._savedY, self._savedW, self._savedH = rx, ry, rw, rh
            safeDbSet("arch_win_x", rx)
            safeDbSet("arch_win_y", ry)
            safeDbSet("arch_win_w", rw)
            safeDbSet("arch_win_h", rh)
        end
    end

    self:updateToolbarLayout(false)
end

function Window:setWindowVisible(visible)
    self.isVisible = (visible == true)
    if not self.isVisible then
        self:hideRowTooltip()
    end
    safeDbSet("arch_win_visible", self.isVisible and 1 or 0)
    if self.win then
        if self.isVisible then
            self.win:Show()
            self:updateToolbarLayout(true)
            self:refresh()
        else
            self.win:Close()
        end
    elseif self.root then
        setComponentHidden(self.root, not self.isVisible)
    end
    self:refreshHub()
end

function Window:resetWindowGeometry()
    safeDbSet("arch_win_x", DEFAULT_X)
    safeDbSet("arch_win_y", DEFAULT_Y)
    safeDbSet("arch_win_w", DEFAULT_W)
    safeDbSet("arch_win_h", DEFAULT_H)
    if self.win then
        self.win.root:SetPos(DEFAULT_X, DEFAULT_Y)
        self.win:SetSize(DEFAULT_W, DEFAULT_H)
        self:setWindowVisible(true)
    elseif self.root then
        self.root:SetPos(DEFAULT_X, DEFAULT_Y)
        self.root:SetSize(DEFAULT_W, DEFAULT_H)
    end
    self:updateToolbarLayout(true)
end

-- Populates the PrettyUI Ribbon Bar hub panel with just the single Show/Hide Window button
function Window:populateRibbonHub(parent)
    self.hubParent = parent
    pcall(function() parent:DeleteAll() end)

    local btn = ui.Button.new(parent)
    btn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    btn:SetPos(12, 12)
    btn:SetSize(-24, 30, 1.0, 0)
    btn.label = self.isVisible and "Hide Assistant Window" or "Show Assistant Window"
    btn:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        if self:tryMount() then
            self:setWindowVisible(not self.isVisible)
        end
    end)
    self.hubToggleBtn = btn
end

function Window:refreshHub()
    if self.hubToggleBtn then
        pcall(function()
            self.hubToggleBtn.label = self.isVisible and "Hide Assistant Window" or "Show Assistant Window"
        end)
    end
end

function Window:refresh()
    if not self.mounted then
        if not self:tryMount() then
            return
        end
    end

    local t = self.tracker
    local res = t.lastResult or t:recalculate()
    local mode = t:getSourceMode()

    local artList = res.artefacts or {}
    local matList = res.filteredMaterials or {}
    self.currentArtefacts = artList
    self.currentMaterials = matList

    -- 1. Update Window Title, Tabs & Toolbar Buttons
    local winTitle = t.isPinned and "Archaeology Assistant [PINNED]" or "Archaeology Assistant"
    if self.win and self.win.SetTitle then
        self.win:SetTitle(winTitle)
    end

    local isArtTab = (self.activeTab == "artefacts")
    self.btnTabArtefacts.setLabel(string.format("Artefacts (%d)", #artList))
    self.btnTabArtefacts.setActive(isArtTab)
    self.btnTabMaterials.setLabel(string.format("Materials (%d)", #matList))
    self.btnTabMaterials.setActive(not isArtTab)

    self.artefactTableLayer.hidden = (not isArtTab) or (#artList == 0)
    self.tableLayer.hidden = isArtTab or (#matList == 0)

    self.btnSource.setLabel(mode.shortLabel)
    if t.hasCustomCounts and t:hasCustomCounts() then
        self.btnDupes.setLabel("Dupes: Custom")
    else
        self.btnDupes.setLabel(t.includeDuplicates and "Dupes: All" or "Dupes: 1x")
    end
    self.btnFilter.setLabel(t.shortOnly and "Short Only" or "Show: All")
    self.btnFilter.setActive(t.shortOnly)
    self.btnPin.setLabel(t.isPinned and "Unpin" or "Pin")
    self.btnPin.setActive(t.isPinned)

    -- 2. Update Compact Sync Status Icon Badges
    local syncStatus = t:getSyncStatus()
    local function getBadgeState(s)
        if not s.enabled then return "ignored" end
        if s.synced then return "synced" end
        if s.cached then return "cached" end
        return "missing"
    end
    if self.badgeStorage then
        self.badgeStorage.setState(getBadgeState(syncStatus.storage))
        if t.storageIconObjId then
            self.badgeStorage.setIcon(t.storageIconObjId)
        end
    end
    if self.badgeBank then
        self.badgeBank.setState(getBadgeState(syncStatus.bank))
    end

    -- 3. Update Artefact & Deficit Summary Card
    if #artList == 0 then
        local noArtsMsg = "No Damaged Artefacts Found in " .. ((mode.id == "BAG_ONLY") and "Backpack" or "Backpack or Bank")
        self.summaryTitle.content = t.isPinned
            and "No Pinned Artefacts"
            or noArtsMsg
        self.summaryTitle.colour = COL_MUTED
        self.deficitSummary.content = string.format("Carry damaged artefacts to calculate materials | Source: %s", mode.label)
        self.deficitSummary.colour = COL_CREAM
    elseif res.totalArtefacts == 0 then
        self.summaryTitle.content = string.format("0 of %d Artefact Types Included (All Toggled Off)", #artList)
        self.summaryTitle.colour = COL_MUTED
        self.deficitSummary.content = "Toggle artefacts On or click '+' in the Artefacts tab to calculate materials."
        self.deficitSummary.colour = COL_CREAM
    else
        local pinTag = t.isPinned and "[Pinned] " or ""
        self.summaryTitle.content = string.format(
            "%s%d Included (%d Repairable Now) | %s XP | %s Chronotes",
            pinTag,
            res.totalArtefacts,
            res.restorableArtefacts,
            formatInt(res.totalXp),
            formatInt(res.totalChronotes)
        )
        self.summaryTitle.colour = (res.distinctMaterialsShort == 0) and COL_GREEN or COL_GOLD

        if res.distinctMaterialsShort == 0 then
            self.deficitSummary.content = string.format(
                "All %d required material types ready! (%s)",
                res.distinctMaterialsRequired,
                mode.label
            )
            self.deficitSummary.colour = COL_GREEN
        else
            self.deficitSummary.content = string.format(
                "Short: %d of %d material types (%s total missing) | %s",
                res.distinctMaterialsShort,
                res.distinctMaterialsRequired,
                formatInt(res.totalMaterialsShort),
                mode.label
            )
            self.deficitSummary.colour = COL_AMBER
        end
    end

    -- 4A. Populate Scrollable Artefact Rows
    local totalArts = #artList
    local visibleArtRowCount = math.min(MAX_ARTEFACT_ROWS, totalArts)
    local maxTouchArtIdx = math.max(visibleArtRowCount, self._prevVisibleArtRowCount or 1)
    self._prevVisibleArtRowCount = visibleArtRowCount

    for slotIdx = 1, maxTouchArtIdx do
        local rowUI = self.artefactRows[slotIdx]
        local item = artList[slotIdx]

        if item then
            local objId = item.artefact and item.artefact.id
            if objId and objId > 0 and rowUI.icon then
                local ok = pcall(function()
                    rowUI.icon:SetAssociatedObject(math.tointeger(objId) or objId)
                    rowUI.icon.associatedObjectQuantity = 1
                    if ui.ObjectQuantityDisplayMode then
                        rowUI.icon.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
                    end
                end)
                rowUI.icon.hidden = not ok
            elseif rowUI.icon then
                rowUI.icon.hidden = true
            end

            rowUI.bg.hidden = false
            rowUI.toggleBg.hidden = false
            rowUI.toggleTxt.hidden = false
            rowUI.nameTxt.hidden = false
            rowUI.lvlTxt.hidden = false
            rowUI.ownedTxt.hidden = false
            rowUI.minusBg.hidden = false
            rowUI.minusTxt.hidden = false
            rowUI.qtyTxt.hidden = false
            rowUI.plusBg.hidden = false
            rowUI.plusTxt.hidden = false
            rowUI.statusTxt.hidden = false

            rowUI.nameTxt.content = item.artefact.name
            rowUI.lvlTxt.content = tostring(item.artefact.level or 1)

            if item.inBag > 0 and item.inBank > 0 then
                rowUI.ownedTxt.content = string.format("%d (%d/%d)", item.rawCount, item.inBag, item.inBank)
            elseif item.inBag > 0 then
                rowUI.ownedTxt.content = string.format("%d (Bag)", item.inBag)
            elseif item.inBank > 0 then
                rowUI.ownedTxt.content = string.format("%d (Bank)", item.inBank)
            else
                rowUI.ownedTxt.content = string.format("%d (Pin)", item.rawCount)
            end
            rowUI.ownedTxt.colour = COL_MUTED

            rowUI.qtyTxt.content = tostring(item.effectiveCount)

            if item.excluded or item.effectiveCount == 0 then
                rowUI.toggleBg.colour = COL_BTN_OFF
                rowUI.toggleTxt.content = "Off"
                rowUI.toggleTxt.colour = COL_MUTED
                rowUI.nameTxt.colour = COL_MUTED
                rowUI.lvlTxt.colour = COL_MUTED
                rowUI.qtyTxt.colour = COL_MUTED
                if item.maxPossibleNow >= 1 then
                    rowUI.statusTxt.content = "Off (Can Repair)"
                    rowUI.statusTxt.colour = COL_MUTED
                else
                    rowUI.statusTxt.content = "Excluded"
                    rowUI.statusTxt.colour = COL_MUTED
                end
            else
                rowUI.toggleBg.colour = COL_BTN_ON
                rowUI.toggleTxt.content = "On"
                rowUI.toggleTxt.colour = COL_WHITE
                rowUI.qtyTxt.colour = COL_WHITE

                if item.maxPossibleNow >= item.effectiveCount then
                    if item.effectiveCount > 1 then
                        rowUI.statusTxt.content = string.format("Ready (%d/%d)", item.effectiveCount, item.effectiveCount)
                    else
                        rowUI.statusTxt.content = "Ready"
                    end
                    rowUI.nameTxt.colour = COL_GREEN
                    rowUI.lvlTxt.colour = COL_GREEN
                    rowUI.statusTxt.colour = COL_GREEN
                elseif item.maxPossibleNow > 0 then
                    rowUI.statusTxt.content = string.format("%d / %d Ready", item.maxPossibleNow, item.effectiveCount)
                    rowUI.nameTxt.colour = COL_WHITE
                    rowUI.lvlTxt.colour = COL_CREAM
                    rowUI.statusTxt.colour = COL_AMBER
                else
                    rowUI.statusTxt.content = string.format(
                        "Short (%d mat%s)",
                        item.missingMatTypes or 1,
                        (item.missingMatTypes == 1) and "" or "s"
                    )
                    rowUI.nameTxt.colour = COL_WHITE
                    rowUI.lvlTxt.colour = COL_CREAM
                    rowUI.statusTxt.colour = COL_RED
                end
            end
        else
            if rowUI.icon then rowUI.icon.hidden = true end
            rowUI.bg.hidden = true
            rowUI.toggleBg.hidden = true
            rowUI.toggleTxt.hidden = true
            rowUI.nameTxt.hidden = true
            rowUI.lvlTxt.hidden = true
            rowUI.ownedTxt.hidden = true
            rowUI.minusBg.hidden = true
            rowUI.minusTxt.hidden = true
            rowUI.qtyTxt.hidden = true
            rowUI.plusBg.hidden = true
            rowUI.plusTxt.hidden = true
            rowUI.statusTxt.hidden = true
        end
    end

    -- 4B. Populate Scrollable Material Rows
    local totalItems = #matList
    local visibleRowCount = math.min(MAX_MATERIAL_ROWS, totalItems)
    local maxTouchIdx = math.max(visibleRowCount, self._prevVisibleRowCount or 1)
    self._prevVisibleRowCount = visibleRowCount

    for slotIdx = 1, maxTouchIdx do
        local rowUI = self.materialRows[slotIdx]
        local item = matList[slotIdx]

        if item then
            local mat = item.material
            local objId = mat and mat.id
            if objId and objId > 0 and rowUI.icon then
                local ok = pcall(function()
                    rowUI.icon:SetAssociatedObject(math.tointeger(objId) or objId)
                    rowUI.icon.associatedObjectQuantity = 1
                    if ui.ObjectQuantityDisplayMode then
                        rowUI.icon.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
                    end
                end)
                rowUI.icon.hidden = not ok
            elseif rowUI.icon then
                rowUI.icon.hidden = true
            end

            if mat and not mat._cachedLoc then
                if mat.caches and #mat.caches > 0 then
                    mat._cachedLoc = table.concat(mat.caches, ", ")
                else
                    mat._cachedLoc = "-"
                end
            end

            rowUI.bg.hidden = false
            rowUI.nameTxt.hidden = false
            rowUI.lvlTxt.hidden = false
            rowUI.locTxt.hidden = false
            rowUI.progTxt.hidden = false
            rowUI.statusTxt.hidden = false

            rowUI.nameTxt.content = item.name
            rowUI.lvlTxt.content = (mat and mat.isArchMaterial == false) and "-" or tostring((mat and mat.level) or 1)
            rowUI.locTxt.content = (mat and mat._cachedLoc) or "-"
            rowUI.progTxt.content = string.format("%s / %s", formatInt(item.owned), formatInt(item.required))

            if item.short > 0 then
                rowUI.statusTxt.content = formatInt(item.short)
                rowUI.nameTxt.colour = COL_WHITE
                rowUI.lvlTxt.colour = COL_CREAM
                rowUI.locTxt.colour = COL_MUTED
                rowUI.progTxt.colour = (item.owned > 0) and COL_AMBER or COL_RED
                rowUI.statusTxt.colour = (item.owned > 0) and COL_AMBER or COL_RED
            else
                rowUI.statusTxt.content = "Ready"
                rowUI.nameTxt.colour = COL_GREEN
                rowUI.lvlTxt.colour = COL_GREEN
                rowUI.locTxt.colour = COL_MUTED
                rowUI.progTxt.colour = COL_GREEN
                rowUI.statusTxt.colour = COL_GREEN
            end
        else
            if rowUI.icon then rowUI.icon.hidden = true end
            rowUI.bg.hidden = true
            rowUI.nameTxt.hidden = true
            rowUI.lvlTxt.hidden = true
            rowUI.locTxt.hidden = true
            rowUI.progTxt.hidden = true
            rowUI.statusTxt.hidden = true
        end
    end

    -- Reflow wrapped text banners, table layer position, and scrollable content height
    self.visibleArtRowCount = visibleArtRowCount
    self.visibleRowCount = visibleRowCount
    self:updateToolbarLayout(true)
    self:refreshHub()
end

function Window:shutdown()
    if Event and Event.ContentLayerReady and Event.ContentLayerReady.Unsubscribe then
        pcall(function() Event.ContentLayerReady.Unsubscribe(HUB_EVENT_ID) end)
    end
    if Event and Event.Logic and Event.Logic.Unsubscribe then
        pcall(function() Event.Logic.Unsubscribe(MOUNT_EVENT_ID) end)
    end
    if self.tooltipRoot and self.tooltipRoot.Destroy then
        pcall(function() self.tooltipRoot:Destroy() end)
        self.tooltipRoot = nil
    end
    for _, h in ipairs({ self.resizeRight, self.resizeBottom, self.resizeCorner }) do
        if h and h.Destroy then
            pcall(function() h:Destroy() end)
        end
    end
    self.resizeRight = nil
    self.resizeBottom = nil
    self.resizeCorner = nil
    if self.win and self.win.Destroy then
        pcall(function() self:onWindowGeometryChanged() end)
        pcall(function() self.win:Destroy() end)
        self.win = nil
    end
end

return Window

