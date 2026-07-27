local Protocol = require("shared.NetworkProtocol")
local ErrorCodes = require("shared.ErrorCodes")
local GameStateSchema = require("shared.GameStateSchema")
local BigNumber = require("shared.BigNumber")
local InventoryView = require("client.InventoryView")

local Spec = {}

local function NewStringVariant(value)
    return {
        GetString = function()
            return value or ""
        end,
    }
end

local function EmptySetProgress()
    local progress = {}
    for _, setId in ipairs(GameStateSchema.SET_IDS) do
        progress[setId] = {
            count = 0,
            regions = { weapon = 0, armor = 0, jewelry = 0, special = 0 },
            activeTiers = {
                ["3"] = false,
                ["6"] = false,
                ["9"] = false,
                ["12"] = false,
            },
            activeRegions = { armor = false, jewelry = false, special = false },
        }
    end
    return progress
end

local function CompleteStats(atk, def, hp)
    atk = atk or 10
    def = def or 5
    hp = hp or 100
    local displayedPower = BigNumber.FromNumber(atk + def + hp)
    return {
        atk = atk,
        def = def,
        hp = hp,
        atkBig = BigNumber.FromNumber(atk),
        defBig = BigNumber.FromNumber(def),
        hpBig = BigNumber.FromNumber(hp),
        maxHpBig = BigNumber.FromNumber(hp),
        crit = 0.10,
        critDmg = 1.5,
        atkSpeed = 1,
        lifeSteal = 0,
        bossDamage = 0,
        damageBonus = 0,
        trueDamageRate = 0,
        luckyChance = 0,
        luckyMultiplier = 1,
        moveSpeed = 0,
        skillDamage = 0,
        damageOverTime = 0,
        damageReduction = 0,
        lowHealthGuard = 0,
        permanentBonus = 0,
        setProgress = EmptySetProgress(),
        power = displayedPower,
        displayedPower = displayedPower,
        recommendedPower = BigNumber.FromNumber(100),
        nextChapterRecommendedPower = BigNumber.FromNumber(200),
        powerRatio = 1,
        headroomFloors = 0,
        difficultyLabel = "challenge",
        equivalentFloor = 1,
        estimatedEasyFloor = 1,
        towerScore = 1,
        bossScore = 1,
        eliteScore = 1,
        dpsSafe = 1,
        ehp = hp,
    }
end

local function ValidSnapshot(revision, updatedAt, level, stats)
    local state = GameStateSchema.NewInitialState(updatedAt)
    state.revision = revision
    state.updatedAt = updatedAt
    state.level = level
    state.stats = stats or CompleteStats()
    state.setProgress = GameStateSchema.DeepCopy(state.stats.setProgress)
    state.hpBig = BigNumber.Clone(state.stats.hpBig)
    state.hp = BigNumber.ToNumber(state.hpBig)
    state.nextExp = GameStateSchema.NextExp(level)
    return GameStateSchema.BuildSnapshot(state, {
        serverTime = updatedAt + 1,
        isAdmin = false,
        playerNickname = "client-spec",
    })
end

