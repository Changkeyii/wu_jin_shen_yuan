local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local Balance = {}

Balance.VERSION = 2
Balance.MAX_LEVEL = 100
Balance.TRAINING_SECONDS = 86400
Balance.OFFLINE_RATE = 0.10
Balance.ENHANCE_LIMIT = 20
Balance.BATTLE_GOLD_BASE = 22000

function Balance.Level(value)
    value = tonumber(value) or 1
    if value ~= value or math.abs(value) == math.huge then value = 1 end
    return math.max(1, math.min(100, math.floor(value)))
end

-- The 99 level intervals sum to 24 hours. Early tiers unlock sooner.
function Balance.LevelSeconds(level)
    return 60 + (Balance.Level(level) - 1) * (86400 - 99 * 60) / 4851
end

function Balance.NextExp(level)
    level = Balance.Level(level)
    return level < 100 and (100 + level * 20) or 0
end

function Balance.EquipmentGrowth(level)
    return BigNumber.FromLog10((Balance.Level(level) - 1) / 25 * math.log(2) / math.log(10))
end

function Balance.TowerGrowthLog10(floor)
    floor = tonumber(floor) or 1
    if floor ~= floor or math.abs(floor) == math.huge then floor = 1 end
    return ((math.min(floor, 100) - 1) / 25 + math.max(0, floor - 100) / 50)
        * math.log(2) / math.log(10)
end

function Balance.RewardLevel(state)
    return Balance.Level(type(state) == "table" and state.level or state)
end

-- Fixed equipment economy; exploration beyond 100 cannot inflate currency forever.
function Balance.EconomyValue(level, scalar)
    return Balance.LegacyEconomyValue(Balance.Level(level), scalar)
end

-- Historical equipment keeps its saved economic basis, including levels above 100.
function Balance.LegacyEconomyValue(level, scalar)
    level = math.max(1, math.min(1000000, math.floor(tonumber(level) or 1)))
    scalar = math.max(0, tonumber(scalar) or 0)
    if scalar == 0 then return LargeNumber.Zero() end
    local logarithm = math.log(1 + level / 100) / math.log(10) * 5.1
        + math.log(scalar) / math.log(10)
    return LargeNumber.FromBigNumber(BigNumber.Floor(BigNumber.FromLog10(logarithm)))
end

function Balance.BattleExp(level)
    -- Supplemental quests, sign-in and trials: twelve seconds of training per scene.
    level = Balance.Level(level)
    local reference = math.min(99, level)
    return math.max(1, math.floor(Balance.NextExp(reference) / Balance.LevelSeconds(reference) * 12))
end

function Balance.TrialGrowth(level)
    return BigNumber.ToNumber(Balance.EquipmentGrowth(level)) or 1
end

function Balance.StrikeTarget(level, tier)
    return math.floor(90 * Balance.TrialGrowth(level) * (tier == 2 and 8 or 16))
end

return Balance
