-- ui/overlay.lua
-- World entity spot highlighter and overhead deficit indicator for Archaeology materials and artefacts.
-- Highlights active Material Caches and Excavation Hotspots providing needed items,
-- displaying live deficit quantities directly above the spots in-game.

local Hotspots  = require("data/hotspots")
local Artefacts = require("data/artefacts")
local Utils     = require("core/utils")
local DB        = require("core/db")
local Theme     = require("ui/theme")

local Overlay = {}
Overlay.__index = Overlay

local MAX_INDICATORS          = 16
local MAX_SLOTS_PER_INDICATOR = 6
local SCAN_INTERVAL_TICKS     = 30 -- ~1.2s between background spot checks
local DEFAULT_PILL_W          = 110
local ROW_H                   = 22
local PILL_H                  = 30

local COL_GOLD    = Theme.COL_GOLD
local COL_CYAN    = Theme.COL_CYAN
local COL_BG_PILL = Theme.makeColour(0.06, 0.09, 0.14, 0.90)

local hotspotArtefacts = nil

--- Builds and caches a lowercase hotspot name -> yielded artefacts lookup map.
local function getHotspotArtefactsMap()
    if hotspotArtefacts then return hotspotArtefacts end
    local map = {}
    for _, art in ipairs((Artefacts and Artefacts.LIST) or {}) do
        if art.location and art.location ~= "" then
            local locClean = Utils.cleanText(art.location)
            local _, matchedName = Hotspots.findMatch(locClean)
            local baseName = matchedName or Utils.trim(string.match(locClean, "^(.-)%s*%b()") or locClean)
            if baseName and baseName ~= "" then
                local lowerKey = string.lower(baseName)
                map[lowerKey] = map[lowerKey] or {}
                table.insert(map[lowerKey], art)
            end
        end
    end
    hotspotArtefacts = map
    return map
end

--- Checks if an RS3 world entity handle is still valid/alive.
local function isEntityAlive(entity)
    if not entity then return false end
    local ok, valid = pcall(function()
        if type(entity.isValid) == "function" then
            return entity:isValid()
        elseif entity.isValid ~= nil then
            return entity.isValid
        end
        return true
    end)
    return ok and (valid == true or valid ~= false)
end

--- Resolves the top-level root UI component to mount the clickthrough overlay onto.
local function resolveParent()
    if not ui or not ui.Interfaces or not id or not id.Component then
        return nil
    end
    if id.Component.TOPLEVEL_V2__ROOT then
        local ok, res = pcall(function() return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__ROOT) end)
        if ok and res then return res end
    end
    if id.Component.TOPLEVEL_V2__GAME_AREA then
        local ok, res = pcall(function() return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA) end)
        if ok and res then return res end
    end
    return nil
end

--- Returns the player's current world grid coordinates (`x`, `z`, `level`).
local function getPlayerCoordGrid()
    local pCoord = nil
    pcall(function()
        local p = (Player and Player.GetEntity and Player.GetEntity())
            or (PlayerList and PlayerList.Self and PlayerList.Self())
        pCoord = p and p.coordGrid
    end)
    return pCoord
end

--- Queries nearby world location entities within 32 tiles of `pCoord`.
local function queryNearbyLocations(pCoord)
    local locs = nil
    if pCoord and LocList and LocList.ByDistance then
        pcall(function() locs = LocList.ByDistance(pCoord, 32) end)
    end
    if not locs and pCoord and LocList and LocList.Filter then
        pcall(function() locs = LocList.Filter({ coordGrid = pCoord, range = 32 }) end)
    end
    if not locs and LocList and LocList.All then
        pcall(function() locs = LocList.All() end)
    end
    return locs
end

--- Iterates an RS3 entity list safely whether indexed numerically or via `pairs`.
local function iterateEntities(list, callback)
    if not list then return end
    local count = #list
    if count and count > 0 then
        for i = 1, count do
            local item = list[i]
            if item then callback(item) end
        end
        return
    end
    for _, item in pairs(list) do
        if item then callback(item) end
    end
end

--- Projects a 3D world entity or coordinate grid to 2D screen coordinates via `ScreenConvert`.
local function projectToScreen(entity, coordGrid, height)
    local pos = nil
    if entity then
        pcall(function() pos = ScreenConvert.CoordGridToScreen(entity, height) end)
        if not pos then
            pcall(function() pos = ScreenConvert.CoordFineToScreen(entity, height) end)
        end
    end
    if not pos and coordGrid then
        pcall(function() pos = ScreenConvert.CoordGridToScreen(coordGrid, height) end)
    end
    return pos
