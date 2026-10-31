-- ui/window.lua
-- In-game movable, resizable, scrollable UI controller for the Archaeology Assistant plugin.
-- Built on PrettyUI (dependency 6398181) with RS3 Ribbon Bar hub integration.
-- Delegates theme/text metrics to ui/theme, floating tooltips to ui/tooltip, and widget construction to ui/widgets.

local Utils = require("core/utils")
local DB = require("core/db")
local Theme = require("ui/theme")
local Tooltip = require("ui/tooltip")
local Widgets = require("ui/widgets")

local okOverlay, Overlay = xpcall(function()
    return require("ui/overlay")
end, function(err)
    print("[ArchAssistant ERROR] Failed to require('ui/overlay'): " .. tostring(err))
end)

local Window = {}
Window.__index = Window

local COL_FILTER_MODES = {
    { id = "all",        label = "Show: All"     },
    { id = "incomplete", label = "Incomplete"    },
    { id = "targeted",   label = "Targeted"      },
    { id = "tetra",      label = "Tetra Pieces"  },
    { id = "powers",     label = "Powers/Relics" },
    { id = "unsynced",   label = "Unsynced"      }
}

local HUB_EVENT_ID = "arch_assistant_hub"
local MOUNT_EVENT_ID = "arch_assistant_mount"
local RESIZE_EVENT_ID = "arch_assistant_resize"

function Window.new(tracker)
    local self = setmetatable({}, Window)
    self.tracker = tracker
    self.mounted = false
    self.activeTab = DB.get("arch_active_tab", "collections")
    self.colFilterIndex = 1
    self.collectionRows = {}
    self.currentCollections = {}
    self.materialRows = {}
    self.artefactRows = {}
    self.currentArtefacts = {}
    self.currentMaterials = {}
    self.hubParent = nil
    self.hubToggleBtn = nil
    self.overlay = nil
    self.tooltip = nil

    if okOverlay and Overlay then
        local okO, oInstance = xpcall(function()
            return Overlay.new(tracker)
        end, function(err)
            print("[ArchAssistant ERROR] Failed to instantiate Overlay: " .. tostring(err))
        end)
        if okO and oInstance then
            self.overlay = oInstance
        end
    end

    self.isVisible = DB.getBool("arch_win_visible", true)

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

-- ============================================================================
-- Window Mounting & Construction
-- ============================================================================

function Window:tryMount()
    if self.mounted then return true end

    local parent = Theme.resolveParent()
    if not parent then return false end
    self.parent = parent

    local savedX = tonumber(DB.get("arch_win_x", Theme.DEFAULT_X)) or Theme.DEFAULT_X
    local savedY = tonumber(DB.get("arch_win_y", Theme.DEFAULT_Y)) or Theme.DEFAULT_Y
    local savedW = math.max(Theme.MIN_W, tonumber(DB.get("arch_win_w", Theme.DEFAULT_W)) or Theme.DEFAULT_W)
    local savedH = math.max(Theme.MIN_H, tonumber(DB.get("arch_win_h", Theme.DEFAULT_H)) or Theme.DEFAULT_H)

    if parent.width and parent.width > 100 then
        savedW = math.min(savedW, parent.width)
        savedX = Utils.clamp(savedX, 0, math.max(0, parent.width - savedW))
    end
    if parent.height and parent.height > 100 then
        savedH = math.min(savedH, parent.height)
        savedY = Utils.clamp(savedY, 0, math.max(0, parent.height - savedH))
    end

    if prettyui and prettyui.Window then
        self:buildPrettyWindow(parent, savedX, savedY, savedW, savedH)
    else
        self:buildFallbackWindow(parent, savedX, savedY, savedW, savedH)
    end

    self.mounted = true
    return true
end

function Window:handleScrollWheel(comp, delta)
    self:hideRowTooltip()
    local onWheel = (self.win and self.win._onScrollWheel)
        or (self.win and self.win._scroll and self.win._scroll._onScrollWheel)
    if onWheel then
        return onWheel(comp, delta)
    elseif self.win and self.win.ScrollBy then
        self.win:ScrollBy(delta * (self.win.scrollStep or 28))
        return false
    end
    return false
end

function Window:createToolbarButton(parent, label, tooltipText, toggleable, onClick)
    return Widgets.createToolbarButton(parent, label, tooltipText, toggleable, onClick, function(comp, delta)
        return self:handleScrollWheel(comp, delta)
    end)
end

function Window:buildPrettyWindow(parent, x, y, w, h)
    local win = prettyui.Window.new(parent, {
        title = "Archaeology Assistant",
        x = x,
        y = y,
        width = w,
        height = h,
        minWidth = Theme.MIN_W,
        minHeight = Theme.MIN_H,
        resizable = true,
        scrollable = true,
        scrollStep = 28,
        onClose = function()
            self.isVisible = false
            self:hideRowTooltip()
            DB.setBool("arch_win_visible", false)
            self:refreshHub()
        end
    })

    self.win = win
    self.root = win.root
    self.contentParent = win.content

    self:buildContentComponents(win.content)
    self.tooltip = Tooltip.new(parent, function(comp, delta)
        return self:handleScrollWheel(comp, delta)
    end)
    Widgets.addCornerResizeGrip(win.root)

    -- Expand PrettyUI's south-east ('se') corner resize handle to a generous 26x26 click box
    if win.resize and win.resize._Refresh and win.resize.handles and win.resize.handles.se then
        local origRefresh = win.resize._Refresh
        win.resize._Refresh = function(resSelf, raise)
            origRefresh(resSelf, raise)
            local drag = resSelf.dragState
            local expanded = drag and drag.captureExpanded
            local se = resSelf.handles and resSelf.handles.se
            if se and not expanded and resSelf.root and not se.hidden then
                local cornerSize = 26
                local rx = resSelf.root.x or 0
                local ry = resSelf.root.y or 0
                local rw = resSelf.root.width or 0
                local rh = resSelf.root.height or 0
                se:SetPos(rx + rw - cornerSize + 4, ry + rh - cornerSize + 4)
                se:SetSize(cornerSize, cornerSize)
                se:MoveToFront()
            end
        end
        win.resize:Refresh()
    end

    self:updateToolbarLayout(true)

    if win._onScrollWheel then
        local origOnWheel = win._onScrollWheel
        win._onScrollWheel = function(component, delta)
            self:hideRowTooltip()
            return origOnWheel(component, delta)
        end
    end

    if win._scroll then
        local origOnLayout = win._scroll.onLayout
        win._scroll.onLayout = function(cw, ch)
            if origOnLayout then origOnLayout(cw, ch) end
            self:onWindowGeometryChanged()
        end
    end

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

function Window:buildFallbackWindow(parent, x, y, w, h)
    local root = ui.GroupBox.new(parent)
    root.stylesheetID = id.StyleSheet.DEFAULT
    root:SetHeaderLayout(0, 0, 0, 0, 0)
    root:SetPos(x, y)
    root:SetSize(w, h)
    self.root = root
    self.contentParent = root

    self:buildContentComponents(root)
    self.tooltip = Tooltip.new(parent, function(comp, delta)
        return self:handleScrollWheel(comp, delta)
    end)
    self:updateToolbarLayout(true)
end

function Window:switchTab(tabName)
    if tabName ~= "collections" and tabName ~= "artefacts" and tabName ~= "materials" then
        return
    end
    self:hideRowTooltip()
    local changed = (self.activeTab ~= tabName)
    self.activeTab = tabName
    DB.set("arch_active_tab", tabName)

    if self.btnTabCollections then self.btnTabCollections.setActive(self.activeTab == "collections") end
    if self.btnTabArtefacts   then self.btnTabArtefacts.setActive(self.activeTab == "artefacts") end
    if self.btnTabMaterials   then self.btnTabMaterials.setActive(self.activeTab == "materials") end

    if not changed then return end
    if self.win and self.win.SetScrollPosition then
        pcall(function() self.win:SetScrollPosition(0) end)
    end
    self:refresh()
end

-- ============================================================================
-- Component Tree Construction
-- ============================================================================

