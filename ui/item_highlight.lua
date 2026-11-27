-- ui/item_highlight.lua
-- Highlights travel items in Backpack (TOPLEVEL_V2_INVENTORY), Dig Sites on the Archaeological
-- Dig Sites map (interface 667:11), and matching teleport options in choice dialogs.
-- Uses a strict two-phase (collect -> apply) pass so C++ component vectors are NEVER mutated
-- while IterateDynamicComponents / IterateStaticComponents is actively iterating.

local Theme = require("ui/theme")

local ItemHighlight = {}
ItemHighlight.__index = ItemHighlight

local CREATE_CAP     = 48
local MAX_COMPS      = 600
local MAX_STATIC     = 200
local MAX_DEPTH      = 7

local COL_FILL    = Theme.makeColour(0.0, 1.0, 0.95, 0.30)
local COL_EDGE    = Theme.makeColour(0.0, 1.0, 0.95, 1.0)

function ItemHighlight.new()
    local self = setmetatable({}, ItemHighlight)
    self.byKey         = {}
    self.activeInvKeys = {}
    self.ownLayers     = setmetatable({}, { __mode = "k" })
    self.created       = 0
    self.wanted        = {}
    self.wantedCount   = 0
    self.itemIfaceIds  = nil
    self.choiceSetup   = nil
    self.mapHost       = nil
    self.mapLayer      = nil
    self.mapBoxes      = nil
    return self
end

local function readContainerWantedIds(invName, patterns, out)
    if not config or not config.Inv or not Inventory or not Inventory.Find then return end
    local okRef, ref = pcall(function() return config.Inv[invName] end)
    if not okRef or not ref then return end
    local okInv, inv = pcall(Inventory.Find, ref)
    if not okInv or not inv then return end
    local okSlots, slots = pcall(function() return inv:GetSlots() end)
    if not okSlots or not slots then return end
    pcall(function()
        for _, slot in pairs(slots) do
            local obj = slot and slot.obj
            local cnt = slot and slot.count
            if obj and cnt and cnt > 0 then
                local name = obj.name
                local oid = obj.id
                if type(name) == "string" and type(oid) == "number" then
                    local lower = string.lower(name)
                    for _, p in ipairs(patterns) do
                        if string.find(lower, p, 1, true) then
                            out[oid] = true
                            break
                        end
                    end
                end
            end
        end
    end)
end

function ItemHighlight:refreshWanted(patterns)
    local wanted = {}
    if patterns and #patterns > 0 then
        readContainerWantedIds("INV", patterns, wanted)
        readContainerWantedIds("WORN", patterns, wanted)
    end
    local n = 0
    for _ in pairs(wanted) do n = n + 1 end
    self.wanted = wanted
    self.wantedCount = n
end

local function hostKey(h)
    return tostring(h.interfaceID) .. ":" .. tostring(h.staticID) .. ":" .. tostring(h.categoryID) .. ":" .. tostring(h.dynamicID)
end

local function isLive(rec)
    local ok, alive = pcall(function()
        local host
        if rec.hostCategoryId == nil or rec.hostCategoryId < 0 then
            host = ui.Interfaces:GetComponent(rec.interfaceId, rec.hostStaticId)
        else
            host = ui.Interfaces:GetComponent(rec.interfaceId, rec.hostStaticId, rec.hostCategoryId, rec.hostDynamicId)
        end
        if host ~= rec.host or not host or not host.IterateDynamicComponents then return false end
        local found = false
        host:IterateDynamicComponents(function(child)
            if child == rec.layer then found = true end
            return found
        end)
        return found
    end)
    return ok and alive == true
end

