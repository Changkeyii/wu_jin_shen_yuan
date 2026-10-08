-- QuestDefinitions.lua
-- 任务系统定义：新手任务 / 每日任务 / 成就任务。
-- 奖励采用「等效普通战斗场数」表达，结算时按玩家当前楼层用 EconomyValue 缩放，
-- 保证奖励与游戏金币/经验产出同比例（与战斗掉落、装备售价共用同一经济模型）。
-- 服务端发放、客户端展示共用本模块，保证两端数值一致。

local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")

local QuestDefinitions = {}

-- 与 server/domain/Catalog 相同的金币经济模型：
--   EconomyValue(L, s) ≈ 10^(log10(1+L/100)*5.1 + log10(s))
-- 单场普通战斗金币 = EconomyValue(L, BATTLE_GOLD_BASE=22000)。
QuestDefinitions.ECONOMY_LEVEL_SOFT_START = 100
QuestDefinitions.ECONOMY_LEVEL_EXPONENT = 5.1
QuestDefinitions.BATTLE_GOLD_BASE = 22000
QuestDefinitions.REFERENCE_FLOOR_MIN = 5

function QuestDefinitions.EconomyValue(level, scalar)
    level = math.floor(tonumber(level) or 1)
    if level < 1 then level = 1 end
    scalar = math.max(0, tonumber(scalar) or 0)
    if scalar == 0 then return LargeNumber.Zero() end
    local levelLog10 = math.log(1 + level / QuestDefinitions.ECONOMY_LEVEL_SOFT_START)
        / math.log(10) * QuestDefinitions.ECONOMY_LEVEL_EXPONENT
    return LargeNumber.FromBigNumber(BigNumber.Floor(
        BigNumber.FromLog10(levelLog10 + math.log(scalar) / math.log(10))
    ))
end

-- 单场普通战斗经验（与 GameEngine 结算一致）
function QuestDefinitions.BattleExp(floor)
    floor = math.floor(tonumber(floor) or 1)
    return math.max(1, floor * 5 + 10)
end

-- 奖励预览：把「等效场数」换算成可展示的绝对值（按参考楼层缩放）。
-- @param reward table { goldScenes, expScenes, fragments }
-- @param referenceFloor number|nil 默认 max(5, floor)
function QuestDefinitions.RewardPreview(reward, referenceFloor)
    reward = type(reward) == "table" and reward or {}
    referenceFloor = math.max(QuestDefinitions.REFERENCE_FLOOR_MIN,
        math.floor(tonumber(referenceFloor) or QuestDefinitions.REFERENCE_FLOOR_MIN))
    local goldScenes = math.max(0, math.floor(reward.goldScenes or 0))
    local expScenes = math.max(0, math.floor(reward.expScenes or 0))
    return {
        gold = goldScenes > 0
            and QuestDefinitions.EconomyValue(referenceFloor, QuestDefinitions.BATTLE_GOLD_BASE * goldScenes)
            or LargeNumber.Zero(),
        fragments = math.max(0, math.floor(reward.fragments or 0)),
        exp = expScenes > 0 and (expScenes * QuestDefinitions.BattleExp(referenceFloor)) or 0,
        abyssTickets = math.max(0, math.floor(reward.abyssTickets or 0)),
    }
end

