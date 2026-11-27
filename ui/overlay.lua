-- ui/overlay.lua
-- World entity spot highlighter and overhead deficit indicator for Archaeology materials and artefacts.
-- Highlights active Material Caches and Excavation Hotspots providing needed items,
-- displaying live deficit quantities directly above the spots in-game.

local Hotspots      = require("data/hotspots")
local Artefacts     = require("data/artefacts")
local Locations     = require("data/locations")
local Utils         = require("core/utils")
local DB            = require("core/db")
local NavMemory     = require("core/nav_memory")
local Theme         = require("ui/theme")
local ItemHighlight = require("ui/item_highlight")

local Overlay = {}
Overlay.__index = Overlay

local MAX_INDICATORS          = 8
local MAX_SLOTS_PER_INDICATOR = 9
local SCAN_INTERVAL_TICKS     = 15 -- ~0.3-0.6s between background spot checks
local DEFAULT_PILL_W          = 110
local ROW_H                   = 22
local PILL_H                  = 30

local COL_GOLD    = Theme.COL_GOLD
local COL_CYAN    = Theme.COL_CYAN
local COL_BG_PILL = Theme.makeColour(0.06, 0.09, 0.14, 0.90)

local hotspotArtefacts     = nil
local hotspotArtefactsList = nil
local rawNameSpotCache     = {}
local rawNameSpotCacheSize = 0
local locSigCache          = {}
local locSigCacheSize      = 0
local bestTierBySpotKey    = {}
local cachedLocQueryMode   = nil

local NEGATIVE_LOC_NAME_TOKENS = {
    "DECOR", "SCENERY", "PROP", "DEPLETED", "EMPTY", "INACTIVE",
    "INSCRIPTION", "EPITAPH", "PLAQUE", "TRANSLAT", "LORE", "MYSTERY", "STATIC",
    "NO_OP", "NOOP",
}

local NEGATIVE_CURSOR_TOKENS = {
    "INSPECT", "SEARCH", "INVESTIGATE", "READ", "STUDY",
    "TALK", "LISTEN", "OPEN", "CLOSE", "ENTER", "EXIT", "CLIMB",
    "UNLOCK", "LOCK", "PICKLOCK",
}

local function containsAnyToken(upperStr, tokens)
    if not upperStr or upperStr == "" then return false end
    for _, tok in ipairs(tokens) do
        if string.find(upperStr, tok, 1, true) then
            return true
        end
    end
    return false
end

local function inspectOp1Cursor(locCfg)
    if not locCfg then return nil, nil end
    local okFn, fn = pcall(function() return locCfg.GetOpCursor end)
    if not okFn or not fn then
        return nil, nil
    end
    local okCur, cur = pcall(locCfg.GetOpCursor, locCfg, 1)
    if not okCur or not cur then
        return nil, nil
    end
    local cName = nil
    pcall(function() cName = cur.configName or cur.name end)
    if not cName or cName == "" then
        cName = tostring(cur)
    end
    return cur, cName and tostring(cName) or nil
end

local function getLocConfigSignature(loc)
    if not loc then return { allow = true, tier = 0, op1 = "nil" } end

    local cfg, pCfg, cfgId, pCfgId
    pcall(function()
        cfg    = loc.config
        pCfg   = loc.parentConfig
        cfgId  = (cfg and cfg.id) or loc.configID
        pCfgId = pCfg and pCfg.id
    end)

    local cNum = tonumber(cfgId)
    local pNum = tonumber(pCfgId)
    local cacheKey = (cNum or pNum) and ((pNum or 0) * 1048576 + (cNum or 0)) or nil
    if cacheKey then
        local cached = locSigCache[cacheKey]
        if cached ~= nil then
            return cached
        end
    end

    local cfgName, pCfgName, pName = nil, nil, nil
    pcall(function()
        if cfg then
            cfgName = cfg.configName
        end
    end)
    pcall(function()
        if pCfg then
            pCfgName = pCfg.configName
            pName    = pCfg.name
        end
    end)

    local upperCfg      = cfgName and string.upper(tostring(cfgName)) or ""
    local upperPCfg     = pCfgName and string.upper(tostring(pCfgName)) or ""
    local combinedUpper = upperCfg .. " " .. upperPCfg

    local op1Cursor, op1Name = inspectOp1Cursor(cfg)
    if not op1Cursor and pCfg then
        local pOp1, pOp1Name = inspectOp1Cursor(pCfg)
        op1Cursor = pOp1
        op1Name   = pOp1Name
    end

    local tier = 0
    if string.find(combinedUpper, "EXCAVAT", 1, true)
        or string.find(combinedUpper, "HOTSPOT", 1, true)
        or string.find(combinedUpper, "CACHE", 1, true) then
        tier = tier + 16
    end
    if containsAnyToken(combinedUpper, NEGATIVE_LOC_NAME_TOKENS) then
        tier = tier - 16
    end

    local op1Upper = op1Name and string.upper(op1Name) or ""
    if op1Cursor ~= nil then
        if containsAnyToken(op1Upper, NEGATIVE_CURSOR_TOKENS) then
            tier = tier - 8
        else
            tier = tier + 8
            if string.find(op1Upper, "ARCH", 1, true)
                or string.find(op1Upper, "EXCAVAT", 1, true)
                or string.find(op1Upper, "MATTOCK", 1, true)
                or string.find(op1Upper, "DIG", 1, true) then
                tier = tier + 4
            end
        end
    end

    if pCfg ~= nil then
        tier = tier + 2
    end
    if string.sub(upperCfg, 1, 5) == "ARCH_" or string.sub(upperPCfg, 1, 5) == "ARCH_" then
        tier = tier + 1
    end

    local sig = {
        allow    = (tier >= 0),
        tier     = tier,
        sigKey   = cacheKey,
        cfgId    = cfgId,
        cfgName  = cfgName,
        pCfgId   = pCfgId,
        pCfgName = pCfgName,
        pName    = pName,
        op1      = op1Name or "nil",
    }

    if cacheKey then
        if locSigCacheSize >= 4096 then
            locSigCache = {}
            locSigCacheSize = 0
        end
        locSigCache[cacheKey] = sig
        locSigCacheSize = locSigCacheSize + 1
    end
    return sig
end

local function isExcavatableLoc(loc)
    local sig = getLocConfigSignature(loc)
    return sig.allow, sig.tier, sig
end

local function getEntityCoordGrid(entity)
    return entity.coordGrid
end

local function getEntityDisplayName(entity)
    return entity.displayName
end

local function classifyRawSpotName(rawName)
    local cached = rawNameSpotCache[rawName]
    if cached ~= nil then
        return cached
    end
    local clean = Utils.cleanText(rawName)
    if clean == "" then
        if rawNameSpotCacheSize >= 4096 then
            rawNameSpotCache = {}
            rawNameSpotCacheSize = 0
        end
        rawNameSpotCache[rawName] = false
        rawNameSpotCacheSize = rawNameSpotCacheSize + 1
        return false
    end

    local cacheMat = string.match(clean, "^[Mm]aterial [Cc]ache %((.+)%)")
        or string.match(clean, "^[Mm]aterial [Cc]ache%s*[:%-]%s*(.+)")
        or string.match(clean, "^(.+)%s+[Cc]ache$")
    local entry
    if cacheMat then
        entry = {
            isCache       = true,
            cacheMatLower = string.lower(cacheMat),
            clean         = clean,
        }
    else
        local hotspotDef, matchedName = Hotspots.findMatch(clean)
        if not hotspotDef then
            entry = false
        else
            entry = {
                isCache     = false,
                hotspotDef  = hotspotDef,
                matchedName = matchedName,
                clean       = clean,
            }
        end
    end

    if rawNameSpotCacheSize >= 4096 then
        rawNameSpotCache = {}
        rawNameSpotCacheSize = 0
    end
    rawNameSpotCache[rawName] = entry
    rawNameSpotCacheSize = rawNameSpotCacheSize + 1
    return entry
end

