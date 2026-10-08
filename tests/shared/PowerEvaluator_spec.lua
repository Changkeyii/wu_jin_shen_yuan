local BigNumber = require("shared.BigNumber")
local PowerEvaluator = require("shared.PowerEvaluator")
local TowerRules = require("shared.TowerRules")

local Spec = {}

local function near(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.12g, got %.12g", label or "value", expected, actual))
end

local function copy(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

function Spec.Run()
    for _, floor in ipairs({ 1, 10, 50, 100, 5000 }) do
        local stats = TowerRules.PlayerBaseline(floor)
        local atFloor = PowerEvaluator.EvaluateAtFloor(stats, floor)
        near(atFloor.towerScore, 1, 1e-9, "baseline TowerScore at floor " .. floor)
        near(atFloor.bossScore, 1, 1e-9, "baseline BossScore at floor " .. floor)
        near(atFloor.eliteScore, 1, 1e-9, "baseline EliteScore at floor " .. floor)
        assert(atFloor.routeSurvives, "recommended baseline must clear its route")

        local evaluated = PowerEvaluator.Evaluate(stats, { floor = floor })
        near(evaluated.equivalentFloor, floor, 1e-7,
            "equivalent floor at baseline " .. floor)
        near(evaluated.powerRatio, 1, 1e-8, "power ratio at baseline " .. floor)
        assert(BigNumber.Compare(evaluated.displayedPower, evaluated.recommendedPower) == 0
            or math.abs(BigNumber.LogRatio(evaluated.displayedPower, evaluated.recommendedPower)) < 1e-9)
    end

    local baseline = TowerRules.PlayerBaseline(1)
    local combat = PowerEvaluator.EvaluateAtFloor(baseline, 1)
    near(combat.normal.meanTtk, 170 / (90 * 1.05 * 100 / 120), 1e-9,
        "normal mean TTK")
    near(combat.elite.meanTtk, 6, 1e-9, "elite mean TTK")
    near(combat.boss.meanTtk, 1150 / (90 * 1.05 * 100 / 160), 1e-9,
        "chapter boss mean TTK")
    assert(combat.boss.ttk > combat.boss.meanTtk,
        "20th-percentile safe DPS must be below mean DPS")
    assert(#combat.boss.distribution.sequences == 3)
    for _, sequence in ipairs(combat.boss.distribution.sequences) do
        assert(sequence.totalWeight >= 2, "all configured multi-hits must be included")
    end

    local lifesteal = copy(baseline)
    lifesteal.lifeSteal = 1
    local lifestealBoss = PowerEvaluator.EvaluateAtFloor(lifesteal, 1).boss
    assert(lifestealBoss.hps <= lifesteal.maxHp * 0.03 + 1e-9)
    assert(lifestealBoss.hps <= lifestealBoss.incomingDps * 0.50 + 1e-9)
    assert(lifestealBoss.ehp >= lifestealBoss.ehp0)

    local reduced = copy(baseline)
    reduced.damageReduction = 0.99
    local reducedBoss = PowerEvaluator.EvaluateAtFloor(reduced, 1).boss
    near(reducedBoss.incomingHitMultiplier, 100 / 185 * 0.30, 1e-12,
        "70 percent reduction cap")

    local fixedLoadout = TowerRules.PlayerBaseline(100)
    local viewedAt100 = PowerEvaluator.Evaluate(fixedLoadout, { floor = 100 })
    local viewedAt130 = PowerEvaluator.Evaluate(fixedLoadout, { floor = 130 })
    near(BigNumber.LogRatio(viewedAt100.displayedPower, viewedAt130.displayedPower), 0, 1e-10,
        "switching floors must not change displayed power")
    near(viewedAt100.equivalentFloor, viewedAt130.equivalentFloor, 1e-9,
        "switching floors must not change equivalent floor")
    near(viewedAt130.headroomFloors, viewedAt130.equivalentFloor - 130, 1e-10,
        "headroom identity")

    local baseGrowth = TowerRules.GrowthNumber(100)
    local baseCurveStats = {
        attack = TowerRules.PLAYER_BASELINE.attack * baseGrowth,
        defense = TowerRules.PLAYER_BASELINE.defense * baseGrowth,
        maxHp = TowerRules.PLAYER_BASELINE.maxHp * baseGrowth,
        attackSpeed = TowerRules.PLAYER_BASELINE.attackSpeed,
        critRate = TowerRules.PLAYER_BASELINE.critRate,
        critDamage = TowerRules.PLAYER_BASELINE.critDamage,
    }
    local offsetEvaluation = PowerEvaluator.Evaluate(baseCurveStats, { floor = 100 })
    near(offsetEvaluation.equivalentFloor, 90, 1e-7,
        "base growth trails the calibrated difficulty curve")
    near(offsetEvaluation.powerRatio, 2 ^ (-10 / 50), 1e-8,
        "difficulty offset power ratio")

    local highStats = TowerRules.PlayerBaseline(100000)
    assert(highStats.attack == nil and highStats.attackBig.exponent > 600)
    local highEvaluation = PowerEvaluator.Evaluate(highStats, { floor = 100000 })
    near(highEvaluation.equivalentFloor, 100000, 1e-5, "high-floor log-domain solve")
    assert(highEvaluation.displayedPowerNumber == nil)
    assert(highEvaluation.displayedPower.exponent > 600)

    assert(PowerEvaluator.DifficultyLabel(1.10) == "碾压")
    assert(PowerEvaluator.DifficultyLabel(0.92) == "轻松")
    assert(PowerEvaluator.DifficultyLabel(0.88) == "可挑战")
    assert(PowerEvaluator.DifficultyLabel(0.75) == "吃力")
    assert(PowerEvaluator.DifficultyLabel(0.74) == "危险")
end

return Spec
