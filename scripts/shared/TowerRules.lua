local BigNumber = require("shared.BigNumber")

local TowerRules = {}

TowerRules.VERSION = 3
TowerRules.LOG10_2 = math.log(2) / math.log(10)
TowerRules.FLOORS_PER_DOUBLING = 50
TowerRules.RECOMMENDED_POWER_BASE = 90000
TowerRules.DIFFICULTY_OFFSET_START_FLOOR = 10
TowerRules.DIFFICULTY_OFFSET_FULL_FLOOR = 50
TowerRules.DIFFICULTY_MAX_OFFSET_FLOORS = 10
TowerRules.ENCOUNTERS_PER_FLOOR = 10
TowerRules.NORMAL_ENCOUNTERS = 7
TowerRules.ELITE_ENCOUNTERS = 2
TowerRules.BOSS_ENCOUNTER = 10
TowerRules.MONSTER_ATTACK_INTERVAL = 1.5
TowerRules.BOSS_ENRAGE_SECONDS = 30
TowerRules.BOSS_ENRAGE_DAMAGE_MULTIPLIER = 1.5
TowerRules.BOSS_ENRAGE_ATTACK_SPEED_MULTIPLIER = 1.3
TowerRules.MIN_ATTACK_PRESENTATION_SECONDS = 0.8
TowerRules.OFFLINE_REWARD_RATE = 0.20

TowerRules.PLAYER_BASELINE = {
    attack = 90,
    defense = 85,
    maxHp = 2200,
    critRate = 0.10,
    critDamage = 1.50,
    attackSpeed = 1.0,
}

TowerRules.MONSTER_COEFFICIENTS = {
    normal = { hp = 170, attack = 30, defense = 20 },
    elite = { hp = 420, attack = 60, defense = 35 },
    boss = { hp = 850, attack = 150, defense = 50 },
    chapterBoss = { hp = 1150, attack = 190, defense = 60 },
}

TowerRules.ATTACK_SEQUENCES = {
    attackA = {
        id = "attackA",
        duration = 2.00,
        fps = 16,
        hitFrames = { 14, 16, 18, 20 },
        weights = { 0.30, 0.40, 0.50, 0.80 },
    },
    attackB = {
        id = "attackB",
        duration = 2.25,
        fps = 16,
        hitFrames = { 16, 20, 22, 24 },
        weights = { 0.35, 0.45, 0.60, 0.85 },
    },
    attackC = {
        id = "attackC",
        duration = 2.00,
        fps = 16,
        hitFrames = { 12, 14, 16, 18 },
        weights = { 0.25, 0.35, 0.55, 0.85 },
    },
}

TowerRules.ATTACK_SEQUENCE_ORDER = { "attackA", "attackB", "attackC" }

local KIND_ALIASES = {
    normal = "normal",
    elite = "elite",
    boss = "boss",
    chapterBoss = "chapterBoss",
    chapter_boss = "chapterBoss",
    chapter = "chapterBoss",
}

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function positiveFloor(floor)
    floor = tonumber(floor) or 1
    if not finite(floor) then return 1 end
    return math.max(1, floor)
end

local function copyArray(values)
    local result = {}
    for index, value in ipairs(values) do result[index] = value end
    return result
end

local function scaledStat(growth, coefficient)
    local big = BigNumber.MultiplyScalar(growth, coefficient)
    return big, BigNumber.ToNumber(big)
end

function TowerRules.NormalizeMonsterKind(kind)
    return KIND_ALIASES[kind]
end

-- log10(G(F)) is the canonical representation.  No high-floor path calls
-- 2 ^ ((F - 1) / 50), so growth cannot overflow while being generated.
function TowerRules.GrowthLog10(floor)
    floor = tonumber(floor) or 1
    if not finite(floor) then floor = 1 end
    return (floor - 1) * TowerRules.LOG10_2 / TowerRules.FLOORS_PER_DOUBLING
end

function TowerRules.Growth(floor)
    return BigNumber.FromLog10(TowerRules.GrowthLog10(floor))
end

function TowerRules.GrowthNumber(floor)
    return BigNumber.ToNumber(TowerRules.Growth(floor))
end

function TowerRules.DifficultyOffsetFloors(floor)
    floor = tonumber(floor) or 1
    if not finite(floor) then floor = 1 end
    local startFloor = TowerRules.DIFFICULTY_OFFSET_START_FLOOR
    local fullFloor = TowerRules.DIFFICULTY_OFFSET_FULL_FLOOR
    if floor <= startFloor then return 0 end
    if floor >= fullFloor then return TowerRules.DIFFICULTY_MAX_OFFSET_FLOORS end
    local progress = (floor - startFloor) / (fullFloor - startFloor)
    local smoothProgress = progress * progress * (3 - 2 * progress)
    return TowerRules.DIFFICULTY_MAX_OFFSET_FLOORS * smoothProgress