function Window:buildContentComponents(container)
    local function forwardScrollWheel(comp)
        if not comp or not comp.Subscribe or not ui or not ui.Hook or not ui.Hook.ONSCROLLWHEEL then return end
        pcall(function()
            comp:Subscribe(ui.Hook.ONSCROLLWHEEL, function(component, delta)
                return self:handleScrollWheel(component, delta)
            end)
        end)
    end

    local function bindRowHover(comp, onOver)
        if not comp or not comp.Subscribe or not ui or not ui.Hook then return end
        pcall(function()
            if ui.Hook.ONMOUSEOVER then
                comp:Subscribe(ui.Hook.ONMOUSEOVER, function()
                    onOver()
                    return false
                end)
            end
            if ui.Hook.ONMOUSELEAVE then
                comp:Subscribe(ui.Hook.ONMOUSELEAVE, function()
                    self:hideRowTooltip()
                    return false
                end)
            end
        end)
        forwardScrollWheel(comp)
    end

    -- 1. Top View Tabs (PrettyUI RS3 TEXT_TAB 3-slice tabs + Divider)
    local onWheelPassthrough = function(comp, delta)
        return self:handleScrollWheel(comp, delta)
    end

    self.btnTabCollections = Widgets.createTabButton(
        container,
        "Collections",
        "View Archaeology collections, rewards, relic powers, turn-in readiness, and target collections for farming.",
        function() self:switchTab("collections") end,
        onWheelPassthrough
    )

    self.btnTabArtefacts = Widgets.createTabButton(
        container,
        "Artefacts",
        "View damaged artefacts in your Backpack & Bank, toggle which ones to track, and set quantities.",
        function() self:switchTab("artefacts") end,
        onWheelPassthrough
    )

    self.btnTabMaterials = Widgets.createTabButton(
        container,
        "Materials",
        "View required materials, levels, locations, owned counts, and remaining deficits.",
        function() self:switchTab("materials") end,
        onWheelPassthrough
    )

    self.btnMaterialsTab = self.btnTabMaterials

    -- 2. Contextual Control Toolbar
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

    self.btnColFilter = self:createToolbarButton(
        container,
        "Show: All",
        "Filter collections: All, Incomplete Only, Targeted Only, or Relics/Powers.",
        false,
        function()
            self.colFilterIndex = (self.colFilterIndex % #COL_FILTER_MODES) + 1
            local mode = COL_FILTER_MODES[self.colFilterIndex]
            if self.btnColFilter then self.btnColFilter.setLabel(mode.label) end
            self:refresh()
        end
    )

    self.btnClearTargets = self:createToolbarButton(
        container,
        "Clear",
        "Clear all tracked collections (resets collection-level pinning).",
        false,
        function()
            self:hideRowTooltip()
            if self.tracker and self.tracker:hasTargetedCollections() then
                self.tracker:clearTargetedCollections()
                self:refresh()
            end
        end
    )

    self.btnArtFilter = self:createToolbarButton(
        container,
        "Show: All",
        "Filter artefacts: Show All (inventory + tracked), Tracked (only artefacts needed for tracked collections), or Owned (only artefacts in bag/bank).",
        false,
        function()
            self.tracker:cycleArtefactFilter()
            if self.btnArtFilter then self.btnArtFilter.setLabel(self.tracker:getArtefactFilterLabel()) end
            self:refresh()
        end
    )

    self.btnDupes = self:createToolbarButton(
        container,
        "Dupes: All",
        "Toggle artefact inclusion: Dupes: All, Dupes: 1x, or Include: 0 (clear all to 0 for selective repair).",
        false,
        function()
            self.tracker:cycleDuplicates()
            if self.btnDupes then self.btnDupes.setLabel(self.tracker:getDuplicatesLabel()) end
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

    self.btnSpots = self:createToolbarButton(
        container,
        (self.overlay and self.overlay.enabled) and "Spots: On" or "Spots: Off",
        "Toggle in-game world highlighting and overhead deficit indicators for excavation spots.",
        true,
        function()
            if self.overlay then
                local on = self.overlay:toggleEnabled()
                self.btnSpots.setLabel(on and "Spots: On" or "Spots: Off")
                self.btnSpots.setActive(on)
            end
        end
    )
    if self.overlay then
        self.btnSpots.setActive(self.overlay.enabled)
    end

    -- 3. Sync Status Indicators
    self.btnCollectorsSync = Widgets.createCollectorSyncPill(container, bindRowHover, function()
        self:onHoverCollectorsStatus()
    end, function()
        if self.tracker and self.tracker:isNoticeboardOpen() then
            self.tracker:syncCollectorBoard(false)
            self:refresh()
        else
            for idx, mode in ipairs(COL_FILTER_MODES) do
                if mode.id == "unsynced" then
                    self.colFilterIndex = (self.colFilterIndex == idx) and 1 or idx
                    if self.btnColFilter then
                        self.btnColFilter.setLabel(COL_FILTER_MODES[self.colFilterIndex].label)
                    end
                    self:refresh()
                    break
                end
            end
        end
    end, onWheelPassthrough)

    self.badgeStorage = Widgets.createSyncBadge(container, "Stor", Theme.STORAGE_ICON_OBJ_ID, bindRowHover, function()
        self:onHoverSyncBadge("storage")
    end)

    self.badgeBank = Widgets.createSyncBadge(container, "Bank", Theme.BANK_ICON_OBJ_ID, bindRowHover, function()
        self:onHoverSyncBadge("bank")
    end)

    -- 4. Prominent Unsynced Notice Banner + KPI Stat Tiles + Page Context Strip
    self.syncNotice = Widgets.createSyncNoticeBanner(container, forwardScrollWheel)
    self.statTiles = {
        Widgets.createStatTile(container, forwardScrollWheel),
        Widgets.createStatTile(container, forwardScrollWheel),
        Widgets.createStatTile(container, forwardScrollWheel),
        Widgets.createStatTile(container, forwardScrollWheel),
    }
    self.pageDescStrip = Widgets.createPageDescStrip(container, forwardScrollWheel)

    -- 5. Build the three Tab Table Layers
    self:buildCollectionsTable(container, bindRowHover, forwardScrollWheel)
    self:buildArtefactsTable(container, bindRowHover, forwardScrollWheel)
    self:buildMaterialsTable(container, bindRowHover, forwardScrollWheel)
end

function Window:buildCollectionsTable(container, bindRowHover, forwardScrollWheel)
    local colLayerH = 26 + (Theme.MAX_COLLECTION_ROWS * Theme.ROW_HEIGHT)
    local colLayer = ui.Layer.new(container)
    colLayer.clickthrough = true
    colLayer:SetPos(0, 120)
    colLayer:SetSize(0, colLayerH, 1.0, 0)
    colLayer.hidden = false
    self.collectionsTableLayer = colLayer
    forwardScrollWheel(colLayer)

    local colHeaderBg = ui.Rectangle.new(colLayer)
    colHeaderBg.colour = Theme.COL_BG_HEADER
    colHeaderBg.fill = true
    colHeaderBg.clickthrough = false
    colHeaderBg:SetPos(8, 0)
    colHeaderBg:SetSize(-16, 22, 1.0, 0)
    forwardScrollWheel(colHeaderBg)

    Widgets.createText(colLayer, Theme.COL_GOLD, 12,   2, 42,   20, "Track")
    Widgets.createText(colLayer, Theme.COL_GOLD, 58,   2, 46,   20, "Done")
    Widgets.createText(colLayer, Theme.COL_GOLD, 108,  2, 32,   20, "Lvl")
    Widgets.createText(colLayer, Theme.COL_GOLD, 144,  2, -476, 20, "Collection", 0, 0, 1.0, 0)
    self.colHReward = Widgets.createText(colLayer, Theme.COL_GOLD, -327, 2, 230, 20, "Reward", 1.0, 0, 0, 0)
    Widgets.createText(colLayer, Theme.COL_GOLD, -93,  2, 85,   20, "Progress", 1.0, 0, 0, 0)

    local startY = 24
    for i = 1, Theme.MAX_COLLECTION_ROWS do
        local rowY = startY + (i - 1) * Theme.ROW_HEIGHT
        self.collectionRows[i] = Widgets.buildCollectionRow(
            colLayer,
            i,
            rowY,
            bindRowHover,
            forwardScrollWheel,
            function(idx) self:onHoverCollectionRow(idx) end,
            function(idx) self:onToggleCollectionTarget(idx) end
        )
    end
end

function Window:buildArtefactsTable(container, bindRowHover, forwardScrollWheel)
    local artLayerH = 26 + (Theme.MAX_ARTEFACT_ROWS * Theme.ROW_HEIGHT)
    local artLayer = ui.Layer.new(container)
    artLayer.clickthrough = true
    artLayer:SetPos(0, 120)
    artLayer:SetSize(0, artLayerH, 1.0, 0)
    self.artefactTableLayer = artLayer
    forwardScrollWheel(artLayer)

    local artHeaderBg = ui.Rectangle.new(artLayer)
    artHeaderBg.colour = Theme.COL_BG_HEADER
    artHeaderBg.fill = true
    artHeaderBg.clickthrough = false
    artHeaderBg:SetPos(8, 0)
    artHeaderBg:SetSize(-16, 22, 1.0, 0)
    forwardScrollWheel(artHeaderBg)

    Widgets.createText(artLayer, Theme.COL_GOLD, 36,  2, 132, 20, "Artefact")
    Widgets.createText(artLayer, Theme.COL_GOLD, 170, 2, 30,  20, "Lvl")
    self.colArtLoc    = Widgets.createText(artLayer, Theme.COL_GOLD, 202,  2, -524, 20, "Location", 0, 0, 1.0, 0)
    self.colArtOwned  = Widgets.createText(artLayer, Theme.COL_GOLD, -316, 2, 82,   20, "Owned",    1.0, 0, 0, 0)
    self.colArtQty    = Widgets.createText(artLayer, Theme.COL_GOLD, -228, 2, 64,   20, "Include",  1.0, 0, 0, 0)
    self.colArtStatus = Widgets.createText(artLayer, Theme.COL_GOLD, -143, 2, 135,  20, "Status",   1.0, 0, 0, 0)

    local startY = 24
    for i = 1, Theme.MAX_ARTEFACT_ROWS do
        local rowY = startY + (i - 1) * Theme.ROW_HEIGHT
        self.artefactRows[i] = Widgets.buildArtefactRow(
            artLayer,
            i,
            rowY,
            bindRowHover,
            function(idx) self:onHoverArtefactRow(idx) end,
            function(idx, delta)
                local item = self.currentArtefacts and self.currentArtefacts[idx]
                if item and item.artefact then
                    self.tracker:adjustArtefactCount(item.artefact.damagedName, delta, item.rawCount)
                    self:refresh()
                    self:onHoverArtefactRow(idx)
                end
            end
        )
    end
    self._prevVisibleArtRowCount = 1
end

function Window:buildMaterialsTable(container, bindRowHover, forwardScrollWheel)
    local tableLayerH = 26 + (Theme.MAX_MATERIAL_ROWS * Theme.ROW_HEIGHT)
    local tableLayer = ui.Layer.new(container)
    tableLayer.clickthrough = true
    tableLayer:SetPos(0, 172)
    tableLayer:SetSize(0, tableLayerH, 1.0, 0)
    tableLayer.hidden = true
    self.tableLayer = tableLayer
    forwardScrollWheel(tableLayer)

    local tableHeaderBg = ui.Rectangle.new(tableLayer)
    tableHeaderBg.colour = Theme.COL_BG_HEADER
    tableHeaderBg.fill = true
    tableHeaderBg.clickthrough = false
    tableHeaderBg:SetPos(8, 0)
    tableHeaderBg:SetSize(-16, 22, 1.0, 0)
    self.tableHeaderBg = tableHeaderBg
    forwardScrollWheel(tableHeaderBg)

    self.colHeaderMat   = Widgets.createText(tableLayer, Theme.COL_GOLD, 38,   2, 131,  20, "Material")
    self.colHeaderLvl   = Widgets.createText(tableLayer, Theme.COL_GOLD, 173,  2, 32,   20, "Lvl")
    self.colHeaderLoc   = Widgets.createText(tableLayer, Theme.COL_GOLD, 209,  2, -390, 20, "Location",    0, 0, 1.0, 0)
    self.colHeaderProg  = Widgets.createText(tableLayer, Theme.COL_GOLD, -175, 2, 100,  20, "Owned / Req", 1.0, 0, 0, 0)
    self.colHeaderShort = Widgets.createText(tableLayer, Theme.COL_GOLD, -71,  2, 63,   20, "Short",       1.0, 0, 0, 0)

    local startY = 24
    for i = 1, Theme.MAX_MATERIAL_ROWS do
        local rowY = startY + (i - 1) * Theme.ROW_HEIGHT
        self.materialRows[i] = Widgets.buildMaterialRow(
            tableLayer,
            i,
            rowY,
            bindRowHover,
            function(idx) self:onHoverMaterialRow(idx) end
        )
    end
    self._prevVisibleRowCount = 1
end

-- ============================================================================
-- Hover & Tooltip Handlers
-- ============================================================================

function Window:showRowTooltip(titleText, subText, detailText, titleCol, objId)
    if self.tooltip then
        self.tooltip:show(self.root, self.isVisible, titleText, subText, detailText, titleCol, objId)
    end
end

function Window:hideRowTooltip()
    if self.tooltip then
        self.tooltip:hide()
    end
end

function Window:onHoverSyncBadge(badgeKind)
    if self._isResizing then return end
    self:showRowTooltip(Tooltip.buildSyncBadgeTooltip(self.tracker, badgeKind))
end

function Window:onHoverCollectorsStatus()
    if self._isResizing or not self.tracker then return end
    self:showRowTooltip(Tooltip.buildCollectorsStatusTooltip(self.tracker))
end

function Window:onToggleCollectionTarget(rowIdx)
    local item = self.currentCollections and self.currentCollections[rowIdx]
    if item and item.data and item.data.name then
        self.tracker:toggleCollectionTargeted(item.data.name)
        self:refresh()
    end
end

function Window:onHoverCollectionRow(rowIdx)
    if self._isResizing then return end
    local item = self.currentCollections and self.currentCollections[rowIdx]
    if not item or not item.data then
        self:hideRowTooltip()
        return
    end
    self:showRowTooltip(Tooltip.buildCollectionRowTooltip(self.tracker, item))
end

function Window:onHoverArtefactRow(rowIdx)
    if self._isResizing then return end
    local item = self.currentArtefacts and self.currentArtefacts[rowIdx]
    if not item or not item.artefact then
        self:hideRowTooltip()
        return
    end
    self:showRowTooltip(Tooltip.buildArtefactRowTooltip(self.tracker, item))
end

function Window:onHoverMaterialRow(rowIdx)
    if self._isResizing then return end
    local item = self.currentMaterials and self.currentMaterials[rowIdx]
    if not item then
        self:hideRowTooltip()
        return
    end
    self:showRowTooltip(Tooltip.buildMaterialRowTooltip(item))
end

-- ============================================================================
-- Responsive Layout & Reflow
-- ============================================================================

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
    local isColTab = (self.activeTab == "collections")
    local isArtTab = (self.activeTab == "artefacts")
    local isMatTab = (self.activeTab == "materials")
    local tabKey = self.activeTab

    if not forceReflow and self._lastAvailW == availW and self._lastTabLayout == tabKey then
        return
    end

    self._inLayout = true

    self:reflowDynamicContent(availW, forceReflow)

    local updatedAvailW = self:getAvailableContentWidth()
    if updatedAvailW ~= availW then
        availW = updatedAvailW
        self:reflowDynamicContent(availW, true)
    end

    if forceReflow or self._lastAvailW ~= availW or self._lastTabLayout ~= tabKey then
        self._lastAvailW = availW
        self._lastTabLayout = tabKey
        local gap = 6

        local tabW = math.floor((availW - (gap * 2)) / 3)
        self.btnTabCollections.setBounds(8, 5, tabW, 26)
        self.btnTabArtefacts.setBounds(8 + tabW + gap, 5, tabW, 26)
        self.btnTabMaterials.setBounds(8 + (tabW * 2) + (gap * 2), 5, availW - (tabW * 2) - (gap * 2), 26)

        self.btnColFilter.setHidden(not isColTab)
        if self.btnCollectorsSync then self.btnCollectorsSync.setHidden(not isColTab) end
        self.btnClearTargets.setHidden(not isColTab)
        self.btnArtFilter.setHidden(not isArtTab)
        self.btnDupes.setHidden(not isArtTab)
        self.btnPin.setHidden(not isArtTab)
        self.btnFilter.setHidden(not isMatTab)
        if self.btnSpots then self.btnSpots.setHidden(not isMatTab) end

        local xBank = 8 + availW - Theme.BADGE_W
        local xStor = xBank - gap - Theme.BADGE_W
        local totalBtnsW = math.max(160, xStor - 8 - gap)

        if isColTab then
            local w1 = math.floor((totalBtnsW - (gap * 3)) * 0.24)
            local w2 = math.floor((totalBtnsW - (gap * 3)) * 0.24)
            local w3 = math.floor((totalBtnsW - (gap * 3)) * 0.18)
            local w4 = totalBtnsW - (gap * 3) - (w1 + w2 + w3)
            local x1 = 8
            local x2 = x1 + w1 + gap
            local x3 = x2 + w2 + gap
            local x4 = x3 + w3 + gap
            self.btnSource.setBounds(x1, 36, w1, 26)
            self.btnColFilter.setBounds(x2, 36, w2, 26)
            self.btnClearTargets.setBounds(x3, 36, w3, 26)
            if self.btnCollectorsSync then
                self.btnCollectorsSync.setBounds(x4, 36, w4, 26)
            end
        elseif isArtTab then
            local w1 = math.floor((totalBtnsW - (gap * 3)) * 0.25)
            local w2 = math.floor((totalBtnsW - (gap * 3)) * 0.27)
            local w3 = math.floor((totalBtnsW - (gap * 3)) * 0.28)
            local w4 = totalBtnsW - (gap * 3) - (w1 + w2 + w3)
            local x1 = 8
            local x2 = x1 + w1 + gap
            local x3 = x2 + w2 + gap
            local x4 = x3 + w3 + gap
            self.btnSource.setBounds(x1, 36, w1, 26)
            self.btnArtFilter.setBounds(x2, 36, w2, 26)
            self.btnDupes.setBounds(x3, 36, w3, 26)
            self.btnPin.setBounds(x4, 36, w4, 26)
        else
            local w1 = math.floor((totalBtnsW - (gap * 2)) * 0.35)
            local w2 = math.floor((totalBtnsW - (gap * 2)) * 0.33)
            local w3 = totalBtnsW - (gap * 2) - (w1 + w2)
            self.btnSource.setBounds(8, 36, w1, 26)
            self.btnFilter.setBounds(8 + w1 + gap, 36, w2, 26)
            if self.btnSpots then
                self.btnSpots.setBounds(8 + w1 + gap + w2 + gap, 36, w3, 26)
            end
        end

        if self.badgeStorage then self.badgeStorage.setBounds(xStor, 36, Theme.BADGE_W, 26) end
        if self.badgeBank    then self.badgeBank.setBounds(xBank, 36, Theme.BADGE_W, 26) end
    end

    self._inLayout = false
end

function Window:reflowDynamicContent(availW, forceReflow)
    if not self.pageDescStrip or not self.statTiles or not self.tableLayer or not self.artefactTableLayer then
        return
    end

    local curY = 66
    local noticeVisible = self.syncNotice and not self.syncNotice.root.hidden
    local noticeH = 0
    local hNoticeBody = 0
    if noticeVisible then
        local noticeWrapW = math.max(160, (availW or 480) - 24)
        hNoticeBody = Theme.measureWrappedTextHeight(self.syncNotice.body.content, noticeWrapW)
        noticeH = 24 + hNoticeBody + 5
        curY = curY + noticeH + 5
    end

    local tilesY = curY
    local tileH = 44
    curY = curY + tileH + 5

    local descY = curY
    local descWrapW = math.max(160, (availW or 480) - 20)
    local hDesc = Theme.measureWrappedTextHeight(self.pageDescStrip.text.content, descWrapW)
    local descH = hDesc + 6
    curY = curY + descH + 5

    local tableHeaderY = curY
    local numTiles = (self.activeTab == "collections") and 4 or 2

    if forceReflow
        or self._lastHeaderAvailW ~= availW
        or self._lastNumTiles ~= numTiles
        or self._lastNoticeH ~= noticeH
        or self._lastDescH ~= descH
        or self._lastTableHeaderY ~= tableHeaderY then
        self._lastHeaderAvailW = availW
        self._lastNumTiles = numTiles
        self._lastNoticeH = noticeH
        self._lastDescH = descH
        self._lastTableHeaderY = tableHeaderY

        if noticeVisible and self.syncNotice then
            self.syncNotice.root:SetPos(8, 66)
            self.syncNotice.root:SetSize(-16, noticeH, 1.0, 0)
            self.syncNotice.body:SetPos(12, 24)
            self.syncNotice.body:SetSize(-20, hNoticeBody, 1.0, 0)
        end

        local gap = 6
        local totalGap = gap * (numTiles - 1)
        local tileW = math.floor(((availW or 480) - totalGap) / numTiles)
        for i = 1, #self.statTiles do
            local tile = self.statTiles[i]
            if tile then
                if i <= numTiles then
                    tile.setHidden(false)
                    local tx = 8 + (i - 1) * (tileW + gap)
                    local tw = (i == numTiles) and ((availW or 480) - (tileW * (numTiles - 1)) - totalGap) or tileW
                    tile.setBounds(tx, tilesY, tw, tileH)
                else
                    tile.setHidden(true)
                end
            end
        end

        self.pageDescStrip.root:SetPos(8, descY)
        self.pageDescStrip.root:SetSize(-16, descH, 1.0, 0)
        self.pageDescStrip.text:SetPos(10, 3)
        self.pageDescStrip.text:SetSize(-16, hDesc, 1.0, 0)

        if self.collectionsTableLayer then
            self.collectionsTableLayer:SetPos(0, tableHeaderY)
        end
        self.artefactTableLayer:SetPos(0, tableHeaderY)
        self.tableLayer:SetPos(0, tableHeaderY)
    end

    if self.colArtStatus and self.colArtQty and self.colArtOwned and self.colArtLoc then
        local statusW = math.min(215, math.max(135, math.floor(135 + ((availW or 480) - 520) * 0.22)))
        local ownedW = math.min(115, math.max(82, math.floor(82 + ((availW or 480) - 520) * 0.15)))
        local statusOffset = statusW + 8
        local qtyOffset = statusOffset + 70
        local ownedOffset = qtyOffset + ownedW + 6
        local locNegOffset = ownedOffset + 6

        if forceReflow or self._lastStatusW ~= statusW or self._lastOwnedW ~= ownedW then
            self._lastStatusW = statusW
            self._lastOwnedW = ownedW
            self.colArtStatus:SetPos(-statusOffset, 2, 1.0, 0)
            self.colArtStatus:SetSize(statusW, 20, 0, 0)
            self.colArtQty:SetPos(-qtyOffset, 2, 1.0, 0)
            self.colArtOwned:SetPos(-ownedOffset, 2, 1.0, 0)
            self.colArtOwned:SetSize(ownedW, 20, 0, 0)
            self.colArtLoc:SetSize(-(202 + locNegOffset), 20, 1.0, 0)

            if self.artefactRows then
                local artStartY = 24
                for i = 1, Theme.MAX_ARTEFACT_ROWS do
                    local row = self.artefactRows[i]
                    if row then
                        local rY = artStartY + (i - 1) * Theme.ROW_HEIGHT
                        row.statusTxt:SetPos(-statusOffset, rY + 2, 1.0, 0)
                        row.statusTxt:SetSize(statusW, Theme.ROW_HEIGHT - 2, 0, 0)
                        row.plusBg:SetPos(-qtyOffset + 46, rY + 3, 1.0, 0)
                        if row.plusTxt then row.plusTxt:SetPos(-qtyOffset + 46, rY + 2, 1.0, 0) end
                        row.qtyTxt:SetPos(-qtyOffset + 20, rY + 2, 1.0, 0)
                        row.minusBg:SetPos(-qtyOffset, rY + 3, 1.0, 0)
                        if row.minusTxt then row.minusTxt:SetPos(-qtyOffset, rY + 2, 1.0, 0) end
                        row.ownedTxt:SetPos(-ownedOffset, rY + 2, 1.0, 0)
                        row.ownedTxt:SetSize(ownedW, Theme.ROW_HEIGHT - 2, 0, 0)
                        row.locTxt:SetSize(-(202 + locNegOffset), Theme.ROW_HEIGHT - 2, 1.0, 0)
                    end
                end
            end
        end
    end

    local activeRows = 0
    if self.activeTab == "collections" then
        activeRows = self.visibleColRowCount or 0
    elseif self.activeTab == "artefacts" then
        activeRows = self.visibleArtRowCount or 0
    else
        activeRows = self.visibleRowCount or 0
    end

    local totalContentHeight = (activeRows <= 0)
        and (tableHeaderY + 4)
        or (tableHeaderY + 24 + (activeRows * Theme.ROW_HEIGHT) + 10)

    if self._lastContentHeight ~= totalContentHeight then
        self._lastContentHeight = totalContentHeight
        if self.win and self.win.SetContentHeight then
            self.win:SetContentHeight(totalContentHeight)
        end
    end
end

function Window:onWindowGeometryChanged()
    if self._inLayout or not self.root then return end

    local rx = math.floor(self.root.x or Theme.DEFAULT_X)
    local ry = math.floor(self.root.y or Theme.DEFAULT_Y)
    local rw = math.floor(self.root.width or Theme.DEFAULT_W)
    local rh = math.floor(self.root.height or Theme.DEFAULT_H)

    if self.parent and self.parent.width and self.parent.height and self.parent.width > 100 then
        local maxX = math.max(0, self.parent.width - rw)
        local maxY = math.max(0, self.parent.height - rh)
        local clampedX = Utils.clamp(rx, 0, maxX)
        local clampedY = Utils.clamp(ry, 0, maxY)
        if clampedX ~= rx or clampedY ~= ry then
            rx, ry = clampedX, clampedY
            self.root:SetPos(rx, ry)
        end
    end

    if not self._isResizing then
        if rx ~= self._savedX or ry ~= self._savedY or rw ~= self._savedW or rh ~= self._savedH then
            self._savedX, self._savedY, self._savedW, self._savedH = rx, ry, rw, rh
            DB.set("arch_win_x", rx)
            DB.set("arch_win_y", ry)
            DB.set("arch_win_w", rw)
            DB.set("arch_win_h", rh)
        end
    end

    self:updateToolbarLayout(false)
end

function Window:setWindowVisible(visible)
    self.isVisible = (visible == true)
    if not self.isVisible then
        self:hideRowTooltip()
    end
    DB.setBool("arch_win_visible", self.isVisible)
    if self.win then
        if self.isVisible then
            self.win:Show()
            self:updateToolbarLayout(true)
            self:refresh()
        else
            self.win:Close()
        end
    elseif self.root then
        Theme.setComponentHidden(self.root, not self.isVisible)
    end
    self:refreshHub()
end

function Window:resetWindowGeometry()
    DB.set("arch_win_x", Theme.DEFAULT_X)
    DB.set("arch_win_y", Theme.DEFAULT_Y)
    DB.set("arch_win_w", Theme.DEFAULT_W)
    DB.set("arch_win_h", Theme.DEFAULT_H)
    if self.win then
        self.win.root:SetPos(Theme.DEFAULT_X, Theme.DEFAULT_Y)
        self.win:SetSize(Theme.DEFAULT_W, Theme.DEFAULT_H)
        self:setWindowVisible(true)
    elseif self.root then
        self.root:SetPos(Theme.DEFAULT_X, Theme.DEFAULT_Y)
        self.root:SetSize(Theme.DEFAULT_W, Theme.DEFAULT_H)
    end
    self:updateToolbarLayout(true)
end

-- ============================================================================
-- Ribbon Bar Hub Integration
-- ============================================================================

function Window:populateRibbonHub(parent)
    self.hubParent = parent
    pcall(function() parent:DeleteAll() end)

    local toggleLabel = self.isVisible and "Hide Assistant Window" or "Show Assistant Window"
    if prettyui and prettyui.SimpleButton then
        local btn = prettyui.SimpleButton.new(parent, toggleLabel, function()
            if self:tryMount() then
                self:setWindowVisible(not self.isVisible)
            end
        end, {
            x = 12,
            y = 12,
            height = 30
        })
        btn.root:SetPos(12, 12)
        btn.root:SetSize(-24, 30, 1.0, 0)
        self.hubToggleBtn = btn

        local btnClear = prettyui.SimpleButton.new(parent, "Clear All Cache & Saved Data", function()
            self.tracker:clearAllCache()
            self:refresh()
        end, {
            x = 12,
            y = 48,
            height = 30
        })
        btnClear.root:SetPos(12, 48)
        btnClear.root:SetSize(-24, 30, 1.0, 0)
        return
    end

    local btn = ui.Button.new(parent)
    btn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    btn:SetPos(12, 12)
    btn:SetSize(-24, 30, 1.0, 0)
    btn.label = toggleLabel
    btn:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        if self:tryMount() then
            self:setWindowVisible(not self.isVisible)
        end
    end)
    self.hubToggleBtn = btn

    local btnClear = ui.Button.new(parent)
    btnClear.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    btnClear:SetPos(12, 48)
    btnClear:SetSize(-24, 30, 1.0, 0)
    btnClear.label = "Clear All Cache & Saved Data"
    btnClear:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        self.tracker:clearAllCache()
        self:refresh()
    end)
