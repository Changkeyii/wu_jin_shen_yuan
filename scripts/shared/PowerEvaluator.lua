local BigNumber = require("shared.BigNumber")
local TowerRules = require("shared.TowerRules")

local PowerEvaluator = {}

PowerEvaluator.VERSION = 3
PowerEvaluator.SAFE_PERCENTILE_Z = 0.8416
PowerEvaluator.MAX_DAMAGE_REDUCTION = 0.70
PowerEvaluator.MAX_LIFESTEAL_HP_PER_SECOND = 0.03
PowerEvaluator.MAX_LIFESTEAL_INCOMING_RATIO = 0.50
PowerEvaluator.BOSS_TIME_LIMIT_SECONDS = 30
PowerEvaluator.BOSS_TIME_SAFETY = 0.90
PowerEvaluator.BOSS_SINGLE_HIT_SAFETY = 1.20

local LOG10 = math.log(10)
local LOG2 = math.log(2)
local HUGE_SCORE = 1e100

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function nonnegative(value)
    value = tonumber(value) or 0
    if not finite(value) then return 0 end
    return math.max(0, value)
end

local function firstValue(source, names)
    if type(source) ~= "table" then return nil end
    for _, name in ipairs(names) do
        if source[name] ~= nil then return source[name] end
    end
    return nil
end

local function magnitudeLog10(value)
    if type(value) == "table" then return BigNumber.Log10(value) end
    value = tonumber(value)
    if not finite(value) or value <= 0 then return -math.huge end
    return math.log(value) / LOG10
end

local function scaledMagnitude(value, growthLogarithm)
    local logarithm = magnitudeLog10(value)
    if logarithm == -math.huge then return 0 end
    local difference = logarithm - growthLogarithm
    if difference > 300 then return 1e300 end
    if difference < -300 then return 0 end
    return 10 ^ difference
end

local function statMagnitude(stats, regularNames, bigNames)
    local value = firstValue(stats, bigNames)
    if value ~= nil and magnitudeLog10(value) ~= -math.huge then return value end
    return firstValue(stats, regularNames)
end

local function normalizeStats(stats, floor)
    stats = type(stats) == "table" and stats or {}
    local growthLogarithm = TowerRules.DifficultyGrowthLog10(floor)
    local attack = statMagnitude(stats, { "attack", "atk" }, { "attackBig", "atkBig" })
    local defense = statMagnitude(stats, { "defense", "def" }, { "defenseBig", "defBig" })
    local maxHp = statMagnitude(stats, { "maxHp", "maxHP", "hp" }, { "maxHpBig", "hpBig" })

    return {
        attack = scaledMagnitude(attack, growthLogarithm),
        defense = scaledMagnitude(defense, growthLogarithm),
        maxHp = scaledMagnitude(maxHp, growthLogarithm),
        attackSpeed = clamp(firstValue(stats, { "attackSpeed", "atkSpeed", "as" }) or 1, 0.01, 100),
        critRate = clamp(firstValue(stats, { "critRate", "crit" }) or 0.10, 0, 1),
        critDamage = math.max(1, tonumber(firstValue(stats, { "critDamage", "critDmg" })) or 1.50),
        lifeSteal = clamp(firstValue(stats, { "lifeSteal", "lifesteal" }) or 0, 0, 1),
        damageReduction = clamp(firstValue(stats, { "damageReduction", "reduction" }) or 0, 0,
            PowerEvaluator.MAX_DAMAGE_REDUCTION),
        damageBonus = math.max(-0.95, tonumber(stats.damageBonus) or 0),
        bossDamage = math.max(-0.95, tonumber(stats.bossDamage) or 0),
        eliteDamage = math.max(-0.95, tonumber(stats.eliteDamage) or 0),
        skillDamage = math.max(-0.95, tonumber(stats.skillDamage) or 0),
        trueDamageRate = clamp(stats.trueDamageRate or 0, 0, 1),
    }
end

local function normalizedReference()
    return {
        attack = TowerRules.PLAYER_BASELINE.attack,
        defense = TowerRules.PLAYER_BASELINE.defense,
        maxHp = TowerRules.PLAYER_BASELINE.maxHp,
        attackSpeed = TowerRules.PLAYER_BASELINE.attackSpeed,
        critRate = TowerRules.PLAYER_BASELINE.critRate,
        critDamage = TowerRules.PLAYER_BASELINE.critDamage,
        lifeSteal = 0,
        damageReduction = 0,
        damageBonus = 0,
        bossDamage = 0,
        eliteDamage = 0,
        skillDamage = 0,
        trueDamageRate = 0,
    }
