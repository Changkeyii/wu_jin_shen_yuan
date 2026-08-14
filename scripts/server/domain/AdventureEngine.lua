local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local TowerRules = require("shared.TowerRules")
local FloorRoute = require("shared.FloorRoute")
local StoryCatalog = require("shared.StoryCatalog")
local PlayerTransition = require("server.domain.PlayerTransition")
local DomainMath = require("server.domain.DomainMath")
local EquipmentEngine = require("server.domain.EquipmentEngine")
local CombatEngine = require("server.domain.CombatEngine")
local QuestEngine = require("server.domain.QuestEngine")
local TutorialEngine = require("server.domain.TutorialEngine")

local AdventureEngine = {}
local storyGateEvent
local maybeQueueStoryGate

local function createPrologueGate()
    return {
        storyId = StoryCatalog.PROLOGUE.id,
        chapter = 0,
        floor = 1,
        phase = "prologue",
        title = StoryCatalog.PROLOGUE.title,
        lines = TableUtils.DeepCopy(StoryCatalog.PROLOGUE.lines),
        lineIndex = 1,
    }
end

storyGateEvent = function(gate)
    return PlayerTransition.Event("story_gate", {
        storyId = gate.storyId,
        chapter = gate.chapter,
        floor = gate.floor,
        phase = gate.phase,
        title = gate.title,
        lines = TableUtils.DeepCopy(gate.lines),
        lineIndex = gate.lineIndex,
    })
end