function ItemHighlight:prune()
    local dead = nil
    for key, rec in pairs(self.byKey) do
        if not isLive(rec) then
            dead = dead or {}
            dead[#dead + 1] = key
        end
    end
    if dead then
        for _, key in ipairs(dead) do
            self.byKey[key] = nil
            self.created = math.max(0, self.created - 1)
        end
    end
end

-- 5-rect bordered highlight box used only on Dig Sites map (1-2 buttons).
local function createBoxOnLayer(parentLayer)
    local fill = ui.Rectangle.new(parentLayer)
    fill.fill = true
    fill.colour = COL_FILL
    fill.clickthrough = true

    local top = ui.Rectangle.new(parentLayer)
    top.fill = true
    top.colour = COL_EDGE
    top.clickthrough = true

    local bot = ui.Rectangle.new(parentLayer)
    bot.fill = true
    bot.colour = COL_EDGE
    bot.clickthrough = true

    local left = ui.Rectangle.new(parentLayer)
    left.fill = true
    left.colour = COL_EDGE
    left.clickthrough = true

    local right = ui.Rectangle.new(parentLayer)
    right.fill = true
    right.colour = COL_EDGE
    right.clickthrough = true

    return {
        fill = fill, top = top, bot = bot, left = left, right = right,
    }
end

local function layoutBox(box, x, y, w, h)
    local bw = math.max(8, w)
    local bh = math.max(8, h)
    box.fill:SetPos(x, y)
    box.fill:SetSize(bw, bh)
    box.fill.hidden = false

    box.top:SetPos(x, y)
    box.top:SetSize(bw, 2)
    box.top.hidden = false

    box.bot:SetPos(x, y + bh - 2)
    box.bot:SetSize(bw, 2)
    box.bot.hidden = false

    box.left:SetPos(x, y)
    box.left:SetSize(2, bh)
    box.left.hidden = false

    box.right:SetPos(x + bw - 2, y)
    box.right:SetSize(2, bh)
    box.right.hidden = false
end

local function hideBox(box)
    if not box then return end
    for _, r in pairs(box) do
        if r and not r.hidden then r.hidden = true end
    end
end

function ItemHighlight:ensureHl(host, key, x, y, w, h)
    if not host or not host.IterateDynamicComponents then return nil end
    local hk = hostKey(host)
    local rec = self.byKey[key]
    if rec and rec.hostKey ~= hk then
        if isLive(rec) then pcall(function() rec.layer:Destroy() end) end
        self.byKey[key] = nil
        self.created = math.max(0, self.created - 1)
        rec = nil
    end
    if not rec then
        if self.created >= CREATE_CAP then
            for oldKey, oldRec in pairs(self.byKey) do
                if oldKey ~= key and oldRec.layer and oldRec.layer.hidden then
                    if isLive(oldRec) then pcall(function() oldRec.layer:Destroy() end) end
                    self.byKey[oldKey] = nil
                    self.created = math.max(0, self.created - 1)
                    break
                end
            end
            if self.created >= CREATE_CAP then return nil end
        end
        local ok, built = pcall(function()
            local layer = ui.Layer.new(host)
            if not layer then return nil end
            layer.clickthrough = true

            local fill = ui.Rectangle.new(layer)
            if not fill then
                pcall(function() layer:Destroy() end)
                return nil
            end
            fill.fill = true
            fill.colour = COL_FILL
            fill.clickthrough = true
            fill:SetPos(0, 0, 0, 0)
            fill:SetSize(0, 0, 1.0, 1.0)

            local top = ui.Rectangle.new(layer)
            top.fill = true
            top.colour = COL_EDGE
            top.clickthrough = true
            top:SetPos(0, 0, 0, 0)
            top:SetSize(0, 2, 1.0, 0)

            local bot = ui.Rectangle.new(layer)
            bot.fill = true
            bot.colour = COL_EDGE
            bot.clickthrough = true
            bot:SetPos(0, -2, 0, 1.0)
            bot:SetSize(0, 2, 1.0, 0)

            local left = ui.Rectangle.new(layer)
            left.fill = true
            left.colour = COL_EDGE
            left.clickthrough = true
            left:SetPos(0, 2, 0, 0)
            left:SetSize(2, -4, 0, 1.0)

            local right = ui.Rectangle.new(layer)
            right.fill = true
            right.colour = COL_EDGE
            right.clickthrough = true
            right:SetPos(-2, 2, 1.0, 0)
            right:SetSize(2, -4, 0, 1.0)

            return { layer = layer, fill = fill, top = top, bot = bot, left = left, right = right }
        end)
        if not ok or not built then return nil end
        rec = built
        self.ownLayers[rec.layer] = true
        rec.host           = host
        rec.interfaceId    = host.interfaceID
        rec.hostStaticId   = host.staticID
        rec.hostCategoryId = host.categoryID
        rec.hostDynamicId  = host.dynamicID
        rec.hostKey        = hk
        self.byKey[key] = rec
        self.created = self.created + 1
        pcall(function() rec.layer:MoveToFront() end)
    end
    x, y = x or 0, y or 0
    w, h = math.max(12, w or 36), math.max(12, h or 32)
    if rec.x ~= x or rec.y ~= y or rec.w ~= w or rec.h ~= h then
        rec.x, rec.y, rec.w, rec.h = x, y, w, h
        pcall(function()
            rec.layer:SetPos(x, y)
            rec.layer:SetSize(w, h)
        end)
    end
    return rec
end

local function isAncestorsVisible(comp)
    local cur = comp
    local guard = 0
    while cur and guard < 12 do
        if cur.hidden == true or cur.visible == false then return false end
        cur = cur.parent
        guard = guard + 1
    end
    return true
end

-- Read-only walk: NEVER creates or destroys components inside `visit`.
local function walkInterfaceReadOnly(ifaceId, visit, opts, ownLayers)
    local okI, iface = pcall(function() return ui.Interfaces:GetInterface(ifaceId) end)
    if not okI or not iface then return end
    local maxComps  = (opts and opts.maxComps) or MAX_COMPS
    local maxStatic = (opts and opts.maxStatic) or MAX_STATIC
    local maxDepth  = (opts and opts.maxDepth) or MAX_DEPTH
    local budget = { n = maxComps, seen = {} }
    local function keyOf(node)
        if node.staticID == nil then return tostring(node) end
        return tostring(node.interfaceID or 0) .. ":" .. tostring(node.staticID) .. ":" .. tostring(node.categoryID or 0) .. ":" .. tostring(node.dynamicID or -1)
    end
    local function recurse(node, depth)
        if not node or depth > maxDepth or budget.n <= 0 or not node.IterateDynamicComponents then return end
        for _, method in ipairs({ "IterateDynamicComponents", "IterateStaticComponents" }) do
            local fn = node[method]
            if fn then
                fn(node, function(child)
                    if budget.n <= 0 then return true end
                    if ownLayers and ownLayers[child] then return false end
                    local k = keyOf(child)
                    if budget.seen[k] then
                        if budget.seen[k] == "root" then
                            budget.seen[k] = true
                            visit(child, node)
                        end
                        return false
                    end
                    budget.seen[k] = true
                    budget.n = budget.n - 1
                    visit(child, node)
                    recurse(child, depth + 1)
                    return budget.n <= 0
                end)
            end
        end
    end
    for sid = 0, maxStatic do
        if budget.n <= 0 then break end
        local comp = iface:GetComponent(sid)
        if comp ~= nil and not (ownLayers and ownLayers[comp]) then
            local k = keyOf(comp)
            if not budget.seen[k] then
                budget.seen[k] = "root"
                budget.n = budget.n - 1
                visit(comp, nil)
                recurse(comp, 1)
            end
        end
    end
end

local function cleanUiText(s)
    if type(s) ~= "string" or s == "" then return "" end
    s = string.gsub(s, "<[^>]*>", " ")
    s = string.gsub(s, "\226\128\153", "")
    s = string.gsub(s, "'", "")
    s = string.gsub(s, "[^%w]+", " ")
    s = string.gsub(s, "%s+", " ")
    return string.lower((string.match(s, "^%s*(.-)%s*$") or s))
end

local HEADER_PHRASES = {
    "choose an option",
    "select an option",
    "select a destination",
    "choose a destination",
    "where would you like",
    "what would you like",
    "archaeology teleport",
}

local function isDialogHeader(cleanTxt)
    if cleanTxt == "" then return true end
    for _, hp in ipairs(HEADER_PHRASES) do
        if cleanTxt == hp or string.sub(cleanTxt, 1, #hp) == hp then
            return true
        end
    end
    return false
end

-- Returns the lowest (highest-priority) index in `paddedTerms` matching `content` on whole-word boundaries, or nil.
local function matchTermRank(content, paddedTerms)
    if type(content) ~= "string" or content == "" or #content > 140 then return nil end
    local txt = cleanUiText(content)
    if txt == "" or isDialogHeader(txt) then return nil end
    local padded = " " .. txt .. " "
    for idx, pTerm in ipairs(paddedTerms) do
        if string.find(padded, pTerm, 1, true) then
            return idx
        end
    end
    return nil
end

--- Highlights matching dig site buttons on interface 667:11.
function ItemHighlight:updateDigsiteMap(dynMap)
    if not dynMap or not next(dynMap) or not ui or not ui.Interfaces or not ui.Interfaces.GetComponent then
        self:hideDigsiteMap()
        return
    end
    local okH, host = pcall(ui.Interfaces.GetComponent, ui.Interfaces, 667, 11)
    if not okH or not host or host.hidden or not host.IterateDynamicComponents then
        self.mapHost = nil
        self.mapLayer = nil
        self.mapBoxes = nil
        return
    end

    -- Phase 1: Read-only collect
    local targets = {}
    local layerAlive = false
    pcall(function()
        host:IterateDynamicComponents(function(child)
            if child == self.mapLayer then
                layerAlive = true
            else
                local did = child and child.dynamicID
                if did ~= nil and dynMap[did] and not child.hidden then
                    targets[#targets + 1] = {
                        x = child.x or 0,
                        y = child.y or 0,
                        w = child.width or 40,
                        h = child.height or 40,
                    }
                end
            end
            return false
        end)
    end)

    if #targets == 0 then
        self:hideDigsiteMap()
        return
    end

    -- Phase 2: Apply outside iteration
    if self.mapHost ~= host or not layerAlive or not self.mapLayer then
        if self.mapLayer and layerAlive then
            pcall(function() self.mapLayer:Destroy() end)
        end
        self.mapHost = nil
        self.mapLayer = nil
        self.mapBoxes = nil
        local okL, layer = pcall(function()
            local l = ui.Layer.new(host)
            if not l then return nil end
            l.clickthrough = true
            l:SetPos(0, 0)
            l:SetSize(0, 0, 1.0, 1.0)
            if l.MoveToFront then l:MoveToFront() end
            return l
        end)
        if not okL or not layer then
            self:hideDigsiteMap()
            return
        end
        self.ownLayers[layer] = true
        self.mapHost = host
        self.mapLayer = layer
        self.mapBoxes = {}
    end

    self.mapBoxes = self.mapBoxes or {}
    local used = 0
    for _, t in ipairs(targets) do
        used = used + 1
        local box = self.mapBoxes[used]
        if not box then
            local okB, created = pcall(createBoxOnLayer, self.mapLayer)
            if okB and created then
                box = created
                self.mapBoxes[used] = box
            end
        end
        if box then
            pcall(layoutBox, box, t.x - 3, t.y - 3, t.w + 6, t.h + 6)
        end
    end
    if self.mapLayer and self.mapLayer.MoveToFront then
        pcall(function() self.mapLayer:MoveToFront() end)
    end
    for i = used + 1, #self.mapBoxes do
        hideBox(self.mapBoxes[i])
    end
end

function ItemHighlight:hideDigsiteMap()
    if self.mapBoxes then
        for _, box in ipairs(self.mapBoxes) do
            hideBox(box)
        end
    end
end

local function ensureChoiceSetup(self)
    if self.choiceSetup then return self.choiceSetup end
    local setup = { directComps = {}, modalIfaces = {} }
    pcall(function()
        if id and id.Interface then
            if type(id.Interface.MODAL_CHOICE) == "number" then
                setup.modalIfaces[1] = id.Interface.MODAL_CHOICE
            end
            if type(id.Interface.CHOICE_V2) == "number" and id.Component then
                local list = {}
                for i = 1, 5 do
                    local cid = id.Component["CHOICE_V2__OPTION_TEXT_" .. i]
                    if type(cid) == "number" then list[#list + 1] = cid & 0xFFFF end
                end
                if #list > 0 then setup.directComps[id.Interface.CHOICE_V2] = list end
            end
            if type(id.Interface.CHAT_V3_CHOICE) == "number" and id.Component and type(id.Component.CHAT_V3_CHOICE__CHOICE_BUTTONS_DRAW) == "number" then
                setup.directComps[id.Interface.CHAT_V3_CHOICE] = { id.Component.CHAT_V3_CHOICE__CHOICE_BUTTONS_DRAW & 0xFFFF }
            end
        end
    end)
    self.choiceSetup = setup
    return setup
end

-- Resolves the best highlightable row component & host collection for a matched text component.
local function resolveDialogRowTarget(comp, fallbackHost)
    local cur = comp
    local guard = 0
    while cur and guard < 4 do
        local p = cur.parent
        local h = cur.height or 0
        local w = cur.width or 0
        if p and p.IterateDynamicComponents and h >= 12 and h <= 68 and w >= 40 then
            return p, cur, cur.x or 0, cur.y or 0, w, h
        end
        cur = p
        guard = guard + 1
    end
    local host = (comp.parent and comp.parent.IterateDynamicComponents and comp.parent) or fallbackHost
    if not host or not host.IterateDynamicComponents then return nil end
    local w = (comp.width and comp.width >= 40) and comp.width or math.max(120, (host.width and host.width > 0) and host.width or 160)
    local h = (comp.height and comp.height >= 12) and comp.height or 24
    return host, comp, comp.x or 0, comp.y or 0, w, h
end

-- Purely read-only recursive dynamic collection walk (matches Quest Helper's _scanComponentCollection).
local function scanDynamicCollectionReadOnly(rootComp, paddedTerms, outCandidates, budget, ownLayers)
    local seen = {}
    local function keyOf(c)
        if c.staticID == nil then return tostring(c) end
        return tostring(c.interfaceID or 0) .. ":" .. tostring(c.staticID) .. ":" .. tostring(c.categoryID or 0) .. ":" .. tostring(c.dynamicID or -1)
    end
    local function recurse(coll, depth)
        if not coll or depth > 4 or budget.n <= 0 or not coll.IterateDynamicComponents then return end
        coll:IterateDynamicComponents(function(c)
            if budget.n <= 0 then return true end
            if ownLayers and ownLayers[c] then return false end
            local ck = keyOf(c)
            if seen[ck] then return false end
            seen[ck] = true
            budget.n = budget.n - 1
            if c.IterateDynamicComponents then
                recurse(c, depth + 1)
                return budget.n <= 0
            end
            local txt = c.content
            if type(txt) == "string" and txt ~= "" and isAncestorsVisible(c) then
                local rank = matchTermRank(txt, paddedTerms)
                if rank then
                    local host, row, rx, ry, rw, rh = resolveDialogRowTarget(c, coll)
                    if host and row then
                        outCandidates[#outCandidates + 1] = {
                            rank = rank,
                            host = host,
                            row  = row,
                            x    = rx,
                            y    = ry,
                            w    = rw,
                            h    = rh,
                        }
                    end
                end
            end
            return budget.n <= 0
        end)
    end
    recurse(rootComp, 1)
end

local function ensureItemInterfaceIds(self)
    if self.itemIfaceIds then return self.itemIfaceIds end
    local list = {}
    local seen = {}
    local function addId(v)
        if type(v) == "number" and v > 0 and not seen[v] then
            seen[v] = true
            list[#list + 1] = v
        end
    end
    pcall(function()
        if id and id.Interface then
            addId(id.Interface.TOPLEVEL_V2_INVENTORY)
            for _, k in ipairs({ "TOPLEVEL_V2_EQUIPMENT", "WORN_EQUIPMENT", "EQUIPMENT" }) do
                local ok, val = pcall(function() return id.Interface[k] end)
                if ok then addId(val) end
            end
        end
    end)
    addId(1473) -- RS3 Backpack (TOPLEVEL_V2_INVENTORY)
    addId(1464) -- RS3 Worn Equipment panel (Pocket, Head, Ring, Neck slots)
    self.itemIfaceIds = list
    return list
end

function ItemHighlight:update(itemPatterns, dialogTerms, mapDynIds, runInvScan)
    if not ui or not ui.Interfaces then return end
    self:updateDigsiteMap(mapDynIds)
    self:prune()

    local hasItems = itemPatterns and #itemPatterns > 0
    local hasDialog = dialogTerms and #dialogTerms > 0
    if not hasItems then
        self.activeInvKeys = {}
    end
    if not hasItems and not hasDialog then
        self:hideSlots()
        return
    end

    -- Phase 1: Purely read-only collection of matching components
    local pending = {}
    local seenKeys = {}
    local want = {}

    if hasItems then
        if runInvScan then
            self:refreshWanted(itemPatterns)
            local nextInvKeys = {}
            if self.wantedCount > 0 then
                local ifaceIds = ensureItemInterfaceIds(self)
                local wanted = self.wanted
                for _, ifaceId in ipairs(ifaceIds) do
                    pcall(walkInterfaceReadOnly, ifaceId, function(comp, parent)
                        local oid = comp.associatedObjectID
                        if type(oid) ~= "number" or oid < 0 or not wanted[oid] then return end
                        local realParent = parent or comp.parent
                        local host = (realParent and realParent.IterateDynamicComponents and realParent) or comp
                        if not host or not host.IterateDynamicComponents then return end
                        if not isAncestorsVisible(comp) then return end
                        local key = "inv:" .. ifaceId .. ":" .. tostring(comp.staticID) .. ":" .. tostring(comp.categoryID) .. ":" .. tostring(comp.dynamicID)
                        if seenKeys[key] then return end
                        seenKeys[key] = true
                        nextInvKeys[key] = true
                        local cw, ch = comp.width or 0, comp.height or 0
                        local hw, hh = host.width or 0, host.height or 0
                        local w = (cw > 4 and cw) or (hw > 4 and hw <= 64 and hw) or 36
                        local h = (ch > 4 and ch) or (hh > 4 and hh <= 64 and hh) or 32
                        pending[#pending + 1] = {
                            host = host,
                            key  = key,
                            x    = (host ~= comp) and (comp.x or 0) or 0,
                            y    = (host ~= comp) and (comp.y or 0) or 0,
                            w    = w,
                            h    = h,
                        }
                    end, nil, self.ownLayers)
                end
            end
            self.activeInvKeys = nextInvKeys
        else
            -- Preserve ONLY the slots that matched on the most recent inventory scan (never resurrect hidden old slots!)
            for key in pairs(self.activeInvKeys) do
                if self.byKey[key] then
                    want[key] = true
                else
                    self.activeInvKeys[key] = nil
                end
            end
        end
    end

    if hasDialog then
        local paddedTerms = {}
        for _, rawTerm in ipairs(dialogTerms) do
            local ct = cleanUiText(rawTerm)
            if ct ~= "" then paddedTerms[#paddedTerms + 1] = " " .. ct .. " " end
        end

        if #paddedTerms > 0 then
            local setup = ensureChoiceSetup(self)
            local dlgCandidates = {}
            local dynBudget = { n = 120 }

            for ifaceId, compIds in pairs(setup.directComps) do
                for _, compId in ipairs(compIds) do
                    pcall(function()
                        local comp = ui.Interfaces:GetComponent(ifaceId, compId)
                        if not comp or not isAncestorsVisible(comp) then return end
                        if comp.IterateDynamicComponents then
                            scanDynamicCollectionReadOnly(comp, paddedTerms, dlgCandidates, dynBudget, self.ownLayers)
                        else
                            local rank = matchTermRank(comp.content, paddedTerms)
                            if rank then
                                local host, row, rx, ry, rw, rh = resolveDialogRowTarget(comp, comp.parent)
                                if host and row then
                                    dlgCandidates[#dlgCandidates + 1] = {
                                        rank    = rank,
                                        ifaceId = ifaceId,
                                        host    = host,
                                        row     = row,
                                        x       = rx,
                                        y       = ry,
                                        w       = rw,
                                        h       = rh,
                                    }
                                end
                            end
                        end
                    end)
                end
            end

            local modalOpts = { maxStatic = 120, maxComps = 300, maxDepth = 6 }
            for _, mId in ipairs(setup.modalIfaces) do
                pcall(walkInterfaceReadOnly, mId, function(comp, parent)
                    if not parent or not parent.IterateDynamicComponents then return end
                    local c = comp.content
                    if type(c) ~= "string" or c == "" or #c > 140 then return end
                    if not isAncestorsVisible(comp) then return end
                    local rank = matchTermRank(c, paddedTerms)
                    if not rank then return end
                    local host, row, rx, ry, rw, rh = resolveDialogRowTarget(comp, parent)
                    if not host or not row then return end
                    if rh < 10 or rh > 72 or rw < 40 then return end
                    dlgCandidates[#dlgCandidates + 1] = {
                        rank    = rank,
                        ifaceId = mId,
                        host    = host,
                        row     = row,
                        x       = rx,
                        y       = ry,
                        w       = rw,
                        h       = rh,
                    }
                end, modalOpts, self.ownLayers)
            end

            -- Select ONLY the highest-priority (lowest rank) matching option(s) currently visible!
            local bestRank = nil
            for _, cand in ipairs(dlgCandidates) do
                if bestRank == nil or cand.rank < bestRank then
                    bestRank = cand.rank
                end
            end

            if bestRank ~= nil then
                for _, cand in ipairs(dlgCandidates) do
                    if cand.rank == bestRank then
                        local r = cand.row
                        local ifId = cand.ifaceId or r.interfaceID or cand.host.interfaceID or 0
                        local key = "dlg:" .. tostring(ifId) .. ":" .. tostring(r.staticID) .. ":" .. tostring(r.categoryID) .. ":" .. tostring(r.dynamicID)
                        if not seenKeys[key] then
                            seenKeys[key] = true
                            pending[#pending + 1] = {
                                host = cand.host,
                                key  = key,
                                x    = cand.x,
                                y    = cand.y,
                                w    = cand.w,
                                h    = cand.h,
                            }
                        end
                    end
                end
            end
        end
    end

    -- Phase 2: Create/update highlights AFTER all interface iterations have returned
    for _, item in ipairs(pending) do
        local rec = self:ensureHl(item.host, item.key, item.x, item.y, item.w, item.h)
        if rec then
            if rec.layer.hidden then
                rec.layer.hidden = false
                pcall(function() rec.layer:MoveToFront() end)
            end
            want[item.key] = true
        end
    end

    for key, rec in pairs(self.byKey) do
        if not want[key] and rec.layer and not rec.layer.hidden then
            pcall(function() rec.layer.hidden = true end)
        end
    end
end

function ItemHighlight:hideSlots()
    self.activeInvKeys = {}
    self:prune()
    for _, rec in pairs(self.byKey) do
        if rec.layer and not rec.layer.hidden then
            pcall(function() rec.layer.hidden = true end)
        end
    end
end

function ItemHighlight:hideAll()
    self:hideDigsiteMap()
    self:hideSlots()
end

function ItemHighlight:destroy()
    if self.mapLayer and self.mapHost and self.mapHost.IterateDynamicComponents then
        local mapAlive = false
        pcall(function()
            local h = ui and ui.Interfaces and ui.Interfaces.GetComponent and ui.Interfaces:GetComponent(667, 11)
            if h == self.mapHost then
                h:IterateDynamicComponents(function(child)
                    if child == self.mapLayer then
                        mapAlive = true
                        return true
                    end
                    return false
                end)
            end
        end)
        if mapAlive then
            pcall(function()
                self.mapLayer.hidden = true
                self.mapLayer:Destroy()
            end)
        end
    end
    self.mapLayer = nil
    self.mapHost = nil
    self.mapBoxes = nil
    for _, rec in pairs(self.byKey) do
        if isLive(rec) then
            pcall(function() rec.layer:Destroy() end)
        end
    end
    self.byKey = {}
    self.created = 0
end

return ItemHighlight
