local Factory = require("server.domain.StateFactory")
local Engine = require("server.domain.CampaignEngine")
local Catalog = require("shared.CampaignCatalog")
local Schema = require("shared.GameStateSchema")
local Big = require("shared.BigNumber")
local Large = require("shared.LargeNumber")
local Copy = require("server.domain.TableUtils").DeepCopy
local now = 1791455000
local state = Factory.Create(now)
state.tutorial.completed = true
local function Unlock(s)
    s.level = 100
    s.campaign.highestUnlockedChapter = 40
    for _, chapter in ipairs(Catalog.GetAllChapters()) do
        for _, stage in ipairs(chapter.stages) do s.campaign.completedStages[stage.id] = {
            clearCount = 1, bestStars = 3, firstClearClaimed = true, clearedAt = now,
        } end
    end
end
assert(Engine.PrepareTrial(state, "main:c01:b"), "same-level stages must allow direct selection")
assert(not Engine.PrepareTrial(state, "main:c40:b"), "higher-level stages must remain locked")
assert(not Engine.PlayStage(state, "main:c01:a", "complete", now).ok, "first section must also require combat")
local openingReport, openingOutcome = Engine.PrepareTrial(state, "main:c01:a", function() return 0.5 end)
assert(openingReport and openingOutcome.won)
state = Engine.SettleTrial(state, "main:c01:a", openingOutcome, now).state
assert(not Engine.PlayStage(state, "main:c01:b", "challenge", now).ok, "old instant-reward path must be closed")
local before = Copy(state)
local report, outcome = Engine.PrepareTrial(state, "main:c01:b", function() return 0.5 end)
assert(report and report.waves == 3 and outcome.won)
assert(state.floor == before.floor and state.position == before.position and Large.Compare(state.gold, before.gold) == 0)
assert(not state.campaign.completedStages['main:c01:b'], "preparation must not grant rewards")
local lastTime, hits, attacks, spawned = -1, 0, 0, 0
for _, frame in ipairs(report.frames) do
    assert(frame.t >= lastTime); lastTime = frame.t
    if frame.kind == "attack_started" then attacks = attacks + 1; assert(frame.sequenceIndex and frame.hitFrame) end
    if frame.kind == "battle_hit" then hits = hits + 1; assert(frame.damageBig and frame.monsterHpBig) end
    if frame.kind == "battle_started" then spawned = spawned + 1 end
end
assert(attacks > 0 and hits > 0 and spawned == 3)
local settled = Engine.SettleTrial(state, 'main:c01:b', outcome, now + 100)
assert(settled.ok and settled.state.campaign.completedStages['main:c01:b'])
local valid, why = Schema.ValidateState(settled.state); assert(valid, why)
local boss = assert(Engine.PrepareTrial(settled.state, 'main:c01:c', function() return 0.5 end))
assert(boss.waves == 4)
local names = {}
for _, frame in ipairs(boss.frames) do if frame.kind == 'battle_started' then names[#names + 1] = frame.name end end
assert(#names == 4 and names[4] == '缄默守门人')
local weak = Copy(state); Unlock(weak)
weak.stats.atk = 1; weak.stats.atkBig = Big.FromNumber(1)
weak.stats.def = 0; weak.stats.defBig = Big.Zero()
weak.stats.hp = 1; weak.stats.hpBig = Big.FromNumber(1)
local lost, losing = Engine.PrepareTrial(weak, 'main:c40:c', function() return 0.99 end)
assert(not losing.won and lost.frames[#lost.frames].kind == 'player_died')
assert(Engine.SettleTrial(weak, 'main:c40:c', losing, now).commit.kind == 'none')
-- Every chapter's battle remains valid, including all mechanic variations.
local all = Copy(state); Unlock(all)
for _, chapter in ipairs(Catalog.GetAllChapters()) do
    for _, stage in ipairs(chapter.stages) do
        if stage.kind ~= 'story' then
            local r = assert(Engine.PrepareTrial(all, stage.id, function() return 0.5 end))
            assert(r.duration <= r.limit + 0.001 and #r.frames > 0)
        end
    end
end

-- Exercise actual command handlers, with the persistence and transport ports replaced.
local definition, session, response
session = { state = state, generation = 5 }
local sent = 0
local services = { sendDelta = function() sent = sent + 1 end, profileService = {} }
function services.profileService:GetSession() return session end
function services.profileService:Apply(_, _, mutate, callback)
    local proposal = mutate(session.state, now)
    if not proposal.ok then callback({ ok = false, code = proposal.error.code, reason = proposal.error.reason }); return end
    local ok, err = Schema.ValidateState(proposal.state); assert(ok, err)
    if proposal.commit.kind ~= 'none' then session.state = proposal.state end
    callback({ ok = true, data = { delta = proposal.delta, state = session.state } })
end
require('server.commands.CampaignTrialCommands').Register({ Register = function(_, d) definition = d end }, services)
local function Call(action, trialId, page)
    response = nil
    definition.handler({ uid = 'test' }, { action = action, stageId = 'main:c01:b', trialId = trialId, page = page },
        function(ok, result) response = result end)
    return assert(response)
end
local prepared = Call('prepare').data
assert(Call('prepare').data.trialId == prepared.trialId, 'lost preparation response must reuse trial')
local frames = Call('frames', prepared.trialId, 1).data.frames
assert(#frames > 0 and #frames <= 80)
assert(Call('finish', prepared.trialId).code == 'CAMPAIGN_BATTLE_RUNNING')
assert(not Call('finish', 'forged').ok)
now = now + 200
assert(Call('finish', prepared.trialId).data.won)
local gold = Copy(session.state.gold)
assert(Call('finish', prepared.trialId).data.won)
assert(Large.Compare(gold, session.state.gold) == 0 and session.state.campaign.completedStages['main:c01:b'].clearCount == 1)
local nextTrial = Call('prepare').data.trialId
assert(nextTrial ~= prepared.trialId)
assert(Call('abort', nextTrial).ok)
assert(not Call('finish', nextTrial).ok)
local expiredTrial = Call('prepare').data.trialId
now = now + 901
assert(Call('prepare').data.trialId ~= expiredTrial, 'expired preparation must be replaced so retry can complete')
print('campaign_trials: PASS')
