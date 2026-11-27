-- ui/locate_window.lua
-- Dedicated movable, resizable, closable PrettyUI companion window for active Locate tracking.
-- Closing this window stops active Locate tracking and clears the persisted target.

local DB      = require("core/db")
local Utils   = require("core/utils")
local Theme   = require("ui/theme")
local Widgets = require("ui/widgets")

local LocateWindow = {}
LocateWindow.__index = LocateWindow

local DEFAULT_W = 360
local DEFAULT_H = 118
local MIN_W     = 200
local MIN_H     = 76
local RESIZE_ID = "arch_locate_win_resize"

function LocateWindow.new(onUserClose)
    local self = setmetatable({}, LocateWindow)
    self.onUserClose        = onUserClose
    self.mounted            = false
    self.isOpen             = false
    self._programmaticClose = false
    self._inLayout          = false
    self._isResizing        = false
    self.parent             = nil
    self.win                = nil
    self.root               = nil
    self.content            = nil
    self.icon               = nil
    self.titleTxt           = nil
    self.metaTxt            = nil
    self.divider            = nil
    self.stepTxt            = nil
    self._curObjId          = nil
    self._lastSig           = nil
    self._lastGeomX         = nil
    self._lastGeomY         = nil
    self._lastGeomW         = nil
    self._lastGeomH         = nil
    return self
end

function LocateWindow:tryMount()
    if self.mounted then return true end
    local parent = Theme.resolveParent()
    if not parent then return false end
    self.parent = parent

    local pw = (parent.width and parent.width > 100) and parent.width or 1920
    local ph = (parent.height and parent.height > 100) and parent.height or 1080

    local savedW = math.max(MIN_W, tonumber(DB.get("arch_loc_win_w", DEFAULT_W)) or DEFAULT_W)
    local savedH = math.max(MIN_H, tonumber(DB.get("arch_loc_win_h", DEFAULT_H)) or DEFAULT_H)
    savedW = math.min(savedW, pw)
    savedH = math.min(savedH, ph)

    local rawX = DB.get("arch_loc_win_x", nil)
    local rawY = DB.get("arch_loc_win_y", nil)
    local savedX = (rawX ~= nil and tonumber(rawX)) or math.floor((pw - savedW) * 0.5)
    local savedY = (rawY ~= nil and tonumber(rawY)) or 24
    savedX = Utils.clamp(savedX, 0, math.max(0, pw - savedW))
    savedY = Utils.clamp(savedY, 0, math.max(0, ph - savedH))

    if prettyui and prettyui.Window then
        self:buildPretty(parent, savedX, savedY, savedW, savedH)
    else
        self:buildFallback(parent, savedX, savedY, savedW, savedH)
    end

    self.mounted = true
    return true
end

function LocateWindow:buildContentWidgets(container)
    local icon = ui.Sprite.new(container)
    icon.clickthrough = true
    icon:SetPos(8, 6)
    icon:SetSize(24, 24)
    icon.hidden = true
    if ui.ObjectQuantityDisplayMode then
        pcall(function() icon.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER end)
    end
    self.icon = icon

    local boldFont = (id and id.Font and (id.Font.MUSEO_SANS_15PT_BOLD or id.Font.MUSEO_SANS_15PT_REGULAR)) or Theme.resolveFont()
    local regFont  = (id and id.Font and id.Font.MUSEO_SANS_15PT_REGULAR) or Theme.resolveFont()

    local titleTxt = ui.Text.new(container)
    if boldFont then titleTxt.font = boldFont end
    titleTxt.colour = Theme.COL_CYAN
    titleTxt.maxLines = 2
    titleTxt.clickthrough = true
    titleTxt:SetPos(38, 4)
    titleTxt:SetSize(280, 20)
    self.titleTxt = titleTxt

    local metaTxt = ui.Text.new(container)
    if regFont then metaTxt.font = regFont end
    metaTxt.colour = Theme.COL_CREAM
    metaTxt.maxLines = 4
    metaTxt.clickthrough = true
    metaTxt:SetPos(38, 22)
    metaTxt:SetSize(280, 20)
    self.metaTxt = metaTxt

    local divider = ui.Rectangle.new(container)
    divider.colour = Theme.makeColour(0.32, 0.28, 0.22, 0.85)
    divider.fill = true
    divider.clickthrough = true
    divider:SetPos(8, 44)
    divider:SetSize(-16, 1, 1.0, 0)
    self.divider = divider

    local stepTxt = ui.Text.new(container)
    if regFont then stepTxt.font = regFont end
    stepTxt.colour = Theme.COL_WHITE
    stepTxt.maxLines = 12
    stepTxt.clickthrough = true
    stepTxt:SetPos(8, 50)
    stepTxt:SetSize(280, 40)
    self.stepTxt = stepTxt
end

