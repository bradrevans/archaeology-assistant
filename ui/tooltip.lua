-- ui/tooltip.lua
-- Single-responsibility floating tooltip component and rich tooltip content builders
-- for collections, artefacts, materials, storage/bank sync badges, and collector status.

local Utils = require("core/utils")
local Theme = require("ui/theme")
local Widgets = require("ui/widgets")
local Collections = require("data/collections")

local Tooltip = {}
Tooltip.__index = Tooltip

local MAX_TOOLTIP_LINES = 35

--- Resolves the highlight colour for a single detail line inside the tooltip.
local function getDetailLineColour(text)
    if string.find(text, "Power/Benefit") then
        return Theme.COL_CYAN
    elseif string.find(text, "Weapon") then
        return Theme.COL_GOLD
    elseif string.find(text, "Mystery") then
        return Theme.COL_AMBER
    elseif string.find(text, "Tetracompass") then
        return Theme.COL_CREAM
    elseif string.find(text, ": Handed in") or string.find(text, "Handed in to collector") then
        return Theme.COL_CYAN
    elseif string.find(text, ": Restored") or string.find(text, ": Ready") then
        return Theme.COL_GREEN
    elseif string.find(text, "%- Synced") or string.find(text, "%[✓%]") then
        return Theme.COL_GREEN
    elseif string.find(text, "%- Not synced") or string.find(text, "%[!%]") then
        return Theme.COL_RED
    elseif string.find(text, "COLLECTORS:") or string.find(text, "HOW TO SYNC") then
        return Theme.COL_GOLD
    elseif string.find(text, ": Damaged") then
        return Theme.COL_AMBER
    elseif string.find(text, ": Missing") then
        return Theme.COL_RED
    elseif string.find(text, "Required Artefacts") then
        return Theme.COL_GOLD
    end
    return Theme.COL_CREAM
end

function Tooltip.new(parent, onScrollWheel)
    local self = setmetatable({}, Tooltip)
    self.parent = parent

    local tipRoot = Widgets.createContentFrame(parent, 0, 0, 400, 90, 0, 0, true)
    tipRoot.hidden = true

    local iconSlot = nil
    local Sprites = (prettyui and prettyui.Sprites) or Theme.Sprites
    if Sprites and Sprites.ITEM_SLOT_BACKGROUND then
        iconSlot = ui.Sprite.new(tipRoot)
        iconSlot.spriteID = Sprites.ITEM_SLOT_BACKGROUND
        iconSlot.clickthrough = true
        iconSlot.hidden = true
        iconSlot:SetPos(8, 8)
        iconSlot:SetSize(36, 36)
    end

    local tipIcon = ui.Sprite.new(tipRoot)
    tipIcon.clickthrough = true
    tipIcon.hidden = true
    tipIcon:SetPos(10, 10)
    tipIcon:SetSize(32, 32)

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
        txt:SetPos(10, yPos)
        txt:SetSize(-20, 18, 1.0, 0)
        return txt
    end

    if onScrollWheel and ui and ui.Hook and ui.Hook.ONSCROLLWHEEL then
        tipRoot:Subscribe(ui.Hook.ONSCROLLWHEEL, onScrollWheel)
    end

    self.root = tipRoot
    self.iconSlot = iconSlot
    self.icon = tipIcon
    self.title = makeTipText(Theme.COL_GOLD, 8)
    self.sub = makeTipText(Theme.COL_WHITE, 28)
    self.lines = {}

    for i = 1, MAX_TOOLTIP_LINES do
        local txt = makeTipText(Theme.COL_CREAM, 48)
        txt.hidden = true
        self.lines[i] = txt
    end

    return self
end

