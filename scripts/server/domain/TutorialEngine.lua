-- TutorialEngine.lua
-- 新手剧情引导：服务端权威的步骤状态机。
-- 步骤：
--   step 1 = 首杀（保底掉落 1 白装武器 + 1 白装防具）→ 引导穿戴
--   step 2 = 穿戴成功 → 引导分解
--   step 3 = 分解成功 → 引导强化
--   step 4 = 强化成功 → 功能介绍（纯告知，无需操作）
--   step 5 = 客户端看完介绍后调用 Complete → 完成（发保底奖励）
-- 每次登录由 PlayerProfileService 重置（测试期每次进入都触发；正式版改终身一次）。
-- 各引擎结算点调用钩子（state 均为 working 副本），钩子只追加事件，不破坏原逻辑。

local PlayerTransition = require("server.domain.PlayerTransition")
local Catalog = require("server.domain.Catalog")

local TutorialEngine = {}

--- 强制腾出背包空位：优先分解未锁定未穿戴装备，保证新手保底掉落能进入 inventory。
--- 老号背包已满时否则会进临时箱/被自动处理，序章穿戴与分解会找不到目标。
local function ForceFreeInventorySlots(state, events, needSlots)
    needSlots = math.max(0, tonumber(needSlots) or 0)
    if needSlots <= 0 then return end
    state.inventory = state.inventory or {}
    local equipped = PlayerTransition.EquippedIdSet(state)

    local function freeCount()
        return select(1, Catalog.GetInventoryFreeSlots(state))
    end

    local function disposeAt(index, reason)
        local removed = table.remove(state.inventory, index)
        if not removed then return end
        local refund = Catalog.GetDecomposeRefund(removed, state.vipLevel)
        PlayerTransition.AddCurrency(state, "gold", refund.gold)
        PlayerTransition.AddCurrency(state, "fragments", refund.fragments)
        events[#events + 1] = PlayerTransition.Event("equipment_auto_disposed", {
            itemId = removed.id,
            equipmentId = removed.equipmentId,
            mode = "decompose",
            gold = refund.gold,
            fragments = refund.fragments,
            incoming = false,
            reason = reason or "tutorial_make_room",
        })
    end

    local function tryPass(preferUnlocked)
        local index = 1
        while freeCount() < needSlots and index <= #state.inventory do
            local item = state.inventory[index]
            if equipped[item.id]
                or item.source == "tutorial_drop"
                or (preferUnlocked and (item.locked or item.aidLocked))
            then
                index = index + 1
            else
                disposeAt(index, "tutorial_make_room")
            end
        end
    end

    -- 先腾未锁定，再必要时腾锁定未穿戴（老号满包兜底）。
    tryPass(true)
    tryPass(false)
end

-- 完成奖励：金币 + 碎片 + 全随机罐（直接入背包）
local TUTORIAL_COMPLETE_GOLD = 5000
local TUTORIAL_COMPLETE_FRAGMENTS = 50
local TUTORIAL_COMPLETE_JARS = 2

local function startTutorialState()
    return { step = 1, completed = false }
end

local function stepEvent(step, payload)
    payload = payload or {}
    payload.step = step
    payload.completed = false
    return PlayerTransition.Event("tutorial_step", payload)
end

--- 每次登录重置教程（测试期每次进入都触发）。
function TutorialEngine.Reset(state, now)
    state.tutorial = startTutorialState()
    -- 测试期每次登录重置教程时，同步回到第 1 层，避免老号高楼层开局。
    TutorialEngine.EnsureTutorialFloor(state, nil)
end

--- 当前是否处于教程中。
function TutorialEngine.IsActive(state)
    local tutorial = type(state) == "table" and state.tutorial
    return tutorial ~= nil and tutorial.completed ~= true
end

--- 当前教程步骤（1~5，完成返回 "completed"）。
function TutorialEngine.CurrentStep(state)
    local tutorial = type(state) == "table" and state.tutorial
    if not tutorial then return nil end
    if tutorial.completed then return "completed" end
    return tutorial.step or 1
end

local function tutorialStep(state)
    local step = TutorialEngine.CurrentStep(state)
    return type(step) == "number" and step or 0
end

