local Factory = require('server.domain.StateFactory')
local Activity = require('server.domain.ActivityEngine')
local Boss = require('server.domain.ChallengeEngine')
local Definitions = require('shared.ActivityDefinitions')
local Challenge = require('shared.ChallengeDefinitions')
local Schema = require('shared.GameStateSchema')
local Copy = require('server.domain.TableUtils').DeepCopy
local Large = require('shared.LargeNumber')
local now = 1791455000
local function Valid(p)
    assert(p.ok, p.error and p.error.reason)
    local ok, why = Schema.ValidateState(p.state); assert(ok, why)
    return p.state
end
local function Has(p, kind)
    for _, e in ipairs(p.delta.events) do if e.kind == kind then return e end end
end
-- Real elapsed seconds must work even if the process consumes no CPU.
os.clock = function() return 10 end
for _, id in ipairs({'act_daily_gold', 'act_daily_exp', 'act_daily_fragments'}) do
    local state = Factory.Create(now)
    state = Valid(Activity.BeginStrike(state, id, now))
    local repeated = Activity.BeginStrike(state, id, now + 1)
    state = Valid(repeated)
    assert(state.activities[id].strikeCount == 1 and state.activities[id].session.startedAt == now)
    state = Valid(Activity.Strike(state, id, now + 1))
    local damage = state.activities[id].session.damage
    assert(damage > 0)
    local fast = Activity.Strike(state, id, now + 1)
    assert(fast.commit.kind == 'none' and fast.state.activities[id].session.damage == damage)
    state = Valid(Activity.Strike(state, id, now + 3))
    assert(state.activities[id].session.damage > damage)
    local view = Definitions.BuildView(state, now + 10)
    for _, item in ipairs(view.strike) do
        if item.id == id then assert(item.sessionStartedAt == now and item.sessionRemaining == 5) end
    end
    local ended = Activity.Strike(state, id, now + 15)
    state = Valid(ended)
    assert(not state.activities[id].session and Has(ended, 'activity_claimed'))
    local duplicate = Activity.FinishStrike(state, id, now + 16)
    assert(duplicate.commit.kind == 'none' and not Has(duplicate, 'activity_claimed'))
    assert(not Activity.BeginStrike(state, id, now + 17).ok)
    local legacy = Factory.Create(now)
    legacy = Valid(Activity.BeginStrike(legacy, id, now))
    legacy.activities[id].session.startedAt = 10
    legacy.activities[id].session.lastHitAt = 10
    legacy = Valid(Activity.BeginStrike(legacy, id, now + 2))
    assert(legacy.activities[id].session.startedAt == now + 2 and legacy.activities[id].strikeCount == 1)
end
for _, grade in ipairs({'rift', 'mutated', 'calamity'}) do
    local state = Factory.Create(now)
    state.level = 40; state.abyss.tickets = 100000
    local tickets = state.abyss.tickets
    state = Valid(Boss.BeginBoss(state, grade, now))
    local session = Copy(state.challenges.bossSession)
    assert(state.abyss.tickets == tickets - session.ticketCost)
    local repeatBegin = Boss.BeginBoss(state, grade, now + 1)
    assert(repeatBegin.commit.kind == 'none' and repeatBegin.state.abyss.tickets == state.abyss.tickets)
    assert(not Boss.BeginBoss(state, grade == 'rift' and 'mutated' or 'rift', now + 1).ok)
    state = Valid(Boss.StrikeBoss(state, now + 1))
    assert(state.challenges.bossSession.damage > 0)
    assert(Boss.StrikeBoss(state, now + 1).commit.kind == 'none')
    local view = Challenge.BuildView(state, now + 8)
    assert(view.sessionStartedAt == now and view.sessionRunId == session.runId and view.remaining == 12)
    -- Force the last hit to test the complete transaction and event stream.
    state.challenges.bossSession.hp = 1
    local beforeRevision = state.revision
    local killed = Boss.StrikeBoss(state, now + 3)
    state = Valid(killed)
    assert(not state.challenges.bossSession and state.challenges.bossKills == 1)
    assert(Has(killed, 'abyss_boss_hit') and Has(killed, 'abyss_boss_finished').killed)
    assert(killed.delta.changes.challenges and state.revision == beforeRevision + 1)
    local repeatFinish = Boss.FinishBoss(state, now + 4)
    assert(repeatFinish.commit.kind == 'none' and repeatFinish.state.challenges.bossKills == 1)
    state = Valid(Boss.BeginBoss(state, grade, now + 5))
    local timeout = Boss.StrikeBoss(state, now + 25)
    state = Valid(timeout)
    assert(Has(timeout, 'abyss_boss_failed') and not state.challenges.bossSession)
    assert(state.challenges.bossKills == 1)
    local fragments = Copy(state.fragments)
    state = Valid(Boss.FinishBoss(state, now + 26))
    assert(Large.Compare(fragments, state.fragments) == 0)
