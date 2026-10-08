local BigNumber = require("shared.BigNumber")
local TowerRules = require("shared.TowerRules")

local Spec = {}

local function near(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.12g, got %.12g", label or "value", expected, actual))
end

function Spec.Run()
    near(TowerRules.GrowthNumber(1), 1, 1e-12, "floor 1 growth")
    near(TowerRules.GrowthNumber(10), 2 ^ (9 / 50), 1e-12, "floor 10 growth")
    near(TowerRules.GrowthNumber(50), 2 ^ (49 / 50), 1e-12, "floor 50 growth")
    near(TowerRules.GrowthNumber(100), 2 ^ (99 / 50), 1e-12, "floor 100 growth")
    near(TowerRules.DifficultyOffsetFloors(10), 0, 1e-12, "floor 10 offset")
    near(TowerRules.DifficultyOffsetFloors(30), 5, 1e-12, "floor 30 offset")
    near(TowerRules.DifficultyOffsetFloors(50), 10, 1e-12, "floor 50 offset")
    near(TowerRules.DifficultyOffsetFloors(1000), 10, 1e-12, "high floor offset")
    near(TowerRules.DifficultyGrowthNumber(100), 2 ^ (109 / 50), 1e-12,
        "floor 100 difficulty growth")
    near(TowerRules.RecommendedPowerNumber(100), 90000 * 2 ^ (109 / 50), 1e-6,
        "floor 100 recommended power")

    local floor5000 = TowerRules.Growth(5000)
    assert(floor5000.exponent == 30, "floor 5000 growth must use scientific representation")
    near(floor5000.mantissa, 1.2501984798, 1e-9, "floor 5000 mantissa")
    local highGrowth = TowerRules.Growth(100000)
    assert(highGrowth.exponent == 602)
    assert(TowerRules.GrowthNumber(100000) == nil, "unsafe native conversion must be rejected")
    local highRecommended = TowerRules.RecommendedPower(100000)
    assert(highRecommended.exponent == 607)

    local product = BigNumber.Multiply(
        BigNumber.New(2.5, 400), BigNumber.New(4, 250))
    assert(product.exponent == 651)
    near(product.mantissa, 1, 1e-12, "big multiplication")
    near(BigNumber.Ratio(BigNumber.New(4, 200), BigNumber.New(2, 200)), 2, 1e-12,
        "big ratio")

    local baseline = TowerRules.PlayerBaseline(1)
    assert(baseline.attack == 90 and baseline.defense == 85 and baseline.maxHp == 2200)
    assert(baseline.critRate == 0.10 and baseline.critDamage == 1.50)

    local chapterBoss = TowerRules.MonsterStats(1, "chapterBoss")
    assert(chapterBoss.hp == 1150 and chapterBoss.attack == 190 and chapterBoss.defense == 60)
    assert(chapterBoss.attackInterval == 1.5 and chapterBoss.regenerates == false)
    near(TowerRules.DamageAfterDefense(90, 60, 1), 56.25, 1e-12,
        "defense formula")

    for room = 1, 7 do assert(TowerRules.GetEncounter(room, 9).kind == "normal") end
    assert(TowerRules.GetEncounter(8, 9).kind == "elite")
    assert(TowerRules.GetEncounter(9, 9).kind == "elite")
    assert(TowerRules.GetEncounter(10, 9).kind == "boss")
    assert(TowerRules.GetEncounter(10, 10).kind == "chapterBoss")
    assert(TowerRules.GetEncounter(11, 10) == nil)

    local expectedWeights = { attackA = 2.00, attackB = 2.25, attackC = 2.00 }
    for _, id in ipairs(TowerRules.ATTACK_SEQUENCE_ORDER) do
        local sequence = TowerRules.AttackSequence(id)
        assert(#sequence.hits == 4 and #sequence.hitFrames == 4 and #sequence.weights == 4)
        near(sequence.totalWeight, expectedWeights[id], 1e-12, id .. " total weight")
        near(TowerRules.AttackDuration(id, 100), 0.8, 1e-12,
            id .. " presentation floor")
    end
end

return Spec
