local Balance = require("shared.GameBalance")
local Progression = require("shared.GameProgression")
local Factory = require("server.domain.StateFactory")
local Normalizer = require("server.domain.StateNormalizer")
local Transition = require("server.domain.PlayerTransition")
local Catalog = require("server.domain.Catalog")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local Big = require("shared.BigNumber")
local Large = require("shared.LargeNumber")
local Schema = require("shared.GameStateSchema")
local Trials = require("server.domain.CampaignEngine")
local Dungeons = require("shared.DungeonCatalog")
local DungeonEngine = require("server.domain.DungeonEngine")
local Abyss = require("shared.AbyssDefinitions")
local Challenge = require("server.domain.ChallengeEngine")
local RewardEngine = require("server.domain.RewardEngine")
local Copy = require("shared.TableUtils").DeepCopy
local now = 1791630000

local function validate(state)
    local ok, why = Schema.ValidateState(state)
    assert(ok, tostring(why and why.reason) .. " " .. tostring(why and why.details and why.details.path))
end

local function loadout(level, setId, rarity, enhance, star)
    local state = Factory.Create(now)
    state.tutorial.completed = true
    state.pendingStoryGate = nil
    state.level, state.floor, state.maxFloor = level, level, level
    state.inventory, state.equipped = {}, {}
    for _, def in ipairs(EquipmentCatalog.GetAll()) do
        if def.setId == setId then
            local item = { id = "balance:" .. def.slot, equipmentId = def.id, level = Progression.EquipmentLevel(level),
                rarity = rarity, enhance = enhance or 0, star = star or 0, source = "balance", setEnabled = true,
                investedGold = Large.Zero(), investedFragments = 0 }
            Catalog.ApplyEquipmentDefinition(item, def)
            item.rarity = rarity
            for key, value in pairs(Catalog.CreateItemStats(def, item.level, rarity, 1, 0, 0)) do item[key] = value end
            state.inventory[#state.inventory + 1] = item
            state.equipped[def.slot] = item.id
        end
    end
    state = Normalizer.Normalize(state, now)
    Transition.RefreshDerived(state)
    state.hpBig, state.hp = Big.Clone(state.stats.hpBig), state.stats.hp
    validate(state)
    return state
end

-- Exact pacing under tiny runtime ticks, batched offline ticks, and save/reconnect.
local seconds = 0
for level = 1, 99 do seconds = seconds + Balance.LevelSeconds(level) end
assert(math.abs(seconds - 86400) < 0.00001)
for _, offline in ipairs({ false, true }) do
    local state = Factory.Create(now)
    for tick = 1, 8640 do
        local xp = Progression.TrainingExp(state, 10, offline)
        Progression.AddExperience(state, xp, now + tick * 10)
        if tick % 100 == 0 then state = Normalizer.Normalize(Schema.ToPersistedState(state), now + tick * 10) end
        if tick == 8639 then assert(state.level < 100) end
    end
    assert(state.level == 100, "24 hours must reach level 100")
    validate(state)
end

-- Old experience percentage and invested resources survive; migrations cannot compound.
local old = loadout(80, "nightmare", "epic", 10, 3)
old.schemaVersion, old.growth.version = 11, 1
old.exp = math.floor(math.floor(100 * 1.15 ^ 79) * 0.5)
local expectedAtk = Big.Clone(old.inventory[1].atkBig)
local oldToNew = 2 ^ ((Progression.EquipmentLevel(80) - 1) / 50)
for _, item in ipairs(old.inventory) do
    item.statVersion = 5
    for _, field in ipairs({'atk', 'def', 'hp', 'budget'}) do
        item[field .. 'Big'] = Big.MultiplyScalar(item[field .. 'Big'], 1 / oldToNew)
        item[field] = Big.ToNumber(item[field .. 'Big'])
    end
end
local migrated = Normalizer.Normalize(old, now)
assert(migrated.level == 80 and math.abs(migrated.exp / Progression.NextExp(80) - 0.5) < 0.01)
assert(math.abs(Big.Ratio(migrated.inventory[1].atkBig, expectedAtk) - 1) < 0.00000001)
local repeated = Normalizer.Normalize(Schema.ToPersistedState(migrated), now)
assert(Big.Compare(migrated.inventory[1].atkBig, repeated.inventory[1].atkBig) == 0)
assert(migrated.inventory[1].enhance == 10 and migrated.inventory[1].star == 3)
validate(repeated)

-- Twenty tiers strictly improve stats, with no infinite reward reference.
for _, setId in ipairs(Catalog.SET_ORDER) do
    local previous = 0
    for level = 5, 100, 5 do
        local state = loadout(level, setId, "epic", 0, 0)
        assert(state.stats.atk > previous * 1.1)
        previous = state.stats.atk
    end
    local state = loadout(100, setId, "epic", 10, 3)
    local evaluated = require("shared.PowerEvaluator").EvaluateActualFloor(state.stats, 150)
    print("balance final150", setId, evaluated.routeSurvives, evaluated.boss.ttk, evaluated.bossSurvivalMargin)
    assert(evaluated.routeSurvives, "endgame loadout must survive the floor 150 route")
end
assert(Large.Compare(Catalog.GetBattleGold(100), Catalog.GetBattleGold(1000000)) == 0)
assert(Large.Compare(require("shared.QuestDefinitions").EconomyValue(100, 22000), Catalog.GetBattleGold(100)) == 0)
local totalGold, totalFragments = Large.Zero(), 0
local state = loadout(100, "nightmare", "epic", 0, 0)
for enhance = 0, 19 do
    local cost = Catalog.GetStrengthenCost(state.inventory[1], enhance)
    totalGold, totalFragments = Large.Add(totalGold, cost.gold), totalFragments + cost.fragments
end
print("balance enhance20", Large.Format(totalGold), totalFragments)
assert(totalFragments >= 1500 and totalFragments <= 3000)

-- Exercise the actual frozen offline ledger, including fractional XP across two claims.
local offline = Factory.Create(now)
offline.tutorial.completed = true
for half = 1, 2 do
    offline.pendingOfflineSeconds = 43200
    local ledger = assert(RewardEngine.FreezeOfflineReward(offline, now + half * 43200, function() return 0.99 end))
    offline = RewardEngine.ClaimOfflineReward(offline, ledger, now + half * 43200).state
    offline = Normalizer.Normalize(Schema.ToPersistedState(offline), now + half * 43200)
    validate(offline)
end
assert(offline.level == 100, '24 cumulative offline hours must survive freeze/claim/reconnect rounding')

-- Strengthening then selling/decomposing cannot pay for its own investment.
for level = 5, 100, 5 do
    for _, rarity in ipairs(Catalog.RARITY_ORDER) do
        local item = Copy(state.inventory[1])
        item.level, item.rarity, item.roll = level, rarity, 1.05
        item.coreAffixes = {'atk', 'def', 'hp'}
        for star = 0, 5 do
            item.star = star
            for enhance = 0, 19 do
                item.enhance, item.investedGold = enhance, Large.Zero()
                local cost = Catalog.GetStrengthenCost(item, enhance)
                local before = Catalog.GetSellValue(item, 10)
                item.enhance, item.investedGold = enhance + 1, cost.gold
                local after = Catalog.GetSellValue(item, 10)
                local gain = Large.Subtract(after, before)
                if rarity ~= 'myth' then assert(Large.Compare(gain, cost.gold) < 0, 'sell arbitrage: ' .. rarity .. ':' .. star .. ':' .. enhance) end
                local refund = Catalog.GetDecomposeRefund(item, 10)
                item.enhance, item.investedGold = enhance, Large.Zero()
                local baseline = Catalog.GetDecomposeRefund(item, 10)
                local extra = Large.Subtract(refund.gold, baseline.gold)
                assert(Large.Compare(extra, cost.gold) < 0)
            end
        end
    end
end

-- All nine trials use actual tower combat and fixed tier rewards; retries cannot mint rewards.
for _, kind in ipairs(Dungeons.ORDER) do
    for tier = 1, 3 do
        local stage = Dungeons.GetStage("dungeon:" .. kind .. ":" .. tier)
        local state = loadout(stage.recommendedLevel, "nightmare", tier == 3 and "epic" or "rare", tier == 3 and 8 or 0, tier == 3 and 2 or 0)
        local report, outcome = Trials.PrepareTrial(state, stage.id, function() return 0.5 end)
        assert(report and report.waves == stage.waves)
        print("balance dungeon", stage.id, outcome.won, report.duration, report.waves)
        assert(outcome.won, "reference loadout must clear " .. stage.id)
        local reserved = DungeonEngine.Reserve(state, stage, now)
        assert(reserved.ok)
        validate(reserved.state)
        local repeatBegin = DungeonEngine.Reserve(reserved.state, stage, now + 1)
        assert(repeatBegin.ok and repeatBegin.state.activities[stage.activityId].strikeCount == 1)
        assert(not require("server.domain.ActivityEngine").FinishStrike(reserved.state, stage.activityId, now + 100).ok)
        local settled = DungeonEngine.Settle(reserved.state, stage, outcome, now + 100)
        validate(settled.state)
        local duplicate = DungeonEngine.Settle(settled.state, stage, outcome, now + 101)
        assert(duplicate.commit.kind == "none" and Large.Compare(duplicate.state.gold, settled.state.gold) == 0)
        assert(not DungeonEngine.Reserve(settled.state, stage, now + 102).ok)
    end
end

-- Boss difficulty is tied to level/grade, never attack or the highest tower floor.
for _, grade in ipairs(Abyss.ORDER) do
    local weak = loadout(100, "nightmare", "rare", 0, 0)
    local strong = loadout(100, "nightmare", "epic", 10, 3)
    assert(Challenge.ComputeBossHp(weak, grade) == Challenge.ComputeBossHp(strong, grade))
    local min, max = Abyss.EquipmentLevelPool(100)
    assert(min == 100 and max == 100)
    weak.maxFloor = 1000000
    assert(Abyss.DropPoolFloor(weak) == 100 and Abyss.TicketCost(100, grade) == Abyss.TicketCost(1000000, grade))
end
local endgame = loadout(100, "nightmare", "epic", 10, 3)
endgame.abyss.tickets = 100000
endgame.abyss.mythMisses = 39
local begin = Challenge.BeginBoss(endgame, "calamity", now, "prophecy")
assert(begin.ok and begin.state.challenges.bossSession.setId == "prophecy")
begin.state.challenges.bossSession.hp = 0
local result = Challenge.FinishBoss(begin.state, now + 20)
assert(result.ok)
local found
for _, item in ipairs(result.state.inventory) do
    if item.source == "abyss_activity" then found = item end
end
assert(found and found.setId == "prophecy" and found.rarity == "myth" and found.level == 100)
validate(result.state)
print("balance_alignment: PASS")