maybeQueueStoryGate = function(state, chapter, phase, context, events)
    chapter = math.max(1, TableUtils.ToInteger(chapter, 1))
    local marker = string.format("story:%d:%s", chapter, phase)
    state.ruleAcknowledgements = state.ruleAcknowledgements or {}
    if state.ruleAcknowledgements[marker] == true then return false end

    local automation = state.automationPolicy or {}
    if automation.autoSkipStory and state.interactionMode ~= "cinematic" then
        state.ruleAcknowledgements[marker] = true
        if phase == "memory" then
            state.storyProgress.highestCompletedChapter = math.max(
                state.storyProgress.highestCompletedChapter or 0,
                chapter
            )
        end
        events[#events + 1] = PlayerTransition.Event("story_skipped", {
            storyId = StoryCatalog.GetChapter(chapter).id .. ":" .. phase,
            chapter = chapter,
            phase = phase,
            automatic = true,
            offline = context and context.offline == true,
        })
        return false
    end

    local gate = StoryCatalog.GetGate(chapter, phase)
    gate.lineIndex = 1
    state.pendingStoryGate = gate
    state.pauseReason = "story_gate"
    events[#events + 1] = storyGateEvent(gate)
    return true
end

function AdventureEngine.SetAutoRun(inputState, enabled, now)
    if type(enabled) ~= "boolean" then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "enabled must be a boolean")
    end
    local working = PlayerTransition.Copy(inputState, now)
    -- 序章教学战斗：开挂机前强制回到第 1 层，避免老号高楼层被秒。
    local tutorialFloorEvents = {}
    if enabled and TutorialEngine and TutorialEngine.IsActive and TutorialEngine.IsActive(working) then
        TutorialEngine.EnsureTutorialFloor(working, tutorialFloorEvents)
    end
    if enabled and working.aidPending then
        return PlayerTransition.Failure(inputState, now, "TOWER_AID_PENDING", "claim tower aid before the third attempt", {
            PlayerTransition.Event("tower_aid_pending", { floor = working.floor }),
        })
    end
    if enabled and #working.inventory >= Catalog.GetInventoryCapacity(working) and working.inventoryPolicy.pauseOnFull and not EquipmentEngine.HasAutoDispositionPolicy(working) then
        return PlayerTransition.Failure(inputState, now, "INVENTORY_FULL", "inventory is full", {
            PlayerTransition.Event("inventory_full", { capacity = Catalog.GetInventoryCapacity(working) }),
        })
    end
    if working.autoRun == enabled then
        return PlayerTransition.NoCommit(inputState, now, "auto_run_unchanged")
    end
    working.autoRun = enabled
    working.pauseReason = nil
    local events = { PlayerTransition.Event("auto_run_changed", { enabled = enabled }) }
    for _, event in ipairs(tutorialFloorEvents) do
        events[#events + 1] = event
    end
    local storyProgress = working.storyProgress or {}
    local automation = working.automationPolicy or {}
    if enabled and not storyProgress.introCompleted then
        if automation.autoSkipStory and working.interactionMode ~= "cinematic" then
            storyProgress.introCompleted = true
            working.storyProgress = storyProgress
            events[#events + 1] = PlayerTransition.Event("story_skipped", {
                storyId = StoryCatalog.PROLOGUE.id,
                chapter = 0,
                phase = "prologue",
                automatic = true,
            })
        else
            local gate = createPrologueGate()
            working.pendingStoryGate = gate
            working.pauseReason = "story_gate"
            events[#events + 1] = storyGateEvent(gate)
        end
    end
    return PlayerTransition.Finalize(inputState, working, now, "auto_run_changed", events, false, false)
end

-- 交互事件：服务端生成待决状态，玩家必须主动选择；超时只会跳过。
local function buildPendingEvent(state, encounter, now)
    local floor = state.floor or 1
    local variant = encounter.variant or 1
    local pending = {
        eventId = string.format("ev.%d.%d.%d", floor, encounter.room or 1, now),
        eventType = encounter.kind,
        floor = floor,
        room = encounter.room or 1,
        encounterId = encounter.encounterId,
        createdAt = now,
        expiresAt = now + Catalog.EVENT_DECISION_SECONDS,
        variant = variant,
    }

    if encounter.kind == "chest" then
        pending.actions = { "open", "skip" }
        pending.title = "迷雾宝箱"
        pending.description = "开启宝箱可获得金币与碎片，跳过则不会有任何消耗。"
        pending.fragmentsReward = Catalog.EVENT_CHEST_FRAGMENTS * variant
    elseif encounter.kind == "merchant" then
        pending.actions = { "buy", "skip" }
        pending.title = "深渊商人"
        pending.description = "支付金币换取强化碎片，也可以直接离开。"
        pending.goldCost = Catalog.GetEventMerchantCost(floor, variant)
        pending.fragmentsReward = Catalog.EVENT_MERCHANT_FRAGMENTS * variant
    else
        pending.actions = { "accept", "skip" }
        pending.title = "未知遗迹"
        pending.description = "接受试炼可能获得碎片奖励，跳过则安全通过。"
        pending.fragmentsReward = Catalog.EVENT_RANDOM_FRAGMENTS * variant
    end

    return pending
end

local function pendingEventPayload(pending)
    return {
        eventId = pending.eventId,
        eventType = pending.eventType,
        floor = pending.floor,
        room = pending.room,
        encounterId = pending.encounterId,
        expiresAt = pending.expiresAt,
        actions = TableUtils.DeepCopy(pending.actions),
        title = pending.title,
        description = pending.description,
        goldCost = pending.goldCost and LargeNumber.ToString(pending.goldCost) or nil,
        fragmentsReward = pending.fragmentsReward,
    }
end

function AdventureEngine.EnterEncounter(inputState, request, rng, now)
    request = type(request) == "table" and request or {}
    local working = PlayerTransition.Copy(inputState, now)
    local expectedRoom = math.min(10, (working.position or 0) + 1)
    local expected = FloorRoute.GetEncounter(working.floor, expectedRoom)
    local expectedRouteId = FloorRoute.RouteId(working.floor)

    if not working.autoRun then
        return PlayerTransition.Failure(inputState, now, "AUTO_RUN_DISABLED", "挂机尚未开启")
    end
    if working.pendingStoryGate then
        return PlayerTransition.Failure(inputState, now, "STORY_GATE_PENDING", "剧情尚未完成")
    end
    if working.pendingEvent then
        if working.pendingEvent.encounterId == request.encounterId then
            return PlayerTransition.NoCommit(inputState, now, "event_already_pending")
        end
        return PlayerTransition.Failure(inputState, now, "EVENT_DECISION_PENDING", "请先处理当前事件")
    end
    if working.aidPending then
        return PlayerTransition.Failure(inputState, now, "TOWER_AID_PENDING", "请先领取深渊援助")
    end
    if working.currentMonster then
        if working.currentMonster.id == request.encounterId then
            return PlayerTransition.NoCommit(inputState, now, "encounter_already_started")
        end
        return PlayerTransition.Failure(inputState, now, "BATTLE_IN_PROGRESS", "当前战斗尚未结束")
    end
    if request.routeId ~= expectedRouteId
        or not expected
        or request.encounterId ~= expected.encounterId
        or request.room ~= expectedRoom
    then
        return PlayerTransition.Failure(inputState, now, "STALE_ENCOUNTER", "楼层路线已更新，请等待最新配置")
    end
    if #working.inventory >= Catalog.GetInventoryCapacity(working)
        and working.inventoryPolicy.pauseOnFull
        and not EquipmentEngine.HasAutoDispositionPolicy(working)
    then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        return PlayerTransition.Finalize(inputState, working, now, "inventory_full", {
            PlayerTransition.Event("inventory_full", { capacity = Catalog.GetInventoryCapacity(working) }),
        }, false, false, true)
    end
    if BigNumber.IsZero(DomainMath.Magnitude(working.hpBig, working.hp, 0)) then
        DomainMath.SetPlayerHp(working, DomainMath.StatMagnitude(working.stats, "hp"))
    end
    if working.floor % 10 == 0 then
        local phase = expectedRoom == 1 and "opening"
            or (expectedRoom == 10 and "boss" or nil)
        local storyEvents = {}
        if phase and maybeQueueStoryGate(
            working,
            math.floor(working.floor / 10),
            phase,
            { offline = false },
            storyEvents
        ) then
            return PlayerTransition.Finalize(inputState, working, now, "story_gate", storyEvents, false, false, true)
        end
    end

    working.position = expectedRoom
    working.currentEvent = expected.eventType
    local events = {
        PlayerTransition.Event("cell_entered", {
            position = expectedRoom,
            room = expectedRoom,
            floor = working.floor,
            routeId = expectedRouteId,
            encounterId = expected.encounterId,
            eventType = expected.eventType,
            encounterKind = expected.kind,
        }),
    }
    if TowerRules.IsInteractiveEvent(expected.kind) then
        local pending = buildPendingEvent(working, expected, now)
        working.pendingEvent = pending
        events[#events + 1] = PlayerTransition.Event("event_pending", pendingEventPayload(pending))
        return PlayerTransition.Finalize(inputState, working, now, "event_pending", events, false, false, true)
    end

    CombatEngine.BeginBattle(working, expected.eventType, rng, events)
    return PlayerTransition.Finalize(inputState, working, now, "battle_started", events, false, false, true)
end

local function applyEventOutcome(working, pending, action)
    local granted = { fragments = 0 }
    if action == "skip" then
        return granted
    end

    if pending.eventType == "chest" then
        QuestEngine.Track(working, "chest_open", 1, PlayerTransition.Now())
        local gold = Catalog.GetEventChestGold(pending.floor, pending.variant or 1)
        working.gold = LargeNumber.Add(working.gold, gold)
        granted.gold = gold
        granted.fragments = pending.fragmentsReward or 0
    elseif pending.eventType == "merchant" then
        granted.fragments = pending.fragmentsReward or 0
        granted.goldSpent = pending.goldCost
    else
        granted.fragments = pending.fragmentsReward or 0
    end

    if granted.fragments > 0 then
        working.fragments = LargeNumber.Add(
            working.fragments,
            LargeNumber.FromNumber(granted.fragments)
        )
    end
    return granted
end

-- 超时结算只允许 skip，绝不代替玩家花费金币。
function AdventureEngine.ResolveEvent(inputState, request, now, options)
    request = type(request) == "table" and request or {}
    options = type(options) == "table" and options or {}
    local working = PlayerTransition.Copy(inputState, now)
    local pending = working.pendingEvent
    if not pending then
        return PlayerTransition.NoCommit(inputState, now, "event_not_pending")
    end

    local timedOut = options.timeout == true
    local action = timedOut and "skip" or tostring(request.action or "")
    if not timedOut then
        if request.eventId ~= pending.eventId then
            return PlayerTransition.Failure(inputState, now, "STALE_EVENT", "事件已失效，请刷新")
        end
        if now > pending.expiresAt then
            action = "skip"
            timedOut = true
        else
            local allowed = false
            for _, candidate in ipairs(pending.actions or {}) do
                if candidate == action then
                    allowed = true
                    break
                end
            end
            if not allowed then
                return PlayerTransition.Failure(inputState, now, "INVALID_EVENT_ACTION", "该事件不支持此操作")
            end
        end
    end

    if action == "buy" then
        local cost = pending.goldCost or LargeNumber.Zero()
        if LargeNumber.Compare(working.gold, cost) < 0 then
            return PlayerTransition.Failure(inputState, now, "INSUFFICIENT_GOLD", "金币不足")
        end
        working.gold = LargeNumber.Subtract(working.gold, cost)
    end

    local granted = applyEventOutcome(working, pending, action)
    working.pendingEvent = nil
    working.currentEvent = nil

    local events = {
        PlayerTransition.Event("event_resolved", {
            eventId = pending.eventId,
            eventType = pending.eventType,
            action = action,
            timedOut = timedOut,
            floor = pending.floor,
            room = pending.room,
            fragments = granted.fragments,
            gold = granted.gold and LargeNumber.ToString(granted.gold) or nil,
        }),
    }
    print(string.format(
        "[Event] resolved id=%s type=%s action=%s timeout=%s",
        tostring(pending.eventId),
        tostring(pending.eventType),
        tostring(action),
        tostring(timedOut)
    ))
    return PlayerTransition.Finalize(inputState, working, now, "event_resolved", events, false, false, true)
end

function AdventureEngine.SetInteractionMode(inputState, mode, now)
    if mode ~= "normal" and mode ~= "cinematic" then
        return PlayerTransition.Failure(inputState, now, "INVALID_INTERACTION_MODE", "mode must be normal or cinematic")
    end
    local working = PlayerTransition.Copy(inputState, now)
    if working.interactionMode == mode then
        return PlayerTransition.NoCommit(inputState, now, "interaction_mode_unchanged")
    end
    working.interactionMode = mode
    return PlayerTransition.Finalize(inputState, working, now, "interaction_mode_changed", {
        PlayerTransition.Event("interaction_mode_changed", { mode = mode }),
    }, false, false)
end

function AdventureEngine.SetAutomationPolicy(inputState, policy, now)
    if type(policy) ~= "table"
        or type(policy.autoEquip) ~= "boolean"
        or type(policy.lootAutoEquip) ~= "boolean"
        or type(policy.autoSkipStory) ~= "boolean"
    then
        return PlayerTransition.Failure(inputState, now, "INVALID_AUTOMATION_POLICY",
            "autoEquip, lootAutoEquip and autoSkipStory must be booleans")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local nextPolicy = {
        autoEquip = policy.lootAutoEquip,
        lootAutoEquip = policy.lootAutoEquip,
        autoSkipStory = policy.autoSkipStory,
    }
    if TableUtils.DeepEqual(working.automationPolicy, nextPolicy) then
        return PlayerTransition.NoCommit(inputState, now, "automation_policy_unchanged")
    end
    working.automationPolicy = nextPolicy
    return PlayerTransition.Finalize(inputState, working, now, "automation_policy_changed", {
        PlayerTransition.Event("automation_policy_changed", { policy = TableUtils.DeepCopy(nextPolicy) }),
    }, false, false)
end

local function completeStoryGate(working, gate, skipped, events)
    working.storyProgress = type(working.storyProgress) == "table" and working.storyProgress or {
        introCompleted = false,
        highestCompletedChapter = 0,
        contentVersion = StoryCatalog.VERSION,
    }
    working.ruleAcknowledgements = type(working.ruleAcknowledgements) == "table"
        and working.ruleAcknowledgements or {}
    if gate.phase == "prologue" then
        working.storyProgress.introCompleted = true
    else
        local marker = string.format("story:%d:%s", gate.chapter or 0, gate.phase or "opening")
        working.ruleAcknowledgements[marker] = true
        if gate.phase == "memory" then
            working.storyProgress.highestCompletedChapter = math.max(
                working.storyProgress.highestCompletedChapter or 0,
                gate.chapter or 0
            )
        end
    end
    working.pendingStoryGate = nil
    if working.pauseReason == "story_gate" then working.pauseReason = nil end
    events[#events + 1] = PlayerTransition.Event(skipped and "story_skipped" or "story_completed", {
        storyId = gate.storyId,
        chapter = gate.chapter,
        phase = gate.phase,
    })
end

function AdventureEngine.AdvanceStory(inputState, action, now)
    if type(action) == "string" then action = { action = action } end
    if type(action) ~= "table" then
        return PlayerTransition.Failure(inputState, now, "INVALID_STORY_ACTION", "story action is required")
    end
    local actionId = action.action
    if actionId ~= "next" and actionId ~= "skip" and actionId ~= "complete" then
        return PlayerTransition.Failure(inputState, now, "INVALID_STORY_ACTION", "action must be next, skip, or complete")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local gate = working.pendingStoryGate
    if type(gate) ~= "table" then
        return PlayerTransition.Failure(inputState, now, "NO_STORY_GATE", "there is no pending story")
    end
    if action.storyId and action.storyId ~= gate.storyId then
        return PlayerTransition.Failure(inputState, now, "STALE_STORY_GATE", "pending story has changed")
    end
    local currentLineIndex = gate.lineIndex or 1
    if actionId ~= "skip" then
        local expectedLineIndex = actionId == "next" and currentLineIndex + 1 or currentLineIndex
        if action.lineIndex ~= expectedLineIndex then
            return PlayerTransition.Failure(inputState, now, "STALE_STORY_GATE", "pending story line has changed")
        end
    end
    local events = {}
    if actionId == "next" and currentLineIndex < #gate.lines then
        gate.lineIndex = currentLineIndex + 1
        working.pendingStoryGate = gate
        events[#events + 1] = PlayerTransition.Event("story_advanced", {
            storyId = gate.storyId,
            chapter = gate.chapter,
            phase = gate.phase,
            lineIndex = gate.lineIndex,
            line = gate.lines[gate.lineIndex],
        })
    else
        completeStoryGate(working, gate, actionId == "skip", events)
    end
    return PlayerTransition.Finalize(inputState, working, now, "story_advanced", events, false, false)