end

function Window:refreshHub()
    if self.hubToggleBtn then
        pcall(function()
            local label = self.isVisible and "Hide Assistant Window" or "Show Assistant Window"
            if self.hubToggleBtn.content then
                self.hubToggleBtn.content.content = label
            elseif self.hubToggleBtn.SetText then
                self.hubToggleBtn:SetText(label)
            else
                self.hubToggleBtn.label = label
            end
        end)
    end
end

-- ============================================================================
-- Data Refresh & Table Population
-- ============================================================================

function Window:updateSummaryCard(isColTab, isArtTab, res, mode, totalCols, completedCols, targetedCols, readyCols, chronoteTotal, syncStatus, syncedCount, totalCount)
    -- 1. Prominent In-UI Unsynced Notice Banner
    if self.syncNotice then
        if isColTab then
            if (totalCount or 0) > 0 and (syncedCount or 0) == 0 then
                self.syncNotice.update(
                    true,
                    "red",
                    string.format("COLLECTORS NOT SYNCED (0 / %d)", totalCount),
                    "Right-click your Archaeology Journal -> 'Collector information' (or use the Guild Noticeboard) and click each collector to sync."
                )
            elseif (totalCount or 0) > 0 and (syncedCount or 0) < totalCount then
                self.syncNotice.update(
                    true,
                    "amber",
                    string.format("%d OF %d COLLECTORS UNSYNCED", totalCount - syncedCount, totalCount),
                    string.format("Click 'Collectors: %d/%d' above to filter unsynced collections, or open 'Collector information' in your Archaeology Journal.", syncedCount, totalCount)
                )
            else
                self.syncNotice.update(false)
            end
        else
            local needStor = syncStatus and syncStatus.storage and syncStatus.storage.enabled
                and not syncStatus.storage.synced and not syncStatus.storage.cached
            local needBank = syncStatus and syncStatus.bank and syncStatus.bank.enabled
                and not syncStatus.bank.synced and not syncStatus.bank.cached
            if needStor and needBank then
                self.syncNotice.update(
                    true,
                    "red",
                    "MATERIAL STORAGE & BANK NOT SYNCED",
                    "Open Material Storage (or via Archaeology Journal) and your Bank in-game so stored items are included."
                )
            elseif needStor then
                self.syncNotice.update(
                    true,
                    "red",
                    "MATERIAL STORAGE NOT SYNCED",
                    "Open Material Storage (or check 'Material storage' in your Archaeology Journal) to include stored materials."
                )
            elseif needBank then
                self.syncNotice.update(
                    true,
                    "red",
                    "BANK NOT SYNCED",
                    "Open your Bank in-game so banked artefacts and materials are included in calculations."
                )
            else
                self.syncNotice.update(false)
            end
        end
    end

    -- 2. KPI Stat Tiles + Page Description Strip
    if isColTab then
        local doneCol = (completedCols == totalCols and totalCols > 0) and Theme.COL_GREEN or Theme.COL_GOLD
        local trackCol = (targetedCols > 0) and Theme.COL_GOLD or Theme.COL_MUTED
        local readyCol = (readyCols > 0) and Theme.COL_GREEN or Theme.COL_MUTED
        local chronoVal = (targetedCols > 0 and (chronoteTotal or 0) > 0) and ("+" .. Utils.formatInt(chronoteTotal)) or "0"
        local chronoCol = ((chronoteTotal or 0) > 0) and Theme.COL_GOLD or Theme.COL_MUTED

        self.statTiles[1].setData("COMPLETED", string.format("%d / %d", completedCols, totalCols), doneCol, doneCol)
        self.statTiles[2].setData("TRACKED", tostring(targetedCols), trackCol, trackCol)
        self.statTiles[3].setData("READY", tostring(readyCols), readyCol, readyCol)
        self.statTiles[4].setData("CHRONOTES LEFT", chronoVal, chronoCol, chronoCol)

        if readyCols > 0 then
            self.pageDescStrip.setContent(
                string.format(
                    "%d %scollection(s) have all artefacts restored and ready to hand in.",
                    readyCols,
                    (targetedCols > 0) and "tracked " or ""
                ),
                Theme.COL_GREEN,
                Theme.COL_GREEN
            )
        else
            self.pageDescStrip.setContent(
                "Check 'Track' on collections you want to complete to automatically include their missing artefacts & materials.",
                Theme.COL_CREAM,
                Theme.COL_GOLD
            )
        end
    elseif isArtTab then
        local waitingToRestore = res.totalArtefacts or 0
        local readyRestored = res.readyRestoredArtefacts or 0
        local readyToRepairNow = res.restorableArtefacts or 0
        local totalInc = waitingToRestore + readyRestored
        local totalReady = readyToRepairNow + readyRestored

        local readyCol = (totalInc > 0 and totalReady == totalInc) and Theme.COL_GREEN
            or ((totalReady > 0) and Theme.COL_GOLD or Theme.COL_MUTED)
        local xpVal = Utils.formatInt(res.totalXp or 0) .. " XP"
        local xpCol = ((res.totalXp or 0) > 0) and Theme.COL_CREAM or Theme.COL_MUTED

        self.statTiles[1].setData("READY", string.format("%d / %d", totalReady, totalInc), readyCol, readyCol)
        self.statTiles[2].setData("RESTORE XP", xpVal, xpCol, xpCol)

        if #self.currentArtefacts == 0 then
            self.pageDescStrip.setContent(
                "No damaged artefacts in Backpack/Bank or Tracked Collections. Track a collection or carry damaged artefacts.",
                Theme.COL_MUTED,
                Theme.COL_MUTED
            )
        elseif totalInc == 0 then
            self.pageDescStrip.setContent(
                "All artefacts are set to 0. Click '+' on any row or change 'Dupes' above to include artefacts in your plan.",
                Theme.COL_AMBER,
                Theme.COL_AMBER
            )
        else
            self.pageDescStrip.setContent(
                "Adjust 'Include' quantities (+/-) below to choose which damaged artefacts to calculate restoration materials for.",
                Theme.COL_CREAM,
                Theme.COL_GOLD
            )
        end
    else
        local reqTypes = res.distinctMaterialsRequired or 0
        local shortTypes = res.distinctMaterialsShort or 0
        local readyTypes = math.max(0, reqTypes - shortTypes)
        local totalShort = res.totalMaterialsShort or 0

        local readyCol = (reqTypes > 0 and shortTypes == 0) and Theme.COL_GREEN
            or ((reqTypes > 0) and Theme.COL_GOLD or Theme.COL_MUTED)
        local missCol = (totalShort == 0) and ((reqTypes > 0) and Theme.COL_GREEN or Theme.COL_MUTED) or Theme.COL_RED

        self.statTiles[1].setData("READY", string.format("%d / %d", readyTypes, reqTypes), readyCol, readyCol)
        self.statTiles[2].setData("MISSING MATS", Utils.formatInt(totalShort), missCol, missCol)

        if (res.totalArtefacts or 0) == 0 then
            self.pageDescStrip.setContent(
                "No active artefacts selected. Track a collection or include damaged artefacts to calculate required materials.",
                Theme.COL_MUTED,
                Theme.COL_MUTED
            )
        elseif shortTypes == 0 then
            self.pageDescStrip.setContent(
                string.format("All %d required material types are ready to restore your %d selected artefact(s)!", reqTypes, res.totalArtefacts),
                Theme.COL_GREEN,
                Theme.COL_GREEN
            )
        else
            self.pageDescStrip.setContent(
                "Materials needed to restore your included artefacts and tracked collections. Hover any row for cache locations.",
                Theme.COL_CREAM,
                Theme.COL_GOLD
            )
        end
    end