end

local function sequenceProbabilities(options)
    local configured = options and options.attackProbabilities
    local probabilities = {}
    local total = 0
    for index, id in ipairs(TowerRules.ATTACK_SEQUENCE_ORDER) do
        local probability = type(configured) == "table"
            and tonumber(configured[id] or configured[index]) or nil
        probability = probability and math.max(0, probability) or 1
        probabilities[index] = probability
        total = total + probability
    end
    if total <= 0 then
        total = #TowerRules.ATTACK_SEQUENCE_ORDER
        for index = 1, total do probabilities[index] = 1 end
    end
    for index = 1, #probabilities do probabilities[index] = probabilities[index] / total end
    return probabilities
end

local function attackDistribution(profile, options)
    local probabilities = sequenceProbabilities(options)
    local critBonus = profile.critDamage - 1
    local critMultiplier = 1 + profile.critRate * critBonus
    local expectedBaseWeight = 0
    local expectedBaseDuration = 0
    local expectedDuration = 0
    local expectedCoefficient = 0
    local expectedCoefficientSquare = 0
    local sequenceData = {}

    for index, id in ipairs(TowerRules.ATTACK_SEQUENCE_ORDER) do
        local sequence = TowerRules.AttackSequence(id)
        local probability = probabilities[index]
        local duration = TowerRules.AttackDuration(id, profile.attackSpeed)
        local meanCoefficient = sequence.totalWeight * critMultiplier
        local critVariance = profile.critRate * (1 - profile.critRate)
            * critBonus * critBonus * sequence.squareWeight

        expectedBaseWeight = expectedBaseWeight + probability * sequence.totalWeight
        expectedBaseDuration = expectedBaseDuration + probability * sequence.duration
        expectedDuration = expectedDuration + probability * duration
        expectedCoefficient = expectedCoefficient + probability * meanCoefficient
        expectedCoefficientSquare = expectedCoefficientSquare
            + probability * (critVariance + meanCoefficient * meanCoefficient)
        sequenceData[index] = {
            id = id,
            probability = probability,
            duration = duration,
            baseDuration = sequence.duration,
            totalWeight = sequence.totalWeight,
        }
    end

    local varianceCoefficient = math.max(0,
        expectedCoefficientSquare - expectedCoefficient * expectedCoefficient)
    local sigmaCoefficient = math.sqrt(varianceCoefficient)
    local safeCoefficient = math.max(0,
        expectedCoefficient - PowerEvaluator.SAFE_PERCENTILE_Z * sigmaCoefficient)
    local actualBaseDps = expectedDuration > 0
        and profile.attack * expectedBaseWeight / expectedDuration or 0
    local formulaBaseDps = expectedBaseDuration > 0
        and profile.attack * profile.attackSpeed * expectedBaseWeight / expectedBaseDuration or 0

    return {
        sequences = sequenceData,
        cycleSeconds = expectedDuration,
        baseCycleSeconds = expectedBaseDuration,
        expectedBaseWeight = expectedBaseWeight,
        baseDps = actualBaseDps,
        formulaBaseDps = formulaBaseDps,
        critMultiplier = critMultiplier,
        meanDamagePerCycle = profile.attack * expectedCoefficient,
        sigmaDamagePerCycle = profile.attack * sigmaCoefficient,
        meanDpsRaw = expectedDuration > 0 and profile.attack * expectedCoefficient / expectedDuration or 0,
        safeDpsRaw = expectedDuration > 0 and profile.attack * safeCoefficient / expectedDuration or 0,
    }
end

local function outgoingMultiplier(profile, kind)
    local bonus = profile.damageBonus + profile.skillDamage
    if kind == "boss" or kind == "chapterBoss" then bonus = bonus + profile.bossDamage end
    if kind == "elite" then bonus = bonus + profile.eliteDamage end
    return math.max(0.05, 1 + bonus)
end

