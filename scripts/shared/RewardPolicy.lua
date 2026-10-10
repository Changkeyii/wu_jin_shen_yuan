local BigNumber = require("shared.BigNumber")
local RarityCatalog = require("shared.RarityCatalog")
local TowerRules = require("shared.TowerRules")

local Balance = require("shared.GameBalance")
local RewardPolicy = {}

RewardPolicy.VERSION = 4
RewardPolicy.ONLINE_RATE = 1.0
RewardPolicy.OFFLINE_RATE = 0.20
RewardPolicy.WEAK_SLOT_BIAS = 0.65
RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN = 0.02
RewardPolicy.AUTO_EQUIP_MINIMUM_ELITE_RETENTION = 0.99
RewardPolicy.AUTO_EQUIP_MINIMUM_SURVIVAL_MARGIN = 1.25
RewardPolicy.AID_FAILURE_THRESHOLD = 2
RewardPolicy.AID_MINIMUM_POWER_GAIN = 0.02
RewardPolicy.AID_TARGET_RECOMMENDED_RATIO = 0.88
RewardPolicy.AID_MINIMUM_REMAINING_HP_RATIO = 0.08
RewardPolicy.EPIC_SOFT_PITY_ATTEMPT = 10
RewardPolicy.EPIC_HARD_PITY_ATTEMPT = 20
RewardPolicy.MYTH_HARD_PITY_ATTEMPT = 100

RewardPolicy.SLOT_ORDER = {
    "weapon", "shoulder", "coat", "pants", "belt", "shoes",
    "bracelet", "necklace", "ring", "support", "magicstone", "earring",
}

RewardPolicy.SLOT_WEIGHTS = {
    weapon = 1550,
    shoulder = 840,
    coat = 840,
    pants = 840,
    belt = 840,
    shoes = 840,
    bracelet = 670,
    necklace = 670,
    ring = 670,
    support = 710,
    magicstone = 765,
    earring = 765,
}

RewardPolicy.STAR_MULTIPLIERS = { 1.00, 1.08, 1.17, 1.27, 1.38, 1.50 }

RewardPolicy.DROP_CHANCES = {
    normal = 0.12,
    elite = 0.35,
    boss = 1.00,
    chapterBoss = 1.00,
}

-- Percent weights.  Locked-quality weight is moved to the highest quality
-- available on that floor instead of being silently discarded.
RewardPolicy.SOURCE_QUALITY_WEIGHTS = {
    normal = {
        common = 55, advanced = 30, rare = 12, artifact = 2.5,
        legendary = 0.45, epic = 0.049, myth = 0.001,
    },
    elite = {
        common = 25, advanced = 35, rare = 28, artifact = 10,
        legendary = 1.7, epic = 0.29, myth = 0.01,
    },
    boss = {
        common = 0, advanced = 0, rare = 65, artifact = 27,
        legendary = 6.5, epic = 1.45, myth = 0.05,
    },
    chapterBoss = {
        common = 0, advanced = 0, rare = 0, artifact = 0,
        legendary = 92, epic = 7.8, myth = 0.2,
    },
}

local SOURCE_ALIASES = {
    normal = "normal",
    elite = "elite",
    boss = "boss",
    chapterBoss = "chapterBoss",
    chapter_boss = "chapterBoss",
    chapter = "chapterBoss",
}

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function normalizeSource(source)
    return SOURCE_ALIASES[source]
end

local function rarityId(value)
    if type(value) == "table" then return value.id end
    return value
end

local function rarityIndex(id)
    id = rarityId(id)
    for index, candidate in ipairs(RarityCatalog.ORDER) do
        if candidate == id then return index end
    end
    return nil
end

local function pityMisses(pity, name)
    if type(pity) ~= "table" then return 0 end
    return math.max(0, math.floor(tonumber(pity[name .. "Misses"] or pity[name]) or 0))
end

local function transferTo(weights, targetId, predicate)
    local transferred = 0
    for _, id in ipairs(RarityCatalog.ORDER) do
        if predicate(id) then
            transferred = transferred + (weights[id] or 0)
            weights[id] = 0
        end
    end
    weights[targetId] = (weights[targetId] or 0) + transferred
end

