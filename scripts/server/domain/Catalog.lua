local Catalog = {}
local BigNumber = require("shared.BigNumber")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local LargeNumber = require("shared.LargeNumber")
local PowerEvaluator = require("shared.PowerEvaluator")
local RarityCatalog = require("shared.RarityCatalog")
local RewardPolicy = require("shared.RewardPolicy")
local TowerRules = require("shared.TowerRules")

Catalog.SCHEMA_VERSION = 5
Catalog.STEP_SECONDS = 12
Catalog.COMBAT_TICK_SECONDS = 0.10
Catalog.OFFLINE_REWARD_RATE = 0.20
-- The reward is scaled at settlement. Scaling the step count too would apply
-- the offline penalty twice.
Catalog.OFFLINE_STEP_SECONDS = Catalog.STEP_SECONDS
Catalog.OFFLINE_MAX_SECONDS = 12 * 60 * 60
Catalog.INVENTORY_CAP = 300
Catalog.MAX_LOG_EVENTS = 40
Catalog.MAX_STAR = 5
Catalog.MAX_ENHANCE = 1000
Catalog.MAX_VIP_LEVEL = 40
Catalog.DECOMPOSE_BASE_REFUND_RATE = 0.60
Catalog.DECOMPOSE_VIP_REFUND_RATE_PER_LEVEL = 0.01
Catalog.MAX_VALUE = 9007199254740991
Catalog.ENEMY_ATTACK_SECONDS = 1.5
Catalog.BOSS_ENRAGE_SECONDS = 30
Catalog.BOSS_ENRAGE_DAMAGE_MULTIPLIER = 1.5
Catalog.BOSS_ENRAGE_SPEED_MULTIPLIER = 1.3

Catalog.RARITY_ORDER = RarityCatalog.ORDER
Catalog.RARITIES = {}
for _, rarityId in ipairs(Catalog.RARITY_ORDER) do
    local rarity = RarityCatalog.Get(rarityId)
    Catalog.RARITIES[rarityId] = {
        name = rarity.name,
        rank = rarity.rank,
        multiplier = rarity.multiplier,
        fragments = rarity.fragments or rarity.rank,
        baseGold = rarity.baseGold or 0,
    }
end

Catalog.SLOTS = {
    { id = "weapon", name = "武器", category = "weapon" },
    { id = "shoulder", name = "头肩", category = "armor" },
    { id = "coat", name = "上衣", category = "armor" },
    { id = "pants", name = "下装", category = "armor" },
    { id = "belt", name = "腰带", category = "armor" },
    { id = "shoes", name = "鞋", category = "armor" },
    { id = "bracelet", name = "手镯", category = "jewelry" },
    { id = "necklace", name = "项链", category = "jewelry" },
    { id = "ring", name = "戒指", category = "jewelry" },
    { id = "support", name = "辅助装备", category = "special" },
    { id = "magicstone", name = "魔法石", category = "special" },
    { id = "earring", name = "耳环", category = "special" },
}

Catalog.SLOT_BY_ID = {}
for _, slot in ipairs(Catalog.SLOTS) do
    Catalog.SLOT_BY_ID[slot.id] = slot
end

Catalog.SET_ORDER = { "nightmare", "lucky", "voyage", "abyss", "prophecy" }
Catalog.SETS = {
    nightmare = {
        name = "绝望的噩梦·地狱之路",
        shortName = "噩梦",
        mythSlot = "earring",
        mythName = "终末的宿命",
    },
    lucky = {
        name = "幸运三角·命运的骰子",
        shortName = "幸运",
        mythSlot = "bracelet",
        mythName = "幸运的第七只手",
    },
    voyage = {
        name = "永恒之旅·军神的隐秘",
        shortName = "军神",
        mythSlot = "support",
        mythName = "军神的远古地图",
    },
    abyss = {
        name = "深渊窥视者·黑暗祭祀",
        shortName = "深渊",
        mythSlot = "coat",
        mythName = "吞噬深渊的祭袍",
    },
    prophecy = {
        name = "古代祭祀·神圣预言",
        shortName = "预言",
        mythSlot = "ring",
        mythName = "千魂祭的预言戒指",
    },
}