end

-- A full bag on the lethal hit must roll the entire settlement back. A later
-- retry after freeing space must emit the last hit and pay exactly once.
local state = Factory.Create(now)
state.level = 40; state.abyss.tickets = 100000
state = Valid(Boss.BeginBoss(state, 'rift', now))
state.challenges.bossSession.hp = 1
state.abyss.dryStreak = require('shared.AbyssDefinitions').HARD_PITY_ATTEMPT - 1
state.inventoryPolicy.autoDecompose = false; state.inventoryPolicy.autoSell = false
local item = Copy(state.inventory[1])
while #state.inventory < require('server.domain.Catalog').GetInventoryCapacity(state) do
    local extra = Copy(item); extra.id = 'full-bag-' .. #state.inventory
    state.inventory[#state.inventory + 1] = extra
end
local before = Copy(state)
local failed = Boss.StrikeBoss(state, now + 1)
assert(not failed.ok and failed.error.code == 'INVENTORY_FULL')
assert(failed.state.challenges.bossSession.hp == before.challenges.bossSession.hp)
assert(failed.state.challenges.bossSession.damage == before.challenges.bossSession.damage)
assert(failed.state.abyss.tickets == before.abyss.tickets and Large.Compare(failed.state.fragments, before.fragments) == 0)
table.remove(state.inventory)
local retried = Boss.StrikeBoss(state, now + 2)
state = Valid(retried)
assert(state.challenges.bossKills == 1 and Has(retried, 'abyss_boss_hit'))
assert(Boss.FinishBoss(state, now + 3).commit.kind == 'none')

-- Independent combat pauses tower ticks, including ticks already in the queue.
local Runtime = require('server.services.IdleRuntimeService')
local realTime = os.time
os.time = function() return now end
local session = {generation = 1, state = {autoRun = true, activities = {}}}
local ticks, queued = 0, nil
local profile = {
    GetSession = function() return session end, IsOnline = function() return true end,
    GetState = function() return session.state end, OnlineUserIds = function() return {'p'} end,
    ApplyRuntime = function(_, _, _, _, cb)
        ticks = ticks + 1
        cb({ok = true, data = {state = session.state, delta = {events = {}}}})
    end,
}
local runtime = Runtime.New{profileService = profile, operationQueue = {
    Enqueue = function(_, _, fn) queued = fn end,
}}
runtime:_enqueueTick('p', 1)
session.state.activities.a = {session = {startedAt = now}}
queued(function() end); assert(ticks == 0 and not runtime.pending.p)
runtime:Update(1); assert(runtime.idlePlayers.p)
session.state.activities = {}
session.state.challenges = {bossSession = {startedAt = now}}
runtime:_enqueueTick('p', 1); queued(function() end); assert(ticks == 0)
now = now + Challenge.BOSS.DURATION
runtime:_enqueueTick('p', 1); queued(function() end); assert(ticks == 1)
session.state.challenges.bossSession = nil
runtime:_enqueueTick('p', 1); queued(function() end); assert(ticks == 2 and session.state.autoRun)
os.time = realTime
print('activity_battles: PASS')