end

function Window:populateCollectionRows(colList)
    local visibleColRowCount = math.min(Theme.MAX_COLLECTION_ROWS, #colList)
    local maxTouchColIdx = math.max(visibleColRowCount, self._prevVisibleColRowCount or 1)
    self._prevVisibleColRowCount = visibleColRowCount
    self.visibleColRowCount = visibleColRowCount

    for slotIdx = 1, maxTouchColIdx do
        local rowUI = self.collectionRows[slotIdx]
        if rowUI then
            if slotIdx <= visibleColRowCount then
                local item = colList[slotIdx]
                local col = item.data
                local prog = item.progress

                rowUI.setRowHidden(false)
                rowUI.setTargetState(prog.isTargeted)
                rowUI.setDoneState(prog.isCompleted)

                if prog.isTargeted then
                    rowUI.bg.colour = Theme.COL_BG_TRACKED
                    rowUI.accentBar.colour = Theme.COL_GOLD
                    rowUI.accentBar.hidden = false
                    rowUI.nameTxt.colour = Theme.COL_GOLD
                    rowUI.lvlTxt.colour = Theme.COL_GOLD
                elseif prog.isCompleted then
                    rowUI.bg.colour = Theme.COL_BG_DONE
                    rowUI.accentBar.colour = Theme.COL_GREEN
                    rowUI.accentBar.hidden = false
                    rowUI.nameTxt.colour = Theme.COL_GREEN
                    rowUI.lvlTxt.colour = Theme.COL_CREAM
                else
                    rowUI.bg.colour = (slotIdx % 2 == 1) and Theme.COL_BG_ROW or Theme.COL_BG_ALT
                    rowUI.accentBar.hidden = true
                    rowUI.nameTxt.colour = Theme.COL_WHITE
                    rowUI.lvlTxt.colour = Theme.COL_MUTED
                end

                rowUI.lvlTxt.content = tostring(col.level)
                rowUI.nameTxt.content = col.name

                local isTetra = string.find(string.lower(col.recurringReward or ""), "tetra", 1, true)
                    or string.find(string.lower(col.specialBenefit or ""), "tetra", 1, true)
                if col.benefitType == "relic" then
                    rowUI.rewardTxt.colour = Theme.COL_CYAN
                    rowUI.rewardTxt.content = (col.specialBenefit ~= "" and col.specialBenefit or col.oneTimeReward)
                elseif col.benefitType == "weapon" then
                    rowUI.rewardTxt.colour = Theme.COL_GOLD
                    rowUI.rewardTxt.content = (col.specialBenefit ~= "" and col.specialBenefit or col.oneTimeReward)
                elseif col.benefitType == "mystery" then
                    rowUI.rewardTxt.colour = Theme.COL_AMBER
                    rowUI.rewardTxt.content = (col.specialBenefit ~= "" and col.specialBenefit or col.oneTimeReward)
                elseif isTetra or col.benefitType == "tetra" then
                    rowUI.rewardTxt.colour = Theme.COL_CREAM
                    rowUI.rewardTxt.content = "Tetracompass piece"
                else
                    rowUI.rewardTxt.colour = Theme.COL_MUTED
                    rowUI.rewardTxt.content = col.chronotes ~= "" and col.chronotes
                        or (col.recurringReward ~= "" and col.recurringReward or col.oneTimeReward)
                end

                local have = prog.haveCount or (prog.readyCount + (prog.damagedCount or 0))
                local total = prog.totalCount or 0
                if prog.isReady then
                    rowUI.readyTxt.colour = Theme.COL_GREEN
                    rowUI.readyTxt.content = string.format("%d / %d", total, total)
                elseif have == total and total > 0 then
                    rowUI.readyTxt.colour = Theme.COL_GOLD
                    rowUI.readyTxt.content = string.format("%d / %d", have, total)
                elseif have > 0 then
                    rowUI.readyTxt.colour = (prog.readyCount > 0) and Theme.COL_CREAM or Theme.COL_AMBER
                    rowUI.readyTxt.content = string.format("%d / %d", have, total)
                else
                    rowUI.readyTxt.colour = Theme.COL_MUTED
                    rowUI.readyTxt.content = string.format("0 / %d", total)
                end
            else
                rowUI.setRowHidden(true)
            end
        end
    end
end

function Window:populateArtefactRows(artList)
    local visibleArtRowCount = math.min(Theme.MAX_ARTEFACT_ROWS, #artList)
    local maxTouchArtIdx = math.max(visibleArtRowCount, self._prevVisibleArtRowCount or 1)
    self._prevVisibleArtRowCount = visibleArtRowCount
    self.visibleArtRowCount = visibleArtRowCount

    for slotIdx = 1, maxTouchArtIdx do
        local rowUI = self.artefactRows[slotIdx]
        local item = artList[slotIdx]

        if item then
            Theme.bindItemSprite(rowUI.icon, item.artefact and item.artefact.id, 1)

            rowUI.bg.hidden = false
            rowUI.nameTxt.hidden = false
            rowUI.lvlTxt.hidden = false
            rowUI.locTxt.hidden = false
            rowUI.ownedTxt.hidden = false
            rowUI.minusBg.hidden = false
            if rowUI.minusTxt then rowUI.minusTxt.hidden = false end
            rowUI.qtyTxt.hidden = false
            rowUI.plusBg.hidden = false
            if rowUI.plusTxt then rowUI.plusTxt.hidden = false end
            rowUI.statusTxt.hidden = false

            rowUI.nameTxt.content = item.artefact.name
            rowUI.lvlTxt.content = tostring(item.artefact.level or 1)
            rowUI.locTxt.content = item.artefact.location or "Archaeology"
            rowUI.locTxt.colour = Theme.COL_MUTED

            local ownedDamaged = item.ownedDamaged or ((item.inBag or 0) + (item.inBank or 0))
            local bagRestored = item.bagRestored or 0
            local bankRestored = item.bankRestored or 0
            local totalRestored = bagRestored + bankRestored
            if item.inBag > 0 and item.inBank > 0 then
                rowUI.ownedTxt.content = string.format("%d (%d/%d)", ownedDamaged, item.inBag, item.inBank)
                rowUI.ownedTxt.colour = Theme.COL_WHITE
            elseif item.inBag > 0 then
                rowUI.ownedTxt.content = string.format("%d (Bag)", item.inBag)
                rowUI.ownedTxt.colour = Theme.COL_WHITE
            elseif item.inBank > 0 then
                rowUI.ownedTxt.content = string.format("%d (Bank)", item.inBank)
                rowUI.ownedTxt.colour = Theme.COL_WHITE
            elseif totalRestored > 0 then
                if bagRestored > 0 and bankRestored > 0 then
                    rowUI.ownedTxt.content = string.format("%d (%d/%d)", totalRestored, bagRestored, bankRestored)
                elseif bagRestored > 0 then
                    rowUI.ownedTxt.content = string.format("%d (Bag)", bagRestored)
                else
                    rowUI.ownedTxt.content = string.format("%d (Bank)", bankRestored)
                end
                rowUI.ownedTxt.colour = Theme.COL_GREEN
            else
                rowUI.ownedTxt.content = "0"
                rowUI.ownedTxt.colour = Theme.COL_MUTED
            end
            rowUI.qtyTxt.content = tostring(item.effectiveCount)

            if item.excluded or item.effectiveCount == 0 then
                rowUI.qtyTxt.colour = Theme.COL_MUTED
                if item.isSubmitted then
                    rowUI.statusTxt.content = "Submitted"
                    rowUI.statusTxt.colour = Theme.COL_GREEN
                    rowUI.nameTxt.colour = Theme.COL_GREEN
                    rowUI.lvlTxt.colour = Theme.COL_GREEN
                elseif (item.ownedRestored or 0) > 0 then
                    rowUI.statusTxt.content = "Ready (Restored)"
                    rowUI.statusTxt.colour = Theme.COL_GREEN
                    rowUI.nameTxt.colour = Theme.COL_GREEN
                    rowUI.lvlTxt.colour = Theme.COL_GREEN
                elseif item.maxPossibleNow >= 1 then
                    rowUI.statusTxt.content = "0 (Can Repair)"
                    rowUI.statusTxt.colour = Theme.COL_MUTED
                    rowUI.nameTxt.colour = Theme.COL_MUTED
                    rowUI.lvlTxt.colour = Theme.COL_MUTED
                else
                    rowUI.statusTxt.content = "Excluded"
                    rowUI.statusTxt.colour = Theme.COL_MUTED
                    rowUI.nameTxt.colour = Theme.COL_MUTED
                    rowUI.lvlTxt.colour = Theme.COL_MUTED
                end
            else
                rowUI.qtyTxt.colour = Theme.COL_WHITE
                if ownedDamaged == 0 then
                    if (item.missingMatTypes or 0) == 0 then
                        rowUI.statusTxt.content = "Need Art"
                        rowUI.statusTxt.colour = Theme.COL_AMBER
                    else
                        rowUI.statusTxt.content = "Short (Art+Mats)"
                        rowUI.statusTxt.colour = Theme.COL_RED
                    end
                    rowUI.nameTxt.colour = Theme.COL_WHITE
                    rowUI.lvlTxt.colour = Theme.COL_CREAM
                elseif item.maxPossibleNow >= item.effectiveCount then
                    rowUI.statusTxt.content = (item.effectiveCount > 1)
                        and string.format("Ready (%d/%d)", item.effectiveCount, item.effectiveCount)
                        or "Ready"
                    rowUI.nameTxt.colour = Theme.COL_GREEN
                    rowUI.lvlTxt.colour = Theme.COL_GREEN
                    rowUI.statusTxt.colour = Theme.COL_GREEN
                elseif item.maxPossibleNow > 0 then
                    rowUI.statusTxt.content = string.format("%d / %d Ready", item.maxPossibleNow, item.effectiveCount)
                    rowUI.nameTxt.colour = Theme.COL_WHITE
                    rowUI.lvlTxt.colour = Theme.COL_CREAM
                    rowUI.statusTxt.colour = Theme.COL_AMBER
                else
                    rowUI.statusTxt.content = string.format(
                        "Short (%d mat%s)",
                        item.missingMatTypes or 1,
                        (item.missingMatTypes == 1) and "" or "s"
                    )
                    rowUI.nameTxt.colour = Theme.COL_WHITE
                    rowUI.lvlTxt.colour = Theme.COL_CREAM
                    rowUI.statusTxt.colour = Theme.COL_RED
                end
            end
            item.statusText = rowUI.statusTxt.content
        else
            if rowUI.icon then rowUI.icon.hidden = true end
            rowUI.bg.hidden = true
            rowUI.nameTxt.hidden = true
            rowUI.lvlTxt.hidden = true
            rowUI.locTxt.hidden = true
            rowUI.ownedTxt.hidden = true
            rowUI.minusBg.hidden = true
            if rowUI.minusTxt then rowUI.minusTxt.hidden = true end
            rowUI.qtyTxt.hidden = true
            rowUI.plusBg.hidden = true
            if rowUI.plusTxt then rowUI.plusTxt.hidden = true end
            rowUI.statusTxt.hidden = true
        end
    end
end

function Window:populateMaterialRows(matList)
    local visibleRowCount = math.min(Theme.MAX_MATERIAL_ROWS, #matList)
    local maxTouchIdx = math.max(visibleRowCount, self._prevVisibleRowCount or 1)
    self._prevVisibleRowCount = visibleRowCount
    self.visibleRowCount = visibleRowCount

    for slotIdx = 1, maxTouchIdx do
        local rowUI = self.materialRows[slotIdx]
        local item = matList[slotIdx]

        if item then
            local mat = item.material
            Theme.bindItemSprite(rowUI.icon, mat and mat.id, 1)

            if mat and not mat._cachedLoc then
                mat._cachedLoc = (mat.caches and #mat.caches > 0) and table.concat(mat.caches, ", ") or "-"
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
            rowUI.progTxt.content = string.format("%s / %s", Utils.formatInt(item.owned), Utils.formatInt(item.required))

            if item.short > 0 then
                rowUI.statusTxt.content = Utils.formatInt(item.short)
                rowUI.nameTxt.colour = Theme.COL_WHITE
                rowUI.lvlTxt.colour = Theme.COL_CREAM
                rowUI.locTxt.colour = Theme.COL_MUTED
                rowUI.progTxt.colour = (item.owned > 0) and Theme.COL_AMBER or Theme.COL_RED
                rowUI.statusTxt.colour = (item.owned > 0) and Theme.COL_AMBER or Theme.COL_RED
            else
                rowUI.statusTxt.content = "Ready"
                rowUI.nameTxt.colour = Theme.COL_GREEN
                rowUI.lvlTxt.colour = Theme.COL_GREEN
                rowUI.locTxt.colour = Theme.COL_MUTED
                rowUI.progTxt.colour = Theme.COL_GREEN
                rowUI.statusTxt.colour = Theme.COL_GREEN
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
end

function Window:refresh()
    if not self.mounted and not self:tryMount() then
        return
    end

    local t = self.tracker
    local res = t.lastResult or t:recalculate()
    local mode = t:getSourceMode()

    local artList = res.artefacts or {}
    local matList = res.filteredMaterials or {}
    self.currentArtefacts = artList
    self.currentMaterials = matList

    local winTitle = t.isPinned and "Archaeology Assistant [PINNED]" or "Archaeology Assistant"
    if self.win and self.win.SetTitle then
        self.win:SetTitle(winTitle)
    end

    local isColTab = (self.activeTab == "collections")
    local isArtTab = (self.activeTab == "artefacts")
    local isMatTab = (self.activeTab == "materials")

    local colFilterMode = COL_FILTER_MODES[self.colFilterIndex] and COL_FILTER_MODES[self.colFilterIndex].id or "all"
    local colList, totalCols, completedCols, targetedCols, readyCols = t:getCollectionsForDisplay(colFilterMode)
    self.currentCollections = colList

    local chronoteTotal = (t.getTargetedChronotesTotal and t:getTargetedChronotesTotal()) or 0
    self.btnTabCollections.setLabel(string.format("Collections (%d)", #colList))
    self.btnTabCollections.setActive(isColTab)
    self.btnTabArtefacts.setLabel(string.format("Artefacts (%d)", #artList))
    self.btnTabArtefacts.setActive(isArtTab)
    self.btnTabMaterials.setLabel(string.format("Materials (%d)", #matList))
    self.btnTabMaterials.setActive(isMatTab)

    self.collectionsTableLayer.hidden = (not isColTab) or (#colList == 0)
    self.artefactTableLayer.hidden    = (not isArtTab) or (#artList == 0)
    self.tableLayer.hidden            = (not isMatTab) or (#matList == 0)

    self.btnSource.setLabel(mode.shortLabel)
    if self.btnColFilter then
        self.btnColFilter.setLabel(COL_FILTER_MODES[self.colFilterIndex].label)
        self.btnColFilter.setActive(self.colFilterIndex > 1)
    end
    if self.btnClearTargets then
        self.btnClearTargets.setLabel(targetedCols > 0 and string.format("Clear (%d)", targetedCols) or "Clear")
        self.btnClearTargets.setActive(targetedCols > 0)
    end
    if self.colHReward then
        self.colHReward.content = "Reward"
    end
    if self.btnArtFilter then
        self.btnArtFilter.setLabel(t:getArtefactFilterLabel())
        self.btnArtFilter.setActive(t.artefactFilter ~= "ALL")
    end
    if self.btnDupes then
        self.btnDupes.setLabel(t:getDuplicatesLabel())
    end
    self.btnFilter.setLabel(t.shortOnly and "Short Only" or "Show: All")
    self.btnFilter.setActive(t.shortOnly)
    if self.btnSpots and self.overlay then
        self.btnSpots.setLabel(self.overlay.enabled and "Spots: On" or "Spots: Off")
        self.btnSpots.setActive(self.overlay.enabled)
    end
    self.btnPin.setLabel(t.isPinned and "Unpin" or "Pin")
    self.btnPin.setActive(t.isPinned)

    -- Update Sync Badges
    local syncStatus = t:getSyncStatus()
    local function getBadgeState(s)
        if not s.enabled then return "ignored" end
        if s.synced then return "synced" end
        if s.cached then return "cached" end
        return "missing"
    end
    if self.badgeStorage then
        self.badgeStorage.setState(getBadgeState(syncStatus.storage))
        self.badgeStorage.setIcon(Theme.STORAGE_ICON_OBJ_ID)
    end
    if self.badgeBank then
        self.badgeBank.setState(getBadgeState(syncStatus.bank))
        self.badgeBank.setIcon(Theme.BANK_ICON_OBJ_ID)
    end
    local syncedCount, totalCount, liveCount = 0, 0, 0
    if t.getCollectorSyncStatuses then
        _, syncedCount, totalCount, liveCount = t:getCollectorSyncStatuses()
        if self.btnCollectorsSync then
            self.btnCollectorsSync.setStatus(syncedCount, totalCount, liveCount)
        end
    end

    self:updateSummaryCard(isColTab, isArtTab, res, mode, totalCols, completedCols, targetedCols, readyCols, chronoteTotal, syncStatus, syncedCount, totalCount)
    self:populateCollectionRows(colList)
    self:populateArtefactRows(artList)
    self:populateMaterialRows(matList)

    self:updateToolbarLayout(true)
    self:refreshHub()
    if self.overlay and self.overlay.triggerScan then
        pcall(function() self.overlay:triggerScan() end)
    end
end

function Window:shutdown()
    if Event and Event.ContentLayerReady and Event.ContentLayerReady.Unsubscribe then
        pcall(function() Event.ContentLayerReady.Unsubscribe(HUB_EVENT_ID) end)
    end
    if Event and Event.Logic and Event.Logic.Unsubscribe then
        pcall(function() Event.Logic.Unsubscribe(MOUNT_EVENT_ID) end)
    end
    if self.tooltip then
        self.tooltip:destroy()
        self.tooltip = nil
    end
    if self.overlay and self.overlay.destroy then
        pcall(function() self.overlay:destroy() end)
        self.overlay = nil
    end
    if self.win and self.win.Destroy then
        pcall(function() self:onWindowGeometryChanged() end)
        pcall(function() self.win:Destroy() end)
        self.win = nil
    end
end

return Window
