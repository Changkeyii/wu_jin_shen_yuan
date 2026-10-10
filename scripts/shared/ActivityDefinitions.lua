-- ActivityDefinitions.lua
-- 活动系统定义：签到活动（新手七日 / 三十日轮回）+ 每日补充玩法（木桩伤害结算）。
-- 奖励沿用「等效普通战斗场数」表达，按玩家楼层用 EconomyValue 缩放（与任务系统一致）。
-- 服务端结算权威，客户端展示共用本模块。

local QuestDefinitions = require("shared.QuestDefinitions")
local LargeNumber = require("shared.LargeNumber")

local DungeonCatalog = require("shared.DungeonCatalog")
---@class ActivityDefinitions
local ActivityDefinitions = {}

-- 每日补充玩法（木桩）通用参数。
ActivityDefinitions.STRIKE = {
    DURATION = 15,          -- 限时秒数
    INTERVAL = 0.3,         -- 攻击最小间隔（防连点）
    BASE_PER_DAY = 1,       -- 每日基础次数
    AD_PER_DAY = 1,         -- 看广告额外次数
}

local function BuildLoopDays()
    local days = {}
    for i = 1, 30 do
        local goldScenes = 10 + i * 2
        local fragments = 15 + i * 3
        local expScenes = math.floor(i / 2)
        if i % 10 == 0 then
            goldScenes = goldScenes * 3
            fragments = fragments * 3
            expScenes = expScenes * 3 + 5
        elseif i % 7 == 0 then
            goldScenes = goldScenes * 2
            fragments = fragments * 2
            expScenes = expScenes * 2
        end
        days[i] = { day = i, reward = {
            goldScenes = goldScenes,
            fragments = fragments,
            expScenes = expScenes,
            abyssTickets = 20
                + (i % 7 == 0 and 20 or 0)
                + (i == 30 and 60 or 0),
        } }
    end
    return days
end

local T = {
    act_signin_newbie_7 = {
        id = "act_signin_newbie_7", type = "signin",
        title = "新手七日签到", desc = "每日签到领好礼，累计 7 天",
        loopDays = 7, once = true,
        days = {
            { day = 1, reward = { goldScenes = 10, fragments = 20, expScenes = 5, abyssTickets = 40 } },
            { day = 2, reward = { goldScenes = 15, fragments = 25, expScenes = 6, abyssTickets = 20 } },
            { day = 3, reward = { goldScenes = 20, fragments = 30, expScenes = 8, abyssTickets = 20 } },
            { day = 4, reward = { goldScenes = 25, fragments = 40, expScenes = 10, abyssTickets = 40 } },
            { day = 5, reward = { goldScenes = 30, fragments = 50, expScenes = 12, abyssTickets = 20 } },
            { day = 6, reward = { goldScenes = 40, fragments = 60, expScenes = 15, abyssTickets = 20 } },
            { day = 7, reward = { goldScenes = 60, fragments = 100, expScenes = 30, abyssTickets = 80 } },
        },
    },
    act_signin_loop_30 = {
        id = "act_signin_loop_30", type = "signin",
        title = "三十日轮回", desc = "30 天一个轮回，循环领奖",
        loopDays = 30, once = false,
        days = BuildLoopDays(),
    },
    act_daily_gold = {
        id = "act_daily_gold", type = "strike",
        title = "每日金币补充", desc = "限时打击金币木桩，按伤害领取金币",
        rewardKind = "gold",
        tiers = {
            { minDamage = 0, reward = { goldScenes = 20 } },
            { minDamage = 1000, reward = { goldScenes = 40 } },
            { minDamage = 2400, reward = { goldScenes = 80 } },
        },
    },
    act_daily_exp = {
        id = "act_daily_exp", type = "strike",
        title = "每日经验补充", desc = "限时打击经验木桩，按伤害领取经验",
        rewardKind = "exp",
        tiers = {
            { minDamage = 0, reward = { expScenes = 10 } },
            { minDamage = 1000, reward = { expScenes = 20 } },
            { minDamage = 2400, reward = { expScenes = 40 } },
        },
    },
    act_daily_fragments = {
        id = "act_daily_fragments", type = "strike",
        title = "每日碎片补充", desc = "限时打击碎片木桩，按伤害领取碎片",
        rewardKind = "fragments",
        tiers = {
            { minDamage = 0, reward = { fragments = 30 } },
            { minDamage = 1000, reward = { fragments = 60 } },
            { minDamage = 2400, reward = { fragments = 120 } },
        },
    },
}

