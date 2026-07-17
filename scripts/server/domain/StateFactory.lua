local StateNormalizer = require("server.domain.StateNormalizer")

local StateFactory = {}

local function equipment(id, name, slot, rarity, setId, stats)
    stats = stats or {}
    return {
        id = id,
        name = name,
        slot = slot,
        rarity = rarity,
        setId = setId,
        level = stats.level or 18,
        atk = stats.atk or 0,
        def = stats.def or 0,
        hp = stats.hp or 0,
        crit = stats.crit or 0,
        critDmg = stats.critDmg or 0,
        atkSpeed = stats.atkSpeed or 0,
        enhance = stats.enhance or 0,
        star = stats.star or 0,
    }
end

function StateFactory.Create(now)
    now = math.max(0, math.floor(now or os.time()))
    local inventory = {
        equipment("eq-000001", "神话·终末的宿命", "earring", "myth", "nightmare", { atk = 145, def = 65, hp = 620, critDmg = 0.18, enhance = 3, star = 1 }),
        equipment("eq-000002", "史诗·噩梦·武器", "weapon", "epic", "nightmare", { atk = 210, hp = 320, crit = 0.03, enhance = 4 }),
        equipment("eq-000003", "史诗·噩梦·上衣", "coat", "epic", "nightmare", { atk = 72, def = 118, hp = 780, enhance = 2 }),
        equipment("eq-000004", "史诗·军神·鞋", "shoes", "epic", "voyage", { atk = 55, def = 86, hp = 510, atkSpeed = 0.12 }),
        equipment("eq-000005", "史诗·幸运·戒指", "ring", "epic", "lucky", { atk = 82, hp = 360, crit = 0.08 }),
        equipment("eq-000006", "稀有·制式·腰带", "belt", "purple", nil, { level = 15, atk = 35, def = 72, hp = 400 }),
        equipment("eq-000007", "稀有·制式·头肩", "shoulder", "purple", nil, { level = 15, atk = 36, def = 81, hp = 380 }),
        equipment("eq-000008", "高级·制式·项链", "necklace", "blue", nil, { level = 12, atk = 42, hp = 240, critDmg = 0.05 }),
        equipment("eq-000009", "普通·制式·魔法石", "magicstone", "common", nil, { level = 10, atk = 24, def = 18, hp = 160 }),
        equipment("eq-000010", "史诗·深渊·下装", "pants", "epic", "abyss", { atk = 95, def = 96, hp = 720, critDmg = 0.08 }),
        equipment("eq-000011", "史诗·预言·手镯", "bracelet", "epic", "prophecy", { atk = 88, hp = 430, crit = 0.04 }),
        equipment("eq-000012", "史诗·军神·辅助装备", "support", "epic", "voyage", { atk = 78, def = 42, hp = 360, atkSpeed = 0.08 }),
        equipment("eq-000013", "史诗·噩梦·下装", "pants", "epic", "nightmare", { atk = 66, def = 104, hp = 690 }),
        equipment("eq-000014", "史诗·噩梦·腰带", "belt", "epic", "nightmare", { atk = 60, def = 92, hp = 580 }),
        equipment("eq-000015", "史诗·幸运·项链", "necklace", "epic", "lucky", { atk = 92, hp = 380, crit = 0.04 }),
        equipment("eq-000016", "稀有·备用·武器", "weapon", "purple", nil, { level = 14, atk = 128, hp = 210 }),
        equipment("eq-000017", "史诗·噩梦·武器", "weapon", "epic", "nightmare", { atk = 180, hp = 280, crit = 0.02 }),
    }

    return StateNormalizer.Normalize({
        schemaVersion = 1,
        revision = 0,
        updatedAt = now,
        lastActiveAt = now,
        pendingOfflineSeconds = 4 * 60 * 60 + 18 * 60,
        level = 21,
        exp = 464,
        floor = 1,
        maxFloor = 1,
        position = 87,
        gold = 38600,
        fragments = 520,
        mythShards = 12,
        autoRun = true,
        hp = nil,
        floorKillBonus = 0.08,
        permanentBonus = 0.035,
        nextItemId = 18,
        inventory = inventory,
        equipped = {
            earring = "eq-000001",
            weapon = "eq-000002",
            coat = "eq-000003",
            shoes = "eq-000004",
            ring = "eq-000005",
            belt = "eq-000006",
            shoulder = "eq-000007",
            necklace = "eq-000008",
            magicstone = "eq-000009",
            pants = "eq-000010",
            bracelet = "eq-000011",
            support = "eq-000012",
        },
        consumables = { healthPotion = 12 },
        appliedGmCommandIds = {},
    }, now)
end

StateFactory.CreateInitialState = StateFactory.Create

return StateFactory