local T = {
    -- 新手任务（一次性）
    newbie_clear_floor_5 = {
        id = "newbie_clear_floor_5", type = "newbie",
        title = "初探塔层", desc = "推进到第 5 层",
        metric = "floor", target = 5,
        reward = { goldScenes = 20, expScenes = 20, fragments = 30 },
    },
    newbie_equip_first = {
        id = "newbie_equip_first", type = "newbie",
        title = "武装自己", desc = "穿戴 1 件装备",
        metric = "equippedCount", target = 1,
        reward = { goldScenes = 10, expScenes = 10, fragments = 15 },
    },
    newbie_open_chest_first = {
        id = "newbie_open_chest_first", type = "newbie",
        title = "首份惊喜", desc = "首次开启宝箱",
        metric = "chest_open", target = 1,
        reward = { goldScenes = 15, expScenes = 10, fragments = 20 },
    },
    newbie_auto_run = {
        id = "newbie_auto_run", type = "newbie",
        title = "解放双手", desc = "开启一次自动登塔",
        metric = "autoRun", target = 1,
        reward = { goldScenes = 8, expScenes = 10, fragments = 0 },
    },
    newbie_decompose_first = {
        id = "newbie_decompose_first", type = "newbie",
        title = "化整为零", desc = "分解 1 件装备",
        metric = "decompose", target = 1,
        reward = { goldScenes = 0, expScenes = 10, fragments = 20 },
    },
    newbie_reach_level_10 = {
        id = "newbie_reach_level_10", type = "newbie",
        title = "小试牛刀", desc = "达到 10 级",
        metric = "level", target = 10,
        reward = { goldScenes = 25, expScenes = 30, fragments = 40 },
    },
    newbie_clear_floor_10 = {
        id = "newbie_clear_floor_10", type = "newbie",
        title = "塔中新秀", desc = "推进到第 10 层",
        metric = "floor", target = 10,
        reward = { goldScenes = 40, expScenes = 40, fragments = 60 },
    },

    -- 每日任务（东八区 0 点重置）
    daily_battle_3_abyss_ticket = {
        id = "daily_battle_3_abyss_ticket", type = "daily",
        title = "深渊预备", desc = "今日完成 3 场战斗",
        metric = "monster_kill", target = 3,
        reward = { abyssTickets = 10 },
    },
    daily_abyss_1 = {
        id = "daily_abyss_1", type = "daily",
        title = "裂隙追猎", desc = "今日完成 1 次深渊",
        metric = "abyss_run", target = 1,
        reward = { abyssTickets = 10 },
    },
    daily_kill_20 = {
        id = "daily_kill_20", type = "daily",
        title = "清扫守层怪", desc = "今日击败 20 只怪物",
        metric = "monster_kill", target = 20,
        reward = { goldScenes = 8, expScenes = 8, fragments = 0 },
    },
    daily_kill_elite_3 = {
        id = "daily_kill_elite_3", type = "daily",
        title = "猎杀精英", desc = "今日击败 3 只精英",
        metric = "elite_kill", target = 3,
        reward = { goldScenes = 10, expScenes = 6, fragments = 30 },
    },
    daily_kill_boss_1 = {
        id = "daily_kill_boss_1", type = "daily",
        title = "讨伐首领", desc = "今日击败 1 只首领",
        metric = "boss_kill", target = 1,
        reward = { goldScenes = 25, expScenes = 10, fragments = 60 },
    },
    daily_floor_advance_10 = {
        id = "daily_floor_advance_10", type = "daily",
        title = "步步高升", desc = "今日推进 10 层",
        metric = "floor_advance", target = 10,
        reward = { goldScenes = 30, expScenes = 15, fragments = 50 },
    },
    daily_pickup_5 = {
        id = "daily_pickup_5", type = "daily",
        title = "满载而归", desc = "今日拾取 5 件装备",
        metric = "item_pickup", target = 5,
        reward = { goldScenes = 10, expScenes = 0, fragments = 40 },
    },
    daily_open_chest_1 = {
        id = "daily_open_chest_1", type = "daily",
        title = "寻宝之旅", desc = "今日开启 1 个宝箱",
        metric = "chest_open", target = 1,
        reward = { goldScenes = 20, expScenes = 0, fragments = 25 },
    },
    daily_decompose_3 = {
        id = "daily_decompose_3", type = "daily",
        title = "拆解达人", desc = "今日分解 3 件装备",
        metric = "decompose", target = 3,
        reward = { goldScenes = 12, expScenes = 0, fragments = 35 },
    },
    daily_campaign_stage_1 = {
        id = "daily_campaign_stage_1", type = "daily",
        title = "万灵回响", desc = "今日完成 1 个剧情 Stage",
        metric = "campaign_stage_clear", target = 1,
        reward = { goldScenes = 12, expScenes = 8, fragments = 20 },
    },
    weekly_abyss_3 = {
        id = "weekly_abyss_3", type = "weekly",
        title = "本周裂隙", desc = "本周完成 3 次深渊",
        metric = "abyss_run", target = 3,
        reward = { goldScenes = 40, expScenes = 12, fragments = 80, abyssTickets = 4 },
    },
    weekly_campaign_1 = {
        id = "weekly_campaign_1", type = "weekly",
        title = "本周记忆", desc = "本周完成 1 个剧情关",
        metric = "campaign_stage_clear", target = 1,
        reward = { goldScenes = 30, expScenes = 15, fragments = 40 },
    },
    weekly_campaign_stars_6 = {
        id = "weekly_campaign_stars_6", type = "weekly",
        title = "本周星辉", desc = "本周获得 6 颗剧情星",
        metric = "campaign_star_earned", target = 6,
        reward = { goldScenes = 50, expScenes = 20, fragments = 60 },
    },
    weekly_campaign_boss_1 = {
        id = "weekly_campaign_boss_1", type = "weekly",
        title = "本周守门", desc = "本周完成 1 次剧情 Boss",
        metric = "campaign_boss_clear", target = 1,
        reward = { goldScenes = 45, expScenes = 18, fragments = 70 },
    },
    weekly_floor_boss_1 = {
        id = "weekly_floor_boss_1", type = "weekly",
        title = "本周登塔", desc = "本周击败 1 只登塔首领",
        metric = "boss_kill", target = 1,
        reward = { goldScenes = 35, expScenes = 12, fragments = 50 },
    },
    weekly_strike_record_1 = {
        id = "weekly_strike_record_1", type = "weekly",
        title = "本周木桩", desc = "本周刷新一次木桩纪录",
        metric = "strike_record", target = 1,
        reward = { goldScenes = 20, expScenes = 8, fragments = 30 },
    },

    -- 成就任务（长期，不重置）
    achv_floor_50 = {
        id = "achv_floor_50", type = "achievement",
        title = "登塔者·一", desc = "推进至 50 层",
        metric = "floor", target = 50,
        reward = { goldScenes = 300, expScenes = 150, fragments = 300 },
    },
    achv_floor_100 = {
        id = "achv_floor_100", type = "achievement",
        title = "登塔者·二", desc = "推进至 100 层",
        metric = "floor", target = 100,
        reward = { goldScenes = 800, expScenes = 400, fragments = 800 },
    },
    achv_kill_1000 = {
        id = "achv_kill_1000", type = "achievement",
        title = "百战老兵", desc = "累计击败 1000 只怪物",
        metric = "monster_kill", target = 1000,
        reward = { goldScenes = 500, expScenes = 0, fragments = 500 },
    },
    achv_decompose_100 = {
        id = "achv_decompose_100", type = "achievement",
        title = "拆解狂人", desc = "累计分解 100 件装备",
        metric = "decompose", target = 100,
        reward = { goldScenes = 300, expScenes = 0, fragments = 400 },
    },
    achv_sell_50 = {
        id = "achv_sell_50", type = "achievement",
        title = "精明商人", desc = "累计出售 50 件装备",
        metric = "sell", target = 50,
        reward = { goldScenes = 400, expScenes = 0, fragments = 250 },
    },
    achv_collection_50 = {
        id = "achv_collection_50", type = "achievement",
        title = "装备图鉴家", desc = "图鉴收集 50 种装备",
        metric = "collectionCount", target = 50,
        reward = { goldScenes = 600, expScenes = 0, fragments = 600 },
    },
}

