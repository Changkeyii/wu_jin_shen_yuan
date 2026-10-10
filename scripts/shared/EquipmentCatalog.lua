local RarityCatalog = require("shared.RarityCatalog")
local LargeNumber = require("shared.LargeNumber")

local EquipmentCatalog = {}

EquipmentCatalog.VERSION = 3
EquipmentCatalog.ATLAS_PATH = "image/equipment/equipment_atlas.png"
EquipmentCatalog.ATLAS_COLUMNS = 8
EquipmentCatalog.ATLAS_CELL_SIZE = 128

local SLOT_ORDER = {
    "weapon", "shoulder", "coat", "pants", "belt", "shoes",
    "bracelet", "necklace", "ring", "support", "magicstone", "earring",
}

local SET_ORDER = { "nightmare", "lucky", "voyage", "abyss", "prophecy" }
local MYTH_SLOT = {
    nightmare = "earring",
    lucky = "bracelet",
    voyage = "support",
    abyss = "coat",
    prophecy = "ring",
}

local NAMES = {
    nightmare = { "噩梦低语之刃", "哀嚎断角肩铠", "绝望囚徒的黑袍", "地狱行刑者的长裤", "血债缚魂腰带", "踏碎梦魇的铁靴", "痛苦回响手镯", "断魂者的黑曜项链", "绝境轮回之戒", "罪孽记录器", "深红灾厄核心", "终末的宿命" },
    lucky = { "三相偏转的幸运刃", "摇骰者的星纹肩甲", "幸运赌徒的金线长衣", "命运逆行者的赌局长裤", "七面骰的束带", "踏上红线的赌徒之靴", "幸运的第七只手", "命运筹码项链", "偏骰之王的指环", "庄家的秘密账本", "流星骰盅", "不存在的第八面" },
    voyage = { "远征终点的长枪", "行军统帅的风暴肩甲", "不落旗帜的远征军装", "跨越千里的疾行战裤", "战术航线束带", "无尽行军之靴", "先锋信标手镯", "军团通讯项链", "时刻校准之戒", "军神的远古地图", "永恒罗盘核心", "远征者的终点钟" },
    abyss = { "饥渴的深渊獠牙", "窥视者的无光冠冕", "吞噬深渊的祭袍", "黑潮浸染的祭裤", "血祭循环束带", "行走于黑潮之靴", "祭血回路手镯", "深渊喉骨项链", "亡者回声之戒", "黑暗祭司的遗书", "深渊心脏碎片", "饥饿星骸耳坠" },
    prophecy = { "斩断宿命的祭剑", "先知的骨文肩饰", "古代祭司的圣衣", "铭刻万魂的祭礼长裤", "预言束缚之带", "走过神谕之路的长靴", "圣痕回响手镯", "先古神谕项链", "千魂祭的预言戒指", "祭坛遗留的神谕卷轴", "万古圣火石", "神谕终章耳坠" },
}