local ALL = {}
local SIGNIN_IDS = {}
local STRIKE_IDS = {}

for id, def in pairs(T) do
    ALL[id] = def
    if def.type == "signin" then SIGNIN_IDS[#SIGNIN_IDS + 1] = id
    else STRIKE_IDS[#STRIKE_IDS + 1] = id end
end
table.sort(SIGNIN_IDS)
table.sort(STRIKE_IDS)

ActivityDefinitions.ALL = ALL
ActivityDefinitions.SigninIds = SIGNIN_IDS
ActivityDefinitions.StrikeIds = STRIKE_IDS

function ActivityDefinitions.Get(id)
    return ALL[id]
end

function ActivityDefinitions.RewardPreview(reward, referenceFloor)
    return QuestDefinitions.RewardPreview(reward, referenceFloor)
end

-- 签到解锁时间：
--   七日新手福利：注册时间 + 已领份数 * 24h（注册当天即可领第 1 份）
--   轮回 30 日：距上次领取满 24h 解锁下一份（首份立即可领）
local function SigninUnlockAt(def, record, state, now)
    local totalDays = math.max(0, math.floor(tonumber(record.totalDays) or 0))
    if def.once then
        local registeredAt = math.max(0, math.floor(tonumber(record.registeredAt) or 0))
        if registeredAt <= 0 then registeredAt = now end
        return registeredAt + totalDays * 24 * 60 * 60
    end
    if totalDays <= 0 then return now end
    local lastClaimAt = math.max(0, math.floor(tonumber(record.lastClaimAt) or 0))
    return lastClaimAt + 24 * 60 * 60
end

-- 签到进度：累计领取 / 是否完成 / 本次循环当前天数 / 解锁时间 / 是否可领。
local function SigninState(state, def, now)
    local record = state.activities and state.activities[def.id] or {}
    local totalDays = math.max(0, math.floor(tonumber(record.totalDays) or 0))
    local once = def.once == true
    local loopDays = def.loopDays or #def.days
    local completed = once and totalDays >= loopDays
    local currentDay = 0
    if not completed then
        currentDay = once and (totalDays + 1) or ((totalDays % loopDays) + 1)
    end
    local unlockAt = SigninUnlockAt(def, record, state, now)
    local claimable = not completed and now >= unlockAt
    return {
        totalDays = totalDays,
        completed = completed,
        currentDay = currentDay,
        once = once,
        loopDays = loopDays,
        unlockAt = unlockAt,
        claimable = claimable,
    }
end

-- 打桩进度：今日次数 / 剩余可打 / 广告可解锁 / 是否有进行中会话。
local function StrikeState(state, def, today, now)
    local record = state.activities and state.activities[def.id] or {}
    local dayKey = record.strikeDay or 0
    local current = dayKey == today
    local count = current and math.max(0, math.floor(tonumber(record.strikeCount) or 0)) or 0
    local adCount = current and math.max(0, math.floor(tonumber(record.adCount) or 0)) or 0
    local limit = ActivityDefinitions.STRIKE.BASE_PER_DAY + adCount
    local session = current and record.session or nil
    local sessionActive = type(session) == "table" and session.finished ~= true
    return {
        todayCount = count,
        limit = limit,
        remaining = math.max(0, limit - count),
        adUsed = adCount,
        adCan = ActivityDefinitions.STRIKE.AD_PER_DAY > adCount and count > 0,
        sessionActive = sessionActive,
        sessionDamage = sessionActive and math.floor(tonumber(session.damage) or 0) or nil,
        sessionStartedAt = sessionActive and session.startedAt or nil,
        sessionRemaining = sessionActive and math.max(0, ActivityDefinitions.STRIKE.DURATION - (now - (session.startedAt or now))) or nil,
    }
end

-- 构建活动展示视图（客户端 RebuildView / 活动页用）。
-- @param state 权威/视图状态
-- @param now 东八区当前时间戳（秒）
function ActivityDefinitions.BuildView(state, now)
    state = type(state) == "table" and state or {}
    now = math.max(0, math.floor(tonumber(now) or os.time()))
    local today = math.floor((now + 8 * 60 * 60) / (24 * 60 * 60))
    local referenceFloor = math.max(QuestDefinitions.REFERENCE_FLOOR_MIN,
        math.floor(tonumber(state.level) or QuestDefinitions.REFERENCE_FLOOR_MIN))
    local view = { signin = {}, strike = {} }
    local redDot = 0

    for _, id in ipairs(SIGNIN_IDS) do
        local def = ALL[id]
        local info = SigninState(state, def, now)
        local days = {}
        for index, dayEntry in ipairs(def.days) do
            local claimed = false
            if info.once then
                claimed = dayEntry.day <= info.totalDays
            else
                -- 轮回签到：本次循环内已领取的天数 = totalDays 对 loopDays 取余
                claimed = dayEntry.day <= (info.totalDays % info.loopDays)
            end
            local isToday = not info.completed and not claimed
                and dayEntry.day == info.currentDay and info.claimable
            days[#days + 1] = {
                day = dayEntry.day,
                reward = ActivityDefinitions.RewardPreview(dayEntry.reward, referenceFloor),
                claimed = claimed,
                isToday = isToday,
            }
        end
        local canSign = info.claimable and not info.completed
        if canSign then redDot = redDot + 1 end
        view.signin[#view.signin + 1] = {
            id = def.id,
            title = def.title,
            desc = def.desc,
            type = def.type,
            loopDays = info.loopDays,
            once = info.once,
            completed = info.completed,
            totalDays = info.totalDays,
            currentDay = info.currentDay,
            unlockAt = info.unlockAt,
            claimable = info.claimable,
            canSign = canSign,
            days = days,
        }
    end

    for _, id in ipairs(STRIKE_IDS) do
        local def = ALL[id]
        local info = StrikeState(state, def, today, now)
        local tiers = {}
        for _, tier in ipairs(def.tiers) do
            tiers[#tiers + 1] = {
                minDamage = tier.minDamage == 0 and 0 or require("shared.GameBalance").StrikeTarget(state.level, tier.minDamage == 1000 and 2 or 3),
                reward = ActivityDefinitions.RewardPreview(tier.reward, referenceFloor),
            }
        end
        if info.remaining > 0 or info.sessionActive then redDot = redDot + 1 end
        local dungeons = DungeonCatalog.ForActivity(def.id)
        view.strike[#view.strike + 1] = {
            id = def.id,
            title = dungeons[1].title:gsub(" · 普通", ""),
            desc = dungeons[1].desc,
            dungeons = dungeons,
            type = def.type,
            rewardKind = def.rewardKind,
            todayCount = info.todayCount,
            limit = info.limit,
            remaining = info.remaining,
            adUsed = info.adUsed,
            adCan = info.adCan,
            sessionActive = info.sessionActive and not ((state.activities or {})[def.id] or {}).session.dungeonStageId,
            dungeonStageId = info.sessionActive and ((state.activities or {})[def.id] or {}).session.dungeonStageId or nil,
            sessionDamage = info.sessionDamage,
            sessionStartedAt = info.sessionStartedAt,
            sessionRemaining = info.sessionRemaining,
            duration = ActivityDefinitions.STRIKE.DURATION,
            tiers = tiers,
        }
    end

    view.redDot = redDot
    return view
end

return ActivityDefinitions
