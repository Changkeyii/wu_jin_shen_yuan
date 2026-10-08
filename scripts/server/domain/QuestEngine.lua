-- QuestEngine.lua
-- 任务系统服务端引擎：进度累计、每日重置、完成判定、奖励发放、领取（单领/一键全领）。
-- 服务端权威，客户端只展示；进度随 quests 存档字段走快照/增量同步。

local Catalog = require("server.domain.Catalog")
local PlayerTransition = require("server.domain.PlayerTransition")
local QuestDefinitions = require("shared.QuestDefinitions")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")

local QuestEngine = {}

local DAY_SECONDS = 24 * 60 * 60
local TIMEZONE_OFFSET_SECONDS = 8 * 60 * 60

local function serverDayKey(now)
    return math.floor(((tonumber(now) or PlayerTransition.Now()) + TIMEZONE_OFFSET_SECONDS) / DAY_SECONDS)
end

local function serverWeekKey(now)
    local dayKey = serverDayKey(now)
    return math.floor((dayKey + 3) / 7)
end

function QuestEngine.NewQuests()
    return {
        newbie = { claimed = {} },
        daily = { dayKey = 0, progress = {}, claimed = {} },
        weekly = { weekKey = 0, progress = {}, claimed = {} },
        achievement = { claimed = {} },
        questStats = {
            monster_kill = 0,
            elite_kill = 0,
            boss_kill = 0,
            item_pickup = 0,
            chest_open = 0,
            decompose = 0,
            sell = 0,
            floor_advance = 0,
            abyss_run = 0,
            campaign_stage_clear = 0,
            campaign_chapter_clear = 0,
            campaign_star_earned = 0,
            campaign_battle_clear = 0,
            campaign_boss_clear = 0,
            strike_record = 0,
        },
    }
end

function QuestEngine.DayKey(now)
    return serverDayKey(now)
end

-- 每日任务重置：跨日清空当日进度与领取标记。
function QuestEngine.EnsureDailyReset(state, now)
    if type(state) ~= "table" then return end
    state.quests = type(state.quests) == "table" and state.quests or QuestEngine.NewQuests()
    local daily = state.quests.daily
    if type(daily) ~= "table" then
        daily = { dayKey = 0, progress = {}, claimed = {} }
        state.quests.daily = daily
    end
    local dayKey = serverDayKey(now)
    if daily.dayKey ~= dayKey then
        daily.dayKey = dayKey
        daily.progress = {}
        daily.claimed = {}
    end
    local weekly = state.quests.weekly
    if type(weekly) ~= "table" then
        weekly = { weekKey = 0, progress = {}, claimed = {} }
        state.quests.weekly = weekly
    end
    local weekKey = serverWeekKey(now)
    if weekly.weekKey ~= weekKey then
        weekly.weekKey = weekKey
        weekly.progress = {}
        weekly.claimed = {}
    end
end

-- 玩法结算处调用：累计 questStats（新手/成就）与当日 daily.progress（每日任务）。
function QuestEngine.Track(state, metric, amount, now)
    if type(state) ~= "table" or type(metric) ~= "string" then return end
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then return end
    QuestEngine.EnsureDailyReset(state, now)
    state.quests.questStats = state.quests.questStats or {}
    state.quests.questStats[metric] = (state.quests.questStats[metric] or 0) + amount
    local daily = state.quests.daily
    daily.progress = daily.progress or {}
    daily.progress[metric] = (daily.progress[metric] or 0) + amount
    local weekly = state.quests.weekly or { weekKey = 0, progress = {}, claimed = {} }
    state.quests.weekly = weekly
    weekly.progress = weekly.progress or {}
    weekly.progress[metric] = (weekly.progress[metric] or 0) + amount
end

-- 进度/完成/领取判定统一走 shared.QuestDefinitions 的只读实现（与客户端展示一致）。
function QuestEngine.CurrentValue(state, def, now)
    return QuestDefinitions.CurrentValue(state, def)
end

function QuestEngine.IsCompleted(state, def, now)
    return QuestDefinitions.IsCompleted(state, def)
end

function QuestEngine.IsClaimed(state, def)
    return QuestDefinitions.IsClaimed(state, def)
end

local function MarkClaimed(state, def)
    state.quests = type(state.quests) == "table" and state.quests or QuestEngine.NewQuests()
    if def.type == "daily" then
        local daily = state.quests.daily
        daily.claimed = daily.claimed or {}
        daily.claimed[def.id] = true
        return
    end
    if def.type == "weekly" then
        local weekly = state.quests.weekly or { weekKey = 0, progress = {}, claimed = {} }
        state.quests.weekly = weekly
        weekly.claimed = weekly.claimed or {}
        weekly.claimed[def.id] = true
        return
    end
    local bucket = def.type == "newbie" and state.quests.newbie or state.quests.achievement
    bucket.claimed = bucket.claimed or {}
    bucket.claimed[def.id] = true
end