end

function TowerRules.DifficultyGrowthLog10(floor)
    floor = tonumber(floor) or 1
    if not finite(floor) then floor = 1 end
    return TowerRules.GrowthLog10(floor + TowerRules.DifficultyOffsetFloors(floor))
end

function TowerRules.DifficultyGrowth(floor)
    return BigNumber.FromLog10(TowerRules.DifficultyGrowthLog10(floor))
end

function TowerRules.DifficultyGrowthNumber(floor)
    return BigNumber.ToNumber(TowerRules.DifficultyGrowth(floor))
end

function TowerRules.RecommendedPower(floor)
    return BigNumber.MultiplyScalar(
        TowerRules.DifficultyGrowth(floor), TowerRules.RECOMMENDED_POWER_BASE)
end

function TowerRules.RecommendedPowerNumber(floor)
    return BigNumber.ToNumber(TowerRules.RecommendedPower(floor))
end

function TowerRules.PlayerBaseline(floor)
    floor = positiveFloor(floor)
    local growth = TowerRules.DifficultyGrowth(floor)
    local attackBig, attack = scaledStat(growth, TowerRules.PLAYER_BASELINE.attack)
    local defenseBig, defense = scaledStat(growth, TowerRules.PLAYER_BASELINE.defense)
    local hpBig, hp = scaledStat(growth, TowerRules.PLAYER_BASELINE.maxHp)
    return {
        floor = floor,
        growth = growth,
        growthNumber = BigNumber.ToNumber(growth),
        attack = attack,
        atk = attack,
        attackBig = attackBig,
        atkBig = attackBig,
        defense = defense,
        def = defense,
        defenseBig = defenseBig,
        defBig = defenseBig,
        maxHp = hp,
        hp = hp,
        maxHpBig = hpBig,
        hpBig = hpBig,
        critRate = TowerRules.PLAYER_BASELINE.critRate,
        crit = TowerRules.PLAYER_BASELINE.critRate,
        critDamage = TowerRules.PLAYER_BASELINE.critDamage,
        critDmg = TowerRules.PLAYER_BASELINE.critDamage,
        attackSpeed = TowerRules.PLAYER_BASELINE.attackSpeed,
        atkSpeed = TowerRules.PLAYER_BASELINE.attackSpeed,
        lifeSteal = 0,
        damageReduction = 0,
    }
end

function TowerRules.MonsterStatsNormalized(kind)
    kind = TowerRules.NormalizeMonsterKind(kind)
    local coefficients = kind and TowerRules.MONSTER_COEFFICIENTS[kind]
    if not coefficients then return nil end
    return {
        kind = kind,
        hp = coefficients.hp,
        attack = coefficients.attack,
        atk = coefficients.attack,
        defense = coefficients.defense,
        def = coefficients.defense,
        attackInterval = TowerRules.MONSTER_ATTACK_INTERVAL,
        enrageSeconds = (kind == "boss" or kind == "chapterBoss")
            and TowerRules.BOSS_ENRAGE_SECONDS or nil,
        enrageDamageMultiplier = (kind == "boss" or kind == "chapterBoss")
            and TowerRules.BOSS_ENRAGE_DAMAGE_MULTIPLIER or nil,
        enrageAttackSpeedMultiplier = (kind == "boss" or kind == "chapterBoss")
            and TowerRules.BOSS_ENRAGE_ATTACK_SPEED_MULTIPLIER or nil,
    }
end

function TowerRules.MonsterStats(floor, kind)
    floor = positiveFloor(floor)
    local normalized = TowerRules.MonsterStatsNormalized(kind)
    if not normalized then return nil end
    local growth = TowerRules.DifficultyGrowth(floor)
    local hpBig, hp = scaledStat(growth, normalized.hp)
    local attackBig, attack = scaledStat(growth, normalized.attack)
    local defenseBig, defense = scaledStat(growth, normalized.defense)
    return {
        floor = floor,
        kind = normalized.kind,
        growth = growth,
        hp = hp,
        hpBig = hpBig,
        attack = attack,
        atk = attack,
        attackBig = attackBig,
        atkBig = attackBig,
        defense = defense,
        def = defense,
        defenseBig = defenseBig,
        defBig = defenseBig,
        attackInterval = normalized.attackInterval,
        enrageSeconds = normalized.enrageSeconds,
        enrageDamageMultiplier = normalized.enrageDamageMultiplier,
        enrageAttackSpeedMultiplier = normalized.enrageAttackSpeedMultiplier,
        regenerates = false,
    }
end

