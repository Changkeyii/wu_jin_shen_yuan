local BigNumber = require("shared.BigNumber")
local PowerEvaluator = require("shared.PowerEvaluator")
local RewardPolicy = require("shared.RewardPolicy")
local RarityCatalog = require("shared.RarityCatalog")
local TowerRules = require("shared.TowerRules")

local Simulator = {}

Simulator.VERSION = 3
Simulator.DEFAULT_SEED = 20260723
Simulator.DEFAULT_SAMPLES = 100000
Simulator.QUICK_SAMPLES = 2000
Simulator.RNG_ALGORITHM = "park-miller-minstd-16807"
Simulator.KEY_FLOORS = { 1, 10, 50, 100, 300, 500, 1000, 5000 }
Simulator.PROFILE_ORDER = {
    "balanced", "glass_cannon", "tank", "lifesteal", "critical", "boss_specialist",
}
Simulator.MATRIX_GROUPS = {
    { key = "regular", representativeFloor = 1, bossKind = "boss" },
    { key = "chapter", representativeFloor = 10, bossKind = "chapterBoss" },
}
Simulator.THRESHOLD_SCENARIOS = {
    {
        id = "regular_boss_attributes_75", floor = 1, ratio = 0.75,
        bossKind = "boss", bossTarget = 0.99,
        measurementRole = "regular boss minimum attributes",
    },
    {
        id = "chapter_boss_attributes_90", floor = 10, ratio = 0.90,
        bossKind = "chapterBoss", bossTarget = 0.90,
        measurementRole = "chapter boss baseline attributes",
    },
    {
        id = "chapter_boss_attributes_92", floor = 10, ratio = 0.92,
        bossKind = "chapterBoss", bossTarget = 0.99,
        measurementRole = "chapter boss safe attributes",
    },
    {
        id = "aid_attributes_102", floor = 10, ratio = 1.02,
        bossKind = "chapterBoss", bossTarget = 0.99,
        measurementRole = "post-aid combat proxy",
    },
}

-- The shapes are deliberately different. BuildProfile calibrates the three
-- main axes together until every shape has the requested displayed-power
-- ratio, so the matrix compares builds that the production evaluator regards
-- as equally strong.
Simulator.PROFILES = {
    balanced = {
        label = "Balanced",
        attack = 1.00, defense = 1.00, maxHp = 1.00,
    },
    glass_cannon = {
        label = "Glass cannon",
        attack = 1.45, defense = 0.60, maxHp = 0.66,
    },
    tank = {
        label = "Pure defense",
        attack = 0.68, defense = 1.50, maxHp = 1.35,
    },
    lifesteal = {
        label = "Lifesteal",
        attack = 0.90, defense = 0.87, maxHp = 0.90,
        lifeSteal = 0.12,
    },
    critical = {
        label = "Critical",
        attack = 0.82, defense = 0.90, maxHp = 0.90,
        critRate = 0.45, critDamage = 2.05,
    },
    boss_specialist = {
        label = "Boss specialist",
        attack = 0.88, defense = 0.90, maxHp = 0.90,
        bossDamage = 0.30,
    },
}

local EPSILON = 1e-9
local MODULUS = 2147483647
local MULTIPLIER = 16807
local QUOTIENT = 127773
local REMAINDER = 2836
local calibrationCache = {}

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function Simulator.NormalizeSeed(seed)
    local numeric = tonumber(seed)
    if not finite(numeric) then numeric = Simulator.DEFAULT_SEED end
    numeric = tonumber(numeric) or Simulator.DEFAULT_SEED
    numeric = math.floor(numeric) % MODULUS
    if numeric <= 0 then numeric = numeric + MODULUS - 1 end
    return numeric
end

function Simulator.Metadata()
    return {
        simulatorVersion = Simulator.VERSION,
        powerEvaluatorVersion = PowerEvaluator.VERSION,
        rewardPolicyVersion = RewardPolicy.VERSION,
        rarityCatalogVersion = RarityCatalog.VERSION,
        towerRulesVersion = TowerRules.VERSION,
        rngAlgorithm = Simulator.RNG_ALGORITHM,
        defaultSeed = Simulator.DEFAULT_SEED,
    }