Catalog.EQUIPMENT_DEFINITIONS = EquipmentCatalog.GetAll()
Catalog.EQUIPMENT_BY_ID = {}
for _, definition in ipairs(Catalog.EQUIPMENT_DEFINITIONS) do
    Catalog.EQUIPMENT_BY_ID[definition.id] = definition
end

function Catalog.GetEquipmentDefinition(equipmentId)
    return Catalog.EQUIPMENT_BY_ID[equipmentId]
end

function Catalog.ResolveEquipment(rawItem)
    if type(rawItem) ~= "table" then return nil end
    if rawItem.equipmentId then
        return Catalog.GetEquipmentDefinition(rawItem.equipmentId)
    end
    return EquipmentCatalog.FindLegacy(rawItem)
end

function Catalog.ApplyEquipmentDefinition(item, definition)
    if not item or not definition then return item end
    item.equipmentId = definition.id
    item.name = definition.name
    item.slot = definition.slot
    item.category = definition.category
    item.rarity = definition.rarity
    item.setId = definition.setId
    item.atk = definition.atk
    item.def = definition.def
    item.hp = definition.hp
    item.crit = definition.crit
    item.critDmg = definition.critDmg
    item.atkSpeed = definition.atkSpeed
    return item
end

function Catalog.Clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

function Catalog.NextExp(level)
    local exponent = math.max(1, tonumber(level) or 1) - 1
    local required = 100 * (1.15 ^ exponent)
    if required ~= required or required == math.huge or required == -math.huge then
        return 1000000000
    end
    return math.min(1000000000, math.floor(required))
end

function Catalog.GetCellType(position, floor)
    position = Catalog.Clamp(math.floor(tonumber(position) or 1), 1, 10)
    if position <= 7 then return "monster" end
    if position <= 9 then return "elite" end
    return "boss"
end

function Catalog.GetItemEffectiveStats(item)
    local definition = item and Catalog.GetEquipmentDefinition(item.equipmentId)
    local function baseMagnitude(field)
        local big = item[field .. "Big"]
        if BigNumber.IsBigNumber(big) then return BigNumber.Normalize(big) end
        local value = item[field]
        if value == nil then value = definition and definition[field] or 0 end
        return BigNumber.FromNumber(value)
    end
    local crit = item.crit ~= nil and item.crit or (definition and definition.crit or 0)
    local critDmg = item.critDmg ~= nil and item.critDmg or (definition and definition.critDmg or 0)
    local atkSpeed = item.atkSpeed ~= nil and item.atkSpeed or (definition and definition.atkSpeed or 0)
    local level = Catalog.Clamp(math.floor(item.level or 1), 1, 1000000)
    local enhance = Catalog.Clamp(math.floor(item.enhance or 0), 0, Catalog.MAX_ENHANCE)
    local star = Catalog.Clamp(math.floor(item.star or 0), 0, Catalog.MAX_STAR)
    local generated = (tonumber(item.statVersion) or 0) >= 4 or item.roll ~= nil
    local levelFactor = generated and 1 or (1 + (level - 1) * 0.06)
    local progressionFactor = generated
        and (RewardPolicy.EnhanceMultiplier(enhance) * RewardPolicy.StarMultiplier(star))
        or (levelFactor + enhance * 0.05 + star * 0.10)
    local function effectiveMagnitude(field)
        local big = BigNumber.MultiplyScalar(baseMagnitude(field), progressionFactor)
        local number = BigNumber.ToNumber(big)
        if not generated and number then
            number = math.floor(number)
            big = BigNumber.FromNumber(number)
        end
        return big, number
    end
    local atkBig, atk = effectiveMagnitude("atk")
    local defBig, def = effectiveMagnitude("def")
    local hpBig, hp = effectiveMagnitude("hp")
    return {
        atk = atk,
        def = def,
        hp = hp,
        atkBig = atkBig,
        defBig = defBig,
        hpBig = hpBig,
        crit = crit + (generated and 0 or star * 0.002),
        critDmg = critDmg + (generated and 0 or star * 0.01),
        atkSpeed = atkSpeed + (generated and 0 or enhance * 0.001),
        lifeSteal = item.lifeSteal or (definition and definition.lifeSteal) or 0,
        damageReduction = item.damageReduction or (definition and definition.damageReduction) or 0,
        bossDamage = item.bossDamage or (definition and definition.bossDamage) or 0,
        levelFactor = levelFactor,
        progressionFactor = progressionFactor,
    }
end

