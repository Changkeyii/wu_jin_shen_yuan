local Catalog = {}
local EquipmentCatalog = require("shared.EquipmentCatalog")
local LargeNumber = require("shared.LargeNumber")

Catalog.SCHEMA_VERSION = 3
Catalog.STEP_SECONDS = 3
Catalog.COMBAT_TICK_SECONDS = 0.10
Catalog.OFFLINE_REWARD_RATE = 0.20
Catalog.OFFLINE_STEP_SECONDS = Catalog.STEP_SECONDS / Catalog.OFFLINE_REWARD_RATE
Catalog.OFFLINE_MAX_SECONDS = 12 * 60 * 60
Catalog.INVENTORY_CAP = 300
Catalog.MAX_LOG_EVENTS = 40
Catalog.MAX_STAR = 5
Catalog.MAX_ENHANCE = 1000
Catalog.MAX_VALUE = 9007199254740991

Catalog.RARITY_ORDER = { "common", "blue", "purple", "epic", "myth" }
Catalog.RARITIES = {
    common = { name = "普通", rank = 1, multiplier = 1.00, fragments = 1 },
    blue = { name = "高级", rank = 2, multiplier = 1.25, fragments = 2 },
    purple = { name = "稀有", rank = 3, multiplier = 1.65, fragments = 5 },
    epic = { name = "史诗", rank = 4, multiplier = 2.35, fragments = 18 },
    myth = { name = "神话", rank = 5, multiplier = 3.35, fragments = 80 },
}

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
    return math.floor(100 * (1.15 ^ (math.max(1, level) - 1)))
end

function Catalog.GetCellType(position, floor)
    if position >= 100 then
        return "boss"
    end
    local roll = (position * 37 + floor * 17) % 100
    if roll < 55 then return "monster" end
    if roll < 65 then return "elite" end
    if roll < 75 then return "chest" end
    if roll < 80 then return "merchant" end
    return "random"
end

function Catalog.GetItemEffectiveStats(item)
    local definition = item and Catalog.GetEquipmentDefinition(item.equipmentId)
    local atk = definition and definition.atk or item.atk or 0
    local def = definition and definition.def or item.def or 0
    local hp = definition and definition.hp or item.hp or 0
    local crit = definition and definition.crit or item.crit or 0
    local critDmg = definition and definition.critDmg or item.critDmg or 0
    local atkSpeed = definition and definition.atkSpeed or item.atkSpeed or 0
    local level = Catalog.Clamp(math.floor(item.level or 1), 1, 1000000)
    local enhance = Catalog.Clamp(math.floor(item.enhance or 0), 0, Catalog.MAX_ENHANCE)
    local star = Catalog.Clamp(math.floor(item.star or 0), 0, Catalog.MAX_STAR)
    local levelFactor = 1 + (level - 1) * 0.06
    local progressionFactor = levelFactor + enhance * 0.05 + star * 0.10
    return {
        atk = math.floor(atk * progressionFactor),
        def = math.floor(def * progressionFactor),
        hp = math.floor(hp * progressionFactor),
        crit = crit + star * 0.002,
        critDmg = critDmg + star * 0.01,
        atkSpeed = atkSpeed + enhance * 0.001,
        levelFactor = levelFactor,
        progressionFactor = progressionFactor,
    }
end

