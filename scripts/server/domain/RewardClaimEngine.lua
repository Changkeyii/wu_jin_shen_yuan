local RewardClaimDefinitions = require("shared.RewardClaimDefinitions")
local AbyssDefinitions = require("shared.AbyssDefinitions")
local LargeNumber = require("shared.LargeNumber")
local PlayerTransition = require("server.domain.PlayerTransition")
local QuestEngine = require("server.domain.QuestEngine")
local TableUtils = require("server.domain.TableUtils")

local RewardClaimEngine = {}

local function ensureState(state)
    state.rewardClaims = type(state.rewardClaims) == "table"
        and state.rewardClaims or RewardClaimDefinitions.NewState()
    state.rewardClaims.pending = type(state.rewardClaims.pending) == "table"
        and state.rewardClaims.pending or {}
    state.rewardClaims.nextId = math.max(
        1,
        math.floor(tonumber(state.rewardClaims.nextId) or 1)
    )
    return state.rewardClaims
end

local function normalizedReward(reward)
    reward = type(reward) == "table" and reward or {}
    local gold = LargeNumber.Normalize(reward.gold or LargeNumber.Zero())
    return {
        gold = gold,
        exp = math.max(0, math.floor(tonumber(reward.exp) or 0)),
        fragments = math.max(0, math.floor(tonumber(reward.fragments) or 0)),
        abyssTickets = math.max(0, math.floor(tonumber(reward.abyssTickets) or 0)),
    }
end

local function emptyReward(reward)
    return LargeNumber.IsZero(reward.gold)
        and reward.exp <= 0
        and reward.fragments <= 0
        and reward.abyssTickets <= 0
end

local function addReward(target, reward)
    target.gold = LargeNumber.Add(target.gold, reward.gold)
    target.exp = target.exp + reward.exp
    target.fragments = target.fragments + reward.fragments
    target.abyssTickets = target.abyssTickets + reward.abyssTickets
end

local function applyReward(state, reward, events)
    if not LargeNumber.IsZero(reward.gold) then
        PlayerTransition.AddCurrency(state, "gold", reward.gold)
    end
    if reward.fragments > 0 then
        PlayerTransition.AddCurrency(state, "fragments", reward.fragments)
    end
    if reward.exp > 0 then
        QuestEngine.AddExperience(state, reward.exp, events)
    end
    if reward.abyssTickets > 0 then
        state.abyss = type(state.abyss) == "table"
            and state.abyss or { tickets = 0 }
        state.abyss.tickets = math.max(
            0,
            math.floor(tonumber(state.abyss.tickets) or 0)
        ) + reward.abyssTickets
    end
end