local UUIDS = {
    nightmare = { "0627efb1-a015-5b13-8a58-52aba44a3ab1", "f5952193-4613-591f-a0d3-e85c3f56183d", "831673aa-40e1-533d-9372-19b52e4ad9e9", "3d778577-02b4-5a92-8db0-fc26fc81024b", "4eb7e5a4-baf9-5769-bac4-7d3d6ccbe6c2", "53086c90-b424-54b6-a7bf-77201f4d238a", "70d8b44b-d7c7-5615-97c6-32cdb61c9a90", "86a622b7-6f7f-5212-adae-c0e2ec437f2d", "107b644d-fd3f-5f28-8554-b4fca474cfe0", "249a7436-d9fb-5db6-a67e-68ffe8b4ced5", "78fcccc1-e559-5f5c-9156-a98502e53c01", "9ee51686-fb86-53f4-aedf-bab6e5ce61cc" },
    lucky = { "3b69efc5-c541-5c52-b515-665faccc433d", "688172a0-792e-5a72-aa9e-acf069bdb4e6", "9a993f60-a974-587f-b7f9-ec6c69b890a0", "91ca704d-d26e-567a-bd4e-2f23c15c6b0b", "b45bc4f8-4afb-539a-9174-226b6cd5802e", "80cd2880-3bd7-5d16-9c98-dfb0c8d464fa", "e05fc63d-08d0-5aa8-9d38-98ef9341ccc9", "a5e29f0d-827c-55e3-b0c8-615abf2e7d9e", "4d4cca2b-da96-5fad-8331-7d9b2fc46ad1", "7b5536e4-07aa-595f-991b-7521b1c51e94", "8bbda8db-8f49-5302-8cb5-e80a82e46e2f", "5ff6794d-3e33-5f5d-93a2-6f43768810e7" },
    voyage = { "7523d891-87b8-5ed1-80bb-ff61f1bffe06", "3c2bcacb-863e-521e-8493-d90ec864872d", "b4f55c5d-81cf-585e-89a4-695490f53ff6", "69c333c2-2587-5dad-ad3f-246924fe6797", "50ced2b2-faee-5480-8a48-e5c5d4d727e6", "b1a2c86a-83d6-5cd3-9333-48381ebc623f", "428409fe-e676-5365-8412-884cb7dec3d0", "ae05ab9a-259c-5068-b7c5-b4b30f7c19b5", "e9f07545-13b3-58f4-90f9-d4eee328ba5c", "a54b50cb-6c7e-5141-bd24-e1d2ce5c921b", "596dbdc6-4aba-5e6f-9e60-b527d922ce2f", "75677b17-e936-5151-b627-a63b7e77c257" },
    abyss = { "eb384e7b-400d-5a5d-89ff-db6979c33067", "12e75fcf-2eda-5e45-90f1-77ed62c210f9", "0c6a6460-0f49-5106-9d0d-5d6fcbc8be8c", "01b15560-5466-5c06-8322-f809cb3d23c4", "43ec78c5-c5dc-58dc-a2ac-60ee3ef69186", "6e993632-dd75-5ff5-8ba9-3d50f4c769a2", "11dd159b-b85c-5696-b74c-1822dcef0f2d", "6e7aee20-c1c2-5e55-8fc4-06e2f6f8afa7", "cbdb2ebd-8128-5bbf-98dc-866d401df33d", "61cdeb03-43d6-5e1e-a1ed-3cb1a7eb433c", "1b0e3386-17bb-5eaa-b8bf-d917a14f534c", "5319d7a7-0733-5455-8a61-3a4e2a6b5492" },
    prophecy = { "7fcd8bf2-ea51-5e74-9dd0-1264855f0ea3", "2c362a5a-b99e-514e-bb62-5e6db5766037", "eb41844f-c31e-585a-89b1-3db2a5265656", "f1f306d3-4d9d-5a92-be79-87818384e230", "6e0caf1e-52d1-55b1-906d-47584c59bfb0", "54a6cc8f-1b2a-598e-bbcf-5aa2e625a5bf", "d61a43e1-6ed1-55ba-b89a-985547e33869", "bd7cc286-07a0-5053-9b3d-8544482eb606", "2c5819ee-7280-5ae8-884b-c8045b81145e", "e172124f-f5e2-55e1-b3fc-2bceffa2370a", "7ded1a15-274f-5eb8-8030-fdc33adb551f", "3d2b509e-f946-5b0c-a0b7-d16d79f8f04b" },
}

