local WishPoolDefinitions = {}

-- 单抽 / 十连消耗（十连优惠：10 次只扣 8 券）。不再支持广告许愿。
WishPoolDefinitions.SINGLE_DRAW_COUNT = 1
WishPoolDefinitions.SINGLE_TICKET_COST = 1
WishPoolDefinitions.MULTI_DRAW_COUNT = 10
WishPoolDefinitions.MULTI_TICKET_COST = 8
-- 兼容旧存档字段；广告许愿已下线，不再参与业务判定。
WishPoolDefinitions.AD_DAILY_LIMIT = 0
WishPoolDefinitions.MYTH_HARD_PITY = 120
WishPoolDefinitions.CHARACTER_HARD_PITY = 400
WishPoolDefinitions.STARTER_TICKETS = 1
WishPoolDefinitions.CHARACTER_MARKS_PER_DUPLICATE = 10

-- 解析许愿次数与券消耗：仅允许 1 抽 / 10 抽。
function WishPoolDefinitions.ResolveDrawPlan(count)
    count = math.floor(tonumber(count) or WishPoolDefinitions.SINGLE_DRAW_COUNT)
    if count == WishPoolDefinitions.MULTI_DRAW_COUNT then
        return WishPoolDefinitions.MULTI_DRAW_COUNT, WishPoolDefinitions.MULTI_TICKET_COST
    end
    return WishPoolDefinitions.SINGLE_DRAW_COUNT, WishPoolDefinitions.SINGLE_TICKET_COST
end

-- 许愿池限定罐品阶（传说及以上）
WishPoolDefinitions.JAR_RARITIES = { "legendary", "epic", "myth" }

-- 许愿池专用图标
local ICONS = {
    ticket = "image/wishpool_ticket_20260812130253.png",
    jarRandom = "image/wishpool_jar_random_20260812130256.png",
    jarArtifact = "image/wishpool_jar_artifact_20260813020533.png",
    jarLegendary = "image/wishpool_jar_legendary_20260812130250.png",
    jarEpic = "image/wishpool_jar_epic_20260812130254.png",
    jarMyth = "image/wishpool_jar_myth_20260812130257.png",
    charMark = "image/wishpool_character_mark_20260812130255.png",
    charEmberBlade = "image/wishpool_char_ember_blade_20260812130325.png",
    charVoidGuard = "image/wishpool_char_void_guard_20260812130345.png",
    charStormRanger = "image/wishpool_char_storm_ranger_20260812130328.png",
}

WishPoolDefinitions.ICONS = ICONS

-- 部位限定罐：12 部位 × 传说/史诗/神话 各一个
local SLOT_JAR_ICONS = {
    weapon = {
        legendary = "image/wishpool_jar_slot_weapon_legendary_20260813020725.png",
        epic = "image/wishpool_jar_slot_weapon_epic_20260813020652.png",
        myth = "image/wishpool_jar_slot_weapon_myth_20260813020730.png",
    },
    shoulder = {
        legendary = "image/wishpool_jar_slot_shoulder_legendary_20260813020726.png",
        epic = "image/wishpool_jar_slot_shoulder_epic_20260813020725.png",
        myth = "image/wishpool_jar_slot_shoulder_myth_20260813020728.png",
    },
    coat = {
        legendary = "image/wishpool_jar_slot_coat_legendary_20260813020722.png",
        epic = "image/wishpool_jar_slot_coat_epic_20260813020720.png",
        myth = "image/wishpool_jar_slot_coat_myth_20260813020723.png",
    },
    pants = {
        legendary = "image/wishpool_jar_slot_pants_legendary_20260813020834.png",
        epic = "image/wishpool_jar_slot_pants_epic_20260813020803.png",
        myth = "image/wishpool_jar_slot_pants_myth_20260813020836.png",
    },
    belt = {
        legendary = "image/wishpool_jar_slot_belt_legendary_20260813020833.png",
        epic = "image/wishpool_jar_slot_belt_epic_20260813020830.png",
        myth = "image/wishpool_jar_slot_belt_myth_20260813020835.png",
    },
    shoes = {
        legendary = "image/wishpool_jar_slot_shoes_legendary_20260813020837.png",
        epic = "image/wishpool_jar_slot_shoes_epic_20260813020844.png",
        myth = "image/wishpool_jar_slot_shoes_myth_20260813020837.png",
    },
    bracelet = {
        legendary = "image/wishpool_jar_slot_bracelet_legendary_20260813020946.png",
        epic = "image/wishpool_jar_slot_bracelet_epic_20260813020942.png",
        myth = "image/wishpool_jar_slot_bracelet_myth_20260813020948.png",
    },
    necklace = {
        legendary = "image/wishpool_jar_slot_necklace_legendary_20260813020944.png",
        epic = "image/wishpool_jar_slot_necklace_epic_20260813020940.png",
        myth = "image/wishpool_jar_slot_necklace_myth_20260813020946.png",
    },
    ring = {
        legendary = "image/wishpool_jar_slot_ring_legendary_20260813020949.png",
        epic = "image/wishpool_jar_slot_ring_epic_20260813020950.png",
        myth = "image/wishpool_jar_slot_ring_myth_20260813020951.png",
    },
    support = {
        legendary = "image/wishpool_jar_slot_support_legendary_20260813021054.png",
        epic = "image/wishpool_jar_slot_support_epic_20260813021048.png",
        myth = "image/wishpool_jar_slot_support_myth_20260813021053.png",
    },
    magicstone = {
        legendary = "image/wishpool_jar_slot_magicstone_legendary_20260813021052.png",
        epic = "image/wishpool_jar_slot_magicstone_epic_20260813021054.png",
        myth = "image/wishpool_jar_slot_magicstone_myth_20260813021050.png",
    },
    earring = {
        legendary = "image/wishpool_jar_slot_earring_legendary_20260813021051.png",
        epic = "image/wishpool_jar_slot_earring_epic_20260813021047.png",
        myth = "image/wishpool_jar_slot_earring_myth_20260813021104.png",
    },
}

