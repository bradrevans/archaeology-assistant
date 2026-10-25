-- ui/overlay.lua
-- World entity spot highlighter and overhead deficit indicator for Archaeology materials.
-- Highlights active Material Caches and Excavation Hotspots providing needed materials,
-- displaying live deficit quantities directly above the spots in-game until all required
-- materials from that spot are collected.

local Hotspots = require("data/hotspots")
local Materials = require("data/materials")
local Artefacts = require("data/artefacts")

local Overlay = {}
Overlay.__index = Overlay

local MAX_INDICATORS = 12
local MAX_SLOTS_PER_INDICATOR = 6
local SCAN_INTERVAL_TICKS = 10 -- Background world spot entity search interval
local DEFAULT_PILL_W = 110
local ROW_H = 22
local PILL_H = 30

local function makeColour(r, g, b, a)
    if Vector4 and Vector4.new then
        return Vector4.new(r, g, b, a or 1.0)
    end
    return { r = r, g = g, b = b, a = a or 1.0 }
end

local COL_GOLD         = makeColour(1.00, 0.82, 0.28, 1.0)
local COL_CYAN         = makeColour(0.25, 0.90, 1.0, 1.0)
local COL_GREEN        = makeColour(0.30, 0.92, 0.45, 1.0)
local COL_WHITE        = makeColour(0.95, 0.95, 0.95, 1.0)
local COL_CREAM        = makeColour(0.91, 0.84, 0.69, 1.0)
local COL_BG_PILL      = makeColour(0.06, 0.09, 0.14, 0.90)

-- Fast index mapping lowercase hotspot names to yielded artefacts
local hotspotArtefacts = nil
local function getHotspotArtefactsMap()
    if hotspotArtefacts then return hotspotArtefacts end
    local map = {}
    if Artefacts and Artefacts.LIST then
        for _, art in ipairs(Artefacts.LIST) do
            if art.location and art.location ~= "" then
                local locClean = string.gsub(art.location, "<[^>]+>", "")
                local def, matchedName = Hotspots.findMatch(locClean)
                local baseName = matchedName
                if not baseName then
                    baseName = string.match(locClean, "^(.-)%s*%b()") or locClean
                    baseName = string.match(baseName, "^%s*(.-)%s*$")
                end
                if baseName and baseName ~= "" then
                    local lowerKey = string.lower(baseName)
                    if not map[lowerKey] then
                        map[lowerKey] = {}
                    end
                    table.insert(map[lowerKey], art)
                end
            end
        end
    end
    hotspotArtefacts = map
    return map
end

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

local function cleanEntityName(name)
    if not name or type(name) ~= "string" then return "" end
    -- Remove RS color tags <col=...> and </col>
    local s = string.gsub(name, "<[^>]+>", "")
    -- Replace non-breaking spaces (0xA0 / 160)
    s = string.gsub(s, "[\194\160\160]", " ")
    -- Trim whitespace
    s = string.match(s, "^%s*(.-)%s*$") or s
    return s
end

local function resolveParent()
    if not ui or not ui.Interfaces or not id or not id.Component then
        return nil
    end
    local parent = nil
    if id.Component.TOPLEVEL_V2__ROOT then
        local ok, res = pcall(function() return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__ROOT) end)
        if ok and res then parent = res end
    end
    if not parent and id.Component.TOPLEVEL_V2__GAME_AREA then
        local ok, res = pcall(function() return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA) end)
        if ok and res then parent = res end
    end
    return parent
end

