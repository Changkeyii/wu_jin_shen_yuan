local failures = {}
local function check(condition, message)
    if not condition then failures[#failures + 1] = message; print('FAIL: ' .. message) end
end

-- A settlement notification can fail after the authoritative state is committed.
-- The operation queue recovers, but the idle service must also release its token.
local Queue = require('server.core.OperationQueue')
local Runtime = require('server.services.IdleRuntimeService')
local session = { generation = 1, state = { autoRun = true } }
local ticks, errors = 0, 0
local profile = {
    GetSession = function() return session end,
    IsOnline = function() return true end,
    ApplyRuntime = function(_, _, _, _, callback)
        ticks = ticks + 1
        callback({ ok = true, data = { state = session.state,
            delta = { events = { { kind = 'battle_won' } } } } })
    end,
}
local queue = Queue.New()
local runtime = Runtime.New {
    operationQueue = queue, profileService = profile,
    onDelta = function() if ticks == 1 then error('injected settlement send failure') end end,
    onError = function() errors = errors + 1 end,
}
runtime:_enqueueTick('player', 1)
check(not queue:IsBusy('player'), 'operation queue must finish after a notification failure')
check(not runtime.pending.player, 'idle token leaked after settlement notification failure')
runtime:_enqueueTick('player', 1)
check(ticks == 2, 'next combat tick must run after notification failure')
check(errors == 0, 'recoverable notification failure must not disable the live connection')

-- Event-timeout notifications share the same asynchronous lifecycle.
local now = os.time()
session.state.pendingEvent = { eventId = 'expired', expiresAt = now - 1 }
profile.ApplyRuntime = function(_, _, _, _, callback)
    callback({ ok = true, data = { delta = { events = { { kind = 'event_resolved' } } } } })
end
runtime.onDelta = function() error('injected timeout send failure') end
runtime:_enqueueEventTimeout('event-player', session.state.pendingEvent)
check(not runtime.pending['event-player'], 'idle token leaked after event-timeout notification failure')
check(not queue:IsBusy('event-player'), 'event timeout queue must finish')
session.state.pendingEvent = nil

-- Exercise the real presentation and encounter controller without native widgets.
local world, lastFrame
package.loaded['client.PlayWorldView'] = { New = function()
    world = { Configure = function() end, Build = function() return {} end,
        Update = function(frame) lastFrame = frame end, Reset = function() end }
    return world
end }
package.loaded['client.PlayHud'] = { New = function() return {
    Configure = function() end, Build = function() return {} end,
    Update = function() end, Reset = function() end,
} end }
package.loaded['client.PlayEffects'] = { New = function() return setmetatable({
    Configure = function() end, BuildNodes = function() return {} end,
    GetLootDisplay = function() return '' end,
}, { __index = function() return function() end end }) end }
local widget = { GetLayout = function() return { w = 1080, h = 1400 } end,
    AddChild = function() end }
local Route = require('shared.FloorRoute')
local Big = require('shared.BigNumber')
local route = Route.Build(1)
local game = { page = 'play', floor = 1, position = 1, autoRun = true,
    revision = 1, floorRoute = route, currentMonster = { id = route.encounters[1].encounterId,
        hp = 0, maxHp = 100, phase = 'recovery', phaseRemaining = 0.2, sequenceIndex = 1 } }
local snapshots, requests = 0, 0
local encounterResponse = { ok = true }
local scene = require('client.PlayPresentation').New()
local colors = setmetatable({}, { __index = function() return {} end })
scene.Configure {
    getGame = function() return game end, UI = { Panel = function() return widget end },
    assets = { bg = 'bg', enemies = { goblin = 'g', skeleton = 's', slime = 's', boss = 'b' } },
    colors = colors, currentPlayer = function() return { attackFrames = { 'attack' } } end,
    getAttackParams = function() return {} end, getRunParams = function() return {} end,
    playerSize = 100, playerScreenX = 180, enemySize = 100, lootSize = 50, runH = 100,
    eventTriggerDistance = 120, presentationSpeed = 96,
    loadingController = { IsPlayAssetLoading = function() return false end },
    actionResult = function() end, updateTopBar = function() end,
    serverClient = {
        EnterEncounter = function(_, _, _, callback) requests = requests + 1; callback(encounterResponse) end,
        RequestSnapshot = function() snapshots = snapshots + 1 end,
    },
}
scene.BuildPage()
scene.HandleSnapshot()
scene.Update(0.1)
check(lastFrame.isAttacking, 'zero HP must keep the lock until authoritative recovery/settlement finishes')
scene.Update(20)
check(snapshots == 1, 'stalled authoritative battle must request a snapshot')
for _ = 1, 100 do scene.Update(0) end
check(snapshots == 1, 'snapshot watchdog must not flood requests per frame')

-- Death state arrived but the death animation handler was interrupted or omitted.
game.currentMonster = nil
game.revision = 2
local before = lastFrame.presentationX
scene.Update(0.1)
check(not lastFrame.isAttacking and lastFrame.visualAutoRun,
    'missing death event must not lock the next encounter')
check(lastFrame.roadEvents[1].room == 2 and lastFrame.presentationX > before,
    'death recovery must resume movement without skipping the next room')

-- A battle-start event can likewise be missed while state was already applied.
game.currentMonster = { id = route.encounters[2].encounterId, hpBig = Big.FromNumber(50),
    maxHpBig = Big.FromNumber(100), sequenceIndex = 1, phase = 'windup', phaseRemaining = 0.3 }
game.position, game.revision = 2, 3
scene.Update(0)
check(lastFrame.isAttacking, 'authoritative active monster must restore its combat presentation')
game.currentMonster = nil
game.revision = 4
scene.Update(0)
scene.Update(10)
scene.Update(0)
check(requests == 1, 'next encounter should be requested exactly once')
scene.HandleSnapshot()
scene.Update(0)
check(requests == 2, 'snapshot must re-arm an accepted request with missing battle state')

-- Repeated state-only deaths must make progress over a long挂机 session.
for room = 4, 9 do
    game.currentMonster = { id = route.encounters[room].encounterId,
        hp = 0, maxHp = 100, sequenceIndex = 1, phase = 'recovery', phaseRemaining = 0.2 }
    game.position, game.revision = room, game.revision + 1
    scene.HandleSnapshot()
    game.currentMonster = nil
    game.revision = game.revision + 1
    scene.Update(0.1)
    check(lastFrame.roadEvents[1].room == room + 1 and lastFrame.visualAutoRun,
        'state-only death stuck or skipped room ' .. room)
end
game.currentMonster = { id = route.encounters[10].encounterId,
    hp = 0, maxHp = 100, sequenceIndex = 1, phase = 'recovery', phaseRemaining = 0.2 }
game.position, game.revision = 10, game.revision + 1
scene.HandleSnapshot()
game.currentMonster, game.floor, game.position = nil, 2, 0
game.floorRoute, game.revision = Route.Build(2), game.revision + 1
scene.Update(0.1)
check(lastFrame.roadEvents[1].room == 1 and lastFrame.visualAutoRun and not lastFrame.isAttacking,
    'missing tenth-room boss death must resume at the first room of the next floor')
game.floor, game.floorRoute = 1, route
game.currentMonster = { id = route.encounters[9].encounterId,
    hp = 0, maxHp = 100, sequenceIndex = 4, phase = 'recovery', phaseRemaining = 0.2 }
game.position, game.autoRun = 9, false
local pausedSnapshots = snapshots
for _ = 1, 20 do scene.Update(1) end
check(not lastFrame.isAttacking and snapshots == pausedSnapshots, 'paused battle must not restart its finisher or watchdog')
game.readOnly, game.autoRun = true, true
local beforeSnapshots, beforeRequests = snapshots, requests
scene.Update(120)
check(snapshots == beforeSnapshots and requests == beforeRequests, 'disconnected view must not run recovery requests')

-- Currency/quest revisions cannot keep a dead battle's watchdog alive forever.
game.readOnly, game.autoRun = false, true
game.currentMonster.sequenceIndex = 1
scene.HandleSnapshot()
beforeSnapshots = snapshots
for _ = 1, 16 do
    game.revision = game.revision + 1
    scene.Update(1)
end
check(snapshots == beforeSnapshots + 1, 'unrelated revisions masked stalled zero-HP combat')

-- Real attack progress resets the watchdog, even at the same global revision.
scene.HandleSnapshot()
beforeSnapshots = snapshots
for _ = 1, 4 do
    game.currentMonster.attackSerial = (game.currentMonster.attackSerial or 0) + 1
    scene.Update(10)
end
check(snapshots == beforeSnapshots, 'active combat incorrectly triggered stall recovery')

-- Exhausted transient retries must recover through a snapshot, with no frame loop.
scene.Reset()
game.currentMonster, game.position = nil, 8
encounterResponse = { ok = false, code = 'REQUEST_TIMEOUT' }
scene.BuildPage()
scene.Update(10); scene.Update(0) -- reach room 9 and send request 1
scene.Update(2) -- request 2
scene.Update(4) -- request 3 exhausts retry budget
beforeSnapshots, beforeRequests = snapshots, requests
for _ = 1, 16 do game.revision = game.revision + 1; scene.Update(1) end
check(requests == beforeRequests, 'stopped requests retried without verified authoritative state')
check(snapshots > beforeSnapshots, 'exhausted retries were never included in snapshot recovery')
encounterResponse = { ok = true }
scene.HandleSnapshot(); scene.Update(0)
check(requests == beforeRequests + 1, 'authoritative recovery did not re-arm room 9')
assert(#failures == 0, table.concat(failures, '; '))
print('tower_idle_recovery: PASS')
