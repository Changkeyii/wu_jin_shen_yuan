-- ActivityEngine.lua
-- 活动系统服务端引擎：签到活动（每日签到发当天奖励）、每日补充玩法（限时打木桩按伤害结算）。
-- 奖励发放复用任务引擎（QuestEngine.GrantReward），按玩家楼层缩放。

local PlayerTransition = require("server.domain.PlayerTransition")
local QuestEngine = require("server.domain.QuestEngine")
local ActivityDefinitions = require("shared.ActivityDefinitions")

local ActivityEngine = {}

local STRIKE = ActivityDefinitions.STRIKE

local function serverDayKey(now)
    return QuestEngine.DayKey(now)
end

local DAY_SECONDS = 24 * 60 * 60

-- 签到解锁时间：
--   七日新手福利：注册时间 + 已领份数 * 24h（注册当天即可领第 1 份）
--   轮回 30 日：距上次领取满 24h 解锁下一份（首份立即可领）
local function SigninUnlockAt(def, record, state, now)
    local totalDays = math.max(0, math.floor(tonumber(record.totalDays) or 0))
    if def.once then
        local registeredAt = math.max(0, math.floor(tonumber(record.registeredAt) or 0))
        if registeredAt <= 0 then
            registeredAt = now
            record.registeredAt = registeredAt
        end
        return registeredAt + totalDays * DAY_SECONDS
    end
    if totalDays <= 0 then return now end
    local lastClaimAt = math.max(0, math.floor(tonumber(record.lastClaimAt) or 0))
    return lastClaimAt + DAY_SECONDS
end

-- 亚秒时钟：打桩攻击间隔/限时判定用（会话内刻度一致，不用于存档时间戳）。
-- 使用 os.clock()（进程单调时间）而非 _G["time"]，避免部分宿主访问崩溃。
local function nowFloat()
    return os.clock()
end

local function EnsureRecord(state, activityId, today)
    state.activities = type(state.activities) == "table" and state.activities or {}
    local record = state.activities[activityId]
    if type(record) ~= "table" then
        record = {
            signInDays = {},
            totalDays = 0,
            lastClaimAt = 0,
            registeredAt = 0,
            strikeDay = 0,
            strikeCount = 0,
            adCount = 0,
        }
        state.activities[activityId] = record
    end
    -- 打桩会话跨日或长期未结算则清理（亚秒刻度判断超时）。
    if type(record.session) == "table" then
        local stale = nowFloat() - (record.session.startedAt or 0)
        if record.strikeDay ~= today or stale > STRIKE.DURATION * 3 then
            record.session = nil
        end
    end
    return record
end

-- 初始化/规范化活动存档（旧档兼容）。
function ActivityEngine.EnsureActivityState(state, now)
    if type(state) ~= "table" then return end
    state.activities = type(state.activities) == "table" and state.activities or {}
    local today = serverDayKey(now)
    for id in pairs(ActivityDefinitions.ALL) do
        EnsureRecord(state, id, today)
    end
end

-- 每日签到：签到即发放当天奖励。
function ActivityEngine.SignIn(inputState, activityId, now)
    now = PlayerTransition.Now(now)
    local def = ActivityDefinitions.Get(activityId)
    if not def or def.type ~= "signin" then
        return PlayerTransition.Failure(inputState, now, "UNKNOWN_ACTIVITY", "未知活动")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local today = serverDayKey(now)
    local record = EnsureRecord(working, activityId, today)
    local loopDays = def.loopDays or #def.days
    local totalDays = math.max(0, math.floor(tonumber(record.totalDays) or 0))
    if def.once and totalDays >= loopDays then
        return PlayerTransition.Failure(inputState, now, "ACTIVITY_COMPLETED", "签到已满")
    end
    -- 解锁检查：未到解锁时间则拒绝，并提示剩余等待时长
    local unlockAt = SigninUnlockAt(def, record, working, now)
    if now < unlockAt then
        local waitSeconds = unlockAt - now
        local waitText = waitSeconds >= 3600
            and (tostring(math.ceil(waitSeconds / 3600)) .. "小时")
            or (tostring(math.ceil(waitSeconds / 60)) .. "分钟")
        return PlayerTransition.Failure(inputState, now, "ACTIVITY_LOCKED", "尚未解锁，请 " .. waitText .. " 后再来")
    end
    local dayIndex = def.once and (totalDays + 1) or ((totalDays % loopDays) + 1)
    local dayEntry = def.days[dayIndex]
    if not dayEntry then
        return PlayerTransition.Failure(inputState, now, "ACTIVITY_INVALID", "活动配置无效")
    end
    record.totalDays = totalDays + 1
    record.lastClaimAt = now
    local events = {}
    local reward = QuestEngine.GrantReward(working, { reward = dayEntry.reward }, now, events)
    events[#events + 1] = PlayerTransition.Event("activity_signed", {
        activityId = activityId,
        day = dayIndex,
        totalDays = record.totalDays,
        reward = reward,
    })
    return PlayerTransition.Finalize(inputState, working, now, "activity_signed", events, false, false)
end

