local Factory = require('server.domain.StateFactory')
local Profile = require('server.services.PlayerProfileService')
local Engine = require('server.domain.GameEngine')
local Route = require('shared.FloorRoute')
local Events = require('shared.GameEventSchema')
local Schema = require('shared.GameStateSchema')
local Large = require('shared.LargeNumber')
local now = 1791513000
local commands = {}
local profile = Profile.New { repository = {}, clock = function() return now end }
local deltas = {}
local timeoutState, timeoutEvent
require('server.commands.GameCommands').Register({Register = function(_, command) commands[command.name] = command end}, {
    profileService = profile, sendDelta = function(_, delta) deltas[#deltas + 1] = delta end,
})
local found = {}
for floor = 2, 9 do
    for _, encounter in ipairs(Route.Build(floor).encounters) do
        if encounter.kind == 'randomEvent' or encounter.kind == 'chest' or encounter.kind == 'merchant' then
            found[encounter.kind] = {floor = floor, encounter = encounter}
        end
    end
end
for kind, fixture in pairs(found) do
    for _, action in ipairs({kind == 'chest' and 'open' or kind == 'merchant' and 'buy' or 'accept', 'skip'}) do
        local state = Factory.Create(now)
        state.tutorial.completed = true
        state.pendingStoryGate = nil
        state.floor, state.maxFloor, state.position, state.autoRun = fixture.floor, fixture.floor, fixture.encounter.room - 1, true
        state.gold = Large.FromNumber(1000000000)
        profile.sessions[1] = {state = state, generation = 1}
        profile:ApplyRuntime(1, 'enter', function(s, time)
            return Engine.EnterEncounter(s, {routeId = Route.RouteId(s.floor), encounterId = fixture.encounter.encounterId, room = fixture.encounter.room}, nil, time)
        end, function(result)
            assert(result.ok, result.reason)
            local networkEvents, reason = Schema.CanonicalizeGameEvents(result.data.delta.events)
            assert(networkEvents, reason)
        end)
        local pending = assert(profile.sessions[1].state.pendingEvent)
        timeoutState = require('server.domain.TableUtils').DeepCopy(profile.sessions[1].state)
        timeoutEvent = timeoutState.pendingEvent
        local before = profile.sessions[1].state.fragments
        local completed
        commands['Game.ResolveEvent'].handler({uid = 1}, {eventId = pending.eventId, action = action}, function(ok, result)
            assert(ok, result.reason); completed = true
        end)
        assert(completed and not profile.sessions[1].state.pendingEvent, kind .. '/' .. action .. ': authoritative event must clear')
        local delta = deltas[#deltas]
        local networkEvents, reason = Schema.CanonicalizeGameEvents(delta.events)
        assert(networkEvents, reason)
        local valid = Events.ValidateList(networkEvents)
        assert(valid, reason)
        local balance = profile.sessions[1].state.fragments
        assert(Large.Compare(balance, before) >= 0)
        if action == 'skip' then assert(Large.Compare(balance, before) == 0) end
        commands['Game.ResolveEvent'].handler({uid = 1}, {eventId = pending.eventId, action = action}, function(ok) assert(ok) end)
        assert(Large.Compare(balance, profile.sessions[1].state.fragments) == 0, 'repeated decision cannot pay twice')
        local nextRoom = fixture.encounter.room + 1
        local nextEncounter = Route.GetEncounter(fixture.floor, nextRoom)
        local nextResult = Engine.EnterEncounter(profile.sessions[1].state, {
            routeId = Route.RouteId(fixture.floor), encounterId = nextEncounter.encounterId, room = nextRoom,
        }, function() return 0.99 end, now)
        assert(nextResult.ok and nextResult.state.position == nextRoom, 'tower advances after either decision')
    end
end
assert(found.randomEvent and found.chest and found.merchant)
-- Server expiry closes the event; a queued timeout for an old event cannot skip a new one.
local originalTime = os.time
os.time = function() return now + 1000 end
local queued, timeoutDelta, finished
profile.sessions[1] = {state = timeoutState, generation = 1, ready = true, connection = {}}
local runtime = require('server.services.IdleRuntimeService').New {
    profileService = profile,
    operationQueue = {Enqueue = function(_, _, job) queued = job end},
    onDelta = function(_, delta) timeoutDelta = delta end,
}
runtime:_enqueueEventTimeout(1, timeoutEvent)
local replacement = require('server.domain.TableUtils').DeepCopy(timeoutEvent)
replacement.eventId = 'ev.new'
timeoutState.pendingEvent = replacement
assert(queued); queued(function() finished = true end)
assert(finished and profile.sessions[1].state.pendingEvent == replacement and not timeoutDelta)
timeoutState.pendingEvent = timeoutEvent
runtime:_enqueueEventTimeout(1, timeoutEvent)
queued(function() end)
assert(not profile.sessions[1].state.pendingEvent and timeoutDelta.events[1].timedOut)
assert(Schema.CanonicalizeGameEvents(timeoutDelta.events))
os.time = originalTime
print('tower_events: PASS')
