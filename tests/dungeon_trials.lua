local Factory = require('server.domain.StateFactory')
local Normalizer = require('server.domain.StateNormalizer')
local Catalog = require('shared.DungeonCatalog')
local Engine = require('server.domain.DungeonEngine')
local Schema = require('shared.GameStateSchema')
local Large = require('shared.LargeNumber')
local Copy = require('shared.TableUtils').DeepCopy
local now = 1791630000
local state = Factory.Create(now)
state.tutorial.completed = true
state.level = 100
state = Normalizer.Normalize(state, now)
require('server.domain.PlayerTransition').RefreshDerived(state)
local session = {state = state, generation = 1}
local definition, response, failSave
local services = {profileService = {}, sendDelta = function() end}
function services.profileService:GetSession() return session end
function services.profileService:Apply(_, _, mutate, cb)
    local proposal = mutate(state, now)
    if not proposal.ok then cb({ok = false, code = proposal.error.code, reason = proposal.error.reason}); return end
    if failSave then failSave = false; cb({ok = false, code = 'SAVE_FAILED', reason = 'injected'}); return end
    assert(Schema.ValidateState(proposal.state))
    state, session.state = proposal.state, proposal.state
    cb({ok = true, data = {state = state, delta = proposal.delta}})
end
require('server.commands.CampaignTrialCommands').Register({Register = function(_, d) definition = d end}, services)
local function Call(action, id, trialId, page)
    response = nil
    definition.handler({uid = 'p'}, {action = action, stageId = id, trialId = trialId, page = page}, function(_, r) response = r end)
    return assert(response)
end
local id = 'dungeon:gold:1'
local prepared = Call('prepare', id).data
assert(prepared and prepared.pages <= 64)
assert(Call('prepare', id).data.trialId == prepared.trialId)
assert(not Call('prepare', 'dungeon:fragments:1').ok)
local runId = state.activities.act_daily_gold.session.dungeonRunId
assert(runId and Call('frames', id, prepared.trialId, 1).data.frames[1])
assert(not Call('finish', id, prepared.trialId).ok)
-- Restart/reconnect: the persisted reservation survives and another type cannot bypass it.
state = Normalizer.Normalize(Schema.ToPersistedState(state), now)
session = {state = state, generation = 2}
assert(not Call('prepare', 'dungeon:fragments:1').ok)
local resumed = Call('prepare', id).data
assert(resumed.trialId ~= prepared.trialId and state.activities.act_daily_gold.strikeCount == 1)
assert(state.activities.act_daily_gold.session.dungeonRunId == runId)
assert(not Call('finish', id, prepared.trialId).ok)
now = now + 100
local before = Copy(state)
failSave = true
assert(Call('finish', id, resumed.trialId).code == 'SAVE_FAILED')
assert(state.activities.act_daily_gold.session.dungeonRunId == runId and Large.Compare(state.gold, before.gold) == 0)
assert(Call('finish', id, resumed.trialId).data.won)
assert(Large.Compare(state.gold, before.gold) > 0)
local paid = Copy(state)
assert(Call('finish', id, resumed.trialId).ok and Large.Compare(state.gold, paid.gold) == 0)
assert(not state.activities.act_daily_gold.session and not Call('prepare', id).ok)
-- Old outcome cannot settle a next-day reservation, even for the same stage.
now = now + 86400
local nextTrial = Call('prepare', id).data
assert(nextTrial)
local stale = Engine.Settle(state, Catalog.GetStage(id), {won = true}, now, runId)
assert(not stale.ok and state.activities.act_daily_gold.session)
assert(Call('abort', id, nextTrial.trialId).ok)
assert(not state.activities.act_daily_gold.session and state.activities.act_daily_gold.strikeCount == 1)
local oldEntry = require('server.domain.AbyssEngine').EnterActivity(state, 'rift', now)
assert(oldEntry.ok and oldEntry.state.challenges.bossSession)
assert(oldEntry.state.abyss.equipmentDrops == state.abyss.equipmentDrops, 'old endpoint must not instantly grant loot')
print('dungeon_trials: PASS (commands, retry, persistence rollback, reconnect, stale reservation)')