WishPoolDefinitions.SLOT_JAR_ICONS = SLOT_JAR_ICONS

-- 五大套装罐
local SET_JAR_ICONS = {
    nightmare = "image/wishpool_jar_set_nightmare_20260813020530.png",
    lucky = "image/wishpool_jar_set_lucky_20260813020531.png",
    voyage = "image/wishpool_jar_set_voyage_20260813020529.png",
    abyss = "image/wishpool_jar_set_abyss_20260813020527.png",
    prophecy = "image/wishpool_jar_set_prophecy_20260813020528.png",
}

WishPoolDefinitions.SET_JAR_ICONS = SET_JAR_ICONS

-- 游戏套装徽记
WishPoolDefinitions.SET_ICONS = {
    nightmare = "image/wishpool_set_nightmare_20260813020048.png",
    lucky = "image/wishpool_set_lucky_20260813020054.png",
    voyage = "image/wishpool_set_voyage_20260813020049.png",
    abyss = "image/wishpool_set_abyss_20260813020047.png",
    prophecy = "image/wishpool_set_prophecy_20260813020046.png",
}

WishPoolDefinitions.SET_NAMES = {
    nightmare = "绝望的噩梦·地狱之路",
    lucky = "幸运三角·命运的骰子",
    voyage = "永恒之旅·军神的隐秘",
    abyss = "深渊窥视者·黑暗祭祀",
    prophecy = "古代祭祀·神圣预言",
}

WishPoolDefinitions.SLOTS = {
    "weapon", "shoulder", "coat", "pants", "belt", "shoes",
    "bracelet", "necklace", "ring", "support", "magicstone", "earring",
}

WishPoolDefinitions.SLOT_NAMES = {
    weapon = "武器", shoulder = "护肩", coat = "上衣", pants = "下装",
    belt = "腰带", shoes = "鞋", bracelet = "手镯", necklace = "项链",
    ring = "戒指", support = "辅助装备", magicstone = "魔法石", earring = "耳环",
}

local SLOT_CATEGORY = {
    weapon = "weapon",
    shoulder = "armor", coat = "armor", pants = "armor", belt = "armor", shoes = "armor",
    bracelet = "jewelry", necklace = "jewelry", ring = "jewelry",
    support = "jewelry", magicstone = "jewelry", earring = "jewelry",
}

WishPoolDefinitions.SLOT_CATEGORY = SLOT_CATEGORY

WishPoolDefinitions.RARITY_NAMES = {
    artifact = "神器",
    legendary = "传说",
    epic = "史诗",
    myth = "神话",
}