local function applyEpicPity(weights, floor, pity)
    if floor < (RarityCatalog.Get("epic").unlockFloor or 50) then return end
    local epicIndex = assert(rarityIndex("epic"))
    local attempt = pityMisses(pity, "epic") + 1

    if attempt >= RewardPolicy.EPIC_HARD_PITY_ATTEMPT then
        transferTo(weights, "epic", function(id)
            return (rarityIndex(id) or 0) < epicIndex
        end)
        return
    end
    if attempt < RewardPolicy.EPIC_SOFT_PITY_ATTEMPT then return end

    local highWeight = (weights.epic or 0) + (weights.myth or 0)
    local progress = (attempt - RewardPolicy.EPIC_SOFT_PITY_ATTEMPT + 1)
        / (RewardPolicy.EPIC_HARD_PITY_ATTEMPT - RewardPolicy.EPIC_SOFT_PITY_ATTEMPT + 1)
    local targetHighWeight = highWeight + (100 - highWeight) * progress
    local requestedTransfer = math.max(0, targetHighWeight - highWeight)
    local lowerWeight = 0
    for _, id in ipairs(RarityCatalog.ORDER) do
        if (rarityIndex(id) or 0) < epicIndex then lowerWeight = lowerWeight + (weights[id] or 0) end
    end
    if lowerWeight <= 0 then return end

    local transferRatio = math.min(1, requestedTransfer / lowerWeight)
    local transferred = 0
    for _, id in ipairs(RarityCatalog.ORDER) do
        if (rarityIndex(id) or 0) < epicIndex then
            local amount = (weights[id] or 0) * transferRatio
            weights[id] = (weights[id] or 0) - amount
            transferred = transferred + amount
        end
    end
    weights.epic = (weights.epic or 0) + transferred
end

local function applyMythPity(weights, floor, pity)
    if floor < (RarityCatalog.Get("myth").unlockFloor or 100) then return end
    local attempt = pityMisses(pity, "myth") + 1
    if attempt < RewardPolicy.MYTH_HARD_PITY_ATTEMPT then return end
    transferTo(weights, "myth", function(id) return id ~= "myth" end)
end

function RewardPolicy.NormalizeSource(source)
    return normalizeSource(source)
end

function RewardPolicy.RewardRate(mode)
    local offline = mode == true or mode == "offline"
    return offline and RewardPolicy.OFFLINE_RATE or RewardPolicy.ONLINE_RATE
end

function RewardPolicy.ScaleReward(value, mode)
    value = math.max(0, tonumber(value) or 0)
    return value * RewardPolicy.RewardRate(mode)
end

function RewardPolicy.ScaleFixedReward(value, mode)
    return math.floor(RewardPolicy.ScaleReward(value, mode))
end

function RewardPolicy.DropChance(source, mode)
    source = normalizeSource(source)
    local chance = source and RewardPolicy.DROP_CHANCES[source] or 0
    return chance * RewardPolicy.RewardRate(mode)
end

function RewardPolicy.ShouldDrop(source, roll, mode)
    return clamp(roll, 0, 1) < RewardPolicy.DropChance(source, mode)
end

function RewardPolicy.GetQualityWeights(source, floor, pity)
    source = normalizeSource(source)
    local configured = source and RewardPolicy.SOURCE_QUALITY_WEIGHTS[source]
    if not configured then return nil end
    floor = math.max(1, math.floor(tonumber(floor) or 1))
    local highest = rarityId(RarityCatalog.HighestUnlocked(floor))
    local weights = {}
    for _, id in ipairs(RarityCatalog.ORDER) do weights[id] = 0 end

    for _, id in ipairs(RarityCatalog.ORDER) do
        local amount = configured[id] or 0
        if RarityCatalog.IsUnlocked(id, floor) then
            weights[id] = weights[id] + amount
        else
            weights[highest] = weights[highest] + amount
        end
    end

    if source == "chapterBoss" then
        applyEpicPity(weights, floor, pity)
        applyMythPity(weights, floor, pity)
    end
    return weights
end