--- 序章战斗强制第 1 层：老号高楼层直接开打会打不过。
--- 返回 true 表示发生了楼层重置。
function TutorialEngine.EnsureTutorialFloor(state, events)
    if not TutorialEngine.IsActive(state) then return false end
    local step = tutorialStep(state)
    -- 仅首杀教学(step1) 强制第 1 层；功能介绍(step5) 不再要求登塔。
    if step ~= 1 then return false end
    local changed = false
    if (state.floor or 1) ~= 1 then
        state.floor = 1
        changed = true
    end
    if (state.position or 0) ~= 0 then
        state.position = 0
        changed = true
    end
    if state.currentMonster ~= nil then
        state.currentMonster = nil
        changed = true
    end
    if state.pendingEvent ~= nil then
        state.pendingEvent = nil
        changed = true
    end
    if state.aidPending then
        state.aidPending = false
        changed = true
    end
    if state.pauseReason ~= nil and state.pauseReason ~= "" then
        -- 不保留旧层的暂停原因，避免教学挂机被旧状态拦住。
        state.pauseReason = nil
        changed = true
    end
    if changed then
        -- 回到第 1 层第 1 格，刷新派生战况。
        PlayerTransition.RefreshDerived(state)
        if events then
            events[#events + 1] = PlayerTransition.Event("tutorial_floor_reset", {
                floor = 1,
                position = 0,
                step = step,
            })
        end
    end
    return changed
end