local ICONS = {
    nightmare = { "image/equipment/icons/equip_nightmare_01_噩梦低语之刃_20260721034747.png", "image/equipment/icons/equip_nightmare_02_哀嚎断角肩铠_20260721034733.png", "image/equipment/icons/equip_nightmare_03_绝望囚徒的黑袍_20260721034742.png", "image/equipment/icons/equip_nightmare_04_地狱行刑者的长裤_20260721034724.png", "image/equipment/icons/equip_nightmare_05_血债缚魂腰带_20260721034725.png", "image/equipment/icons/equip_nightmare_06_踏碎梦魇的铁靴_20260721034725.png", "image/equipment/icons/equip_nightmare_07_痛苦回响手镯_20260721034721.png", "image/equipment/icons/equip_nightmare_08_断魂者的黑曜项链_20260721034720.png", "image/equipment/icons/equip_nightmare_09_绝境轮回之戒_20260721034719.png", "image/equipment/icons/equip_nightmare_10_罪孽记录器_20260721034722.png", "image/equipment/icons/equip_nightmare_11_深红灾厄核心_20260721034936.png", "image/equipment/icons/equip_nightmare_12_终末的宿命_20260721034936.png" },
    lucky = { "image/equipment/icons/equip_lucky_01_三相偏转的幸运刃_20260721034935.png", "image/equipment/icons/equip_lucky_02_摇骰者的星纹肩甲_20260721034904.png", "image/equipment/icons/equip_lucky_03_幸运赌徒的金线长衣_20260721034903.png", "image/equipment/icons/equip_lucky_04_命运逆行者的赌局长裤_20260721034903.png", "image/equipment/icons/equip_lucky_05_七面骰的束带_20260721034916.png", "image/equipment/icons/equip_lucky_06_踏上红线的赌徒之靴_20260721034907.png", "image/equipment/icons/equip_lucky_07_幸运的第七只手_20260721034909.png", "image/equipment/icons/equip_lucky_08_命运筹码项链_20260721034902.png", "image/equipment/icons/equip_lucky_09_偏骰之王的指环_20260721035034.png", "image/equipment/icons/equip_lucky_10_庄家的秘密账本_20260721035022.png", "image/equipment/icons/equip_lucky_11_流星骰盅_20260721035024.png", "image/equipment/icons/equip_lucky_12_不存在的第八面_20260721035021.png" },
    voyage = { "image/equipment/icons/equip_voyage_01_远征终点的长枪_20260721035020.png", "image/equipment/icons/equip_voyage_02_行军统帅的风暴肩甲_20260721035038.png", "image/equipment/icons/equip_voyage_03_不落旗帜的远征军装_20260721035043.png", "image/equipment/icons/equip_voyage_04_跨越千里的疾行战裤_20260721035030.png", "image/equipment/icons/equip_voyage_05_战术航线束带_20260721035019.png", "image/equipment/icons/equip_voyage_06_无尽行军之靴_20260721035019.png", "image/equipment/icons/equip_voyage_07_先锋信标手镯_20260721035210.png", "image/equipment/icons/equip_voyage_08_军团通讯项链_20260721035210.png", "image/equipment/icons/equip_voyage_09_时刻校准之戒_20260721035206.png", "image/equipment/icons/equip_voyage_10_军神的远古地图_20260721035234.png", "image/equipment/icons/equip_voyage_11_永恒罗盘核心_20260721035209.png", "image/equipment/icons/equip_voyage_12_远征者的终点钟_20260721035211.png" },
    abyss = { "image/equipment/icons/equip_abyss_01_饥渴的深渊獠牙_20260721035208.png", "image/equipment/icons/equip_abyss_02_窥视者的无光冠冕_20260721035206.png", "image/equipment/icons/equip_abyss_03_吞噬深渊的祭袍_20260721035207.png", "image/equipment/icons/equip_abyss_04_黑潮浸染的祭裤_20260721035218.png", "image/equipment/icons/equip_abyss_05_血祭循环束带_20260721035313.png", "image/equipment/icons/equip_abyss_06_行走于黑潮之靴_20260721035316.png", "image/equipment/icons/equip_abyss_07_祭血回路手镯_20260721035317.png", "image/equipment/icons/equip_abyss_08_深渊喉骨项链_20260721035314.png", "image/equipment/icons/equip_abyss_09_亡者回声之戒_20260721035318.png", "image/equipment/icons/equip_abyss_10_黑暗祭司的遗书_20260721035316.png", "image/equipment/icons/equip_abyss_11_深渊心脏碎片_20260721035319.png", "image/equipment/icons/equip_abyss_12_饥饿星骸耳坠_20260721035327.png" },
    prophecy = { "image/equipment/icons/equip_prophecy_01_斩断宿命的祭剑_20260721035322.png", "image/equipment/icons/equip_prophecy_02_先知的骨文肩饰_20260721035315.png", "image/equipment/icons/equip_prophecy_03_古代祭司的圣衣_20260721035409.png", "image/equipment/icons/equip_prophecy_04_铭刻万魂的祭礼长裤_20260721035415.png", "image/equipment/icons/equip_prophecy_05_预言束缚之带_20260721035408.png", "image/equipment/icons/equip_prophecy_06_走过神谕之路的长靴_20260721035906.png", "image/equipment/icons/equip_prophecy_07_圣痕回响手镯_20260721035413.png", "image/equipment/icons/equip_prophecy_08_先古神谕项链_20260721035411.png", "image/equipment/icons/equip_prophecy_09_千魂祭的预言戒指_20260721035414.png", "image/equipment/icons/equip_prophecy_10_祭坛遗留的神谕卷轴_20260721035410.png", "image/equipment/icons/equip_prophecy_11_万古圣火石_20260721035412.png", "image/equipment/icons/equip_prophecy_12_神谕终章耳坠_20260721035412.png" },
}