end

--- Measures string width in pixels using font metrics or character width fallback.
local function measureTextWidth(str, font, fallbackCharW)
    if not str or str == "" then return 0 end
    if (type(font) == "table" or type(font) == "userdata") and font.GetStringWidth then
        local ok, measured = pcall(function() return font:GetStringWidth(str, false) end)
        if ok and measured and measured > 0 then
            return measured
        end
    end
    return #str * (fallbackCharW or 8.5)
end

--- Creates a single pre-allocated indicator widget in the overlay pool.
local function createIndicatorWidget(root, fontQ)
    local node = ui.Layer.new(root)
    node.clickthrough = true
    node.hidden = true
    node:SetPos(0, 0)
    node:SetSize(0, 0, 1.0, 1.0)

    local pill = ui.Layer.new(node)
    pill.clickthrough = true
    pill:SetPos(0, 0)
    pill:SetSize(DEFAULT_PILL_W, PILL_H)

    local pillBorder = ui.Rectangle.new(pill)
    pillBorder.colour = COL_GOLD
    pillBorder.fill = true
    pillBorder.clickthrough = true
    pillBorder:SetPos(0, 0)
    pillBorder:SetSize(DEFAULT_PILL_W, PILL_H)

    local pillBg = ui.Rectangle.new(pill)
    pillBg.colour = COL_BG_PILL
    pillBg.fill = true
    pillBg.clickthrough = true
    pillBg:SetPos(1, 1)
    pillBg:SetSize(DEFAULT_PILL_W - 2, PILL_H - 2)

    local pinGroup = ui.Layer.new(node)
    pinGroup.clickthrough = true
    pinGroup:SetPos(0, 0)
    pinGroup:SetSize(0, 0, 1.0, 1.0)

    local function createPinBar(w)
        local bar = ui.Rectangle.new(pinGroup)
        bar.colour = COL_GOLD
        bar.fill = true
        bar.clickthrough = true
        bar:SetSize(w, 2)
        return bar
    end

    local p1 = createPinBar(12)
    local p2 = createPinBar(8)
    local p3 = createPinBar(4)
    local p4 = createPinBar(2)

    local slots = {}
    for s = 1, MAX_SLOTS_PER_INDICATOR do
        local icon = ui.Sprite.new(pill)
        icon.clickthrough = true
        icon:SetPos(0, 5)
        icon:SetSize(20, 20)
        icon.hidden = true
        if ui.ObjectQuantityDisplayMode then
            pcall(function() icon.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER end)
        end

        local text = ui.Text.new(pill)
        text.font = fontQ
        text.colour = COL_GOLD
        text.maxLines = 1
        text.clickthrough = true
        text:SetPos(0, 6)
        text:SetSize(60, 18)
        text.hidden = true

        slots[s] = { icon = icon, text = text, currentObjId = nil }
    end

    return {
        root       = node,
        pill       = pill,
        pillBorder = pillBorder,
        pillBg     = pillBg,
        pinP1      = p1,
        pinP2      = p2,
        pinP3      = p3,
        pinP4      = p4,
        slots      = slots,
        lastPillW  = DEFAULT_PILL_W,
        lastPillH  = PILL_H,
    }
end

function Overlay.new(tracker)
    local self = setmetatable({}, Overlay)
    self.tracker      = tracker
    self.mounted      = false
    self.activeSpots  = {}
    self.widgets      = {}
    self.scanCooldown = SCAN_INTERVAL_TICKS

    local savedEnabled = DB.get("arch_spots_enabled", 1)
    self.enabled = (savedEnabled ~= 0 and savedEnabled ~= false)

    self:tryMount()

    if Event and Event.Draw and Event.Draw.Subscribe then
        Event.Draw.Subscribe("arch_spot_draw", function()
            self:onDraw()
        end)
    end

    if Event and Event.Logic and Event.Logic.Subscribe then
        Event.Logic.Subscribe("arch_spot_logic", function()
            self:onLogic()
        end)
    end

    return self
end

function Overlay:tryMount()
    if self.mounted then return true end

    local parent = resolveParent()
    if not parent then return false end
    self.parent = parent

    local okRoot, root = pcall(function()
        local r = ui.Layer.new(parent)
        r.clickthrough = true
        r:SetPos(0, 0)
        r:SetSize(0, 0, 1.0, 1.0)
        return r
    end)
    if not okRoot or not root then
        return false
    end
    self.overlayRoot = root

    local fontQ = (id and id.Font and (id.Font.MUSEO_SANS_13PT_BOLD or id.Font.MUSEO_SANS_15PT_REGULAR))
    for i = 1, MAX_INDICATORS do
        self.widgets[i] = createIndicatorWidget(root, fontQ)
    end

    self.mounted = true
    return true
