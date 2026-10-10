-- ActivityEngine.lua
-- 活动系统服务端引擎：签到活动（每日签到发当天奖励）、每日补充玩法（限时打木桩按伤害结算）。
-- 奖励发放复用任务引擎（QuestEngine.GrantReward），按玩家楼层缩放。

local PlayerTransition = require("server.domain.PlayerTransition")
local QuestEngine = require("server.domain.QuestEngine")
local CombatEngine = require("server.domain.CombatEngine")
local ActivityDefinitions = require("shared.ActivityDefinitions")
local BigNumber = require("shared.BigNumber")
local TowerRules = require("shared.TowerRules")
local RewardClaimEngine = require("server.domain.RewardClaimEngine")
local ChallengeDefinitions = require("shared.ChallengeDefinitions")

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

local function EnsureRecord(state, activityId, today, now)
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
    -- Epoch timestamps survive persistence/reconnection; process CPU time does not.
    if type(record.session) == "table" then
        if record.strikeDay ~= today then
            record.session = nil
        elseif (record.session.startedAt or 0) < 1000000000 then
            -- Recover the old frozen CPU-clock session without consuming another attempt.
            record.session.startedAt = now
            record.session.lastHitAt = 0
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
        EnsureRecord(state, id, today, now)
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
    local record = EnsureRecord(working, activityId, today, now)
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
    local offer = RewardClaimEngine.CreateAdOffer(
        working,
        {
            source = "signin",
            sourceKey = string.format(
                "signin:%s:%d",
                activityId,
                record.totalDays
            ),
            baseReward = reward,
            meta = {
                activityId = activityId,
                day = dayIndex,
            },
        },
        now
    )
    if offer then
        events[#events + 1] = PlayerTransition.Event(
            "reward_offer_pending",
            {
                rewardId = offer.id,
                source = offer.source,
                baseReward = offer.baseReward,
                extraReward = offer.extraReward,
            }
        )
    end
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
    local record = EnsureRecord(working, activityId, today, now)
    if record.strikeDay ~= today then
        record.strikeDay = today
        record.strikeCount = 0
        record.adCount = 0
    end
    local limit = STRIKE.BASE_PER_DAY + record.adCount
    if type(record.session) == "table" and record.session.finished ~= true then
        return PlayerTransition.Finalize(inputState, working, now, "activity_strike_resumed", {}, false, false)
    end
    if record.strikeCount >= limit then
        return PlayerTransition.Failure(inputState, now, "STRIKE_LIMIT", "今日次数已用完")
    end
    record.strikeCount = record.strikeCount + 1
    record.session = { startedAt = now, lastHitAt = 0, damage = 0, finished = false, rewardLevel = working.level }
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
    local record = EnsureRecord(working, activityId, today, now)
    local session = type(record.session) == "table" and record.session or nil
    if session and session.dungeonStageId then
        return PlayerTransition.Failure(inputState, now, "DUNGEON_TRIAL_REQUIRED", "请在副本战斗中完成挑战")
    end
    if not session or session.finished then
        return PlayerTransition.Failure(inputState, now, "STRIKE_NOT_STARTED", "打桩尚未开始")
    end
    local elapsed = now - (session.startedAt or now)
    if elapsed >= STRIKE.DURATION then
        return ActivityEngine.FinishStrike(inputState, activityId, now)
    end
    if (now - (session.lastHitAt or 0)) < STRIKE.INTERVAL then
        return PlayerTransition.NoCommit(inputState, now, "strike_too_fast", {})
    end
    session.lastHitAt = now
    -- 与放置挂机同一套伤害计算：木桩防御为 0，按攻击序列多段权重结算总伤害
    -- （放置挂机一次攻击含多段命中 weights 0.30~0.85，累计约 2 倍攻击）
    local sequenceIndex = math.random(1, 3)
    local sequence = TowerRules.AttackSequence(sequenceIndex)
    local weights = sequence and sequence.weights or { 1.0 }
    local totalDamage = 0
    local lastCritical = false
    local lastLucky = false
    for _, weight in ipairs(weights) do
        local damage, critical, lucky = CombatEngine.PlayerHitDamage(working, {
            encounter = "normal",
            def = 0,
            defBig = BigNumber.Zero(),
        }, weight, nil)
        totalDamage = totalDamage + math.max(1, math.floor(BigNumber.ToNumber(damage) or 0))
        if critical then lastCritical = true end
        if lucky then lastLucky = true end
    end
    session.damage = (session.damage or 0) + totalDamage
    local events = {
        PlayerTransition.Event("activity_strike_hit", {
            activityId = activityId,
            damage = totalDamage,
            critical = lastCritical,
            lucky = lastLucky,
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
    local record = EnsureRecord(working, activityId, today, now)
    local session = type(record.session) == "table" and record.session or nil
    if session and session.dungeonStageId then
        return PlayerTransition.Failure(inputState, now, "DUNGEON_TRIAL_REQUIRED", "请在副本战斗中完成挑战")
    end
    if not session or session.finished then
        return PlayerTransition.NoCommit(inputState, now, "strike_not_active", {})
    end
    session.finished = true
    record.session = nil
    local damage = math.max(0, math.floor(tonumber(session.damage) or 0))
    local tier = def.tiers and def.tiers[1] or nil
    for index, candidate in ipairs(def.tiers or {}) do
        local target = index == 1 and 0 or require("shared.GameBalance").StrikeTarget(session.rewardLevel or working.level, index)
        if damage >= target then tier = candidate end
    end
    local events = {}
    local reward = tier and QuestEngine.GrantReward(working, { reward = tier.reward }, now, events) or nil
    working.challenges = type(working.challenges) == "table"
        and working.challenges or ChallengeDefinitions.NewState()
    working.challenges.lastStrikeDamage = ChallengeDefinitions.ClampScore(damage)
    working.challenges.lastStrikeAt = now
    if working.challenges.lastStrikeDamage > (working.challenges.bestStrikeDamage or 0) then
        working.challenges.bestStrikeDamage = working.challenges.lastStrikeDamage
    end
    events[#events + 1] = PlayerTransition.Event("activity_claimed", {
        activityId = activityId,
        rewardKind = def.rewardKind,
        damage = damage,
        bestDamage = working.challenges.bestStrikeDamage,
        ranked = true,
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
    local record = EnsureRecord(working, activityId, today, now)
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