function Overlay.new(tracker)
    local self = setmetatable({}, Overlay)
    self.tracker = tracker
    self.mounted = false
    self.activeSpots = {}
    self.widgets = {}
    -- Start at threshold so the very first logic tick scans immediately
    self.scanCooldown = SCAN_INTERVAL_TICKS

    local savedEnabled = safeDbGet("arch_spots_enabled", 1)
    self.enabled = (savedEnabled ~= 0 and savedEnabled ~= false)

    self:tryMount()

    -- Frame-by-frame 2D screen tracking
    if Event and Event.Draw and Event.Draw.Subscribe then
        Event.Draw.Subscribe("arch_spot_draw", function()
            self:onDraw()
        end)
    end

    -- Periodic world location scanning
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

    -- Dedicated non-blocking overlay root layer for all world indicators
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

    -- Pre-allocate indicator component pool (zero garbage generation during gameplay)
    for i = 1, MAX_INDICATORS do
        local node = ui.Layer.new(root)
        node.clickthrough = true
        node.hidden = true
        node:SetPos(0, 0)
        node:SetSize(0, 0, 1.0, 1.0)

        -- Overhead Floating Deficit Badge
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

        -- Downward indicator pointer (sharp triangular chevron attached to node, not pill, so it is never clipped)
        local pinGroup = ui.Layer.new(node)
        pinGroup.clickthrough = true
        pinGroup:SetPos(0, 0)
        pinGroup:SetSize(0, 0, 1.0, 1.0)

        local p1 = ui.Rectangle.new(pinGroup)
        p1.colour = COL_GOLD
        p1.fill = true
        p1.clickthrough = true
        p1:SetSize(12, 2)

        local p2 = ui.Rectangle.new(pinGroup)
        p2.colour = COL_GOLD
        p2.fill = true
        p2.clickthrough = true
        p2:SetSize(8, 2)

        local p3 = ui.Rectangle.new(pinGroup)
        p3.colour = COL_GOLD
        p3.fill = true
        p3.clickthrough = true
        p3:SetSize(4, 2)

        local p4 = ui.Rectangle.new(pinGroup)
        p4.colour = COL_GOLD
        p4.fill = true
        p4.clickthrough = true
        p4:SetSize(2, 2)

        local fontQ = (id and id.Font and (id.Font.MUSEO_SANS_13PT_BOLD or id.Font.MUSEO_SANS_15PT_REGULAR))

        local slots = {}
        for s = 1, MAX_SLOTS_PER_INDICATOR do
            local icon = ui.Sprite.new(pill)
            icon.clickthrough = true
            icon:SetPos(0, 5)
            icon:SetSize(20, 20)
            icon.hidden = true
            if ui.ObjectQuantityDisplayMode then
                pcall(function()
                    icon.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
                end)
            end

            local text = ui.Text.new(pill)
            text.font = fontQ or id.Font.MUSEO_SANS_15PT_REGULAR
            text.colour = COL_GOLD
            text.maxLines = 1
            text.clickthrough = true
            text:SetPos(0, 6)
            text:SetSize(60, 18)
            text.hidden = true

            slots[s] = {
                icon = icon,
                text = text,
                currentObjId = nil
            }
        end

        self.widgets[i] = {
            root = node,
            pill = pill,
            pillBorder = pillBorder,
            pillBg = pillBg,
            pinP1 = p1,
            pinP2 = p2,
            pinP3 = p3,
            pinP4 = p4,
            slots = slots,
            lastPillW = DEFAULT_PILL_W,
            lastPillH = PILL_H
        }
    end

    self.mounted = true
    return true
end

-- Periodically scans active world location entities near the player
function Overlay:onLogic()
    if not self.enabled then
        if #self.activeSpots > 0 then
            self.activeSpots = {}
        end
        return
    end

    -- Fast-path live update for currently visible active spots (runs every 2 ticks: ~0.002ms)
    self.fastUpdateTicks = (self.fastUpdateTicks or 0) + 1
    if self.fastUpdateTicks >= 2 then
        self.fastUpdateTicks = 0
        if #self.activeSpots > 0 then
            self:updateActiveSpotCounts()
        end
    end

    self.scanCooldown = (self.scanCooldown or 0) + 1
    if self.scanCooldown < SCAN_INTERVAL_TICKS then
        return
    end
    self.scanCooldown = 0

    self:scanWorldSpots()
end