function Tooltip:show(windowRoot, isWindowVisible, titleText, subText, detailText, titleCol, objId)
    if not self.root or not isWindowVisible then
        return
    end

    local tipW = 460
    local hasIcon = Theme.bindItemSprite(self.icon, objId, (tonumber(objId) == 995) and 10000 or 1)
    if self.iconSlot then
        self.iconSlot.hidden = not hasIcon
    end

    local textX = hasIcon and 50 or 10
    local availTxtW = tipW - textX - 10
    local hTitle = Theme.measureWrappedTextHeight(titleText, availTxtW)
    local hSub = Theme.measureWrappedTextHeight(subText, availTxtW)

    self.title.colour = titleCol or Theme.COL_GOLD
    self.title.content = titleText
    self.title:SetPos(textX, 8)
    self.title:SetSize(-(textX + 10), hTitle, 1.0, 0)

    local subY = 8 + hTitle + 3
    self.sub.content = subText
    self.sub:SetPos(textX, subY)
    self.sub:SetSize(-(textX + 10), hSub, 1.0, 0)

    local currentY = subY + hSub + 4
    local lines = {}
    if type(detailText) == "table" then
        lines = detailText
    else
        for line in string.gmatch((detailText or "") .. "\n", "(.-)[\r\n]") do
            table.insert(lines, line)
        end
    end

    for i = 1, #self.lines do
        local lineTxt = self.lines[i]
        local entry = lines[i]
        local text = type(entry) == "table" and entry.text or entry
        local explicitCol = type(entry) == "table" and entry.colour or nil
        if text ~= nil and text ~= "" then
            lineTxt.hidden = false
            lineTxt.content = text
            lineTxt.colour = explicitCol or getDetailLineColour(text)

            local hLine = Theme.measureWrappedTextHeight(text, availTxtW)
            lineTxt:SetPos(textX, currentY)
            lineTxt:SetSize(-(textX + 10), hLine, 1.0, 0)
            currentY = currentY + hLine + 2
        elseif text == "" then
            lineTxt.hidden = true
            currentY = currentY + 4
        else
            lineTxt.hidden = true
        end
    end

    local minH = hasIcon and 52 or 40
    local tipH = math.max(minH, currentY + 8)

    local fallbackX = (windowRoot and windowRoot.x or 100) + 120
    local fallbackY = (windowRoot and windowRoot.y or 100) + 120
    local mx, my = Theme.getScaledMousePos(fallbackX, fallbackY)
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

    self.root:SetPos(tx, ty)
    self.root:SetSize(tipW, tipH)
    self.root.hidden = false
    self.root:MoveToFront()
end

function Tooltip:hide()
    if self.root and not self.root.hidden then
        self.root.hidden = true
    end
    if self.iconSlot and not self.iconSlot.hidden then
        self.iconSlot.hidden = true
    end
    if self.icon and not self.icon.hidden then
        self.icon.hidden = true
    end
    if self.lines then
        for _, line in ipairs(self.lines) do
            line.hidden = true
        end
    end
end

function Tooltip:destroy()
    if self.root and self.root.Destroy then
        pcall(function() self.root:Destroy() end)
        self.root = nil
    end
end

-- ============================================================================
-- Domain-Specific Tooltip Builders
-- ============================================================================

function Tooltip.buildSyncBadgeTooltip(tracker, badgeKind)
    local status = tracker:getSyncStatus()
    local mode = tracker:getSourceMode()
    local isStorage = (badgeKind == "storage")

    local s = isStorage and status.storage or status.bank
    local name = isStorage and "Material Storage" or "Bank"
    local iconObjId = isStorage and Theme.STORAGE_ICON_OBJ_ID or Theme.BANK_ICON_OBJ_ID

    local openHint = isStorage
        and "Open Material Storage (at a workbench) or check Material storage information in your Archaeology journal to sync."
        or "Open your Bank to sync."

    local contents = isStorage
        and string.format("%d material types stored.", s.matTypes or 0)
        or string.format("%d material types, %d damaged artefact types.", s.matTypes or 0, s.artTypes or 0)

    if not s.enabled then
        return name .. ": Ignored",
            "Current source mode: " .. mode.label .. ".",
            "Click the Src button to include " .. name .. " in calculations.",
            Theme.COL_MUTED,
            iconObjId
    elseif s.synced then
        return name .. ": Synced",
            "Read live this session. " .. contents,
            "Updates automatically while open. Changes made elsewhere (e.g. another device) need a resync.",
            Theme.COL_GREEN,
            iconObjId
    elseif s.cached then
        return name .. ": Cached",
            "Using data saved from a previous session. " .. contents,
            openHint .. " Counts may be out of date if changed on another device.",
            Theme.COL_AMBER,
            iconObjId
    else
        return name .. ": Not synced",
            "No data yet - " .. name .. " contents are not being counted.",
            openHint,
            Theme.COL_RED,
            iconObjId
    end
end