WishPoolDefinitions.RARITY_COLORS = {
    artifact = { 244, 114, 182, 255 },
    legendary = { 255, 190, 40, 255 },
    epic = { 190, 80, 255, 255 },
    myth = { 255, 64, 128, 255 },
}

WishPoolDefinitions.CHARACTERS = {
    ember_blade = {
        id = "ember_blade",
        name = "赤焰枪刃",
        subtitle = "烈焰连击",
        icon = ICONS.charEmberBlade,
    },
    void_guard = {
        id = "void_guard",
        name = "虚空壁垒",
        subtitle = "守御反击",
        icon = ICONS.charVoidGuard,
    },
    storm_ranger = {
        id = "storm_ranger",
        name = "风暴猎手",
        subtitle = "极速追击",
        icon = ICONS.charStormRanger,
    },
}

WishPoolDefinitions.CHARACTER_ORDER = { "void_guard", "storm_ranger" }

-- 十万分权重。许愿池只产出传说及以上装备罐，角色为完整角色。
WishPoolDefinitions.DRAW_WEIGHTS = {
    { kind = "random", weight = 67750 },
    { kind = "slot", weight = 20000 },
    { kind = "rarity", rarity = "legendary", weight = 500 },
    { kind = "rarity", rarity = "epic", weight = 6800 },
    { kind = "rarity", rarity = "myth", weight = 700 },
    { kind = "combo", rarity = "legendary", weight = 250 },
    { kind = "combo", rarity = "epic", weight = 3450 },
    { kind = "combo", rarity = "myth", weight = 300 },
    { kind = "character", weight = 250 },
}

WishPoolDefinitions.OPEN_RARITY_WEIGHTS = {
    { rarity = "legendary", weight = 648 },
    { rarity = "epic", weight = 350 },
    { rarity = "myth", weight = 2 },
}

-- 许愿池展示全部可获得的罐子：随机罐、品阶罐、12 个部位罐、36 个部位+品阶罐、5 个套装罐。
-- 展示顺序仅用于客户端视觉，服务端仍根据 reward kind 与 stopCell 进行权威停靠。
WishPoolDefinitions.DISPLAY_CELLS = {}