local ALL = {}
local BY_TYPE = {
    newbie = {},
    daily = {},
    weekly = {},
    achievement = {},
}
local ORDER = { "newbie", "daily", "weekly", "achievement" }

for _, def in pairs(T) do
    ALL[def.id] = def
    if not BY_TYPE[def.type] then BY_TYPE[def.type] = {} end
    BY_TYPE[def.type][#BY_TYPE[def.type] + 1] = def.id
end

-- 每个分类内按定义书写顺序稳定输出
local function SortedIds(type)
    local list = {}
    for id, def in pairs(T) do
        if def.type == type then list[#list + 1] = id end
    end
    table.sort(list, function(a, b) return T[a].target < T[b].target end)
    return list
end

QuestDefinitions.ALL = ALL
QuestDefinitions.ORDER = ORDER
QuestDefinitions.BY_TYPE = BY_TYPE
QuestDefinitions.SortedIds = SortedIds

function QuestDefinitions.Get(id)
    return ALL[id]
end

function QuestDefinitions.IsSupportedType(questType)
    return BY_TYPE[questType] ~= nil
end

-- 需要服务端追踪进度的计数器指标（累计 questStats + 当日 daily.progress）
QuestDefinitions.COUNTER_METRICS = {
    monster_kill = true,
    elite_kill = true,
    boss_kill = true,
    item_pickup = true,
    chest_open = true,
    decompose = true,
    sell = true,
    floor_advance = true,
    abyss_run = true,
    campaign_stage_clear = true,
    campaign_chapter_clear = true,
    campaign_star_earned = true,
    campaign_battle_clear = true,
    campaign_boss_clear = true,
    strike_record = true,
}

-- 只读进度判定（服务端权威 QuestEngine 与客户端展示共用，保证两端一致）。
function QuestDefinitions.CurrentValue(state, def)
    state = type(state) == "table" and state or {}
    def = type(def) == "table" and def or {}
    if def.metric == "floor" then return math.floor(tonumber(state.maxFloor) or 1) end
    if def.metric == "level" then return math.floor(tonumber(state.level) or 1) end
    if def.metric == "equippedCount" then
        local n = 0
        for _ in pairs(state.equipped or {}) do n = n + 1 end
        return n
    end
    if def.metric == "autoRun" then return state.autoRun == true and 1 or 0 end
    if def.metric == "collectionCount" then
        local n = 0
        for _ in pairs(state.equipmentCollection or {}) do n = n + 1 end
        return n
    end
    if def.type == "daily" then
        local daily = state.quests and state.quests.daily
        return math.floor(tonumber(daily and daily.progress and daily.progress[def.metric]) or 0)
    end
    if def.type == "weekly" then
        local weekly = state.quests and state.quests.weekly
        return math.floor(tonumber(weekly and weekly.progress and weekly.progress[def.metric]) or 0)
    end
    return math.floor(tonumber(state.quests and state.quests.questStats and state.quests.questStats[def.metric]) or 0)
end

function QuestDefinitions.IsClaimed(state, def)
    if type(state) ~= "table" or type(def) ~= "table" or not def.id then return false end
    local quests = state.quests
    if type(quests) ~= "table" then return false end
    if def.type == "daily" then
        local daily = quests.daily
        return type(daily) == "table" and daily.claimed and daily.claimed[def.id] == true
    end
    if def.type == "weekly" then
        local weekly = quests.weekly
        return type(weekly) == "table" and weekly.claimed and weekly.claimed[def.id] == true
    end
    local bucket = def.type == "newbie" and quests.newbie or quests.achievement
    return type(bucket) == "table" and bucket.claimed and bucket.claimed[def.id] == true
end

function QuestDefinitions.IsCompleted(state, def)
    return QuestDefinitions.CurrentValue(state, def) >= (def.target or 1)
end

-- 构建任务展示视图（cur/target/state/reward），客户端 RebuildView 用。
-- @param state 权威/视图状态
-- @param today 东八区日 key（nil 时按当前时间）
function QuestDefinitions.BuildView(state, today)
    state = type(state) == "table" and state or {}
    today = today or math.floor((os.time() + 8 * 60 * 60) / (24 * 60 * 60))
    local daily = state.quests and state.quests.daily or {}
    local weekly = state.quests and state.quests.weekly or {}
    local dailyActive = (daily.dayKey or 0) == today
    local weekKey = math.floor((today + 3) / 7)
    local weeklyActive = (weekly.weekKey or 0) == weekKey
    local view = { newbie = {}, daily = {}, weekly = {}, achievement = {}, dailyActive = dailyActive, weeklyActive = weeklyActive }
    for _, questType in ipairs(QuestDefinitions.ORDER) do
        for _, questId in ipairs(QuestDefinitions.SortedIds(questType)) do
            local def = QuestDefinitions.Get(questId)
            if def then
                local cur = QuestDefinitions.CurrentValue(state, def)
                local completed = cur >= (def.target or 1)
                local claimed = QuestDefinitions.IsClaimed(state, def)
                view[questType][#view[questType] + 1] = {
                    id = def.id,
                    type = def.type,
                    title = def.title,
                    desc = def.desc,
                    metric = def.metric,
                    target = def.target,
                    cur = cur,
                    completed = completed,
                    claimed = claimed,
                    state = claimed and "claimed" or (completed and "claimable" or "inProgress"),
                    reward = QuestDefinitions.RewardPreview(def.reward, state.maxFloor),
                }
            end
        end
    end
    return view
end

return QuestDefinitions