--- 首杀：保底掉落白装武器 + 白装防具（引导穿戴/分解用）。
--- 教学战斗为「演示一击即止」：击杀后自动停止挂机，避免剧情阶段一直挂机。
function TutorialEngine.OnKill(state, events, now, rng)
    local tutorial = state.tutorial
    if not tutorial or tutorial.completed or (tutorial.step or 1) ~= 1 then return end
    TutorialEngine.EnsureTutorialFloor(state, events)
    -- 延迟 require 避免模块循环（RewardEngine -> EquipmentEngine -> TutorialEngine）
    local RewardEngine = require("server.domain.RewardEngine")
    -- 老号/满包：先强制腾 2 格，确保武器+护具真正进入背包而不是临时箱。
    ForceFreeInventorySlots(state, events, 2)
    local dropEvents = {}
    RewardEngine.AddGeneratedDrop(state, "common", false, rng, now, "tutorial_drop", dropEvents, {
        slot = "weapon",
        floor = 1,
        requireInventory = true,
        trackInLootStash = false,
    })
    RewardEngine.AddGeneratedDrop(state, "common", false, rng, now, "tutorial_drop", dropEvents, {
        slot = "shoulder",
        floor = 1,
        requireInventory = true,
        trackInLootStash = false,
    })
    for _, event in ipairs(dropEvents) do
        events[#events + 1] = event
    end
    tutorial.step = 2
    -- 演示战斗结束：停止自动挂机，教学不再持续战斗
    state.autoRun = false
    -- 清掉满包暂停标记，避免教学阶段被 inventory_full 卡住。
    if state.pauseReason == "inventory_full" then
        state.pauseReason = nil
    end
    events[#events + 1] = stepEvent(2, { message = "首杀掉落" })
end

--- 是否需要清理老号装备后再继续序章教学。
--- 已有穿戴、超过 2 件装备、临时箱有货、或已推进过层数时视为老号脏数据。
function TutorialEngine.NeedsLoadoutReset(state)
    if not TutorialEngine.IsActive(state) then return false end
    -- 仅第二步穿戴教学前需要清档；进入 step>=3 后玩家必然有穿戴，不能再判脏。
    if (state.tutorial.step or 1) ~= 2 then return false end
    if #(state.overflowLoot or {}) > 0 then return true end
    local equippedCount = 0
    for _, itemId in pairs((state and state.equipped) or {}) do
        if itemId then equippedCount = equippedCount + 1 end
    end
    local equipmentCount = 0
    local hasTutorialWeapon = false
    local hasTutorialArmor = false
    for _, item in ipairs(state.inventory or {}) do
        if item and item.equipmentId then
            equipmentCount = equipmentCount + 1
            if item.source == "tutorial_drop" and item.slot == "weapon" then
                hasTutorialWeapon = true
            end
            if item.source == "tutorial_drop" and item.slot ~= "weapon" then
                hasTutorialArmor = true
            end
        end
    end
    if equippedCount > 0 then return true end
    if equipmentCount > 2 then return true end
    if not hasTutorialWeapon or not hasTutorialArmor then return true end
    return false
end

--- 测试/老号兜底：清空全部装备数据，并按当前教程步骤补发教学装备。
function TutorialEngine.ResetLoadoutForTutorial(state, events, now, rng)
    if not TutorialEngine.IsActive(state) then
        return false, "TUTORIAL_INACTIVE"
    end
    events = events or {}
    now = now or PlayerTransition.Now()
    rng = rng or math.random

    local removed = 0
    local kept = {}
    for _, item in ipairs(state.inventory or {}) do
        if item and item.equipmentId then
            removed = removed + 1
        else
            kept[#kept + 1] = item
        end
    end
    state.inventory = kept
    state.equipped = {}
    state.overflowLoot = {}
    state.lootStash = {}
    state.previousLoadout = nil
    state.pendingEquipDecision = nil
    if state.pauseReason == "inventory_full" then
        state.pauseReason = nil
    end

    local granted = 0
    local step = tutorialStep(state)
    if step >= 2 and step <= 5 then
        local RewardEngine = require("server.domain.RewardEngine")
        local dropEvents = {}
        local okWeapon, weapon = RewardEngine.AddGeneratedDrop(
            state, "common", false, rng, now, "tutorial_drop", dropEvents, {
                slot = "weapon",
                floor = 1,
                requireInventory = true,
                trackInLootStash = false,
            }
        )
        local okArmor, armor = RewardEngine.AddGeneratedDrop(
            state, "common", false, rng, now, "tutorial_drop", dropEvents, {
                slot = "shoulder",
                floor = 1,
                requireInventory = true,
                trackInLootStash = false,
            }
        )
        for _, event in ipairs(dropEvents) do
            events[#events + 1] = event
        end
        if okWeapon and weapon then granted = granted + 1 end
        if okArmor and armor then granted = granted + 1 end
    end

    PlayerTransition.RefreshDerived(state)
    events[#events + 1] = PlayerTransition.Event("tutorial_loadout_reset", {
        removed = removed,
        granted = granted,
        step = step,
    })
    return true, nil, {
        removed = removed,
        granted = granted,
        step = step,
    }
end

--- 穿戴成功。
function TutorialEngine.OnEquip(state, events, now)
    local tutorial = state.tutorial
    if not tutorial or tutorial.completed or (tutorial.step or 1) ~= 2 then return end
    tutorial.step = 3
    events[#events + 1] = stepEvent(3, { message = "穿戴完成" })
end

--- 分解成功。
function TutorialEngine.OnDecompose(state, events, now)
    local tutorial = state.tutorial
    if not tutorial or tutorial.completed or (tutorial.step or 1) ~= 3 then return end
    tutorial.step = 4
    events[#events + 1] = stepEvent(4, { message = "分解完成" })
end

--- 强化成功 → 进入功能介绍（step 5），不再要求通关演示。
function TutorialEngine.OnStrengthen(state, events, now)
    local tutorial = state.tutorial
    if not tutorial or tutorial.completed or (tutorial.step or 1) ~= 4 then return end
    tutorial.step = 5
    events[#events + 1] = stepEvent(5, { message = "强化完成，进入功能介绍" })
end

local function GrantCompleteRewards(state, events)
    PlayerTransition.AddCurrency(state, "gold", TUTORIAL_COMPLETE_GOLD)
    PlayerTransition.AddCurrency(state, "fragments", TUTORIAL_COMPLETE_FRAGMENTS)
    if type(state.wishPool) ~= "table" then state.wishPool = {} end
    if type(state.wishPool.jars) ~= "table" then state.wishPool.jars = {} end
    local WishPoolDefinitions = require("shared.WishPoolDefinitions")
    if WishPoolDefinitions.ResolveJar("jar.random") then
        WishPoolDefinitions.GrantJars(state, state.level <= 5 and "jar.random.lv5" or "jar.random", TUTORIAL_COMPLETE_JARS)
    end
    events[#events + 1] = PlayerTransition.Event("tutorial_completed", {
        gold = TUTORIAL_COMPLETE_GOLD,
        fragments = TUTORIAL_COMPLETE_FRAGMENTS,
        jars = TUTORIAL_COMPLETE_JARS,
    })
end

--- 客户端功能介绍看完后调用：标记完成并发放保底奖励。
function TutorialEngine.Complete(state, events, now)
    local tutorial = state.tutorial
    if not tutorial or tutorial.completed then
        return false, "TUTORIAL_ALREADY_COMPLETED"
    end
    if (tutorial.step or 1) < 5 then
        return false, "TUTORIAL_NOT_READY"
    end
    tutorial.completed = true
    tutorial.step = 6
    GrantCompleteRewards(state, events)
    return true
end

--- 兼容旧逻辑：若仍停在 step 5，通关一层也可收尾（不再作为主路径）。
function TutorialEngine.OnFloorClear(state, events, now)
    local tutorial = state.tutorial
    if not tutorial or tutorial.completed or (tutorial.step or 1) ~= 5 then return end
    tutorial.completed = true
    tutorial.step = 6
    GrantCompleteRewards(state, events)
end

return TutorialEngine
