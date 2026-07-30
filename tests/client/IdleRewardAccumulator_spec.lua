local BigNumber = require("shared.BigNumber")
local IdleRewardAccumulator = require("client.IdleRewardAccumulator")

local Spec = {}

local function AssertBigEqual(actual, expected, message)
    local actualNumber = assert(BigNumber.ToNumber(actual))
    local expectedNumber = assert(BigNumber.ToNumber(expected))
    local tolerance = math.max(1, math.abs(expectedNumber)) * 1e-12
    assert(math.abs(actualNumber - expectedNumber) <= tolerance, message or "big number mismatch")
end

function Spec.Run()
    local summary = IdleRewardAccumulator.New()
    assert(not IdleRewardAccumulator.HasValue(summary))
    assert(IdleRewardAccumulator.IsRewardEvent("battle_reward"))
    assert(not IdleRewardAccumulator.IsRewardEvent("battle_won"))

    IdleRewardAccumulator.Accumulate(summary, {
        { kind = "battle_reward", gold = 12, exp = 7 },
        { kind = "battle_reward", gold = 8, exp = 3 },
        { kind = "chest_reward", gold = 5, fragments = 2 },
        { kind = "equipment_auto_disposed", gold = 4, fragments = 3 },
        { kind = "equipment_drop", itemId = "drop-1", name = "测试长剑", rarity = "epic" },
        { kind = "equipment_drop", itemId = "drop-1", name = "测试长剑", rarity = "epic" },
    })

    assert(IdleRewardAccumulator.HasValue(summary))
    AssertBigEqual(summary.gold, 29, "gold must aggregate across battles and disposal")
    AssertBigEqual(summary.exp, 10, "experience must aggregate across battles")
    AssertBigEqual(summary.fragments, 5, "fragments must aggregate across reward sources")
    assert(summary.battles == 2, "battle count must aggregate")
    assert(#summary.equipmentItems == 1, "duplicate equipment events must be deduplicated")

    local later = IdleRewardAccumulator.New()
    IdleRewardAccumulator.Accumulate(later, {
        { kind = "battle_reward", gold = 6, exp = 4 },
        { kind = "equipment_drop", itemId = "drop-2", name = "测试护甲", rarity = "myth" },
    })
    IdleRewardAccumulator.Merge(summary, later)

    AssertBigEqual(summary.gold, 35)
    AssertBigEqual(summary.exp, 14)
    assert(summary.battles == 3)
    assert(#summary.equipmentItems == 2, "separate settlement segments must merge")
end

return Spec