local function classifyFromConfigSig(sig)
    if not sig then return false end
    if sig.pName and sig.pName ~= "" then
        local c = classifyRawSpotName(sig.pName)
        if c then return c end
    end
    local cfgStr = sig.pCfgName or sig.cfgName
    if type(cfgStr) == "string" and cfgStr ~= "" then
        local upper = string.upper(cfgStr)
        if string.sub(upper, 1, 16) == "ARCH_EXCAVATION_" then
            local body = string.sub(cfgStr, 17)
            body = string.gsub(body, "_[Uu][Nn][Cc][Oo][Vv][Ee][Rr][Ee][Dd]$", "")
            body = string.gsub(body, "_[Cc][Oo][Vv][Ee][Rr][Ee][Dd]$", "")
            body = string.gsub(body, "_[Mm][Uu][Ll][Tt][Ii]$", "")
            body = string.gsub(body, "_%d+$", "")
            body = string.gsub(body, "_", " ")
            local c = classifyRawSpotName(body)
            if c then return c end
        end
    end
    return false
end

--- Builds and caches a lowercase hotspot name -> yielded artefacts lookup map and flat deduplicated list.
local function getHotspotArtefactsMap()
    if hotspotArtefacts then return hotspotArtefacts, hotspotArtefactsList end
    local map  = {}
    local list = {}
    for _, art in ipairs((Artefacts and Artefacts.LIST) or {}) do
        if art.location and art.location ~= "" then
            local locClean = Utils.cleanText(art.location)
            local _, matchedName = Hotspots.findMatch(locClean)
            local baseName = matchedName or Utils.trim(string.match(locClean, "^(.-)%s*%b()") or locClean)
            if baseName and baseName ~= "" then
                table.insert(list, art)
                local lowerKey = string.lower(baseName)
                map[lowerKey] = map[lowerKey] or {}
                table.insert(map[lowerKey], art)
                local normKey = Hotspots.normalizeKey(baseName)
                if normKey ~= "" and normKey ~= lowerKey then
                    map[normKey] = map[normKey] or {}
                    table.insert(map[normKey], art)
                end
            end
        end
    end
    hotspotArtefacts     = map
    hotspotArtefactsList = list
    return map, list
end

local function checkEntityValid(entity)
    if type(entity.isValid) == "function" then
        return entity:isValid()
    elseif entity.isValid ~= nil then
        return entity.isValid
    end
    return true
end

--- Checks if an RS3 world entity handle is still valid/alive.
local function isEntityAlive(entity)
    if not entity then return false end
    local ok, valid = pcall(checkEntityValid, entity)
    return ok and (valid == true or valid ~= false)
end

--- Resolves the bottom background UI layer to mount the clickthrough world overlay onto.
--- Mounting onto TOPLEVEL_V2__PLUGIN_BUILD_LAYER_BOTTOM places world overheads behind all
--- RuneScape UI interfaces (inventory, bank, chat, action bars, dialogs, assistant window).
local function resolveParent()
    if not ui or not ui.Interfaces or not id or not id.Component then
        return nil
    end
    if id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_BOTTOM then
        local ok, res = pcall(function() return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_BOTTOM) end)
        if ok and res then return res end
    end
    if id.Component.TOPLEVEL_V2__GAME_AREA then
        local ok, res = pcall(function() return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA) end)
        if ok and res then return res end
    end
    if id.Component.TOPLEVEL_V2__ROOT then
        local ok, res = pcall(function() return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__ROOT) end)
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

local function getPlayerExcavateState()
    local pEntity, isAnimating, interacting = nil, false, nil
    pcall(function()
        pEntity = (Player and Player.GetEntity and Player.GetEntity())
            or (PlayerList and PlayerList.Self and PlayerList.Self())
        if Player and Player.IsAnimating then
            isAnimating = Player.IsAnimating() == true
        end
        if not isAnimating and pEntity then
            isAnimating = (pEntity.isAnimating == true) or (type(pEntity.animation) == "number" and pEntity.animation ~= -1)
        end
        if Player and Player.GetInteracting then
            interacting = Player.GetInteracting()
        elseif pEntity and pEntity.interacting then
            interacting = pEntity.interacting
        end
    end)
    return pEntity, isAnimating, interacting
end

local function callLocByDistance(pCoord)
    return LocList.ByDistance(pCoord, 32)
end

local function callLocFilter(pCoord)
    return LocList.Filter({ coordGrid = pCoord, range = 32 })
end

local function callLocAll()
    return LocList.All()
end

--- Queries nearby world location entities within 32 tiles of `pCoord`.
local function queryNearbyLocations(pCoord)
    if not LocList then return nil end
    if cachedLocQueryMode == "ByDistance" and pCoord and LocList.ByDistance then
        local ok, locs = pcall(callLocByDistance, pCoord)
        if ok and locs then return locs end
    elseif cachedLocQueryMode == "Filter" and pCoord and LocList.Filter then
        local ok, locs = pcall(callLocFilter, pCoord)
        if ok and locs then return locs end
    elseif cachedLocQueryMode == "All" and LocList.All then
        local ok, locs = pcall(callLocAll)
        if ok and locs then return locs end
    end

    if pCoord and LocList.ByDistance then
        local ok, locs = pcall(callLocByDistance, pCoord)
        if ok and locs then
            cachedLocQueryMode = "ByDistance"
            return locs
        end
    end
    if pCoord and LocList.Filter then
        local ok, locs = pcall(callLocFilter, pCoord)
        if ok and locs then
            cachedLocQueryMode = "Filter"
            return locs
        end
    end
    if LocList.All then
        local ok, locs = pcall(callLocAll)
        if ok and locs then
            cachedLocQueryMode = "All"
            return locs
        end
    end
    return nil
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

--- Projects a 3D world coordinate grid (or entity fallback) to 2D screen coordinates via `ScreenConvert`.
local function projectToScreen(entity, coordGrid, height)
    if coordGrid then
        local ok, pos = pcall(ScreenConvert.CoordGridToScreen, coordGrid, height)
        if ok and pos then return pos end
    end
    if entity then
        local ok, pos = pcall(ScreenConvert.CoordGridToScreen, entity, height)
        if ok and pos then return pos end
        if ScreenConvert.CoordFineToScreen then
            local okF, posF = pcall(ScreenConvert.CoordFineToScreen, entity, height)
            if okF and posF then return posF end
        end
    end
    return nil
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
    self.tracker       = tracker
    self.mounted       = false
    self.activeSpots   = {}
    self.widgets       = {}
    self.scanCooldown  = SCAN_INTERVAL_TICKS
    self.itemHighlight = ItemHighlight.new()
    self.focusTarget   = nil

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
        if r.MoveToBack then pcall(function() r:MoveToBack() end) end
        return r
    end)
    if not okRoot or not root then
        return false
    end
    self.overlayRoot = root
    self.fontQ = (id and id.Font and (id.Font.MUSEO_SANS_13PT_BOLD or id.Font.MUSEO_SANS_15PT_REGULAR))

    self.mounted = true
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

local CLOSE_OVERHEAD_RADIUS = 5
local MAX_LINE_RADIUS       = 30
local LINE_SEGMENTS         = 24
local ARROW_PIXELS          = 17
local COL_ROUTE_LINE        = Theme.makeColour(0.0, 1.0, 0.95, 0.95)
local COL_ROUTE_EDGE        = Theme.makeColour(0.0, 0.0, 0.0, 0.85)
local COL_WHITE             = Theme.makeColour(0.95, 0.97, 1.0, 1.0)

local function isSpotMatchingFocus(spotKey, spotClass, focusTarget)
    if not focusTarget then return false end
    if focusTarget.cacheOnly and spotClass and not spotClass.isCache then
        return false
    end
    if spotKey and focusTarget.focusKeys and focusTarget.focusKeys[spotKey] then
        return true
    end
    if spotClass then
        if spotClass.isCache and focusTarget.materialName then
            return spotClass.cacheMatLower == string.lower(focusTarget.materialName)
        elseif not spotClass.isCache and not focusTarget.cacheOnly then
            local disp = spotClass.matchedName or spotClass.clean or ""
            if focusTarget.hotspotName and disp ~= "" then
                local tn = Hotspots.normalizeKey(focusTarget.hotspotName)
                local sn = Hotspots.normalizeKey(disp)
                if tn ~= "" and (sn == tn or string.find(sn, tn, 1, true)) then
                    return true
                end
            end
            if focusTarget.materialName and spotClass.hotspotDef and spotClass.hotspotDef.materials then
                local ml = string.lower(focusTarget.materialName)
                for _, m in ipairs(spotClass.hotspotDef.materials) do
                    if string.lower(m) == ml then return true end
                end
            end
        end
    end
    return false
