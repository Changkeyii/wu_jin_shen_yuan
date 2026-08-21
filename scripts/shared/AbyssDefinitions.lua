local AbyssDefinitions = {}

AbyssDefinitions.VERSION = 1
AbyssDefinitions.STARTER_TICKETS = 120
AbyssDefinitions.BASE_TICKET_COST = 40
AbyssDefinitions.TICKET_COST_PER_LEVEL_BAND = 10
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
        dropChance = 0.35,
        fragments = 12,
        randomWeight = 70,
        qualityWeights = {
            common = 12, advanced = 28, rare = 35, artifact = 19,
            legendary = 5.4, epic = 0.58, myth = 0.02,
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
        dropChance = 0.65,
        fragments = 24,
        randomWeight = 25,
        qualityWeights = {
            common = 2, advanced = 10, rare = 36, artifact = 34,
            legendary = 15.5, epic = 2.4, myth = 0.1,
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
        dropChance = 0.90,
        fragments = 40,
        randomWeight = 5,
        qualityWeights = {
            common = 0, advanced = 2, rare = 20, artifact = 38,
            legendary = 33, epic = 6.7, myth = 0.3,
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
    level = math.max(1, math.floor(tonumber(level) or 1))
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
    return math.max(level, floor)
end

function AbyssDefinitions.EquipmentLevelPool(level)
    level = math.max(1, math.floor(tonumber(level) or 1))
    local band = math.floor((level - 1) / AbyssDefinitions.LEVEL_BAND_SIZE)
    local minLevel = band * AbyssDefinitions.LEVEL_BAND_SIZE + 1
    local maxLevel = (band + 1) * AbyssDefinitions.LEVEL_BAND_SIZE
    return minLevel, maxLevel, band + 1
end

function AbyssDefinitions.RecommendedPower(level, gradeId)
    local TowerRules = require("shared.TowerRules")
    local BigNumber = require("shared.BigNumber")
    local grade = GRADES[gradeId] or GRADES.rift
    local _, maxLevel = AbyssDefinitions.EquipmentLevelPool(level)
    local equivalentFloor = math.max(1, maxLevel * 2)
    return BigNumber.MultiplyScalar(
        TowerRules.RecommendedPower(equivalentFloor),
        grade.multiplier
    )
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
        dryStreak = 0,
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
