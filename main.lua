-- main.lua
-- Entrypoint for the RS3 "Archaeology Assistant" plugin.
-- Initialises the material & artefact tracker, builds the UI overlay window,
-- and subscribes to client inventory & chat events for real-time updates.

local function recordError(context, err)
    local msg = string.format("[%s] %s", tostring(context), tostring(err))
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
        tracker:recalculate()
        window:refresh()
        if PersistentDB then
            pcall(function() PersistentDB:Set("arch_last_error", "NONE") end)
        end
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
    if not event or not tracker or not window then return end
    xpcall(function()
        local msg = event.chatMessage or event.text or event.message or (type(event) == "string" and event)
        if msg and tracker:onChatMessage(msg) then
            window:refresh()
        end
    end, function(e)
        recordError("onChatMessage", e)
    end)
end

local chatSubscribed = false
local function updateChatSubscription()
    local hasPerm = true
    if Plugin and Plugin.HasPermission and PluginPermissions and PluginPermissions.chatAccess then
        local ok, granted = pcall(Plugin.HasPermission, PluginPermissions.chatAccess)
        if ok then
            hasPerm = granted
        end
    end

    if hasPerm and not chatSubscribed then
        if Event and Event.ChatMessage and Event.ChatMessage.Subscribe then
            local ok, err = pcall(function()
                Event.ChatMessage.Subscribe("arch_assistant_chat", onChatMessage)
            end)
            if ok then
                chatSubscribed = true
            else
                recordError("ChatMessage.Subscribe", err)
            end
        end
    elseif not hasPerm and chatSubscribed then
        if Event and Event.ChatMessage and Event.ChatMessage.Unsubscribe then
            pcall(function()
                Event.ChatMessage.Unsubscribe("arch_assistant_chat")
            end)
        end
        chatSubscribed = false
    end
end

updateChatSubscription()

if Event and Event.OptionalPermissionChanged and Event.OptionalPermissionChanged.Subscribe then
    Event.OptionalPermissionChanged.Subscribe("arch_assistant_perm_changed", function(ev)
        updateChatSubscription()
    end)
end

-- Track player player actions like Drop vs Deposit from the MiniMenu
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
    if window and window.shutdown then
        pcall(function() window:shutdown() end)
    end
    if tracker then
        pcall(function() tracker:savePersistentState() end)
    end
end

print("Archaeology Assistant v0.2.0 loaded.")

