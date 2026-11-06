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
    { id = "level",      label = "Level Met"     },
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
    self.colSearchQuery = ""
    self.artSearchQuery = ""
    self.matSearchQuery = ""
    self.searchField = nil
    self.btnSearchClear = nil
    self.hubParent = nil
    self.hubToggleBtn = nil
    self.overlay = nil
    self.tooltip = nil
    self.previousTab = "collections"

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

function Window:getActiveSearchQuery()
    if self.activeTab == "collections" then
        return self.colSearchQuery or ""
    elseif self.activeTab == "artefacts" then
        return self.artSearchQuery or ""
    else
        return self.matSearchQuery or ""
    end
end

function Window:setActiveSearchQuery(query)
    query = query or ""
    if self.activeTab == "collections" then
        self.colSearchQuery = query
    elseif self.activeTab == "artefacts" then
        self.artSearchQuery = query
    else
        self.matSearchQuery = query
    end
end

function Window:getSearchPlaceholder()
    if self.activeTab == "collections" then
        return "Search collections, collectors, artefacts..."
    elseif self.activeTab == "artefacts" then
        return "Search artefacts, locations, levels..."
    else
        return "Search materials, caches, locations..."
    end
end

function Window:switchTab(tabName)
    if tabName ~= "collections" and tabName ~= "artefacts" and tabName ~= "materials" then
        return
    end

    self:hideRowTooltip()
    local changed = (self.activeTab ~= tabName)
    self.activeTab = tabName
    DB.set("arch_active_tab", tabName)

    if self.searchField then
        if self.searchField.SetPlaceholder then
            self.searchField:SetPlaceholder(self:getSearchPlaceholder())
        end
        if self.searchField.SetText then
            self.searchField:SetText(self:getActiveSearchQuery(), false)
        end
        if self.searchField.SetVisible then
            self.searchField:SetVisible(true)
        end
    end
    if self.btnSearchClear then
        self.btnSearchClear.setHidden(self:getActiveSearchQuery() == "")
    end

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

    self.btnTargetMax = self:createToolbarButton(
        container,
        "Target Max",
        "Set all tracked collections to the maximum possible completions from your current holdings.",
        false,
        function()
            self:hideRowTooltip()
            if self.tracker then
                self.tracker:setAllTrackedToMax()
                self:refresh()
            end
        end
    )

    self.btnClearTargets = self:createToolbarButton(
        container,
        "Clear",
        "Untrack all collections and reset target quantities to 1.",
        false,
        function()
            self:hideRowTooltip()
            if self.tracker then
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

    -- 3. Sync Status Indicators (Word status badge for Collectors + Icon badges for Storage & Bank)
    self.badgeBoard = Widgets.createCollectorSyncPill(
        container,
        bindRowHover,
        function() self:onHoverCollectorsStatus() end,
        onWheelPassthrough
    )

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

    -- 5. Search Bar & Clear Button
    self:buildSearchBar(container, forwardScrollWheel)

    -- 6. Empty Table Notice (replaces table rows when 0 items match)
    self.emptyTableNotice = Widgets.createEmptyTableNotice(container, forwardScrollWheel)

    -- 7. Build the three Tab Table Layers & Settings View
    self:buildCollectionsTable(container, bindRowHover, forwardScrollWheel)
    self:buildArtefactsTable(container, bindRowHover, forwardScrollWheel)
    self:buildMaterialsTable(container, bindRowHover, forwardScrollWheel)
end

function Window:buildSearchBar(container, forwardScrollWheel)
    if not prettyui or not prettyui.TextField then return end

    local ok, field = pcall(function()
        return prettyui.TextField.new(container, {
            x = 8,
            y = 0,
            width = 240,
            height = 24,
            placeholder = self:getSearchPlaceholder(),
            text = self:getActiveSearchQuery(),
            _onScrollWheel = function(comp, delta) return self:handleScrollWheel(comp, delta) end,
            onChange = function(_, _, newText)
                local curr = tostring(newText or "")
                local prev = self:getActiveSearchQuery()
                if curr ~= prev then
                    self:setActiveSearchQuery(curr)
                    self:refresh()
                end
            end,
        })
    end)
    if ok and field then
        self.searchField = field
    end

    self.btnSearchClear = Widgets.createSearchClearButton(container, function()
        self:setActiveSearchQuery("")
        if self.searchField and self.searchField.SetText then
            self.searchField:SetText("", false)
        end
        self:refresh()
    end)
    if self.btnSearchClear then
        self.btnSearchClear.setHidden(false)
    end
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

    self.colHTrack   = Widgets.createText(colLayer, Theme.COL_GOLD, 8,   2, 44,  20, "Track")
    self.colHTarget  = Widgets.createText(colLayer, Theme.COL_GOLD, 56,  2, 68,  20, "Target")
    if ui.AlignMode then
        pcall(function()
            self.colHTarget.alignHorizontal = ui.AlignMode.CENTRE
        end)
    end
    self.colHDone    = Widgets.createText(colLayer, Theme.COL_GOLD, 126, 2, 66,  20, "Turn-ins")
    if ui.AlignMode then
        pcall(function()
            self.colHDone.alignHorizontal = ui.AlignMode.CENTRE
        end)
    end
    self.colHLvl     = Widgets.createText(colLayer, Theme.COL_GOLD, 196, 2, 28,  20, "Lvl")
    if ui.AlignMode then
        pcall(function()
            self.colHLvl.alignHorizontal = ui.AlignMode.CENTRE
        end)
    end
    self.colHColName = Widgets.createText(colLayer, Theme.COL_GOLD, 228, 2, 60,  20, "Collection", 0, 0, 0, 0)
    self.colHReward  = Widgets.createText(colLayer, Theme.COL_GOLD, -156, 2, 88,   20, "Reward",     1.0, 0, 0, 0)
    self.colHReady   = Widgets.createText(colLayer, Theme.COL_GOLD, -62,  2, 54,   20, "Ready",      1.0, 0, 0, 0)

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
            function(idx) self:onToggleCollectionTarget(idx) end,
            function(idx, delta) self:onStepCollectionTarget(idx, delta) end
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

    self.colArtName   = Widgets.createText(artLayer, Theme.COL_GOLD, 36,  2, 132, 20, "Artefact")
    self.colArtLvl    = Widgets.createText(artLayer, Theme.COL_GOLD, 170, 2, 30,  20, "Lvl")
    self.colArtLoc    = Widgets.createText(artLayer, Theme.COL_GOLD, 202, 2, 100, 20, "Location", 0, 0, 0, 0)
    self.colArtOwned  = Widgets.createText(artLayer, Theme.COL_GOLD, -330, 2, 82,   20, "Owned",    1.0, 0, 0, 0)
    self.colArtQty    = Widgets.createText(artLayer, Theme.COL_GOLD, -242, 2, 64,   20, "Include",  1.0, 0, 0, 0)
    if ui.AlignMode then
        pcall(function()
            self.colArtQty.alignHorizontal = ui.AlignMode.CENTRE
        end)
    end
    self.colArtStatus = Widgets.createText(artLayer, Theme.COL_GOLD, -143, 2, 135,  20, "Status",   1.0, 0, 0, 0)

    local startY = 24
    for i = 1, Theme.MAX_ARTEFACT_ROWS do
        local rowY = startY + (i - 1) * Theme.ROW_HEIGHT
        self.artefactRows[i] = Widgets.buildArtefactRow(
            artLayer,
            i,
            rowY,
            bindRowHover,
            forwardScrollWheel,
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

function Window:onStepCollectionTarget(rowIdx, delta)
    local item = self.currentCollections and self.currentCollections[rowIdx]
    if item and item.data and item.data.name and self.tracker then
        self.tracker:adjustCollectionTargetCount(item.data.name, delta)
        self:refresh()
        self:onHoverCollectionRow(rowIdx)
    end
end

function Window:onSetCollectionTargetMax(rowIdx)
    local item = self.currentCollections and self.currentCollections[rowIdx]
    if item and item.data and item.data.name and self.tracker then
        self.tracker:setCollectionTargetToMax(item.data.name)
        self:refresh()
        self:onHoverCollectionRow(rowIdx)
    end
end

function Window:onResetCollectionTarget(rowIdx)
    local item = self.currentCollections and self.currentCollections[rowIdx]
    if item and item.data and item.data.name and self.tracker then
        self.tracker:resetCollectionTarget(item.data.name)
        self:refresh()
        self:onHoverCollectionRow(rowIdx)
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

    self._inLayout = true

    local availW = self:getAvailableContentWidth()
    self.btnTabCollections.setHidden(false)
    self.btnTabArtefacts.setHidden(false)
    self.btnTabMaterials.setHidden(false)
    if self.badgeBoard     then if self.badgeBoard.setHidden then self.badgeBoard.setHidden(false) elseif self.badgeBoard.root then self.badgeBoard.root.hidden = false end end
    if self.badgeStorage   then if self.badgeStorage.setHidden then self.badgeStorage.setHidden(false) elseif self.badgeStorage.root then self.badgeStorage.root.hidden = false end end
    if self.badgeBank      then if self.badgeBank.setHidden then self.badgeBank.setHidden(false) elseif self.badgeBank.root then self.badgeBank.root.hidden = false end end

    local isColTab = (self.activeTab == "collections")
    local isArtTab = (self.activeTab == "artefacts")
    local isMatTab = (self.activeTab == "materials")
    local tabKey = self.activeTab

    if not forceReflow and self._lastAvailW == availW and self._lastTabLayout == tabKey then
        self._inLayout = false
        return
    end

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

        -- Top row (y = 5): [ Collections ] [ Artefacts ] [ Materials ] (full width)
        local tabW = math.floor((availW - (gap * 2)) / 3)
        self.btnTabCollections.setBounds(8, 5, tabW, 26)
        self.btnTabArtefacts.setBounds(8 + tabW + gap, 5, tabW, 26)
        self.btnTabMaterials.setBounds(8 + (tabW * 2) + (gap * 2), 5, availW - (tabW * 2) - (gap * 2), 26)

        -- Second row (y = 36):
        -- Right side: [Collectors: 13/13] [Stor] [Bank]
        local xBank = 8 + availW - Theme.BADGE_W
        local xStor = xBank - gap - Theme.BADGE_W
        local pillW = 142
        local xCol  = xStor - gap - pillW
        local totalBtnsW = math.max(120, xCol - 8 - gap)

        if self.badgeBank then self.badgeBank.setBounds(xBank, 36, Theme.BADGE_W, 26) end
        if self.badgeStorage then self.badgeStorage.setBounds(xStor, 36, Theme.BADGE_W, 26) end
        if self.badgeBoard then self.badgeBoard.setBounds(xCol, 36, pillW, 26) end

        -- Left side buttons per tab: (PROPORTIONALLY SCALED - ALL BUTTONS RESIZE TOGETHER)
        self.btnSource.setHidden(true)
        if isColTab then
            local availForBtns = totalBtnsW - (gap * 2)
            local w1 = math.floor(availForBtns * 0.34)
            local w2 = math.floor(availForBtns * 0.38)
            local w3 = availForBtns - (w1 + w2)
            self.btnColFilter.setHidden(false)
            self.btnColFilter.setBounds(8, 36, w1, 26)
            if self.btnTargetMax then
                self.btnTargetMax.setHidden(false)
                self.btnTargetMax.setBounds(8 + w1 + gap, 36, w2, 26)
            end
            self.btnClearTargets.setHidden(false)
            self.btnClearTargets.setBounds(8 + w1 + gap + w2 + gap, 36, w3, 26)

            self.btnArtFilter.setHidden(true)
            self.btnDupes.setHidden(true)
            self.btnPin.setHidden(true)
            self.btnFilter.setHidden(true)
            if self.btnSpots then self.btnSpots.setHidden(true) end
        elseif isArtTab then
            local availForBtns = totalBtnsW - (gap * 2)
            local w1 = math.floor(availForBtns * 0.38)
            local w2 = math.floor(availForBtns * 0.38)
            local w3 = availForBtns - (w1 + w2)
            self.btnArtFilter.setHidden(false)
            self.btnArtFilter.setBounds(8, 36, w1, 26)
            self.btnDupes.setHidden(false)
            self.btnDupes.setBounds(8 + w1 + gap, 36, w2, 26)
            self.btnPin.setHidden(false)
            self.btnPin.setBounds(8 + w1 + gap + w2 + gap, 36, w3, 26)

            self.btnColFilter.setHidden(true)
            if self.btnTargetMax then self.btnTargetMax.setHidden(true) end
            self.btnClearTargets.setHidden(true)
            self.btnFilter.setHidden(true)
            if self.btnSpots then self.btnSpots.setHidden(true) end
        else
            self.btnFilter.setHidden(false)
            self.btnFilter.setBounds(8, 36, totalBtnsW, 26)

            self.btnColFilter.setHidden(true)
            if self.btnTargetMax then self.btnTargetMax.setHidden(true) end
            self.btnClearTargets.setHidden(true)
            self.btnArtFilter.setHidden(true)
            self.btnDupes.setHidden(true)
            self.btnPin.setHidden(true)
            if self.btnSpots then self.btnSpots.setHidden(true) end
        end
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

    local searchY = curY
    local searchH = (self.searchField ~= nil) and 24 or 0
    if searchH > 0 then
        curY = curY + searchH + 5
    end

    local tableHeaderY = curY
    local numTiles = (self.activeTab == "collections") and 4 or 2

    if forceReflow
        or self._lastHeaderAvailW ~= availW
        or self._lastNumTiles ~= numTiles
        or self._lastNoticeH ~= noticeH
        or self._lastDescH ~= descH
        or self._lastSearchH ~= searchH
        or self._lastTableHeaderY ~= tableHeaderY then
        self._lastHeaderAvailW = availW
        self._lastNumTiles = numTiles
        self._lastNoticeH = noticeH
        self._lastDescH = descH
        self._lastSearchH = searchH
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

        if self.searchField and self.searchField.root then
            local clearW = 20
            local sGap = 4
            local inputW = (availW or 480) - clearW - sGap
            self.searchField.root:SetPos(8, searchY)
            self.searchField.root:SetSize(inputW, searchH)
            if self.btnSearchClear then
                self.btnSearchClear.setHidden(false)
                self.btnSearchClear.setBounds(8 + inputW + sGap, searchY + 2, clearW, 20)
            end
        end

        if self.emptyTableNotice then
            local noticeW = math.max(120, (availW or 480) - 16)
            self.emptyTableNotice.setBounds(8, tableHeaderY, noticeW, 52)
        end

        if self.collectionsTableLayer then
            self.collectionsTableLayer:SetPos(0, tableHeaderY)
        end
        self.artefactTableLayer:SetPos(0, tableHeaderY)
        self.tableLayer:SetPos(0, tableHeaderY)
    end

    local locW = 88
    if self.colArtStatus and self.colArtQty and self.colArtOwned and self.colArtLoc then
        local wAvail = availW or 480
        local statusW = math.min(185, math.max(86, math.floor(105 + (wAvail - 500) * 0.18)))
        local ownedW = math.min(95, math.max(54, math.floor(68 + (wAvail - 500) * 0.12)))
        local nameW = math.min(132, math.max(98, math.floor(125 + math.min(0, wAvail - 520) * 0.18)))
        local lvlW = 26
        local lvlX = 36 + nameW + 2
        local locX = lvlX + lvlW + 4

        local statusOffset = statusW + 6
        local qtyGap = 14
        local qtyOffset = statusOffset + 64 + qtyGap
        local ownedOffset = qtyOffset + ownedW + 6
        local availableLocW = (wAvail - ownedOffset - 6) - locX
        local locVisible = availableLocW >= 28
        locW = locVisible and math.floor(availableLocW) or 88
        self._artLocVisible = locVisible

        if forceReflow or self._lastArtAvailW ~= wAvail then
            self._lastArtAvailW = wAvail
            self._lastStatusW = statusW
            self._lastOwnedW = ownedW

            if self.colArtName then self.colArtName:SetSize(nameW, 20, 0, 0) end
            if self.colArtLvl then self.colArtLvl:SetPos(lvlX, 2, 0, 0) end

            self.colArtStatus:SetPos(-statusOffset, 2, 1.0, 0)
            self.colArtStatus:SetSize(statusW, 20, 0, 0)
            self.colArtQty:SetPos(-qtyOffset, 2, 1.0, 0)
            self.colArtOwned:SetPos(-ownedOffset, 2, 1.0, 0)
            self.colArtOwned:SetSize(ownedW, 20, 0, 0)

            if locVisible then
                self.colArtLoc.hidden = false
                self.colArtLoc:SetPos(locX, 2, 0, 0)
                self.colArtLoc:SetSize(locW, 20, 0, 0)
            else
                self.colArtLoc.hidden = true
            end

            if self.artefactRows then
                local artStartY = 24
                for i = 1, Theme.MAX_ARTEFACT_ROWS do
                    local row = self.artefactRows[i]
                    if row then
                        local rY = artStartY + (i - 1) * Theme.ROW_HEIGHT
                        row.nameTxt:SetSize(nameW, Theme.ROW_HEIGHT - 2, 0, 0)
                        row.lvlTxt:SetPos(lvlX, rY + 2, 0, 0)

                        row.statusTxt:SetPos(-statusOffset, rY + 2, 1.0, 0)
                        row.statusTxt:SetSize(statusW, Theme.ROW_HEIGHT - 2, 0, 0)
                        local isSprite = (row.plusTxt == nil)
                        local btnY = isSprite and (rY + 4) or (rY + 2)
                        row.plusBg:SetPos(-qtyOffset + 48, btnY, 1.0, 0)
                        if row.plusTxt then row.plusTxt:SetPos(-qtyOffset + 48, rY + 2, 1.0, 0) end
                        row.qtyTxt:SetPos(-qtyOffset + 20, rY + 2, 1.0, 0)
                        row.minusBg:SetPos(-qtyOffset, btnY, 1.0, 0)
                        if row.minusTxt then row.minusTxt:SetPos(-qtyOffset, rY + 2, 1.0, 0) end
                        row.ownedTxt:SetPos(-ownedOffset, rY + 2, 1.0, 0)
                        row.ownedTxt:SetSize(ownedW, Theme.ROW_HEIGHT - 2, 0, 0)

                        row.locTxt:SetPos(locX, rY + 2, 0, 0)
                        row.locTxt:SetSize(locW, Theme.ROW_HEIGHT - 2, 0, 0)
                        if not locVisible then
                            row.locTxt.hidden = true
                        elseif i <= (self.visibleArtRowCount or 0) then
                            row.locTxt.hidden = false
                        end
                    end
                end
            end
        end
    end

    if self.colHReward and self.colHTarget and self.colHReady and self.colHColName then
        local wAvail = availW or 480
        local maxRewW = 220
        local rewW = math.min(maxRewW, math.max(40, locW))
        local rewNegOffset = 68 + rewW
        local nameW = math.max(40, (wAvail - rewNegOffset - 6) - 228)

        if forceReflow or self._lastColAvailW ~= wAvail then
            self._lastColAvailW = wAvail
            self.colHReward:SetPos(-rewNegOffset, 2, 1.0, 0)
            self.colHReward:SetSize(rewW, 20, 0, 0)
            self.colHColName:SetPos(228, 2, 0, 0)
            self.colHColName:SetSize(nameW, 20, 0, 0)

            if self.collectionRows then
                for i = 1, Theme.MAX_COLLECTION_ROWS do
                    local row = self.collectionRows[i]
                    if row then
                        local rY = 24 + (i - 1) * Theme.ROW_HEIGHT
                        row.rewardTxt:SetPos(-rewNegOffset, rY + 2, 1.0, 0)
                        row.rewardTxt:SetSize(rewW, Theme.ROW_HEIGHT - 2, 0, 0)
                        row.nameTxt:SetPos(228, rY + 2, 0, 0)
                        row.nameTxt:SetSize(nameW, Theme.ROW_HEIGHT - 2, 0, 0)
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
        and (tableHeaderY + 60)
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

    local targetContent = parent
    local scrollHost = nil

    if prettyui and prettyui.SimpleView then
        local ok, view = pcall(function()
            return prettyui.SimpleView.new(parent, {
                x = 0,
                y = 0,
                width = 0,
                height = 0,
                widthAnchor = 1.0,
                heightAnchor = 1.0,
                scrollable = true,
                contentHeight = 460,
                scrollStep = 28,
            })
        end)
        if ok and view and view.content then
            targetContent = view.content
            scrollHost = view
            self.hubScrollView = view
        end
    end

    if parent.Subscribe and ui and ui.Hook and ui.Hook.ONRESIZE then
        pcall(function()
            parent:Subscribe(ui.Hook.ONRESIZE, "arch_hub_resize", function()
                if self.hubScrollView and self.hubScrollView.Refresh then
                    self.hubScrollView:Refresh()
                end
            end)
        end)
    end

    local curY = 10
    local t = self.tracker

    local function forwardHubWheel(comp, delta)
        if scrollHost and scrollHost.ScrollBy then
            scrollHost:ScrollBy(delta * (scrollHost.scrollStep or 28))
            return false
        end
        return false
    end

    -- 1. Window Visibility
    local toggleLabel = self.isVisible and "Hide Assistant Window" or "Show Assistant Window"
    self.hubBtnWinToggle = Widgets.createToolbarButton(targetContent, toggleLabel, "Show or hide the main Archaeology Assistant window.", false, function()
        if self:tryMount() then
            self:setWindowVisible(not self.isVisible)
            self:refreshHub()
        end
    end, forwardHubWheel)
    self.hubBtnWinToggle.setBounds(12, curY, -24, 28, 0, 0, 1.0, 0)
    curY = curY + 36

    -- 2. Section: INVENTORY SOURCES
    Widgets.createText(targetContent, Theme.COL_GOLD, 12, curY, 240, 18, "INVENTORY SOURCES")
    curY = curY + 22

    -- Backpack toggle
    local isBag = t and t:isSourceEnabled("bag")
    self.hubBtnSrcBag = Widgets.createToolbarButton(targetContent, isBag and "Backpack: ON" or "Backpack: OFF", "Include materials & artefacts in backpack.", false, function()
        if self.tracker then
            self.tracker:toggleSource("bag")
            self:refresh()
            self:refreshHub()
        end
    end, forwardHubWheel)
    self.hubBtnSrcBag.setBounds(12, curY, -24, 26, 0, 0, 1.0, 0)
    self.hubBtnSrcBag.setActive(isBag)
    curY = curY + 30

    -- Material Storage toggle
    local isStor = t and t:isSourceEnabled("storage")
    self.hubBtnSrcStorage = Widgets.createToolbarButton(targetContent, isStor and "Material Storage: ON" or "Material Storage: OFF", "Include materials in Material Storage.", false, function()
        if self.tracker then
            self.tracker:toggleSource("storage")
            self:refresh()
            self:refreshHub()
        end
    end, forwardHubWheel)
    self.hubBtnSrcStorage.setBounds(12, curY, -24, 26, 0, 0, 1.0, 0)
    self.hubBtnSrcStorage.setActive(isStor)
    curY = curY + 30

    -- Bank toggle
    local isBank = t and t:isSourceEnabled("bank")
    self.hubBtnSrcBank = Widgets.createToolbarButton(targetContent, isBank and "Bank: ON" or "Bank: OFF", "Include materials & artefacts in your Bank.", false, function()
        if self.tracker then
            self.tracker:toggleSource("bank")
            self:refresh()
            self:refreshHub()
        end
    end, forwardHubWheel)
    self.hubBtnSrcBank.setBounds(12, curY, -24, 26, 0, 0, 1.0, 0)
    self.hubBtnSrcBank.setActive(isBank)
    curY = curY + 30

    -- Workbench toggle
    local isBench = t and t:isSourceEnabled("workbench")
    self.hubBtnSrcWorkbench = Widgets.createToolbarButton(targetContent, isBench and "Workbench Storage: ON" or "Workbench Storage: OFF", "Include damaged artefacts stored in the Archaeologist's workbench.", false, function()
        if self.tracker then
            self.tracker:toggleSource("workbench")
            self:refresh()
            self:refreshHub()
        end
    end, forwardHubWheel)
    self.hubBtnSrcWorkbench.setBounds(12, curY, -24, 26, 0, 0, 1.0, 0)
    self.hubBtnSrcWorkbench.setActive(isBench)
    curY = curY + 38

    -- 3. Section: COLLECTIONS FILTER
    Widgets.createText(targetContent, Theme.COL_GOLD, 12, curY, 240, 18, "COLLECTIONS FILTER")
    curY = curY + 22

    -- Level Met / Show All toggle
    local isLvlMet = t and t.filterByLevel
    self.hubBtnLevelFilter = Widgets.createToolbarButton(targetContent, isLvlMet and "Level Req: Level Met" or "Level Req: Show All", "Toggle only showing collections you have the Archaeology level for.", false, function()
        if self.tracker then
            self.tracker:toggleFilterByLevel()
            self:refresh()
            self:refreshHub()
        end
    end, forwardHubWheel)
    self.hubBtnLevelFilter.setBounds(12, curY, -24, 26, 0, 0, 1.0, 0)
    self.hubBtnLevelFilter.setActive(isLvlMet)
    curY = curY + 38

    -- 4. Section: 3D WORLD OVERLAYS
    Widgets.createText(targetContent, Theme.COL_GOLD, 12, curY, 240, 18, "3D WORLD OVERLAYS")
    curY = curY + 22

    local spotsOn = self.overlay and self.overlay.enabled
    self.hubBtnSpots = Widgets.createToolbarButton(targetContent, spotsOn and "3D Excavation Spots: ON" or "3D Excavation Spots: OFF", "Toggle 3D world overhead indicators and excavation spot highlights.", false, function()
        if self.overlay and self.overlay.toggleEnabled then
            self.overlay:toggleEnabled()
            self:refreshHub()
        end
    end, forwardHubWheel)
    self.hubBtnSpots.setBounds(12, curY, -24, 26, 0, 0, 1.0, 0)
    self.hubBtnSpots.setActive(spotsOn)
    curY = curY + 38

    -- 5. Section: CACHE & RESET
    Widgets.createText(targetContent, Theme.COL_GOLD, 12, curY, 240, 18, "CACHE & RESET")
    curY = curY + 22

    self.hubBtnClearCache = Widgets.createToolbarButton(targetContent, "Clear All Cache & Saved Data", "Erase all saved collector, bank, and storage data and restart fresh.", false, function()
        if self.tracker then
            self.tracker:clearAllCache()
            self:refresh()
            self:refreshHub()
        end
    end, forwardHubWheel)
    self.hubBtnClearCache.setBounds(12, curY, -24, 26, 0, 0, 1.0, 0)
    curY = curY + 46

    if scrollHost and scrollHost.SetContentHeight then
        scrollHost:SetContentHeight(curY)
        if scrollHost.Refresh then scrollHost:Refresh() end
    end

    self:refreshHub()
end

function Window:refreshHub()
    local t = self.tracker
    if self.hubBtnWinToggle then
        self.hubBtnWinToggle.setLabel(self.isVisible and "Hide Assistant Window" or "Show Assistant Window")
    end
    if t then
        if self.hubBtnSrcBag then
            local isBag = t:isSourceEnabled("bag")
            self.hubBtnSrcBag.setLabel(isBag and "Backpack: ON" or "Backpack: OFF")
            self.hubBtnSrcBag.setActive(isBag)
        end
        if self.hubBtnSrcStorage then
            local isStor = t:isSourceEnabled("storage")
            self.hubBtnSrcStorage.setLabel(isStor and "Material Storage: ON" or "Material Storage: OFF")
            self.hubBtnSrcStorage.setActive(isStor)
        end
        if self.hubBtnSrcBank then
            local isBank = t:isSourceEnabled("bank")
            self.hubBtnSrcBank.setLabel(isBank and "Bank: ON" or "Bank: OFF")
            self.hubBtnSrcBank.setActive(isBank)
        end
        if self.hubBtnSrcWorkbench then
            local isBench = t:isSourceEnabled("workbench")
            self.hubBtnSrcWorkbench.setLabel(isBench and "Workbench Storage: ON" or "Workbench Storage: OFF")
            self.hubBtnSrcWorkbench.setActive(isBench)
        end
        if self.hubBtnLevelFilter then
            local isMet = t.filterByLevel
            self.hubBtnLevelFilter.setLabel(isMet and "Level Req: Level Met" or "Level Req: Show All")
            self.hubBtnLevelFilter.setActive(isMet)
        end
    end
    if self.hubBtnSpots and self.overlay then
        local on = self.overlay.enabled
        self.hubBtnSpots.setLabel(on and "3D Excavation Spots: ON" or "3D Excavation Spots: OFF")
        self.hubBtnSpots.setActive(on)
    end
    if self.hubScrollView and self.hubScrollView.Refresh then
        self.hubScrollView:Refresh()
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
                rowUI.setDoneState(prog.isCompleted, prog.completedCount)

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
                    local raw = (col.specialBenefit ~= "" and col.specialBenefit or col.oneTimeReward)
                    rowUI.rewardTxt.content = Utils.getShortReward(raw)
                elseif col.benefitType == "weapon" then
                    rowUI.rewardTxt.colour = Theme.COL_GOLD
                    local raw = (col.specialBenefit ~= "" and col.specialBenefit or col.oneTimeReward)
                    rowUI.rewardTxt.content = Utils.getShortReward(raw)
                elseif col.benefitType == "mystery" then
                    rowUI.rewardTxt.colour = Theme.COL_AMBER
                    local raw = (col.specialBenefit ~= "" and col.specialBenefit or col.oneTimeReward)
                    rowUI.rewardTxt.content = Utils.getShortReward(raw)
                elseif isTetra or col.benefitType == "tetra" then
                    rowUI.rewardTxt.colour = Theme.COL_CREAM
                    rowUI.rewardTxt.content = "Tetracompass piece"
                else
                    rowUI.rewardTxt.colour = Theme.COL_MUTED
                    local raw = col.chronotes ~= "" and col.chronotes
                        or (col.recurringReward ~= "" and col.recurringReward or col.oneTimeReward)
                    rowUI.rewardTxt.content = Utils.getShortReward(raw)
                end

                local isTargeted = prog.isTargeted
                local targetCount = (prog.targetCount and prog.targetCount > 0) and prog.targetCount or (prog.effectiveTarget or 1)
                if rowUI.targetTxt then
                    rowUI.targetTxt.content = tostring(targetCount)
                    rowUI.targetTxt.colour = isTargeted and Theme.COL_GOLD or Theme.COL_MUTED
                end


                if prog.targetCount and prog.targetCount > 1 then
                    local sets = prog.setsReady or 0
                    local target = prog.targetCount
                    if prog.isReady or sets >= target then
                        rowUI.readyTxt.colour = Theme.COL_GREEN
                        rowUI.readyTxt.content = string.format("%d / %d", sets, target)
                    elseif sets > 0 then
                        rowUI.readyTxt.colour = Theme.COL_GOLD
                        rowUI.readyTxt.content = string.format("%d / %d", sets, target)
                    else
                        rowUI.readyTxt.colour = Theme.COL_MUTED
                        rowUI.readyTxt.content = string.format("0 / %d", target)
                    end
                else
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
            Theme.bindItemSprite(rowUI.icon, item.artefact and (item.artefact.restoredId or item.artefact.id), 1)

            rowUI.bg.hidden = false
            rowUI.nameTxt.hidden = false
            rowUI.lvlTxt.hidden = false
            rowUI.locTxt.hidden = (self._artLocVisible == false)
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

            local inBench = item.inBench or 0
            local ownedDamaged = item.ownedDamaged or ((item.inBag or 0) + (item.inBank or 0) + inBench)
            local bagRestored = item.bagRestored or 0
            local bankRestored = item.bankRestored or 0
            local totalRestored = bagRestored + bankRestored
            if inBench > 0 and (item.inBag > 0 or item.inBank > 0) then
                rowUI.ownedTxt.content = string.format("%d (Multi)", ownedDamaged)
                rowUI.ownedTxt.colour = Theme.COL_WHITE
            elseif inBench > 0 then
                rowUI.ownedTxt.content = string.format("%d (Bench)", inBench)
                rowUI.ownedTxt.colour = Theme.COL_WHITE
            elseif item.inBag > 0 and item.inBank > 0 then
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

    -- Apply Search Filtering per Tab
    local colQuery = string.lower(Utils.trim(self.colSearchQuery or ""))
    if colQuery ~= "" then
        local filteredCols = {}
        for _, item in ipairs(colList) do
            local matched = false
            local d = item.data
            if d then
                if d.name and string.find(string.lower(d.name), colQuery, 1, true) then
                    matched = true
                elseif d.collector and string.find(string.lower(d.collector), colQuery, 1, true) then
                    matched = true
                elseif d.specialBenefit and string.find(string.lower(d.specialBenefit), colQuery, 1, true) then
                    matched = true
                elseif d.oneTimeReward and string.find(string.lower(d.oneTimeReward), colQuery, 1, true) then
                    matched = true
                elseif d.recurringReward and string.find(string.lower(d.recurringReward), colQuery, 1, true) then
                    matched = true
                elseif d.artefacts then
                    for _, artName in ipairs(d.artefacts) do
                        if string.find(string.lower(artName), colQuery, 1, true) then
                            matched = true
                            break
                        end
                    end
                end
            end
            if matched then
                table.insert(filteredCols, item)
            end
        end
        colList = filteredCols
    end

    local artQuery = string.lower(Utils.trim(self.artSearchQuery or ""))
    if artQuery ~= "" then
        local filteredArts = {}
        for _, item in ipairs(artList) do
            local matched = false
            local a = item.artefact
            if a then
                if a.name and string.find(string.lower(a.name), artQuery, 1, true) then
                    matched = true
                elseif a.damagedName and string.find(string.lower(a.damagedName), artQuery, 1, true) then
                    matched = true
                elseif a.location and string.find(string.lower(a.location), artQuery, 1, true) then
                    matched = true
                elseif tostring(a.level or "") == artQuery then
                    matched = true
                end
            end
            if matched then
                table.insert(filteredArts, item)
            end
        end
        artList = filteredArts
    end

    local matQuery = string.lower(Utils.trim(self.matSearchQuery or ""))
    if matQuery ~= "" then
        local filteredMats = {}
        for _, item in ipairs(matList) do
            local matched = false
            local m = item.material
            if m then
                if m.name and string.find(string.lower(m.name), matQuery, 1, true) then
                    matched = true
                elseif m.culture and string.find(string.lower(m.culture), matQuery, 1, true) then
                    matched = true
                elseif m.caches then
                    for _, cName in ipairs(m.caches) do
                        if string.find(string.lower(cName), matQuery, 1, true) then
                            matched = true
                            break
                        end
                    end
                end
            end
            if matched then
                table.insert(filteredMats, item)
            end
        end
        matList = filteredMats
    end

    self.currentCollections = colList
    self.currentArtefacts = artList
    self.currentMaterials = matList

    local chronoteTotal = (t.getTargetedChronotesTotal and t:getTargetedChronotesTotal()) or 0
    self.btnTabCollections.setLabel(string.format("Collections (%d)", #colList))
    self.btnTabCollections.setActive(isColTab)
    self.btnTabArtefacts.setLabel(string.format("Artefacts (%d)", #artList))
    self.btnTabArtefacts.setActive(isArtTab)
    self.btnTabMaterials.setLabel(string.format("Materials (%d)", #matList))
    self.btnTabMaterials.setActive(isMatTab)

    local isColEmpty = (#colList == 0)
    local isArtEmpty = (#artList == 0)
    local isMatEmpty = (#matList == 0)

    self.collectionsTableLayer.hidden = (not isColTab) or isColEmpty
    self.artefactTableLayer.hidden    = (not isArtTab) or isArtEmpty
    self.tableLayer.hidden            = (not isMatTab) or isMatEmpty

    local isCurrentEmpty = (isColTab and isColEmpty) or (isArtTab and isArtEmpty) or (isMatTab and isMatEmpty)
    if self.emptyTableNotice then
        self.emptyTableNotice.setHidden(not isCurrentEmpty)
        if isCurrentEmpty then
            local emptyMsg = ""
            if isColTab then
                if colQuery ~= "" then
                    emptyMsg = string.format("No collections found matching '%s'.", self.colSearchQuery)
                else
                    emptyMsg = "No collections found matching current filter."
                end
            elseif isArtTab then
                if artQuery ~= "" then
                    emptyMsg = string.format("No artefacts found matching '%s'.", self.artSearchQuery)
                else
                    emptyMsg = "No damaged artefacts in Backpack, Bank, or Tracked Collections."
                end
            else
                if matQuery ~= "" then
                    emptyMsg = string.format("No materials found matching '%s'.", self.matSearchQuery)
                else
                    emptyMsg = "No materials needed. Track a collection or include artefacts to calculate requirements."
                end
            end
            local col = (self:getActiveSearchQuery() ~= "") and Theme.COL_AMBER or Theme.COL_MUTED
            self.emptyTableNotice.setMessage(emptyMsg, col)
        end
    end

    self.btnSource.setLabel(mode.shortLabel)
    if self.btnColFilter then
        self.btnColFilter.setLabel(COL_FILTER_MODES[self.colFilterIndex].label)
        self.btnColFilter.setActive(self.colFilterIndex > 1)
    end
    if self.btnTargetMax then
        self.btnTargetMax.setHidden(not isColTab)
        self.btnTargetMax.setActive(targetedCols > 0)
    end
    if self.btnClearTargets then
        self.btnClearTargets.setHidden(not isColTab)
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
    end
    if self.badgeBoard and self.badgeBoard.setStatus then
        self.badgeBoard.setStatus(syncedCount, totalCount, liveCount)
    end
    if self.pageDescStrip and self.pageDescStrip.root then
        self.pageDescStrip.root.hidden = false
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
    if self.hubScrollView and self.hubScrollView.Destroy then
        pcall(function() self.hubScrollView:Destroy() end)
        self.hubScrollView = nil
    end
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
    if self.searchField and self.searchField.Destroy then
        pcall(function() self.searchField:Destroy() end)
        self.searchField = nil
    end
    if self.win and self.win.Destroy then
        pcall(function() self:onWindowGeometryChanged() end)
        pcall(function() self.win:Destroy() end)
        self.win = nil
    end
end

return Window
