local Protocol = require('shared.NetworkProtocol')
local Client = require('client.ServerClient')
local Adapter = require('client.GameStateAdapter')
local Schema = require('shared.GameStateSchema')
local events, decoded = {}, {}
LOCAL = 0
function Scene() return { CreateComponent = function() end, Dispose = function() end } end
function SubscribeToEvent(name, callback) events[name] = callback end
function UnsubscribeFromEvent(name) events[name] = nil end
function VariantMap() return {} end
function Variant(value) return { GetString = function() return value end } end
cjson = { encode = function() return '{}' end, decode = function() return decoded end }
local transport = { SendRemoteEvent = function() end }
network = { GetServerConnection = function() return transport end, RegisterRemoteEvent = function() end }
local state = require('server.domain.StateFactory').Create(1791455000)
state.revision = 10
local function Snapshot(revision)
    state.revision = revision
    local snapshot = Schema.BuildSnapshot(state, { serverTime = 1791455000, playerNickname = 'Recovery test' })
    snapshot.logs, snapshot.recentDamage = {}, 'Waiting'
    return snapshot
end
local snapshots, rewards = 0, 0
Client.On('snapshot', function() snapshots = snapshots + 1 end)
Client.On('delta', function(payload) rewards = rewards + #payload.events end)
assert(Client.Start())
local function Receive(snapshot)
    decoded = { snapshot = snapshot, events = { { type = 'battle_reward', gold = 1, exp = 1 } } }
    events[Protocol.EVENTS.SNAPSHOT](nil, { [Protocol.FIELDS.PAYLOAD_JSON] = Variant('{}') })
end
Receive(Snapshot(10))
assert(snapshots == 1 and rewards == 1 and Adapter.GetRevision() == 10)
Receive(Snapshot(10))
assert(snapshots == 1 and rewards == 1, 'unsolicited duplicate snapshot must stay ignored')
assert(Client.RequestSnapshot())
Receive(Snapshot(9))
assert(snapshots == 1 and Adapter.GetRevision() == 10, 'recovery must never accept older state')
Receive(Snapshot(10))
assert(snapshots == 2 and rewards == 1, 'requested equal revision must repair state without replaying rewards')
Receive(Snapshot(10))
assert(snapshots == 2 and rewards == 1, 'recovery permission must be consumed by one snapshot')

-- Inventory drops use chunked snapshots on large backpacks; recovery must work
-- after full assembly, including out-of-order chunks, without replaying rewards.
assert(Client.RequestSnapshot())
local snapshot = Snapshot(10)
local inventory = snapshot.inventory
snapshot.inventory = nil
local function Chunk(index)
    decoded = { transferId = 'recovery:10', revision = 10, chunkIndex = index, chunkCount = 2,
        inventory = index == 1 and inventory or {}, snapshot = index == 1 and snapshot or nil,
        events = index == 1 and { { type = 'battle_reward', gold = 1, exp = 1 } } or nil }
    events[Protocol.EVENTS.SNAPSHOT](nil, { [Protocol.FIELDS.PAYLOAD_JSON] = Variant('{}') })
end
Chunk(2); assert(snapshots == 2)
Chunk(1); assert(snapshots == 3 and rewards == 1, 'chunked recovery duplicated reward or failed to apply')
assert(Client.RequestSnapshot())
Client.Update(15)
assert(Client.RequestSnapshot())
Client.Update(15)
Receive(Snapshot(10))
assert(snapshots == 4 and rewards == 1, 'old request timeout must not cancel a newer snapshot recovery')
-- Newer deltas depend on an incomplete inventory snapshot. Preserve their
-- order, discard duplicates and do not replay the snapshot's reward events.
local function ReceiveDelta(revision, changes, eventList)
    local delta = Schema.BuildDelta(revision, changes, { serverTime = 1791455000, state = state })
    delta.events = eventList or {}
    decoded = { delta = delta }
    events[Protocol.EVENTS.DELTA](nil, { [Protocol.FIELDS.PAYLOAD_JSON] = Variant('{}') })
end
local function ReceiveChunk(id, revision, index, base)
    decoded = { transferId = id, revision = revision, chunkIndex = index, chunkCount = 2,
        inventory = index == 1 and inventory or {}, snapshot = index == 1 and base or nil,
        events = index == 1 and { { type = 'battle_reward', gold = 1, exp = 1 } } or nil }
    events[Protocol.EVENTS.SNAPSHOT](nil, { [Protocol.FIELDS.PAYLOAD_JSON] = Variant('{}') })
end
local base = Snapshot(11); base.inventory = nil
ReceiveChunk('settlement:11', 11, 1, base)
ReceiveDelta(13, { exp = 3 }, { { type = 'battle_reward', gold = 1, exp = 1 } })
ReceiveDelta(12, { level = 2 })
ReceiveDelta(13, { exp = 3 }, { { type = 'battle_reward', gold = 1, exp = 1 } })
ReceiveChunk('old:10', 10, 2) -- late old transfer must not replace the active assembly
assert(Adapter.GetRevision() == 10, 'delta overtook an incomplete snapshot')
ReceiveChunk('settlement:11', 11, 2)
assert(Adapter.GetRevision() == 13 and Adapter.GetViewState().level == 2
    and Adapter.GetViewState().exp == 3, 'deferred deltas were lost or applied out of order')
assert(rewards == 3, 'snapshot or duplicate deferred delta replayed rewards')

-- A transfer with a missing chunk must expire while already connected. Drop
-- its queued patches and request a fresh complete state instead of blocking forever.
base = Snapshot(14); base.inventory = nil
ReceiveChunk('incomplete:14', 14, 1, base)
ReceiveDelta(15, { exp = 999 }, { { type = 'battle_reward', gold = 1, exp = 1 } })
Client.Update(30)
local latest = Snapshot(16); latest.exp = 5
Receive(latest)
assert(Adapter.GetRevision() == 16 and Adapter.GetViewState().exp == 5 and rewards == 4,
    'incomplete snapshot did not recover or replayed abandoned patches')

-- Duplicate completed transfers cannot block ordinary deltas. The bounded
-- backlog must request a fresh snapshot rather than grow indefinitely.
base = Snapshot(16); base.inventory = nil
ReceiveChunk('duplicate:16', 16, 1, base)
ReceiveDelta(17, { exp = 6 })
assert(Adapter.GetRevision() == 17, 'duplicate snapshot blocked later state')
base = Snapshot(18); base.inventory = nil
ReceiveChunk('backlog:18', 18, 1, base)
for revision = 19, 146 do ReceiveDelta(revision, { exp = revision }) end
Receive(Snapshot(147))
assert(Adapter.GetRevision() == 147 and rewards == 5, 'snapshot backlog did not recover cleanly')

-- An abandoned session must not replay its deferred rewards into a reconnect.
base = Snapshot(148); base.inventory = nil
ReceiveChunk('old-session:148', 148, 1, base)
ReceiveDelta(149, { exp = 999 }, { { type = 'battle_reward', gold = 1, exp = 1 } })
events['ServerDisconnected'](nil, {})
assert(Client.RetryConnection())
local restored = Snapshot(5); restored.exp = 2
Receive(restored)
assert(Adapter.GetRevision() == 5 and Adapter.GetViewState().exp == 2 and rewards == 6,
    'deferred state or rewards escaped into the reconnected session')
Client.Stop()
print('tower_snapshot_recovery: PASS')