end

local SITE_DIALOG_ALIASES = {
    ["Stormguard Citadel"] = { "stormguard citadel", "stormguard" },
    ["Infernal Source"]    = { "infernal source", "infernal" },
    ["Kharid-et"]          = { "kharid-et", "kharidet" },
    ["Archaeology Campus"] = { "archaeology campus", "archaeology guild", "varrock dig site", "campus" },
    ["Senntisten"]         = { "senntisten", "senntisten temple" },
}

local function buildDialogTerms(focusTarget, step)
    local terms = {}
    local seen = {}
    local function add(s)
        if not s or s == "" then return end
        local low = string.lower(s)
        if not seen[low] then
            seen[low] = true
            terms[#terms + 1] = low
        end
    end

    -- Intra-dig-site transitions use ONLY the transition's explicit ordered option terms,
    -- avoiding false matches against site-name headers or sibling sub-zones.
    if step and step.stage == "transition" then
        for _, dt in ipairs(step.dialogTerms or {}) do
            add(dt)
        end
        return terms
    end

    local function addSiteWithAliases(siteName)
        if not siteName or siteName == "" then return end
        add(siteName)
        local aliases = SITE_DIALOG_ALIASES[siteName]
        if aliases then
            for _, a in ipairs(aliases) do add(a) end
        end
    end

    addSiteWithAliases(focusTarget.siteKey)
    addSiteWithAliases(focusTarget.siteLabel)
    if focusTarget.allSites then
        for sk in pairs(focusTarget.allSites) do
            addSiteWithAliases(sk)
        end
    end

    -- Lower-priority fallbacks for two-step outfit menus ("Dig sites" -> site) or Campus relay teleports
    if step and step.stage == "offsite" and focusTarget.siteKey ~= "Archaeology Campus" then
        add("dig sites")
        add("digsites")
        add("archaeology campus")
        add("varrock dig site")
    end
    return terms
end

local function scanFocusScene(self, pCoord)
    self._liveFocusSpot        = nil
    self._nearbyFocusSpots     = nil
    self._liveTransitionEntity = nil
    if not self.focusTarget or not pCoord or not pCoord.x or not pCoord.z then return end

    local learned = NavMemory.getSpotsForKeys(self.focusTarget.focusKeys)
    local preStep = Locations.resolveGuidanceStep(self.focusTarget, pCoord, learned)
    local wantCfg = preStep and preStep.cfgPattern and string.lower(preStep.cfgPattern) or nil
    local wantObjMap = nil
    if preStep and preStep.objIds then
        wantObjMap = {}
        for _, oid in ipairs(preStep.objIds) do
            wantObjMap[oid] = true
        end
    end

    local locs = queryNearbyLocations(pCoord)
    if not locs then return end

    local px, pz, pl = pCoord.x, pCoord.z, pCoord.level or 0
    local bestSpotDist  = 999999999
    local bestTransScore = 999999999
    local nearbyFocus   = {}

    iterateEntities(locs, function(loc)
        if not isEntityAlive(loc) then return end
        local okC, cg = pcall(getEntityCoordGrid, loc)
        if not okC or not cg or not cg.x or not cg.z then return end
        if (cg.level or 0) ~= pl then return end
        local cheb = math.max(math.abs(cg.x - px), math.abs(cg.z - pz))
        if cheb > 32 then return end
        local d2 = computeDistSq(cg, pCoord)

        if (wantObjMap or wantCfg) and preStep.targetCoord then
            local targetDistSq = computeDistSq(cg, preStep.targetCoord)
            if targetDistSq <= 144 then
                local sig = getLocConfigSignature(loc)
                local idMatch = wantObjMap and sig and (
                    (sig.cfgId and wantObjMap[sig.cfgId]) or (sig.pCfgId and wantObjMap[sig.pCfgId])
                )
                local cfgMatch = false
                if not idMatch and wantCfg and targetDistSq <= 36 and sig then
                    local okDN, dispN = pcall(getEntityDisplayName, loc)
                    local combined = string.lower(
                        tostring(sig.cfgName or "") .. " " .. tostring(sig.pCfgName or "")
                        .. " " .. tostring(sig.pName or "") .. " " .. tostring((okDN and dispN) or "")
                    )
                    cfgMatch = (combined ~= "" and string.find(combined, wantCfg, 1, true) ~= nil)
                end
                if idMatch or cfgMatch then
                    local score = (idMatch and 0 or 1000) + targetDistSq
                    if score < bestTransScore then
                        bestTransScore = score
                        self._liveTransitionEntity = { entity = loc, coordGrid = cg, distSq = d2 }
                    end
                end
            end
        end

        local canExcavate, locTier, locSig = isExcavatableLoc(loc)
        if not canExcavate then return end

        local okN, rawName = pcall(getEntityDisplayName, loc)
        local spotClass = (okN and rawName and rawName ~= "") and classifyRawSpotName(rawName) or false
        if not spotClass then
            spotClass = classifyFromConfigSig(locSig)
            if not spotClass then return end
        end

        local spotKey, dispName
        if spotClass.isCache then
            dispName = spotClass.cacheMatLower
            spotKey  = "cache:" .. dispName
        else
            dispName = spotClass.matchedName or spotClass.clean or ""
            spotKey  = "spot:" .. Hotspots.normalizeKey(dispName)
        end

        NavMemory.rememberSpot(spotKey, cg.x, cg.z, cg.level or 0)

        if isSpotMatchingFocus(spotKey, spotClass, self.focusTarget) then
            if d2 < bestSpotDist then
                bestSpotDist = d2
                self._liveFocusSpot = {
                    entity      = loc,
                    coordGrid   = cg,
                    distSq      = d2,
                    displayName = dispName,
                    spotKey     = spotKey,
                    tier        = locTier,
                    isCache     = spotClass.isCache,
                    hotspotDef  = spotClass.hotspotDef,
                }
            end
            if cheb <= 32 then
                nearbyFocus[#nearbyFocus + 1] = {
                    entity      = loc,
                    coordGrid   = cg,
                    distSq      = d2,
                    displayName = dispName,
                    spotKey     = spotKey,
                    tier        = locTier,
                    isCache     = spotClass.isCache,
                    hotspotDef  = spotClass.hotspotDef,
                }
            end
        end
    end)

    self._nearbyFocusSpots = (#nearbyFocus > 0) and nearbyFocus or nil
end

function Overlay:updateFocusLogic(forceScan)
    if not self.focusTarget then
        if self._hadFocusHighlight then
            self.itemHighlight:hideAll()
            self._hadFocusHighlight = false
        end
        return
    end

    local pCoord = getPlayerCoordGrid()
    if not pCoord then return end

    self._focusScanTick = (self._focusScanTick or 0) + 1
    local movedFar = (not self._lastFocusCoord)
        or (pCoord.level ~= self._lastFocusCoord.level)
        or computeDistSq(pCoord, self._lastFocusCoord) >= 36

    if forceScan or movedFar or self._focusScanTick >= SCAN_INTERVAL_TICKS then
        self._focusScanTick = 0
        self._lastFocusCoord = { x = pCoord.x, z = pCoord.z, level = pCoord.level }
        scanFocusScene(self, pCoord)
        if NavMemory.isDirty() then
            NavMemory.flush()
        end
    end

    local learned = NavMemory.getSpotsForKeys(self.focusTarget.focusKeys)
    local step = nil
    if self._liveFocusSpot and isEntityAlive(self._liveFocusSpot.entity)
        and self._liveFocusSpot.coordGrid
        and (self._liveFocusSpot.coordGrid.level or 0) == (pCoord.level or 0) then
        step = {
            stage        = "onsite",
            targetCoord  = self._liveFocusSpot.coordGrid,
            targetEntity = self._liveFocusSpot.entity,
            label        = self.focusTarget.label,
        }
    else
        step = Locations.resolveGuidanceStep(self.focusTarget, pCoord, learned)
        if step and (step.cfgPattern or step.objIds) and self._liveTransitionEntity and isEntityAlive(self._liveTransitionEntity.entity) then
            step.targetCoord  = self._liveTransitionEntity.coordGrid
            step.targetEntity = self._liveTransitionEntity.entity
        end
    end
    self._currentGuidanceStep = step

    local stage = step and step.stage or "offsite"
    local stageChanged = (self._lastHlStage ~= stage)
    local invChanged = (self._forceInvHlScan == true)
    if invChanged then self._forceInvHlScan = false end
    self._hlTick = (self._hlTick or 0) + 1
    self._invHlTick = (self._invHlTick or 0) + 1
    local hlDue = forceScan or stageChanged or (self._hlTick >= 8)
    local runInvScan = forceScan or stageChanged or invChanged or (self._invHlTick >= 25)
    if hlDue or runInvScan then
        if hlDue then self._hlTick = 0 end
        if runInvScan then self._invHlTick = 0 end
        self._lastHlStage = stage
        local itemPats = nil
        local dlgTerms = nil
        if stage == "offsite" then
            itemPats = self.focusTarget.travelItems
            dlgTerms = buildDialogTerms(self.focusTarget, step)
        elseif stage == "campus" then
            itemPats = {}
            for _, p in ipairs(self.focusTarget.travelItems or {}) do
                if p ~= "archaeology journal" then
                    itemPats[#itemPats + 1] = p
                end
            end
            dlgTerms = buildDialogTerms(self.focusTarget, step)
        elseif stage == "transition" then
            dlgTerms = buildDialogTerms(self.focusTarget, step)
        end
        self.itemHighlight:update(itemPats, dlgTerms, self.focusTarget.mapDynIds, runInvScan)
        self._hadFocusHighlight = true
    end
end

function Overlay:onInventoryChanged()
    if self.focusTarget then
        self._forceInvHlScan = true
    end
end

function Overlay:setFocusTarget(spec)
    self.focusTarget           = spec
    self._liveFocusSpot        = nil
    self._nearbyFocusSpots     = nil
    self._liveTransitionEntity = nil
    self._currentGuidanceStep  = nil
    self._lastFocusCoord       = nil
    self._lastScanCoord        = nil
    self._hlTick               = 0
    self._invHlTick            = 0
    self._lastHlStage          = nil
    self._forceFocusUpdate     = true
    if not spec then
        self:hideFocusWidgets()
    end
end

function Overlay:onLogic()
    local forcedFocus = (self._forceFocusUpdate == true)
    if forcedFocus then
        self._forceFocusUpdate = false
        if self.focusTarget then
            self:ensureFocusWidgetsBuilt()
            self:updateFocusLogic(true)
            self.scanCooldown = SCAN_INTERVAL_TICKS - 1
            return
        else
            if self.itemHighlight then self.itemHighlight:hideAll() end
            self._hadFocusHighlight = false
            self:hideFocusWidgets()
            if self.enabled then
                self:triggerScan()
            else
                self.activeSpots = {}
            end
            return
        end
    end

    if self.focusTarget or self._hadFocusHighlight then
        if self.focusTarget then
            self:ensureFocusWidgetsBuilt()
        end
        self:updateFocusLogic(false)
    end
    if not self.enabled and not self.focusTarget then
        if #self.activeSpots > 0 then
            self.activeSpots = {}
        end
        return
    end

    self.scanCooldown = (self.scanCooldown or 0) + 1
    local movedFar = false
    if self.scanCooldown < SCAN_INTERVAL_TICKS then
        local pCoord = getPlayerCoordGrid()
        if pCoord and ((not self._lastScanCoord)
            or (pCoord.level ~= nil and pCoord.level ~= self._lastScanCoord.level)
            or computeDistSq(pCoord, self._lastScanCoord) >= 36) then
            movedFar = true
        end
        if not movedFar then
            return
        end
    end
    self.scanCooldown = 0

    self:scanWorldSpots(movedFar)
end

function Overlay:triggerScan()
    if not self.enabled then return end
    self.scanCooldown = SCAN_INTERVAL_TICKS
    self:scanWorldSpots(true)
end

--- Fast in-place updater for an existing active spot's display items and counts.
local function updateSpotDisplayItems(spot, deficits, spotArtsMap, tracker, focusTarget)
    if not isEntityAlive(spot.entity) then
        return false
    end
    local allow, curTier = isExcavatableLoc(spot.entity)
    if not allow then
        return false
    end
    spot.tier = curTier
    if spot.spotKey then
        local best = bestTierBySpotKey[spot.spotKey]
        if best == nil or curTier > best then
            bestTierBySpotKey[spot.spotKey] = curTier
            best = curTier
        end
        if curTier < best then
            return false
        end
    end

    if spot.isCache then
        local def = deficits[string.lower(spot.displayName)]
        if def and def.short > 0 then
            spot.materials    = { def }
            spot.hasArtefacts = false
            spot.isFocusOnly  = false
            return true
        end
        if focusTarget and spot.isFocusOnly and spot.spotKey and focusTarget.focusKeys and focusTarget.focusKeys[spot.spotKey] then
            local isArt = (focusTarget.kind == "artefact")
            spot.hasArtefacts = isArt
            spot.materials = { {
                isFocusOnly = true,
                isArtefact  = isArt,
                name        = focusTarget.itemName or focusTarget.label or "Target",
                id          = focusTarget.itemId,
                short       = 1,
            } }
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
    local spotArts = spotArtsMap[hKey] or spotArtsMap[Hotspots.normalizeKey(spot.displayName)]
    if (not spotArts) and hotspotDef and hotspotDef.name then
        spotArts = spotArtsMap[string.lower(hotspotDef.name)] or spotArtsMap[Hotspots.normalizeKey(hotspotDef.name)]
    end
    if spotArts and tracker and tracker.getArtefactNeededCount then
        for _, art in ipairs(spotArts) do
            local neededQty = tracker:getArtefactNeededCount(art.damagedName, art.name)
            if neededQty > 0 then
                table.insert(neededArts, {
                    isArtefact = true,
                    name       = art.name,
                    id         = art.restoredId or art.id,
                    short      = neededQty,
                })
            end
        end
    end

    if #neededMats == 0 and #neededArts == 0 then
        if focusTarget and spot.isFocusOnly and spot.spotKey and focusTarget.focusKeys and focusTarget.focusKeys[spot.spotKey] then
            local isArt = (focusTarget.kind == "artefact")
            spot.hasArtefacts = isArt
            spot.materials = { {
                isFocusOnly = true,
                isArtefact  = isArt,
                name        = focusTarget.itemName or focusTarget.label or "Target",
                id          = focusTarget.itemId,
                short       = 1,
            } }
            return true
        end
        return false
    end

    local displayItems = {}
    for _, artItem in ipairs(neededArts) do table.insert(displayItems, artItem) end
    for _, matItem in ipairs(neededMats) do table.insert(displayItems, matItem) end

    spot.materials    = displayItems
    spot.hasArtefacts = (#neededArts > 0)
    spot.isFocusOnly  = false
    return true
end

local function compareSpots(a, b)
    if (a.isExcavating == true) ~= (b.isExcavating == true) then
        return a.isExcavating == true
    end
    if (a.distSq or 999999) ~= (b.distSq or 999999) then
        return (a.distSq or 999999) < (b.distSq or 999999)
    end
    local ax = (a.coordGrid and a.coordGrid.x) or 0
    local bx = (b.coordGrid and b.coordGrid.x) or 0
    if ax ~= bx then return ax < bx end
    return ((a.coordGrid and a.coordGrid.z) or 0) < ((b.coordGrid and b.coordGrid.z) or 0)
end

local function updateExcavateStateAndSort(self, spots)
    if not spots or #spots == 0 then return end
    local _, isAnimating, interacting = getPlayerExcavateState()
    local lastExcavateTarget = self.tracker and self.tracker.lastExcavateTarget and string.lower(self.tracker.lastExcavateTarget) or nil
    local targetNorm = lastExcavateTarget and Hotspots.normalizeKey(lastExcavateTarget) or ""
    local hasDirectExcavate = false
    for _, spot in ipairs(spots) do
        spot.isExcavating = false
        if interacting and spot.entity then
            local sameEntity = (spot.entity == interacting)
            if not sameEntity and interacting.coordGrid and spot.coordGrid then
                sameEntity = (interacting.coordGrid.x == spot.coordGrid.x and interacting.coordGrid.z == spot.coordGrid.z)
            end
            if sameEntity then
                spot.isExcavating = true
                hasDirectExcavate = true
            end
        end
    end

    if not hasDirectExcavate then
        local bestTargetSpot = nil
        local bestAnimSpot = nil
        for _, spot in ipairs(spots) do
            local d = spot.distSq or 999999
            if not spot.isCache and lastExcavateTarget and lastExcavateTarget ~= "" and d <= 9 then
                local spotNameLower = string.lower(spot.displayName or "")
                local spotNameNorm  = Hotspots.normalizeKey(spot.displayName or "")
                if spotNameLower == lastExcavateTarget
                    or string.find(lastExcavateTarget, spotNameLower, 1, true)
                    or (spotNameNorm ~= "" and (spotNameNorm == targetNorm or string.find(targetNorm, spotNameNorm, 1, true))) then
                    if not bestTargetSpot or d < (bestTargetSpot.distSq or 999999) then
                        bestTargetSpot = spot
                    end
                end
            end
            if not spot.isCache and isAnimating and d <= 6 then
                if not bestAnimSpot or d < (bestAnimSpot.distSq or 999999) then
                    bestAnimSpot = spot
                end
            end
        end
        local chosen = bestTargetSpot or bestAnimSpot
        if chosen then
            chosen.isExcavating = true
        end
    end

    table.sort(spots, compareSpots)
end

function Overlay:scanWorldSpots(force)
    local spotArtsMap, spotArtsList = getHotspotArtefactsMap()
    local trackerSeq = self.tracker and self.tracker._recalcSeq

    if (not trackerSeq) or self._lastRecalcSeq ~= trackerSeq or not self._cachedDeficits then
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

        local neededArtCount = 0
        if self.tracker and self.tracker.getArtefactNeededCount then
            for _, art in ipairs(spotArtsList or {}) do
                local n = self.tracker:getArtefactNeededCount(art.damagedName, art.name)
                if n > 0 then
                    neededArtCount = neededArtCount + n
                end
            end
        end

        self._cachedDeficits       = deficits
        self._cachedAnyShort       = anyShort
        self._cachedDeficitCount   = deficitCount
        self._cachedNeededArtCount = neededArtCount
        self._cachedAnyArts        = (neededArtCount > 0)
        self._lastRecalcSeq        = trackerSeq
    end

    local deficits       = self._cachedDeficits
    local anyShort       = self._cachedAnyShort
    local deficitCount   = self._cachedDeficitCount
    local neededArtCount = self._cachedNeededArtCount
    local anyArts        = self._cachedAnyArts

    local function appendFocusOnlySpots(list, pCoord)
        if not self.focusTarget or not self._nearbyFocusSpots or not pCoord then return end
        local seen = {}
        for _, s in ipairs(list) do
            if s.coordGrid and s.coordGrid.x and s.coordGrid.z then
                seen[s.coordGrid.x * 65536 + s.coordGrid.z] = true
            end
        end
        local isArt = (self.focusTarget.kind == "artefact")
        local fName = self.focusTarget.itemName or self.focusTarget.label or "Target"
        local fId   = self.focusTarget.itemId
        for _, fs in ipairs(self._nearbyFocusSpots) do
            if isEntityAlive(fs.entity) and fs.coordGrid and fs.coordGrid.x and fs.coordGrid.z then
                local ck = fs.coordGrid.x * 65536 + fs.coordGrid.z
                if not seen[ck] then
                    seen[ck] = true
                    table.insert(list, {
                        entity        = fs.entity,
                        coordGrid     = fs.coordGrid,
                        distSq        = computeDistSq(fs.coordGrid, pCoord),
                        displayName   = fs.displayName,
                        spotKey       = fs.spotKey,
                        tier          = fs.tier or 0,
                        isCache       = fs.isCache,
                        hotspotDef    = fs.hotspotDef,
                        hasArtefacts  = isArt,
                        isFocusOnly   = true,
                        totalPossible = 1,
                        materials     = { {
                            isFocusOnly = true,
                            isArtefact  = isArt,
                            name        = fName,
                            id          = fId,
                            short       = 1,
                        } },
                    })
                end
            end
        end
    end

    if (not self.enabled) or (not anyShort and not anyArts) then
        if self.focusTarget and self._nearbyFocusSpots then
            local pCoordF = getPlayerCoordGrid()
            local focusList = {}
            appendFocusOnlySpots(focusList, pCoordF)
            updateExcavateStateAndSort(self, focusList)
            self.activeSpots = focusList
        else
            self.activeSpots = {}
        end
        self._lastScanCoord = nil
        return
    end

    local pCoord = getPlayerCoordGrid()
    if not pCoord then
        if #self.activeSpots > 0 then
            local kept = {}
            for _, spot in ipairs(self.activeSpots) do
                if updateSpotDisplayItems(spot, deficits, spotArtsMap, self.tracker, self.focusTarget) then
                    table.insert(kept, spot)
                end
            end
            updateExcavateStateAndSort(self, kept)
            self.activeSpots = kept
        end
        return
    end

    local withinScanRadius = (not force)
        and self._lastScanCoord
        and (pCoord.level == nil or pCoord.level == self._lastScanCoord.level)
        and computeDistSq(pCoord, self._lastScanCoord) < 36
        and (self._fullScanSkipCount or 0) < 8
        and self._lastDeficitCount == deficitCount
        and self._lastNeededArtCount == neededArtCount
        and (trackerSeq == nil or self._lastScanRecalcSeq == trackerSeq)

    if withinScanRadius then
        self._fullScanSkipCount = (self._fullScanSkipCount or 0) + 1
        local spotDespawned = false
        if #self.activeSpots > 0 then
            local kept = {}
            for _, spot in ipairs(self.activeSpots) do
                if updateSpotDisplayItems(spot, deficits, spotArtsMap, self.tracker, self.focusTarget) then
                    spot.distSq = computeDistSq(spot.coordGrid, pCoord)
                    table.insert(kept, spot)
                else
                    spotDespawned = true
                end
            end
            appendFocusOnlySpots(kept, pCoord)
            updateExcavateStateAndSort(self, kept)
            self.activeSpots = kept
        end
        if not spotDespawned then
            return
        end
    end

    self._fullScanSkipCount  = 0
    self._lastScanCoord      = { x = pCoord.x, z = pCoord.z, level = pCoord.level }
    self._lastDeficitCount   = deficitCount
    self._lastNeededArtCount = neededArtCount
    self._lastScanRecalcSeq  = trackerSeq

    local locs = queryNearbyLocations(pCoord)
    if not locs then
        self.activeSpots = {}
        return
    end

    local px, pz            = pCoord.x, pCoord.z
    local matched           = {}
    local seenCoords        = {}

    iterateEntities(locs, function(loc)
        if not isEntityAlive(loc) then return end
        local okC, cg = pcall(getEntityCoordGrid, loc)
        if not okC or not cg then return end
        local lx, lz = cg.x, cg.z
        if not lx or not lz then return end
        if px and pz and (math.abs(lx - px) > 32 or math.abs(lz - pz) > 32) then
            return
        end

        local coordKey = lx * 65536 + lz
        if seenCoords[coordKey] then return end

        local okN, rawName = pcall(getEntityDisplayName, loc)
        local spotClass = (okN and rawName and rawName ~= "") and classifyRawSpotName(rawName) or false

        local canExcavate, locTier, locSig = isExcavatableLoc(loc)
        if not canExcavate then return end

        if not spotClass then
            spotClass = classifyFromConfigSig(locSig)
            if not spotClass then return end
        end

        if spotClass.isCache then
            local def = deficits[spotClass.cacheMatLower]
            if def then
                seenCoords[coordKey] = true
                local spotKey = "cache:" .. def.name
                if bestTierBySpotKey[spotKey] == nil or locTier > bestTierBySpotKey[spotKey] then
                    bestTierBySpotKey[spotKey] = locTier
                end
                table.insert(matched, {
                    entity        = loc,
                    coordGrid     = cg,
                    distSq        = computeDistSq(cg, pCoord),
                    displayName   = def.name,
                    spotKey       = spotKey,
                    tier          = locTier,
                    isCache       = true,
                    hasArtefacts  = false,
                    totalPossible = 1,
                    materials     = { def },
                })
            end
            return
        end

        local hotspotDef  = spotClass.hotspotDef
        local matchedName = spotClass.matchedName
        local clean       = spotClass.clean

        local neededMats = {}
        for _, matName in ipairs(hotspotDef.materials or {}) do
            local def = deficits[string.lower(matName)]
            if def then table.insert(neededMats, def) end
        end

        local neededArts = {}
        local hKey       = string.lower(matchedName or clean)
        local spotArts   = spotArtsMap[hKey]
            or spotArtsMap[Hotspots.normalizeKey(matchedName or clean)]
            or (hotspotDef.name and (spotArtsMap[string.lower(hotspotDef.name)] or spotArtsMap[Hotspots.normalizeKey(hotspotDef.name)]))
        if spotArts and self.tracker and self.tracker.getArtefactNeededCount then
            for _, art in ipairs(spotArts) do
                local neededQty = self.tracker:getArtefactNeededCount(art.damagedName, art.name)
                if neededQty > 0 then
                    table.insert(neededArts, {
                        isArtefact = true,
                        name       = art.name,
                        id         = art.restoredId or art.id,
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

            local spotDisplayName = matchedName or clean
            local spotKey = "spot:" .. Hotspots.normalizeKey(spotDisplayName)
            if bestTierBySpotKey[spotKey] == nil or locTier > bestTierBySpotKey[spotKey] then
                bestTierBySpotKey[spotKey] = locTier
            end

            table.insert(matched, {
                entity        = loc,
                coordGrid     = cg,
                distSq        = computeDistSq(cg, pCoord),
                displayName   = spotDisplayName,
                spotKey       = spotKey,
                tier          = locTier,
                isCache       = false,
                hotspotDef    = hotspotDef,
                hasArtefacts  = (#neededArts > 0),
                totalPossible = (#(hotspotDef.materials or {}) > 0) and #hotspotDef.materials or 1,
                materials     = displayItems,
            })
        end
    end)

    if #matched > 0 then
        local filtered = {}
        for _, spot in ipairs(matched) do
            local bestTier = bestTierBySpotKey[spot.spotKey]
            if bestTier == nil or spot.tier >= (bestTier - 20) then
                table.insert(filtered, spot)
            end
        end
        matched = filtered
    end

    appendFocusOnlySpots(matched, pCoord)
    updateExcavateStateAndSort(self, matched)
    self.activeSpots = matched
end

local function makeCoordGridUserdata(c)
    if not c or type(c) ~= "table" then return c end
    if CoordGrid and CoordGrid.new and c.x and c.z then
        local ok, cg = pcall(CoordGrid.new, c.level or 0, math.floor(c.x / 64), math.floor(c.z / 64), c.x % 64, c.z % 64)
        if ok and cg then return cg end
    end
    return nil
end

local function projectVerifiedWorldPoint(entity, coordTableOrUd, height)
    local cg = (type(coordTableOrUd) == "table") and makeCoordGridUserdata(coordTableOrUd) or coordTableOrUd
    local pt = projectToScreen(entity, cg, height or 0)
    if not pt or not pt.x or not pt.y then return nil end
    if pt.x ~= pt.x or pt.y ~= pt.y then return nil end
    -- Front-of-camera check: raising world height must move screen Y upward (smaller Y)
    if cg and ScreenConvert and ScreenConvert.CoordGridToScreen then
        local okUp, up = pcall(ScreenConvert.CoordGridToScreen, cg, (height or 0) + 512)
        if okUp and up and up.y and up.y >= pt.y then
            return nil
        end
    end
    return pt
end

local function computeScreenDirection(pCoord, targetCoord)
    local dxW = targetCoord.x - pCoord.x
    local dzW = targetCoord.z - pCoord.z
    local lenW = math.sqrt(dxW * dxW + dzW * dzW)
    if lenW < 0.01 then return nil, nil end
    local ux, uz = dxW / lenW, dzW / lenW

    -- 1. Nearby tile tangent (4 tiles ahead, strictly inside loaded 32-tile scene)
    local p0 = projectVerifiedWorldPoint(nil, pCoord, 0)
    if p0 then
        local nx = math.floor(pCoord.x + ux * 4 + 0.5)
        local nz = math.floor(pCoord.z + uz * 4 + 0.5)
        if nx ~= pCoord.x or nz ~= pCoord.z then
            local p1 = projectVerifiedWorldPoint(nil, { level = pCoord.level or 0, x = nx, z = nz }, 0)
            if p1 then
                local sx, sy = p1.x - p0.x, p1.y - p0.y
                local sl = math.sqrt(sx * sx + sy * sy)
                if sl > 0.5 then return sx / sl, sy / sl end
            end
        end
    end

    -- 2. Camera basis vector fallback (Quest Helper farTargetEdge math)
    if Camera and Camera.GetPosition and Camera.GetFocusPosition then
        local okCam, sx, sy = pcall(function()
            local cam = Camera.GetPosition()
            local foc = Camera.GetFocusPosition()
            if not cam or not foc then return nil, nil end
            local fx, fz = foc.x - cam.x, foc.z - cam.z
            local horiz = math.sqrt(fx * fx + fz * fz)
            if horiz < 1e-6 then return nil, nil end
            fx, fz = fx / horiz, fz / horiz
            local rx, rz = fz, -fx
            local right = dxW * rx + dzW * rz
            local fwd   = dxW * fx + dzW * fz
            local drop  = math.abs((cam.y or 0) - (foc.y or 0))
            local sinPitch = math.max(0.25, drop / math.sqrt(drop * drop + horiz * horiz))
            return right, -fwd * sinPitch
        end)
        if okCam and sx and sy then
            local sl = math.sqrt(sx * sx + sy * sy)
            if sl > 1e-4 then return sx / sl, sy / sl end
        end
    end

    return nil, nil
end

local function ensureFocusLine(self)
    if self.focusLine then return self.focusLine end
    local segs = {}
    for i = 1, LINE_SEGMENTS do
        local edge = ui.Rectangle.new(self.overlayRoot)
        edge.colour = COL_ROUTE_EDGE
        edge.fill = true
        edge.clickthrough = true
        edge:SetSize(7, 7)
        edge.hidden = true

        local core = ui.Rectangle.new(self.overlayRoot)
        core.colour = COL_ROUTE_LINE
        core.fill = true
        core.clickthrough = true
        core:SetSize(5, 5)
        core.hidden = true

        segs[i] = { edge = edge, core = core }
    end

    local tDark = ui.Rectangle.new(self.overlayRoot)
    tDark.colour = COL_ROUTE_EDGE
    tDark.fill = true
    tDark.clickthrough = true
    tDark:SetSize(13, 13)
    tDark.hidden = true

    local tOut = ui.Rectangle.new(self.overlayRoot)
    tOut.colour = COL_ROUTE_LINE
    tOut.fill = true
    tOut.clickthrough = true
    tOut:SetSize(9, 9)
    tOut.hidden = true

    local tIn = ui.Rectangle.new(self.overlayRoot)
    tIn.colour = COL_BG_PILL
    tIn.fill = true
    tIn.clickthrough = true
    tIn:SetSize(5, 5)
    tIn.hidden = true

    self.focusLine = { segs = segs, tDark = tDark, tOut = tOut, tIn = tIn }
    return self.focusLine
end

local function hideFocusLine(self)
    local fl = self.focusLine
    if not fl then return end
    for _, s in ipairs(fl.segs) do
        if not s.edge.hidden then s.edge.hidden = true end
        if not s.core.hidden then s.core.hidden = true end
    end
    if not fl.tDark.hidden then fl.tDark.hidden = true end
    if not fl.tOut.hidden then fl.tOut.hidden = true end
    if not fl.tIn.hidden then fl.tIn.hidden = true end
end

local function ensureFocusArrow(self)
    if self.focusArrow then return self.focusArrow end
    local pts = {}
    for i = 1, ARROW_PIXELS do
        local edge = ui.Rectangle.new(self.overlayRoot)
        edge.colour = COL_ROUTE_EDGE
        edge.fill = true
        edge.clickthrough = true
        edge:SetSize(7, 7)
        edge.hidden = true
        pts[i] = { edge = edge }
    end
    for i = 1, ARROW_PIXELS do
        local core = ui.Rectangle.new(self.overlayRoot)
        core.colour = COL_ROUTE_LINE
        core.fill = true
        core.clickthrough = true
        core:SetSize(5, 5)
        core.hidden = true
        pts[i].core = core
    end

    local lblBg = ui.Rectangle.new(self.overlayRoot)
    lblBg.colour = COL_BG_PILL
    lblBg.fill = true
    lblBg.clickthrough = true
    lblBg:SetSize(74, 20)
    lblBg.hidden = true

    local lbl = ui.Text.new(self.overlayRoot)
    lbl.font = self.fontQ
    lbl.colour = COL_CYAN
    lbl.maxLines = 1
    lbl.clickthrough = true
    lbl:SetSize(84, 18)
    lbl.hidden = true

    self.focusArrow = { pts = pts, lblBg = lblBg, lbl = lbl, lastDistStr = nil }
    return self.focusArrow
end

local function hideFocusArrow(self)
    local fa = self.focusArrow
    if not fa then return end
    for _, p in ipairs(fa.pts) do
        if p.edge and not p.edge.hidden then p.edge.hidden = true end
        if p.core and not p.core.hidden then p.core.hidden = true end
    end
    if fa.lblBg and not fa.lblBg.hidden then fa.lblBg.hidden = true end
    if fa.lbl and not fa.lbl.hidden then fa.lbl.hidden = true end
end

function Overlay:ensureFocusWidgetsBuilt()
    if not self.mounted and not self:tryMount() then return false end
    ensureFocusLine(self)
    ensureFocusArrow(self)
    return true
end

function Overlay:hideFocusWidgets()
    hideFocusLine(self)
    hideFocusArrow(self)
end

function Overlay:getGuidanceSnapshot()
    if not self.focusTarget then
        return nil, nil, CLOSE_OVERHEAD_RADIUS
    end
    local pCoord = getPlayerCoordGrid()
    local step = self._currentGuidanceStep
    if not step and pCoord and pCoord.x and pCoord.z then
        local learned = NavMemory.getSpotsForKeys(self.focusTarget.focusKeys)
        step = Locations.resolveGuidanceStep(self.focusTarget, pCoord, learned)
        self._currentGuidanceStep = step
    end
    local chebDist = nil
    local tc = step and step.targetCoord
    if pCoord and pCoord.x and pCoord.z and tc and tc.x and tc.z then
        chebDist = math.max(math.abs(tc.x - pCoord.x), math.abs(tc.z - pCoord.z))
    end
    return step, chebDist, CLOSE_OVERHEAD_RADIUS
end

local COS_WING = 0.819152 -- cos(35 deg)
local SIN_WING = 0.573576 -- sin(35 deg)

local function drawFocusGuidance(self, parentW, parentH)
    if not self.focusTarget or not self.overlayRoot or not self.focusLine or not self.focusArrow then
        self:hideFocusWidgets()
        return
    end

    local pCoord = getPlayerCoordGrid()
    if not pCoord or not pCoord.x or not pCoord.z then
        self:hideFocusWidgets()
        return
    end

    local step = self._currentGuidanceStep
    if not step then
        local learned = NavMemory.getSpotsForKeys(self.focusTarget.focusKeys)
        step = Locations.resolveGuidanceStep(self.focusTarget, pCoord, learned)
        self._currentGuidanceStep = step
    end
    if not step then
        self:hideFocusWidgets()
        return
    end

    local stage       = step.stage
    local targetCoord = step.targetCoord
    local targetEnt   = step.targetEntity
    local chebDist    = nil
    if targetCoord and targetCoord.x and targetCoord.z then
        chebDist = math.max(math.abs(targetCoord.x - pCoord.x), math.abs(targetCoord.z - pCoord.z))
    end

    -- Tier 1: Right next to the final spot (<= 5 tiles) -> Overheads ONLY (no 3D line/arrow)!
    if stage == "onsite" and chebDist and chebDist <= CLOSE_OVERHEAD_RADIUS then
        self:hideFocusWidgets()
        return
    end

    -- Off-site stage: LocateWindow + item/UI highlights only (no cross-world arrow/line)
    if stage == "offsite" or not targetCoord or not chebDist or chebDist <= 1 then
        hideFocusLine(self)
        hideFocusArrow(self)
        return
    end

    local pPos = projectVerifiedWorldPoint(nil, pCoord, 0)
    local px = (pPos and pPos.x) or (parentW * 0.5)
    local py = (pPos and pPos.y) or (parentH * 0.5)

    -- Tier 2: Direct World Line when within loaded range (<= 42 tiles) and target projects cleanly on-screen
    if chebDist <= MAX_LINE_RADIUS and pPos then
        local tPos = projectVerifiedWorldPoint(targetEnt, targetCoord, 40)
        if tPos and tPos.x >= 24 and tPos.x <= (parentW - 24) and tPos.y >= 24 and tPos.y <= (parentH - 24) then
            local dx, dy = tPos.x - px, tPos.y - py
            local sLen = math.sqrt(dx * dx + dy * dy)
            if sLen >= 14 then
                hideFocusArrow(self)
                local fl = ensureFocusLine(self)
                local nSeg = math.max(5, math.min(LINE_SEGMENTS, math.floor(sLen / 11)))
                for i = 1, LINE_SEGMENTS do
                    local seg = fl.segs[i]
                    if i <= nSeg then
                        local t = (i / (nSeg + 1))
                        local sx = math.floor(px + dx * t + 0.5)
                        local sy = math.floor(py + dy * t + 0.5)
                        seg.edge:SetPos(sx - 3, sy - 3)
                        seg.core:SetPos(sx - 2, sy - 2)
                        seg.edge.hidden = false
                        seg.core.hidden = false
                    else
                        if not seg.edge.hidden then seg.edge.hidden = true end
                        if not seg.core.hidden then seg.core.hidden = true end
                    end
                end
                local tx, ty = math.floor(tPos.x + 0.5), math.floor(tPos.y + 0.5)
                fl.tDark:SetPos(tx - 6, ty - 6)
                fl.tOut:SetPos(tx - 4, ty - 4)
                fl.tIn:SetPos(tx - 2, ty - 2)
                fl.tDark.hidden = false
                fl.tOut.hidden  = false
                fl.tIn.hidden   = false
                return
            end
        end
    end

    -- Tier 3: QuestHelper-inspired Directional Arrow when too far (> 42 tiles) or off-screen
    hideFocusLine(self)
    local dirX, dirY = computeScreenDirection(pCoord, targetCoord)
    if not dirX or not dirY then
        hideFocusArrow(self)
        return
    end

    local fa = ensureFocusArrow(self)
    local orbitR = 92
    local ax = math.max(70, math.min(parentW - 70, px + dirX * orbitR))
    local ay = math.max(82, math.min(parentH - 70, py + dirY * orbitR))
    local tipX = ax + dirX * 12
    local tipY = ay + dirY * 12

    local function placeArrowPt(idx, x, y)
        local pt = fa.pts[idx]
        if not pt then return end
        local ix, iy = math.floor(x + 0.5), math.floor(y + 0.5)
        pt.edge:SetPos(ix - 3, iy - 3)
        pt.core:SetPos(ix - 2, iy - 2)
        pt.edge.hidden = false
        pt.core.hidden = false
    end

    -- 1..5: tip + shaft
    for s = 0, 4 do
        placeArrowPt(s + 1, tipX - dirX * (s * 4.5), tipY - dirY * (s * 4.5))
    end
    -- 6..11: left chevron wing; 12..17: right chevron wing
    local lwx = -dirX * COS_WING + dirY * SIN_WING
    local lwy = -dirY * COS_WING - dirX * SIN_WING
    local rwx = -dirX * COS_WING - dirY * SIN_WING
    local rwy = -dirY * COS_WING + dirX * SIN_WING
    for w = 1, 6 do
        local dist = w * 2.7
        placeArrowPt(5 + w, tipX + lwx * dist, tipY + lwy * dist)
        placeArrowPt(11 + w, tipX + rwx * dist, tipY + rwy * dist)
    end

    local distStr = string.format("%d tiles", chebDist)
    if fa.lastDistStr ~= distStr then
        fa.lastDistStr = distStr
        fa.lbl.content = distStr
        local tw = measureTextWidth(distStr, fa.lbl.font, 7.6)
        fa.lblW = math.max(54, tw + 12)
        fa.lblBg:SetSize(fa.lblW, 20)
        fa.lbl:SetSize(fa.lblW, 18)
    end
    local lw = fa.lblW or 68
    local lx = math.floor(ax - lw * 0.5)
    local ly = (dirY > 0.25) and math.floor(tipY + 12) or math.floor(ay + 20)
    lx = math.max(8, math.min(parentW - lw - 8, lx))
    ly = math.max(8, math.min(parentH - 26, ly))
    fa.lblBg:SetPos(lx, ly)
    fa.lbl:SetPos(lx + 6, ly + 2)
    fa.lblBg.hidden = false
    fa.lbl.hidden   = false
end

function Overlay:onDraw()
    local hasFocus = (self.focusTarget ~= nil)
    local showSpots = (self.enabled or hasFocus) and (#self.activeSpots > 0)
    if not showSpots and not hasFocus then
        if self.mounted then self:hideAllWidgets() end
        return
    end
    if not self.mounted and not self:tryMount() then return end
    if not ScreenConvert or not ScreenConvert.CoordGridToScreen then
        self:hideAllWidgets()
        return
    end

    local parentW = (self.parent and self.parent.width and self.parent.width > 0) and self.parent.width or 3840
    local parentH = (self.parent and self.parent.height and self.parent.height > 0) and self.parent.height or 2160

    if not showSpots then
        for _, w in ipairs(self.widgets) do
            if w.root and not w.root.hidden then w.root.hidden = true end
        end
        drawFocusGuidance(self, parentW, parentH)
        return
    end

    local drawCount = math.min(MAX_INDICATORS, #self.activeSpots)
    for i = drawCount + 1, #self.widgets do
        if self.widgets[i] and self.widgets[i].root then
            self.widgets[i].root.hidden = true
        end
    end

    for i = drawCount, 1, -1 do
        local widget = self.widgets[i]
        local spot   = self.activeSpots[i]

        if spot and spot.coordGrid and isEntityAlive(spot.entity) then
            local overheadPos = projectToScreen(spot.entity, spot.coordGrid, 850)
            if overheadPos and overheadPos.x and overheadPos.y then
                local sx, sy = overheadPos.x, overheadPos.y
                if sx >= -100 and sx <= parentW + 100 and sy >= -50 and sy <= parentH + 100 then
                    if not widget then
                        widget = createIndicatorWidget(self.overlayRoot, self.fontQ)
                        self.widgets[i] = widget
                    end
                    local totalPossible = spot.totalPossible or 1
                    local numItems      = math.min(#spot.materials, MAX_SLOTS_PER_INDICATOR)
                    local hasArts       = (spot.hasArtefacts == true)

                    -- Build lightweight key so slot text/layout only updates when spot data changes
                    local firstItem = spot.materials[1]
                    local renderKey = string.format("%s|%d|%d|%d|%s|%s|%s",
                        tostring(spot.coordGrid.x or 0) .. "_" .. tostring(spot.coordGrid.z or 0),
                        numItems,
                        firstItem and (firstItem.short or 0) or 0,
                        firstItem and (firstItem.id or 0) or 0,
                        tostring(firstItem and firstItem.isFocusOnly == true),
                        tostring(hasArts),
                        tostring(totalPossible)
                    )

                    local pillW = widget.lastPillW or 105
                    local pillH = widget.lastPillH or 28
                    local sizeChanged = false

                    if widget.lastRenderKey ~= renderKey or widget.lastSpotRef ~= spot then
                        widget.lastRenderKey = renderKey
                        widget.lastSpotRef   = spot

                        local pct      = math.floor((100 / totalPossible) + 0.5)
                        local maxTextW = 60
                        pillH = math.max(28, (numItems * ROW_H) + 6)

                        for s = 1, MAX_SLOTS_PER_INDICATOR do
                            local slot = widget.slots[s]
                            local item = spot.materials[s]

                            if item then
                                local str
                                if item.isFocusOnly then
                                    str = tostring(item.name)
                                    slot.text.colour = item.isArtefact and COL_CYAN or COL_GOLD
                                elseif item.isArtefact then
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

                        pillW = math.max(105, math.min(240, maxTextW + 36))
                        for s = 1, numItems do
                            widget.slots[s].text:SetSize(pillW - 32, 18)
                        end

                        sizeChanged = (widget.lastPillW ~= pillW or widget.lastPillH ~= pillH)
                        if sizeChanged then
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
                    end

                    local pillX = sx - (pillW / 2)
                    local pillY = sy - pillH - 44
                    if pillX ~= widget.lastPillX or pillY ~= widget.lastPillY or sizeChanged or widget.root.hidden then
                        widget.lastPillX = pillX
                        widget.lastPillY = pillY
                        local centerX = pillX + (pillW / 2)
                        local topY    = pillY + pillH

                        widget.pill:SetPos(pillX, pillY)
                        widget.pinP1:SetPos(centerX - 6, topY)
                        widget.pinP2:SetPos(centerX - 4, topY + 2)
                        widget.pinP3:SetPos(centerX - 2, topY + 4)
                        widget.pinP4:SetPos(centerX - 1, topY + 6)
                    end

                    widget.root.hidden = false
                    local shouldFront = (spot.isExcavating == true) or (i == 1)
                    if shouldFront and not widget.lastFront then
                        pcall(function() widget.root:MoveToFront() end)
                    end
                    widget.lastFront = shouldFront
                elseif widget and widget.root then
                    widget.root.hidden = true
                end
            elseif widget and widget.root then
                widget.root.hidden = true
            end
        elseif widget and widget.root then
            widget.root.hidden = true
        end
    end

    drawFocusGuidance(self, parentW, parentH)
end

function Overlay:hideAllWidgets()
    for _, w in ipairs(self.widgets) do
        if w.root and not w.root.hidden then
            w.root.hidden = true
        end
    end
    self:hideFocusWidgets()
end

function Overlay:toggleEnabled()
    self.enabled = not self.enabled
    DB.set("arch_spots_enabled", self.enabled and 1 or 0)
    if not self.enabled then
        for _, w in ipairs(self.widgets) do
            if w.root and not w.root.hidden then w.root.hidden = true end
        end
        self.activeSpots = {}
        if self.focusTarget then
            self:scanWorldSpots(true)
        end
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
    if self.itemHighlight then
        pcall(function() self.itemHighlight:destroy() end)
        self.itemHighlight = nil
    end
    self.focusBanner = nil
    self.focusLine   = nil
    self.focusArrow  = nil
    if self.overlayRoot then
        pcall(function()
            self.overlayRoot.hidden = true
            if self.overlayRoot.Destroy then
                self.overlayRoot:Destroy()
            end
        end)
        self.overlayRoot = nil
    end
    self.widgets = {}
    self.mounted = false
end

return Overlay
