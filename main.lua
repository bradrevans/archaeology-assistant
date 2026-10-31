-- main.lua
-- Entrypoint for the RS3 "Archaeology Assistant" plugin.
-- Initialises the material & artefact tracker, builds the UI overlay window,
-- and subscribes to client inventory & chat events for real-time updates.

print("[Archaeology Assistant] Initializing plugin v1.0.0...")



local function recordError(context, err)
    local trace = (debug and debug.traceback) and debug.traceback(tostring(err), 2) or tostring(err)
    local msg = string.format("[%s] %s", tostring(context), tostring(trace))
    print("[Archaeology Assistant ERROR] " .. msg)
    if PersistentDB then
        pcall(function() PersistentDB:Set("arch_last_error", msg) end)
    end
end

local okTracker, Tracker = xpcall(function() return require("tracker") end, function(e)
    recordError("require(tracker)", e)
end)

local okWindow, Window = xpcall(function() return require("ui/window") end, function(e)
    recordError("require(ui/window)", e)
end)

local tracker = nil
local window = nil

if okTracker and Tracker then
    local okInitT, tInstance = xpcall(function() return Tracker.new() end, function(e)
        recordError("Tracker.new", e)
    end)
    if okInitT then
        tracker = tInstance
    end
end

if tracker and okWindow and Window then
    local okInitW, wInstance = xpcall(function() return Window.new(tracker) end, function(e)
        recordError("Window.new", e)
    end)
    if okInitW then
        window = wInstance
    end
end

if tracker and window then
    xpcall(function()
        tracker:syncCollectionsDoneStatus()
        tracker:recalculate()
        window:refresh()
        if PersistentDB then
            pcall(function() PersistentDB:Set("arch_last_error", "NONE") end)
        end
        print("[Archaeology Assistant] Plugin ready!")
    end, function(e)
        recordError("Initial recalculate/refresh", e)
    end)
end

-- Handle inventory container creation / updates (Backpack, Material Storage, Bank)
local function onInventoryEvent(event)
    if not tracker or not window then return end
    xpcall(function()
        local triggerInv = event and event.inv or nil
        tracker:recalculate(triggerInv)
        window:refresh()
    end, function(e)
        recordError("onInventoryEvent", e)
    end)
end

if Event and Event.InventoryAdded and Event.InventoryAdded.Subscribe then
    Event.InventoryAdded.Subscribe("arch_assistant_inv_added", onInventoryEvent)
end

if Event and Event.InventoryUpdated and Event.InventoryUpdated.Subscribe then
    Event.InventoryUpdated.Subscribe("arch_assistant_inv_updated", onInventoryEvent)
end

-- Handle Sign of the Porter / Material Storage chat messages while excavating
local function onChatMessage(event)
    if not tracker then return end
    xpcall(function()
        local msg = (type(event) == "table" and (event.chatMessage or event.text or event.message))
            or (type(event) == "string" and event)

        if not msg and type(event) == "table" then
            for _, v in pairs(event) do
                if type(v) == "string" and (string.find(string.lower(v), "transport") or string.find(string.lower(v), "storage")) then
                    msg = v
                    break
                end
            end
        end

        if msg then
            local lower = string.lower(tostring(msg))
            if string.find(lower, "transport") or string.find(lower, "storage") or string.find(lower, "porter") or string.find(lower, "grace of the elves") then
                print("[Archaeology Assistant CHAT] " .. tostring(msg))
            end
            if tracker:onChatMessage(msg) then
                if window then
                    window:refresh()
                end
            end
        end
    end, function(e)
        recordError("onChatMessage", e)
    end)
end

local function checkHasChatPermission()
    local hasChatPerm = false
    pcall(function()
        if Plugin and Plugin.HasPermission then
            if PluginPermissions and PluginPermissions.chatAccess then
                hasChatPerm = Plugin.HasPermission(PluginPermissions.chatAccess)
            else
                hasChatPerm = Plugin.HasPermission("chatAccess")
            end
        end
    end)
    return hasChatPerm
