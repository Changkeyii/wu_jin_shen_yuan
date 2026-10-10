local Progression = require("shared.GameProgression")
local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local PlayerTransition = require("server.domain.PlayerTransition")
local DomainMath = require("server.domain.DomainMath")
local InventoryState = require("server.domain.InventoryState")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local TowerRules = require("shared.TowerRules")
local RewardPolicy = require("shared.RewardPolicy")
local RarityCatalog = require("shared.RarityCatalog")
local PowerEvaluator = require("shared.PowerEvaluator")
local GameStateSchema = require("shared.GameStateSchema")
local QuestEngine = require("server.domain.QuestEngine")
local TutorialEngine = require("server.domain.TutorialEngine")

local EquipmentEngine = {}

local function bindEquipmentOnSuccessfulEquip(item)
    if item and item.tradeable == true then
        item.tradeable = false
        print("[EquipmentTrade] bound after equip itemId=" .. tostring(item.id))
        return true
    end
    return false
end

local function disposeEquipment(state, item, mode)
    if mode == "sell" then
        QuestEngine.Track(state, "sell", 1, PlayerTransition.Now())
        local gold = Catalog.GetSellValue(item, state.vipLevel)
        PlayerTransition.AddCurrency(state, "gold", gold)
        return { gold = gold, fragments = 0 }
    end
    QuestEngine.Track(state, "decompose", 1, PlayerTransition.Now())
    local refund = Catalog.GetDecomposeRefund(item, state.vipLevel)
    PlayerTransition.AddCurrency(state, "gold", refund.gold)
    PlayerTransition.AddCurrency(state, "fragments", refund.fragments)
    return refund
end

local function autoDispositionEnabled(state, item)
    local policy = state.inventoryPolicy or {}
    if item.rarity == "myth" or item.locked or item.aidLocked then return false end
    if policy.autoDecompose and policy.decomposeRarities and policy.decomposeRarities[item.rarity] == true then
        return "decompose"
    end
    if policy.autoSell and policy.sellRarities and policy.sellRarities[item.rarity] == true then
        return "sell"
    end
    return false
end

local function hasAutoDispositionPolicy(state)
    local policy = state.inventoryPolicy or {}
    for _, enabled in pairs(policy.decomposeRarities or {}) do
        if policy.autoDecompose and enabled then return true end
    end
    for _, enabled in pairs(policy.sellRarities or {}) do
        if policy.autoSell and enabled then return true end
    end
    return false
end

local function makeRoomForDrop(state, incoming, events, allowOverflow)
    if #state.inventory < Catalog.GetInventoryCapacity(state) then return true, false end
    local policy = state.inventoryPolicy or {}
    -- 新手保底掉落绝不可被自动分解/出售吞掉，否则序章后续穿戴/分解会卡死。
    local protectTutorialDrop = incoming and incoming.source == "tutorial_drop"
    local mode = (not protectTutorialDrop) and autoDispositionEnabled(state, incoming) or false
    local equipped = PlayerTransition.EquippedIdSet(state)
    local disposalIndex = nil
    if mode then
        local reward = disposeEquipment(state, incoming, mode)
        events[#events + 1] = PlayerTransition.Event("equipment_auto_disposed", {
            itemId = incoming.id,
            equipmentId = incoming.equipmentId,
            mode = mode,
            gold = reward.gold,
            fragments = reward.fragments,
            incoming = true,
        })
        return false, "consumed"
    end
    for index, item in ipairs(state.inventory) do
        if not item.locked
            and not item.aidLocked
            and not equipped[item.id]
            and item.source ~= "tutorial_drop"
            and autoDispositionEnabled(state, item)
        then
            disposalIndex = index
            break
        end
    end
    if not disposalIndex then
        if allowOverflow ~= false and #(state.overflowLoot or {}) < GameStateSchema.TEMPORARY_LOOT_CAP then
            state.overflowLoot = state.overflowLoot or {}
            state.overflowLoot[#state.overflowLoot + 1] = incoming
            state.autoRun = false
            state.pauseReason = "inventory_full"
            events[#events + 1] = PlayerTransition.Event("inventory_full", {
                itemId = incoming.id,
                equipmentId = incoming.equipmentId,
                capacity = Catalog.GetInventoryCapacity(state),
                temporaryLootCount = #state.overflowLoot,
            })
            return false, "overflow"
        end
        state.autoRun = false
        state.pauseReason = "inventory_full"
        return false, false
    end
    local removed = table.remove(state.inventory, disposalIndex)
    local mode = autoDispositionEnabled(state, removed)
    local reward = disposeEquipment(state, removed, mode)
    events[#events + 1] = PlayerTransition.Event("equipment_auto_disposed", {
        itemId = removed.id,
        equipmentId = removed.equipmentId,
        mode = mode,
        gold = reward.gold,
        fragments = reward.fragments,
        incoming = false,
    })
    return true, true
end

local function drainOverflowLoot(state, events)
    state.overflowLoot = state.overflowLoot or {}
    local moved = 0
    while #state.inventory < Catalog.GetInventoryCapacity(state) and #state.overflowLoot > 0 do
        local item = table.remove(state.overflowLoot, 1)
        state.inventory[#state.inventory + 1] = item
        InventoryState.AddToLootStash(state, item.id)
        moved = moved + 1
        events[#events + 1] = PlayerTransition.Event("loot_settled", {
            itemId = item.id,
            outcome = "inventory",
            fromTemporaryLoot = true,
        })
    end
    if #state.overflowLoot == 0 and state.pauseReason == "inventory_full" then
        state.pauseReason = nil
    end
    return moved