local function combatMetrics(profile, kind, options)
    local monster = assert(TowerRules.MonsterStatsNormalized(kind), "unknown monster kind")
    local distribution = attackDistribution(profile, options)
    local defendedPortion = 100 / (100 + monster.defense)
    local outgoingDefenseMultiplier = profile.trueDamageRate
        + (1 - profile.trueDamageRate) * defendedPortion
    local outgoing = outgoingMultiplier(profile, kind) * outgoingDefenseMultiplier
    local meanDps = distribution.meanDpsRaw * outgoing
    local safeDps = distribution.safeDpsRaw * outgoing
    local baseDps = distribution.baseDps * outgoing

    local reductionMultiplier = 1 - profile.damageReduction
    local incomingHitMultiplier = 100 / (100 + profile.defense) * reductionMultiplier
    local singleHit = monster.attack * incomingHitMultiplier
    local incomingDps = singleHit / monster.attackInterval
    local hps = math.min(
        safeDps * profile.lifeSteal,
        profile.maxHp * PowerEvaluator.MAX_LIFESTEAL_HP_PER_SECOND,
        incomingDps * PowerEvaluator.MAX_LIFESTEAL_INCOMING_RATIO
    )
    if not finite(hps) then hps = 0 end
    local ehp0 = incomingHitMultiplier > 0 and profile.maxHp / incomingHitMultiplier or HUGE_SCORE
    local healingRatio = incomingDps > 0 and clamp(hps / incomingDps, 0, 0.999999) or 0
    local ehp = ehp0 / (1 - healingRatio)
    local ttk = safeDps > 0 and monster.hp / safeDps or math.huge
    local meanTtk = meanDps > 0 and monster.hp / meanDps or math.huge
    local netIncomingDps = math.max(0, incomingDps - hps)
    local ttd = netIncomingDps > 0 and profile.maxHp / netIncomingDps or math.huge

    return {
        kind = kind,
        monster = monster,
        distribution = distribution,
        dpsBase = baseDps,
        dpsBaseFormula = distribution.formulaBaseDps * outgoing,
        dpsMean = meanDps,
        dpsSafe = safeDps,
        critMultiplier = distribution.critMultiplier,
        defenseMultiplier = outgoingDefenseMultiplier,
        incomingHitMultiplier = incomingHitMultiplier,
        incomingDps = incomingDps,
        p95SingleHit = singleHit,
        hps = hps,
        ehp0 = ehp0,
        ehp = ehp,
        ttk = ttk,
        meanTtk = meanTtk,
        ttd = ttd,
        netIncomingDps = netIncomingDps,
    }
end

local function ratio(numerator, denominator)
    if denominator <= 0 then return numerator > 0 and HUGE_SCORE or 0 end
    if numerator == math.huge then return HUGE_SCORE end
    if not finite(numerator) then return 0 end
    return math.min(HUGE_SCORE, math.max(0, numerator / denominator))
end

local function balanceScore(outputRatio, survivalRatio)
    if outputRatio <= 0 or survivalRatio <= 0 then return 0 end
    if outputRatio >= survivalRatio then
        return math.sqrt(outputRatio * survivalRatio)
    end
    return outputRatio ^ 0.7 * survivalRatio ^ 0.3
end

local function simulatePrelude(profile, options)
    local currentHp = profile.maxHp
    local encounters = {}
    local routeAlive = currentHp > 0

    local function fight(kind, count)
        for _ = 1, count do
            local metrics = combatMetrics(profile, kind, options)
            local healthLoss = metrics.ttk == math.huge
                and math.huge or metrics.netIncomingDps * metrics.ttk
            currentHp = math.max(0, currentHp - healthLoss)
            routeAlive = routeAlive and currentHp > 0 and metrics.ttk < math.huge
            encounters[#encounters + 1] = {
                kind = kind,
                ttk = metrics.ttk,
                healthLoss = healthLoss,
                remainingHp = currentHp,
            }
            if not routeAlive then return false end
        end
        return true
    end

    if fight("normal", TowerRules.NORMAL_ENCOUNTERS) then
        fight("elite", TowerRules.ELITE_ENCOUNTERS)
    end
    return {
        alive = routeAlive,
        bossEntryHp = routeAlive and currentHp or 0,
        encounters = encounters,
    }
end