function Tooltip.buildCollectorsStatusTooltip(tracker)
    local list, syncedCount, totalCount, liveCount = tracker:getCollectorSyncStatuses()
    liveCount = liveCount or 0

    local titleText = string.format("Collector Sync Status (%d / %d)", syncedCount, totalCount)
    local titleCol = (liveCount == totalCount and totalCount > 0) and Theme.COL_GREEN
        or ((syncedCount > 0) and Theme.COL_AMBER or Theme.COL_RED)

    local subText
    if liveCount == totalCount and totalCount > 0 then
        subText = "All collectors synced live this session!"
    elseif syncedCount == totalCount and totalCount > 0 then
        subText = "Using cached collector data from a previous session. Resync via Journal or Noticeboard if changed."
    else
        subText = "Noticeboard or Journal scan needed to track turned-in artefacts for unsynced collectors."
    end

    local lines = { "COLLECTORS:" }
    for _, c in ipairs(list or {}) do
        local col = c.synced and Theme.COL_GREEN or (c.cached and Theme.COL_AMBER or Theme.COL_RED)
        table.insert(lines, {
            text   = "  • " .. tostring(c.name),
            colour = col,
        })
    end

    table.insert(lines, "")
    table.insert(lines, "HOW TO SYNC:")
    table.insert(lines, "• Click the 'Collector Information Noticeboard' at Arch Guild, OR")
    table.insert(lines, "• Right-click Archaeology Journal -> select 'Collector information'.")
    table.insert(lines, "• Click each collector on the list to automatically sync!")

    return titleText, subText, lines, titleCol, Theme.BOARD_ICON_OBJ_ID
end

function Tooltip.buildCollectionRowTooltip(tracker, item)
    local col = item.data
    local prog = item.progress

    local title = string.format("%s (Level %d)", col.name, col.level)
    local statusStr
    if prog.isReady then
        statusStr = string.format("All %d Ready to Turn In!", prog.totalCount)
    else
        local parts = {}
        if (prog.submittedCount or 0) > 0 then
            table.insert(parts, string.format("%d In", prog.submittedCount))
        end
        if (prog.restoredOnlyCount or 0) > 0 then
            table.insert(parts, string.format("%d Restored", prog.restoredOnlyCount))
        end
        if (prog.damagedOnlyCount or 0) > 0 then
            table.insert(parts, string.format("%d Dmg", prog.damagedOnlyCount))
        end
        local missing = (prog.totalCount or 0) - (prog.haveCount or 0)
        if missing > 0 then
            table.insert(parts, string.format("%d Missing", missing))
        end
        statusStr = string.format("%d/%d possessed (%s)", prog.haveCount or 0, prog.totalCount or 0, table.concat(parts, ", "))
    end
    if prog.isCompleted then
        statusStr = statusStr .. " [Completed]"
    end

    local sub = string.format("Collector: %s | %s", col.collector, statusStr)

    local details = {}
    local colLoc = col.location or (Collections and Collections.getCollectorLocation and Collections.getCollectorLocation(col.collector)) or "Archaeology Guild"
    table.insert(details, string.format("Hand-In Location: %s", colLoc))
    table.insert(details, string.format("Collection Status: %s", statusStr))
    table.insert(details, "")

    local isTetra = string.find(string.lower(col.recurringReward or ""), "tetra", 1, true)
        or string.find(string.lower(col.oneTimeReward or ""), "tetra", 1, true)
        or string.find(string.lower(col.specialBenefit or ""), "tetra", 1, true)
    if isTetra then
        table.insert(details, "Tetracompass: Awards a Tetracompass Piece on completion!")
    end
    if col.specialBenefit and col.specialBenefit ~= "" then
        table.insert(details, string.format("Power/Benefit: %s", col.specialBenefit))
    end
    if col.oneTimeReward and col.oneTimeReward ~= "" then
        table.insert(details, string.format("One-Time: %s", col.oneTimeReward))
    end
    if col.recurringReward and col.recurringReward ~= "" then
        table.insert(details, string.format("Recurring: %s", col.recurringReward))
    end
    if col.chronotes and col.chronotes ~= "" then
        table.insert(details, string.format("Chronotes: %s", col.chronotes))
    end

    table.insert(details, "")
    table.insert(details, string.format("Required Artefacts (%d):", prog.totalCount))

    for _, a in ipairs(prog.artefacts or {}) do
        if a.isSubmitted then
            table.insert(details, string.format("  %s: Handed in to collector", a.name))
        elseif a.restoredCount and a.restoredCount > 0 then
            local locStr
            if (a.bagRestored or 0) > 0 and (a.bankRestored or 0) > 0 then
                locStr = string.format("%d in Bag, %d in Bank", a.bagRestored, a.bankRestored)
            elseif (a.bagRestored or 0) > 0 then
                locStr = string.format("%d in Bag", a.bagRestored)
            else
                locStr = string.format("%d in Bank", a.bankRestored or a.restoredCount)
            end
            table.insert(details, string.format("  %s: Restored (%s)", a.name, locStr))
        elseif a.damagedCount and a.damagedCount > 0 then
            local locStr
            if (a.bagDamaged or 0) > 0 and (a.bankDamaged or 0) > 0 then
                locStr = string.format("%d in Bag, %d in Bank", a.bagDamaged, a.bankDamaged)
            elseif (a.bagDamaged or 0) > 0 then
                locStr = string.format("%d in Bag", a.bagDamaged)
            else
                locStr = string.format("%d in Bank", a.bankDamaged or a.damagedCount)
            end
            table.insert(details, string.format("  %s: Damaged (%s)", a.name, locStr))
        else
            table.insert(details, string.format("  %s: Missing", a.name))
        end
    end

    local titleCol = Theme.COL_GOLD
    if col.benefitType == "relic" then
        titleCol = Theme.COL_CYAN
    elseif col.benefitType == "weapon" then
        titleCol = Theme.COL_GOLD
    elseif col.benefitType == "mystery" then
        titleCol = Theme.COL_AMBER
    end

    return title, sub, table.concat(details, "\n"), titleCol, Theme.STORAGE_ICON_OBJ_ID