local SLOT_STAT_SPLITS = {
    weapon = { atk = 0.70, def = 0.05, hp = 0.25 },
    armor = { atk = 0.10, def = 0.45, hp = 0.45 },
    jewelry = { atk = 0.45, def = 0.10, hp = 0.45 },
    special = { atk = 0.40, def = 0.20, hp = 0.40 },
}

-- Weighted by the twelve slot budgets. These denominators make a complete
-- same-floor rare set land on the intended 85% equipment contribution.
local FULL_SET_AXIS_SHARE = { atk = 0.33055, def = 0.26165, hp = 0.40780 }
local RARE_STANDARD_RATIO = 100000 / 90000
local FULL_SET_EQUIPMENT_STATS = {
    atk = 76.5 * RARE_STANDARD_RATIO,
    def = 72.25 * RARE_STANDARD_RATIO,
    hp = 1870 * RARE_STANDARD_RATIO,
}

function Catalog.CreateItemStats(definition, floor, rarityId, roll, enhance, star)
    assert(type(definition) == "table", "equipment definition is required")
    floor = math.max(1, math.floor(tonumber(floor) or 1))
    rarityId = RarityCatalog.NormalizeId(rarityId) or "common"
    roll = Catalog.Clamp(tonumber(roll) or 1, 0.95, 1.05)
    enhance = Catalog.Clamp(math.floor(tonumber(enhance) or 0), 0, Catalog.MAX_ENHANCE)
    star = Catalog.Clamp(math.floor(tonumber(star) or 0), 0, Catalog.MAX_STAR)

    -- Persist base stats. Enhancement and star multipliers are applied exactly
    -- once by GetItemEffectiveStats so old saves can be migrated losslessly.
    local normalizedRoll = (roll - 0.95) / 0.10
    local budgetBig = RewardPolicy.ItemBudget(definition.slot, floor, rarityId, normalizedRoll, 0, 0)
    local split = SLOT_STAT_SPLITS[definition.category] or SLOT_STAT_SPLITS.special
    local atkBig = BigNumber.MultiplyScalar(budgetBig, split.atk * FULL_SET_EQUIPMENT_STATS.atk
        / (85000 * FULL_SET_AXIS_SHARE.atk))
    local defBig = BigNumber.MultiplyScalar(budgetBig, split.def * FULL_SET_EQUIPMENT_STATS.def
        / (85000 * FULL_SET_AXIS_SHARE.def))
    local hpBig = BigNumber.MultiplyScalar(budgetBig, split.hp * FULL_SET_EQUIPMENT_STATS.hp
        / (85000 * FULL_SET_AXIS_SHARE.hp))
    local stats = {
        statVersion = 5,
        roll = roll,
        budget = BigNumber.ToNumber(budgetBig),
        budgetBig = budgetBig,
        atk = BigNumber.ToNumber(atkBig),
        def = BigNumber.ToNumber(defBig),
        hp = BigNumber.ToNumber(hpBig),
        atkBig = atkBig,
        defBig = defBig,
        hpBig = hpBig,
        crit = tonumber(definition.crit) or 0,
        critDmg = tonumber(definition.critDmg) or 0,
        atkSpeed = tonumber(definition.atkSpeed) or 0,
        lifeSteal = tonumber(definition.lifeSteal) or 0,
        damageReduction = tonumber(definition.damageReduction) or 0,
        bossDamage = tonumber(definition.bossDamage) or 0,
        setId = (rarityId == "epic" or rarityId == "myth") and definition.setId or nil,
        setEnabled = rarityId == "epic" or rarityId == "myth",
    }
    return stats
end

function Catalog.GetDecomposeRefundRate(vipLevel)
    vipLevel = Catalog.Clamp(
        math.floor(tonumber(vipLevel) or 0),
        0,
        Catalog.MAX_VIP_LEVEL
    )
    return math.min(
        1,
        Catalog.DECOMPOSE_BASE_REFUND_RATE
            + vipLevel * Catalog.DECOMPOSE_VIP_REFUND_RATE_PER_LEVEL
    )
end

function Catalog.GetEquipmentRecoveryValue(item)
    if not item then return { gold = 0, fragments = 0 } end
    local rarity = Catalog.RARITIES[item.rarity] or Catalog.RARITIES.common
    return {
        gold = (rarity.baseGold or 0)
            + math.max(0, math.floor(item.investedGold or 0)),
        fragments = rarity.fragments
            + math.max(0, math.floor(item.investedFragments or 0)),
    }