end

local function nextChapterFloor(floor)
    return (math.floor(math.max(1, floor) / 10) + 1) * 10
end

local function loadoutState(state, equipped)
    return {
        level = state.level,
        growth = state.growth,
        floor = state.floor,
        maxFloor = state.maxFloor,
        floorKillBonus = state.floorKillBonus,
        permanentBonus = state.permanentBonus,
        inventory = state.inventory,
        equipped = equipped,
    }
end

local function evaluateLoadout(state, equipped, includeDisplay)
    local stats = Catalog.CalculateStats(loadoutState(state, equipped), { skipPowerEvaluation = true })
    local chapterFloor = nextChapterFloor(state.floor)
    local score = PowerEvaluator.EvaluateAtFloor(stats, chapterFloor, { bossKind = "chapterBoss" })
    local display = includeDisplay and PowerEvaluator.Evaluate(stats, { floor = state.floor }) or nil
    return {
        stats = stats,
        score = score,
        display = display,
        chapterFloor = chapterFloor,
        setProgress = Catalog.GetSetProgress(loadoutState(state, equipped)),
    }
end

local function breaksActiveSetTier(beforeProgress, afterProgress)
    for setId, before in pairs(beforeProgress or {}) do
        local after = afterProgress and afterProgress[setId] or nil
        for _, tier in ipairs({ 3, 6, 9, 12 }) do
            local key = tostring(tier)
            if before.activeTiers and before.activeTiers[key]
                and not (after and after.activeTiers and after.activeTiers[key])
            then
                return true
            end
        end
    end
    return false
end

local function upgradePasses(before, after, minimumGain)
    local oldScore = tonumber(before.score.towerScore) or 0
    local newScore = tonumber(after.score.towerScore) or 0
    local required = oldScore > 0 and oldScore * (1 + (minimumGain or 0.02)) or 0
    return newScore >= required
        and (tonumber(after.score.bossScore) or 0) >= (tonumber(before.score.bossScore) or 0)
        and (tonumber(after.score.eliteScore) or 0)
            >= (tonumber(before.score.eliteScore) or 0)
                * RewardPolicy.AUTO_EQUIP_MINIMUM_ELITE_RETENTION
        and RewardPolicy.AutoEquipSurvivalMarginPasses(
            before.score.bossSurvivalMargin,
            after.score.bossSurvivalMargin)
        and not breaksActiveSetTier(before.setProgress, after.setProgress)
end

local function upgradePayload(item, before, after)
    local payload = {
        itemId = item.id,
        slot = item.slot,
        chapterFloor = after.chapterFloor,
        oldTowerScore = before.score.towerScore,
        newTowerScore = after.score.towerScore,
        oldBossScore = before.score.bossScore,
        newBossScore = after.score.bossScore,
        oldEliteScore = before.score.eliteScore,
        newEliteScore = after.score.eliteScore,
        oldBossDps = before.score.boss and before.score.boss.dpsSafe or 0,
        newBossDps = after.score.boss and after.score.boss.dpsSafe or 0,
        oldEffectiveHp = before.score.boss and before.score.boss.ehp or 0,
        newEffectiveHp = after.score.boss and after.score.boss.ehp or 0,
        headroomDelta = (after.display.equivalentFloor or 0) - (before.display.equivalentFloor or 0),
        estimatedFloorBefore = before.display.estimatedEasyFloor,
        estimatedFloorAfter = after.display.estimatedEasyFloor,
        setProgressBefore = before.setProgress,
        setProgressAfter = after.setProgress,
    }
    return DomainMath.AddMagnitudeFields(
        payload,
        "displayedPowerDelta",
        "displayedPowerDeltaBig",
        DomainMath.DisplayedPowerDelta(before.display, after.display))
end