local function addDisplayCell(cell)
    WishPoolDefinitions.DISPLAY_CELLS[#WishPoolDefinitions.DISPLAY_CELLS + 1] = cell
end

addDisplayCell({ kind = "random", label = "全随机罐", icon = ICONS.jarRandom })
for _, rarity in ipairs({ "legendary", "epic", "myth" }) do
    local icon = ICONS.jarLegendary
    if rarity == "epic" then icon = ICONS.jarEpic end
    if rarity == "myth" then icon = ICONS.jarMyth end
    addDisplayCell({
        kind = "rarity", label = WishPoolDefinitions.RARITY_NAMES[rarity] .. "罐",
        rarity = rarity, icon = icon,
    })
end

for _, characterId in ipairs({ "ember_blade", "void_guard", "storm_ranger" }) do
    local character = WishPoolDefinitions.CHARACTERS[characterId]
    addDisplayCell({
        kind = "character",
        label = character.name,
        characterId = characterId,
        icon = character.icon,
    })
end

for _, slot in ipairs(WishPoolDefinitions.SLOTS) do
    addDisplayCell({
        kind = "slot", label = WishPoolDefinitions.SLOT_NAMES[slot] .. "部位罐",
        slot = slot, icon = SLOT_JAR_ICONS[slot].legendary,
    })
end

for _, slot in ipairs(WishPoolDefinitions.SLOTS) do
    for _, rarity in ipairs({ "legendary", "epic", "myth" }) do
        addDisplayCell({
            kind = "combo",
            label = WishPoolDefinitions.SLOT_NAMES[slot] .. "·"
                .. WishPoolDefinitions.RARITY_NAMES[rarity] .. "罐",
            slot = slot,
            rarity = rarity,
            icon = SLOT_JAR_ICONS[slot][rarity],
        })
    end
end

for _, setId in ipairs({ "nightmare", "lucky", "voyage", "abyss", "prophecy" }) do
    addDisplayCell({
        kind = "set",
        label = WishPoolDefinitions.SET_NAMES[setId] .. "罐",
        setId = setId,
        icon = SET_JAR_ICONS[setId],
    })
end

local function safeId(value)
    return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

function WishPoolDefinitions.DayKey(now)
    return math.floor((math.max(0, math.floor(tonumber(now) or 0)) + 8 * 60 * 60) / (24 * 60 * 60))
end

function WishPoolDefinitions.RandomSlot(randomInt)
    return WishPoolDefinitions.SLOTS[randomInt(1, #WishPoolDefinitions.SLOTS)]
end

local function makeBaseId(kind, rarity, slot, setId)
    if kind == "random" then return "jar.random" end
    if kind == "set" and safeId(setId) then return "jar.set." .. setId end
    if kind == "slot" and safeId(slot) then return "jar.slot." .. slot end
    if kind == "rarity" and safeId(rarity) then return "jar.rarity." .. rarity end
    if kind == "combo" and safeId(slot) and safeId(rarity) then
        return "jar.combo." .. slot .. "." .. rarity
    end
    return nil
end

local function resolveBaseJar(jarId)
    if jarId == "jar.random" then
        return { id = jarId, kind = "random", name = "全随机罐", icon = ICONS.jarRandom }
    end
    if type(jarId) ~= "string" then return nil end
    local setId = jarId:match("^jar%.set%.([%w_%-]+)$")
    if setId and WishPoolDefinitions.SET_NAMES[setId] then
        return {
            id = jarId, kind = "set", setId = setId,
            name = WishPoolDefinitions.SET_NAMES[setId] .. "套装罐",
            icon = SET_JAR_ICONS[setId],
        }
    end
    local slot = jarId:match("^jar%.slot%.([%w_%-]+)$")
    if slot and WishPoolDefinitions.SLOT_NAMES[slot] then
        return {
            id = jarId, kind = "slot", slot = slot,
            name = WishPoolDefinitions.SLOT_NAMES[slot] .. "部位罐",
            icon = SLOT_JAR_ICONS[slot] and SLOT_JAR_ICONS[slot].legendary
                or ICONS.jarRandom,
            category = SLOT_CATEGORY[slot],
        }
    end
    local rarity = jarId:match("^jar%.rarity%.([%w_%-]+)$")
    if rarity and WishPoolDefinitions.RARITY_NAMES[rarity] then
        local icon = ICONS.jarLegendary
        if rarity == "artifact" then icon = ICONS.jarArtifact
        elseif rarity == "epic" then icon = ICONS.jarEpic
        elseif rarity == "myth" then icon = ICONS.jarMyth end
        return {
            id = jarId, kind = "rarity", rarity = rarity,
            name = WishPoolDefinitions.RARITY_NAMES[rarity] .. "罐",
            icon = icon,
        }
    end
    local comboSlot, comboRarity = jarId:match("^jar%.combo%.([%w_%-]+)%.([%w_%-]+)$")
    if comboSlot and WishPoolDefinitions.SLOT_NAMES[comboSlot]
        and WishPoolDefinitions.RARITY_NAMES[comboRarity]
    then
        return {
            id = jarId, kind = "combo", slot = comboSlot, rarity = comboRarity,
            name = WishPoolDefinitions.SLOT_NAMES[comboSlot]
                .. "·" .. WishPoolDefinitions.RARITY_NAMES[comboRarity] .. "罐",
            icon = SLOT_JAR_ICONS[comboSlot]
                and SLOT_JAR_ICONS[comboSlot][comboRarity]
                or ICONS.jarRandom,
        }
    end
    return nil
end

function WishPoolDefinitions.CellCandidates(kind, rarity)
    local candidates = {}
    for index, cell in ipairs(WishPoolDefinitions.DISPLAY_CELLS) do
        if cell.kind == kind and (cell.rarity == nil or rarity == nil or cell.rarity == rarity) then
            candidates[#candidates + 1] = index
        end
    end
    if #candidates == 0 then
        for index, cell in ipairs(WishPoolDefinitions.DISPLAY_CELLS) do
            if cell.kind == kind then candidates[#candidates + 1] = index end
        end
    end
    return candidates
end

-- Only grades at or above the current character level participate; quality/pity is unchanged.
WishPoolDefinitions.JAR_LEVELS = {}
for level = 5, 100, 5 do WishPoolDefinitions.JAR_LEVELS[#WishPoolDefinitions.JAR_LEVELS + 1] = level end

function WishPoolDefinitions.MinimumJarLevel(playerLevel)
    playerLevel = require("shared.GameProgression").Level(playerLevel)
    return math.max(5, math.min(100, math.ceil(playerLevel / 5) * 5))
end

function WishPoolDefinitions.RandomLevel(rng, playerLevel)
    local first = math.floor(WishPoolDefinitions.MinimumJarLevel(playerLevel) / 5)
    local index = rng and rng(first, #WishPoolDefinitions.JAR_LEVELS) or math.random(first, #WishPoolDefinitions.JAR_LEVELS)
    index = math.max(first, math.min(#WishPoolDefinitions.JAR_LEVELS, math.floor(tonumber(index) or first)))
    return WishPoolDefinitions.JAR_LEVELS[index]
end

function WishPoolDefinitions.MakeJarId(kind, rarity, slot, setId, level)
    local id = makeBaseId(kind, rarity, slot, setId)
    if not id then return nil end
    if level == nil then return id end
    if type(level) ~= "number" or level < 5 or level > 100 or level % 5 ~= 0 then return nil end
    return id .. ".lv" .. level
end

---@return table|nil
function WishPoolDefinitions.ResolveJar(jarId)
    if type(jarId) ~= "string" then return nil end
    local baseId, digits = jarId:match("^(.-)%.lv(%d+)$")
    local level = digits and tonumber(digits) or nil
    if digits and (level < 5 or level > 100 or level % 5 ~= 0 or tostring(level) ~= digits) then return nil end
    ---@type table|nil
    local jar = resolveBaseJar(baseId or jarId)
    if not jar then return nil end
    jar.baseName = jar.name
    jar.baseId, jar.id = baseId or jarId, jarId
    jar.level = level or 100
    jar.legacy = level == nil
    jar.name = (jar.legacy and "旧版100级·" or (level .. "级·")) .. jar.name
    return jar
end

function WishPoolDefinitions.GrantJars(state, jarId, count, rng)
    ---@type table|nil
    local jar = WishPoolDefinitions.ResolveJar(jarId)
    count = math.max(0, math.floor(tonumber(count) or 0))
    if not jar or count == 0 then return nil end
    -- A specified grade is exact; generic GM/reward grants pick one grade for this stack.
    local id = jar.legacy and (jar.baseId .. ".lv" .. WishPoolDefinitions.RandomLevel(rng, state.level)) or jar.id
    state.wishPool.jars[id] = (state.wishPool.jars[id] or 0) + count
    return id
end

function WishPoolDefinitions.RecycleFragments(jar)
    jar = type(jar) == "table" and jar or WishPoolDefinitions.ResolveJar(jar)
    if not jar then return 0 end
    local factor = ({ artifact = 1, legendary = 2, epic = 4, myth = 8 })[jar.rarity] or 2
    return math.floor(jar.level / 5) * factor
end

function WishPoolDefinitions.JarIcon(jar)
    jar = type(jar) == "table" and jar or WishPoolDefinitions.ResolveJar(jar)
    if not jar then return ICONS.jarRandom end
    if jar.icon then return jar.icon end
    if jar.setId then return SET_JAR_ICONS[jar.setId] or ICONS.jarRandom end
    if jar.slot and jar.rarity then
        local entry = SLOT_JAR_ICONS[jar.slot]
        if entry and entry[jar.rarity] then return entry[jar.rarity] end
        return ICONS.jarRandom
    end
    if jar.slot then
        local entry = SLOT_JAR_ICONS[jar.slot]
        return entry and entry.legendary or ICONS.jarRandom
    end
    if jar.rarity == "artifact" then return ICONS.jarArtifact end
    if jar.rarity == "myth" then return ICONS.jarMyth end
    if jar.rarity == "epic" then return ICONS.jarEpic end
    if jar.rarity == "legendary" then return ICONS.jarLegendary end
    return ICONS.jarRandom
end

-- 收集全部许愿池图标路径（供客户端预加载）
function WishPoolDefinitions.AllIcons()
    local result = {}
    local seen = {}
    local function add(path)
        if type(path) == "string" and not seen[path] then
            seen[path] = true
            result[#result + 1] = path
        end
    end
    for _, path in pairs(ICONS) do add(path) end
    for _, entry in pairs(SLOT_JAR_ICONS) do
        for _, path in pairs(entry) do add(path) end
    end
    for _, path in pairs(SET_JAR_ICONS) do add(path) end
    for _, path in pairs(WishPoolDefinitions.SET_ICONS) do add(path) end
    return result
end

return WishPoolDefinitions