end

function Catalog.GetDecomposeRefund(item, vipLevel)
    local rate = Catalog.GetDecomposeRefundRate(vipLevel)
    local total = Catalog.GetEquipmentRecoveryValue(item)
    return {
        gold = math.floor(total.gold * rate),
        fragments = math.floor(total.fragments * rate),
        rate = rate,
    }
end

function Catalog.GetSellValue(item)
    if not item then return 0 end
    local rarity = Catalog.RARITIES[item.rarity] or Catalog.RARITIES.common
    local level = math.max(1, math.floor(item.level or 1))
    return math.floor((50 + level * 15) * rarity.multiplier)
        + math.max(0, math.floor(item.investedGold or 0))
end

function Catalog.GetItemPower(item)
    if not item then return 0 end
    if not item.equipmentId and not item.slot then
        return item.quantity or 1
    end
    if (tonumber(item.statVersion) or 0) >= 4 then
        local budget = BigNumber.IsBigNumber(item.budgetBig)
            and item.budgetBig or BigNumber.FromNumber(item.budget)
        local power = BigNumber.Floor(BigNumber.MultiplyScalar(budget,
            RewardPolicy.EnhanceMultiplier(item.enhance or 0)
                * RewardPolicy.StarMultiplier(item.star or 0)))
        return BigNumber.ToNumber(power) or power
    end
    local stats = Catalog.GetItemEffectiveStats(item)
    local base = stats.atk * 7
        + stats.def * 3
        + stats.hp * 0.55
        + stats.crit * 2000
        + stats.critDmg * 900
        + stats.atkSpeed * 650
    -- Legacy-only compatibility value. V5 generated stats already include the
    -- quality multiplier, so it must never be multiplied here again.
    return math.floor(base)
end

function Catalog.CompareItemPower(left, right)
    return BigNumber.Compare(Catalog.GetItemPower(left), Catalog.GetItemPower(right))
end

function Catalog.GetSetProgress(state)
    local byId = {}
    for _, item in ipairs(state.inventory or {}) do byId[item.id] = item end

    local progress = {}
    for _, setId in ipairs(Catalog.SET_ORDER) do
        progress[setId] = {
            count = 0,
            regions = { weapon = 0, armor = 0, jewelry = 0, special = 0 },
            activeTiers = {},
            activeRegions = {},
        }
    end

    for _, slot in ipairs(Catalog.SLOTS) do
        local slotId = slot.id
        local itemId = (state.equipped or {})[slotId]
        local item = byId[itemId]
        local setId = item and item.setEnabled == true and item.setId or nil
        local setProgress = setId and progress[setId]
        if setProgress then
            local region = EquipmentCatalog.REGION_BY_SLOT[slotId]
            setProgress.count = setProgress.count + 1
            if region then setProgress.regions[region] = setProgress.regions[region] + 1 end
        end
    end

    for _, setId in ipairs(Catalog.SET_ORDER) do
        local setProgress = progress[setId]
        for _, tier in ipairs({ 3, 6, 9, 12 }) do
            setProgress.activeTiers[tostring(tier)] = setProgress.count >= tier
        end
        setProgress.activeRegions.armor = setProgress.regions.armor >= 3
        setProgress.activeRegions.jewelry = setProgress.regions.jewelry >= 3
        setProgress.activeRegions.special = setProgress.regions.special >= 3
    end
    return progress
end

function Catalog.GetSetCounts(state)
    local progress = Catalog.GetSetProgress(state)
    local counts = {}
    for _, setId in ipairs(Catalog.SET_ORDER) do counts[setId] = progress[setId].count end
    return counts
end