-- 经验发放：与战斗/离线同源升级结算。
function QuestEngine.AddExperience(state, amount, events)
    local gained = math.max(0, math.floor(tonumber(amount) or 0))
    local previousLevel = math.max(1, math.floor(tonumber(state.level) or 1))
    state.exp = (state.exp or 0) + gained
    local levelUps = 0
    while state.exp >= Catalog.NextExp(state.level) do
        state.exp = state.exp - Catalog.NextExp(state.level)
        state.level = state.level + 1
        levelUps = levelUps + 1
    end
    state.nextExp = Catalog.NextExp(state.level)
    if levelUps > 0 and type(events) == "table" then
        events[#events + 1] = PlayerTransition.Event("level_up", {
            previousLevel = previousLevel,
            level = state.level,
            levelsGained = levelUps,
            exp = state.exp,
            nextExp = state.nextExp,
            expGained = gained,
        })
        local RewardClaimEngine = require(
            "server.domain.RewardClaimEngine"
        )
        RewardClaimEngine.GrantLevelMilestones(
            state,
            previousLevel,
            state.level,
            PlayerTransition.Now(),
            events
        )
    end
    return levelUps > 0
end

-- 发放任务奖励（金币/碎片/经验），返回奖励明细。
function QuestEngine.GrantReward(state, def, now, events)
    local referenceFloor = math.max(QuestDefinitions.REFERENCE_FLOOR_MIN,
        math.floor(tonumber(state and state.maxFloor) or QuestDefinitions.REFERENCE_FLOOR_MIN))
    local preview = QuestDefinitions.RewardPreview(def and def.reward, referenceFloor)
    if not LargeNumber.IsZero(preview.gold) then
        PlayerTransition.AddCurrency(state, "gold", preview.gold)
    end
    if preview.fragments > 0 then
        PlayerTransition.AddCurrency(state, "fragments", preview.fragments)
    end
    if preview.exp > 0 then
        QuestEngine.AddExperience(state, preview.exp, events)
    end
    if preview.abyssTickets > 0 then
        local AbyssEngine = require("server.domain.AbyssEngine")
        AbyssEngine.GrantTickets(state, preview.abyssTickets)
    end
    return {
        gold = preview.gold,
        fragments = preview.fragments,
        exp = preview.exp,
        abyssTickets = preview.abyssTickets,
        level = state.level,
    }
end

local function CreateRewardOffer(state, def, reward, now, events)
    local RewardClaimEngine = require(
        "server.domain.RewardClaimEngine"
    )
    local sourceKey = "quest:" .. tostring(def.id)
    if def.type == "daily" then
        sourceKey = sourceKey .. ":" .. tostring(serverDayKey(now))
    end
    local offer, offerError = RewardClaimEngine.CreateAdOffer(
        state,
        {
            source = "task",
            sourceKey = sourceKey,
            baseReward = reward,
            meta = {},
        },
        now
    )
    if not offer and offerError == "REWARD_OFFER_CAPACITY" then
        return nil, offerError
    end
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
end

-- 单领一个任务奖励。
function QuestEngine.Claim(inputState, questId, now)
    now = PlayerTransition.Now(now)
    local def = QuestDefinitions.Get(questId)
    if not def then
        return PlayerTransition.Failure(inputState, now, "UNKNOWN_QUEST", "unknown quest")
    end
    local working = PlayerTransition.Copy(inputState, now)
    QuestEngine.EnsureDailyReset(working, now)
    if QuestEngine.IsClaimed(working, def) then
        return PlayerTransition.Failure(inputState, now, "QUEST_ALREADY_CLAIMED", "该任务奖励已领取")
    end
    if not QuestEngine.IsCompleted(working, def, now) then
        return PlayerTransition.Failure(inputState, now, "QUEST_NOT_COMPLETED", "任务尚未完成")
    end
    local events = {}
    local reward = QuestEngine.GrantReward(working, def, now, events)
    local _, offerError = CreateRewardOffer(
        working,
        def,
        reward,
        now,
        events
    )
    if offerError then
        return PlayerTransition.Failure(
            inputState,
            now,
            offerError,
            "激励奖励待领取数量已满，请先处理旧奖励"
        )
    end
    MarkClaimed(working, def)
    events[#events + 1] = PlayerTransition.Event("quest_claimed", {
        questId = def.id,
        questType = def.type,
        reward = reward,
    })
    return PlayerTransition.Finalize(inputState, working, now, "quest_claimed", events, false, false)
end

-- 一键领取所有可领任务（跨分类），只提交一次状态。
-- 领取明细通过 delta.events 中的 quest_claimed 事件下发给客户端。
function QuestEngine.ClaimAll(inputState, now)
    now = PlayerTransition.Now(now)
    local working = PlayerTransition.Copy(inputState, now)
    QuestEngine.EnsureDailyReset(working, now)
    local events = {}
    local count = 0
    for _, questType in ipairs(QuestDefinitions.ORDER) do
        for _, questId in ipairs(QuestDefinitions.SortedIds(questType)) do
            local def = QuestDefinitions.Get(questId)
            if QuestEngine.IsCompleted(working, def, now)
                and not QuestEngine.IsClaimed(working, def)
            then
                local reward = QuestEngine.GrantReward(working, def, now, events)
                local _, offerError = CreateRewardOffer(
                    working,
                    def,
                    reward,
                    now,
                    events
                )
                if offerError then
                    return PlayerTransition.Failure(
                        inputState,
                        now,
                        offerError,
                        "激励奖励待领取数量已满，请先处理旧奖励"
                    )
                end
                MarkClaimed(working, def)
                count = count + 1
                events[#events + 1] = PlayerTransition.Event("quest_claimed", {
                    questId = def.id,
                    questType = def.type,
                    reward = reward,
                })
            end
        end
    end
    if count == 0 then
        return PlayerTransition.NoCommit(inputState, now, "quest_claim_all_empty")
    end
    return PlayerTransition.Finalize(inputState, working, now, "quest_claim_all", events, false, false)
end

return QuestEngine