function Catalog.GetDecomposeRefund(item)
    if not item then return { gold = 0, fragments = 0 } end
    local rarity = Catalog.RARITIES[item.rarity] or Catalog.RARITIES.common
    return {
        gold = math.max(0, math.floor(item.investedGold or 0)),
        fragments = rarity.fragments + math.max(0, math.floor(item.investedFragments or 0)),
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
    local stats = Catalog.GetItemEffectiveStats(item)
    local rarity = Catalog.RARITIES[item.rarity] or Catalog.RARITIES.common
    local base = stats.atk * 7
        + stats.def * 3
        + stats.hp * 0.55
        + stats.crit * 2000
        + stats.critDmg * 900
        + stats.atkSpeed * 650
    return math.floor(base * rarity.multiplier)
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

    for slotId, itemId in pairs(state.equipped or {}) do
        local item = byId[itemId]
        local definition = item and Catalog.GetEquipmentDefinition(item.equipmentId)
        local setProgress = definition and progress[definition.setId]
        if setProgress then
            local region = EquipmentCatalog.REGION_BY_SLOT[slotId]
            setProgress.count = setProgress.count + 1
            if region then setProgress.regions[region] = setProgress.regions[region] + 1 end
        end
    end

    for _, setProgress in pairs(progress) do
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
    for setId, setProgress in pairs(progress) do counts[setId] = setProgress.count end
    return counts
end

local function applyRegionBonuses(stats, setId, setProgress)
    local active = setProgress.activeRegions
    if active.armor then
        stats.def = stats.def * 1.12
        stats.hp = stats.hp * 1.10
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
        stats.atk = stats.atk * 1.10
        stats.bossDamage = stats.bossDamage + 0.08
        if setId == "abyss" then stats.damageOverTime = stats.damageOverTime + 0.10 end
        if setId == "voyage" then stats.atkSpeed = stats.atkSpeed + 0.15 end
    end
end

local function applySetTierBonuses(stats, state, setId, count)
    if setId == "nightmare" then
        if count >= 3 then stats.damageBonus = stats.damageBonus + 0.08 end
        if count >= 6 then stats.critDmg = stats.critDmg + 0.20; stats.lifeSteal = stats.lifeSteal + 0.02 end
        if count >= 9 then stats.atk = stats.atk * 1.15; stats.lowHealthDamage = 0.15 end
        if count >= 12 then stats.damageBonus = stats.damageBonus + 0.35; stats.lowHealthGuard = math.max(stats.lowHealthGuard, 0.20) end
    elseif setId == "lucky" then
        if count >= 3 then stats.crit = stats.crit + 0.06 end
        if count >= 6 then stats.luckyChance = math.max(stats.luckyChance, 0.20); stats.luckyMultiplier = math.max(stats.luckyMultiplier, 2.0) end
        if count >= 9 then stats.luckyChance = math.max(stats.luckyChance, 0.28); stats.luckyMultiplier = math.max(stats.luckyMultiplier, 2.8) end
        if count >= 12 then stats.critDmg = stats.critDmg + 0.25; stats.luckyPity = 2 end
    elseif setId == "voyage" then
        if count >= 3 then stats.atkSpeed = stats.atkSpeed + 0.15; stats.moveSpeed = stats.moveSpeed + 0.05 end
        if count >= 6 then stats.atk = stats.atk * 1.12; stats.damageReduction = stats.damageReduction + 0.05 end
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

function Catalog.CalculateStats(state)
    local level = math.max(1, state.level or 1)
    local permanentBonus = math.max(0, state.permanentBonus or 0)
    local stats = {
        atk = (10 + level * 2) * (1 + permanentBonus),
        def = 5 + level,
        hp = (200 + level * 20) * (1 + permanentBonus),
        crit = 0.05,
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
    for _, itemId in pairs(state.equipped or {}) do
        local item = byId[itemId]
        if item then
            local itemStats = Catalog.GetItemEffectiveStats(item)
            stats.atk = stats.atk + itemStats.atk
            stats.def = stats.def + itemStats.def
            stats.hp = stats.hp + itemStats.hp
            stats.crit = stats.crit + itemStats.crit
            stats.critDmg = stats.critDmg + itemStats.critDmg
            stats.atkSpeed = stats.atkSpeed + itemStats.atkSpeed
        end
    end

    local progress = Catalog.GetSetProgress(state)
    for setId, setProgress in pairs(progress) do
        applyRegionBonuses(stats, setId, setProgress)
        applySetTierBonuses(stats, state, setId, setProgress.count)
    end

    stats.setProgress = progress

    stats.crit = Catalog.Clamp(stats.crit, 0, 0.80)
    stats.atkSpeed = Catalog.Clamp(stats.atkSpeed, 0.5, 3.0)
    stats.atk = math.floor(stats.atk)
    stats.def = math.floor(stats.def)
    stats.hp = math.floor(stats.hp)
    stats.power = LargeNumber.Clamp(
        stats.atk * 7
        + stats.def * 3
        + stats.hp * 0.55
        + stats.crit * 2200
        + (stats.critDmg - 1.5) * 1200
        + stats.atkSpeed * 680
    )
    return stats
end

return Catalog