end

local function subscribeChatEvents()
    if not Event or not Event.ChatMessage or not Event.ChatMessage.Subscribe then
        return false
    end
    local ok, err = pcall(function()
        Event.ChatMessage.Unsubscribe("arch_assistant_chat")
    end)
    ok, err = pcall(function()
        Event.ChatMessage.Subscribe("arch_assistant_chat", onChatMessage)
    end)
    if not ok then
        print("[Archaeology Assistant WARNING] Event.ChatMessage.Subscribe failed: " .. tostring(err))
        return false
    end
    return true
end

if subscribeChatEvents() then
    if checkHasChatPermission() then
        print("[Archaeology Assistant] Chat event listener active (chatAccess GRANTED).")
    else
        print("[Archaeology Assistant] Chat event listener active (waiting for chatAccess permission).")
        print("[Archaeology Assistant] NOTE: Run 'ppr archaeology-assistant' in console, then open the Plugin Hub UI and tick the chatAccess checkbox.")
    end
end

if Event and Event.OptionalPermissionChanged and Event.OptionalPermissionChanged.Subscribe then
    Event.OptionalPermissionChanged.Subscribe("arch_assistant_perm_changed", function(perm)
        pcall(function()
            subscribeChatEvents()
            local granted = checkHasChatPermission()
            print(string.format(
                "[Archaeology Assistant] Permission status changed (%s) -> chatAccess %s",
                tostring(perm),
                granted and "GRANTED" or "NOT GRANTED"
            ))
        end)
    end)
end

-- Track player actions like Drop vs Deposit from the MiniMenu
local function onMiniMenuSelected(event)
    if not event or not event.entry or not tracker then return end
    xpcall(function()
        local verb = event.entry.verbText or ""
        local full = event.entry.fullText or ""
        tracker:onMiniMenuAction(verb, full)
    end, function(e)
        recordError("onMiniMenuSelected", e)
    end)
end

if Event and Event.MiniMenuEntrySelected and Event.MiniMenuEntrySelected.Subscribe then
    Event.MiniMenuEntrySelected.Subscribe("arch_assistant_minimenu", onMiniMenuSelected)
end

if Event and Event.Logic and Event.Logic.Subscribe then
    Event.Logic.Subscribe("arch_assistant_collector_scan", function()
        if tracker and tracker:onLogicTick() then
            if window then window:refresh() end
        end
    end)
end

-- Global shutdown hook called automatically by the RS3 client when disabling or closing
function PluginShutdown()
    if Event and Event.InventoryAdded and Event.InventoryAdded.Unsubscribe then
        pcall(function() Event.InventoryAdded.Unsubscribe("arch_assistant_inv_added") end)
    end
    if Event and Event.InventoryUpdated and Event.InventoryUpdated.Unsubscribe then
        pcall(function() Event.InventoryUpdated.Unsubscribe("arch_assistant_inv_updated") end)
    end
    if Event and Event.ChatMessage and Event.ChatMessage.Unsubscribe then
        pcall(function() Event.ChatMessage.Unsubscribe("arch_assistant_chat") end)
    end
    if Event and Event.OptionalPermissionChanged and Event.OptionalPermissionChanged.Unsubscribe then
        pcall(function() Event.OptionalPermissionChanged.Unsubscribe("arch_assistant_perm_changed") end)
    end
    if Event and Event.MiniMenuEntrySelected and Event.MiniMenuEntrySelected.Unsubscribe then
        pcall(function() Event.MiniMenuEntrySelected.Unsubscribe("arch_assistant_minimenu") end)
    end
    if Event and Event.Logic and Event.Logic.Unsubscribe then
        pcall(function() Event.Logic.Unsubscribe("arch_assistant_collector_scan") end)
    end
    if window and window.shutdown then
        pcall(function() window:shutdown() end)
    end
    if tracker then
        pcall(function() tracker:savePersistentState() end)
    end
end

print("Archaeology Assistant v1.0.0 loaded.")

