local Progression = require("shared.GameProgression")
local Balance = require("shared.GameBalance")
local AbyssDefinitions = {}

AbyssDefinitions.VERSION = 1
AbyssDefinitions.STARTER_TICKETS = 120
AbyssDefinitions.BASE_TICKET_COST = 20
AbyssDefinitions.TICKET_COST_PER_LEVEL_BAND = 2
AbyssDefinitions.LEVEL_BAND_SIZE = 10
AbyssDefinitions.HARD_PITY_ATTEMPT = 6
AbyssDefinitions.RANDOM_TRIGGER_CHANCE = 0.04
AbyssDefinitions.RANDOM_COOLDOWN_BATTLES = 20
AbyssDefinitions.ICON = "image/abyss_ticket_20260819022441.png"
AbyssDefinitions.AD_REWARD_MULTIPLIER = 5
AbyssDefinitions.ACTIVE_TICKET_REFUND_RATE = 0.25
AbyssDefinitions.RANDOM_TICKET_REWARD_RATE = 0.50
AbyssDefinitions.DAILY_AD_TICKET_RATE = 0.80
AbyssDefinitions.DAILY_AD_TICKET_LIMIT = 3

AbyssDefinitions.ORDER = { "rift", "mutated", "calamity" }

local GRADES = {
    rift = {
        id = "rift",
        name = "裂隙深渊",
        shortName = "裂隙",
        multiplier = 1,
        minLevel = 1,
        color = { 41, 182, 255, 255 },
        colorHex = "#29B6FF",
        dropChance = 0.70,
        fragments = 12,
        randomWeight = 70,
        qualityWeights = {
            common = 0, advanced = 0, rare = 20, artifact = 40,
            legendary = 30, epic = 9.5, myth = 0.5,
        },
    },
    mutated = {
        id = "mutated",
        name = "异变深渊",
        shortName = "异变",
        multiplier = 2,
        minLevel = 20,
        color = { 177, 92, 255, 255 },
        colorHex = "#B15CFF",
        dropChance = 0.85,
        fragments = 24,
        randomWeight = 25,
        qualityWeights = {
            common = 0, advanced = 0, rare = 0, artifact = 30,
            legendary = 44, epic = 25, myth = 1,
        },
    },
    calamity = {
        id = "calamity",
        name = "灾厄深渊",
        shortName = "灾厄",
        multiplier = 3,
        minLevel = 40,
        color = { 255, 138, 36, 255 },
        colorHex = "#FF8A24",
        dropChance = 1.00,
        fragments = 40,
        randomWeight = 5,
        qualityWeights = {
            common = 0, advanced = 0, rare = 0, artifact = 0,
            legendary = 55, epic = 42, myth = 3,
        },
    },
}

function AbyssDefinitions.Get(gradeId)
    return GRADES[gradeId]
end

function AbyssDefinitions.IsKnownGrade(gradeId)
    return GRADES[gradeId] ~= nil
end

function AbyssDefinitions.IsUnlocked(gradeId, level)
    local grade = GRADES[gradeId]
    return grade ~= nil and math.max(1, math.floor(tonumber(level) or 1)) >= grade.minLevel
end

function AbyssDefinitions.BaseTicketCost(level)
    level = Progression.Level(level)
    local band = math.floor((level - 1) / AbyssDefinitions.LEVEL_BAND_SIZE)
    return AbyssDefinitions.BASE_TICKET_COST
        + band * AbyssDefinitions.TICKET_COST_PER_LEVEL_BAND
end

function AbyssDefinitions.TicketCost(level, gradeId)
    local grade = GRADES[gradeId]
    if not grade then return nil end
    return AbyssDefinitions.BaseTicketCost(level) * grade.multiplier
end

function AbyssDefinitions.DropPoolFloor(state)
    state = type(state) == "table" and state or {}
    local level = math.max(1, math.floor(tonumber(state.level) or 1))
    local floor = math.max(1, math.floor(tonumber(state.maxFloor or state.floor) or 1))
    return Progression.Level(level)
end