end

function Overlay:onLogic()
    self.scanCooldown = (self.scanCooldown or 0) + 1
    if self.scanCooldown < SCAN_INTERVAL_TICKS then
        return
    end
    self.scanCooldown = 0

    if not self.enabled then
        if #self.activeSpots > 0 then
            self.activeSpots = {}
        end
        return
    end

    self:scanWorldSpots()
end

function Overlay:triggerScan()
    if not self.enabled then return end
    self.scanCooldown = SCAN_INTERVAL_TICKS
    self:scanWorldSpots(true)
end

--- Fast in-place updater for an existing active spot's display items and counts.
local function updateSpotDisplayItems(spot, deficits, spotArtsMap, tracker)
    if not isEntityAlive(spot.entity) then
        return false
    end

    if spot.isCache then
        local def = deficits[string.lower(spot.displayName)]
        if def and def.short > 0 then
            spot.materials = { def }
            return true
        end
        return false
    end

    local neededMats = {}
    local hotspotDef = spot.hotspotDef or Hotspots.findMatch(spot.displayName)
    if hotspotDef then
        for _, matName in ipairs(hotspotDef.materials or {}) do
            local def = deficits[string.lower(matName)]
            if def and def.short > 0 then
                table.insert(neededMats, def)
            end
        end
    end

    local neededArts = {}
    local hKey = string.lower(spot.displayName)
    local spotArts = spotArtsMap[hKey]
    if (not spotArts) and hotspotDef and hotspotDef.name then
        spotArts = spotArtsMap[string.lower(hotspotDef.name)]
    end
    if spotArts and tracker and tracker.getArtefactNeededCount then
        for _, art in ipairs(spotArts) do
            local neededQty = tracker:getArtefactNeededCount(art.damagedName, art.name)
            if neededQty > 0 then
                table.insert(neededArts, {
                    isArtefact = true,
                    name       = art.name,
                    id         = art.id,
                    short      = neededQty,
                })
            end
        end
    end

    if #neededMats == 0 and #neededArts == 0 then
        return false
    end

    local displayItems = {}
    for _, artItem in ipairs(neededArts) do table.insert(displayItems, artItem) end
    for _, matItem in ipairs(neededMats) do table.insert(displayItems, matItem) end

    spot.materials    = displayItems
    spot.hasArtefacts = (#neededArts > 0)
    return true
end

--- Computes squared tile distance between two coordinate grids.
local function computeDistSq(coordA, coordB)
    if coordA and coordB and coordA.x and coordA.z and coordB.x and coordB.z then
        local dx = coordA.x - coordB.x
        local dz = coordA.z - coordB.z
        return (dx * dx) + (dz * dz)
    end
    return 999999
end

function Overlay:scanWorldSpots(force)
    local deficits     = {}
    local anyShort     = false
    local deficitCount = 0

    if self.tracker and self.tracker.lastResult and self.tracker.lastResult.materials then
        for _, row in ipairs(self.tracker.lastResult.materials) do
            if row.short and row.short > 0 then
                deficits[string.lower(row.name)] = {
                    name       = row.name,
                    short      = row.short,
                    id         = row.material and row.material.id,
                    isArtefact = false,
                }
                anyShort     = true
                deficitCount = deficitCount + row.short
            end
        end
    end

    local spotArtsMap    = getHotspotArtefactsMap()
    local neededArtCount = 0
    if self.tracker and self.tracker.getArtefactNeededCount then
        for _, artList in pairs(spotArtsMap or {}) do
            for _, art in ipairs(artList) do
                local n = self.tracker:getArtefactNeededCount(art.damagedName, art.name)
                if n > 0 then
                    neededArtCount = neededArtCount + n
                end
            end
        end
    end
    local anyArts = (neededArtCount > 0)

    if not anyShort and not anyArts then
        self.activeSpots    = {}
        self._lastScanCoord = nil
        return
    end

    local pCoord = getPlayerCoordGrid()

    if #self.activeSpots > 0 then
        local kept = {}
        for _, spot in ipairs(self.activeSpots) do
            if updateSpotDisplayItems(spot, deficits, spotArtsMap, self.tracker) then
                spot.distSq = computeDistSq(spot.coordGrid, pCoord)
                table.insert(kept, spot)
            end
        end
        table.sort(kept, function(a, b) return (a.distSq or 999999) < (b.distSq or 999999) end)
        self.activeSpots = kept
    end

    if not pCoord then return end

    local isStationary = (not force)
        and self._lastScanCoord
        and pCoord.x == self._lastScanCoord.x
        and pCoord.z == self._lastScanCoord.z
        and self._lastDeficitCount == deficitCount
        and self._lastNeededArtCount == neededArtCount

    if isStationary and #self.activeSpots > 0 then
        return
    end

    self._lastScanCoord      = { x = pCoord.x, z = pCoord.z, level = pCoord.level }
    self._lastDeficitCount   = deficitCount
    self._lastNeededArtCount = neededArtCount

    local locs = queryNearbyLocations(pCoord)
    if not locs then
        self.activeSpots = {}
        return
    end

    local matched    = {}
    local seenCoords = {}

    iterateEntities(locs, function(loc)
        if not isEntityAlive(loc) or not loc.coordGrid then return end
        local rawName = nil
        pcall(function() rawName = loc.displayName end)
        if not rawName or rawName == "" then return end

        local clean    = Utils.cleanText(rawName)
        local coordKey = string.format("%d_%d", loc.coordGrid.x or 0, loc.coordGrid.z or 0)
        if seenCoords[coordKey] then return end

        if loc.coordGrid.x and pCoord.x and loc.coordGrid.z and pCoord.z then
            if math.abs(loc.coordGrid.x - pCoord.x) > 35 or math.abs(loc.coordGrid.z - pCoord.z) > 35 then
                return
            end
        end

        local cacheMat = string.match(clean, "^[Mm]aterial [Cc]ache %((.+)%)")
            or string.match(clean, "^[Mm]aterial [Cc]ache%s*[:%-]%s*(.+)")
            or string.match(clean, "^(.+)%s+[Cc]ache$")

        if cacheMat then
            local def = deficits[string.lower(cacheMat)]
            if def then
                seenCoords[coordKey] = true
                table.insert(matched, {
                    entity        = loc,
                    coordGrid     = loc.coordGrid,
                    distSq        = computeDistSq(loc.coordGrid, pCoord),
                    displayName   = def.name,
                    isCache       = true,
                    hasArtefacts  = false,
                    totalPossible = 1,
                    materials     = { def },
                })
            end
            return
        end

        local hotspotDef, matchedName = Hotspots.findMatch(clean)
        if not hotspotDef then return end

        local neededMats = {}
        for _, matName in ipairs(hotspotDef.materials or {}) do
            local def = deficits[string.lower(matName)]
            if def then table.insert(neededMats, def) end
        end

        local neededArts = {}
        local hKey       = string.lower(matchedName or clean)
        local spotArts   = spotArtsMap[hKey] or (hotspotDef.name and spotArtsMap[string.lower(hotspotDef.name)])
        if spotArts and self.tracker and self.tracker.getArtefactNeededCount then
            for _, art in ipairs(spotArts) do
                local neededQty = self.tracker:getArtefactNeededCount(art.damagedName, art.name)
                if neededQty > 0 then
                    table.insert(neededArts, {
                        isArtefact = true,
                        name       = art.name,
                        id         = art.id,
                        short      = neededQty,
                    })
                end
            end
        end

        if #neededMats > 0 or #neededArts > 0 then
            seenCoords[coordKey] = true
            local displayItems = {}
            for _, artItem in ipairs(neededArts) do table.insert(displayItems, artItem) end
            for _, matItem in ipairs(neededMats) do table.insert(displayItems, matItem) end

            table.insert(matched, {
                entity        = loc,
                coordGrid     = loc.coordGrid,
                distSq        = computeDistSq(loc.coordGrid, pCoord),
                displayName   = matchedName or clean,
                isCache       = false,
                hotspotDef    = hotspotDef,
                hasArtefacts  = (#neededArts > 0),
                totalPossible = (#(hotspotDef.materials or {}) > 0) and #hotspotDef.materials or 1,
                materials     = displayItems,
            })
        end
    end)

    table.sort(matched, function(a, b) return (a.distSq or 999999) < (b.distSq or 999999) end)
    self.activeSpots = matched
end

function Overlay:onDraw()
    if not self.mounted and not self:tryMount() then return end
    if not self.enabled or #self.activeSpots == 0 then
        self:hideAllWidgets()
        return
    end
    if not ScreenConvert or not ScreenConvert.CoordGridToScreen then
        self:hideAllWidgets()
        return
    end

    local parentW = (self.parent and self.parent.width and self.parent.width > 0) and self.parent.width or 3840
    local parentH = (self.parent and self.parent.height and self.parent.height > 0) and self.parent.height or 2160

    for i = 1, MAX_INDICATORS do
        local widget = self.widgets[i]
        local spot   = self.activeSpots[i]

        if spot and spot.coordGrid and isEntityAlive(spot.entity) then
            local overheadPos = projectToScreen(spot.entity, spot.coordGrid, 450)
            if overheadPos and overheadPos.x and overheadPos.y then
                local sx, sy = overheadPos.x, overheadPos.y
                if sx >= -100 and sx <= parentW + 100 and sy >= -50 and sy <= parentH + 100 then
                    local totalPossible = spot.totalPossible or 1
                    local pct           = math.floor((100 / totalPossible) + 0.5)
                    local hasArts       = (spot.hasArtefacts == true)
                    local numItems      = math.min(#spot.materials, MAX_SLOTS_PER_INDICATOR)
                    local pillH         = math.max(28, (numItems * ROW_H) + 6)
                    local maxTextW      = 60

                    for s = 1, MAX_SLOTS_PER_INDICATOR do
                        local slot = widget.slots[s]
                        local item = spot.materials[s]

                        if item then
                            local str
                            if item.isArtefact then
                                str = string.format("x%d %s", item.short, item.name)
                                slot.text.colour = COL_CYAN
                            else
                                str = string.format("x%d (%d%%)", item.short, pct)
                                slot.text.colour = COL_GOLD
                            end
                            slot.text.content = str

                            local textW = measureTextWidth(str, slot.text.font, 8.0)
                            if textW > maxTextW then maxTextW = textW end

                            local rowY = 3 + (s - 1) * ROW_H
                            slot.icon:SetPos(6, rowY + 1)
                            slot.text:SetPos(30, rowY + 2)

                            if item.id and item.id > 0 and slot.currentObjId ~= item.id then
                                pcall(function() slot.icon:SetAssociatedObject(item.id) end)
                                slot.currentObjId = item.id
                            end

                            slot.icon.hidden = false
                            slot.text.hidden = false
                        else
                            slot.icon.hidden = true
                            slot.text.hidden = true
                        end
                    end

                    local pillW = math.max(105, math.min(240, maxTextW + 36))
                    for s = 1, numItems do
                        widget.slots[s].text:SetSize(pillW - 32, 18)
                    end

                    if widget.lastPillW ~= pillW or widget.lastPillH ~= pillH then
                        widget.lastPillW = pillW
                        widget.lastPillH = pillH
                        widget.pill:SetSize(pillW, pillH)
                        widget.pillBorder:SetSize(pillW, pillH)
                        widget.pillBg:SetSize(pillW - 2, pillH - 2)
                    end

                    local accentCol = hasArts and COL_CYAN or COL_GOLD
                    widget.pillBorder.colour = accentCol
                    widget.pinP1.colour      = accentCol
                    widget.pinP2.colour      = accentCol
                    widget.pinP3.colour      = accentCol
                    widget.pinP4.colour      = accentCol

                    local pillX   = math.floor(sx - (pillW / 2))
                    local pillY   = math.floor(sy - pillH - 8)
                    local centerX = math.floor(pillX + (pillW / 2))
                    local topY    = pillY + pillH

                    widget.pill:SetPos(pillX, pillY)
                    widget.pinP1:SetPos(centerX - 6, topY)
                    widget.pinP2:SetPos(centerX - 4, topY + 2)
                    widget.pinP3:SetPos(centerX - 2, topY + 4)
                    widget.pinP4:SetPos(centerX - 1, topY + 6)
                    widget.root.hidden = false
                else
                    widget.root.hidden = true
                end
            else
                widget.root.hidden = true
            end
        else
            widget.root.hidden = true
        end
    end
end

function Overlay:hideAllWidgets()
    for _, w in ipairs(self.widgets) do
        if w.root and not w.root.hidden then
            w.root.hidden = true
        end
    end
end

function Overlay:toggleEnabled()
    self.enabled = not self.enabled
    DB.set("arch_spots_enabled", self.enabled and 1 or 0)
    if not self.enabled then
        self:hideAllWidgets()
        self.activeSpots = {}
    else
        self:triggerScan()
    end
    return self.enabled
end

function Overlay:destroy()
    if Event and Event.Draw and Event.Draw.Unsubscribe then
        pcall(function() Event.Draw.Unsubscribe("arch_spot_draw") end)
    end
    if Event and Event.Logic and Event.Logic.Unsubscribe then
        pcall(function() Event.Logic.Unsubscribe("arch_spot_logic") end)
    end
    self:hideAllWidgets()
    if self.overlayRoot then
        pcall(function() self.overlayRoot.hidden = true end)
    end
end

return Overlay