local function considerEquipmentUpgrade(state, item, now, events)
    if not item or item.aidLocked or not Progression.CanEquip(state, item) or not PlayerTransition.FindItem(state, item.id) then return false, false end
    local current = PlayerTransition.FindItem(state, state.equipped[item.slot])
    if current and (current.locked or current.aidLocked) then return false, false end
    local before = evaluateLoadout(state, state.equipped, true)
    local candidateEquipped = TableUtils.DeepCopy(state.equipped)
    candidateEquipped[item.slot] = item.id
    local after = evaluateLoadout(state, candidateEquipped, true)
    if not upgradePasses(before, after, RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN) then return false, false end

    local payload = upgradePayload(item, before, after)
    local tradeabilityChanged = false
    -- 序章期间禁止“发现更强装备”决策弹窗：静默跳过，不打断强引导。
    if TutorialEngine.IsActive(state) then
        state.pendingEquipDecision = nil
        return false, false
    end
    if state.automationPolicy and state.automationPolicy.autoEquip then
        state.previousLoadout = {
            equipped = TableUtils.DeepCopy(state.equipped),
            createdAt = PlayerTransition.Now(now),
            available = true,
        }
        state.equipped = candidateEquipped
        tradeabilityChanged = bindEquipmentOnSuccessfulEquip(item)
        InventoryState.RemoveFromLootStash(state, item.id)
        state.pendingEquipDecision = nil
        PlayerTransition.RefreshDerived(state)
        payload.automatic = true
        events[#events + 1] = PlayerTransition.Event("equipment_equipped", payload)
        -- 自动穿戴同样推进序章，避免老号/自动装配后卡在 step 2。
        TutorialEngine.OnEquip(state, events, now)
    else
        state.pendingEquipDecision = {
            itemId = item.id,
            createdAt = PlayerTransition.Now(now),
            oldTowerScore = payload.oldTowerScore,
            newTowerScore = payload.newTowerScore,
            oldBossScore = payload.oldBossScore,
            newBossScore = payload.newBossScore,
            displayedPowerDelta = payload.displayedPowerDelta,
            displayedPowerDeltaBig = BigNumber.Clone(payload.displayedPowerDeltaBig),
            headroomDelta = payload.headroomDelta,
        }
        events[#events + 1] = PlayerTransition.Event("equipment_upgrade_available", payload)
    end
    return true, tradeabilityChanged
end

-- 一键穿戴 / 自动整装：
-- force=true（玩家点“一键穿戴”）：12 部位各自换成背包中战力最高的装备。
-- force=false（挂机策略）：保留原有评分门槛，避免无脑换装破坏套装/生存。
local function optimizeWholeLoadout(state, now, events, force)
    if not force and not (state.automationPolicy and state.automationPolicy.autoEquip) then
        return false, false
    end
    local originalEquipped = TableUtils.DeepCopy(state.equipped)
    local selected = TableUtils.DeepCopy(originalEquipped)
    local changedSlots = {}

    for _, slot in ipairs(Catalog.SLOTS) do
        local slotId = slot.id
        local current = PlayerTransition.FindItem(state, selected[slotId])
        local locked = current and (current.locked or current.aidLocked)
        if not locked then
            local best = current
            for _, candidate in ipairs(state.inventory or {}) do
                if candidate
                    and candidate.slot == slotId
                    and candidate.equipmentId
                    and not candidate.aidLocked
                    and Progression.CanEquip(state, candidate)
                then
                    if not best then
                        best = candidate
                    elseif Catalog.CompareItemPower(candidate, best) > 0 then
                        best = candidate
                    end
                end
            end

            if best and best.id and selected[slotId] ~= best.id then
                local accept = true
                if not force then
                    -- 非强制路径仍做整装评分保护，避免挂机把生存/套装弄坏。
                    local before = evaluateLoadout(state, selected)
                    local proposal = TableUtils.DeepCopy(selected)
                    proposal[slotId] = best.id
                    local after = evaluateLoadout(state, proposal)
                    accept = upgradePasses(before, after, 0)
                        and (tonumber(after.score.towerScore) or 0)
                            > (tonumber(before.score.towerScore) or 0)
                    if accept then
                        selected = proposal
                    end
                else
                    selected[slotId] = best.id
                end
                if accept then
                    changedSlots[#changedSlots + 1] = slotId
                end
            end
        end
    end

    if #changedSlots == 0 or TableUtils.DeepEqual(selected, originalEquipped) then
        return false, false
    end

    -- 挂机自动整装仍要求整体达到最小收益；手动一键穿戴只要有部位提升就提交。
    if not force then
        local original = evaluateLoadout(state, originalEquipped)
        local optimized = evaluateLoadout(state, selected)
        if not upgradePasses(original, optimized, RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN) then
            return false, false
        end
    end

    state.previousLoadout = {
        equipped = originalEquipped,
        createdAt = PlayerTransition.Now(now),
        available = true,
    }
    state.equipped = selected
    local tradeabilityChanged = false
    for slotId, itemId in pairs(selected) do
        if originalEquipped[slotId] ~= itemId then
            tradeabilityChanged = bindEquipmentOnSuccessfulEquip(PlayerTransition.FindItem(state, itemId))
                or tradeabilityChanged
        end
        InventoryState.RemoveFromLootStash(state, itemId)
    end
    state.pendingEquipDecision = nil
    local original = evaluateLoadout(state, originalEquipped, true)
    local optimized = evaluateLoadout(state, selected, true)
    PlayerTransition.RefreshDerived(state)
    local equippedPayload = {
        automatic = true,
        batch = true,
        force = force == true,
        changedSlots = changedSlots,
        changedCount = #changedSlots,
        oldTowerScore = original.score.towerScore,
        newTowerScore = optimized.score.towerScore,
        oldBossScore = original.score.bossScore,
        newBossScore = optimized.score.bossScore,
        headroomDelta = (optimized.display and optimized.display.equivalentFloor or 0)
            - (original.display and original.display.equivalentFloor or 0),
    }
    DomainMath.AddMagnitudeFields(
        equippedPayload,
        "displayedPowerDelta",
        "displayedPowerDeltaBig",
        DomainMath.DisplayedPowerDelta(original.display, optimized.display))
    events[#events + 1] = PlayerTransition.Event("equipment_equipped", equippedPayload)
    events[#events + 1] = PlayerTransition.Event("auto_equip", {
        evaluatedBy = force and "ItemPower" or "PowerEvaluator",
        changedCount = #changedSlots,
        force = force == true,
    })
    return true, tradeabilityChanged
end

function EquipmentEngine.Equip(inputState, itemId, now)
    local working = PlayerTransition.Copy(inputState, now)
    local item = PlayerTransition.FindItem(working, itemId)
    if not item then
        return PlayerTransition.Failure(inputState, now, "ITEM_NOT_FOUND", "equipment item was not found")
    end
    if not Catalog.SLOT_BY_ID[item.slot] then
        return PlayerTransition.Failure(inputState, now, "INVALID_ITEM", "item has no valid equipment slot")
    end
    if not Progression.CanEquip(working, item) then
        return PlayerTransition.Failure(inputState, now, "EQUIPMENT_LEVEL_REQUIRED",
            string.format("人物达到%d级后可穿戴，装备已保留", Progression.RequiredEquipmentLevel(item)))
    end
    if working.equipped[item.slot] == item.id then
        -- 已穿戴时仍推进序章，并回传 equipment_equipped，避免客户端卡在“穿戴成功请稍候”。
        local events = {
            PlayerTransition.Event("equipment_equipped", {
                itemId = item.id,
                slot = item.slot,
                alreadyEquipped = true,
            }),
        }
        TutorialEngine.OnEquip(working, events, now)
        if #events > 1 or (working.tutorial and working.tutorial.step == 3) then
            return PlayerTransition.Finalize(
                inputState, working, now, "equipment_changed", events, false, false
            )
        end
        return PlayerTransition.NoCommit(inputState, now, "already_equipped", events)
    end
    working.equipped[item.slot] = item.id
    local tradeabilityChanged = bindEquipmentOnSuccessfulEquip(item)
    InventoryState.RemoveFromLootStash(working, item.id)
    PlayerTransition.RefreshDerived(working)
    local events = {
        PlayerTransition.Event("equipment_equipped", { itemId = item.id, slot = item.slot }),
    }
    -- 新手剧情：穿戴完成
    TutorialEngine.OnEquip(working, events, now)
    return PlayerTransition.Finalize(inputState, working, now, "equipment_changed", events, tradeabilityChanged, true)
end

EquipmentEngine.EquipItem = EquipmentEngine.Equip

function EquipmentEngine.Unequip(inputState, slotId, now)
    if not Catalog.SLOT_BY_ID[slotId] then
        return PlayerTransition.Failure(inputState, now, "INVALID_SLOT", "unknown equipment slot")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local item = PlayerTransition.FindItem(working, working.equipped[slotId])
    if not item then
        return PlayerTransition.NoCommit(inputState, now, "already_unequipped")
    end
    working.equipped[slotId] = nil
    PlayerTransition.RefreshDerived(working)
    return PlayerTransition.Finalize(inputState, working, now, "equipment_changed", {
        PlayerTransition.Event("equipment_unequipped", { itemId = item.id, slot = slotId }),
    }, false, true)
end

EquipmentEngine.UnequipItem = EquipmentEngine.Unequip

function EquipmentEngine.AutoEquip(inputState, now)
    local working = PlayerTransition.Copy(inputState, now)
    local events = {}
    -- 玩家主动一键穿戴：强制按 12 部位最高战力替换。
    local changed, tradeabilityChanged = optimizeWholeLoadout(working, now, events, true)
    if not changed then
        return PlayerTransition.NoCommit(inputState, now, "auto_equip_unchanged")
    end
    return PlayerTransition.Finalize(inputState, working, now, "auto_equip", events, tradeabilityChanged, true)
end

EquipmentEngine.AutoEquipBest = EquipmentEngine.AutoEquip

function EquipmentEngine.GetSellPreview(inputState, itemId)
    local item = PlayerTransition.FindItem(inputState, itemId)
    if not item then
        return {
            ok = false,
            code = "ITEM_NOT_FOUND",
            reason = "equipment item was not found",
        }
    end
    local equipped = PlayerTransition.EquippedIdSet(inputState)
    if equipped[item.id] or item.locked or item.aidLocked then
        return {
            ok = false,
            code = "ITEM_NOT_TRADABLE",
            reason = "equipment item is protected",
        }
    end
    local rarity = Catalog.RARITIES[item.rarity]
    if not rarity or rarity.rank >= #Catalog.RARITY_ORDER then
        return {
            ok = false,
            code = "INVALID_ARGUMENT",
            reason = "myth equipment cannot be sold",
        }
    end
    return {
        ok = true,
        data = {
            itemId = item.id,
            gold = Catalog.GetSellValue(item, inputState.vipLevel),
        },
    }
end

function EquipmentEngine.GetDecomposePreview(inputState, itemId)
    local item = PlayerTransition.FindItem(inputState, itemId)
    if not item then
        return {
            ok = false,
            code = "ITEM_NOT_FOUND",
            reason = "equipment item was not found",
        }
    end
    local refund = Catalog.GetDecomposeRefund(item, inputState.vipLevel)
    return {
        ok = true,
        data = {
            itemId = item.id,
            gold = refund.gold,
            fragments = refund.fragments,
            rate = refund.rate,
            vipLevel = inputState.vipLevel or 0,
        },
    }
end

function EquipmentEngine.Decompose(inputState, maximumRank, now, candidateIds)
    maximumRank = TableUtils.ToInteger(maximumRank, -1)
    if maximumRank < 1 or maximumRank >= #Catalog.RARITY_ORDER then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "maximumRank must exclude myth equipment")
    end

    local working = PlayerTransition.Copy(inputState, now)
    local equipped = PlayerTransition.EquippedIdSet(working)
    local selected = nil
    if type(candidateIds) == "table" then
        selected = {}
        for _, itemId in ipairs(candidateIds) do
            selected[itemId] = true
        end
    end
    local kept = {}
    local removed = 0
    local fragments = 0
    local adBaseFragments = 0
    local gold = LargeNumber.Zero()
    for _, item in ipairs(working.inventory) do
        local rarity = Catalog.RARITIES[item.rarity]
        local explicitlySelected = selected == nil or selected[item.id] == true
        if explicitlySelected and rarity and rarity.rank <= maximumRank
            and not equipped[item.id] and not item.locked and not item.aidLocked then
            removed = removed + 1
            local refund = Catalog.GetDecomposeRefund(item, working.vipLevel)
            adBaseFragments = adBaseFragments + Catalog.GetEquipmentBaseRecoveryValue(item).fragments
            fragments = fragments + refund.fragments
            gold = LargeNumber.Add(gold, refund.gold)
            PlayerTransition.AddCurrency(working, "gold", refund.gold)
        else
            kept[#kept + 1] = item
        end
    end
    if removed == 0 then
        return PlayerTransition.NoCommit(inputState, now, "decompose_empty")
    end
    QuestEngine.Track(working, "decompose", removed, now)
    working.inventory = kept
    InventoryState.PruneLootStash(working)
    PlayerTransition.AddCurrency(working, "fragments", fragments)
    local events = {
        PlayerTransition.Event("equipment_decomposed", { count = removed, fragments = fragments, gold = gold }),
    }
    local recovered = drainOverflowLoot(working, events)
    PlayerTransition.RefreshDerived(working)
    if recovered > 0 then events[#events + 1] = PlayerTransition.Event("temporary_loot_recovered", { count = recovered }) end
    -- 新手剧情：分解完成
    TutorialEngine.OnDecompose(working, events, now)
    require("server.domain.AdGiftEngine").OnDecompose(working, adBaseFragments, events)
    return PlayerTransition.Finalize(inputState, working, now, "equipment_decomposed", events, true, false)
end

EquipmentEngine.DecomposeByRank = EquipmentEngine.Decompose

function EquipmentEngine.Sell(inputState, maximumRank, now, candidateIds)
    maximumRank = TableUtils.ToInteger(maximumRank, -1)
    if maximumRank < 1 or maximumRank >= #Catalog.RARITY_ORDER then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "maximumRank must exclude myth equipment")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local equipped = PlayerTransition.EquippedIdSet(working)
    local selected = nil
    if type(candidateIds) == "table" then
        selected = {}
        for _, itemId in ipairs(candidateIds) do selected[itemId] = true end
    end
    local kept = {}
    local removed = 0
    local gold = LargeNumber.Zero()
    for _, item in ipairs(working.inventory) do
        local rarity = Catalog.RARITIES[item.rarity]
        local explicitlySelected = selected == nil or selected[item.id] == true
        if explicitlySelected and rarity and rarity.rank <= maximumRank
            and not equipped[item.id] and not item.locked and not item.aidLocked
        then
            removed = removed + 1
            local value = Catalog.GetSellValue(item, working.vipLevel)
            gold = LargeNumber.Add(gold, value)
        else
            kept[#kept + 1] = item
        end
    end
    if removed == 0 then return PlayerTransition.NoCommit(inputState, now, "sell_empty") end
    QuestEngine.Track(working, "sell", removed, now)
    working.inventory = kept
    InventoryState.PruneLootStash(working)
    PlayerTransition.AddCurrency(working, "gold", gold)
    local events = { PlayerTransition.Event("equipment_sold", { count = removed, gold = gold }) }
    local recovered = drainOverflowLoot(working, events)
    PlayerTransition.RefreshDerived(working)
    if recovered > 0 then events[#events + 1] = PlayerTransition.Event("temporary_loot_recovered", { count = recovered }) end
    return PlayerTransition.Finalize(inputState, working, now, "equipment_sold", events, true, false)
end

EquipmentEngine.SellByRank = EquipmentEngine.Sell

function EquipmentEngine.WeakestEquipmentSlots(state)
    local growth = TowerRules.Growth(state.floor)
    local ranked = {}
    for _, slot in ipairs(Catalog.SLOTS) do
        local item = PlayerTransition.FindItem(state, state.equipped[slot.id])
        local score = -1
        if item then
            local stats = Catalog.GetItemEffectiveStats(item)
            score = (BigNumber.Ratio(stats.atkBig, BigNumber.MultiplyScalar(growth, 90)) or 0)
                + (BigNumber.Ratio(stats.defBig, BigNumber.MultiplyScalar(growth, 85)) or 0)
                + (BigNumber.Ratio(stats.hpBig, BigNumber.MultiplyScalar(growth, 2200)) or 0)
        end
        ranked[#ranked + 1] = { slot = slot.id, score = score }
    end
    table.sort(ranked, function(left, right)
        if left.score == right.score then return left.slot < right.slot end
        return left.score < right.score
    end)
    return ranked
end

function EquipmentEngine.SetEquipmentLock(inputState, itemId, locked, now)
    if type(locked) ~= "boolean" then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "locked must be a boolean")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local item = PlayerTransition.FindItem(working, itemId)
    if not item then return PlayerTransition.Failure(inputState, now, "ITEM_NOT_FOUND", "equipment item was not found") end
    if item.locked == locked then return PlayerTransition.NoCommit(inputState, now, "equipment_lock_unchanged") end
    item.locked = locked
    return PlayerTransition.Finalize(inputState, working, now, "equipment_lock_changed", {
        PlayerTransition.Event("equipment_lock_changed", { itemId = item.id, locked = locked }),
    }, true, false)
end

function EquipmentEngine.SetInventoryPolicy(inputState, policy, now)
    if type(policy) ~= "table" then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "inventory policy is required")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local function copyRarities(source)
        local values = {}
        for _, rarityId in ipairs(Catalog.RARITY_ORDER) do
            values[rarityId] = rarityId ~= "myth"
                and type(source) == "table"
                and source[rarityId] == true
        end
        return values
    end
    local decomposeRarities = copyRarities(policy.decomposeRarities)
    local sellRarities = copyRarities(policy.sellRarities)
    for _, rarityId in ipairs(Catalog.RARITY_ORDER) do
        if decomposeRarities[rarityId] then sellRarities[rarityId] = false end
    end
    local autoDecompose = policy.autoDecompose == true
    local autoSell = policy.autoSell == true and not autoDecompose
    working.inventoryPolicy = {
        pauseOnFull = policy.pauseOnFull == true,
        autoDecompose = autoDecompose,
        autoSell = autoSell,
        decomposeRarities = decomposeRarities,
        sellRarities = sellRarities,
    }
    if not working.inventoryPolicy.pauseOnFull or hasAutoDispositionPolicy(working) then
        if working.pauseReason == "inventory_full" then working.pauseReason = nil end
    end
    return PlayerTransition.Finalize(inputState, working, now, "inventory_policy_changed", {
        PlayerTransition.Event("inventory_policy_changed", { inventoryPolicy = TableUtils.DeepCopy(working.inventoryPolicy) }),
    }, false, false)
end

function EquipmentEngine.DecideEquip(inputState, decision, now)
    if type(decision) ~= "table" or (decision.action ~= "equip" and decision.action ~= "keep") then
        return PlayerTransition.Failure(inputState, now, "INVALID_EQUIP_DECISION", "action must be equip or keep")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local pending = working.pendingEquipDecision
    if type(pending) ~= "table" then
        return PlayerTransition.Failure(inputState, now, "NO_EQUIP_DECISION", "there is no pending equipment decision")
    end
    if decision.itemId and decision.itemId ~= pending.itemId then
        return PlayerTransition.Failure(inputState, now, "STALE_EQUIP_DECISION", "pending equipment item has changed")
    end
    local events = {}
    local equippedChanged = false
    local tradeabilityChanged = false
    if decision.action == "equip" then
        local item = PlayerTransition.FindItem(working, pending.itemId)
        if not item then
            return PlayerTransition.Failure(inputState, now, "ITEM_NOT_FOUND", "pending equipment item was not found")
        end
        if not Progression.CanEquip(working, item) then
            return PlayerTransition.Failure(inputState, now, "EQUIPMENT_LEVEL_REQUIRED", "人物等级不足，装备已保留")
        end
        local current = PlayerTransition.FindItem(working, working.equipped[item.slot])
        if current and (current.locked or current.aidLocked) then
            return PlayerTransition.Failure(inputState, now, "EQUIPMENT_LOCKED", "the equipped item cannot be replaced")
        end
        local before = evaluateLoadout(working, working.equipped, true)
        local candidateEquipped = TableUtils.DeepCopy(working.equipped)
        candidateEquipped[item.slot] = item.id
        local after = evaluateLoadout(working, candidateEquipped, true)
        if not upgradePasses(before, after, RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN) then
            working.pendingEquipDecision = nil
            return PlayerTransition.Finalize(inputState, working, now, "equip_decision_stale", {
                PlayerTransition.Event("equip_decision_applied", { action = "keep", itemId = item.id, stale = true }),
            }, false, false)
        end
        working.previousLoadout = {
            equipped = TableUtils.DeepCopy(working.equipped),
            createdAt = PlayerTransition.Now(now),
            available = true,
        }
        working.equipped = candidateEquipped
        tradeabilityChanged = bindEquipmentOnSuccessfulEquip(item)
        InventoryState.RemoveFromLootStash(working, item.id)
        PlayerTransition.RefreshDerived(working)
        equippedChanged = true
        local appliedPayload = {
            action = "equip",
            itemId = item.id,
            slot = item.slot,
            headroomDelta = (after.display.equivalentFloor or 0)
                - (before.display.equivalentFloor or 0),
        }
        DomainMath.AddMagnitudeFields(
            appliedPayload,
            "displayedPower",
            "displayedPowerBig",
            DomainMath.Magnitude(working.stats.displayedPower, working.stats.power, 0))
        DomainMath.AddMagnitudeFields(
            appliedPayload,
            "displayedPowerDelta",
            "displayedPowerDeltaBig",
            DomainMath.DisplayedPowerDelta(before.display, after.display))
        events[#events + 1] = PlayerTransition.Event("equip_decision_applied", appliedPayload)
    else
        events[#events + 1] = PlayerTransition.Event("equip_decision_applied", {
            action = "keep",
            itemId = pending.itemId,
        })
    end
    working.pendingEquipDecision = nil
    return PlayerTransition.Finalize(inputState, working, now, "equip_decided", events,
        tradeabilityChanged, equippedChanged)
end

function EquipmentEngine.UndoEquip(inputState, now)
    local working = PlayerTransition.Copy(inputState, now)
    local backup = working.previousLoadout
    if type(backup) ~= "table" or backup.available ~= true or type(backup.equipped) ~= "table" then
        return PlayerTransition.Failure(inputState, now, "NO_EQUIP_UNDO", "there is no equipment change to undo")
    end
    local restored = {}
    for slotId, itemId in pairs(backup.equipped) do
        local item = PlayerTransition.FindItem(working, itemId)
        if item and item.slot == slotId and Progression.CanEquip(working, item) then restored[slotId] = itemId end
    end
    working.equipped = restored
    backup.available = false
    working.previousLoadout = backup
    PlayerTransition.RefreshDerived(working)
    local revertedPayload = {}
    DomainMath.AddMagnitudeFields(
        revertedPayload,
        "displayedPower",
        "displayedPowerBig",
        DomainMath.Magnitude(working.stats.displayedPower, working.stats.power, 0))
    return PlayerTransition.Finalize(inputState, working, now, "equipment_reverted", {
        PlayerTransition.Event("equipment_reverted", revertedPayload),
    }, false, true)
end

local function StrengthenCost(state, item, enhance)
    -- 教学护具仅返还 5 碎片，普通首次强化需要 8；教学武器的 +0 -> +1 由塔灵承担。
    -- 预览与执行共用规则，兼容已停在 step 4 的存档；成功后步骤原子推进，不可重复领取。
    if TutorialEngine.CurrentStep(state) == 4
        and item.source == "tutorial_drop"
        and item.slot == "weapon"
        and item.rarity == "common"
        and item.level == 5
        and enhance == 0
    then
        return { gold = LargeNumber.Zero(), fragments = 0, tutorialFree = true }
    end
    return Catalog.GetStrengthenCost(item, enhance)
end

function EquipmentEngine.GetStrengthenPreview(inputState, slotId)
    if not Catalog.SLOT_BY_ID[slotId] then
        return PlayerTransition.Failure(inputState, os.time(), "INVALID_SLOT", "unknown equipment slot")
    end
    local working = PlayerTransition.Copy(inputState, os.time())
    local item = PlayerTransition.FindItem(working, working.equipped[slotId])
    if not item then
        return PlayerTransition.Failure(inputState, os.time(), "ITEM_NOT_FOUND", "slot has no equipped item")
    end
    -- 强化与楼层解耦；与属性计算、存档归一化共用同一个硬上限。
    local limit = Catalog.MAX_ENHANCE
    local cost = StrengthenCost(working, item, item.enhance)
    local atMax = item.enhance >= limit
    local goldEnough = PlayerTransition.HasCurrency(working, "gold", cost.gold)
    local fragmentsEnough = PlayerTransition.HasCurrency(working, "fragments", cost.fragments)
    return {
        ok = true,
        code = "OK",
        data = {
            slot = slotId,
            itemId = item.id,
            itemName = item.name,
            currentEnhance = item.enhance,
            nextEnhance = math.max(item.enhance, math.min(limit, item.enhance + 1)),
            enhanceLimit = limit,
            gold = cost.gold,
            goldOwned = LargeNumber.Normalize(working.gold),
            fragments = cost.fragments,
            fragmentsOwned = LargeNumber.Normalize(working.fragments),
            canStrengthen = not atMax and goldEnough and fragmentsEnough,
            atMax = atMax,
            goldEnough = goldEnough,
            fragmentsEnough = fragmentsEnough,
            tutorialFree = cost.tutorialFree == true,
        },
    }
end

function EquipmentEngine.Strengthen(inputState, slotId, now)
    if not Catalog.SLOT_BY_ID[slotId] then
        return PlayerTransition.Failure(inputState, now, "INVALID_SLOT", "unknown equipment slot")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local item = PlayerTransition.FindItem(working, working.equipped[slotId])
    if not item then
        return PlayerTransition.Failure(inputState, now, "ITEM_NOT_FOUND", "slot has no equipped item")
    end
    local limit = Catalog.MAX_ENHANCE
    if item.enhance >= limit then
        return PlayerTransition.Failure(inputState, now, "ENHANCE_LIMIT", "equipment reached the current strengthen limit")
    end
    local cost = StrengthenCost(working, item, item.enhance)
    local goldCost = cost.gold
    local fragmentCost = cost.fragments
    if not PlayerTransition.HasCurrency(working, "gold", goldCost) or not PlayerTransition.HasCurrency(working, "fragments", fragmentCost) then
        return PlayerTransition.Failure(inputState, now, "INSUFFICIENT_RESOURCES", "not enough gold or fragments")
    end
    PlayerTransition.SpendCurrency(working, "gold", goldCost)
    PlayerTransition.SpendCurrency(working, "fragments", fragmentCost)
    item.enhance = item.enhance + 1
    item.investedGold = LargeNumber.Add(
        item.investedGold,
        goldCost
    )
    item.investedFragments = math.min(
        Catalog.MAX_VALUE,
        (item.investedFragments or 0) + fragmentCost
    )
    PlayerTransition.RefreshDerived(working)
    local events = {
        PlayerTransition.Event("equipment_strengthened", {
            itemId = item.id,
            enhance = item.enhance,
            goldCost = goldCost,
            fragmentCost = fragmentCost,
        }),
    }
    -- 新手剧情：强化完成
    TutorialEngine.OnStrengthen(working, events, now)
    return PlayerTransition.Finalize(inputState, working, now, "equipment_strengthened", events, true, false)
end

EquipmentEngine.StrengthenSelected = EquipmentEngine.Strengthen

local function StarCost(item, star)
    return Catalog.GetStarCost(item, star)
end

local function StarMaterials(state, item)
    local equipped = PlayerTransition.EquippedIdSet(state)
    local materials = {}
    for index, candidate in ipairs(state.inventory or {}) do
        if candidate.id ~= item.id
            and candidate.equipmentId == item.equipmentId
            and candidate.level == item.level
            and candidate.legacyLevel == item.legacyLevel
            and (candidate.star or 0) == (item.star or 0)
            and RarityCatalog.NormalizeId(candidate.rarity) == RarityCatalog.NormalizeId(item.rarity)
            and not candidate.locked
            and not candidate.aidLocked
            and not equipped[candidate.id]
        then
            materials[#materials + 1] = { item = candidate, index = index }
        end
    end
    return materials
end

local function FindStarMaterial(state, item, materialItemId)
    for _, material in ipairs(StarMaterials(state, item)) do
        if materialItemId == nil or tostring(material.item.id) == tostring(materialItemId) then
            return material.item, material.index
        end
    end
    return nil, nil
end

function EquipmentEngine.GetStarPreview(inputState, slotId)
    if not Catalog.SLOT_BY_ID[slotId] then
        return PlayerTransition.Failure(inputState, os.time(), "INVALID_SLOT", "unknown equipment slot")
    end
    local working = PlayerTransition.Copy(inputState, os.time())
    local item = PlayerTransition.FindItem(working, working.equipped[slotId])
    if not item then
        return PlayerTransition.Failure(inputState, os.time(), "ITEM_NOT_FOUND", "slot has no equipped item")
    end
    local cost = StarCost(item, item.star)
    local materialEntries = StarMaterials(working, item)
    local materials = {}
    for _, entry in ipairs(materialEntries) do
        local material = entry.item
        materials[#materials + 1] = {
            itemId = material.id,
            equipmentId = material.equipmentId,
            name = material.name,
            rarity = material.rarity,
            level = material.level,
            enhance = material.enhance or 0,
            star = material.star or 0,
            slot = material.slot,
            category = material.category,
            icon = material.icon,
            locked = material.locked == true,
            aidLocked = material.aidLocked == true,
        }
    end
    local atMax = item.star >= Catalog.MAX_STAR
    local goldEnough = PlayerTransition.HasCurrency(working, "gold", cost.gold)
    local fragmentsEnough = PlayerTransition.HasCurrency(working, "fragments", cost.fragments)
    return {
        ok = true,
        code = "OK",
        data = {
            slot = slotId,
            itemId = item.id,
            itemName = item.name,
            currentStar = item.star,
            nextStar = math.min(Catalog.MAX_STAR, item.star + 1),
            maxStar = Catalog.MAX_STAR,
            gold = cost.gold,
            goldOwned = LargeNumber.Normalize(working.gold),
            fragments = cost.fragments,
            fragmentsOwned = LargeNumber.Normalize(working.fragments),
            duplicateCount = cost.duplicateCount,
            materialOwned = #materials,
            materials = materials,
            material = materials[1],
            canStar = not atMax and #materials > 0 and goldEnough and fragmentsEnough,
            atMax = atMax,
            goldEnough = goldEnough,
            fragmentsEnough = fragmentsEnough,
        },
    }
end

function EquipmentEngine.Star(inputState, slotId, materialItemId, now)
    if not Catalog.SLOT_BY_ID[slotId] then
        return PlayerTransition.Failure(inputState, now, "INVALID_SLOT", "unknown equipment slot")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local item = PlayerTransition.FindItem(working, working.equipped[slotId])
    if not item then
        return PlayerTransition.Failure(inputState, now, "ITEM_NOT_FOUND", "slot has no equipped item")
    end
    if item.star >= 5 then
        return PlayerTransition.Failure(inputState, now, "STAR_LIMIT", "equipment already has five stars")
    end

    if type(materialItemId) ~= "string" or materialItemId == "" then
        return PlayerTransition.Failure(inputState, now, "MATERIAL_REQUIRED", "a star material item must be selected")
    end
    local _, duplicateIndex = FindStarMaterial(working, item, materialItemId)
    if not duplicateIndex then
        return PlayerTransition.Failure(inputState, now, "DUPLICATE_REQUIRED", "an unequipped item with the same equipment, star level and rarity is required")
    end
    local cost = StarCost(item, item.star)
    if not PlayerTransition.HasCurrency(working, "gold", cost.gold)
        or not PlayerTransition.HasCurrency(working, "fragments", cost.fragments)
    then
        return PlayerTransition.Failure(inputState, now, "INSUFFICIENT_RESOURCES", "not enough gold or fragments")
    end
    PlayerTransition.SpendCurrency(working, "gold", cost.gold)
    PlayerTransition.SpendCurrency(working, "fragments", cost.fragments)
    local consumed = working.inventory[duplicateIndex]
    local consumedId = consumed.id
    local refund = Catalog.GetEquipmentRecoveryValue(consumed)
    item.investedGold = LargeNumber.Add(
        item.investedGold,
        refund.gold
    )
    item.investedFragments = math.min(
        Catalog.MAX_VALUE,
        (item.investedFragments or 0) + refund.fragments
    )
    table.remove(working.inventory, duplicateIndex)
    item.star = item.star + 1
    if working.pauseReason == "inventory_full" then
        working.pauseReason = nil
    end
    PlayerTransition.RefreshDerived(working)
    return PlayerTransition.Finalize(inputState, working, now, "equipment_starred", {
        PlayerTransition.Event("equipment_starred", {
            itemId = item.id,
            consumedItemId = consumedId,
            star = item.star,
            previousStar = item.star - 1,
            goldCost = cost.gold,
            fragmentCost = cost.fragments,
        }),
    }, true, false)
end

EquipmentEngine.StarSelected = EquipmentEngine.Star

EquipmentEngine.BindOnSuccessfulEquip = bindEquipmentOnSuccessfulEquip
EquipmentEngine.HasAutoDispositionPolicy = hasAutoDispositionPolicy
EquipmentEngine.MakeRoomForDrop = makeRoomForDrop
EquipmentEngine.DrainOverflowLoot = drainOverflowLoot
EquipmentEngine.ConsiderUpgrade = considerEquipmentUpgrade
EquipmentEngine.OptimizeLoadout = optimizeWholeLoadout

return EquipmentEngine
