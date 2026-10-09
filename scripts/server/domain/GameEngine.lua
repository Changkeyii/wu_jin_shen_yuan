local Catalog = require("server.domain.Catalog")
local StateNormalizer = require("server.domain.StateNormalizer")
local TableUtils = require("server.domain.TableUtils")
local CombatSequence = require("shared.CombatSequence")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local TowerRules = require("shared.TowerRules")
local FloorRoute = require("shared.FloorRoute")
local RewardPolicy = require("shared.RewardPolicy")
local RarityCatalog = require("shared.RarityCatalog")
local ItemTradeRules = require("shared.ItemTradeRules")
local PowerEvaluator = require("shared.PowerEvaluator")
local StoryCatalog = require("shared.StoryCatalog")
local GameStateSchema = require("shared.GameStateSchema")
local PlayerTransition = require("server.domain.PlayerTransition")
local DomainMath = require("server.domain.DomainMath")
local InventoryState = require("server.domain.InventoryState")
local EquipmentEngine = require("server.domain.EquipmentEngine")
local CombatEngine = require("server.domain.CombatEngine")
local AdventureEngine = require("server.domain.AdventureEngine")
local RewardEngine = require("server.domain.RewardEngine")
local QuestEngine = require("server.domain.QuestEngine")
local TutorialEngine = require("server.domain.TutorialEngine")
local AbyssEngine = require("server.domain.AbyssEngine")
local RewardClaimEngine = require("server.domain.RewardClaimEngine")
local RewardClaimDefinitions = require("shared.RewardClaimDefinitions")

-- 允许对外导出函数别名（Equip/Decompose 等），避免 LSP 将空表字段判为 unknown。
---@type table<string, any>
local GameEngine = {}

local function rewardScale(context)
    return context and context.offline and Catalog.OFFLINE_REWARD_RATE or 1
end

local function hasAidForFloor(state, floor)
    for _, grantedFloor in ipairs(type(state.aidGrantedFloors) == "table"
        and state.aidGrantedFloors or {})
    do
        if grantedFloor == floor then return true end
    end
    return false
end

