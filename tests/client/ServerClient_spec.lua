local Protocol = require("shared.NetworkProtocol")

local Spec = {}

local function NewStringVariant(value)
    return {
        GetString = function()
            return value or ""
        end,
    }
end

function Spec.Run()
    local oldGlobals = {
        Scene = rawget(_G, "Scene"),
        LOCAL = rawget(_G, "LOCAL"),
        Variant = rawget(_G, "Variant"),
        VariantMap = rawget(_G, "VariantMap"),
        SubscribeToEvent = rawget(_G, "SubscribeToEvent"),
        UnsubscribeFromEvent = rawget(_G, "UnsubscribeFromEvent"),
        network = rawget(_G, "network"),
        cjson = rawget(_G, "cjson"),
    }
    local oldClientModule = package.loaded["client.ServerClient"]
    local oldAdapterModule = package.loaded["client.GameStateAdapter"]

    local subscriptions = {}
    local registeredEvents = {}
    local scenes = {}
    local activeConnection = nil
    local jsonValues = {}
    local jsonCounter = 0
    local ServerClient = nil

    local function NewConnection(name)
        return {
            name = name,
            sent = {},
            SendRemoteEvent = function(self, eventName, reliable, eventData)
                self.sent[#self.sent + 1] = {
                    eventName = eventName,
                    reliable = reliable,
                    eventData = eventData,
                }
            end,
        }
    end

    local function EventData(payload)
        local encoded = _G.cjson.encode(payload)
        return {
            [Protocol.FIELDS.PAYLOAD_JSON] = NewStringVariant(encoded),
            [Protocol.FIELDS.REQUEST_ID] = NewStringVariant(payload.requestId),
        }
    end

    local ok, reason = pcall(function()
        _G.LOCAL = 0
        _G.Scene = function()
            local scene = {
                disposed = false,
                CreateComponent = function() end,
                Dispose = function(self) self.disposed = true end,
            }
            scenes[#scenes + 1] = scene
            return scene
        end
        _G.VariantMap = function() return {} end
        _G.Variant = function(value) return value end
        _G.SubscribeToEvent = function(eventName, handler)
            subscriptions[eventName] = handler
        end
        _G.UnsubscribeFromEvent = function(eventName)
            subscriptions[eventName] = nil
        end
        _G.network = {
            RegisterRemoteEvent = function(_, eventName)
                registeredEvents[#registeredEvents + 1] = eventName
            end,
            GetServerConnection = function()
                return activeConnection
            end,
        }
        _G.cjson = {
            encode = function(value)
                jsonCounter = jsonCounter + 1
                local token = "json:" .. tostring(jsonCounter)
                jsonValues[token] = value
                return token
            end,
            decode = function(token)
                assert(jsonValues[token] ~= nil, "unknown fake JSON token")
                return jsonValues[token]
            end,
        }

        package.loaded["client.ServerClient"] = nil
        package.loaded["client.GameStateAdapter"] = nil
        ServerClient = require("client.ServerClient")
        local GameStateAdapter = require("client.GameStateAdapter")

        local firstConnection = NewConnection("first")
        activeConnection = firstConnection
        assert(ServerClient.Start())
        assert(#scenes == 1, "Start must create one module-owned scene")
        assert(firstConnection.scene == scenes[1], "initial connection must use the module scene")
        assert(#firstConnection.sent == 1)
        assert(firstConnection.sent[1].eventName == Protocol.EVENTS.CLIENT_READY)
        assert(subscriptions.ServerConnected ~= nil, "ServerConnected must be subscribed")
        assert(subscriptions.ServerDisconnected ~= nil, "ServerDisconnected must be subscribed")

        subscriptions[Protocol.EVENTS.SNAPSHOT](Protocol.EVENTS.SNAPSHOT, EventData({
            snapshot = {
                schemaVersion = 1,
                revision = 7,
                updatedAt = 100,
                level = 21,
                inventory = {},
                equippedSlots = {},
            },
        }))
        assert(ServerClient.IsReady())
        assert(GameStateAdapter.GetViewState().readOnly == false)

        local callbackCalls = 0
        local oldRequestId = assert(ServerClient.Send("Game.RequestSnapshot", {}, function()
            callbackCalls = callbackCalls + 1
        end))

        local secondConnection = NewConnection("second")
        activeConnection = secondConnection
        subscriptions.ServerConnected("ServerConnected", {})
        assert(#scenes == 1, "reconnect must reuse the existing scene")
        assert(secondConnection.scene == scenes[1], "new connection must be rebound to the module scene")
        assert(#secondConnection.sent == 1)
        assert(secondConnection.sent[1].eventName == Protocol.EVENTS.CLIENT_READY)
        assert(not ServerClient.IsReady(), "reconnect must wait for a new snapshot")

        local syncingView = GameStateAdapter.GetViewState()
        assert(syncingView.revision == 7, "reconnect must preserve the last snapshot")
        assert(syncingView.connectionState == "syncing")
        assert(syncingView.readOnly == true)

        subscriptions[Protocol.EVENTS.RESPONSE](Protocol.EVENTS.RESPONSE, EventData({
            requestId = oldRequestId,
            ok = true,
        }))
        assert(callbackCalls == 0, "callbacks from the old connection must be cleared")

        subscriptions[Protocol.EVENTS.SNAPSHOT](Protocol.EVENTS.SNAPSHOT, EventData({
            snapshot = {
                schemaVersion = 1,
                revision = 8,
                updatedAt = 101,
                level = 22,
                inventory = {},
                equippedSlots = {},
            },
        }))
        assert(ServerClient.IsReady())

        subscriptions.ServerDisconnected("ServerDisconnected", {})
        local disconnectedView = GameStateAdapter.GetViewState()
        assert(not ServerClient.IsReady())
        assert(disconnectedView.revision == 8, "disconnect must preserve the last snapshot")
        assert(disconnectedView.connectionState == "disconnected")
        assert(disconnectedView.readOnly == true)

        subscriptions[Protocol.EVENTS.SNAPSHOT](Protocol.EVENTS.SNAPSHOT, EventData({
            snapshot = { revision = 9 },
        }))
        assert(GameStateAdapter.GetViewState().revision == 8, "events received after disconnect must be ignored")

        local stoppedConnectHandler = subscriptions.ServerConnected
        ServerClient.Stop()
        assert(subscriptions.ServerConnected == nil)
        assert(subscriptions.ServerDisconnected == nil)
        assert(subscriptions[Protocol.EVENTS.SNAPSHOT] == nil)
        assert(scenes[1].disposed == true)

        local thirdConnection = NewConnection("third")
        activeConnection = thirdConnection
        stoppedConnectHandler("ServerConnected", {})
        assert(#thirdConnection.sent == 0, "a stale event callback must not restart a stopped client")

        activeConnection = nil
        assert(ServerClient.Start(), "Start must wait when the connection is not available yet")
        assert(#scenes == 2)
        assert(GameStateAdapter.GetViewState().connectionState == "syncing")
        activeConnection = thirdConnection
        subscriptions.ServerConnected("ServerConnected", {})
        assert(thirdConnection.scene == scenes[2])
        assert(#thirdConnection.sent == 1)
        assert(thirdConnection.sent[1].eventName == Protocol.EVENTS.CLIENT_READY)
        ServerClient.Stop()

        assert(#registeredEvents >= #Protocol.CLIENT_EVENTS)
    end)

    if ServerClient then pcall(ServerClient.Stop) end
    package.loaded["client.ServerClient"] = oldClientModule
    package.loaded["client.GameStateAdapter"] = oldAdapterModule
    for name, value in pairs(oldGlobals) do _G[name] = value end
    for _, name in ipairs({ "Scene", "LOCAL", "Variant", "VariantMap", "SubscribeToEvent", "UnsubscribeFromEvent", "network", "cjson" }) do
        if oldGlobals[name] == nil then _G[name] = nil end
    end

    assert(ok, reason)
end

return Spec