local function applyRegionBonuses(stats, setId, setProgress)
    local active = setProgress.activeRegions
    if active.armor then
        stats.defBig = BigNumber.MultiplyScalar(stats.defBig, 1.12)
        stats.hpBig = BigNumber.MultiplyScalar(stats.hpBig, 1.10)
        if setId == "nightmare" then stats.lowHealthGuard = 0.10 end
        if setId == "voyage" then stats.damageReduction = stats.damageReduction + 0.05 end
        if setId == "abyss" then stats.lifeSteal = stats.lifeSteal + 0.02 end
    end
    if active.jewelry then
        stats.crit = stats.crit + 0.05
        stats.critDmg = stats.critDmg + 0.12
        if setId == "lucky" then stats.luckyChance = math.max(stats.luckyChance, 0.10) end
        if setId == "prophecy" then stats.skillDamage = stats.skillDamage + 0.08 end
    end
    if active.special then
        stats.atkBig = BigNumber.MultiplyScalar(stats.atkBig, 1.10)
        stats.bossDamage = stats.bossDamage + 0.08
        if setId == "abyss" then stats.damageOverTime = stats.damageOverTime + 0.10 end
        if setId == "voyage" then stats.atkSpeed = stats.atkSpeed + 0.15 end
    end
end

local function applySetTierBonuses(stats, state, setId, count)
    if setId == "nightmare" then
        if count >= 3 then stats.damageBonus = stats.damageBonus + 0.08 end
        if count >= 6 then stats.critDmg = stats.critDmg + 0.20; stats.lifeSteal = stats.lifeSteal + 0.02 end
        if count >= 9 then stats.atkBig = BigNumber.MultiplyScalar(stats.atkBig, 1.15); stats.lowHealthDamage = 0.15 end
        if count >= 12 then stats.damageBonus = stats.damageBonus + 0.35; stats.lowHealthGuard = math.max(stats.lowHealthGuard, 0.20) end
    elseif setId == "lucky" then
        if count >= 3 then stats.crit = stats.crit + 0.06 end
        if count >= 6 then stats.luckyChance = math.max(stats.luckyChance, 0.20); stats.luckyMultiplier = math.max(stats.luckyMultiplier, 2.0) end
        if count >= 9 then stats.luckyChance = math.max(stats.luckyChance, 0.28); stats.luckyMultiplier = math.max(stats.luckyMultiplier, 2.8) end
        if count >= 12 then stats.critDmg = stats.critDmg + 0.25; stats.luckyPity = 2 end
    elseif setId == "voyage" then
        if count >= 3 then stats.atkSpeed = stats.atkSpeed + 0.15; stats.moveSpeed = stats.moveSpeed + 0.05 end
        if count >= 6 then stats.atkBig = BigNumber.MultiplyScalar(stats.atkBig, 1.12); stats.damageReduction = stats.damageReduction + 0.05 end
        if count >= 9 then stats.damageBonus = stats.damageBonus + 0.18; stats.moveBurst = 0.10 end
        if count >= 12 then stats.atkSpeed = stats.atkSpeed + 0.35; stats.damageBonus = stats.damageBonus + 0.15 end
    elseif setId == "abyss" then
        if count >= 3 then stats.damageOverTime = stats.damageOverTime + 0.08 end
        if count >= 6 then stats.damageBonus = stats.damageBonus + 0.12; stats.lifeSteal = stats.lifeSteal + 0.03 end
        if count >= 9 then stats.damageOverTime = stats.damageOverTime + 0.18; stats.enemyDamageReduction = 0.10 end
        if count >= 12 then stats.damageBonus = stats.damageBonus + 0.25; stats.lifeSteal = stats.lifeSteal + 0.05 end
    elseif setId == "prophecy" then
        if count >= 3 then stats.skillDamage = stats.skillDamage + 0.10 end
        if count >= 6 then stats.damageBonus = stats.damageBonus + (state.floorKillBonus or 0) end
        if count >= 9 then stats.bossDamage = stats.bossDamage + 0.35; stats.skillDamage = stats.skillDamage + 0.15 end
        if count >= 12 then stats.permanentGrowthActive = true; stats.damageBonus = stats.damageBonus + 0.20 end
    end
end