function LocateWindow:buildPretty(parent, x, y, w, h)
    local win = prettyui.Window.new(parent, {
        title = "Locating",
        categoryID = "auto",
        x = x,
        y = y,
        width = w,
        height = h,
        minWidth = MIN_W,
        minHeight = MIN_H,
        resizable = true,
        scrollable = true,
        scrollStep = 22,
        respectInterfaceLock = false,
        onClose = function()
            self.isOpen = false
            if not self._programmaticClose and self.onUserClose then
                self.onUserClose()
            end
        end,
    })

    self.win = win
    self.root = win.root
    self.content = win.content or win.root

    self:buildContentWidgets(self.content)
    Widgets.addCornerResizeGrip(win.root)

    if win.resize and win.resize._Refresh then
        local origRefresh = win.resize._Refresh
        win.resize._Refresh = function(resSelf, raise)
            origRefresh(resSelf, raise)
            local drag = resSelf.dragState
            local wasResizing = (self._isResizing == true)
            self._isResizing = (drag ~= nil)
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
            if wasResizing and not self._isResizing then
                self._lastGeomW = nil
                self:onGeometryChanged()
            end
        end
        win.resize:Refresh()
    end

    local anchor = ui.Layer.new(win.root)
    anchor:SetSize(0, 0)
    if win._RegisterOverlay then
        win:_RegisterOverlay(anchor, function() return false end, function()
            self:onGeometryChanged()
        end)
    end
    if ui.Hook and ui.Hook.ONRESIZE then
        win.root:Subscribe(ui.Hook.ONRESIZE, RESIZE_ID, function()
            self:onGeometryChanged()
        end)
        parent:Subscribe(ui.Hook.ONRESIZE, RESIZE_ID, function()
            self:onGeometryChanged()
        end)
    end

    self._programmaticClose = true
    pcall(function() win:Close() end)
    self._programmaticClose = false
    self.isOpen = false
end

function LocateWindow:buildFallback(parent, x, y, w, h)
    local root = ui.GroupBox.new(parent)
    root.stylesheetID = id.StyleSheet.DEFAULT
    root:SetHeaderLayout(0, 0, 0, 0, 0)
    root:SetPos(x, y)
    root:SetSize(w, h)
    root.hidden = true
    self.root = root
    self.content = root
    self:buildContentWidgets(root)
end

function LocateWindow:getAvailableWidth()
    if self.content and self.content.width and self.content.width > 40 then
        return self.content.width
    end
    if self.win and self.win._scroll and self.win._scroll.width and self.win._scroll.width > 40 then
        return self.win._scroll.width
    end
    return math.max(140, ((self.root and self.root.width) or DEFAULT_W) - 16)
end

function LocateWindow:applyFlowPass(cw)
    local leftX = (self._curObjId and self._curObjId > 0) and 38 or 8
    local headerW = math.max(60, cw - leftX - 8)
    local bodyW   = math.max(60, cw - 16)

    local titleH = Theme.measureWrappedTextHeight(self.titleTxt.content or "", headerW)
    local metaY  = 4 + titleH
    local metaH  = Theme.measureWrappedTextHeight(self.metaTxt.content or "", headerW)
    local headerBottom = math.max(34, metaY + metaH + 4)

    self.titleTxt:SetPos(leftX, 4)
    self.titleTxt:SetSize(headerW, titleH)
    self.metaTxt:SetPos(leftX, metaY)
    self.metaTxt:SetSize(headerW, metaH)

    if self.divider then
        self.divider:SetPos(8, headerBottom)
        self.divider:SetSize(bodyW, 1)
    end

    local stepY = headerBottom + 6
    local stepH = Theme.measureWrappedTextHeight(self.stepTxt.content or "", bodyW)
    self.stepTxt:SetPos(8, stepY)
    self.stepTxt:SetSize(bodyW, stepH + 2)

    return stepY + stepH + 8
end

function LocateWindow:reflowLayout()
    if not self.root or not self.titleTxt or not self.metaTxt or not self.stepTxt then return end
    local cw = self:getAvailableWidth()
    local totalH = self:applyFlowPass(cw)

    if self.win and self.win.SetContentHeight and self._lastContentH ~= totalH then
        self._lastContentH = totalH
        self.win:SetContentHeight(totalH)
        local updatedCw = self:getAvailableWidth()
        if updatedCw ~= cw then
            totalH = self:applyFlowPass(updatedCw)
            if self._lastContentH ~= totalH then
                self._lastContentH = totalH
                self.win:SetContentHeight(totalH)
            end
        end
    end
end

function LocateWindow:onGeometryChanged()
    if self._inLayout or not self.root or not self.isOpen then return end
    self._inLayout = true

    local rx = math.floor(self.root.x or 0)
    local ry = math.floor(self.root.y or 24)
    local rw = math.floor(self.root.width or DEFAULT_W)
    local rh = math.floor(self.root.height or DEFAULT_H)

    if rx == self._lastGeomX and ry == self._lastGeomY and rw == self._lastGeomW and rh == self._lastGeomH then
        self._inLayout = false
        return
    end
    self._lastGeomX, self._lastGeomY, self._lastGeomW, self._lastGeomH = rx, ry, rw, rh

    if self.parent and self.parent.width and self.parent.height and self.parent.width > 100 then
        local maxX = math.max(0, self.parent.width - rw)
        local maxY = math.max(0, self.parent.height - rh)
        local cx = Utils.clamp(rx, 0, maxX)
        local cy = Utils.clamp(ry, 0, maxY)
        if cx ~= rx or cy ~= ry then
            rx, ry = cx, cy
            self.root:SetPos(rx, ry)
        end
    end

    if not self._isResizing then
        DB.set("arch_loc_win_x", rx)
        DB.set("arch_loc_win_y", ry)
        DB.set("arch_loc_win_w", rw)
        DB.set("arch_loc_win_h", rh)
    end

    self:reflowLayout()
    self._inLayout = false