end

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function shallowCopy(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function combatStatsCopy(stats)
    local result = {}
    for _, key in ipairs({
        "attack", "atk", "defense", "def", "maxHp", "hp",
        "attackBig", "atkBig", "defenseBig", "defBig", "maxHpBig", "hpBig",
        "attackSpeed", "atkSpeed", "critRate", "crit", "critDamage", "critDmg",
        "lifeSteal", "damageReduction", "damageBonus", "bossDamage", "eliteDamage",
        "skillDamage", "trueDamageRate",
    }) do
        if stats[key] ~= nil then result[key] = stats[key] end
    end
    return result
end

local Rng = {}
Rng.__index = Rng

function Rng.New(seed)
    return setmetatable({ state = Simulator.NormalizeSeed(seed) }, Rng)
end

function Rng:NextInteger()
    local high = math.floor(self.state / QUOTIENT)
    local low = self.state - high * QUOTIENT
    local nextState = MULTIPLIER * low - REMAINDER * high
    if nextState <= 0 then nextState = nextState + MODULUS end
    self.state = nextState
    return nextState
end

function Rng:Next()
    return (self:NextInteger() - 1) / (MODULUS - 1)
end

function Rng:Integer(minimum, maximum)
    return minimum + math.floor(self:Next() * (maximum - minimum + 1))
end

-- GameEngine accepts Int/Float while the combat simulator historically used
-- Integer/Next. Expose both names so one deterministic stream can drive the
-- production reward and aid rules without falling back to math.random.
function Rng:Int(minimum, maximum)
    return self:Integer(minimum, maximum)
end

function Rng:NextInt(minimum, maximum)
    return self:Integer(minimum, maximum)
end

function Rng:Float()
    return self:Next()
end

function Rng:NextFloat()
    return self:Next()
end

Simulator.Rng = Rng

local function inverseNormal(probability)
    probability = clamp(probability, 1e-12, 1 - 1e-12)
    local a1, a2, a3 = -39.6968302866538, 220.946098424521, -275.928510446969
    local a4, a5, a6 = 138.357751867269, -30.6647980661472, 2.50662827745924
    local b1, b2, b3 = -54.4760987982241, 161.585836858041, -155.698979859887
    local b4, b5 = 66.8013118877197, -13.2806815528857
    local c1, c2, c3 = -0.00778489400243029, -0.322396458041136, -2.40075827716184
    local c4, c5, c6 = -2.54973253934373, 4.37466414146497, 2.93816398269878
    local d1, d2, d3, d4 = 0.00778469570904146, 0.32246712907004,
        2.445134137143, 3.75440866190742
    local lower = 0.02425
    local upper = 1 - lower
    if probability < lower then
        local q = math.sqrt(-2 * math.log(probability))
        return (((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6)
            / ((((d1 * q + d2) * q + d3) * q + d4) * q + 1)
    end
    if probability > upper then
        local q = math.sqrt(-2 * math.log(1 - probability))
        return -(((((c1 * q + c2) * q + c3) * q + c4) * q + c5) * q + c6)
            / ((((d1 * q + d2) * q + d3) * q + d4) * q + 1)
    end
    local q = probability - 0.5
    local r = q * q
    return (((((a1 * r + a2) * r + a3) * r + a4) * r + a5) * r + a6) * q
        / (((((b1 * r + b2) * r + b3) * r + b4) * r + b5) * r + 1)
end

local NORMAL_TABLE_SIZE = 4096
local NORMAL_TABLE = {}
for index = 1, NORMAL_TABLE_SIZE do
    NORMAL_TABLE[index] = inverseNormal((index - 0.5) / NORMAL_TABLE_SIZE)
end

local function sampleNormal(rng)
    local index = math.min(NORMAL_TABLE_SIZE, math.floor(rng:Next() * NORMAL_TABLE_SIZE) + 1)
    return NORMAL_TABLE[index]
end

local function percentile(sorted, probability)
    if #sorted == 0 then return nil end
    probability = clamp(probability, 0, 1)
    local position = 1 + (#sorted - 1) * probability
    local lower = math.floor(position)
    local upper = math.ceil(position)
    if lower == upper then return sorted[lower] end
    local fraction = position - lower
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
end

local function mean(values)
    if #values == 0 then return nil end
    local total = 0
    for _, value in ipairs(values) do total = total + value end
    return total / #values
end

Simulator.Percentile = percentile
Simulator.Mean = mean

local function profileStatsAtFloor(shape, scale, floor)
    local growth = assert(TowerRules.DifficultyGrowthNumber(floor),
        "profile floor exceeds native simulator range")
    return {
        attack = TowerRules.PLAYER_BASELINE.attack * shape.attack * scale * growth,
        defense = TowerRules.PLAYER_BASELINE.defense * shape.defense * scale * growth,
        maxHp = TowerRules.PLAYER_BASELINE.maxHp * shape.maxHp * scale * growth,
        attackSpeed = shape.attackSpeed or TowerRules.PLAYER_BASELINE.attackSpeed,
        critRate = shape.critRate or TowerRules.PLAYER_BASELINE.critRate,
        critDamage = shape.critDamage or TowerRules.PLAYER_BASELINE.critDamage,
        lifeSteal = shape.lifeSteal or 0,
        damageReduction = shape.damageReduction or 0,
        damageBonus = shape.damageBonus or 0,
        bossDamage = shape.bossDamage or 0,
        eliteDamage = shape.eliteDamage or 0,
        skillDamage = shape.skillDamage or 0,
        trueDamageRate = shape.trueDamageRate or 0,
    }
end

local function calibrationScale(profileId, targetPowerRatio)
    local cacheKey = profileId .. ":" .. string.format("%.8f", targetPowerRatio)
    if calibrationCache[cacheKey] then return calibrationCache[cacheKey] end
    local shape = assert(Simulator.PROFILES[profileId], "unknown profile: " .. tostring(profileId))
    local low, high = 0.05, 4.0
    for _ = 1, 52 do
        local middle = (low + high) * 0.5
        local evaluation = PowerEvaluator.Evaluate(profileStatsAtFloor(shape, middle, 1), { floor = 1 })
        if (evaluation.powerRatio or 0) < targetPowerRatio then low = middle else high = middle end
    end
    local result = (low + high) * 0.5
    calibrationCache[cacheKey] = result
    return result
end

function Simulator.BuildProfile(profileId, floor, targetPowerRatio)
    targetPowerRatio = tonumber(targetPowerRatio) or 1
    local shape = assert(Simulator.PROFILES[profileId], "unknown profile: " .. tostring(profileId))
    local scale = calibrationScale(profileId, targetPowerRatio)
    return profileStatsAtFloor(shape, scale, floor), scale
end

function Simulator.BuildUniformBaseline(floor, attributeRatio)
    return profileStatsAtFloor(Simulator.PROFILES.balanced, tonumber(attributeRatio) or 1, floor)
end

local function actualBossKind(floor)
    local encounter = TowerRules.GetEncounter(TowerRules.BOSS_ENCOUNTER, floor)
    return encounter and encounter.kind or "boss"
end

local function metricsByKind(evaluation, bossKind)
    return {
        normal = evaluation.normal,
        elite = evaluation.elite,
        boss = evaluation.boss,
        chapterBoss = evaluation.boss,
        actualBossKind = bossKind,
    }
end

local function prepareCombat(stats, floor, bossKind)
    bossKind = bossKind or actualBossKind(floor)
    local evaluation = PowerEvaluator.EvaluateAtFloor(stats, floor, { bossKind = bossKind })
    return {
        floor = floor,
        bossKind = bossKind,
        evaluation = evaluation,
        profile = evaluation.profile,
        metrics = metricsByKind(evaluation, bossKind),
    }
end

local function sampledTtk(metrics, rng)
    local distribution = metrics.distribution
    local meanDps = metrics.dpsMean
    if not meanDps or meanDps <= 0 then return math.huge end
    local rawMeanDps = distribution.meanDpsRaw
    local outgoingScale = rawMeanDps > 0 and meanDps / rawMeanDps or 0
    local cycleSeconds = math.max(EPSILON, distribution.cycleSeconds)
    local sigmaCycle = distribution.sigmaDamagePerCycle * outgoingScale
    local nominalCycles = math.max(1, metrics.monster.hp / (meanDps * cycleSeconds))
    local sigmaDps = sigmaCycle / cycleSeconds / math.sqrt(nominalCycles)
    local sampledDps = math.max(meanDps * 0.05, meanDps + sampleNormal(rng) * sigmaDps)
    return metrics.monster.hp / sampledDps
end

local function incomingDamageForDuration(metrics, duration, boss)
    if duration <= 0 then return 0 end
    local interval = metrics.monster.attackInterval or TowerRules.MONSTER_ATTACK_INTERVAL
    local hit = metrics.p95SingleHit
    if not boss or duration <= TowerRules.BOSS_ENRAGE_SECONDS then
        local count = math.floor(math.max(0, duration - EPSILON) / interval)
        return count * hit
    end

    local enrageAt = TowerRules.BOSS_ENRAGE_SECONDS
    local beforeCount = math.floor(math.max(0, enrageAt - EPSILON) / interval)
    local enragedInterval = interval / TowerRules.BOSS_ENRAGE_ATTACK_SPEED_MULTIPLIER
    local afterCount = math.floor(math.max(0, duration - enrageAt - EPSILON) / enragedInterval) + 1
    return beforeCount * hit
        + afterCount * hit * TowerRules.BOSS_ENRAGE_DAMAGE_MULTIPLIER
end

local function fightAggregate(playerHp, maxHp, profile, metrics, rng, boss)
    local duration = sampledTtk(metrics, rng)
    if duration == math.huge then
        return false, 0, duration
    end
    local incoming = incomingDamageForDuration(metrics, duration, boss)
    local healing = math.min(
        metrics.hps * duration,
        metrics.monster.hp * math.max(0, profile.lifeSteal or 0)
    )
    local loss = math.max(0, incoming - healing)
    if loss >= playerHp then
        local deathFraction = loss > 0 and clamp(playerHp / loss, 0, 1) or 1
        return false, 0, duration * deathFraction
    end
    return true, math.min(maxHp, playerHp - incoming + healing), duration
end

local function hitTime(sequence, hitIndex, duration)
    local endFrame = math.max(2, math.floor(sequence.duration * sequence.fps + 0.5))
    return (sequence.hitFrames[hitIndex] - 1) / (endFrame - 1) * duration
end

local function fightHits(playerHp, maxHp, profile, metrics, rng, boss)
    local monsterHp = metrics.monster.hp
    local elapsed = 0
    local nextMonsterAttack = metrics.monster.attackInterval or TowerRules.MONSTER_ATTACK_INTERVAL
    local previousSequence = 0
    local rawMeanDps = metrics.distribution.meanDpsRaw
    local outgoingScale = rawMeanDps > 0 and metrics.dpsMean / rawMeanDps or 0
    local effectiveLifeSteal = metrics.dpsMean > 0
        and math.min(profile.lifeSteal or 0, metrics.hps / metrics.dpsMean) or 0

    for _ = 1, 10000 do
        local sequenceIndex = rng:Integer(1, #TowerRules.ATTACK_SEQUENCE_ORDER)
        if sequenceIndex == previousSequence then
            sequenceIndex = sequenceIndex % #TowerRules.ATTACK_SEQUENCE_ORDER + 1
        end
        previousSequence = sequenceIndex
        local sequence = TowerRules.AttackSequence(sequenceIndex)
        local duration = TowerRules.AttackDuration(sequenceIndex, profile.attackSpeed)
        local cycleStart = elapsed

        for index, weight in ipairs(sequence.weights) do
            local absoluteHitTime = cycleStart + hitTime(sequence, index, duration)
            while nextMonsterAttack < absoluteHitTime - EPSILON do
                local enraged = boss and nextMonsterAttack >= TowerRules.BOSS_ENRAGE_SECONDS
                local damage = metrics.p95SingleHit
                    * (enraged and TowerRules.BOSS_ENRAGE_DAMAGE_MULTIPLIER or 1)
                playerHp = playerHp - damage
                if playerHp <= 0 then return false, 0, nextMonsterAttack end
                local interval = metrics.monster.attackInterval or TowerRules.MONSTER_ATTACK_INTERVAL
                if enraged then interval = interval / TowerRules.BOSS_ENRAGE_ATTACK_SPEED_MULTIPLIER end
                nextMonsterAttack = nextMonsterAttack + interval
            end

            local critical = rng:Next() < profile.critRate
            local damage = profile.attack * weight * outgoingScale
                * (critical and profile.critDamage or 1)
            local effectiveDamage = math.min(monsterHp, damage)
            monsterHp = monsterHp - damage
            if effectiveLifeSteal > 0 and effectiveDamage > 0 then
                playerHp = math.min(maxHp, playerHp + effectiveDamage * effectiveLifeSteal)
            end
            if monsterHp <= 0 then return true, playerHp, absoluteHitTime end
        end
        elapsed = cycleStart + duration
    end
    return false, 0, math.huge
end

local function fight(playerHp, maxHp, prepared, kind, rng, model)
    local metrics = prepared.metrics[kind]
    local boss = kind == "boss" or kind == "chapterBoss"
    if model == "hits" then
        return fightHits(playerHp, maxHp, prepared.profile, metrics, rng, boss)
    end
    return fightAggregate(playerHp, maxHp, prepared.profile, metrics, rng, boss)
end

function Simulator.SimulateEncounter(prepared, kind, rng, options)
    options = options or {}
    kind = kind or prepared.bossKind
    local maxHp = math.max(0, tonumber(options.maxHp) or prepared.profile.maxHp)
    local playerHp = math.max(0, math.min(
        maxHp,
        tonumber(options.playerHp) or maxHp
    ))
    local success, remainingHp, duration = fight(
        playerHp,
        maxHp,
        prepared,
        kind,
        rng,
        options.model or "aggregate"
    )
    return {
        success = success,
        kind = kind,
        remainingHp = remainingHp,
        remainingHpRatio = maxHp > 0 and remainingHp / maxHp or 0,
        combatSeconds = duration,
    }
end

function Simulator.SimulateRoute(prepared, rng, options)
    options = options or {}
    local model = options.model or "aggregate"
    local playerHp = prepared.profile.maxHp
    local maxHp = playerHp
    local elapsed = 0
    local completed = 0

    local route = {}
    for _ = 1, TowerRules.NORMAL_ENCOUNTERS do route[#route + 1] = "normal" end
    for _ = 1, TowerRules.ELITE_ENCOUNTERS do route[#route + 1] = "elite" end
    route[#route + 1] = prepared.bossKind

    for room, kind in ipairs(route) do
        local success, nextHp, duration = fight(playerHp, maxHp, prepared, kind, rng, model)
        elapsed = elapsed + duration
        if not success then
            return {
                success = false,
                deathRoom = room,
                completedEncounters = completed,
                remainingHp = 0,
                remainingHpRatio = 0,
                combatSeconds = elapsed,
            }
        end
        playerHp = nextHp
        completed = completed + 1
    end
    return {
        success = true,
        deathRoom = nil,
        completedEncounters = completed,
        remainingHp = playerHp,
        remainingHpRatio = maxHp > 0 and playerHp / maxHp or 0,
        combatSeconds = elapsed,
    }
end

function Simulator.SimulateBoss(prepared, rng, options)
    options = options or {}
    local maxHp = prepared.profile.maxHp
    local success, remainingHp, duration = fight(
        maxHp, maxHp, prepared, prepared.bossKind, rng, options.model or "aggregate")
    return {
        success = success,
        deathRoom = success and nil or TowerRules.BOSS_ENCOUNTER,
        completedEncounters = success and 1 or 0,
        remainingHp = remainingHp,
        remainingHpRatio = maxHp > 0 and remainingHp / maxHp or 0,
        combatSeconds = duration,
    }
end

local function distributionSummary(values, prefix, target)
    table.sort(values)
    target[prefix .. "Mean"] = mean(values) or 0
    target[prefix .. "P50"] = percentile(values, 0.50) or 0
    target[prefix .. "P90"] = percentile(values, 0.90) or 0
    target[prefix .. "P99"] = percentile(values, 0.99) or 0
end

local function summarizeTrials(
    durations, successDurations, failureDurations, remainingRatios,
    deathRoomCounts, successes, samples)

    table.sort(durations)
    table.sort(remainingRatios)
    local result = {
        samples = samples,
        successCount = successes,
        failureCount = samples - successes,
        passRate = samples > 0 and successes / samples or 0,
        softStuckRate = samples > 0 and (samples - successes) / samples or 0,
        combatSecondsMean = mean(durations) or 0,
        combatSecondsP50 = percentile(durations, 0.50) or 0,
        combatSecondsP90 = percentile(durations, 0.90) or 0,
        combatSecondsP99 = percentile(durations, 0.99) or 0,
        remainingHpRatioMean = mean(remainingRatios) or 0,
        remainingHpRatioP10 = percentile(remainingRatios, 0.10) or 0,
        remainingHpRatioP50 = percentile(remainingRatios, 0.50) or 0,
        deathRoomCounts = deathRoomCounts,
    }
    distributionSummary(successDurations, "successCombatSeconds", result)
    distributionSummary(failureDurations, "failureCombatSeconds", result)
    return result
end

function Simulator.RunTrials(spec)
    assert(type(spec) == "table", "trial specification is required")
    local samples = math.max(1, math.floor(tonumber(spec.samples) or 1))
    local requestedSeed = spec.seed ~= nil and spec.seed or Simulator.DEFAULT_SEED
    local effectiveSeed = Simulator.NormalizeSeed(requestedSeed)
    local rng = Rng.New(effectiveSeed)
    local prepared = prepareCombat(spec.stats, spec.floor, spec.bossKind)
    local durations = {}
    local successDurations = {}
    local failureDurations = {}
    local remainingRatios = {}
    local deathRoomCounts = {}
    local failures = {}
    local successes = 0
    local simulate = spec.scope == "boss" and Simulator.SimulateBoss or Simulator.SimulateRoute
    local maxFailureSeeds = math.max(0, math.floor(spec.maxFailureSeeds or 8))

    for index = 1, samples do
        local trialSeed = rng.state
        local result = simulate(prepared, rng, { model = spec.model or "aggregate" })
        durations[index] = result.combatSeconds
        if result.success then
            successes = successes + 1
            successDurations[#successDurations + 1] = result.combatSeconds
            remainingRatios[#remainingRatios + 1] = result.remainingHpRatio
        else
            failureDurations[#failureDurations + 1] = result.combatSeconds
            local room = math.floor(tonumber(result.deathRoom) or 0)
            deathRoomCounts[room] = (deathRoomCounts[room] or 0) + 1
            if #failures < maxFailureSeeds then
                failures[#failures + 1] = {
                    simulatorVersion = Simulator.VERSION,
                    scenarioId = spec.id,
                    floor = spec.floor,
                    profileId = spec.profileId,
                    scope = spec.scope or "route",
                    model = spec.model or "aggregate",
                    bossKind = prepared.bossKind,
                    cohortSeed = effectiveSeed,
                    trialIndex = index,
                    seed = trialSeed,
                    trialSeed = trialSeed,
                    deathRoom = result.deathRoom,
                    combatSeconds = result.combatSeconds,
                }
            end
        end
    end

    local summary = summarizeTrials(
        durations, successDurations, failureDurations, remainingRatios,
        deathRoomCounts, successes, samples)
    summary.id = spec.id
    summary.floor = spec.floor
    summary.profileId = spec.profileId
    summary.scope = spec.scope or "route"
    summary.model = spec.model or "aggregate"
    summary.requestedSeed = requestedSeed
    summary.seed = effectiveSeed
    summary.effectiveSeed = effectiveSeed
    summary.bossKind = prepared.bossKind
    summary.towerScore = prepared.evaluation.towerScore
    summary.bossScore = prepared.evaluation.bossScore
    summary.eliteScore = prepared.evaluation.eliteScore
    summary.routeSurvivesAnalytic = prepared.evaluation.routeSurvives
    summary.bossTtkSafe = prepared.evaluation.boss.ttk
    summary.bossTtkMean = prepared.evaluation.boss.meanTtk
    summary.simulatorVersion = Simulator.VERSION
    summary.powerEvaluatorVersion = PowerEvaluator.VERSION
    summary.rewardPolicyVersion = RewardPolicy.VERSION
    summary.rarityCatalogVersion = RarityCatalog.VERSION
    summary.towerRulesVersion = TowerRules.VERSION
    summary.rngAlgorithm = Simulator.RNG_ALGORITHM
    summary.failureSeedLimit = maxFailureSeeds
    summary.retainedFailureSeedCount = #failures
    for _, failure in ipairs(failures) do
        failure.totalFailureCount = summary.failureCount
        failure.retainedFailureSeedCount = #failures
        failure.failureSeedLimit = maxFailureSeeds
    end
    summary.failures = failures
    return summary
end

function Simulator.PrepareCombat(stats, floor, bossKind)
    return prepareCombat(stats, floor, bossKind)
end

function Simulator.ActualBossKind(floor)
    return actualBossKind(floor)
end

function Simulator.CombatStatsCopy(stats)
    return combatStatsCopy(stats)
end

function Simulator.RunKeyFloorMatrix(options)
    options = options or {}
    local samples = math.max(1, math.floor(tonumber(options.samples) or Simulator.DEFAULT_SAMPLES))
    local requestedBaseSeed = options.seed ~= nil and options.seed or Simulator.DEFAULT_SEED
    local baseSeed = Simulator.NormalizeSeed(requestedBaseSeed)
    local model = options.model or "aggregate"
    local results, failures = {}, {}
    local groupResults = {}

    for profileIndex, profileId in ipairs(Simulator.PROFILE_ORDER) do
        -- The normalized production formulas are exactly scale invariant. One
        -- regular-boss cohort and one chapter-boss cohort therefore cover all
        -- listed floors without pretending that duplicated random work adds
        -- information.
        for _, group in ipairs(Simulator.MATRIX_GROUPS) do
            local stats = Simulator.BuildProfile(profileId, group.representativeFloor, 1.0)
            local scenarioId = "matrix_" .. profileId .. "_" .. group.key
            local cohortSeed = Simulator.NormalizeSeed(
                baseSeed + profileIndex * 100003 + (group.key == "chapter" and 700001 or 0))
            local summary = Simulator.RunTrials({
                id = scenarioId,
                stats = stats,
                floor = group.representativeFloor,
                bossKind = group.bossKind,
                profileId = profileId,
                samples = samples,
                seed = cohortSeed,
                scope = "route",
                model = model,
            })
            summary.scenarioKind = "key_floor_matrix"
            summary.profileLabel = Simulator.PROFILES[profileId].label
            summary.representativeFloor = group.representativeFloor
            summary.simulationGroup = profileId .. ":" .. group.key
            summary.requestedBaseSeed = requestedBaseSeed
            summary.effectiveBaseSeed = baseSeed
            groupResults[profileId .. ":" .. group.key] = summary
            for _, failure in ipairs(summary.failures) do
                failure.scenarioKind = "key_floor_matrix"
                failure.profileLabel = Simulator.PROFILES[profileId].label
                failure.representativeFloor = group.representativeFloor
                failure.simulationGroup = summary.simulationGroup
                failure.targetPowerRatio = 1.0
                failure.requestedBaseSeed = requestedBaseSeed
                failure.effectiveBaseSeed = baseSeed
                failures[#failures + 1] = failure
            end
        end

        for _, floor in ipairs(Simulator.KEY_FLOORS) do
            local groupKey = floor == 1 and "regular" or "chapter"
            local source = groupResults[profileId .. ":" .. groupKey]
            local stats = Simulator.BuildProfile(profileId, floor, 1.0)
            local display = PowerEvaluator.Evaluate(stats, { floor = floor })
            local row = shallowCopy(source)
            row.failures = nil
            row.id = "matrix_" .. profileId .. "_floor_" .. floor
            row.floor = floor
            row.profileLabel = Simulator.PROFILES[profileId].label
            row.recommendedPower = BigNumber.ToScientificString(TowerRules.RecommendedPower(floor), 6)
            row.displayedPowerRatio = display.powerRatio
            row.equivalentFloor = display.equivalentFloor
            row.headroomFloors = display.headroomFloors
            row.simulationGroup = profileId .. ":" .. groupKey
            row.scaleInvariantReuse = floor ~= (groupKey == "regular" and 1 or 10)
            row.independentCohort = not row.scaleInvariantReuse
            results[#results + 1] = row
        end
    end
    return results, failures
end

function Simulator.RunThresholdScenarios(options)
    options = options or {}
    local samples = math.max(1, math.floor(tonumber(options.samples) or Simulator.DEFAULT_SAMPLES))
    local requestedBaseSeed = options.seed ~= nil and options.seed or Simulator.DEFAULT_SEED
    local baseSeed = Simulator.NormalizeSeed(requestedBaseSeed)
    local model = options.model or "aggregate"
    local results, failures = {}, {}
    for index, scenario in ipairs(Simulator.THRESHOLD_SCENARIOS) do
        for _, scope in ipairs({ "boss", "route" }) do
            local cohortSeed = Simulator.NormalizeSeed(
                baseSeed + index * 200003 + (scope == "route" and 900001 or 0))
            local summary = Simulator.RunTrials({
                id = scenario.id .. "_" .. scope,
                stats = Simulator.BuildUniformBaseline(scenario.floor, scenario.ratio),
                floor = scenario.floor,
                bossKind = scenario.bossKind,
                profileId = "balanced_uniform_" .. scenario.ratio,
                samples = samples,
                seed = cohortSeed,
                scope = scope,
                model = model,
                maxFailureSeeds = 12,
            })
            local gate = scope == "boss"
            summary.attributeRatio = scenario.ratio
            summary.scenarioKind = "threshold"
            summary.measurementRole = scenario.measurementRole
            summary.profileLabel = "Balanced uniform " .. scenario.ratio
            summary.requestedBaseSeed = requestedBaseSeed
            summary.effectiveBaseSeed = baseSeed
            summary.gate = gate
            summary.diagnosticOnly = not gate
            summary.targetPassRate = gate and scenario.bossTarget or nil
            summary.meetsTarget = gate and summary.passRate >= scenario.bossTarget or nil
            results[#results + 1] = summary
            for _, failure in ipairs(summary.failures) do
                failure.scenarioKind = "threshold"
                failure.attributeRatio = scenario.ratio
                failure.measurementRole = scenario.measurementRole
                failure.profileLabel = summary.profileLabel
                failure.representativeFloor = scenario.floor
                failure.targetPassRate = summary.targetPassRate
                failure.gate = gate
                failure.requestedBaseSeed = requestedBaseSeed
                failure.effectiveBaseSeed = baseSeed
                failures[#failures + 1] = failure
            end
            summary.failures = nil
        end
    end
    return results, failures
end

function Simulator.ResolveScenario(scenarioId, options)
    options = options or {}
    local model = options.model or "aggregate"
    for _, scenario in ipairs(Simulator.THRESHOLD_SCENARIOS) do
        for _, scope in ipairs({ "boss", "route" }) do
            if scenarioId == scenario.id .. "_" .. scope then
                return {
                    id = scenarioId,
                    stats = Simulator.BuildUniformBaseline(scenario.floor, scenario.ratio),
                    floor = scenario.floor,
                    bossKind = scenario.bossKind,
                    profileId = "balanced_uniform_" .. scenario.ratio,
                    scope = scope,
                    model = model,
                    scenarioKind = "threshold",
                    attributeRatio = scenario.ratio,
                }
            end
        end
    end

    for _, profileId in ipairs(Simulator.PROFILE_ORDER) do
        for _, group in ipairs(Simulator.MATRIX_GROUPS) do
            if scenarioId == "matrix_" .. profileId .. "_" .. group.key then
                return {
                    id = scenarioId,
                    stats = Simulator.BuildProfile(profileId, group.representativeFloor, 1.0),
                    floor = group.representativeFloor,
                    bossKind = group.bossKind,
                    profileId = profileId,
                    scope = "route",
                    model = model,
                    scenarioKind = "key_floor_matrix",
                    simulationGroup = profileId .. ":" .. group.key,
                }
            end
        end
    end
    return nil, "unknown simulation scenario: " .. tostring(scenarioId)
end

function Simulator.ReplayScenario(scenarioId, trialSeed, options)
    local spec, reason = Simulator.ResolveScenario(scenarioId, options)
    if not spec then return nil, reason end
    spec.samples = 1
    spec.seed = Simulator.NormalizeSeed(trialSeed)
    spec.maxFailureSeeds = 1
    local summary = Simulator.RunTrials(spec)
    summary.scenarioKind = spec.scenarioKind
    summary.attributeRatio = spec.attributeRatio
    summary.simulationGroup = spec.simulationGroup
    return summary
end

local function relativeDifference(left, right)
    if left == right then return 0 end
    if not finite(left) or not finite(right) then return math.huge end
    return math.abs(left - right) / math.max(EPSILON, math.abs(left), math.abs(right))
end

local function invariantMetrics(prepared)
    local maxHp = math.max(EPSILON, prepared.profile.maxHp)
    return {
        towerScore = prepared.evaluation.towerScore,
        bossScore = prepared.evaluation.bossScore,
        eliteScore = prepared.evaluation.eliteScore,
        normalMeanTtk = prepared.metrics.normal.meanTtk,
        eliteMeanTtk = prepared.metrics.elite.meanTtk,
        bossMeanTtk = prepared.metrics[prepared.bossKind].meanTtk,
        normalHitToHp = prepared.metrics.normal.p95SingleHit / maxHp,
        eliteHitToHp = prepared.metrics.elite.p95SingleHit / maxHp,
        bossHitToHp = prepared.metrics[prepared.bossKind].p95SingleHit / maxHp,
    }
end

function Simulator.CheckMatrixScaleInvariant()
    local checks = {}
    local maximum = 0
    for _, profileId in ipairs(Simulator.PROFILE_ORDER) do
        for _, group in ipairs(Simulator.MATRIX_GROUPS) do
            local representative = prepareCombat(
                Simulator.BuildProfile(profileId, group.representativeFloor, 1.0),
                group.representativeFloor,
                group.bossKind)
            local baseline = invariantMetrics(representative)
            for _, floor in ipairs(Simulator.KEY_FLOORS) do
                local belongsToGroup = group.key == "regular" and floor == 1
                    or group.key == "chapter" and floor ~= 1
                if belongsToGroup then
                    local candidate = invariantMetrics(prepareCombat(
                        Simulator.BuildProfile(profileId, floor, 1.0),
                        floor,
                        group.bossKind))
                    local difference = 0
                    for metric, expected in pairs(baseline) do
                        difference = math.max(
                            difference,
                            relativeDifference(expected, candidate[metric]))
                    end
                    maximum = math.max(maximum, difference)
                    checks[#checks + 1] = {
                        profileId = profileId,
                        group = group.key,
                        representativeFloor = group.representativeFloor,
                        floor = floor,
                        maximumRelativeDifference = difference,
                    }
                end
            end
        end
    end
    return {
        checks = checks,
        maximumRelativeDifference = maximum,
        targetMaximum = 1e-9,
        meetsTarget = maximum <= 1e-9,
    }
end

function Simulator.CheckFloorInvariant()
    local stats = Simulator.BuildProfile("balanced", 100, 1.0)
    local at100 = PowerEvaluator.Evaluate(stats, { floor = 100 })
    local at130 = PowerEvaluator.Evaluate(stats, { floor = 130 })
    local logarithmicDifference = math.abs(BigNumber.LogRatio(
        at100.displayedPower, at130.displayedPower) or math.huge)
    local relativeDifference = logarithmicDifference == math.huge
        and math.huge or math.abs(10 ^ logarithmicDifference - 1)
    return {
        simulatorVersion = Simulator.VERSION,
        powerEvaluatorVersion = PowerEvaluator.VERSION,
        towerRulesVersion = TowerRules.VERSION,
        floorA = 100,
        floorB = 130,
        displayedPowerA = BigNumber.ToScientificString(at100.displayedPower, 8),
        displayedPowerB = BigNumber.ToScientificString(at130.displayedPower, 8),
        equivalentFloorA = at100.equivalentFloor,
        equivalentFloorB = at130.equivalentFloor,
        relativeDifference = relativeDifference,
        targetMaximum = 0.001,
        meetsTarget = relativeDifference <= 0.001,
    }
end

return Simulator
