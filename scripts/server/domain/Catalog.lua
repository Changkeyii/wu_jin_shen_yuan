local Catalog = {}

Catalog.SCHEMA_VERSION = 1
Catalog.STEP_SECONDS = 3
Catalog.OFFLINE_MAX_SECONDS = 12 * 60 * 60
Catalog.INVENTORY_CAP = 300
Catalog.MAX_LOG_EVENTS = 40

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

Catalog.EVENTS = {
    monster = { name = "普通怪物" },
    elite = { name = "精英怪物" },
    chest = { name = "宝箱" },
    merchant = { name = "商人" },
    random = { name = "随机事件" },
    boss = { name = "Boss" },
}

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
    local factor = 1 + (item.enhance or 0) * 0.05 + (item.star or 0) * 0.10
    return {
        atk = math.floor((item.atk or 0) * factor),
        def = math.floor((item.def or 0) * factor),
        hp = math.floor((item.hp or 0) * factor),
        crit = item.crit or 0,
        critDmg = item.critDmg or 0,
        atkSpeed = item.atkSpeed or 0,
    }
end

function Catalog.GetItemPower(item)
    if not item.slot then
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

function Catalog.GetSetCounts(state)
    local byId = {}
    for _, item in ipairs(state.inventory or {}) do
        byId[item.id] = item
    end

    local counts = {}
    for _, itemId in pairs(state.equipped or {}) do
        local item = byId[itemId]
        if item and Catalog.SETS[item.setId] then
            counts[item.setId] = (counts[item.setId] or 0) + 1
            if item.rarity == "myth" then
                counts[item.setId] = counts[item.setId] + 1
            end
        end
    end
    return counts
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

    local counts = Catalog.GetSetCounts(state)
    local nightmare = counts.nightmare or 0
    if nightmare >= 2 then stats.damageBonus = stats.damageBonus + 0.15 end
    if nightmare >= 3 then stats.critDmg = stats.critDmg + 0.30 end
    if nightmare >= 5 then stats.trueDamageRate = stats.trueDamageRate + 0.02 end
    if nightmare >= 8 then
        stats.atk = stats.atk * 1.25
        stats.atkSpeed = stats.atkSpeed + 0.5
    end

    local lucky = counts.lucky or 0
    if lucky >= 2 then stats.crit = stats.crit + 0.10 end
    if lucky >= 3 then
        stats.luckyChance = 0.15
        stats.luckyMultiplier = 3
    end
    if lucky >= 5 then
        stats.luckyChance = 0.22
        stats.luckyMultiplier = 4
    end
    if lucky >= 8 then
        stats.crit = stats.crit + 0.15
        stats.luckyMultiplier = 5
    end

    local voyage = counts.voyage or 0
    if voyage >= 2 then stats.atkSpeed = stats.atkSpeed + 0.3 end
    if voyage >= 3 then
        stats.atk = stats.atk * (1 + math.floor(stats.atkSpeed * 10) * 0.03)
    end
    if voyage >= 5 then stats.atkSpeed = stats.atkSpeed + 0.5 end
    if voyage >= 8 then stats.damageBonus = stats.damageBonus + 0.18 end

    local abyss = counts.abyss or 0
    if abyss >= 2 then stats.lifeSteal = stats.lifeSteal + 0.03 end
    if abyss >= 3 then stats.damageBonus = stats.damageBonus + 0.25 end
    if abyss >= 5 then stats.lifeSteal = stats.lifeSteal + 0.05 end
    if abyss >= 8 then stats.damageBonus = stats.damageBonus + 0.20 end

    local prophecy = counts.prophecy or 0
    if prophecy >= 2 then stats.damageBonus = stats.damageBonus + (state.floorKillBonus or 0) end
    if prophecy >= 3 then stats.bossDamage = stats.bossDamage + 0.40 end
    if prophecy >= 5 then stats.damageBonus = stats.damageBonus + (state.floorKillBonus or 0) * 0.5 end
    if prophecy >= 8 then stats.permanentGrowthActive = true end

    stats.crit = Catalog.Clamp(stats.crit, 0, 0.80)
    stats.atkSpeed = Catalog.Clamp(stats.atkSpeed, 0.5, 3.0)
    stats.atk = math.floor(stats.atk)
    stats.def = math.floor(stats.def)
    stats.hp = math.floor(stats.hp)
    stats.power = math.floor(
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