end

function LocateWindow:show()
    if not self.mounted and not self:tryMount() then return false end
    if not self.isOpen then
        self.isOpen = true
        if self.win and self.win.Show then
            pcall(function() self.win:Show() end)
        elseif self.root then
            self.root.hidden = false
        end
        self._lastGeomW = nil
        self:reflowLayout()
    end
    return true
end

function LocateWindow:closeProgrammatic()
    if not self.mounted then
        self.isOpen = false
        return
    end
    if self.isOpen then
        self.isOpen = false
        self._programmaticClose = true
        if self.win and self.win.Close then
            pcall(function() self.win:Close() end)
        elseif self.root then
            self.root.hidden = true
        end
        self._programmaticClose = false
    end
    self._lastSig = nil
end

function LocateWindow:updateState(spec, step, chebDist, closeRadius)
    if not spec then
        self:closeProgrammatic()
        return
    end
    if not self:show() then return end

    local objId = spec.itemId or 0
    local titleStr = tostring(spec.itemName or spec.label or spec.key or "")
    local siteStr = tostring(spec.siteLabel or "Dig Site")
    local metaParts = { siteStr }
    if spec.kind == "artefact" and spec.hotspotName and spec.hotspotName ~= "" then
        metaParts[#metaParts + 1] = spec.hotspotName
    elseif spec.kind == "material" then
        metaParts[#metaParts + 1] = spec.cacheOnly and "Material Cache (100%)" or "Caches & Hotspots"
    end
    local metaStr = table.concat(metaParts, "  •  ")

    local stage = step and step.stage or "offsite"
    local stepStr = ""
    local isCloseOnsite = (stage == "onsite" and chebDist ~= nil and chebDist <= (closeRadius or 5))
    if isCloseOnsite then
        stepStr = "At target: Excavate " .. tostring(step and step.label or spec.label or titleStr)
    elseif step and step.label then
        stepStr = tostring(step.label)
        if stage ~= "offsite" and chebDist and chebDist > 1 then
            stepStr = string.format("%s  (%d tiles)", stepStr, chebDist)
        end
    else
        stepStr = "Resolving route..."
    end

    local isArt = (spec.kind == "artefact")
    local sig = table.concat({ tostring(spec.kind or ""), tostring(objId), titleStr, metaStr, stepStr, isCloseOnsite and "1" or "0" }, "|")
    if sig == self._lastSig then return end
    self._lastSig = sig

    if self.icon then
        if objId > 0 then
            if self._curObjId ~= objId then
                self._curObjId = objId
                pcall(function() self.icon:SetAssociatedObject(objId) end)
            end
            self.icon.hidden = false
        else
            self._curObjId = nil
            self.icon.hidden = true
        end
    end

    if self._lastTargetKey ~= spec.key then
        self._lastTargetKey = spec.key
        if self.win and self.win.SetScrollPosition then
            pcall(function() self.win:SetScrollPosition(0) end)
        end
    end

    if self.titleTxt then
        self.titleTxt.content = titleStr
        self.titleTxt.colour = isArt and Theme.COL_CYAN or Theme.COL_GOLD
    end
    if self.metaTxt then
        self.metaTxt.content = metaStr
        self.metaTxt.colour = Theme.COL_CREAM
    end
    if self.stepTxt then
        self.stepTxt.content = stepStr
        self.stepTxt.colour = isCloseOnsite and Theme.COL_GREEN or Theme.COL_WHITE
    end
    self:reflowLayout()
end

function LocateWindow:destroy()
    if self.parent and self.parent.Unsubscribe and ui and ui.Hook and ui.Hook.ONRESIZE then
        pcall(function() self.parent:Unsubscribe(ui.Hook.ONRESIZE, RESIZE_ID) end)
    end
    if self.root and self.root.Unsubscribe and ui and ui.Hook and ui.Hook.ONRESIZE then
        pcall(function() self.root:Unsubscribe(ui.Hook.ONRESIZE, RESIZE_ID) end)
    end
    self._programmaticClose = true
    if self.win and self.win.Destroy then
        pcall(function() self.win:Destroy() end)
    elseif self.root and self.root.Destroy then
        pcall(function() self.root:Destroy() end)
    end
    self._programmaticClose = false
    self.win = nil
    self.root = nil
    self.content = nil
    self.mounted = false
    self.isOpen = false
end

return LocateWindow