function Spec.Run()
    local highPowerItems = {
        { id = "lower", rarity = "myth", power = BigNumber.New(9, 599) },
        { id = "higher", rarity = "myth", power = BigNumber.New(1, 600) },
        { id = "rarer", rarity = "epic", power = BigNumber.New(9, 900) },
    }
    InventoryView.SortByRarityAndPower(highPowerItems, {
        myth = { rank = 7 },
        epic = { rank = 6 },
    }, function(left, right)
        return BigNumber.Compare(left.power, right.power)
    end)
    assert(highPowerItems[1].id == "higher" and highPowerItems[2].id == "lower")

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
    local oldPresentationModule = package.loaded["client.PlayPresentation"]

    local subscriptions = {}
    local registeredEvents = {}
    local scenes = {}
    local activeConnection = nil
    local jsonValues = {}
    local jsonCounter = 0
    local ServerClient = nil
    local PlayPresentation = nil

    local function NewConnection(name)
        return {
            name = name,
            sent = {},
            SendRemoteEvent = function(self, eventName, reliable, eventData)
                if self.failNextSend then
                    self.failNextSend = false
                    error("simulated send failure")
                end
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
        package.loaded["client.PlayPresentation"] = nil
        ServerClient = require("client.ServerClient")
        local GameStateAdapter = require("client.GameStateAdapter")
        PlayPresentation = require("client.PlayPresentation")

        local firstConnection = NewConnection("first")
        activeConnection = firstConnection
        assert(ServerClient.Start())
        assert(#scenes == 1, "Start must create one module-owned scene")
        assert(firstConnection.scene == scenes[1], "initial connection must use the module scene")
        assert(#firstConnection.sent == 1)
        assert(firstConnection.sent[1].eventName == Protocol.EVENTS.CLIENT_READY)
        assert(subscriptions.ServerConnected ~= nil, "ServerConnected must be subscribed")
        assert(subscriptions.ServerDisconnected ~= nil, "ServerDisconnected must be subscribed")

        local protocolErrors = {}
        local removeErrorListener = ServerClient.On("error", function(payload)
            protocolErrors[#protocolErrors + 1] = payload
        end)
        local reconnectStoryGate = {
            storyId = "tower-prologue",
            chapter = 0,
            floor = 1,
            phase = "prologue",
            title = "万灵塔苏醒",
            lines = { "第一句", "第二句" },
            lineIndex = 1,
        }
        local reconnectItemId = "00000000-0000-4000-8000-000000000007"
        local reconnectEquipDecision = {
            itemId = reconnectItemId,
            createdAt = 101,
            displayedPowerDeltaBig = BigNumber.FromNumber(25),
        }
        subscriptions[Protocol.EVENTS.SNAPSHOT](Protocol.EVENTS.SNAPSHOT, EventData({
            snapshot = {
                kind = "GameSnapshot",
                schemaVersion = GameStateSchema.VERSION,
                revision = 7,
                updatedAt = 100,
                playerNickname = "client-spec",
                level = 99,
                inventory = {},
                equipped = {},
            },
        }))
        assert(not ServerClient.IsReady(), "an invalid snapshot must not make the client ready")
        assert(GameStateAdapter.GetViewState().revision == 0, "an invalid snapshot must not reach the adapter")
        assert(#protocolErrors == 1)
        assert(protocolErrors[1].code == ErrorCodes.INVALID_STATE)
        assert(type(protocolErrors[1].reason) == "string" and protocolErrors[1].reason ~= "")

        local unknownEventSnapshot = ValidSnapshot(7, 100, 21)
        subscriptions[Protocol.EVENTS.SNAPSHOT](Protocol.EVENTS.SNAPSHOT, EventData({
            snapshot = unknownEventSnapshot,
            events = {
                { type = "future_unknown_event" },
            },
        }))
        assert(not ServerClient.IsReady(), "a snapshot with an unknown event must be rejected")
        assert(GameStateAdapter.GetViewState().revision == 0,
            "snapshot events must be validated before the snapshot reaches the adapter")
        assert(#protocolErrors == 2)
        assert(protocolErrors[2].code == ErrorCodes.INVALID_STATE)
        assert(type(protocolErrors[2].reason) == "string" and protocolErrors[2].reason ~= "")

        subscriptions[Protocol.EVENTS.SNAPSHOT](Protocol.EVENTS.SNAPSHOT, EventData({
            snapshot = ValidSnapshot(7, 100, 21),
        }))
        assert(ServerClient.IsReady())
        assert(GameStateAdapter.GetViewState().readOnly == false)

        local callbackCalls = 0
        local oldRequestResult = nil
        local oldRequestId = assert(ServerClient.Send("Game.RequestSnapshot", {}, function(response)
            callbackCalls = callbackCalls + 1
            oldRequestResult = response
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
        assert(callbackCalls == 1, "reconnect must complete old callbacks with a terminal failure")
        assert(oldRequestResult and oldRequestResult.ok == false)
        assert(oldRequestResult.code == ErrorCodes.NOT_READY)

        local reconnectSnapshot = ValidSnapshot(8, 101, 22)
        reconnectSnapshot.pendingStoryGate = reconnectStoryGate
        reconnectSnapshot.pendingEquipDecision = reconnectEquipDecision
        subscriptions[Protocol.EVENTS.SNAPSHOT](Protocol.EVENTS.SNAPSHOT, EventData({
            snapshot = reconnectSnapshot,
            events = {
                {
                    type = "story_gate",
                    storyId = reconnectStoryGate.storyId,
                    chapter = reconnectStoryGate.chapter,
                    floor = reconnectStoryGate.floor,
                    phase = reconnectStoryGate.phase,
                    title = reconnectStoryGate.title,
                    lines = reconnectStoryGate.lines,
                    lineIndex = reconnectStoryGate.lineIndex,
                },
            },
        }))
        assert(ServerClient.IsReady())
        local reconnectView = GameStateAdapter.GetViewState()
        assert(reconnectView.pendingStoryGate ~= nil,
            "reconnect snapshot must restore the pending story gate")
        assert(reconnectView.pendingStoryGate.storyId == reconnectStoryGate.storyId)
        assert(reconnectView.pendingStoryGate.type == nil and reconnectView.pendingStoryGate.kind == nil,
            "pendingStoryGate must retain the shared snapshot schema shape")
        assert(reconnectView.pendingStory == nil,
            "the client view must use the canonical story gate field")

        local shownStoryGate = nil
        local shownEquipmentUpgrade = nil
        PlayPresentation.Configure({
            getGame = function() return GameStateAdapter.GetViewState() end,
            showStoryGate = function(gate) shownStoryGate = gate; return true end,
            showEquipmentUpgrade = function(decision) shownEquipmentUpgrade = decision; return true end,
        })
        PlayPresentation.HandleSnapshot()
        assert(shownStoryGate and shownStoryGate.storyId == reconnectStoryGate.storyId,
            "presentation must reopen a pending story after reconnect")
        assert(shownEquipmentUpgrade and shownEquipmentUpgrade.itemId == reconnectItemId,
            "presentation must reopen a pending equipment decision after reconnect")

        GameStateAdapter.ApplySnapshotEvents({ {
            kind = "story_advanced",
            storyId = reconnectStoryGate.storyId,
            lineIndex = 2,
            line = reconnectStoryGate.lines[2],
        } })
        assert(GameStateAdapter.GetViewState().pendingStoryGate.lineIndex == 2,
            "story advancement must keep the authoritative gate active")

        local commandStart = #secondConnection.sent
        assert(ServerClient.AdvanceStory("next", "intro", 2))
        local itemId = reconnectItemId
        assert(ServerClient.DecideEquip("equip", itemId))
        assert(ServerClient.Equip(itemId))
        assert(ServerClient.ClaimAid())
        assert(ServerClient.AcknowledgeRules("tower_rules_v2"))

        local function AssertCommand(offset, command, expectedPayload)
            local sent = secondConnection.sent[commandStart + offset]
            assert(sent and sent.eventName == Protocol.EVENTS.COMMAND)
            assert(sent.eventData[Protocol.FIELDS.COMMAND] == command)
            local payload = jsonValues[sent.eventData[Protocol.FIELDS.PAYLOAD_JSON]]
            assert(type(payload) == "table")
            for key, value in pairs(expectedPayload) do
                assert(payload[key] == value, command .. " payload mismatch: " .. tostring(key))
            end
            return payload
        end

        local storyPayload = AssertCommand(1, "Game.AdvanceStory", {
            action = "next", storyId = "intro", lineIndex = 2,
        })
        assert(storyPayload.chapter == nil and storyPayload.phase == nil)
        local equipPayload = AssertCommand(2, "Game.DecideEquip", {
            action = "equip", itemId = itemId,
        })
        assert(equipPayload.decisionId == nil and equipPayload.accept == nil)
        AssertCommand(3, "Game.Equip", { itemId = itemId })
        local aidPayload = AssertCommand(4, "Game.ClaimAid", {})
        assert(next(aidPayload) == nil)
        AssertCommand(5, "Game.AcknowledgeRules", { ruleId = "tower_rules_v2" })

        local receivedDelta = nil
        local receivedDeltaCount = 0
        local removeDeltaListener = ServerClient.On("delta", function(payload)
            receivedDelta = payload
            receivedDeltaCount = receivedDeltaCount + 1
        end)
        local replacementStats = CompleteStats(20, 8, 120)
        replacementStats.atk = nil
        replacementStats.def = nil
        replacementStats.hp = nil
        subscriptions[Protocol.EVENTS.DELTA](Protocol.EVENTS.DELTA, EventData({
            delta = {
                kind = "GameDelta",
                schemaVersion = GameStateSchema.VERSION,
                revision = 9,
                serverTime = 102,
                inventoryChanged = false,
                changes = {
                    stats = replacementStats,
                },
                events = {
                    { type = "monster_spawned", floor = 1, room = 1, kind = "normal", hp = 170, maxHp = 170 },
                    { type = "player_damaged", amount = 20, hp = 80, maxHp = 100 },
                    { type = "player_healed", amount = 10, hp = 90, maxHp = 100, source = "life_steal" },
                },
            },
        }))
        local combatView = GameStateAdapter.GetViewState()
        assert(combatView.revision == 9)
        assert(combatView.hp == 90 and combatView.playerMaxHp == 100)
        assert(combatView.stats.atk == nil and combatView.stats.def == nil and combatView.stats.hp == nil,
            "full stats deltas must remove obsolete scalar projections")
        assert(combatView.currentMonster and combatView.currentMonster.hp == 170)
        assert(combatView.currentMonster.encounterKind == "normal")
        assert(receivedDelta and #receivedDelta.events == 3)
        assert(receivedDelta.events[1].kind == "monster_spawned")
        assert(receivedDelta.events[1].encounterKind == "normal")

        subscriptions[Protocol.EVENTS.DELTA](Protocol.EVENTS.DELTA, EventData({
            delta = {
                kind = "GameDelta",
                schemaVersion = GameStateSchema.VERSION,
                revision = 9,
                serverTime = 103,
                inventoryChanged = false,
                changes = {},
                events = {
                    { type = "player_damaged", amount = 1, hp = 89, maxHp = 100 },
                },
            },
        }))
        assert(receivedDeltaCount == 1, "duplicate revisions must not replay presentation events")
        assert(GameStateAdapter.GetViewState().hp == 90)
        removeDeltaListener()

        local sentBeforeInvalidDelta = #secondConnection.sent
        subscriptions[Protocol.EVENTS.DELTA](Protocol.EVENTS.DELTA, EventData({
            delta = {
                kind = "GameDelta",
                schemaVersion = GameStateSchema.VERSION,
                revision = 10,
                serverTime = 103,
                inventoryChanged = false,
                changes = { serverOwnedSecret = true },
                events = {},
            },
        }))
        assert(GameStateAdapter.GetViewState().revision == 9, "an invalid delta must not reach the adapter")
        assert(#protocolErrors == 3)
        assert(protocolErrors[3].code == ErrorCodes.INVALID_STATE)
        assert(type(protocolErrors[3].reason) == "string" and protocolErrors[3].reason ~= "")
        local resyncRequest = secondConnection.sent[sentBeforeInvalidDelta + 1]
        assert(resyncRequest and resyncRequest.eventName == Protocol.EVENTS.COMMAND)
        assert(resyncRequest.eventData[Protocol.FIELDS.COMMAND] == "Game.RequestSnapshot")

        secondConnection.failNextSend = true
        local sendFailure = nil
        local failedRequestId, failedReason = ServerClient.AutoRun(true, function(response)
            sendFailure = response
        end)
        assert(failedRequestId == nil, "a transport exception must reject the request")
        assert(type(failedReason) == "string" and failedReason ~= "")
        assert(sendFailure and sendFailure.ok == false)
        assert(sendFailure.code == "OPERATION_FAILED")

        local timeoutCalls = 0
        local timeoutResult = nil
        local timeoutRequestId = assert(ServerClient.CollectOffline("offline-quote-token", function(response)
            timeoutCalls = timeoutCalls + 1
            timeoutResult = response
        end))
        ServerClient.Update(29.9)
        assert(timeoutCalls == 0, "request must remain pending before its deadline")
        ServerClient.Update(0.2)
        assert(timeoutCalls == 1, "request timeout must complete the callback exactly once")
        assert(timeoutResult and timeoutResult.code == ErrorCodes.REQUEST_TIMEOUT)
        subscriptions[Protocol.EVENTS.RESPONSE](Protocol.EVENTS.RESPONSE, EventData({
            requestId = timeoutRequestId,
            ok = true,
        }))
        assert(timeoutCalls == 1, "a late response must not complete a timed-out request twice")

        subscriptions.ServerDisconnected("ServerDisconnected", {})
        local disconnectedView = GameStateAdapter.GetViewState()
        assert(not ServerClient.IsReady())
        assert(disconnectedView.revision == 9, "disconnect must preserve the last authoritative update")
        assert(disconnectedView.connectionState == "disconnected")
        assert(disconnectedView.readOnly == true)

        subscriptions[Protocol.EVENTS.SNAPSHOT](Protocol.EVENTS.SNAPSHOT, EventData({
            snapshot = { revision = 10 },
        }))
        assert(GameStateAdapter.GetViewState().revision == 9, "events received after disconnect must be ignored")

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
        removeErrorListener()
        ServerClient.Stop()

        GameStateAdapter.ApplySnapshot({
            revision = 10,
            pendingStory = reconnectStoryGate,
        })
        local legacyView = GameStateAdapter.GetViewState()
        assert(legacyView.pendingStoryGate
            and legacyView.pendingStoryGate.storyId == reconnectStoryGate.storyId,
            "legacy pendingStory snapshots must migrate to pendingStoryGate")
        assert(legacyView.pendingStory == nil)
        GameStateAdapter.ApplySnapshotEvents({ {
            kind = "story_completed",
            storyId = reconnectStoryGate.storyId,
        } })
        assert(GameStateAdapter.GetViewState().pendingStoryGate == nil)

        assert(#registeredEvents >= #Protocol.CLIENT_EVENTS)
    end)

    if ServerClient then pcall(ServerClient.Stop) end
    if PlayPresentation then pcall(PlayPresentation.Reset) end
    package.loaded["client.ServerClient"] = oldClientModule
    package.loaded["client.GameStateAdapter"] = oldAdapterModule
    package.loaded["client.PlayPresentation"] = oldPresentationModule
    for name, value in pairs(oldGlobals) do _G[name] = value end
    for _, name in ipairs({ "Scene", "LOCAL", "Variant", "VariantMap", "SubscribeToEvent", "UnsubscribeFromEvent", "network", "cjson" }) do
        if oldGlobals[name] == nil then _G[name] = nil end
    end

    assert(ok, reason)
end

return Spec
