local Protocol = require('shared.NetworkProtocol')
local Schema = require('shared.GameStateSchema')
local Adapter = require('client.GameStateAdapter')
local Client = require('client.ServerClient')
local Engine = require('server.domain.GameEngine')
local Adventure = require('server.domain.AdventureEngine')
local Big = require('shared.BigNumber')
local Large = require('shared.LargeNumber')
local Tables = require('shared.TableUtils')
local Route = require('shared.FloorRoute')
local callbacks, encoded, serial = {}, {}, 0
LOCAL = 0
function Scene() return { CreateComponent = function() end, Dispose = function() end } end
function SubscribeToEvent(name, callback) callbacks[name] = callback end
function UnsubscribeFromEvent(name) callbacks[name] = nil end
function VariantMap() return {} end
function Variant(value) return { GetString = function() return value end } end
cjson = { encode = function(value) serial = serial + 1; encoded[tostring(serial)] = value; return tostring(serial) end,
    decode = function(key) return encoded[key] end }
local commands = {}
local transport = { SendRemoteEvent = function(_, name, _, data)
    if name ~= Protocol.EVENTS.CLIENT_READY then
        commands[#commands + 1] = { name = name, data = data }
    end
end }
network = { GetServerConnection = function() return transport end, RegisterRemoteEvent = function() end }
local frame
local widget = setmetatable({GetLayout = function() return { w = 1080, h = 1400 } end},
    { __index = function() return function() end end })
package.loaded['client.PlayWorldView'] = { New = function() return {
    Configure = function() end, Build = function() return {} end,
    Update = function(value) frame = value end, Reset = function() end,
    GetPlayerMetrics = function() end,
} end }
package.loaded['client.PlayHud'] = { New = function() return {
    Configure = function() end, Build = function() return {} end,
    Update = function() end, Reset = function() end,
} end }
package.loaded['client.PlayEffects'] = { New = function() return setmetatable({
    Configure = function() end, BuildNodes = function() return {} end,
    GetLootDisplay = function() return '' end,
    ShouldRender = function() return true end,
}, { __index = function() return function() end end }) end }
local scene = require('client.PlayPresentation').New()
scene.Configure {
    getGame = Adapter.GetViewState, UI = { Panel = function() return widget end, Toast = { Show = function() end } },
    assets = { bg = 'bg', enemies = { goblin = 'g', skeleton = 's', slime = 's', boss = 'b' }, items = { gold = 'g', chest = 'c' } },
    colors = {}, currentPlayer = function() return { attackFrames = { 'attack' } } end,
    getAttackParams = function() return {} end, getRunParams = function() return {} end,
    playerSize = 100, playerScreenX = 180, enemySize = 100, lootSize = 50, runH = 100,
    eventTriggerDistance = 120, presentationSpeed = 96, formatInt = function() return '1' end,
    loadingController = { IsPlayAssetLoading = function() return false end,
        BeginFloorTransition = function() end, CompleteFloorTransition = function() end },
    actionResult = function(r) if not r.ok then print('ACTION', r.code) end end, updateTopBar = function() end,
    serverClient = Client,
}
Client.On('snapshot', scene.HandleSnapshot)
local presentedRewards, clientErrors = 0, {}
Client.On('delta', function(payload)
    scene.HandleDelta(payload)
    for _, event in ipairs(payload.events) do
        if event.type == 'battle_reward' then presentedRewards = presentedRewards + 1 end
    end
end)
Client.On('error', function(r) clientErrors[#clientErrors + 1] = r.reason end)
local now = 1791455000
local state = require('server.domain.StateFactory').Create(now)
state.tutorial.completed, state.storyProgress.introCompleted = true, true
state.floor, state.maxFloor, state.position, state.autoRun = 9, 9, 7, true
state.automationPolicy.autoEquip, state.automationPolicy.autoSkipStory = true, true
local original = state.inventory[1]
while #state.inventory < 181 do
    local item = Tables.DeepCopy(original)
    item.id = string.format('00000000-0000-4000-8000-%012d', #state.inventory)
    state.inventory[#state.inventory + 1] = item
end
local function receive(name, payload)
    callbacks[name](nil, { [Protocol.FIELDS.PAYLOAD_JSON] = Variant(cjson.encode(payload)) })
end
local transfers, won, requests = 0, 0, 0
local interleavedSettlements = {}
local verifyInterleaving = false
local interleavingValid = true
local function snapshot(events)
    local value = Schema.BuildSnapshot(state, { serverTime = now, playerNickname = 'Continuous probe' })
    value.logs, value.recentDamage, value.floorRoute = {}, 'Waiting', Route.Build(state.floor)
    transfers = transfers + 1
    local inventory = value.inventory; value.inventory = nil
    local count = math.ceil(#inventory / 24)
    for chunk = 1, count do
        -- A newer command delta can arrive while the death/drop snapshot is
        -- incomplete. It is a patch against that snapshot, not the old battle.
        local key = state.floor .. ':' .. state.position
        local target = key == '9:9' or key == '10:0' or key == '11:0'
        if chunk == count and target and not state.currentMonster and not interleavedSettlements[key] then
            interleavedSettlements[key] = true
            verifyInterleaving = true
            state.revision = state.revision + 1
            state.fragments = Large.Add(state.fragments, Large.FromNumber(1))
            local delta = Schema.BuildDelta(state.revision, { fragments = state.fragments }, { serverTime = now, state = state })
            delta.events = {}
            receive(Protocol.EVENTS.DELTA, { delta = delta })
        end
        local items = {}
        for i = (chunk - 1) * 24 + 1, math.min(chunk * 24, #inventory) do items[#items + 1] = inventory[i] end
        receive(Protocol.EVENTS.SNAPSHOT, { transferId = tostring(transfers), revision = value.revision,
            chunkIndex = chunk, chunkCount = count, inventory = items,
            snapshot = chunk == 1 and value or nil, events = chunk == 1 and (events or {}) or nil })
    end
    if verifyInterleaving then
        verifyInterleaving = false
        interleavingValid = interleavingValid and not Adapter.GetViewState().currentMonster
            and Large.Compare(Adapter.GetViewState().fragments, state.fragments) == 0
    end
end
local function deliver(result)
    assert(result.ok, result.error and result.error.code)
    state = result.state
    local events = assert(Schema.CanonicalizeGameEvents(result.delta.events))
    for _, event in ipairs(events) do if event.type == 'battle_won' then won = won + 1 end end
    if result.delta.inventoryChanged or result.delta.equippedChanged then snapshot(events)
    else
        local changes = Tables.DeepCopy(result.delta.changes)
        changes.floorRoute = Route.Build(state.floor)
        local delta = Schema.BuildDelta(state.revision, changes, { serverTime = now, state = state })
        delta.events = events
        receive(Protocol.EVENTS.DELTA, { delta = delta })
    end
end
local rng = function() return 0.1 end
assert(Client.Start()); snapshot(); Adapter.SetPage('play'); scene.BuildPage()
local runtime = require('server.services.IdleRuntimeService').New {
    operationQueue = require('server.core.OperationQueue').New(),
    rng = rng,
    profileService = {
        GetSession = function() return { generation = 1, state = state } end,
        GetState = function() return state end,
        OnlineUserIds = function() return { 'player' } end,
        IsOnline = function() return true end,
        ApplyRuntime = function(_, _, _, transform, callback)
            local result = transform(state, now)
            state = result.state
            callback({ ok = result.ok, data = { state = state, delta = result.delta } })
        end,
    },
    onDelta = function(_, delta) deliver({ ok = true, state = state, delta = delta }) end,
}
local duration = 0
while duration < 1500 and state.floor < 12 do
    duration = duration + 0.1; now = 1791455000 + math.floor(duration)
    if state.currentMonster then
        state.stats.atkBig, state.stats.hpBig = Big.New(1, 20), Big.New(1, 20)
        state.stats.atk, state.stats.hp, state.hp = 1e20, 1e20, 1e20; state.hpBig = Big.New(1, 20)
    end
    runtime:Update(0.1); Client.Update(0.1); scene.Update(0.1)
    local pending = commands; commands = {}
    for _, command in ipairs(pending) do
        local value = cjson.decode(command.data[Protocol.FIELDS.PAYLOAD_JSON]:GetString())
        local id = command.data[Protocol.FIELDS.REQUEST_ID]:GetString()
        local name = command.data[Protocol.FIELDS.COMMAND]:GetString()
        if name == 'Game.EnterEncounter' then
            requests = requests + 1
            local result = Adventure.EnterEncounter(state, value, rng, now)
            if result.ok then deliver(result) end
            receive(Protocol.EVENTS.RESPONSE, { requestId = id, ok = result.ok, code = result.error and result.error.code })
        elseif name == 'Game.RequestSnapshot' then snapshot(); receive(Protocol.EVENTS.RESPONSE, { requestId = id, ok = true })
        else print('COMMAND', name) end
    end
    if state.pendingEvent then deliver(Adventure.ResolveEvent(state, { eventId = state.pendingEvent.eventId, action = 'skip' }, now)) end
end
print('CONTINUOUS', 'floor',state.floor,'room',state.position,'won',won,'requests',requests,'snapshots',transfers,'duration',duration,
    'clientMonster',Adapter.GetViewState().currentMonster and Adapter.GetViewState().currentMonster.id,'serverMonster',state.currentMonster and state.currentMonster.id)
assert(interleavedSettlements['9:9'] and interleavedSettlements['10:0'] and interleavedSettlements['11:0'],
    'ninth-room, tenth-room and chapter-boss interleavings were not all exercised')
assert(interleavingValid, 'newer delta discarded the ninth-room death/drop snapshot, leaving a zero-HP monster')
assert(state.floor >= 12, 'continuous tower stalled')
assert(Adapter.GetViewState().floor == state.floor, 'client failed to reach the next authoritative floor')
assert(presentedRewards == won, 'settlement rewards were missed or replayed')
assert(#clientErrors == 0, table.concat(clientErrors, '; '))
Client.Stop()
print('tower_continuous_sync: PASS')
