local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local TowerRules = require("shared.TowerRules")
local RewardPolicy = require("shared.RewardPolicy")
local RarityCatalog = require("shared.RarityCatalog")
local ItemTradeRules = require("shared.ItemTradeRules")
local PlayerTransition = require("server.domain.PlayerTransition")
local DomainMath = require("server.domain.DomainMath")
local InventoryState = require("server.domain.InventoryState")
local EquipmentEngine = require("server.domain.EquipmentEngine")

local RewardEngine = {}

local function addExp(state, amount, events)
    local gained = math.max(0, TableUtils.ToInteger(amount, 0))
    local previousLevel = math.max(1, TableUtils.ToInteger(state.level, 1))
    state.exp = state.exp + gained
    local levelUps = 0
    while state.exp >= Catalog.NextExp(state.level) do
        state.exp = state.exp - Catalog.NextExp(state.level)
        state.level = state.level + 1
        levelUps = levelUps + 1
    end
    state.nextExp = Catalog.NextExp(state.level)
    if levelUps > 0 then
        local currentHp = DomainMath.Magnitude(state.hpBig, state.hp, 0)
        state.stats = Catalog.CalculateStats(state)
        DomainMath.SetPlayerHp(state, BigNumber.Min(currentHp, DomainMath.StatMagnitude(state.stats, "hp")))
        events[#events + 1] = PlayerTransition.Event("level_up", {
            previousLevel = previousLevel,
            level = state.level,
            levelsGained = levelUps,
            exp = state.exp,
            nextExp = state.nextExp,
            expGained = gained,
        })
    end
    return levelUps > 0
end

local function randomHex16()
    return string.format("%04x", math.random(0, 65535))
end

local function makeInstanceUuid()
    local first = randomHex16() .. randomHex16()
    local second = randomHex16()
    local third = string.format("4%03x", math.random(0, 4095))
    local fourth = string.format("%04x", 0x8000 + math.random(0, 16383))
    local fifth = randomHex16() .. randomHex16() .. randomHex16()
    return string.format("%s-%s-%s-%s-%s", first, second, third, fourth, fifth)
end

local function allocateItemId(state)
    local used = {}
    for _, item in ipairs(state.inventory) do
        used[item.id] = true
    end
    for _, item in ipairs(state.overflowLoot or {}) do used[item.id] = true end
    local itemId
    repeat
        itemId = makeInstanceUuid()
    until not used[itemId]
    state.nextItemId = state.nextItemId + 1
    return itemId
end

local CORE_AFFIX_POOL = {
    "core.fury", "core.guard", "core.vitality", "core.swiftness",
    "core.vampirism", "core.boss_hunter",
}