local function evaluateAtFloor(stats, floor, options)
    floor = tonumber(floor) or 1
    if not finite(floor) then floor = 1 end
    options = type(options) == "table" and options or {}

    local profile = normalizeStats(stats, floor)
    local reference = normalizedReference()
    local bossKind = TowerRules.NormalizeMonsterKind(options.bossKind) or "chapterBoss"

    local playerNormal = combatMetrics(profile, "normal", options)
    local playerElite = combatMetrics(profile, "elite", options)
    local playerBoss = combatMetrics(profile, bossKind, options)
    local referenceNormal = combatMetrics(reference, "normal", options)
    local referenceElite = combatMetrics(reference, "elite", options)
    local referenceBoss = combatMetrics(reference, bossKind, options)

    local playerPrelude = simulatePrelude(profile, options)
    local referencePrelude = simulatePrelude(reference, options)
    local playerEntryFraction = profile.maxHp > 0 and playerPrelude.bossEntryHp / profile.maxHp or 0
    local referenceEntryFraction = referencePrelude.bossEntryHp / reference.maxHp

    local normalOutput = ratio(playerNormal.dpsSafe, referenceNormal.dpsSafe)
    local normalSurvival = ratio(playerNormal.ehp, referenceNormal.ehp)
    local normalScore = balanceScore(normalOutput, normalSurvival)
    local eliteOutput = ratio(playerElite.dpsSafe, referenceElite.dpsSafe)
    local eliteSurvival = ratio(playerElite.ehp, referenceElite.ehp)
    local eliteScore = balanceScore(eliteOutput, eliteSurvival)
    local bossOutput = ratio(playerBoss.dpsSafe, referenceBoss.dpsSafe)
    local bossSurvival = ratio(
        playerBoss.ehp * playerEntryFraction,
        referenceBoss.ehp * referenceEntryFraction
    )
    local bossBalance = balanceScore(bossOutput, bossSurvival)
    local bossTimeGate = playerBoss.ttk < math.huge and
        PowerEvaluator.BOSS_TIME_SAFETY * PowerEvaluator.BOSS_TIME_LIMIT_SECONDS / playerBoss.ttk or 0
    local bossHitGate = playerBoss.p95SingleHit > 0 and
        playerPrelude.bossEntryHp /
            (PowerEvaluator.BOSS_SINGLE_HIT_SAFETY * playerBoss.p95SingleHit) or HUGE_SCORE
    local bossScore = math.max(0, math.min(bossBalance, bossTimeGate, bossHitGate))
    local combinedScore = bossScore > 0 and eliteScore > 0
        and bossScore ^ 0.7 * eliteScore ^ 0.3 or 0
    local towerScore = math.max(0, math.min(
        combinedScore,
        bossScore / 0.75,
        eliteScore / 0.70
    ))
    if not finite(towerScore) then towerScore = towerScore == math.huge and HUGE_SCORE or 0 end

    local bossNetIncoming = playerBoss.netIncomingDps
    local bossTtd = bossNetIncoming > 0
        and playerPrelude.bossEntryHp / bossNetIncoming or math.huge
    local bossSurvivalMargin = playerBoss.ttk > 0 and bossTtd / playerBoss.ttk or HUGE_SCORE

    return {
        floor = floor,
        bossKind = bossKind,
        towerScore = towerScore,
        score = towerScore,
        bossScore = bossScore,
        bossBalanceScore = bossBalance,
        bossTimeGate = bossTimeGate,
        bossSingleHitGate = bossHitGate,
        eliteScore = eliteScore,
        normalScore = normalScore,
        outputRatio = bossOutput,
        survivalRatio = bossSurvival,
        profile = profile,
        normal = playerNormal,
        elite = playerElite,
        boss = playerBoss,
        prelude = playerPrelude,
        bossEntryHp = playerPrelude.bossEntryHp,
        bossEntryHpRatio = playerEntryFraction,
        bossTtd = bossTtd,
        bossSurvivalMargin = bossSurvivalMargin,
        routeSurvives = playerPrelude.alive and bossTtd >= playerBoss.ttk,
        dpsSafe = playerBoss.dpsSafe,
        dpsMean = playerBoss.dpsMean,
        ehp = playerBoss.ehp,
        hps = playerBoss.hps,
    }
end

function PowerEvaluator.EvaluateAtFloor(stats, floor, options)
    return evaluateAtFloor(stats, floor, options)
end

function PowerEvaluator.EvaluateActualFloor(stats, floor, options)
    local actualOptions = {}
    for key, value in pairs(type(options) == "table" and options or {}) do actualOptions[key] = value end
    local encounter = TowerRules.GetEncounter(TowerRules.BOSS_ENCOUNTER, floor)
    actualOptions.bossKind = encounter and encounter.kind or "boss"
    return evaluateAtFloor(stats, floor, actualOptions)
end