function RewardPolicy.RollRarity(source, floor, roll, pity)
    local weights = RewardPolicy.GetQualityWeights(source, floor, pity)
    if not weights then return nil end
    roll = clamp(roll, 0, 1)
    if roll >= 1 then roll = 1 - 1e-12 end
    local total = 0
    for _, id in ipairs(RarityCatalog.ORDER) do total = total + (weights[id] or 0) end
    local threshold = roll * total
    local accumulated = 0
    local fallback = RarityCatalog.ORDER[#RarityCatalog.ORDER]
    for _, id in ipairs(RarityCatalog.ORDER) do
        accumulated = accumulated + (weights[id] or 0)
        if threshold < accumulated then return id end
        if (weights[id] or 0) > 0 then fallback = id end
    end
    return fallback
end

function RewardPolicy.UpdatePity(pity, droppedRarity)
    local result = {
        epicMisses = pityMisses(pity, "epic"),
        mythMisses = pityMisses(pity, "myth"),
    }
    local droppedIndex = rarityIndex(droppedRarity) or 0
    if droppedIndex >= assert(rarityIndex("epic")) then
        result.epicMisses = 0
    else
        result.epicMisses = result.epicMisses + 1
    end
    if rarityId(droppedRarity) == "myth" then
        result.mythMisses = 0
    else
        result.mythMisses = result.mythMisses + 1
    end
    result.epicMisses = math.min(RewardPolicy.EPIC_HARD_PITY_ATTEMPT, result.epicMisses)
    result.mythMisses = math.min(RewardPolicy.MYTH_HARD_PITY_ATTEMPT, result.mythMisses)
    return result
end

function RewardPolicy.RollMultiplier(roll)
    return 0.95 + clamp(roll == nil and 0.5 or roll, 0, 1) * 0.10
end

function RewardPolicy.EnhanceMultiplier(level)
    level = math.max(0, tonumber(level) or 0)
    return math.max(1 + 0.025 * math.min(Balance.ENHANCE_LIMIT, level),
        1 + 0.35 * (1 - math.exp(-level / 20)))
end

function RewardPolicy.StarMultiplier(star)
    star = math.floor(clamp(star, 0, 5))
    return RewardPolicy.STAR_MULTIPLIERS[star + 1]
end

local function qualityMultiplier(rarity)
    local definition = RarityCatalog.Get(rarityId(rarity))
    return definition and (definition.multiplier or definition.qualityMultiplier) or nil
end

function RewardPolicy.ItemBudgetWithMultiplier(slot, itemLevel, rarity, rollMultiplier, enhance, star)
    local slotWeight = RewardPolicy.SLOT_WEIGHTS[slot]
    local quality = qualityMultiplier(rarity)
    if not slotWeight or not quality then return BigNumber.Zero() end
    local scalar = 85000 * slotWeight / 10000
        * quality
        * clamp(rollMultiplier, 0.95, 1.05)
        * RewardPolicy.EnhanceMultiplier(enhance)
        * RewardPolicy.StarMultiplier(star)
    return BigNumber.MultiplyScalar(Balance.EquipmentGrowth(itemLevel), scalar)
end

function RewardPolicy.ItemBudget(slot, itemLevel, rarity, roll, enhance, star)
    return RewardPolicy.ItemBudgetWithMultiplier(
        slot, itemLevel, rarity, RewardPolicy.RollMultiplier(roll), enhance, star)
end

function RewardPolicy.ItemBudgetNumber(slot, itemLevel, rarity, roll, enhance, star)
    return BigNumber.ToNumber(RewardPolicy.ItemBudget(slot, itemLevel, rarity, roll, enhance, star))
end

function RewardPolicy.ItemBudgetBreakdown(slot, itemLevel, rarity, roll, enhance, star)
    local rollMultiplier = RewardPolicy.RollMultiplier(roll)
    local budget = RewardPolicy.ItemBudgetWithMultiplier(
        slot, itemLevel, rarity, rollMultiplier, enhance, star)
    return {
        budget = budget,
        budgetNumber = BigNumber.ToNumber(budget),
        slotWeight = RewardPolicy.SLOT_WEIGHTS[slot],
        qualityMultiplier = qualityMultiplier(rarity),
        rollMultiplier = rollMultiplier,
        enhanceMultiplier = RewardPolicy.EnhanceMultiplier(enhance),
        starMultiplier = RewardPolicy.StarMultiplier(star),
    }
end

local function choose(values, roll)
    if type(values) ~= "table" or #values == 0 then return nil end
    roll = clamp(roll, 0, 1)
    local index = math.min(#values, math.floor(roll * #values) + 1)
    return values[index]
end

function RewardPolicy.PickDropSlot(allSlots, weakSlots, biasRoll, indexRoll)
    local candidates = allSlots
    if type(weakSlots) == "table" and #weakSlots > 0
        and clamp(biasRoll, 0, 1) < RewardPolicy.WEAK_SLOT_BIAS then
        candidates = weakSlots
    end
    return choose(candidates, indexRoll)
end

function RewardPolicy.AutoEquipSurvivalMarginPasses(beforeMargin, afterMargin)
    local before = math.max(0, tonumber(beforeMargin) or 0)
    local after = math.max(0, tonumber(afterMargin) or 0)
    local required = math.min(RewardPolicy.AUTO_EQUIP_MINIMUM_SURVIVAL_MARGIN, before)
    return after >= required
end

function RewardPolicy.ShouldGrantAid(consecutiveFailures, alreadyGranted)
    return alreadyGranted ~= true
        and math.max(0, math.floor(tonumber(consecutiveFailures) or 0))
            >= RewardPolicy.AID_FAILURE_THRESHOLD
end

return RewardPolicy