local function appendAidFloor(state, floor)
    state.aidGrantedFloors = type(state.aidGrantedFloors) == "table"
        and state.aidGrantedFloors or {}
    if not hasAidForFloor(state, floor) then
        state.aidGrantedFloors[#state.aidGrantedFloors + 1] = floor
        table.sort(state.aidGrantedFloors)
    end
end

local function settleMonsterVictory(state, monster, rng, now, events, context)
    local encounterKind = monster.encounter
    local randomAbyss = monster.abyssSource == "random"
        and type(monster.abyssRunId) == "string"
        and monster.abyssRunId ~= ""
        and monster.abyssGradeId ~= nil
    local isBoss = encounterKind == "boss" or encounterKind == "chapterBoss"
    local isElite = encounterKind == "elite"
    QuestEngine.Track(state, isBoss and "boss_kill" or (isElite and "elite_kill" or "monster_kill"), 1, now)
    -- 新手剧情：首杀保底掉落引导装备（仅在线战斗触发，离线结算不推进教程）
    if not (context and context.offline == true) then
        TutorialEngine.OnKill(state, events, now, rng)
    end
    local rate = rewardScale(context)
    local exp = math.floor((state.floor * 5 + 10) * (isBoss and 10 or (isElite and 2.3 or 1)) * rate)
    local gold = LargeNumber.MultiplyScalar(
        Catalog.GetBattleGold(state.floor, encounterKind),
        rate
    )
    if not LargeNumber.IsZero(gold) then
        PlayerTransition.AddCurrency(state, "gold", gold)
    end
    if exp > 0 then RewardEngine.AddExp(state, exp, events) end
    state.floorKillBonus = math.min(0.50, state.floorKillBonus + 0.01)
    events[#events + 1] = PlayerTransition.Event("battle_reward", {
        gold = gold,
        exp = exp,
        rewardRate = rate,
        offline = context and context.offline == true,
    })
    if not LargeNumber.IsZero(gold)
        and not (context and context.offline == true)
    then
        events[#events + 1] = PlayerTransition.Event("currency_drop", {
            currency = "gold",
            amount = gold,
            dropCount = math.max(1, math.min(12,
                math.floor(math.log(math.max(10,
                    state.floor + 10)) / math.log(10) * 3))),
        })
    end

    local inventoryChanged = false
    if randomAbyss then
        local settled, _, _, abyssInventoryChanged =
            AbyssEngine.SettleWorking(
                state,
                "random",
                monster.abyssGradeId,
                0,
                monster.abyssRunId,
                rng,
                now,
                events
            )
        if not settled then return false, inventoryChanged end
        inventoryChanged = inventoryChanged
            or abyssInventoryChanged == true
    else
        local chance = RewardPolicy.DropChance(
            encounterKind,
            context and context.offline == true
        ) or 0
        local droppedRarity = nil
        local droppedItem = nil
        if DomainMath.RandomFloat(rng) < chance then
            local rarity = RewardPolicy.RollRarity(
                encounterKind,
                state.floor,
                DomainMath.RandomFloat(rng),
                state.rewardPity
            )
            droppedRarity = rarity
            local source = encounterKind == "chapterBoss"
                and "chapter_boss_drop"
                or (isBoss and "boss_drop"
                    or (isElite and "elite_drop" or "monster_drop"))
            local dropOptions = nil
            if (tonumber(state.stats and state.stats.powerRatio) or 0) < 1 then
                local weakRanked = EquipmentEngine.WeakestEquipmentSlots(state)
                local weakSlots = {}
                for index = 1, math.min(3, #weakRanked) do
                    weakSlots[index] = weakRanked[index].slot
                end
                local allSlots = {}
                for index, slot in ipairs(Catalog.SLOTS) do
                    allSlots[index] = slot.id
                end
                dropOptions = {
                    slot = RewardPolicy.PickDropSlot(
                        allSlots,
                        weakSlots,
                        DomainMath.RandomFloat(rng),
                        DomainMath.RandomFloat(rng)
                    ),
                    rollTradeable = true,
                }
            else
                dropOptions = { rollTradeable = true }
            end
            local added, item, inventoryAdded =
                RewardEngine.AddGeneratedDrop(
                    state,
                    rarity,
                    isBoss,
                    rng,
                    now,
                    source,
                    events,
                    dropOptions
                )
            if not added then return false, inventoryChanged end
            droppedItem = item
            inventoryChanged = inventoryChanged or inventoryAdded
        end
        if encounterKind == "chapterBoss" then
            local pity = RewardPolicy.UpdatePity(
                state.rewardPity,
                droppedRarity
            )
            if state.floor < RarityCatalog.Get("epic").unlockFloor then
                pity.epicMisses = 0
            end
            if state.floor < RarityCatalog.Get("myth").unlockFloor then
                pity.mythMisses = 0
            end
            state.rewardPity = pity
            events[#events + 1] = PlayerTransition.Event(
                "reward_pity_updated",
                {
                    epicMisses = pity.epicMisses,
                    mythMisses = pity.mythMisses,
                    droppedRarity = droppedRarity,
                }
            )
        end

        if droppedItem then
            local _, boundOnEquip = EquipmentEngine.ConsiderUpgrade(
                state,
                droppedItem,
                now,
                events
            )
            inventoryChanged = inventoryChanged or boundOnEquip
        end
    end

    if not randomAbyss
        and not (context and context.offline == true)
        and state.abyss
        and (state.abyss.randomCooldownBattles or 0) > 0
    then
        state.abyss.randomCooldownBattles = math.max(
            0,
            state.abyss.randomCooldownBattles - 1
        )
    end
    if isBoss and context and context.offline == true then
        local _, boundOnOptimize = EquipmentEngine.OptimizeLoadout(state, now, events)
        inventoryChanged = inventoryChanged or boundOnOptimize
        state.position = 0
        state.currentEvent = Catalog.GetCellType(1, state.floor)
        state.floorDefeats = 0
        state.floorKillBonus = 0
        PlayerTransition.RefreshDerived(state)
        DomainMath.SetPlayerHp(state, DomainMath.StatMagnitude(state.stats, "hp"))
        return true, inventoryChanged
    end
    if isBoss then
        require("server.domain.AdGiftEngine").OnBossVictory(state, gold, events)
        local _, boundOnOptimize = EquipmentEngine.OptimizeLoadout(state, now, events)
        inventoryChanged = inventoryChanged or boundOnOptimize
        local completedFloor = state.floor
        local milestoneReward = RewardClaimDefinitions.FloorMilestoneReward(
            completedFloor
        )
        if milestoneReward then
            local ticketCount = AbyssEngine.GrantTickets(
                state,
                milestoneReward.abyssTickets or 0
            )
            if (milestoneReward.fragments or 0) > 0 then
                PlayerTransition.AddCurrency(
                    state,
                    "fragments",
                    milestoneReward.fragments
                )
            end
            local baseReward = {
                gold = LargeNumber.Zero(),
                exp = 0,
                fragments = milestoneReward.fragments or 0,
                abyssTickets = ticketCount,
            }
            local offer = RewardClaimEngine.CreateAdOffer(
                state,
                {
                    source = "floor_milestone",
                    sourceKey = "floor:" .. tostring(completedFloor),
                    baseReward = baseReward,
                    meta = { floor = completedFloor },
                },
                now
            )
            events[#events + 1] = PlayerTransition.Event(
                "floor_milestone_reward",
                {
                    floor = completedFloor,
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
        events[#events + 1] = PlayerTransition.Event("floor_completed", {
            floor = completedFloor,
            chapterBoss = encounterKind == "chapterBoss",
        })
        if encounterKind == "chapterBoss" then
            events[#events + 1] = PlayerTransition.Event("chapter_boss_defeated", {
                floor = completedFloor,
                chapter = math.floor(completedFloor / 10),
            })
            AdventureEngine.QueueStoryGate(
                state,
                math.floor(completedFloor / 10),
                "memory",
                context,
                events
            )
        end
        if (Catalog.GetSetCounts(state).prophecy or 0) >= 12 then
            state.permanentBonus = state.permanentBonus + 0.005
            events[#events + 1] = PlayerTransition.Event("permanent_growth", { amount = 0.005 })
        end
        for _, item in ipairs(state.inventory) do
            if item.aidLocked and (item.aidFloor or completedFloor) <= completedFloor then
                item.aidLocked = false
            end
        end
        state.floor = completedFloor + 1
        state.maxFloor = math.max(state.maxFloor, state.floor)
        QuestEngine.Track(state, "floor_advance", 1, now)
        -- 新手剧情：登塔推进一层即完成教程
        TutorialEngine.OnFloorClear(state, events, now)
        state.position = 0
        state.floorDefeats = 0
        state.aidPending = false
        state.floorKillBonus = 0
        PlayerTransition.RefreshDerived(state)
        local beforeHeal = DomainMath.Magnitude(state.hpBig, state.hp, 0)
        local maximumHp = DomainMath.StatMagnitude(state.stats, "hp")
        DomainMath.SetPlayerHp(state, maximumHp)
        local healed = BigNumber.Subtract(maximumHp, beforeHeal)
        events[#events + 1] = PlayerTransition.Event("floor_advanced", {
            completedFloor = completedFloor,
            floor = state.floor,
        })
        local recovery = {
            source = "floor_rest",
        }
        DomainMath.AddMagnitudeFields(recovery, "amount", "amountBig", healed)
        DomainMath.AddMagnitudeFields(recovery, "playerHp", "playerHpBig", state.hpBig)
        DomainMath.AddMagnitudeFields(recovery, "playerMaxHp", "playerMaxHpBig", maximumHp)
        events[#events + 1] = PlayerTransition.Event("floor_recovery", recovery)
        if not BigNumber.IsZero(healed) then
            local healedEvent = {
                source = "floor_rest",
            }
            DomainMath.AddMagnitudeFields(healedEvent, "amount", "amountBig", healed)
            DomainMath.AddMagnitudeFields(healedEvent, "playerHp", "playerHpBig", state.hpBig)
            DomainMath.AddMagnitudeFields(healedEvent, "playerMaxHp", "playerMaxHpBig", maximumHp)
            events[#events + 1] = PlayerTransition.Event("player_healed", healedEvent)
        end
    else
        PlayerTransition.RefreshDerived(state, true)
    end
    return true, inventoryChanged
end

local function playerDeath(state, monster, events, context)
    local floor = state.floor
    local room = monster.room or state.position
    state.floorDefeats = math.max(0, TableUtils.ToInteger(state.floorDefeats, 0)) + 1
    if monster.abyssSource == "random" and state.abyss then
        state.abyss.currentRandom = nil
    end
    state.currentMonster = nil
    state.position = 0
    state.currentEvent = Catalog.GetCellType(1, floor)
    state.floorKillBonus = 0
    PlayerTransition.RefreshDerived(state, true)
    local beforeRevive = DomainMath.Magnitude(state.hpBig, state.hp, 0)
    local maximumHp = DomainMath.StatMagnitude(state.stats, "hp")
    local diedEvent = {
        floor = floor,
        room = room,
        monsterId = monster.id,
    }
    DomainMath.AddMagnitudeFields(diedEvent, "hp", "hpBig", BigNumber.Zero())
    DomainMath.AddMagnitudeFields(diedEvent, "maxHp", "maxHpBig", maximumHp)
    events[#events + 1] = PlayerTransition.Event("player_died", diedEvent)
    DomainMath.SetPlayerHp(state, maximumHp)
    events[#events + 1] = PlayerTransition.Event("battle_lost", {
        monster = monster.name,
        monsterId = monster.id,
        encounterKind = monster.encounter,
        floor = floor,
        room = room,
        floorDefeats = state.floorDefeats,
    })
    events[#events + 1] = PlayerTransition.Event("floor_reset", {
        floor = floor,
        fromRoom = room,
        room = 1,
        rewardsRetained = true,
    })
    local revivedEvent = {
        source = "revive",
        floor = floor,
        room = 1,
    }
    DomainMath.AddMagnitudeFields(revivedEvent, "playerHp", "playerHpBig", state.hpBig)
    DomainMath.AddMagnitudeFields(revivedEvent, "playerMaxHp", "playerMaxHpBig", maximumHp)
    events[#events + 1] = PlayerTransition.Event("player_revived", revivedEvent)
    local healedEvent = {
        source = "revive",
    }
    DomainMath.AddMagnitudeFields(healedEvent, "amount", "amountBig",
        BigNumber.Subtract(state.hpBig, beforeRevive))
    DomainMath.AddMagnitudeFields(healedEvent, "playerHp", "playerHpBig", state.hpBig)
    DomainMath.AddMagnitudeFields(healedEvent, "playerMaxHp", "playerMaxHpBig", maximumHp)
    events[#events + 1] = PlayerTransition.Event("player_healed", healedEvent)

    local offline = context and context.offline == true
    if not offline then require("server.domain.AdGiftEngine").OnLoss(state, monster, events) end
    local granted = hasAidForFloor(state, floor)
    if not offline and RewardPolicy.ShouldGrantAid(state.floorDefeats, granted) then
        state.aidPending = true
        state.autoRun = false
        state.pauseReason = "tower_aid"
        local aidPayload = {
            floor = floor,
            floorDefeats = state.floorDefeats,
            minimumPowerGain = RewardPolicy.AID_MINIMUM_POWER_GAIN,
            targetPowerRatio = RewardPolicy.AID_TARGET_RECOMMENDED_RATIO,
            targetRemainingHpRatio = RewardPolicy.AID_MINIMUM_REMAINING_HP_RATIO,
        }
        events[#events + 1] = PlayerTransition.Event("aid_pending", TableUtils.DeepCopy(aidPayload))
        events[#events + 1] = PlayerTransition.Event("tower_aid_requested", aidPayload)
    end
end

local combatCallbacks = {
    settleVictory = function(state, monster, rng, now, events, context)
        return settleMonsterVictory(state, monster, rng, now, events, context)
    end,
    handlePlayerDeath = function(state, monster, events, context)
        return playerDeath(state, monster, events, context)
    end,
}

local resolveChest
local resolveMerchant
local resolveRandomEvent

local function advanceOnlineCombatWorking(state, rng, now, timeStep, context)
    local events = {}
    if not state.currentMonster then
        if state.pendingStoryGate then
            state.pauseReason = "story_gate"
            return state, "story_gate", { AdventureEngine.StoryGateEvent(state.pendingStoryGate) }, false
        end
        local transition = math.max(0, tonumber(state.transitionRemaining) or 0)
        if transition > 0 then
            state.transitionRemaining = math.max(0, transition - math.max(0, tonumber(timeStep) or 0))
            return state, "encounter_transition", {
                PlayerTransition.Event("encounter_transition", {
                    seconds = state.transitionRemaining,
                    floor = state.floor,
                    nextRoom = math.min(10, (state.position or 0) + 1),
                }),
            }, false
        end
        if #state.inventory >= Catalog.GetInventoryCapacity(state)
            and state.inventoryPolicy.pauseOnFull
            and not EquipmentEngine.HasAutoDispositionPolicy(state)
        then
            state.autoRun = false
            state.pauseReason = "inventory_full"
            return state, "inventory_full", {
                PlayerTransition.Event("inventory_full", { capacity = Catalog.GetInventoryCapacity(state) }),
            }, false
        end
        if state.aidPending and not (context and context.offline) then
            state.autoRun = false
            state.pauseReason = "tower_aid"
            return state, "tower_aid_pending", {
                PlayerTransition.Event("tower_aid_pending", { floor = state.floor }),
            }, false
        end
        if not (context and context.offline) then
            return state, "awaiting_encounter", {}, false
        end
        if BigNumber.IsZero(DomainMath.Magnitude(state.hpBig, state.hp, 0)) then
            DomainMath.SetPlayerHp(state, DomainMath.StatMagnitude(state.stats, "hp"))
        end
        if state.floor % 10 == 0 then
            local phase = state.position == 0 and "opening"
                or (state.position == 9 and "boss" or nil)
            if phase and AdventureEngine.QueueStoryGate(state, math.floor(state.floor / 10), phase, context, events) then
                return state, "story_gate", events, false
            end
        end
        state.position = math.min(10, state.position + 1)
        local encounter = CombatEngine.GetMonster(state, nil, state.position).encounter
        state.currentEvent = encounter.eventType
        events[#events + 1] = PlayerTransition.Event("cell_entered", {
            position = state.position,
            room = state.position,
            floor = state.floor,
            eventType = encounter.eventType,
            encounterKind = encounter.kind,
        })
        CombatEngine.BeginBattle(state, encounter.eventType, rng, events, context)
        return state, "battle_started", events, false
    end

    local kind, inventoryChanged = CombatEngine.AdvanceActiveCombat(
        state,
        rng,
        now,
        timeStep or Catalog.COMBAT_TICK_SECONDS,
        events,
        context,
        combatCallbacks
    )
    return state, kind, events, inventoryChanged
end

local function resolveMonsterOffline(state, eventType, rng, now, events, context)
    CombatEngine.BeginBattle(state, eventType, rng, events, context)
    local inventoryChanged = false
    local guard = 0
    while state.currentMonster and guard < 120 do
        guard = guard + 1
        local kind, changed = CombatEngine.AdvanceActiveCombat(state, rng, now, 60, events, context, combatCallbacks)
        inventoryChanged = inventoryChanged or changed
        if kind == "inventory_full" then return false, inventoryChanged end
    end
    return true, inventoryChanged
end

resolveChest = function(state, rng, now, events)
    local gold = Catalog.GetChestGold(
        state.floor,
        DomainMath.RandomFloat(rng)
    )
    local fragments = DomainMath.RandomInt(rng, 3, 12)
    PlayerTransition.AddCurrency(state, "gold", gold)
    PlayerTransition.AddCurrency(state, "fragments", fragments)
    events[#events + 1] = PlayerTransition.Event("chest_reward", { gold = gold, fragments = fragments })
    if DomainMath.RandomInt(rng, 1, 100) <= 35 then
        local added, _, inventoryAdded = RewardEngine.AddGeneratedDrop(
            state,
            "blue",
            false,
            rng,
            now,
            "chest_drop",
            events,
            { rollTradeable = true }
        )
        return added, inventoryAdded
    end
    return true, false
end

resolveMerchant = function(state, events)
    local price = Catalog.GetMerchantGoldCost(state.floor)
    if PlayerTransition.HasCurrency(state, "gold", price) then
        PlayerTransition.SpendCurrency(state, "gold", price)
        PlayerTransition.AddCurrency(state, "fragments", 10)
        events[#events + 1] = PlayerTransition.Event("merchant_trade", { goldSpent = price, fragments = 10 })
    else
        events[#events + 1] = PlayerTransition.Event("merchant_skipped", { price = price, reason = "insufficient_gold" })
    end
end

resolveRandomEvent = function(state, rng, events)
    local roll = DomainMath.RandomInt(rng, 1, 4)
    if roll == 1 then
        local gold = Catalog.GetWishGold(state.floor)
        PlayerTransition.AddCurrency(state, "gold", gold)
        events[#events + 1] = PlayerTransition.Event("wish_pool", { gold = gold })
    elseif roll == 2 then
        local distance = DomainMath.RandomInt(rng, 5, 10)
        state.position = math.min(99, state.position + distance)
        events[#events + 1] = PlayerTransition.Event("teleport", { distance = distance, position = state.position })
    elseif roll == 3 then
        local maximumHp = DomainMath.StatMagnitude(state.stats, "hp")
        local currentHp = DomainMath.Magnitude(state.hpBig, state.hp, maximumHp)
        local healed = BigNumber.Min(
            BigNumber.Subtract(maximumHp, currentHp),
            BigNumber.Floor(BigNumber.MultiplyScalar(maximumHp, 0.18)))
        DomainMath.SetPlayerHp(state, BigNumber.Add(currentHp, healed))
        local healPayload = { source = "altar" }
        DomainMath.AddMagnitudeFields(healPayload, "amount", "amountBig", healed)
        DomainMath.AddMagnitudeFields(healPayload, "hp", "hpBig", state.hpBig)
        DomainMath.AddMagnitudeFields(healPayload, "maxHp", "maxHpBig", maximumHp)
        DomainMath.AddMagnitudeFields(healPayload, "playerHp", "playerHpBig", state.hpBig)
        DomainMath.AddMagnitudeFields(healPayload, "playerMaxHp", "playerMaxHpBig", maximumHp)
        events[#events + 1] = PlayerTransition.Event("altar_heal", TableUtils.DeepCopy(healPayload))
        if not BigNumber.IsZero(healed) then
            events[#events + 1] = PlayerTransition.Event("player_healed", healPayload)
        end
    else
        PlayerTransition.AddCurrency(state, "fragments", 18)
        events[#events + 1] = PlayerTransition.Event("abyss_echo", { fragments = 18 })
    end
end

GameEngine.ClaimDailySignInVip = RewardEngine.ClaimDailySignInVip
GameEngine.ClaimDailyAdVip = RewardEngine.ClaimDailyAdVip

GameEngine.SetAutoRun = AdventureEngine.SetAutoRun

local function advanceOneCellWorking(working, rng, now, context)
    local before = TableUtils.DeepCopy(working)
    if context and context.offline then working.transitionRemaining = 0 end
    if working.currentMonster then
        return advanceOnlineCombatWorking(working, rng, now, 60, context)
    end
    if working.pendingStoryGate then
        working.pauseReason = "story_gate"
        return working, "story_gate", { AdventureEngine.StoryGateEvent(working.pendingStoryGate) }, false
    end
    if #working.inventory >= Catalog.GetInventoryCapacity(working) and working.inventoryPolicy.pauseOnFull and not EquipmentEngine.HasAutoDispositionPolicy(working) then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        return working, "inventory_full", {
            PlayerTransition.Event("inventory_full", { capacity = Catalog.GetInventoryCapacity(working) }),
        }, false
    end

    if BigNumber.IsZero(DomainMath.Magnitude(working.hpBig, working.hp, 0)) then
        DomainMath.SetPlayerHp(working, DomainMath.StatMagnitude(working.stats, "hp"))
    end
    local storyEvents = {}
    if not (context and context.offline)
        and working.floor % 10 == 0
    then
        local phase = working.position == 0 and "opening"
            or (working.position == 9 and "boss" or nil)
        if phase and AdventureEngine.QueueStoryGate(
            working,
            math.floor(working.floor / 10),
            phase,
            context,
            storyEvents
        ) then
            return working, "story_gate", storyEvents, false
        end
    end
    working.position = math.min(10, working.position + 1)
    local encounter = CombatEngine.GetMonster(working, nil, working.position).encounter
    local eventType = encounter.eventType
    working.currentEvent = encounter.eventType
    local events = storyEvents
    events[#events + 1] =
        PlayerTransition.Event("cell_entered", {
            position = working.position,
            room = working.position,
            floor = working.floor,
            eventType = eventType,
            encounterKind = encounter.kind,
        })
    local completed = true
    local inventoryChanged = false

    completed, inventoryChanged = resolveMonsterOffline(
        working,
        eventType,
        rng,
        now,
        events,
        context
    )

    if not completed then
        if working.inventoryPolicy.pauseOnFull ~= false then
            before.autoRun = false
            before.pauseReason = "inventory_full"
            return before, "inventory_full", {
                PlayerTransition.Event("inventory_full", {
                    capacity = Catalog.GetInventoryCapacity(before),
                    rollback = "cell_settlement",
                }),
            }, false
        end
        working = before
        working.position = math.min(10, working.position + 1)
        return working, "drop_skipped", {
            PlayerTransition.Event("inventory_drop_skipped", { capacity = Catalog.GetInventoryCapacity(working) }),
        }, false
    end

    PlayerTransition.RefreshDerived(working)
    if #working.inventory >= Catalog.GetInventoryCapacity(working) and working.inventoryPolicy.pauseOnFull and not EquipmentEngine.HasAutoDispositionPolicy(working) then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        events[#events + 1] = PlayerTransition.Event("inventory_full", { capacity = Catalog.GetInventoryCapacity(working) })
    end
    return working, "cell_resolved", events, inventoryChanged
end

function GameEngine.AdvanceOneCell(inputState, rng, now)
    local working = PlayerTransition.Copy(inputState, now)
    local kind, events, inventoryChanged
    working, kind, events, inventoryChanged = advanceOneCellWorking(working, rng, now)
    return PlayerTransition.Finalize(inputState, working, now, kind, events, inventoryChanged, false)
end

GameEngine.EnterEncounter = AdventureEngine.EnterEncounter
GameEngine.ResolveEvent = AdventureEngine.ResolveEvent

function GameEngine.AdvanceCombatTick(inputState, rng, now, timeStep)
    timeStep = tonumber(timeStep) or 0
    if timeStep <= 0 then
        return PlayerTransition.NoCommit(inputState, now, "combat_tick_ignored")
    end
    local working = PlayerTransition.ShallowClone(inputState, now)
    if not working.autoRun then
        return PlayerTransition.NoCommit(inputState, now, "combat_paused")
    end
    timeStep = math.min(timeStep, 60)
    local kind, events, inventoryChanged
    working, kind, events, inventoryChanged = advanceOnlineCombatWorking(
        working,
        rng,
        now,
        timeStep,
        { offline = false }
    )
    return PlayerTransition.Finalize(inputState, working, now, kind, events, inventoryChanged, false, true)
end

GameEngine.ClaimLootStash = RewardEngine.ClaimLootStash
GameEngine.ExpandInventoryByAd = RewardEngine.ExpandInventoryByAd

GameEngine.Equip = EquipmentEngine.Equip
GameEngine.EquipItem = GameEngine.Equip
GameEngine.Unequip = EquipmentEngine.Unequip
GameEngine.UnequipItem = GameEngine.Unequip
GameEngine.AutoEquip = EquipmentEngine.AutoEquip
GameEngine.AutoEquipBest = GameEngine.AutoEquip
GameEngine.GetSellPreview = EquipmentEngine.GetSellPreview
GameEngine.GetDecomposePreview = EquipmentEngine.GetDecomposePreview
GameEngine.Decompose = EquipmentEngine.Decompose
GameEngine.DecomposeByRank = GameEngine.Decompose
GameEngine.Sell = EquipmentEngine.Sell
GameEngine.SellByRank = GameEngine.Sell

local function aidEvaluation(state, floor)
    ---@type fun(stats: table, options: table): any
    local evaluatePower = PowerEvaluator.Evaluate
    local ok, result = pcall(evaluatePower, state.stats, { floor = floor })
    if not ok or type(result) ~= "table" then return {} end
    ---@cast result table
    return result
end

local function aidTargetsMet(evaluation, targetPower)
    local power = DomainMath.Magnitude(evaluation.displayedPower, evaluation.displayedPowerNumber, 0)
    local survival = tonumber(evaluation.bossRemainingHpRatio)
        or tonumber(evaluation.remainingHpRatio)
    if survival == nil then
        survival = (tonumber(evaluation.bossSurvivalMargin) or 0) >= 1.2
            and RewardPolicy.AID_MINIMUM_REMAINING_HP_RATIO or 0
    end
    return BigNumber.Compare(power, targetPower) >= 0
        and survival >= RewardPolicy.AID_MINIMUM_REMAINING_HP_RATIO
end

local AID_SCALAR_FIELDS = {
    "crit",
    "critDmg",
    "atkSpeed",
    "lifeSteal",
    "damageReduction",
    "bossDamage",
}

local function aidItemBaseline(item)
    local baseline = {
        budgetBig = DomainMath.Magnitude(item.budgetBig, item.budget, 0),
        atkBig = DomainMath.Magnitude(item.atkBig, item.atk, 0),
        defBig = DomainMath.Magnitude(item.defBig, item.def, 0),
        hpBig = DomainMath.Magnitude(item.hpBig, item.hp, 0),
    }
    for _, field in ipairs(AID_SCALAR_FIELDS) do
        baseline[field] = tonumber(item[field]) or 0
    end
    return baseline
end

local function applyAidItemScale(item, baseline, scalar)
    scalar = math.max(0, math.min(1, tonumber(scalar) or 0))
    for _, field in ipairs({ "budget", "atk", "def", "hp" }) do
        local value = BigNumber.MultiplyScalar(
            baseline[field .. "Big"],
            scalar
        )
        item[field .. "Big"] = value
        item[field] = DomainMath.ProjectedMagnitude(value)
    end
    for _, field in ipairs(AID_SCALAR_FIELDS) do
        item[field] = baseline[field] * scalar
    end
end

local function trimAidItemToTarget(state, item, targetPower, evaluation)
    if not item or not aidTargetsMet(evaluation, targetPower) then
        return evaluation
    end
    local baseline = aidItemBaseline(item)
    local low = 0
    local high = 1
    local best = 1
    local bestEvaluation = evaluation
    for _ = 1, 14 do
        local middle = (low + high) * 0.5
        applyAidItemScale(item, baseline, middle)
        PlayerTransition.RefreshDerived(state)
        local candidate = aidEvaluation(state, state.floor)
        if aidTargetsMet(candidate, targetPower) then
            best = middle
            high = middle
            bestEvaluation = candidate
        else
            low = middle
        end
    end
    applyAidItemScale(item, baseline, best)
    PlayerTransition.RefreshDerived(state)
    return aidEvaluation(state, state.floor) or bestEvaluation
end

function GameEngine.ClaimAid(inputState, rng, now)
    if type(rng) == "number" and now == nil then
        now = rng
        rng = nil
    end
    local working = PlayerTransition.Copy(inputState, now)
    working.aidGrantedFloors = type(working.aidGrantedFloors) == "table"
        and working.aidGrantedFloors or {}
    if not working.aidPending then
        return PlayerTransition.Failure(inputState, now, "NO_TOWER_AID", "tower aid is not pending")
    end
    if hasAidForFloor(working, working.floor) then
        return PlayerTransition.Failure(inputState, now, "TOWER_AID_ALREADY_CLAIMED", "tower aid was already claimed on this floor")
    end

    PlayerTransition.RefreshDerived(working)
    local beforeEvaluation = aidEvaluation(working, working.floor)
    local beforePower = DomainMath.Magnitude(
        beforeEvaluation.displayedPower,
        beforeEvaluation.displayedPowerNumber or working.stats.power,
        0)
    local recommended = TowerRules.RecommendedPower(working.floor)
    local targetPower = BigNumber.Max(
        BigNumber.MultiplyScalar(beforePower, 1 + RewardPolicy.AID_MINIMUM_POWER_GAIN),
        BigNumber.MultiplyScalar(recommended, RewardPolicy.AID_TARGET_RECOMMENDED_RATIO))
    local highest = RarityCatalog.HighestUnlocked(working.floor)
    local rarity = type(highest) == "table" and highest.id or (highest or "rare")
    local weakest = EquipmentEngine.WeakestEquipmentSlots(working)
    local events = {}
    local grantedItems = {}
    local inventoryChanged = false
    local evaluation = beforeEvaluation

    for index = 1, math.min(2, #weakest) do
        local slotId = weakest[index].slot
        local added, item, changed = RewardEngine.AddGeneratedDrop(
            working,
            rarity,
            false,
            rng,
            now,
            "tower_aid",
            events,
            {
                slot = slotId,
                floor = working.floor,
                roll = 1.05,
                aidLocked = true,
                aidFloor = working.floor,
                requireInventory = true,
            }
        )
        if not added or not item then
            return PlayerTransition.Failure(inputState, now, "INVENTORY_FULL", "clear inventory space before claiming tower aid", {
                PlayerTransition.Event("inventory_full", { capacity = Catalog.GetInventoryCapacity(working) }),
            })
        end
        item.setId = nil
        item.setEnabled = false
        working.equipped[slotId] = item.id
        EquipmentEngine.BindOnSuccessfulEquip(item)
        grantedItems[#grantedItems + 1] = item
        inventoryChanged = inventoryChanged or changed
        events[#events + 1] = PlayerTransition.Event("tower_aid_equipment", {
            itemId = item.id,
            equipmentId = item.equipmentId,
            slot = slotId,
            rarity = item.rarity,
            floor = working.floor,
        })
        PlayerTransition.RefreshDerived(working)
        evaluation = aidEvaluation(working, working.floor)
        if aidTargetsMet(evaluation, targetPower) then break end
    end

    -- 只做小幅校准，目标是刚好进入当前层“可挑战”线，而不是生成碾压装备。
    local tuned = grantedItems[#grantedItems]
    local tuneCount = 0
    while tuned and not aidTargetsMet(evaluation, targetPower) and tuneCount < 24 do
        tuneCount = tuneCount + 1
        DomainMath.MultiplyItemMagnitude(tuned, "atk", 1.02)
        DomainMath.MultiplyItemMagnitude(tuned, "def", 1.02)
        DomainMath.MultiplyItemMagnitude(tuned, "hp", 1.02)
        tuned.budgetBig = BigNumber.MultiplyScalar(
            DomainMath.Magnitude(tuned.budgetBig, tuned.budget, 0), 1.02)
        tuned.budget = DomainMath.ProjectedMagnitude(tuned.budgetBig)
        PlayerTransition.RefreshDerived(working)
        evaluation = aidEvaluation(working, working.floor)
    end
    evaluation = trimAidItemToTarget(
        working,
        tuned,
        targetPower,
        evaluation
    )

    working.aidPending = false
    appendAidFloor(working, working.floor)
    working.pauseReason = nil
    working.autoRun = false
    local aidClaimedPayload = {
        floor = working.floor,
        itemCount = #grantedItems,
        targetMet = aidTargetsMet(evaluation, targetPower),
        bossSurvivalMargin = evaluation.bossSurvivalMargin,
    }
    DomainMath.AddMagnitudeFields(aidClaimedPayload, "beforePower", "beforePowerBig", beforePower)
    DomainMath.AddMagnitudeFields(
        aidClaimedPayload,
        "displayedPower",
        "displayedPowerBig",
        DomainMath.Magnitude(evaluation.displayedPower, evaluation.displayedPowerNumber, working.stats.power))
    DomainMath.AddMagnitudeFields(aidClaimedPayload, "targetPower", "targetPowerBig", targetPower)
    events[#events + 1] = PlayerTransition.Event("tower_aid_claimed", aidClaimedPayload)
    local aidGrantedPayload = {
        floor = working.floor,
        itemCount = #grantedItems,
        targetMet = aidTargetsMet(evaluation, targetPower),
    }
    DomainMath.AddMagnitudeFields(
        aidGrantedPayload,
        "displayedPower",
        "displayedPowerBig",
        DomainMath.Magnitude(evaluation.displayedPower, evaluation.displayedPowerNumber, working.stats.power))
    events[#events + 1] = PlayerTransition.Event("aid_granted", aidGrantedPayload)
    return PlayerTransition.Finalize(inputState, working, now, "tower_aid_claimed", events, inventoryChanged, true)
end

GameEngine.ApplyAid = GameEngine.ClaimAid

GameEngine.SetEquipmentLock = EquipmentEngine.SetEquipmentLock
GameEngine.SetInventoryPolicy = EquipmentEngine.SetInventoryPolicy

GameEngine.SetInteractionMode = AdventureEngine.SetInteractionMode
GameEngine.SetAutomationPolicy = AdventureEngine.SetAutomationPolicy

GameEngine.DecideEquip = EquipmentEngine.DecideEquip
GameEngine.UndoEquip = EquipmentEngine.UndoEquip

GameEngine.AdvanceStory = AdventureEngine.AdvanceStory
GameEngine.AcknowledgeRules = AdventureEngine.AcknowledgeRules

GameEngine.GetStrengthenPreview = EquipmentEngine.GetStrengthenPreview
GameEngine.Strengthen = EquipmentEngine.Strengthen
GameEngine.StrengthenSelected = GameEngine.Strengthen
GameEngine.GetStarPreview = EquipmentEngine.GetStarPreview
GameEngine.Star = EquipmentEngine.Star
GameEngine.StarSelected = GameEngine.Star

GameEngine.TouchActive = RewardEngine.TouchActive
GameEngine.AccrueOffline = RewardEngine.AccrueOffline
GameEngine.PrepareLogin = GameEngine.AccrueOffline
GameEngine.FreezeOfflineReward = RewardEngine.FreezeOfflineReward
GameEngine.ClaimOfflineReward = RewardEngine.ClaimOfflineReward

GameEngine.GrantCurrency = RewardEngine.GrantCurrency
GameEngine.GrantEquipment = RewardEngine.GrantEquipment

--- 序章老号兜底：清空全部装备数据并补发教学装备。
function GameEngine.ResetTutorialLoadout(inputState, now)
    if not TutorialEngine.IsActive(inputState) then
        return PlayerTransition.Failure(
            inputState,
            now,
            "TUTORIAL_INACTIVE",
            "当前不在序章教学中"
        )
    end
    local working = PlayerTransition.Copy(inputState, now)
    local events = {}
    local ok, code, summary = TutorialEngine.ResetLoadoutForTutorial(
        working,
        events,
        now,
        math.random
    )
    if not ok then
        return PlayerTransition.Failure(
            inputState,
            now,
            code or "TUTORIAL_RESET_FAILED",
            "清理装备失败"
        )
    end
    return PlayerTransition.Finalize(
        inputState,
        working,
        now,
        "tutorial_loadout_reset",
        events,
        true,
        true
    )
end

--- 功能介绍看完后完成序章，发放保底奖励。
function GameEngine.CompleteTutorial(inputState, now)
    if not TutorialEngine.IsActive(inputState) then
        return PlayerTransition.Failure(
            inputState,
            now,
            "TUTORIAL_INACTIVE",
            "当前不在序章教学中"
        )
    end
    local working = PlayerTransition.Copy(inputState, now)
    local events = {}
    local ok, code = TutorialEngine.Complete(working, events, now)
    if not ok then
        return PlayerTransition.Failure(
            inputState,
            now,
            code or "TUTORIAL_COMPLETE_FAILED",
            code == "TUTORIAL_NOT_READY" and "功能介绍尚未完成" or "序章已完成"
        )
    end
    return PlayerTransition.Finalize(
        inputState,
        working,
        now,
        "tutorial_completed",
        events,
        true,
        false
    )
end

function GameEngine.AdjustProgress(inputState, adjustment, now)
    if type(adjustment) ~= "table" then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "progress adjustment is required")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local changed = false
    local limits = {
        level = { 1, 1000000 },
        exp = { 0, 1000000000 },
        floor = { 1, 1000000 },
        maxFloor = { 1, 1000000 },
        position = { 0, 10 },
    }
    for field, range in pairs(limits) do
        if adjustment[field] ~= nil then
            local value = TableUtils.ToInteger(adjustment[field], nil)
            if value == nil or value < range[1] or value > range[2] then
                return PlayerTransition.Failure(inputState, now, "INVALID_PROGRESS", field .. " is outside the allowed range")
            end
            working[field] = value
            changed = true
        end
    end
    if not changed then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "no supported progress field was supplied")
    end
    working.maxFloor = math.max(working.maxFloor, working.floor)
    while working.exp >= Catalog.NextExp(working.level) do
        working.exp = working.exp - Catalog.NextExp(working.level)
        working.level = working.level + 1
    end
    PlayerTransition.RefreshDerived(working)
    DomainMath.SetPlayerHp(working, DomainMath.StatMagnitude(working.stats, "hp"))
    return PlayerTransition.Finalize(inputState, working, now, "progress_adjusted", {
        PlayerTransition.Event("progress_adjusted", { fields = TableUtils.DeepCopy(adjustment) }),
    }, false, false)
end

function GameEngine.GetMonster(state, eventType)
    local copy = PlayerTransition.Copy(state, state and state.updatedAt or nil)
    return CombatEngine.GetMonster(copy, eventType)
end

function GameEngine.GetCellType(position, floor)
    return Catalog.GetCellType(position, floor)
end

function GameEngine.GetItemPower(item)
    return Catalog.GetItemPower(item)
end

--- 供 MarketEngine 复用的内部构件。市场是独立领域模块，但必须产出与本文件
--- 完全一致的 proposal 结构（state/delta/commit），否则 PlayerProfileService 无法消费。
GameEngine.Internal = {
    stateCopy = PlayerTransition.Copy,
    finalize = PlayerTransition.Finalize,
    noCommit = PlayerTransition.NoCommit,
    failure = PlayerTransition.Failure,
    event = PlayerTransition.Event,
    findItem = PlayerTransition.FindItem,
    equippedIdSet = PlayerTransition.EquippedIdSet,
    addCurrency = PlayerTransition.AddCurrency,
    spendCurrency = PlayerTransition.SpendCurrency,
    hasCurrency = PlayerTransition.HasCurrency,
}

return GameEngine