end

function AdventureEngine.AcknowledgeRules(inputState, ruleId, now)
    if type(ruleId) ~= "string" or #ruleId < 1 or #ruleId > 96
        or ruleId:match("^[%w%._:%-]+$") == nil
    then
        return PlayerTransition.Failure(inputState, now, "INVALID_RULE_ID", "ruleId is invalid")
    end
    ruleId = StoryCatalog.NormalizeRuleId(ruleId)
    if not StoryCatalog.IsKnownRuleId(ruleId) then
        return PlayerTransition.Failure(inputState, now, "UNKNOWN_RULE_ID", "ruleId is not registered")
    end
    local working = PlayerTransition.Copy(inputState, now)
    working.ruleAcknowledgements = type(working.ruleAcknowledgements) == "table"
        and working.ruleAcknowledgements or {}
    if working.ruleAcknowledgements[ruleId] == true then
        return PlayerTransition.NoCommit(inputState, now, "rules_already_acknowledged")
    end
    working.ruleAcknowledgements[ruleId] = true
    return PlayerTransition.Finalize(inputState, working, now, "rules_acknowledged", {
        PlayerTransition.Event("rules_acknowledged", { ruleId = ruleId }),
    }, false, false)
end

AdventureEngine.StoryGateEvent = storyGateEvent
AdventureEngine.QueueStoryGate = maybeQueueStoryGate

return AdventureEngine
