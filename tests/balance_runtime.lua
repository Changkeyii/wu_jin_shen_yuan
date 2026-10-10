local Runtime = require('server.services.IdleRuntimeService')
local Queue = require('server.core.OperationQueue')
local Factory = require('server.domain.StateFactory')
local Progression = require('shared.GameProgression')
local Schema = require('shared.GameStateSchema')
local Normalizer = require('server.domain.StateNormalizer')
local Adventure = require('server.domain.AdventureEngine')
local Engine = require('server.domain.GameEngine')
local Big = require('shared.BigNumber')
local now = 1791630000
local clock = os.time
os.time = function() return now end
local state = Factory.Create(now)
state.tutorial.completed, state.autoRun, state.pendingStoryGate = true, true, nil
local session = {generation = 1, state = state}
local online, ticks, deltas = true, 0, 0
local profile = {
    GetSession = function() return session end,
    GetState = function() return state end,
    OnlineUserIds = function() return online and {'p'} or {} end,
    IsOnline = function() return online end,
    Apply = function() error('training must not add a cloud transaction') end,
    ApplyRuntime = function(_, _, _, mutate, cb)
        ticks = ticks + 1
        local proposal = mutate(state, now)
        assert(proposal.ok)
        state, session.state = proposal.state, proposal.state
        cb({ok = true, data = {state = state, delta = proposal.delta}})
    end,
}
local queue = Queue.New()
local runtime = Runtime.New{profileService = profile, operationQueue = queue,
    onDelta = function() deltas = deltas + 1 end}
local function Step(seconds)
    for _ = 1, seconds * 4 do now = now + 0.25; runtime:Update(0.25) end
end
local reference = Factory.Create(now)
Step(60) -- no currentMonster: walking time must still earn XP.
Progression.AddExperience(reference, Progression.TrainingExp(reference, 60), now)
assert(state.level == reference.level and state.exp == reference.exp and ticks == 12 and deltas > 0)
assert(state.level == 2 and not state.currentMonster)
state = Normalizer.Normalize(Schema.ToPersistedState(state), now); session.state = state
Step(100)
Progression.AddExperience(reference, Progression.TrainingExp(reference, 100), now)
assert(state.level == reference.level and state.exp == reference.exp)
state.autoRun = false
local xp, level, calls = state.exp, state.level, ticks
Step(20); assert(state.exp == xp and state.level == level and ticks == calls)
state.autoRun = true
session.campaignTrial = {expiresAt = now + 100}
Step(20); assert(state.exp == xp and ticks == calls)
session.campaignTrial = nil
Step(5)
Progression.AddExperience(reference, Progression.TrainingExp(reference, 5), now)
assert(state.exp == reference.exp, 'paused and independent-battle time must not leak into training')
online = false; runtime:Update(1)
assert(runtime.trainingElapsed.p == nil and runtime.elapsed.p == nil)
online = true
-- A queued old session cannot award time to a newly connected character.
local queued
runtime.operationQueue = {Enqueue = function(_, _, fn) queued = fn end}
Step(5); assert(queued)
session = {generation = 2, state = state}
queued(function() end)
assert(not runtime.pending.p and state.exp == reference.exp)
Step(5); queued(function() end)
Progression.AddExperience(reference, Progression.TrainingExp(reference, 5), now)
assert(state.exp == reference.exp, 'a new session must not inherit old queued training time')
runtime:Remove('p'); assert(runtime.trainingElapsed.p == nil)

local milestone = Factory.Create(now)
milestone.tutorial.completed, milestone.autoRun, milestone.pendingStoryGate = true, true, nil
milestone.level, milestone.exp = 19, Progression.NextExp(19) - 1
local originalTickets = milestone.abyss.tickets
local leveled = Engine.AdvanceCombatTick(milestone, nil, now, 5)
assert(leveled.state.level == 20 and milestone.abyss.tickets == originalTickets)
assert(leveled.state.abyss.tickets > originalTickets and leveled.delta.changed.abyss)

-- Two defeats before the cap retreat one floor and keep training enabled.
state = Factory.Create(now)
state.tutorial.completed, state.autoRun, state.pendingStoryGate = true, true, nil
state.level, state.floor, state.maxFloor = 10, 10, 10
state.floorDefeats = 1
local route = require('shared.FloorRoute').Build(10)
local encounter = route.encounters[1]
local entered = Adventure.EnterEncounter(state, {routeId = route.routeId, room = 1, encounterId = encounter.encounterId}, function() return 0.5 end, now)
assert(entered.ok and entered.state.currentMonster)
state = entered.state
state.stats.def, state.stats.defBig = 0, Big.Zero()
state.stats.hp, state.stats.hpBig, state.hp, state.hpBig = 1, Big.FromNumber(1), 1, Big.FromNumber(1)
state.currentMonster.nextMonsterAttackSeconds = 0
local lost = Engine.AdvanceCombatTick(state, function() return 0.99 end, now + 1, 0.1)
assert(lost.ok and lost.state.floor == 9 and lost.state.maxFloor == 10)
assert(lost.state.autoRun and not lost.state.aidPending and not lost.state.currentMonster)
os.time = clock
print('balance_runtime: PASS (walking XP, pause, cloud cadence, reconnect, retreat)')