local function rollCoreAffixes(rarityId, rng, actual)
    local rarity = RarityCatalog.Get(rarityId)
    local count = math.max(0, TableUtils.ToInteger(rarity and rarity.coreAffixCount, 0))
    local pool = TableUtils.DeepCopy(CORE_AFFIX_POOL)
    local result = {}
    for _ = 1, math.min(count, #pool) do
        local affix = table.remove(pool, DomainMath.RandomInt(rng, 1, #pool))
        result[#result + 1] = affix
        if affix == "core.fury" then DomainMath.MultiplyItemMagnitude(actual, "atk", 1.03)
        elseif affix == "core.guard" then DomainMath.MultiplyItemMagnitude(actual, "def", 1.04)
        elseif affix == "core.vitality" then DomainMath.MultiplyItemMagnitude(actual, "hp", 1.04)
        elseif affix == "core.swiftness" then actual.atkSpeed = (actual.atkSpeed or 0) + 0.03
        elseif affix == "core.vampirism" then actual.lifeSteal = (actual.lifeSteal or 0) + 0.01
        elseif affix == "core.boss_hunter" then actual.bossDamage = (actual.bossDamage or 0) + 0.05 end
    end
    return result
end

local function generatedEquipment(state, rarityId, isBoss, rng, now, source, options)
    options = options or {}
    local floor = math.max(1, TableUtils.ToInteger(options.floor, state.floor))
    local unlocked = RarityCatalog.HighestUnlocked(floor)
    if type(rarityId) == "table" then rarityId = rarityId.id end
    local targetRarity = rarityId ~= nil and RarityCatalog.NormalizeId(rarityId)
        or (type(unlocked) == "table" and unlocked.id or unlocked)
        or "common"
    local candidates = {}
    local fallback = {}
    for _, definition in ipairs(Catalog.EQUIPMENT_DEFINITIONS) do
        if not options.slot or definition.slot == options.slot then
            fallback[#fallback + 1] = definition
            if RarityCatalog.NormalizeId(definition.rarity) == targetRarity then
                candidates[#candidates + 1] = definition
            end
        end
    end
    if #candidates == 0 then candidates = fallback end
    if #candidates == 0 then return nil end
    local definition = candidates[DomainMath.RandomInt(rng, 1, #candidates)]
    local itemRoll = options.roll
        and Catalog.Clamp(tonumber(options.roll) or 1, 0.95, 1.05)
        or (DomainMath.RandomInt(rng, 9500, 10500) / 10000)
    local enhance = Catalog.Clamp(TableUtils.ToInteger(options.enhance, 0), 0, Catalog.MAX_ENHANCE)
    local star = Catalog.Clamp(TableUtils.ToInteger(options.star, 0), 0, Catalog.MAX_STAR)
    local actual = Catalog.CreateItemStats(definition, floor, targetRarity, itemRoll, enhance, star)
    local coreAffixes = rollCoreAffixes(targetRarity, rng, actual)
    local uniqueEffect = targetRarity == "myth" and "myth.tower_soul_resonance" or nil
    if uniqueEffect then actual.bossDamage = (actual.bossDamage or 0) + 0.08 end
    local itemSource = source or (isBoss and "boss_drop" or "monster_drop")
    local tradeable = options.tradeable == true
    if options.rollTradeable == true then
        tradeable = ItemTradeRules.RollDropTradeable(
            itemSource,
            targetRarity,
            DomainMath.RandomFloat(rng)
        )
    end
    local item = {
        id = allocateItemId(state),
        equipmentId = definition.id,
        level = floor,
        enhance = enhance,
        star = star,
        locked = false,
        acquiredAt = PlayerTransition.Now(now),
        source = itemSource,
        tradeable = tradeable,
        investedGold = LargeNumber.Zero(),
        investedFragments = 0,
        name = definition.name,
        slot = definition.slot,
        category = definition.category,
        rarity = targetRarity,
        setId = actual.setId,
        setEnabled = actual.setEnabled == true,
        statVersion = 5,
        roll = actual.roll,
        budget = actual.budget,
        budgetBig = actual.budgetBig,
        atk = actual.atk,
        def = actual.def,
        hp = actual.hp,
        atkBig = actual.atkBig,
        defBig = actual.defBig,
        hpBig = actual.hpBig,
        crit = actual.crit,
        critDmg = actual.critDmg,
        atkSpeed = actual.atkSpeed,
        lifeSteal = actual.lifeSteal,
        damageReduction = actual.damageReduction,
        bossDamage = actual.bossDamage,
        coreAffixes = coreAffixes,
        uniqueEffect = uniqueEffect,
        aidLocked = options.aidLocked == true,
        aidFloor = options.aidFloor,
    }
    return item
end

local function addGeneratedDrop(state, rarityId, isBoss, rng, now, source, events, options)
    local item = generatedEquipment(state, rarityId, isBoss, rng, now, source, options)
    if not item then return true, nil, false end
    InventoryState.RecordCollection(state, item)
    local hasRoom, handled = EquipmentEngine.MakeRoomForDrop(state, item, events, not (options and options.requireInventory))
    local definition = Catalog.GetEquipmentDefinition(item.equipmentId)
    local icon = definition and definition.icon or ""
    if not hasRoom then
        if handled == "consumed" or handled == "overflow" then
            events[#events + 1] = PlayerTransition.Event("loot_dropped", {
                itemId = item.id,
                equipmentId = item.equipmentId,
                rarity = item.rarity,
                icon = icon,
                source = source,
                tradeable = item.tradeable == true,
            })
            events[#events + 1] = PlayerTransition.Event("loot_settled", {
                itemId = item.id,
                outcome = handled == "overflow" and "temporary_box" or "auto_disposed",
            })
            return true, handled == "overflow" and item or nil, handled == "overflow"
        end
        return false, nil, false
    end
    state.inventory[#state.inventory + 1] = item
    if not options or options.trackInLootStash ~= false then
        InventoryState.AddToLootStash(state, item.id)
    end
    events[#events + 1] = PlayerTransition.Event("equipment_drop", {
        itemId = item.id,
        equipmentId = item.equipmentId,
        name = definition and definition.name or "未知装备",
        rarity = item.rarity or (definition and definition.rarity) or "common",
        level = item.level,
        slot = item.slot or (definition and definition.slot) or "",
        source = source,
        aidLocked = item.aidLocked == true,
        tradeable = item.tradeable == true,
    })
    events[#events + 1] = PlayerTransition.Event("loot_dropped", {
        itemId = item.id,
        equipmentId = item.equipmentId,
        rarity = item.rarity,
        icon = icon,
        level = item.level,
        source = source,
        tradeable = item.tradeable == true,
    })
    events[#events + 1] = PlayerTransition.Event("loot_settled", {
        itemId = item.id,
        outcome = "inventory",
    })
    return true, item, true
end

local function serverDayKey(now)
    return math.floor((PlayerTransition.Now(now) + 8 * 60 * 60) / (24 * 60 * 60))
end

local function claimDailyVip(inputState, source, now)
    if source ~= "signIn" and source ~= "ad" then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "unknown VIP daily source")
    end
    local working = PlayerTransition.Copy(inputState, now)
    working.dailyVip = type(working.dailyVip) == "table"
        and working.dailyVip or { signInDay = 0, adDay = 0 }
    local dayKey = serverDayKey(now)
    local field = source == "signIn" and "signInDay" or "adDay"
    if working.dailyVip[field] == dayKey then
        return PlayerTransition.Failure(inputState, now, "DAILY_VIP_ALREADY_CLAIMED",
            source == "signIn" and "今日已签到" or "今日广告奖励已领取")
    end
    if working.vipLevel >= Catalog.MAX_VIP_LEVEL then
        return PlayerTransition.Failure(inputState, now, "VIP_LEVEL_MAX", "VIP 已达到 V10")
    end
    working.dailyVip[field] = dayKey
    working.vipLevel = math.min(Catalog.MAX_VIP_LEVEL, working.vipLevel + 1)
    local events = { PlayerTransition.Event("vip_level_up", {
        source = source,
        vipLevel = working.vipLevel,
        dayKey = dayKey,
    }) }
    print(string.format("[VIP] source=%s day=%d level=%d",
        source, dayKey, working.vipLevel))
    return PlayerTransition.Finalize(inputState, working, now, "vip_daily_claimed", events, false, false)
end

function RewardEngine.ClaimDailySignInVip(inputState, now)
    return claimDailyVip(inputState, "signIn", now)
end

function RewardEngine.ClaimDailyAdVip(inputState, now)
    return claimDailyVip(inputState, "ad", now)
end

function RewardEngine.ClaimLootStash(inputState, now)
    local working = PlayerTransition.Copy(inputState, now)
    local count = #(working.lootStash or {})
    if count == 0 then
        return PlayerTransition.NoCommit(inputState, now, "loot_stash_empty")
    end
    working.lootStash = {}
    return PlayerTransition.Finalize(inputState, working, now, "loot_stash_claimed", {
        PlayerTransition.Event("loot_stash_claimed", { count = count }),
    }, false, false)
end

function RewardEngine.TouchActive(inputState, now)
    now = PlayerTransition.Now(now)
    local working = PlayerTransition.Copy(inputState, now)
    if now <= working.lastActiveAt then
        return PlayerTransition.NoCommit(inputState, now, "active_unchanged")
    end
    return PlayerTransition.Finalize(inputState, working, now, "active_touched", {
        PlayerTransition.Event("active_touched", { lastActiveAt = now }),
    }, false, false)
end

function RewardEngine.AccrueOffline(inputState, now)
    now = PlayerTransition.Now(now)
    local working = PlayerTransition.Copy(inputState, now)
    local elapsed = math.max(0, now - working.lastActiveAt)
    if elapsed == 0 then
        return PlayerTransition.NoCommit(inputState, now, "offline_unchanged")
    end
    local before = working.pendingOfflineSeconds
    working.pendingOfflineSeconds = math.min(Catalog.OFFLINE_MAX_SECONDS, before + elapsed)
    return PlayerTransition.Finalize(inputState, working, now, "offline_accrued", {
        PlayerTransition.Event("offline_accrued", {
            elapsedSeconds = elapsed,
            creditedSeconds = working.pendingOfflineSeconds - before,
            capped = working.pendingOfflineSeconds >= Catalog.OFFLINE_MAX_SECONDS,
        }),
    }, false, false, true)
end

RewardEngine.PrepareLogin = RewardEngine.AccrueOffline

local function registerOfflineEquipment(summary, value)
    local itemId = tostring(value.itemId or "")
    local existing = summary.equipmentById[itemId]
    if existing then
        if value.icon and value.icon ~= "" then existing.icon = value.icon end
        if value.name and value.name ~= "" then existing.name = value.name end
        return existing
    end
    local groupKey = table.concat({
        tostring(value.equipmentId or "unknown"),
        tostring(value.rarity or "common"),
        tostring(value.level or 1),
    }, ":")
    local item = summary.equipmentGroups[groupKey]
    if not item then
        item = {
            equipmentId = value.equipmentId,
            name = value.name,
            rarity = value.rarity or "common",
            level = value.level or 1,
            slot = value.slot,
            icon = value.icon,
            quantity = 0,
        }
        summary.equipmentGroups[groupKey] = item
        summary.equipmentItems[#summary.equipmentItems + 1] = item
    end
    item.quantity = item.quantity + 1
    summary.equipment = summary.equipment + 1
    if itemId ~= "" then summary.equipmentById[itemId] = item end
    return item
end

local function accumulateOfflineEvent(summary, value)
    if value.kind == "battle_reward" then
        summary.gold = LargeNumber.Add(summary.gold, value.gold or 0)
        summary.exp = summary.exp + (value.exp or 0)
    elseif value.kind == "chest_reward" then
        summary.gold = LargeNumber.Add(summary.gold, value.gold or 0)
        summary.fragments = summary.fragments + (value.fragments or 0)
    elseif value.kind == "merchant_trade" or value.kind == "abyss_echo" then
        summary.fragments = summary.fragments + (value.fragments or 0)
    elseif value.kind == "wish_pool" then
        summary.gold = LargeNumber.Add(summary.gold, value.gold or 0)
    elseif value.kind == "equipment_auto_disposed" then
        summary.gold = LargeNumber.Add(summary.gold, value.gold or 0)
        summary.fragments = summary.fragments + (value.fragments or 0)
    elseif value.kind == "equipment_drop" then
        registerOfflineEquipment(summary, value)
    elseif value.kind == "loot_dropped" then
        local item = summary.equipmentById[tostring(value.itemId or "")]
        if item and value.icon and value.icon ~= "" then item.icon = value.icon end
    end
end

-- 离线期间无人操作，交互事件按"超时默认跳过"处理：不产出金币也不产出掉落。
local function offlineEncounterKind(floor, room)
    local encounter = TowerRules.GetEncounter(room, floor)
    if encounter and encounter.isInteractive then return nil end
    if room <= TowerRules.NORMAL_ENCOUNTERS then return "normal" end
    if room <= TowerRules.NORMAL_ENCOUNTERS + TowerRules.ELITE_ENCOUNTERS then return "elite" end
    return floor % 10 == 0 and "chapterBoss" or "boss"
end

local function offlineEncounterCounts(floor, position, cycles)
    local counts = { normal = 0, elite = 0, boss = 0, chapterBoss = 0 }
    local fullRounds = math.floor(cycles / TowerRules.ENCOUNTERS_PER_FLOOR)
    for room = 1, TowerRules.ENCOUNTERS_PER_FLOOR do
        local kind = offlineEncounterKind(floor, room)
        if kind then counts[kind] = counts[kind] + fullRounds end
    end
    local remainder = cycles - fullRounds * TowerRules.ENCOUNTERS_PER_FLOOR
    for offset = 1, remainder do
        local room = (math.max(0, position) + offset - 1)
            % TowerRules.ENCOUNTERS_PER_FLOOR + 1
        local kind = offlineEncounterKind(floor, room)
        if kind then counts[kind] = counts[kind] + 1 end
    end
    return counts
end

local function pickOfflineDropKind(counts, rng)
    local totalWeight = 0
    for _, kind in ipairs({ "normal", "elite", "boss", "chapterBoss" }) do
        totalWeight = totalWeight + (counts[kind] or 0) * RewardPolicy.DropChance(kind, true)
    end
    if totalWeight <= 0 then return "normal" end
    local threshold = DomainMath.RandomFloat(rng) * totalWeight
    local accumulated = 0
    for _, kind in ipairs({ "normal", "elite", "boss", "chapterBoss" }) do
        accumulated = accumulated + (counts[kind] or 0) * RewardPolicy.DropChance(kind, true)
        if threshold < accumulated then return kind end
    end
    return "normal"
end

local function offlineAverageReward(floor, kind)
    local multiplier = kind == "chapterBoss" and 10
        or (kind == "boss" and 10 or (kind == "elite" and 2.3 or 1))
    local baseExp = math.floor((floor * 5 + 10) * multiplier * Catalog.OFFLINE_REWARD_RATE)
    local baseGold = LargeNumber.MultiplyScalar(
        Catalog.GetBattleGold(floor, kind),
        Catalog.OFFLINE_REWARD_RATE
    )
    return baseGold, baseExp
end

local function offlinePityAfterMisses(pity, misses, floor)
    pity = type(pity) == "table" and pity or {}
    local result = {
        epicMisses = math.min(RewardPolicy.EPIC_HARD_PITY_ATTEMPT,
            math.max(0, TableUtils.ToInteger(pity.epicMisses or pity.epic, 0)) + misses),
        mythMisses = math.min(RewardPolicy.MYTH_HARD_PITY_ATTEMPT,
            math.max(0, TableUtils.ToInteger(pity.mythMisses or pity.myth, 0)) + misses),
    }
    if floor < RarityCatalog.Get("epic").unlockFloor then result.epicMisses = 0 end
    if floor < RarityCatalog.Get("myth").unlockFloor then result.mythMisses = 0 end
    return result
end

local function simulateOfflineCollection(inputState, now, rng)
    now = PlayerTransition.Now(now)
    local working = PlayerTransition.Copy(inputState, now)
    local floor = math.max(1, TableUtils.ToInteger(working.floor, 1))
    local seconds = math.min(working.pendingOfflineSeconds, Catalog.OFFLINE_MAX_SECONDS)
    local cycles = math.floor(seconds / Catalog.OFFLINE_STEP_SECONDS)
    if cycles <= 0 then
        return nil, "NO_OFFLINE_REWARD", "offline reward requires at least "
            .. tostring(Catalog.OFFLINE_STEP_SECONDS) .. " seconds"
    end

    local position = math.max(0, TableUtils.ToInteger(working.position, 0))
    local encounterCounts = offlineEncounterCounts(floor, position, cycles)
    local summary = {
        gold = LargeNumber.Zero(),
        exp = 0,
        fragments = 0,
        equipment = 0,
        equipmentItems = {},
        equipmentById = {},
        equipmentGroups = {},
    }
    local expectedDrops = 0
    for _, kind in ipairs({ "normal", "elite", "boss", "chapterBoss" }) do
        local count = encounterCounts[kind] or 0
        local gold, exp = offlineAverageReward(floor, kind)
        summary.gold = LargeNumber.Add(
            summary.gold,
            LargeNumber.MultiplyScalar(gold, count)
        )
        summary.exp = summary.exp + count * exp
        expectedDrops = expectedDrops + count * (RewardPolicy.DropChance(kind, true) or 0)
    end
    local events = {}
    if not LargeNumber.IsZero(summary.gold) then
        PlayerTransition.AddCurrency(working, "gold", summary.gold)
    end
    if summary.exp > 0 then addExp(working, summary.exp, events) end
    events[#events + 1] = PlayerTransition.Event("battle_reward", {
        gold = summary.gold,
        exp = summary.exp,
        rewardRate = Catalog.OFFLINE_REWARD_RATE,
        offline = true,
        batch = true,
        cycles = cycles,
        floor = floor,
    })

    local dropCount = math.floor(expectedDrops)
    if DomainMath.RandomFloat(rng) < expectedDrops - dropCount then dropCount = dropCount + 1 end
    local availableSlots = math.max(0, Catalog.INVENTORY_CAP - #working.inventory)
    local generatedDrops = math.min(dropCount, availableSlots)
    local generatedChapterDrops = 0
    local generatedChapterRarities = {}

    for _ = 1, generatedDrops do
        local kind = pickOfflineDropKind(encounterCounts, rng)
        local rarity = RewardPolicy.RollRarity(
            kind,
            floor,
            DomainMath.RandomFloat(rng),
            working.rewardPity)
        local weakSlots = {}
        local powerRatio = tonumber(working.stats and working.stats.powerRatio) or 0
        if powerRatio < 1 then
            local weakRanked = EquipmentEngine.WeakestEquipmentSlots(working)
            for index = 1, math.min(3, #weakRanked) do weakSlots[index] = weakRanked[index].slot end
        end
        local allSlots = {}
        for index, slot in ipairs(Catalog.SLOTS) do allSlots[index] = slot.id end
        local options = {
            floor = floor,
            trackInLootStash = false,
            rollTradeable = true,
            slot = RewardPolicy.PickDropSlot(
                allSlots,
                weakSlots,
                DomainMath.RandomFloat(rng),
                DomainMath.RandomFloat(rng)
            ),
        }
        local source = kind == "chapterBoss" and "chapter_boss_drop"
            or (kind == "boss" and "boss_drop" or (kind == "elite" and "elite_drop" or "monster_drop"))
        local dropEvents = {}
        local added = addGeneratedDrop(
            working,
            rarity,
            kind == "boss" or kind == "chapterBoss",
            rng,
            now,
            source,
            dropEvents,
            options
        )
        if added then
            if kind == "chapterBoss" then
                generatedChapterDrops = generatedChapterDrops + 1
                generatedChapterRarities[#generatedChapterRarities + 1] = rarity
            end
            for _, dropEvent in ipairs(dropEvents) do
                accumulateOfflineEvent(summary, dropEvent)
            end
        end
    end
    local _, boundOnOptimize = EquipmentEngine.OptimizeLoadout(working, now, events)

    local bossCycles = encounterCounts.chapterBoss or 0
    local missedBossCycles = math.max(0, bossCycles - generatedChapterDrops)
    if floor % 10 == 0 and missedBossCycles > 0 then
        working.rewardPity = offlinePityAfterMisses(working.rewardPity, missedBossCycles, floor)
        events[#events + 1] = PlayerTransition.Event("reward_pity_updated", {
            epicMisses = working.rewardPity.epicMisses,
            mythMisses = working.rewardPity.mythMisses,
            batch = true,
        })
    end
    for _, rarity in ipairs(generatedChapterRarities) do
        working.rewardPity = RewardPolicy.UpdatePity(working.rewardPity, rarity)
    end

    working.pendingOfflineSeconds = math.max(0,
        seconds - cycles * Catalog.OFFLINE_STEP_SECONDS)
    working.currentMonster = nil
    working.position = (position + cycles) % TowerRules.ENCOUNTERS_PER_FLOOR
    working.floorKillBonus = working.position * 0.01
    working.pauseReason = generatedDrops < dropCount and "inventory_full" or nil
    if generatedDrops < dropCount then working.autoRun = false end
    PlayerTransition.RefreshDerived(working)

    local processedSeconds = cycles * Catalog.OFFLINE_STEP_SECONDS
    local reward = {
        seconds = seconds,
        processedSeconds = processedSeconds,
        remainingSeconds = working.pendingOfflineSeconds,
        rewardRate = Catalog.OFFLINE_REWARD_RATE,
        gold = summary.gold,
        exp = summary.exp,
        fragments = summary.fragments,
        equipment = summary.equipment,
        equipmentItems = summary.equipmentItems,
        floor = floor,
        fixedFloor = true,
        interrupted = generatedDrops < dropCount,
        droppedEquipment = dropCount,
        generatedEquipment = generatedDrops,
        discardedEquipment = dropCount - generatedDrops,
    }
    events[#events + 1] = PlayerTransition.Event("offline_collected", TableUtils.DeepCopy(reward))
    return {
        working = working,
        events = events,
        inventoryChanged = generatedDrops > 0 or boundOnOptimize,
        reward = reward,
        storyGate = false,
    }
end

-- 登录时冻结离线收益。账本只记录离线通道产出，不保存整体角色快照，
-- 因此上线后的在线战斗与离线奖励互不影响。
function RewardEngine.FreezeOfflineReward(inputState, now, rng)
    local simulation, code, reason = simulateOfflineCollection(inputState, now, rng)
    if not simulation then return nil, code, reason end

    local existing = {}
    for _, item in ipairs(inputState.inventory or {}) do existing[tostring(item.id)] = true end
    for _, item in ipairs(inputState.overflowLoot or {}) do existing[tostring(item.id)] = true end

    local items = {}
    for _, item in ipairs(simulation.working.inventory or {}) do
        if not existing[tostring(item.id)] then items[#items + 1] = TableUtils.DeepCopy(item) end
    end
    for _, item in ipairs(simulation.working.overflowLoot or {}) do
        if not existing[tostring(item.id)] then items[#items + 1] = TableUtils.DeepCopy(item) end
    end

    local reward = TableUtils.DeepCopy(simulation.reward)
    return {
        seconds = reward.processedSeconds or 0,
        gold = reward.gold or LargeNumber.Zero(),
        exp = reward.exp or 0,
        fragments = reward.fragments or 0,
        items = items,
        rewardPity = TableUtils.DeepCopy(simulation.working.rewardPity),
        reward = reward,
    }
end

-- 将冻结账本增量合并到最新权威状态，不覆盖在线收益。
function RewardEngine.ClaimOfflineReward(inputState, ledger, now)
    now = PlayerTransition.Now(now)
    if type(ledger) ~= "table" or type(ledger.reward) ~= "table" then
        return PlayerTransition.Failure(inputState, now, "INVALID_OFFLINE_QUOTE", "offline reward ledger is invalid")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local consumed = math.max(0, TableUtils.ToInteger(ledger.seconds, 0))
    if consumed <= 0
        or math.max(0, TableUtils.ToInteger(working.pendingOfflineSeconds, 0)) < consumed
    then
        return PlayerTransition.Failure(inputState, now, "NO_OFFLINE_REWARD", "offline reward was already collected")
    end
    working.pendingOfflineSeconds = working.pendingOfflineSeconds - consumed

    local events = {}
    if not LargeNumber.IsZero(ledger.gold) then
        PlayerTransition.AddCurrency(working, "gold", ledger.gold)
    end
    if (ledger.fragments or 0) > 0 then
        PlayerTransition.AddCurrency(working, "fragments", ledger.fragments)
    end
    if (ledger.exp or 0) > 0 then
        addExp(working, ledger.exp, events)
    end

    working.overflowLoot = working.overflowLoot or {}
    local used = {}
    for _, item in ipairs(working.inventory) do used[tostring(item.id)] = true end
    for _, item in ipairs(working.overflowLoot) do used[tostring(item.id)] = true end

    local stored, overflowed = 0, 0
    for _, source in ipairs(ledger.items or {}) do
        local item = TableUtils.DeepCopy(source)
        if used[tostring(item.id)] then item.id = allocateItemId(working) end
        used[tostring(item.id)] = true
        InventoryState.RecordCollection(working, item)
        if #working.inventory < Catalog.INVENTORY_CAP then
            working.inventory[#working.inventory + 1] = item
            InventoryState.AddToLootStash(working, item.id)
            stored = stored + 1
        else
            working.overflowLoot[#working.overflowLoot + 1] = item
            overflowed = overflowed + 1
        end
    end
    if ledger.rewardPity then
        working.rewardPity = TableUtils.DeepCopy(ledger.rewardPity)
    end

    local reward = TableUtils.DeepCopy(ledger.reward)
    reward.processedSeconds = consumed
    reward.remainingSeconds = working.pendingOfflineSeconds
    reward.interrupted = overflowed > 0
    reward.generatedEquipment = stored
    reward.discardedEquipment = overflowed
    events[#events + 1] = PlayerTransition.Event("offline_collected", reward)

    PlayerTransition.RefreshDerived(working)
    return PlayerTransition.Finalize(
        inputState,
        working,
        now,
        "offline_collected",
        events,
        stored > 0 or overflowed > 0,
        false
    )
end

function RewardEngine.GrantCurrency(inputState, currency, amount, now)
    if currency ~= "gold" and currency ~= "fragments" then
        return PlayerTransition.Failure(inputState, now, "INVALID_CURRENCY", "currency is not grantable")
    end
    amount = TableUtils.ToInteger(amount, 0)
    if amount <= 0 or amount > 1000000000 then
        return PlayerTransition.Failure(inputState, now, "INVALID_AMOUNT", "amount must be positive and within the grant limit")
    end
    local working = PlayerTransition.Copy(inputState, now)
    PlayerTransition.AddCurrency(working, currency, amount)
    return PlayerTransition.Finalize(inputState, working, now, "currency_granted", {
        PlayerTransition.Event("currency_granted", { currency = currency, amount = amount }),
    }, false, false)
end

function RewardEngine.GrantEquipment(inputState, specification, now)
    if type(specification) ~= "table" then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "equipment specification is required")
    end
    local definition = Catalog.GetEquipmentDefinition(specification.equipmentId)
    if not definition then
        return PlayerTransition.Failure(inputState, now, "INVALID_EQUIPMENT", "unknown equipment definition")
    end
    if specification.slot ~= nil and specification.slot ~= definition.slot then
        return PlayerTransition.Failure(inputState, now, "INVALID_SLOT", "equipment slot does not match definition")
    end
    local working = PlayerTransition.Copy(inputState, now)
    local level = Catalog.Clamp(TableUtils.ToInteger(specification.level, working.floor), 1, 1000000)
    local enhance = Catalog.Clamp(TableUtils.ToInteger(specification.enhance, 0), 0, 1000)
    local star = Catalog.Clamp(TableUtils.ToInteger(specification.star, 0), 0, Catalog.MAX_STAR)
    local rarity = RarityCatalog.NormalizeId(specification.rarity or definition.rarity)
    local actual = Catalog.CreateItemStats(
        definition,
        level,
        rarity,
        tonumber(specification.roll) or 1,
        enhance,
        star
    )
    local atkBig = DomainMath.Magnitude(specification.atkBig, specification.atk, actual.atkBig)
    local defBig = DomainMath.Magnitude(specification.defBig, specification.def, actual.defBig)
    local hpBig = DomainMath.Magnitude(specification.hpBig, specification.hp, actual.hpBig)
    local item = {
        id = allocateItemId(working),
        equipmentId = definition.id,
        name = definition.name,
        slot = definition.slot,
        category = definition.category,
        level = level,
        enhance = enhance,
        star = star,
        rarity = rarity,
        setEnabled = actual.setEnabled == true,
        setId = actual.setId,
        statVersion = 5,
        roll = actual.roll,
        budget = actual.budget,
        budgetBig = actual.budgetBig,
        atk = DomainMath.ProjectedMagnitude(atkBig),
        def = DomainMath.ProjectedMagnitude(defBig),
        hp = DomainMath.ProjectedMagnitude(hpBig),
        atkBig = atkBig,
        defBig = defBig,
        hpBig = hpBig,
        crit = tonumber(specification.crit) or actual.crit,
        critDmg = tonumber(specification.critDmg) or actual.critDmg,
        atkSpeed = tonumber(specification.atkSpeed) or actual.atkSpeed,
        lifeSteal = tonumber(specification.lifeSteal) or actual.lifeSteal,
        damageReduction = tonumber(specification.damageReduction) or actual.damageReduction,
        bossDamage = tonumber(specification.bossDamage) or actual.bossDamage,
        coreAffixes = {},
        locked = specification.locked == true,
        acquiredAt = PlayerTransition.Now(now),
        source = "admin_grant",
        investedGold = LargeNumber.Zero(),
        investedFragments = 0,
    }
    local events = {}
    InventoryState.RecordCollection(working, item)
    local hasRoom, handled = EquipmentEngine.MakeRoomForDrop(working, item, events)
    if not hasRoom then
        if handled then
            return PlayerTransition.Finalize(inputState, working, now, "equipment_auto_disposed", events, false, false)
        end
        return PlayerTransition.Failure(inputState, now, "INVENTORY_FULL", "inventory is full", {
            PlayerTransition.Event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
        })
    end
    item.power = Catalog.GetItemPower(item)
    working.inventory[#working.inventory + 1] = item
    PlayerTransition.RefreshDerived(working)
    if #working.inventory >= Catalog.INVENTORY_CAP and working.inventoryPolicy.pauseOnFull and not EquipmentEngine.HasAutoDispositionPolicy(working) then
        working.autoRun = false
        working.pauseReason = "inventory_full"
    end
    events[#events + 1] = PlayerTransition.Event("equipment_granted", {
        itemId = item.id,
        equipmentId = item.equipmentId,
        rarity = item.rarity,
        slot = definition.slot,
    })
    return PlayerTransition.Finalize(inputState, working, now, "equipment_granted", events, true, false)
end

RewardEngine.AddExp = addExp
RewardEngine.AddGeneratedDrop = addGeneratedDrop

return RewardEngine
