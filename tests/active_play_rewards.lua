local Factory = require('server.domain.StateFactory')
local Normalize = require('server.domain.StateNormalizer')
local Dungeon = require('server.domain.DungeonEngine')
local Catalog = require('shared.DungeonCatalog')
local Campaign = require('shared.CampaignCatalog')
local Claims = require('server.domain.RewardClaimEngine')
local Progression = require('shared.GameProgression')
local Balance = require('shared.GameBalance')
local Preview = require('shared.ActivityDefinitions').RewardPreview
local Tables = require('shared.TableUtils')
local Schema = require('shared.GameStateSchema')
local Large = require('shared.LargeNumber')
local now = 1791630000
for _, kind in ipairs(Catalog.ORDER) do
    for tier = 1, 3 do
        local stage = Catalog.GetStage('dungeon:' .. kind .. ':' .. tier)
        local state = Factory.Create(now); state.level = stage.recommendedLevel
        state = Normalize.Normalize(state, now)
        local reserved = Dungeon.Reserve(state, stage, now)
        assert(reserved.ok)
        local expected = Tables.DeepCopy(reserved.state)
        local reward = Preview(stage.reward, stage.recommendedLevel)
        assert(reward.exp >= Balance.BattleExp(stage.recommendedLevel) * 15)
        Progression.AddExperience(expected, reward.exp, now)
        local settled = Dungeon.Settle(reserved.state, stage, {won = true}, now)
        assert(settled.ok and settled.state.level == expected.level and settled.state.exp == expected.exp)
        assert(Schema.ValidateState(settled.state))
        local duplicate = Dungeon.Settle(settled.state, stage, {won = true}, now)
        assert(duplicate.commit.kind == 'none' and duplicate.state.exp == settled.state.exp)
        local failed = Dungeon.Settle(reserved.state, stage, {won = false}, now)
        assert(failed.state.level == reserved.state.level and failed.state.exp == reserved.state.exp)
    end
end
local state = Factory.Create(now)
local stage = Campaign.GetStage('main:c20:c')
assert(stage.exp >= Balance.BattleExp(stage.recommendedLevel) * 30)
local offer = Claims.CreateAdOffer(state, {source = 'campaign', sourceKey = stage.id,
    baseReward = {exp = stage.exp, gold = Large.FromNumber(stage.gold), fragments = stage.fragments}}, now)
assert(offer and offer.extraReward.exp == stage.exp * 4)
local expected = Tables.DeepCopy(state)
Progression.AddExperience(expected, offer.extraReward.exp, now)
local paid = Claims.ClaimAdExtra(state, offer.id, now)
assert(paid.ok and paid.state.level == expected.level and paid.state.exp == expected.exp)
local twice = Claims.ClaimAdExtra(paid.state, offer.id, now)
assert(twice.state.exp == paid.state.exp and twice.state.level == paid.state.level)

-- Existing quotes remain frozen, including old zero-XP campaign ads.
offer.baseReward.exp, offer.extraReward.exp = 0, 0
local old = Claims.CreateAdOffer(state, {source = 'campaign', sourceKey = stage.id,
    baseReward = {exp = 1000000, gold = Large.FromNumber(stage.gold)}}, now)
assert(old == offer and old.extraReward.exp == 0)
local milestone = Claims.CreateAdOffer(state, {source = 'floor_milestone', sourceKey = 'floor:50',
    baseReward = {gold = Large.FromNumber(100), exp = 1000000, abyssTickets = 1000000}}, now)
assert(milestone.extraReward.exp == 0 and milestone.extraReward.abyssTickets == 0)
print('active_play_rewards: PASS (nine tiers, XP persistence, failure, duplicate, frozen ads, milestone limits)')