function AbyssDefinitions.EquipmentLevelPool(level)
    local maximum = Progression.EquipmentLevel(level)
    return maximum == 100 and 100 or math.max(5, maximum - 5), maximum, math.max(1, math.floor(maximum / 5))
end

function AbyssDefinitions.BossHp(level, gradeId)
    local mul = ({ rift = 0.8, mutated = 1.15, calamity = 1.6 })[gradeId] or 0.8
    return math.floor(1400 * Balance.TrialGrowth(Progression.EquipmentLevel(level)) * mul)
end

function AbyssDefinitions.RecommendedPower(level, gradeId)
    local BigNumber = require("shared.BigNumber")
    local mul = ({ rift = 0.8, mutated = 1.15, calamity = 1.6 })[gradeId] or 0.8
    return BigNumber.MultiplyScalar(Balance.EquipmentGrowth(Progression.EquipmentLevel(level)), 100000 * mul)
end

function AbyssDefinitions.DailyAdTickets(level)
    local cost = AbyssDefinitions.TicketCost(level, "calamity") or 0
    return math.max(1, math.ceil(cost * AbyssDefinitions.DAILY_AD_TICKET_RATE))
end

function AbyssDefinitions.HighestUnlocked(level)
    local result = GRADES.rift
    for _, gradeId in ipairs(AbyssDefinitions.ORDER) do
        local grade = GRADES[gradeId]
        if AbyssDefinitions.IsUnlocked(gradeId, level) then result = grade end
    end
    return result
end

function AbyssDefinitions.Rank(gradeId)
    for index, candidate in ipairs(AbyssDefinitions.ORDER) do
        if candidate == gradeId then return index end
    end
    return 0
end

function AbyssDefinitions.NewState()
    return {
        tickets = AbyssDefinitions.STARTER_TICKETS,
        dryStreak = 0, epicMisses = 0, mythMisses = 0,
        activeRuns = 0,
        randomRuns = 0,
        equipmentDrops = 0,
        highestGrade = "rift",
        randomCooldownBattles = 0,
        currentRandom = nil,
    }
end

function AbyssDefinitions.BuildView(state)
    state = type(state) == "table" and state or {}
    local level = math.max(1, math.floor(tonumber(state.level) or 1))
    local abyss = type(state.abyss) == "table" and state.abyss
        or AbyssDefinitions.NewState()
    local grades = {}
    for _, gradeId in ipairs(AbyssDefinitions.ORDER) do
        local grade = GRADES[gradeId]
        grades[#grades + 1] = {
            id = grade.id,
            name = grade.name,
            shortName = grade.shortName,
            multiplier = grade.multiplier,
            minLevel = grade.minLevel,
            color = grade.color,
            colorHex = grade.colorHex,
            dropChance = grade.dropChance,
            fragments = grade.fragments,
            unlocked = AbyssDefinitions.IsUnlocked(gradeId, level),
            ticketCost = AbyssDefinitions.TicketCost(level, gradeId),
            recommendedPower = AbyssDefinitions.RecommendedPower(level, gradeId),
        }
    end
    local poolMin, poolMax, poolBand = AbyssDefinitions.EquipmentLevelPool(level)
    return {
        tickets = math.max(0, math.floor(tonumber(abyss.tickets) or 0)),
        dryStreak = math.max(0, math.floor(tonumber(abyss.dryStreak) or 0)),
        guaranteeAt = AbyssDefinitions.HARD_PITY_ATTEMPT,
        epicMisses = abyss.epicMisses or 0, mythMisses = abyss.mythMisses or 0,
        epicGuaranteeAt = 10, mythGuaranteeAt = 40,
        baseTicketCost = AbyssDefinitions.BaseTicketCost(level),
        dailyAdTickets = AbyssDefinitions.DailyAdTickets(level),
        dailyAdLimit = AbyssDefinitions.DAILY_AD_TICKET_LIMIT,
        equipmentPoolMin = poolMin,
        equipmentPoolMax = poolMax,
        equipmentPoolBand = poolBand,
        grades = grades,
        currentRandom = abyss.currentRandom,
    }
end

AbyssDefinitions.GRADES = GRADES
return AbyssDefinitions
