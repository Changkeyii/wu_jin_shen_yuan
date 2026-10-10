local Catalog = require("shared.DungeonCatalog")
local Activity = require("server.domain.ActivityEngine")
local ActivityDefinitions = require("shared.ActivityDefinitions")
local Transition = require("server.domain.PlayerTransition")
local Quest = require("server.domain.QuestEngine")
local Dungeon = {}

function Dungeon.Reserve(state, stage, now)
    if state.level < stage.minLevel then
        return Transition.Failure(state, now, "DUNGEON_LOCKED", "该难度需达到 Lv." .. tostring(stage.minLevel))
    end
    for id, record in pairs(state.activities or {}) do
        if id ~= stage.activityId and record.session and record.session.dungeonStageId
            and record.strikeDay == Quest.DayKey(now) then
            return Transition.Failure(state, now, "DUNGEON_ACTIVE", "请先完成或放弃当前每日挑战")
        end
    end
    local record = state.activities and state.activities[stage.activityId]
    if record and record.session and record.strikeDay == Quest.DayKey(now) then
        local session = record.session
        if session.dungeonStageId ~= stage.id then
            return Transition.Failure(state, now, "DUNGEON_ACTIVE", "请先完成或放弃当前每日挑战")
        end
        return Transition.NoCommit(state, now, "dungeon_resumed")
    end
    local result = Activity.BeginStrike(state, stage.activityId, now)
    if not result.ok then return result end
    local working = result.state
    working.activities[stage.activityId].session.dungeonStageId = stage.id
    working.activities[stage.activityId].session.dungeonRunId = "dungeon:" .. tostring(now) .. ":" .. tostring((state.revision or 0) + 1)
    return Transition.Finalize(state, working, now, "dungeon_prepared", {}, false, false)
end

function Dungeon.Settle(state, stage, outcome, now, runId)
    local record = state.activities and state.activities[stage.activityId]
    local active = record and record.session
    if not active or active.dungeonStageId ~= stage.id then
        return Transition.NoCommit(state, now, "dungeon_already_settled")
    end
    if runId and active.dungeonRunId ~= runId then
        return Transition.Failure(state, now, "DUNGEON_RUN_CHANGED", "本次副本已改变，请重新同步")
    end
    local working = Transition.Copy(state, now)
    working.activities[stage.activityId].session = nil
    local events = {}
    local reward
    if outcome and outcome.won then
        -- Reward is bound to the selected fixed tier, never the player's later floor.
        local rewardState = { level = stage.recommendedLevel }
        reward = ActivityDefinitions.RewardPreview(stage.reward, rewardState.level)
        Transition.AddCurrency(working, "gold", reward.gold)
        Transition.AddCurrency(working, "fragments", reward.fragments)
        require("server.domain.AbyssEngine").GrantTickets(working, reward.abyssTickets)
        Quest.AddExperience(working, reward.exp, events)
        Quest.Track(working, "campaign_battle_clear", 1, now)
        events[#events + 1] = Transition.Event("activity_claimed", {
            activityId = stage.activityId, dungeonId = stage.id, reward = reward,
            rewardKind = stage.dungeon == "tickets" and "abyssTickets" or stage.dungeon,
            damage = 0, ranked = false,
        })
    end
    return Transition.Finalize(state, working, now, outcome and outcome.won and "dungeon_cleared" or "dungeon_aborted",
        events, false, false)
end

return Dungeon