function Overlay:updateActiveSpotCounts()
    if #self.activeSpots == 0 then return end

    local deficits = {}
    if self.tracker and self.tracker.lastResult and self.tracker.lastResult.materials then
        for _, row in ipairs(self.tracker.lastResult.materials) do
            if row.short and row.short > 0 then
                deficits[string.lower(row.name)] = {
                    name = row.name,
                    short = row.short,
                    id = row.material and row.material.id,
                    isArtefact = false
                }
            end
        end
    end

    local spotArtsMap = getHotspotArtefactsMap()
    local kept = {}
    for _, spot in ipairs(self.activeSpots) do
        if updateSpotDisplayItems(spot, deficits, spotArtsMap, self.tracker) then
            table.insert(kept, spot)
        end
    end
    self.activeSpots = kept
end

function Overlay:triggerScan()
    if not self.enabled then return end
    self.scanCooldown = SCAN_INTERVAL_TICKS
    self:scanWorldSpots(true)
end

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

-- Fast in-place updater for an existing active spot's display items and counts (takes <0.002ms)
local function updateSpotDisplayItems(spot, deficits, spotArtsMap, tracker)
    if not isEntityAlive(spot.entity) then
        return false
    end

    if spot.isCache then
        local def = deficits[string.lower(spot.displayName)]
        if def and def.short > 0 then
            spot.materials = { def }
            return true
        else
            return false -- Cache satisfied!
        end
    else
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
                        name = art.name,
                        id = art.id,
                        short = neededQty
                    })
                end
            end
        end

        if #neededMats == 0 and #neededArts == 0 then
            return false -- All items from this hotspot satisfied!
        end

        local displayItems = {}
        for _, artItem in ipairs(neededArts) do
            table.insert(displayItems, artItem)
        end
        for _, matItem in ipairs(neededMats) do
            table.insert(displayItems, matItem)
        end

        spot.materials = displayItems
        spot.hasArtefacts = (#neededArts > 0)
        return true
    end
end

function Overlay:scanWorldSpots(force)
    -- 1. Extract all currently short/deficit materials from Tracker
    local deficits = {}
    local anyShort = false
    local deficitCount = 0

    if self.tracker and self.tracker.lastResult and self.tracker.lastResult.materials then
        for _, row in ipairs(self.tracker.lastResult.materials) do
            if row.short and row.short > 0 then
                local lowerName = string.lower(row.name)
                deficits[lowerName] = {
                    name = row.name,
                    short = row.short,
                    id = row.material and row.material.id,
                    isArtefact = false
                }
                anyShort = true
                deficitCount = deficitCount + row.short
            end
        end
    end

    local spotArtsMap = getHotspotArtefactsMap()
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

    -- If neither materials nor artefacts are needed, all indicators are dismissed immediately ("until they're gone")
    if not anyShort and not anyArts then
        self.activeSpots = {}
        self._lastScanCoord = nil
        return
    end

    -- 2. LIVE IN-PLACE UPDATE FOR EXISTING ACTIVE SPOTS
    -- Immediately updates exact live counts and prunes satisfied artefacts/materials in real time
    if #self.activeSpots > 0 then
        local kept = {}
        for _, spot in ipairs(self.activeSpots) do
            if updateSpotDisplayItems(spot, deficits, spotArtsMap, self.tracker) then
                table.insert(kept, spot)
            end
        end
        self.activeSpots = kept
    end

    -- 3. Query active location entities near the player
    local pCoord = nil
    pcall(function()
        local p = (Player and Player.GetEntity and Player.GetEntity())
            or (PlayerList and PlayerList.Self and PlayerList.Self())
        pCoord = p and p.coordGrid
    end)

    if not pCoord then
        return
    end

    -- Fast-path stationary cache: if the player hasn't moved and force is false,
    -- reuse the live-updated active spots without running an expensive 32-tile LocList entity search!
    local isStationary = false
    if not force and self._lastScanCoord and pCoord.x == self._lastScanCoord.x and pCoord.z == self._lastScanCoord.z then
        if self._lastDeficitCount == deficitCount and self._lastNeededArtCount == neededArtCount then
            isStationary = true
        end
    end

    if isStationary and #self.activeSpots > 0 then
        return
    end

    self._lastScanCoord = { x = pCoord.x, z = pCoord.z, level = pCoord.level }
    self._lastDeficitCount = deficitCount
    self._lastNeededArtCount = neededArtCount

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
    if not locs then
        self.activeSpots = {}
        return
    end

    -- 3. Match active entities against Material Caches & Excavation Hotspots
    local matched = {}
    local seenCoords = {}
    local spotArtsMap = getHotspotArtefactsMap()

    iterateEntities(locs, function(loc)
        if isEntityAlive(loc) and loc.coordGrid then
            local rawName = nil
            pcall(function() rawName = loc.displayName end)
            if rawName and rawName ~= "" then
                local clean = cleanEntityName(rawName)
                local coordKey = string.format("%d_%d", loc.coordGrid.x or 0, loc.coordGrid.z or 0)

                if not seenCoords[coordKey] then
                    -- Check proximity if player coordinate is available (within 35 tiles)
                    local inRange = true
                    if pCoord and loc.coordGrid.x and pCoord.x and loc.coordGrid.z and pCoord.z then
                        local dx = math.abs(loc.coordGrid.x - pCoord.x)
                        local dz = math.abs(loc.coordGrid.z - pCoord.z)
                        if dx > 35 or dz > 35 then
                            inRange = false
                        end
                    end

                    if inRange then
                        -- A. Check if Material Cache: "Material cache (<Material Name>)"
                        local cacheMat = string.match(clean, "^[Mm]aterial [Cc]ache %((.+)%)")
                            or string.match(clean, "^[Mm]aterial [Cc]ache%s*[:%-]%s*(.+)")
                            or string.match(clean, "^(.+)%s+[Cc]ache$")

                        if cacheMat then
                            local lowerCache = string.lower(cacheMat)
                            local def = deficits[lowerCache]
                            if def then
                                seenCoords[coordKey] = true
                                table.insert(matched, {
                                    entity = loc,
                                    coordGrid = loc.coordGrid,
                                    displayName = def.name,
                                    isCache = true,
                                    hasArtefacts = false,
                                    totalPossible = 1,
                                    materials = { def }
                                })
                            end
                        else
                            -- B. Check if Excavation Hotspot: "Administratum debris", "Venator remains", etc.
                            local hotspotDef, matchedName = Hotspots.findMatch(clean)
                            if hotspotDef then
                                local neededMats = {}
                                for _, matName in ipairs(hotspotDef.materials or {}) do
                                    local def = deficits[string.lower(matName)]
                                    if def then
                                        table.insert(neededMats, def)
                                    end
                                end

                                -- Check for needed artefacts yielded by this hotspot
                                local neededArts = {}
                                local hKey = string.lower(matchedName or clean)
                                local spotArts = spotArtsMap[hKey]
                                if (not spotArts) and hotspotDef and hotspotDef.name then
                                    spotArts = spotArtsMap[string.lower(hotspotDef.name)]
                                end
                                if spotArts and self.tracker and self.tracker.getArtefactNeededCount then
                                    for _, art in ipairs(spotArts) do
                                        local neededQty = self.tracker:getArtefactNeededCount(art.damagedName, art.name)
                                        if neededQty > 0 then
                                            table.insert(neededArts, {
                                                isArtefact = true,
                                                name = art.name,
                                                id = art.id,
                                                short = neededQty
                                            })
                                        end
                                    end
                                end

                                if #neededMats > 0 or #neededArts > 0 then
                                    seenCoords[coordKey] = true
                                    local totalPossible = (#(hotspotDef.materials or {}) > 0) and #hotspotDef.materials or 1

                                    local displayItems = {}
                                    for _, artItem in ipairs(neededArts) do
                                        table.insert(displayItems, artItem)
                                    end
                                    for _, matItem in ipairs(neededMats) do
                                        table.insert(displayItems, matItem)
                                    end

                                    table.insert(matched, {
                                        entity = loc,
                                        coordGrid = loc.coordGrid,
                                        displayName = matchedName or clean,
                                        isCache = false,
                                        hotspotDef = hotspotDef,
                                        hasArtefacts = (#neededArts > 0),
                                        totalPossible = totalPossible,
                                        materials = displayItems
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    self.activeSpots = matched
end

local function projectToScreen(entity, coordGrid, height)
    local pos = nil
    if entity then
        pcall(function()
            pos = ScreenConvert.CoordGridToScreen(entity, height)
        end)
        if not pos then
            pcall(function()
                pos = ScreenConvert.CoordFineToScreen(entity, height)
            end)
        end
    end
    if not pos and coordGrid then
        pcall(function()
            pos = ScreenConvert.CoordGridToScreen(coordGrid, height)
        end)
    end
    return pos
end

local function measureTextWidth(str, font, fallbackCharW)
    if not str or str == "" then return 0 end
    local w = nil
    if (type(font) == "table" or type(font) == "userdata") and font.GetStringWidth then
        local ok, measured = pcall(function() return font:GetStringWidth(str, false) end)
        if ok and measured and measured > 0 then
            w = measured
        end
    end
    if not w or w <= 0 then
        w = #str * (fallbackCharW or 8.5)
    end
    return w
end

-- Smooth per-frame 2D screen projection and indicator positioning
function Overlay:onDraw()
    if not self.mounted then
        if not self:tryMount() then return end
    end

    if not self.enabled or #self.activeSpots == 0 then
        self:hideAllWidgets()
        return
    end

    if not ScreenConvert or not ScreenConvert.CoordGridToScreen then
        self:hideAllWidgets()
        return
    end

    local parentW = 3840
    local parentH = 2160
    if self.parent and self.parent.width and self.parent.width > 0 then
        parentW = self.parent.width
    end
    if self.parent and self.parent.height and self.parent.height > 0 then
        parentH = self.parent.height
    end

    for i = 1, MAX_INDICATORS do
        local widget = self.widgets[i]
        local spot = self.activeSpots[i]

        if spot and spot.coordGrid and isEntityAlive(spot.entity) then
            -- Project 3D tile coordinates to 2D screen positions (450 fine units overhead)
            local overheadPos = projectToScreen(spot.entity, spot.coordGrid, 450)

            if overheadPos and overheadPos.x and overheadPos.y then
                local sx = overheadPos.x
                local sy = overheadPos.y

                -- Cull if completely off-screen
                if sx >= -100 and sx <= parentW + 100 and sy >= -50 and sy <= parentH + 100 then
                    local totalPossible = spot.totalPossible or 1
                    local pct = math.floor((100 / totalPossible) + 0.5)

                    local hasArts = (spot.hasArtefacts == true)
                    local numItems = math.min(#spot.materials, MAX_SLOTS_PER_INDICATOR)
                    local pillH = math.max(28, (numItems * ROW_H) + 6)
                    local maxTextW = 60

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
                                pcall(function()
                                    slot.icon:SetAssociatedObject(item.id)
                                end)
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

                    -- Distinctive border & pointer styling: Cyan if spot yields needed artefact, Gold for materials
                    local accentCol = hasArts and COL_CYAN or COL_GOLD
                    widget.pillBorder.colour = accentCol
                    widget.pinP1.colour = accentCol
                    widget.pinP2.colour = accentCol
                    widget.pinP3.colour = accentCol
                    widget.pinP4.colour = accentCol

                    -- Position Pill above the Spot
                    local pillX = math.floor(sx - (pillW / 2))
                    local pillY = math.floor(sy - pillH - 8)
                    widget.pill:SetPos(pillX, pillY)

                    -- Position Downward Pointer Chevron right under the pill center
                    local centerX = math.floor(pillX + (pillW / 2))
                    local topY = pillY + pillH

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
    safeDbSet("arch_spots_enabled", self.enabled and 1 or 0)
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
