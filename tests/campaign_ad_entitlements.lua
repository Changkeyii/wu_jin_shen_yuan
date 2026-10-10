local Factory = require('server.domain.StateFactory')
local Campaign = require('server.domain.CampaignEngine')
local Catalog = require('shared.CampaignCatalog')
local Claims = require('server.domain.RewardClaimEngine')
local Schema = require('shared.GameStateSchema')
local Events = require('shared.GameEventSchema')
local Large = require('shared.LargeNumber')
local now = os.time()
local state = Factory.Create(now)
state.tutorial.completed = true
-- Existing non-campaign offers keep their previous 50-entry overflow policy.
for i = 1, 50 do
    assert(Claims.CreateAdOffer(state, { source = 'floor_milestone', sourceKey = 'floor:' .. (i * 50),
        baseReward = { gold = Large.FromNumber(1) } }, now))
end
local seen, count, firstId = {}, 0, nil
for _, chapter in ipairs(Catalog.GetAllChapters()) do
    assert(chapter.stages[1].kind == 'battle' and chapter.stages[1].enemy)
    assert(not Campaign.PlayStage(state, chapter.stages[1].id, 'complete', now).ok)
    for _, stage in ipairs(chapter.stages) do
        local settled = Campaign.SettleTrial(state, stage.id, { won = true, stars = 3, elapsed = 10 }, now)
        assert(settled.ok)
        local offer
        for _, event in ipairs(settled.delta.events) do
            if event.kind == 'reward_offer_pending' and event.source == 'campaign' then
                assert(not offer, 'exactly one campaign entitlement per first clear')
                offer = event; event.type = event.kind
                local ok, why = Events.Validate(event); assert(ok, why)
            end
        end
        if stage.stage == 'c' then
            assert(offer and not seen[offer.rewardId], 'only chapter finale offers fivefold')
            assert(Large.Compare(offer.baseReward.gold, stage.gold) == 0)
            assert(offer.baseReward.exp == stage.exp and offer.baseReward.abyssTickets == 0)
            assert(offer.extraReward.exp == stage.exp * 4)
            assert(offer.baseReward.fragments == stage.fragments)
            assert(Large.Compare(offer.extraReward.gold, stage.gold * 4) == 0)
            seen[offer.rewardId] = true; firstId = firstId or offer.rewardId; count = count + 1
        else assert(not offer, 'ordinary stages must not advertise fivefold') end
        state = settled.state
        local replay = Campaign.SettleTrial(state, stage.id, { won = true, stars = 3, elapsed = 10 }, now)
        assert(Large.Compare(replay.state.gold, state.gold) == 0)
        for _, event in ipairs(replay.delta.events) do assert(event.kind ~= 'reward_offer_pending') end
    end
end
assert(count == 40 and #state.rewardClaims.pending == 90)
local snapshot = Schema.BuildSnapshot(state)
local delta = Schema.BuildDelta(state.revision, { rewardClaims = state.rewardClaims })
assert(#snapshot.rewardClaims.pending == 51 and #delta.changes.rewardClaims.pending == 51)
assert(#state.rewardClaims.pending == 90, 'network projection must preserve historical entitlements on the server')
local ok, why = Schema.ValidateState(state); assert(ok, why)
local claimed = Claims.ClaimAdExtra(state, firstId, now)
assert(claimed.ok and #claimed.state.rewardClaims.pending == 89)
assert(Large.Compare(Claims.ClaimAdExtra(claimed.state, firstId, now).state.gold, claimed.state.gold) == 0)
for _, event in ipairs(claimed.delta.events) do
    if event.kind == 'reward_ad_extra_claimed' then
        event.type = event.kind
        local valid, reason = Events.Validate(event); assert(valid, reason)
        assert(Large.Compare(event.totalReward.gold, Catalog.GetStage('main:c01:c').gold * 5) == 0)
        assert(event.totalReward.exp == Catalog.GetStage('main:c01:c').exp * 5)
    end
end
print('campaign_ad_entitlements: PASS (40 chapter finales + 50 milestone offers)')