local SLOT_NAMES = { weapon = "武器", shoulder = "头肩", coat = "上衣", pants = "下装", belt = "腰带", shoes = "鞋", bracelet = "手镯", necklace = "项链", ring = "戒指", support = "辅助装备", magicstone = "魔法石", earring = "耳环" }
local CATEGORY_BY_SLOT = { weapon = "weapon", shoulder = "armor", coat = "armor", pants = "armor", belt = "armor", shoes = "armor", bracelet = "jewelry", necklace = "jewelry", ring = "jewelry", support = "special", magicstone = "special", earring = "special" }
local REGION_BY_SLOT = { weapon = "weapon", shoulder = "armor", coat = "armor", pants = "armor", belt = "armor", shoes = "armor", bracelet = "jewelry", necklace = "jewelry", ring = "jewelry", support = "special", magicstone = "special", earring = "special" }
local REGION_NAMES = { weapon = "武器", armor = "防具", jewelry = "首饰", special = "特殊装备" }
local REGION_SLOT_COUNT = { weapon = 1, armor = 5, jewelry = 3, special = 3 }
local RARITY_NAMES = { common = "普通", blue = "高级", purple = "稀有", epic = "史诗", myth = "神话" }

local definitionsById = {}
local definitionsBySlot = {}
local definitions = {}
local function buildDefinition(setId, index)
    local slot = SLOT_ORDER[index]
    local rarity = slot == MYTH_SLOT[setId] and "myth" or "epic"
    local tier = rarity == "myth" and 3.35 or 2.35
    local slotBonus = CATEGORY_BY_SLOT[slot] == "weapon" and 22 or 8
    local definition = {
        id = UUIDS[setId][index],
        equipmentId = UUIDS[setId][index],
        name = NAMES[setId][index],
        slot = slot,
        category = CATEGORY_BY_SLOT[slot],
        region = REGION_BY_SLOT[slot],
        rarity = rarity,
        setId = setId,
        setName = ({ nightmare = "绝望的噩梦·地狱之路", lucky = "幸运三角·命运的骰子", voyage = "永恒之旅·军神的隐秘", abyss = "深渊窥视者·黑暗祭祀", prophecy = "古代祭祀·神圣预言" })[setId],
        icon = ICONS[setId][index],
        atlas = EquipmentCatalog.ATLAS_PATH,
        atlasIndex = (#definitions),
        level = 5,
        atk = math.floor(slotBonus + tier * 3 + index * 2),
        def = math.floor((CATEGORY_BY_SLOT[slot] == "armor" and 20 or 6) + tier * 2 + index),
        hp = math.floor(80 + tier * 16 + index * 12),
        crit = CATEGORY_BY_SLOT[slot] == "jewelry" and 0.02 or 0,
        critDmg = CATEGORY_BY_SLOT[slot] == "special" and 0.08 or 0,
        atkSpeed = setId == "voyage" and 0.05 or 0,
        description = setId == "nightmare" and "以生命为代价换取更高的终结伤害。"
            or setId == "lucky" and "让每一次暴击都像一次押中命运。"
            or setId == "voyage" and "把速度与战术优势推进到极限。"
            or setId == "abyss" and "从深渊汲取力量，持续压制战场。"
            or "记录战斗并将成长转化为下一次胜势。",
    }
    definitions[#definitions + 1] = definition
    definitionsById[definition.id] = definition
    definitionsBySlot[slot] = definitionsBySlot[slot] or {}
    definitionsBySlot[slot][#definitionsBySlot[slot] + 1] = definition
end

for _, setId in ipairs(SET_ORDER) do
    for index = 1, #SLOT_ORDER do buildDefinition(setId, index) end
end

function EquipmentCatalog.Get(equipmentId)
    return type(equipmentId) == "string" and definitionsById[equipmentId] or nil
end

EquipmentCatalog.GetDefinition = EquipmentCatalog.Get

function EquipmentCatalog.GetAll()
    return definitions
end

function EquipmentCatalog.GetBySlot(slotId)
    return definitionsBySlot[slotId] or {}
end

function EquipmentCatalog.FindLegacy(rawItem)
    if type(rawItem) ~= "table" then return nil end
    local rawName = type(rawItem.name) == "string" and rawItem.name or ""
    local rawSlot = rawItem.slot
    local rawSet = rawItem.setId
    local rawRarity = rawItem.rarity and RarityCatalog.NormalizeId(rawItem.rarity) or nil
    for _, definition in ipairs(definitions) do
        if definition.slot == rawSlot and (not rawSet or definition.setId == rawSet)
            and (not rawRarity or definition.rarity == rawRarity
                or (rawRarity ~= "epic" and rawRarity ~= "myth"))
        then
            if rawName == definition.name or rawName:find(definition.name, 1, true) or rawName:find(definition.setId, 1, true) then return definition end
        end
    end
    for _, definition in ipairs(definitions) do
        if definition.slot == rawSlot and (not rawSet or definition.setId == rawSet) then return definition end
    end
    return nil
end

function EquipmentCatalog.BuildViewItem(instance)
    if type(instance) ~= "table" then return nil end
    local definition = EquipmentCatalog.Get(instance.equipmentId)
    if not definition then return nil end
    local item = {}
    for key, value in pairs(definition) do item[key] = value end
    item.id = instance.id
    item.equipmentId = definition.id
    item.level = instance.level or definition.level
    item.legacyLevel = instance.legacyLevel
    item.rarity = RarityCatalog.NormalizeId(instance.rarity or definition.rarity)
    item.setEnabled = instance.setEnabled ~= false and RarityCatalog.Rank(item.rarity) >= RarityCatalog.Rank("epic")
    item.setId = item.setEnabled and (instance.setId or definition.setId) or nil
    item.enhance = instance.enhance or 0
    item.star = instance.star or 0
    item.locked = instance.locked == true
    item.acquiredAt = instance.acquiredAt or 0
    item.source = instance.source or "legacy"
    item.statVersion = instance.statVersion or 5
    item.budget = instance.budget
    item.budgetBig = instance.budgetBig
    item.investedGold = LargeNumber.IsLargeNumber(instance.investedGold)
        and LargeNumber.Normalize(instance.investedGold)
        or LargeNumber.FromNumber(instance.investedGold)
    item.investedFragments = instance.investedFragments or 0
    item.roll = instance.roll or 1
    item.atk = instance.atk or definition.atk or 0
    item.def = instance.def or definition.def or 0
    item.hp = instance.hp or definition.hp or 0
    item.atkBig = instance.atkBig
    item.defBig = instance.defBig
    item.hpBig = instance.hpBig
    item.crit = instance.crit or definition.crit or 0
    item.critDmg = instance.critDmg or definition.critDmg or 0
    item.atkSpeed = instance.atkSpeed or definition.atkSpeed or 0
    item.lifeSteal = instance.lifeSteal or 0
    item.damageReduction = instance.damageReduction or 0
    item.bossDamage = instance.bossDamage or 0
    item.aidLocked = instance.aidLocked == true
    item.aidFloor = instance.aidFloor
    item.coreAffixes = instance.coreAffixes
    item.uniqueEffect = instance.uniqueEffect
    item.power = instance.power
    return item
end

EquipmentCatalog.SLOT_ORDER = SLOT_ORDER
EquipmentCatalog.SLOT_NAMES = SLOT_NAMES
EquipmentCatalog.CATEGORY_BY_SLOT = CATEGORY_BY_SLOT
EquipmentCatalog.REGION_BY_SLOT = REGION_BY_SLOT
EquipmentCatalog.REGION_NAMES = REGION_NAMES
EquipmentCatalog.REGION_SLOT_COUNT = REGION_SLOT_COUNT
EquipmentCatalog.RARITY_NAMES = RARITY_NAMES
EquipmentCatalog.RARITY_NAMES = {}
for _, rarityId in ipairs(RarityCatalog.ORDER) do
    EquipmentCatalog.RARITY_NAMES[rarityId] = RarityCatalog.Get(rarityId).name
end
EquipmentCatalog.RARITY_ORDER = RarityCatalog.ORDER
EquipmentCatalog.MYTH_SLOT = MYTH_SLOT

return EquipmentCatalog