-- 开始打桩：消耗一次当日次数，创建会话。
function ActivityEngine.BeginStrike(inputState, activityId, now)
    now = PlayerTransition.Now(now)
    local def = ActivityDefinitions.Get(activityId)
    if not def or def.type ~= "strike" then
        return PlayerTransition.Failure(inputState, now, "UNKNOWN_ACTIVITY", "未知活动")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local today = serverDayKey(now)
    local record = EnsureRecord(working, activityId, today)
    if record.strikeDay ~= today then
        record.strikeDay = today
        record.strikeCount = 0
        record.adCount = 0
    end
    local limit = STRIKE.BASE_PER_DAY + record.adCount
    if record.strikeCount >= limit then
        return PlayerTransition.Failure(inputState, now, "STRIKE_LIMIT", "今日次数已用完")
    end
    -- 已有未结算会话（如中途退出残留）：先自动结算旧会话，再从 0 开始新会话。
    -- 满足「每次从 0 进入，只看次数，没有继续」的产品语义。
    if type(record.session) == "table" then
        local settled = ActivityEngine.FinishStrike(working, activityId, now)
        if settled.ok and settled.state then
            working = settled.state
            record = EnsureRecord(working, activityId, today)
        end
    end
    record.strikeCount = record.strikeCount + 1
    local t = nowFloat()
    record.session = { startedAt = t, lastHitAt = t - STRIKE.INTERVAL, damage = 0, finished = false }
    local events = {
        PlayerTransition.Event("activity_strike_begin", {
            activityId = activityId,
            remaining = math.max(0, limit - record.strikeCount),
        }),
    }
    return PlayerTransition.Finalize(inputState, working, now, "activity_strike_begin", events, false, false)
end

-- 单次攻击：服务端权威累加伤害（限流防连点）。
function ActivityEngine.Strike(inputState, activityId, now)
    now = PlayerTransition.Now(now)
    local def = ActivityDefinitions.Get(activityId)
    if not def or def.type ~= "strike" then
        return PlayerTransition.Failure(inputState, now, "UNKNOWN_ACTIVITY", "未知活动")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local today = serverDayKey(now)
    local record = EnsureRecord(working, activityId, today)
    local session = type(record.session) == "table" and record.session or nil
    if not session or session.finished then
        return PlayerTransition.Failure(inputState, now, "STRIKE_NOT_STARTED", "打桩尚未开始")
    end
    local t = nowFloat()
    local elapsed = t - (session.startedAt or t)
    if elapsed > STRIKE.DURATION then
        return ActivityEngine.FinishStrike(inputState, activityId, now)
    end
    if (t - (session.lastHitAt or t)) < STRIKE.INTERVAL then
        return PlayerTransition.NoCommit(inputState, now, "strike_too_fast", {})
    end
    session.lastHitAt = t
    session.damage = (session.damage or 0) + STRIKE.DAMAGE_PER_HIT
    local events = {
        PlayerTransition.Event("activity_strike_hit", {
            activityId = activityId,
            damage = STRIKE.DAMAGE_PER_HIT,
            total = session.damage,
        }),
    }
    return PlayerTransition.Finalize(inputState, working, now, "activity_strike_hit", events, false, false)
end

-- 结束打桩：按总伤害分档发放奖励。
function ActivityEngine.FinishStrike(inputState, activityId, now)
    now = PlayerTransition.Now(now)
    local def = ActivityDefinitions.Get(activityId)
    if not def or def.type ~= "strike" then
        return PlayerTransition.Failure(inputState, now, "UNKNOWN_ACTIVITY", "未知活动")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local today = serverDayKey(now)
    local record = EnsureRecord(working, activityId, today)
    local session = type(record.session) == "table" and record.session or nil
    if not session or session.finished then
        return PlayerTransition.NoCommit(inputState, now, "strike_not_active", {})
    end
    session.finished = true
    record.session = nil
    local damage = math.max(0, math.floor(tonumber(session.damage) or 0))
    local tier = def.tiers and def.tiers[1] or nil
    for _, candidate in ipairs(def.tiers or {}) do
        if damage >= (candidate.minDamage or 0) then tier = candidate end
    end
    local events = {}
    local reward = tier and QuestEngine.GrantReward(working, { reward = tier.reward }, now, events) or nil
    events[#events + 1] = PlayerTransition.Event("activity_claimed", {
        activityId = activityId,
        rewardKind = def.rewardKind,
        damage = damage,
        tier = tier and tier.minDamage or 0,
        reward = reward,
    })
    return PlayerTransition.Finalize(inputState, working, now, "activity_claimed", events, false, false)
end

-- 看广告解锁一次额外打桩次数（每日上限）。
function ActivityEngine.UnlockExtraStrike(inputState, activityId, now)
    now = PlayerTransition.Now(now)
    local def = ActivityDefinitions.Get(activityId)
    if not def or def.type ~= "strike" then
        return PlayerTransition.Failure(inputState, now, "UNKNOWN_ACTIVITY", "未知活动")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local today = serverDayKey(now)
    local record = EnsureRecord(working, activityId, today)
    if record.strikeDay ~= today then
        record.strikeDay = today
        record.strikeCount = 0
        record.adCount = 0
    end
    if record.adCount >= STRIKE.AD_PER_DAY then
        return PlayerTransition.Failure(inputState, now, "AD_LIMIT", "今日广告次数已用完")
    end
    record.adCount = record.adCount + 1
    local events = {
        PlayerTransition.Event("activity_ad_unlocked", {
            activityId = activityId,
            adCount = record.adCount,
        }),
    }
    return PlayerTransition.Finalize(inputState, working, now, "activity_ad_unlocked", events, false, false)
end

return ActivityEngine