end

function Tooltip.buildArtefactRowTooltip(tracker, item)
    local art = item.artefact
    local objId = art and art.id
    local title = string.format("%s (Lv %d) | %s XP | %s Chronotes",
        art.name, art.level or 1, Utils.formatInt(art.xp), Utils.formatInt(art.chronotes))
    local locStr = art.location or "Archaeology"
    local ownedDamaged = item.ownedDamaged or ((item.inBag or 0) + (item.inBank or 0))
    local bagRestored = item.bagRestored or (tracker and tracker.backpackRestored and tracker.backpackRestored[art.name]) or 0
    local bankRestored = item.bankRestored or (tracker and tracker.bankRestored and tracker.bankRestored[art.name]) or 0
    local totalRestored = bagRestored + bankRestored
    local statusStr = item.statusText or (item.excluded and "Excluded" or "Ready")

    local ownedBreakdown
    if totalRestored > 0 and ownedDamaged > 0 then
        ownedBreakdown = string.format(
            "Restored: %d (Bag: %d, Bank: %d) | Damaged: %d (Bag: %d, Bank: %d)",
            totalRestored, bagRestored, bankRestored, ownedDamaged, item.inBag or 0, item.inBank or 0
        )
    elseif totalRestored > 0 then
        ownedBreakdown = string.format(
            "Restored: %d (Bag: %d, Bank: %d)",
            totalRestored, bagRestored, bankRestored
        )
    else
        ownedBreakdown = string.format(
            "Damaged: %d (Bag: %d, Bank: %d)",
            ownedDamaged, item.inBag or 0, item.inBank or 0
        )
    end

    local sub = string.format(
        "Status: %s | Location: %s | %s",
        statusStr, locStr, ownedBreakdown
    )
    local reqParts = {}
    local mult = math.max(1, item.effectiveCount > 0 and item.effectiveCount or 1)
    for _, req in ipairs(art.materials or {}) do
        local owned = tracker:getOwnedMaterialCount(req.name)
        local needed = req.count * mult
        table.insert(reqParts, string.format("%s (%s/%s)", req.name, Utils.formatInt(owned), Utils.formatInt(needed)))
    end
    local detail = string.format("Materials (%dx): %s", mult, table.concat(reqParts, ", "))
    if item.colNames and #item.colNames > 0 then
        detail = string.format("Status: %s\nTargeted by: %s\n%s", statusStr, table.concat(item.colNames, ", "), detail)
    else
        detail = string.format("Status: %s\n%s", statusStr, detail)
    end
    return title, sub, detail, Theme.COL_GOLD, objId
end

function Tooltip.buildMaterialRowTooltip(item)
    local mat = item.material
    local objId = mat and mat.id
    local lvlStr = (mat and mat.isArchMaterial == false) and "Secondary" or ("Lv " .. tostring((mat and mat.level) or 1))
    local title = string.format("%s (%s)", item.name, lvlStr)
    local locStr = (mat and mat._cachedLoc and mat._cachedLoc ~= "-") and mat._cachedLoc or "None / Secondary"
    local sub = string.format(
        "Owned: %s (Bag: %s, Storage: %s, Bank: %s) | Req: %s | Remaining: %s",
        Utils.formatInt(item.owned),
        Utils.formatInt(item.ownedBag or 0),
        Utils.formatInt(item.ownedStorage or 0),
        Utils.formatInt(item.ownedBank or 0),
        Utils.formatInt(item.required),
        item.short > 0 and Utils.formatInt(item.short) or "Ready"
    )
    local detail = string.format("Locations: %s", locStr)
    return title, sub, detail, Theme.COL_GOLD, objId
end

return Tooltip