function PowerEvaluator.FindEquivalentFloor(stats, options)
    options = type(options) == "table" and options or {}
    local attack = statMagnitude(stats, { "attack", "atk" }, { "attackBig", "atkBig" })
    local hp = statMagnitude(stats, { "maxHp", "maxHP", "hp" }, { "maxHpBig", "hpBig" })
    local attackLogarithm = magnitudeLog10(attack)
    if attackLogarithm == -math.huge or magnitudeLog10(hp) == -math.huge then return 0 end

    local estimate = 1 + (attackLogarithm - math.log(TowerRules.PLAYER_BASELINE.attack) / LOG10)
        * TowerRules.FLOORS_PER_DOUBLING / TowerRules.LOG10_2
    estimate = clamp(estimate, -1e9, 1e9)
    local scoreAtEstimate = evaluateAtFloor(stats, estimate, options).towerScore
    local low, high
    local step = TowerRules.FLOORS_PER_DOUBLING

    if scoreAtEstimate >= 1 then
        low = estimate
        high = estimate + step
        for _ = 1, 64 do
            if evaluateAtFloor(stats, high, options).towerScore < 1 then break end
            low = high
            step = step * 2
            high = math.min(1e9, high + step)
            if high >= 1e9 then break end
        end
    else
        high = estimate
        low = estimate - step
        for _ = 1, 64 do
            if evaluateAtFloor(stats, low, options).towerScore >= 1 then break end
            high = low
            step = step * 2
            low = math.max(-1e9, low - step)
            if low <= -1e9 then break end
        end
    end

    for _ = 1, 64 do
        local middle = (low + high) * 0.5
        if evaluateAtFloor(stats, middle, options).towerScore >= 1 then
            low = middle
        else
            high = middle
        end
    end
    return (low + high) * 0.5
end

function PowerEvaluator.DifficultyLabel(powerRatio)
    powerRatio = nonnegative(powerRatio)
    if powerRatio >= 1.10 then return "碾压" end
    if powerRatio >= 0.92 then return "轻松" end
    if powerRatio >= 0.88 then return "可挑战" end
    if powerRatio >= 0.75 then return "吃力" end
    return "危险"
end

local function powerRatioFromFloors(equivalentFloor, targetFloor)
    local logarithm = (TowerRules.DifficultyGrowthLog10(equivalentFloor)
        - TowerRules.DifficultyGrowthLog10(targetFloor)) * LOG10
    if logarithm > math.log(HUGE_SCORE) then return HUGE_SCORE end
    if logarithm < -700 then return 0 end
    return math.exp(logarithm)
end

function PowerEvaluator.Evaluate(stats, options)
    options = type(options) == "table" and options or {}
    local targetFloor = math.max(1, tonumber(options.floor) or 1)
    local equivalentOptions = {}
    for key, value in pairs(options) do
        if key ~= "floor" then equivalentOptions[key] = value end
    end
    local equivalentFloor = PowerEvaluator.FindEquivalentFloor(stats, equivalentOptions)
    local floorEvaluation = evaluateAtFloor(stats, targetFloor, equivalentOptions)
    local valid = equivalentFloor ~= 0 or floorEvaluation.towerScore > 0
    local displayedPower = valid
        and BigNumber.MultiplyScalar(TowerRules.DifficultyGrowth(equivalentFloor),
            TowerRules.RECOMMENDED_POWER_BASE)
        or BigNumber.Zero()
    local recommendedPower = TowerRules.RecommendedPower(targetFloor)
    local powerRatio = valid and powerRatioFromFloors(equivalentFloor, targetFloor) or 0
    local headroomFloors = valid and 50 * (math.log(math.max(powerRatio, 1e-300)) / LOG2)
        or (equivalentFloor - targetFloor)
    if valid then headroomFloors = equivalentFloor - targetFloor end
    local nextChapterFloor = (math.floor(targetFloor / 10) + 1) * 10

    floorEvaluation.displayedPower = displayedPower
    floorEvaluation.displayedPowerNumber = BigNumber.ToNumber(displayedPower)
    floorEvaluation.recommendedPower = recommendedPower
    floorEvaluation.recommendedPowerNumber = BigNumber.ToNumber(recommendedPower)
    floorEvaluation.powerRatio = powerRatio
    floorEvaluation.headroomFloors = headroomFloors
    floorEvaluation.equivalentFloor = equivalentFloor
    floorEvaluation.estimatedEasyFloor = valid and math.max(0, math.floor(equivalentFloor)) or 0
    floorEvaluation.difficultyLabel = PowerEvaluator.DifficultyLabel(powerRatio)
    floorEvaluation.nextChapterFloor = nextChapterFloor
    floorEvaluation.nextChapterRecommendedPower = TowerRules.RecommendedPower(nextChapterFloor)
    floorEvaluation.nextChapterRecommendedPowerNumber =
        BigNumber.ToNumber(floorEvaluation.nextChapterRecommendedPower)
    return floorEvaluation
end

PowerEvaluator.EvaluateLoadout = PowerEvaluator.Evaluate

return PowerEvaluator