-- 交互事件只占用普通房，精英房与 Boss 房永不被替换。
TowerRules.EVENT_ROOMS = { 3, 6 }
TowerRules.EVENT_START_FLOOR = 2
TowerRules.INTERACTIVE_EVENTS = { "chest", "merchant", "randomEvent" }

TowerRules.INTERACTIVE_EVENT_SET = {
    chest = true,
    merchant = true,
    randomEvent = true,
}

function TowerRules.IsInteractiveEvent(kind)
    return TowerRules.INTERACTIVE_EVENT_SET[kind] == true
end

-- 纯函数散列：同一 floor/room 在服务端与客户端得到相同事件，无需同步随机数。
local function eventHash(floor, room)
    local hash = (floor * 2654435761 + room * 40503) % 2147483647
    hash = (hash * 1103515245 + 12345) % 2147483647
    return hash
end

local function interactiveEventFor(floor, room)
    if floor < TowerRules.EVENT_START_FLOOR then return nil end

    local slot = nil
    for index, eventRoom in ipairs(TowerRules.EVENT_ROOMS) do
        if eventRoom == room then
            slot = index
            break
        end
    end
    if not slot then return nil end

    local hash = eventHash(floor, room)
    -- 每个候选房约 50% 概率出现事件，避免战斗节奏被完全打断。
    if hash % 2 == 0 then return nil end

    local pick = math.floor(hash / 2) % #TowerRules.INTERACTIVE_EVENTS
    return TowerRules.INTERACTIVE_EVENTS[pick + 1], (math.floor(hash / 8) % 3) + 1
end

function TowerRules.GetEncounter(room, floor)
    room = math.floor(tonumber(room) or 0)
    floor = math.floor(positiveFloor(floor))
    if room < 1 or room > TowerRules.ENCOUNTERS_PER_FLOOR then return nil end

    local kind
    if room <= TowerRules.NORMAL_ENCOUNTERS then
        kind = "normal"
    elseif room <= TowerRules.NORMAL_ENCOUNTERS + TowerRules.ELITE_ENCOUNTERS then
        kind = "elite"
    elseif floor % 10 == 0 then
        kind = "chapterBoss"
    else
        kind = "boss"
    end

    local variant = nil
    if kind == "normal" then
        local eventKind, eventVariant = interactiveEventFor(floor, room)
        if eventKind then
            kind = eventKind
            variant = eventVariant
        end
    end

    local interactive = TowerRules.IsInteractiveEvent(kind)
    return {
        room = room,
        floor = floor,
        kind = kind,
        eventType = kind,
        isBoss = kind == "boss" or kind == "chapterBoss",
        isChapterBoss = kind == "chapterBoss",
        isInteractive = interactive,
        variant = variant,
    }
end

function TowerRules.AttackSequence(id)
    if type(id) == "number" then id = TowerRules.ATTACK_SEQUENCE_ORDER[id] end
    local source = TowerRules.ATTACK_SEQUENCES[id]
    if not source then return nil end

    local totalWeight = 0
    local squareWeight = 0
    local hits = {}
    for index, weight in ipairs(source.weights) do
        totalWeight = totalWeight + weight
        squareWeight = squareWeight + weight * weight
        hits[index] = { weight = weight, hitFrame = source.hitFrames[index] }
    end

    return {
        id = source.id,
        duration = source.duration,
        fps = source.fps,
        hitFrames = copyArray(source.hitFrames),
        weights = copyArray(source.weights),
        hits = hits,
        totalWeight = totalWeight,
        squareWeight = squareWeight,
    }
end

function TowerRules.AttackDuration(id, attackSpeed)
    local sequence = TowerRules.AttackSequence(id)
    if not sequence then return nil end
    attackSpeed = math.max(0.01, tonumber(attackSpeed) or 1)
    return math.max(
        TowerRules.MIN_ATTACK_PRESENTATION_SECONDS,
        sequence.duration / attackSpeed
    )
end

function TowerRules.DefenseMultiplier(defense, growth)
    growth = growth or 1
    local defenseRatio
    if type(defense) == "table" or type(growth) == "table" then
        defenseRatio = BigNumber.Ratio(defense, growth) or math.huge
    else
        growth = tonumber(growth) or 1
        defenseRatio = growth > 0 and math.max(0, (tonumber(defense) or 0) / growth) or math.huge
    end
    return 100 / (100 + defenseRatio)
end

function TowerRules.DamageAfterDefense(attack, defense, growth)
    local multiplier = TowerRules.DefenseMultiplier(defense, growth)
    if type(attack) == "table" then
        return BigNumber.MultiplyScalar(attack, multiplier)
    end
    return math.max(0, tonumber(attack) or 0) * multiplier
end

return TowerRules