function RewardClaimEngine.GrantLevelMilestones(
    state,
    previousLevel,
    currentLevel,
    now,
    events
)
    previousLevel = math.max(1, math.floor(tonumber(previousLevel) or 1))
    currentLevel = math.max(previousLevel, math.floor(tonumber(currentLevel) or previousLevel))
    events = type(events) == "table" and events or {}
    for level = previousLevel + 1, currentLevel do
        local reward = RewardClaimDefinitions.LevelMilestoneReward(level)
        if reward then
            state.abyss = type(state.abyss) == "table"
                and state.abyss or { tickets = 0 }
            local tickets = math.max(0, math.floor(tonumber(reward.abyssTickets) or 0))
            state.abyss.tickets = math.max(
                0,
                math.floor(tonumber(state.abyss.tickets) or 0)
            ) + tickets
            if (reward.fragments or 0) > 0 then
                PlayerTransition.AddCurrency(
                    state,
                    "fragments",
                    reward.fragments
                )
            end
            local baseReward = normalizedReward {
                gold = LargeNumber.Zero(),
                exp = 0,
                fragments = reward.fragments or 0,
                abyssTickets = tickets,
            }
            local offer = RewardClaimEngine.CreateAdOffer(
                state,
                {
                    source = "level_milestone",
                    sourceKey = "level:" .. tostring(level),
                    baseReward = baseReward,
                    meta = { level = level },
                },
                now
            )
            events[#events + 1] = PlayerTransition.Event(
                "level_milestone_reward",
                {
                    level = level,
                    reward = baseReward,
                    rewardId = offer and offer.id or nil,
                }
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
        end
    end
end

function RewardClaimEngine.CreateAdOffer(state, spec, now)
    spec = type(spec) == "table" and spec or {}
    local source = tostring(spec.source or "")
    local sourceKey = tostring(spec.sourceKey or "")
    if not RewardClaimDefinitions.IsKnownSource(source)
        or sourceKey == ""
    then
        return nil
    end
    local base = normalizedReward(spec.baseReward)
    if emptyReward(base) then return nil end
    local extra = {
        gold = LargeNumber.MultiplyRatio(
            base.gold,
            RewardClaimDefinitions.AD_EXTRA_MULTIPLIER,
            1
        ),
        exp = base.exp * RewardClaimDefinitions.AD_EXTRA_MULTIPLIER,
        fragments = base.fragments * RewardClaimDefinitions.AD_EXTRA_MULTIPLIER,
        abyssTickets = base.abyssTickets
            * RewardClaimDefinitions.AD_EXTRA_MULTIPLIER,
    }
    local claims = ensureState(state)
    for _, pending in ipairs(claims.pending) do
        if pending.sourceKey == sourceKey then
            return pending
        end
    end
    local timestamp = PlayerTransition.Now(now)
    for index = #claims.pending, 1, -1 do
        local pending = claims.pending[index]
        if pending.expiresAt > 0
            and pending.expiresAt < timestamp
        then
            table.remove(claims.pending, index)
        end
    end
    if #claims.pending >= RewardClaimDefinitions.MAX_PENDING then
        local overflow = nil
        for _, pending in ipairs(claims.pending) do
            if pending.sourceKey == "overflow:reward-offers" then
                overflow = pending
                break
            end
        end
        if not overflow then
            overflow = claims.pending[1]
            overflow.source = "task"
            overflow.sourceKey = "overflow:reward-offers"
            overflow.meta = {}
        end
        addReward(overflow.baseReward, base)
        addReward(overflow.extraReward, extra)
        print("[RewardClaim] merged overflow offer sourceKey="
            .. sourceKey)
        return overflow
    end
    local id = string.format("rc.%d.%d", claims.nextId, timestamp)
    claims.nextId = claims.nextId + 1
    local pending = {
        id = id,
        source = source,
        sourceKey = sourceKey,
        createdAt = PlayerTransition.Now(now),
        expiresAt = math.max(0, math.floor(tonumber(spec.expiresAt) or 0)),
        baseReward = base,
        extraReward = extra,
        meta = TableUtils.DeepCopy(spec.meta or {}),
    }
    claims.pending[#claims.pending + 1] = pending
    return pending
end

function RewardClaimEngine.ClaimAdExtra(inputState, rewardId, now)
    now = PlayerTransition.Now(now)
    local working = PlayerTransition.Copy(inputState, now)
    local claims = ensureState(working)
    local index = nil
    local pending = nil
    for candidateIndex, candidate in ipairs(claims.pending) do
        if candidate.id == rewardId then
            index = candidateIndex
            pending = candidate
            break
        end
    end
    if not pending then
        return PlayerTransition.Failure(
            inputState,
            now,
            "REWARD_OFFER_NOT_FOUND",
            "该激励奖励已领取或已失效"
        )
    end
    if pending.expiresAt > 0 and pending.expiresAt < now then
        table.remove(claims.pending, index)
        return PlayerTransition.Finalize(
            inputState,
            working,
            now,
            "reward_offer_expired",
            {},
            false,
            false
        )
    end
    local reward = normalizedReward(pending.extraReward)
    local events = {}
    applyReward(working, reward, events)
    table.remove(claims.pending, index)
    events[#events + 1] = PlayerTransition.Event(
        "reward_ad_extra_claimed",
        {
            rewardId = pending.id,
            source = pending.source,
            multiplier = RewardClaimDefinitions.AD_MULTIPLIER,
            reward = reward,
        }
    )
    return PlayerTransition.Finalize(
        inputState,
        working,
        now,
        "reward_ad_extra_claimed",
        events,
        false,
        false
    )
end

function RewardClaimEngine.ClaimExclusiveAdGift(
    inputState,
    giftId,
    now
)
    now = PlayerTransition.Now(now)
    local working = PlayerTransition.Copy(inputState, now)
    local claims = ensureState(working)
    claims.exclusive = type(claims.exclusive) == "table"
        and claims.exclusive
        or RewardClaimDefinitions.NewState().exclusive
    local exclusive = claims.exclusive
    local dayKey = math.floor((now + 8 * 60 * 60) / (24 * 60 * 60))
    if giftId ~= "daily" then
        return PlayerTransition.Failure(
            inputState,
            now,
            "INVALID_AD_GIFT",
            "未知激励补给"
        )
    end
    if exclusive.dailyDayKey ~= dayKey then
        exclusive.dailyDayKey = dayKey
        exclusive.dailyClaimed = 0
    end
    exclusive.dailyClaimed = math.max(
        0,
        math.floor(tonumber(exclusive.dailyClaimed) or 0)
    )
    if exclusive.dailyClaimed >= AbyssDefinitions.DAILY_AD_TICKET_LIMIT then
        return PlayerTransition.Failure(
            inputState,
            now,
            "AD_GIFT_ALREADY_CLAIMED",
            "今日深渊补给已看满 3 次"
        )
    end
    exclusive.dailyClaimed = exclusive.dailyClaimed + 1
    local reward = {
        abyssTickets = AbyssDefinitions.DailyAdTickets(working.level),
        fragments = 0,
    }

    local granted = normalizedReward {
        gold = LargeNumber.Zero(),
        exp = 0,
        fragments = reward.fragments or 0,
        abyssTickets = reward.abyssTickets or 0,
    }
    local events = {}
    applyReward(working, granted, events)
    events[#events + 1] = PlayerTransition.Event(
        "ad_exclusive_reward_claimed",
        {
            giftId = giftId,
            reward = granted,
        }
    )
    return PlayerTransition.Finalize(
        inputState,
        working,
        now,
        "ad_exclusive_reward_claimed",
        events,
        false,
        false
    )
end

RewardClaimEngine.EnsureState = ensureState
RewardClaimEngine.NormalizeReward = normalizedReward
return RewardClaimEngine