function Catalog.CalculateStats(state, options)
    options = type(options) == "table" and options or {}
    local permanentBonus = math.max(0, state.permanentBonus or 0)
    -- The character core is 15% of the same-floor rare baseline and follows
    -- highest reached progression, never the currently selected challenge.
    local coreGrowth = TowerRules.Growth(math.max(1, state.maxFloor or 1))
    local stats = {
        atkBig = BigNumber.MultiplyScalar(coreGrowth,
            90 * RARE_STANDARD_RATIO * 0.15 * (1 + permanentBonus)),
        defBig = BigNumber.MultiplyScalar(coreGrowth,
            85 * RARE_STANDARD_RATIO * 0.15 * (1 + permanentBonus)),
        hpBig = BigNumber.MultiplyScalar(coreGrowth,
            2200 * RARE_STANDARD_RATIO * 0.15 * (1 + permanentBonus)),
        crit = 0.10,
        critDmg = 1.5,
        atkSpeed = 1.0,
        lifeSteal = 0,
        bossDamage = 0,
        damageBonus = 0,
        trueDamageRate = 0,
        luckyChance = 0,
        luckyMultiplier = 1,
        moveSpeed = 0,
        skillDamage = 0,
        damageOverTime = 0,
        damageReduction = 0,
        lowHealthGuard = 0,
        permanentBonus = permanentBonus,
    }

    local byId = {}
    for _, item in ipairs(state.inventory or {}) do
        byId[item.id] = item
    end
    for _, slot in ipairs(Catalog.SLOTS) do
        local itemId = (state.equipped or {})[slot.id]
        local item = byId[itemId]
        if item then
            local itemStats = Catalog.GetItemEffectiveStats(item)
            stats.atkBig = BigNumber.Add(stats.atkBig, itemStats.atkBig)
            stats.defBig = BigNumber.Add(stats.defBig, itemStats.defBig)
            stats.hpBig = BigNumber.Add(stats.hpBig, itemStats.hpBig)
            stats.crit = stats.crit + itemStats.crit
            stats.critDmg = stats.critDmg + itemStats.critDmg
            stats.atkSpeed = stats.atkSpeed + itemStats.atkSpeed
            stats.lifeSteal = stats.lifeSteal + itemStats.lifeSteal
            stats.damageReduction = stats.damageReduction + itemStats.damageReduction
            stats.bossDamage = stats.bossDamage + itemStats.bossDamage
        end
    end

    local progress = Catalog.GetSetProgress(state)
    for _, setId in ipairs(Catalog.SET_ORDER) do
        local setProgress = progress[setId]
        applyRegionBonuses(stats, setId, setProgress)
        applySetTierBonuses(stats, state, setId, setProgress.count)
    end

    stats.setProgress = progress

    stats.crit = Catalog.Clamp(stats.crit, 0, 0.80)
    stats.atkSpeed = Catalog.Clamp(stats.atkSpeed, 0.5, 3.0)
    stats.damageReduction = Catalog.Clamp(stats.damageReduction, 0, 0.70)
    stats.atkBig = BigNumber.Floor(stats.atkBig)
    stats.defBig = BigNumber.Floor(stats.defBig)
    stats.hpBig = BigNumber.Floor(stats.hpBig)
    stats.maxHpBig = BigNumber.Clone(stats.hpBig)
    stats.atk = BigNumber.ToNumber(stats.atkBig)
    stats.def = BigNumber.ToNumber(stats.defBig)
    stats.hp = BigNumber.ToNumber(stats.hpBig)
    ---@type table<string, any>
    local evaluation = {}
    if not options.skipPowerEvaluation then
        ---@type fun(stats: table, options: table): any
        local evaluatePower = PowerEvaluator.Evaluate
        local ok, result = pcall(evaluatePower, stats, { floor = state.floor })
        if ok and type(result) == "table" then
            ---@cast result table
            evaluation = result
        end
    end
    stats.power = evaluation.displayedPowerNumber or evaluation.displayedPower or 0
    stats.displayedPower = evaluation.displayedPower
    stats.recommendedPower = evaluation.recommendedPower
    stats.nextChapterRecommendedPower = evaluation.nextChapterRecommendedPower
    stats.powerRatio = evaluation.powerRatio or 0
    stats.headroomFloors = evaluation.headroomFloors or 0
    stats.difficultyLabel = evaluation.difficultyLabel or "危险"
    stats.equivalentFloor = math.max(0,
        tonumber(evaluation.equivalentFloor or evaluation.floorStar) or 0)
    stats.estimatedEasyFloor = math.max(0,
        tonumber(evaluation.estimatedEasyFloor) or stats.equivalentFloor)
    stats.towerScore = evaluation.towerScore or 0
    stats.bossScore = evaluation.bossScore or 0
    stats.eliteScore = evaluation.eliteScore or 0
    stats.dpsSafe = evaluation.dpsSafe or 0
    stats.ehp = evaluation.ehp or evaluation.effectiveHp or stats.hp
    return stats
end

return Catalog
