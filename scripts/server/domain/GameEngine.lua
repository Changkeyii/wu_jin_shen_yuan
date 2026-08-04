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

local GameEngine = {}
local weakestEquipmentSlots
local maybeQueueStoryGate
local storyGateEvent

local SCALAR_DELTA_FIELDS = {
    "pendingOfflineSeconds",
    "level",
    "exp",
    "nextExp",
    "floor",
    "maxFloor",
    "position",
    "transitionRemaining",
    "gold",
    "fragments",
    "mythShards",
    "autoRun",
    "pauseReason",
    "hp",
    "hpBig",
    "floorDefeats",
    "aidPending",
    "aidGrantedFloors",
    "floorKillBonus",
    "permanentBonus",
    "inventoryPolicy",
    "automationPolicy",
    "interactionMode",
    "storyProgress",
    "pendingStoryGate",
    "ruleAcknowledgements",
    "pendingEquipDecision",
    "previousLoadout",
    "rewardPity",
    "currentMonster",
    "currentEvent",
    "lootStash",
}

local function addCurrency(state, currency, amount)
    state[currency] = LargeNumber.Add(state[currency], amount)
end

local function spendCurrency(state, currency, amount)
    local nextValue, ok = LargeNumber.Subtract(state[currency], amount)
    if not ok then return false end
    state[currency] = nextValue
    return true
end

local function hasCurrency(state, currency, amount)
    return LargeNumber.Compare(state[currency], amount) >= 0
end

local function nowInteger(now)
    return math.max(0, TableUtils.ToInteger(now, os.time()))
end

local function stateCopy(state, now)
    return StateNormalizer.Normalize(TableUtils.DeepCopy(state), nowInteger(now))
end

local function event(kind, fields)
    local value = fields or {}
    value.kind = kind
    return value
end

local function magnitude(bigValue, numberValue, fallback)
    if BigNumber.IsBigNumber(bigValue) then return BigNumber.Normalize(bigValue) end
    if BigNumber.IsBigNumber(numberValue) then return BigNumber.Normalize(numberValue) end
    if type(numberValue) == "number" and numberValue == numberValue
        and numberValue ~= math.huge and numberValue ~= -math.huge and numberValue >= 0
    then
        return BigNumber.FromNumber(numberValue)
    end
    return BigNumber.Clone(fallback or BigNumber.Zero())
end

local function projectedMagnitude(value)
    return BigNumber.ToNumber(value)
end

local function floorDamage(value)
    return BigNumber.Max(BigNumber.Floor(value), BigNumber.FromNumber(1))
end

local function statMagnitude(stats, field)
    stats = type(stats) == "table" and stats or {}
    return magnitude(stats[field .. "Big"], stats[field], 0)
end

local function setPlayerHp(state, value)
    state.hpBig = BigNumber.Clone(value)
    state.hp = projectedMagnitude(state.hpBig)
end

local function setMonsterMagnitude(monster, field, value)
    monster[field .. "Big"] = BigNumber.Clone(value)
    monster[field] = projectedMagnitude(value)
end

local function addMagnitudeFields(payload, field, bigField, value)
    payload[field] = projectedMagnitude(value)
    payload[bigField] = BigNumber.Clone(value)
    return payload
end

local function displayedPowerDelta(before, after)
    local oldPower = magnitude(
        before and before.displayedPower,
        before and before.displayedPowerNumber,
        0)
    local newPower = magnitude(
        after and after.displayedPower,
        after and after.displayedPowerNumber,
        oldPower)
    return BigNumber.Subtract(newPower, oldPower)
end

local function multiplyItemMagnitude(item, field, scalar)
    local value = BigNumber.MultiplyScalar(
        magnitude(item[field .. "Big"], item[field], 0), scalar)
    item[field .. "Big"] = value
    item[field] = projectedMagnitude(value)
end

local function randomInt(rng, minimum, maximum)
    local value
    if type(rng) == "table" and type(rng.Int) == "function" then
        value = rng:Int(minimum, maximum)
    elseif type(rng) == "table" and type(rng.NextInt) == "function" then
        value = rng:NextInt(minimum, maximum)
    elseif type(rng) == "function" then
        value = rng(minimum, maximum)
    else
        value = math.random(minimum, maximum)
    end
    value = TableUtils.ToInteger(value, minimum)
    return Catalog.Clamp(value, minimum, maximum)
end

local function randomFloat(rng)
    local value
    if type(rng) == "table" and type(rng.Float) == "function" then
        value = rng:Float()
    elseif type(rng) == "table" and type(rng.NextFloat) == "function" then
        value = rng:NextFloat()
    elseif type(rng) == "function" then
        value = rng()
    else
        value = math.random()
    end
    if not TableUtils.IsFiniteNumber(value) then
        value = 0
    end
    return Catalog.Clamp(value, 0, 0.999999999)
end

local function recordEquipmentCollection(state, item)
    if not item or not item.equipmentId then return end
    state.equipmentCollection = state.equipmentCollection or {}
    local powerBig = BigNumber.Normalize(Catalog.GetItemPower(item))
    local record = state.equipmentCollection[item.equipmentId]
    if not record or BigNumber.Compare(powerBig, record.powerBig) > 0 then
        state.equipmentCollection[item.equipmentId] = {
            powerBig = powerBig,
            level = item.level,
            enhance = item.enhance,
            star = item.star,
            rarity = item.rarity,
        }
    end
end

local function updateEquipmentCollection(state)
    for _, item in ipairs(state.inventory or {}) do recordEquipmentCollection(state, item) end
    for _, item in ipairs(state.overflowLoot or {}) do recordEquipmentCollection(state, item) end
end

local function removeFromLootStash(state, itemId)
    local kept = {}
    for _, value in ipairs(state.lootStash or {}) do
        if tostring(value) ~= tostring(itemId) then kept[#kept + 1] = value end
    end
    state.lootStash = kept
end

local function addToLootStash(state, itemId)
    if itemId == nil then return end
    state.lootStash = state.lootStash or {}
    removeFromLootStash(state, itemId)
    state.lootStash[#state.lootStash + 1] = itemId
    while #state.lootStash > GameStateSchema.LOOT_STASH_CAP do table.remove(state.lootStash, 1) end
end

local function pruneLootStash(state)
    local existing = {}
    for _, item in ipairs(state.inventory or {}) do existing[tostring(item.id)] = true end
    local kept = {}
    for _, itemId in ipairs(state.lootStash or {}) do
        if existing[tostring(itemId)] then kept[#kept + 1] = itemId end
    end
    state.lootStash = kept
end

local function refreshDerived(state, combatOnly)
    local previousMaximum = state.stats and (state.stats.hpBig or state.stats.hp) or 1
    local previousHp = magnitude(state.hpBig, state.hp, previousMaximum)
    for _, item in ipairs(state.inventory) do
        item.power = Catalog.GetItemPower(item)
    end
    for _, item in ipairs(state.overflowLoot or {}) do item.power = Catalog.GetItemPower(item) end
    updateEquipmentCollection(state)
    state.nextExp = Catalog.NextExp(state.level)
    local previousStats = state.stats or {}
    state.stats = Catalog.CalculateStats(state, combatOnly and { skipPowerEvaluation = true } or nil)
    if combatOnly then
        for _, field in ipairs({
            "power", "displayedPower", "recommendedPower", "nextChapterRecommendedPower",
            "powerRatio", "headroomFloors", "difficultyLabel", "equivalentFloor",
            "estimatedEasyFloor", "towerScore", "bossScore", "eliteScore", "dpsSafe", "ehp",
        }) do
            state.stats[field] = previousStats[field]
        end
    end
    state.setProgress = TableUtils.DeepCopy(state.stats.setProgress or {})
    setPlayerHp(state, BigNumber.Min(previousHp, statMagnitude(state.stats, "hp")))
    if state.currentMonster then
        state.currentEvent = state.currentMonster.eventType
    else
        state.currentEvent = Catalog.GetCellType(math.max(1, state.position), state.floor)
    end
end

local function buildCommit(previousRevision, state)
    local persisted = StateNormalizer.ToPersisted(state)
    return {
        kind = "BatchCommit",
        expectedRevision = previousRevision,
        revision = persisted.revision,
        scores = {
            abyss_schema_version = persisted.schemaVersion,
            abyss_revision = persisted.revision,
            abyss_updated_at = persisted.updatedAt,
            abyss_last_active_at = persisted.lastActiveAt,
            abyss_pending_offline_seconds = persisted.pendingOfflineSeconds,
            abyss_level = persisted.level,
            abyss_exp = persisted.exp,
            abyss_floor = persisted.floor,
            abyss_max_floor = persisted.maxFloor,
            abyss_position = persisted.position,
            abyss_auto_run = persisted.autoRun and 1 or 0,
            abyss_pause_reason = persisted.pauseReason == "inventory_full" and 1 or 0,
            abyss_hp = persisted.hp,
            abyss_floor_kill_bonus = persisted.floorKillBonus,
            abyss_permanent_bonus = persisted.permanentBonus,
            abyss_next_item_id = persisted.nextItemId,
        },
        money = {},
        lists = {
            abyss_inventory = persisted.inventory,
            abyss_equipped = persisted.equipped,
        },
        items = {
            abyss_health_potion = persisted.consumables.healthPotion or 0,
        },
    }
end

local function buildDelta(previous, current, kind, events, inventoryChanged, equippedChanged)
    local changed = {}
    for _, field in ipairs(SCALAR_DELTA_FIELDS) do
        if not TableUtils.DeepEqual(previous[field], current[field]) then
            if field == "pauseReason" and current[field] == nil then
                changed[field] = ""
            else
                changed[field] = current[field]
            end
        end
    end
    if not TableUtils.DeepEqual(previous.stats, current.stats) then
        changed.stats = TableUtils.DeepCopy(current.stats)
    end
    if not TableUtils.DeepEqual(previous.consumables, current.consumables) then
        changed.consumables = TableUtils.DeepCopy(current.consumables)
    end

    local delta = {
        kind = "GameDelta",
        operation = kind,
        schemaVersion = Catalog.SCHEMA_VERSION,
        revision = current.revision,
        updatedAt = current.updatedAt,
        changed = changed,
        changes = changed,
        events = TableUtils.DeepCopy(events or {}),
        inventoryCount = #current.inventory,
        inventoryChanged = inventoryChanged == true,
        equippedChanged = equippedChanged == true,
    }
    if inventoryChanged then
        changed.inventory = TableUtils.DeepCopy(current.inventory)
        changed.equipped = TableUtils.DeepCopy(current.equipped)
        changed.consumables = TableUtils.DeepCopy(current.consumables)
    end
    if equippedChanged then
        changed.equipped = TableUtils.DeepCopy(current.equipped)
    end
    return delta
end

local function finalize(inputState, workingState, now, kind, events, inventoryChanged, equippedChanged, combatOnly)
    now = nowInteger(now)
    local previous = stateCopy(inputState, now)
    workingState.revision = previous.revision + 1
    workingState.updatedAt = now
    workingState.lastActiveAt = now
    workingState = StateNormalizer.Normalize(workingState, now)
    refreshDerived(workingState, combatOnly == true)
    return {
        ok = true,
        state = workingState,
        delta = buildDelta(previous, workingState, kind, events, inventoryChanged, equippedChanged),
        commit = buildCommit(previous.revision, workingState),
    }
end

local function noCommit(inputState, now, kind, events)
    local copy = stateCopy(inputState, now)
    local changed = {}
    return {
        ok = true,
        state = copy,
        delta = {
            kind = "GameDelta",
            operation = kind or "noop",
            schemaVersion = Catalog.SCHEMA_VERSION,
            revision = copy.revision,
            updatedAt = copy.updatedAt,
            changed = changed,
            changes = changed,
            events = TableUtils.DeepCopy(events or {}),
            inventoryCount = #copy.inventory,
            inventoryChanged = false,
            equippedChanged = false,
        },
        commit = { kind = "none", expectedRevision = copy.revision },
    }
end

local function failure(inputState, now, code, reason, events)
    local proposal = noCommit(inputState, now, "rejected", events)
    proposal.ok = false
    proposal.error = { code = code, reason = reason }
    return proposal
end

local function findItem(state, itemId)
    return TableUtils.FindById(state.inventory, itemId)
end

local function bindEquipmentOnSuccessfulEquip(item)
    if item and item.tradeable == true then
        item.tradeable = false
        print("[EquipmentTrade] bound after equip itemId=" .. tostring(item.id))
        return true
    end
    return false
end

local function equippedIdSet(state)
    local ids = {}
    for _, itemId in pairs(state.equipped) do
        ids[itemId] = true
    end
    return ids
end

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
        local currentHp = magnitude(state.hpBig, state.hp, 0)
        state.stats = Catalog.CalculateStats(state)
        setPlayerHp(state, BigNumber.Min(currentHp, statMagnitude(state.stats, "hp")))
        events[#events + 1] = event("level_up", {
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
        local affix = table.remove(pool, randomInt(rng, 1, #pool))
        result[#result + 1] = affix
        if affix == "core.fury" then multiplyItemMagnitude(actual, "atk", 1.03)
        elseif affix == "core.guard" then multiplyItemMagnitude(actual, "def", 1.04)
        elseif affix == "core.vitality" then multiplyItemMagnitude(actual, "hp", 1.04)
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
    local definition = candidates[randomInt(rng, 1, #candidates)]
    local itemRoll = options.roll
        and Catalog.Clamp(tonumber(options.roll) or 1, 0.95, 1.05)
        or (randomInt(rng, 9500, 10500) / 10000)
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
            randomFloat(rng)
        )
    end
    local item = {
        id = allocateItemId(state),
        equipmentId = definition.id,
        level = floor,
        enhance = enhance,
        star = star,
        locked = false,
        acquiredAt = nowInteger(now),
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

local function disposeEquipment(state, item, mode)
    if mode == "sell" then
        local gold = Catalog.GetSellValue(item, state.vipLevel)
        addCurrency(state, "gold", gold)
        return { gold = gold, fragments = 0 }
    end
    local refund = Catalog.GetDecomposeRefund(item, state.vipLevel)
    addCurrency(state, "gold", refund.gold)
    addCurrency(state, "fragments", refund.fragments)
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
    if #state.inventory < Catalog.INVENTORY_CAP then return true, false end
    local policy = state.inventoryPolicy or {}
    local mode = autoDispositionEnabled(state, incoming)
    local equipped = equippedIdSet(state)
    local disposalIndex = nil
    if mode then
        local reward = disposeEquipment(state, incoming, mode)
        events[#events + 1] = event("equipment_auto_disposed", {
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
        if not item.locked and not item.aidLocked and not equipped[item.id] and autoDispositionEnabled(state, item) then
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
            events[#events + 1] = event("inventory_full", {
                itemId = incoming.id,
                equipmentId = incoming.equipmentId,
                capacity = Catalog.INVENTORY_CAP,
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
    events[#events + 1] = event("equipment_auto_disposed", {
        itemId = removed.id,
        equipmentId = removed.equipmentId,
        mode = mode,
        gold = reward.gold,
        fragments = reward.fragments,
        incoming = false,
    })
    return true, true
end

local function addGeneratedDrop(state, rarityId, isBoss, rng, now, source, events, options)
    local item = generatedEquipment(state, rarityId, isBoss, rng, now, source, options)
    if not item then return true, nil, false end
    recordEquipmentCollection(state, item)
    local hasRoom, handled = makeRoomForDrop(state, item, events, not (options and options.requireInventory))
    local definition = Catalog.GetEquipmentDefinition(item.equipmentId)
    local icon = definition and definition.icon or ""
    if not hasRoom then
        if handled == "consumed" or handled == "overflow" then
            events[#events + 1] = event("loot_dropped", {
                itemId = item.id,
                equipmentId = item.equipmentId,
                rarity = item.rarity,
                icon = icon,
                source = source,
                tradeable = item.tradeable == true,
            })
            events[#events + 1] = event("loot_settled", {
                itemId = item.id,
                outcome = handled == "overflow" and "temporary_box" or "auto_disposed",
            })
            return true, handled == "overflow" and item or nil, handled == "overflow"
        end
        return false, nil, false
    end
    state.inventory[#state.inventory + 1] = item
    if not options or options.trackInLootStash ~= false then
        addToLootStash(state, item.id)
    end
    events[#events + 1] = event("equipment_drop", {
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
    events[#events + 1] = event("loot_dropped", {
        itemId = item.id,
        equipmentId = item.equipmentId,
        rarity = item.rarity,
        icon = icon,
        level = item.level,
        source = source,
        tradeable = item.tradeable == true,
    })
    events[#events + 1] = event("loot_settled", {
        itemId = item.id,
        outcome = "inventory",
    })
    return true, item, true
end

local function drainOverflowLoot(state, events)
    state.overflowLoot = state.overflowLoot or {}
    local moved = 0
    while #state.inventory < Catalog.INVENTORY_CAP and #state.overflowLoot > 0 do
        local item = table.remove(state.overflowLoot, 1)
        state.inventory[#state.inventory + 1] = item
        addToLootStash(state, item.id)
        moved = moved + 1
        events[#events + 1] = event("loot_settled", {
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
    return addMagnitudeFields(
        payload,
        "displayedPowerDelta",
        "displayedPowerDeltaBig",
        displayedPowerDelta(before.display, after.display))
end

local function considerEquipmentUpgrade(state, item, now, events)
    if not item or item.aidLocked or not findItem(state, item.id) then return false, false end
    local current = findItem(state, state.equipped[item.slot])
    if current and (current.locked or current.aidLocked) then return false, false end
    local before = evaluateLoadout(state, state.equipped, true)
    local candidateEquipped = TableUtils.DeepCopy(state.equipped)
    candidateEquipped[item.slot] = item.id
    local after = evaluateLoadout(state, candidateEquipped, true)
    if not upgradePasses(before, after, RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN) then return false, false end

    local payload = upgradePayload(item, before, after)
    local tradeabilityChanged = false
    if state.automationPolicy and state.automationPolicy.autoEquip then
        state.previousLoadout = {
            equipped = TableUtils.DeepCopy(state.equipped),
            createdAt = nowInteger(now),
            available = true,
        }
        state.equipped = candidateEquipped
        tradeabilityChanged = bindEquipmentOnSuccessfulEquip(item)
        removeFromLootStash(state, item.id)
        state.pendingEquipDecision = nil
        refreshDerived(state)
        payload.automatic = true
        events[#events + 1] = event("equipment_equipped", payload)
    else
        state.pendingEquipDecision = {
            itemId = item.id,
            createdAt = nowInteger(now),
            oldTowerScore = payload.oldTowerScore,
            newTowerScore = payload.newTowerScore,
            oldBossScore = payload.oldBossScore,
            newBossScore = payload.newBossScore,
            displayedPowerDelta = payload.displayedPowerDelta,
            displayedPowerDeltaBig = BigNumber.Clone(payload.displayedPowerDeltaBig),
            headroomDelta = payload.headroomDelta,
        }
        events[#events + 1] = event("equipment_upgrade_available", payload)
    end
    return true, tradeabilityChanged
end

local function optimizeWholeLoadout(state, now, events, force)
    if not force and not (state.automationPolicy and state.automationPolicy.autoEquip) then return false, false end
    local originalEquipped = TableUtils.DeepCopy(state.equipped)
    local original = evaluateLoadout(state, originalEquipped)
    local selected = TableUtils.DeepCopy(originalEquipped)

    for _, slot in ipairs(Catalog.SLOTS) do
        local current = findItem(state, selected[slot.id])
        if not (current and (current.locked or current.aidLocked)) then
            local bestEquipped = selected
            local best = evaluateLoadout(state, selected)
            local candidates = {}
            for _, candidate in ipairs(state.inventory) do
                if candidate.slot == slot.id and not candidate.aidLocked then
                    candidates[#candidates + 1] = candidate
                end
            end
            table.sort(candidates, function(left, right)
                return Catalog.CompareItemPower(left, right) > 0
            end)
            for index = 1, math.min(6, #candidates) do
                local candidate = candidates[index]
                local proposal = TableUtils.DeepCopy(selected)
                proposal[slot.id] = candidate.id
                local evaluated = evaluateLoadout(state, proposal)
                if upgradePasses(best, evaluated, 0)
                    and (tonumber(evaluated.score.towerScore) or 0) > (tonumber(best.score.towerScore) or 0)
                then
                    best = evaluated
                    bestEquipped = proposal
                end
            end
            selected = bestEquipped
        end
    end

    local optimized = evaluateLoadout(state, selected)
    if TableUtils.DeepEqual(selected, originalEquipped)
        or not upgradePasses(original, optimized, RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN)
    then
        return false, false
    end
    state.previousLoadout = {
        equipped = originalEquipped,
        createdAt = nowInteger(now),
        available = true,
    }
    state.equipped = selected
    local tradeabilityChanged = false
    for slotId, itemId in pairs(selected) do
        if originalEquipped[slotId] ~= itemId then
            tradeabilityChanged = bindEquipmentOnSuccessfulEquip(findItem(state, itemId))
                or tradeabilityChanged
        end
        removeFromLootStash(state, itemId)
    end
    state.pendingEquipDecision = nil
    original = evaluateLoadout(state, originalEquipped, true)
    optimized = evaluateLoadout(state, selected, true)
    refreshDerived(state)
    local equippedPayload = {
        automatic = true,
        batch = true,
        changedSlots = true,
        oldTowerScore = original.score.towerScore,
        newTowerScore = optimized.score.towerScore,
        oldBossScore = original.score.bossScore,
        newBossScore = optimized.score.bossScore,
        headroomDelta = (optimized.display.equivalentFloor or 0)
            - (original.display.equivalentFloor or 0),
    }
    addMagnitudeFields(
        equippedPayload,
        "displayedPowerDelta",
        "displayedPowerDeltaBig",
        displayedPowerDelta(original.display, optimized.display))
    events[#events + 1] = event("equipment_equipped", equippedPayload)
    return true, tradeabilityChanged
end

local function encounterFor(room, floor, explicitType)
    room = Catalog.Clamp(TableUtils.ToInteger(room, 1), 1, 10)
    floor = math.max(1, TableUtils.ToInteger(floor, 1))
    local encounter = TowerRules.GetEncounter(room, floor) or {}
    local kind = encounter.kind or encounter.eventType
    if explicitType == "monster" or explicitType == "normal" then kind = "normal" end
    if explicitType == "elite" then kind = "elite" end
    if explicitType == "chapterBoss" then kind = "chapterBoss" end
    if explicitType == "boss" then kind = floor % 10 == 0 and "chapterBoss" or "boss" end
    if kind ~= "elite" and kind ~= "boss" and kind ~= "chapterBoss" then kind = "normal" end
    return {
        room = room,
        floor = floor,
        kind = kind,
        eventType = kind == "normal" and "monster" or (kind == "chapterBoss" and "boss" or kind),
        isBoss = kind == "boss" or kind == "chapterBoss",
        isChapterBoss = kind == "chapterBoss",
    }
end

local function monsterFor(state, eventType, room)
    local encounter = encounterFor(room or state.position or 1, state.floor, eventType)
    local stats = TowerRules.MonsterStats(state.floor, encounter.kind)
        or TowerRules.MonsterStats(state.floor, encounter.eventType)
        or {}
    local hpBig = magnitude(stats.hpBig or stats.maxHpBig, stats.hp or stats.maxHp, 1)
    local atkBig = magnitude(stats.attackBig or stats.atkBig, stats.attack or stats.atk, 0)
    local defBig = magnitude(stats.defenseBig or stats.defBig, stats.defense or stats.def, 0)
    local names = {
        normal = "回廊怪物",
        elite = "深渊精英",
        boss = "第" .. state.floor .. "层守层者",
        chapterBoss = "第" .. state.floor .. "层万灵领主",
    }
    return {
        name = names[encounter.kind],
        hp = projectedMagnitude(hpBig),
        atk = projectedMagnitude(atkBig),
        def = projectedMagnitude(defBig),
        hpBig = hpBig,
        atkBig = atkBig,
        defBig = defBig,
        encounter = encounter,
    }
end

local function defendedDamage(attack, defense, growth)
    local ok, value = pcall(TowerRules.DamageAfterDefense, attack, defense, growth)
    if ok then
        if BigNumber.IsBigNumber(value) then return BigNumber.Normalize(value) end
        if type(value) == "number" and value == value and value >= 0 then
            return BigNumber.FromNumber(value)
        end
    end
    local defenseRatio = BigNumber.Ratio(defense, growth) or math.huge
    local multiplier = 100 / (100 + defenseRatio)
    return BigNumber.MultiplyScalar(attack, multiplier)
end

local function damageToMonster(state, monster, weight, rng)
    local stats = state.stats
    local attack = BigNumber.MultiplyScalar(statMagnitude(stats, "atk"), weight)
    local critical = randomFloat(rng) < (stats.crit or 0)
    local lucky = false
    if critical then attack = BigNumber.MultiplyScalar(attack, stats.critDmg or 1.5) end
    if (stats.luckyChance or 0) > 0 and randomFloat(rng) < stats.luckyChance then
        attack = BigNumber.MultiplyScalar(attack, stats.luckyMultiplier or 1)
        lucky = true
    end
    if monster.encounter == "boss" or monster.encounter == "chapterBoss" then
        attack = BigNumber.MultiplyScalar(attack, 1 + (stats.bossDamage or 0))
    end
    attack = BigNumber.MultiplyScalar(attack, 1 + (stats.damageBonus or 0))
    attack = BigNumber.Add(attack, BigNumber.MultiplyScalar(
        statMagnitude(stats, "hp"), (stats.trueDamageRate or 0) * weight))
    return floorDamage(defendedDamage(
        attack,
        magnitude(monster.defBig, monster.def, 0),
        TowerRules.DifficultyGrowth(state.floor))), critical, lucky
end

local function damageToPlayer(state, monster)
    local attack = BigNumber.MultiplyScalar(
        magnitude(monster.atkBig, monster.atk, 0),
        monster.enraged and Catalog.BOSS_ENRAGE_DAMAGE_MULTIPLIER or 1)
    local damage = defendedDamage(
        attack, statMagnitude(state.stats, "def"), TowerRules.DifficultyGrowth(state.floor))
    damage = BigNumber.MultiplyScalar(
        damage, 1 - Catalog.Clamp(state.stats.damageReduction or 0, 0, 0.70))
    return floorDamage(damage)
end

local function attackDefinition(index, attackSpeed)
    local visual = CombatSequence.Get(index) or CombatSequence.Get(1)
    local rules = TowerRules.AttackSequence(index)
        or TowerRules.AttackSequence(visual.id)
        or {}
    local hitFrames = rules.hitFrames or visual.hitFrames
    local weights = rules.weights or {}
    if #weights == 0 and type(rules.hits) == "table" then
        for hitIndex, hit in ipairs(rules.hits) do
            weights[hitIndex] = hit.weight
        end
    end
    if #weights == 0 then weights = { 0.30, 0.40, 0.50, 0.80 } end
    local fps = tonumber(rules.fps) or visual.fps
    local endFrame = tonumber(rules.endFrame) or visual.endFrame
    local baseDuration = math.max(0.01, tonumber(rules.duration) or (endFrame / fps))
    local duration = math.max(0.8, baseDuration / Catalog.Clamp(tonumber(attackSpeed) or 1, 0.5, 3.0))
    local hitTimes = {}
    for hitIndex, frame in ipairs(hitFrames) do
        hitTimes[hitIndex] = Catalog.Clamp((frame - 1) / math.max(1, endFrame - 1) * duration, 0.01, duration)
    end
    return {
        sequenceIndex = index,
        sequenceId = rules.id or visual.id,
        fps = fps,
        hitFrames = hitFrames,
        weights = weights,
        hitTimes = hitTimes,
        endFrame = endFrame,
        duration = duration,
    }
end

local function randomAttack(state, monster, rng)
    local count = CombatSequence.Count()
    local index = randomInt(rng, 1, count)
    if count > 1 and index == (monster.lastSequenceIndex or 0) then index = index % count + 1 end
    local attack = attackDefinition(index, state.stats.atkSpeed)
    monster.phase = "windup"
    monster.phaseRemaining = attack.hitTimes[1]
    monster.sequenceIndex = attack.sequenceIndex
    monster.sequenceId = attack.sequenceId
    monster.fps = attack.fps
    monster.hitIndex = 1
    monster.hitFrame = attack.hitFrames[1]
    monster.endFrame = attack.endFrame
    monster.recoverySeconds = math.max(CombatSequence.MIN_PHASE_SECONDS,
        attack.duration - attack.hitTimes[#attack.hitTimes])
    monster.lastSequenceIndex = attack.sequenceIndex
    return attack
end

local function attackStartedEvent(monster, attack)
    return event("attack_started", {
        monsterId = monster.id,
        eventType = monster.eventType,
        encounterKind = monster.encounter,
        attackSerial = monster.attackSerial,
        sequenceIndex = attack.sequenceIndex,
        sequenceId = attack.sequenceId,
        fps = attack.fps,
        hitFrames = TableUtils.DeepCopy(attack.hitFrames),
        hitWeights = TableUtils.DeepCopy(attack.weights),
        endFrame = attack.endFrame,
        durationSeconds = attack.duration,
    })
end

local function beginOnlineBattle(state, eventType, rng, events)
    local generated = monsterFor(state, eventType, state.position)
    local encounter = generated.encounter
    local monster = {
        id = string.format("floor:%d:room:%d", state.floor, encounter.room),
        eventType = encounter.eventType,
        encounter = encounter.kind,
        room = encounter.room,
        name = generated.name,
        hp = generated.hp,
        maxHp = generated.hp,
        atk = generated.atk,
        def = generated.def,
        hpBig = BigNumber.Clone(generated.hpBig),
        maxHpBig = BigNumber.Clone(generated.hpBig),
        atkBig = BigNumber.Clone(generated.atkBig),
        defBig = BigNumber.Clone(generated.defBig),
        isChapterBoss = encounter.isChapterBoss,
        phase = "windup",
        phaseRemaining = 0,
        attackSerial = 1,
        hitIndex = 1,
        lastSequenceIndex = 0,
        elapsedSeconds = 0,
        enraged = false,
        nextMonsterAttackSeconds = Catalog.ENEMY_ATTACK_SECONDS,
    }
    state.currentMonster = monster
    state.currentEvent = encounter.eventType
    local attack = randomAttack(state, monster, rng)
    local battleStarted = {
        monsterId = monster.id,
        eventType = monster.eventType,
        encounterKind = encounter.kind,
        room = encounter.room,
        floor = encounter.floor,
        name = monster.name,
        isChapterBoss = encounter.isChapterBoss,
    }
    addMagnitudeFields(battleStarted, "monsterHp", "monsterHpBig", monster.hpBig)
    addMagnitudeFields(battleStarted, "monsterMaxHp", "monsterMaxHpBig", monster.maxHpBig)
    events[#events + 1] = event("battle_started", battleStarted)
    local spawned = {
        monsterId = monster.id,
        floor = state.floor,
        room = monster.room,
        kind = monster.encounter,
        encounterKind = monster.encounter,
        name = monster.name,
        isChapterBoss = monster.isChapterBoss,
    }
    addMagnitudeFields(spawned, "hp", "hpBig", monster.hpBig)
    addMagnitudeFields(spawned, "maxHp", "maxHpBig", monster.maxHpBig)
    events[#events + 1] = event("monster_spawned", spawned)
    events[#events + 1] = attackStartedEvent(monster, attack)
end

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

local function settleMonsterVictory(state, encounterKind, rng, now, events, context)
    local isBoss = encounterKind == "boss" or encounterKind == "chapterBoss"
    local isElite = encounterKind == "elite"
    local rate = rewardScale(context)
    local exp = math.floor((state.floor * 5 + 10) * (isBoss and 10 or (isElite and 2.3 or 1)) * rate)
    local gold = LargeNumber.MultiplyScalar(
        Catalog.GetBattleGold(state.floor, encounterKind),
        rate
    )
    if not LargeNumber.IsZero(gold) then
        addCurrency(state, "gold", gold)
    end
    if exp > 0 then addExp(state, exp, events) end
    state.floorKillBonus = math.min(0.50, state.floorKillBonus + 0.01)
    events[#events + 1] = event("battle_reward", {
        gold = gold,
        exp = exp,
        rewardRate = rate,
        offline = context and context.offline == true,
    })
    if not LargeNumber.IsZero(gold)
        and not (context and context.offline == true)
    then
        events[#events + 1] = event("currency_drop", {
            currency = "gold",
            amount = gold,
            dropCount = math.max(1, math.min(12,
                math.floor(math.log(math.max(10,
                    state.floor + 10)) / math.log(10) * 3))),
        })
    end

    local inventoryChanged = false
    local chance = RewardPolicy.DropChance(encounterKind, context and context.offline == true) or 0
    local droppedRarity = nil
    local droppedItem = nil
    if randomFloat(rng) < chance then
        local rarity = RewardPolicy.RollRarity(encounterKind, state.floor, randomFloat(rng), state.rewardPity)
        droppedRarity = rarity
        local source = encounterKind == "chapterBoss" and "chapter_boss_drop"
            or (isBoss and "boss_drop" or (isElite and "elite_drop" or "monster_drop"))
        local dropOptions = nil
        if (tonumber(state.stats and state.stats.powerRatio) or 0) < 1 then
            local weakRanked = weakestEquipmentSlots(state)
            local weakSlots = {}
            for index = 1, math.min(3, #weakRanked) do weakSlots[index] = weakRanked[index].slot end
            local allSlots = {}
            for index, slot in ipairs(Catalog.SLOTS) do allSlots[index] = slot.id end
            dropOptions = {
                slot = RewardPolicy.PickDropSlot(allSlots, weakSlots, randomFloat(rng), randomFloat(rng)),
                rollTradeable = true,
            }
        else
            dropOptions = { rollTradeable = true }
        end
        local added, item, inventoryAdded = addGeneratedDrop(state, rarity, isBoss, rng, now, source, events, dropOptions)
        if not added then return false, inventoryChanged end
        droppedItem = item
        inventoryChanged = inventoryChanged or inventoryAdded
    end
    if encounterKind == "chapterBoss" then
        local pity = RewardPolicy.UpdatePity(state.rewardPity, droppedRarity)
        if state.floor < RarityCatalog.Get("epic").unlockFloor then pity.epicMisses = 0 end
        if state.floor < RarityCatalog.Get("myth").unlockFloor then pity.mythMisses = 0 end
        state.rewardPity = pity
        events[#events + 1] = event("reward_pity_updated", {
            epicMisses = pity.epicMisses,
            mythMisses = pity.mythMisses,
            droppedRarity = droppedRarity,
        })
    end

    if droppedItem then
        local _, boundOnEquip = considerEquipmentUpgrade(state, droppedItem, now, events)
        inventoryChanged = inventoryChanged or boundOnEquip
    end
    if isBoss and context and context.offline == true then
        local _, boundOnOptimize = optimizeWholeLoadout(state, now, events)
        inventoryChanged = inventoryChanged or boundOnOptimize
        state.position = 0
        state.currentEvent = Catalog.GetCellType(1, state.floor)
        state.floorDefeats = 0
        state.floorKillBonus = 0
        refreshDerived(state)
        setPlayerHp(state, statMagnitude(state.stats, "hp"))
        return true, inventoryChanged
    end
    if isBoss then
        local _, boundOnOptimize = optimizeWholeLoadout(state, now, events)
        inventoryChanged = inventoryChanged or boundOnOptimize
        local completedFloor = state.floor
        events[#events + 1] = event("floor_completed", {
            floor = completedFloor,
            chapterBoss = encounterKind == "chapterBoss",
        })
        if encounterKind == "chapterBoss" then
            events[#events + 1] = event("chapter_boss_defeated", {
                floor = completedFloor,
                chapter = math.floor(completedFloor / 10),
            })
            maybeQueueStoryGate(
                state,
                math.floor(completedFloor / 10),
                "memory",
                context,
                events
            )
        end
        if (Catalog.GetSetCounts(state).prophecy or 0) >= 12 then
            state.permanentBonus = state.permanentBonus + 0.005
            events[#events + 1] = event("permanent_growth", { amount = 0.005 })
        end
        for _, item in ipairs(state.inventory) do
            if item.aidLocked and (item.aidFloor or completedFloor) <= completedFloor then
                item.aidLocked = false
            end
        end
        state.floor = completedFloor + 1
        state.maxFloor = math.max(state.maxFloor, state.floor)
        state.position = 0
        state.floorDefeats = 0
        state.aidPending = false
        state.floorKillBonus = 0
        refreshDerived(state)
        local beforeHeal = magnitude(state.hpBig, state.hp, 0)
        local maximumHp = statMagnitude(state.stats, "hp")
        setPlayerHp(state, maximumHp)
        local healed = BigNumber.Subtract(maximumHp, beforeHeal)
        events[#events + 1] = event("floor_advanced", {
            completedFloor = completedFloor,
            floor = state.floor,
        })
        local recovery = {
            source = "floor_rest",
        }
        addMagnitudeFields(recovery, "amount", "amountBig", healed)
        addMagnitudeFields(recovery, "playerHp", "playerHpBig", state.hpBig)
        addMagnitudeFields(recovery, "playerMaxHp", "playerMaxHpBig", maximumHp)
        events[#events + 1] = event("floor_recovery", recovery)
        if not BigNumber.IsZero(healed) then
            local healedEvent = {
                source = "floor_rest",
            }
            addMagnitudeFields(healedEvent, "amount", "amountBig", healed)
            addMagnitudeFields(healedEvent, "playerHp", "playerHpBig", state.hpBig)
            addMagnitudeFields(healedEvent, "playerMaxHp", "playerMaxHpBig", maximumHp)
            events[#events + 1] = event("player_healed", healedEvent)
        end
    else
        refreshDerived(state, true)
    end
    return true, inventoryChanged
end

local function playerDeath(state, monster, events, context)
    local floor = state.floor
    local room = monster.room or state.position
    state.floorDefeats = math.max(0, TableUtils.ToInteger(state.floorDefeats, 0)) + 1
    state.currentMonster = nil
    state.position = 0
    state.currentEvent = Catalog.GetCellType(1, floor)
    state.floorKillBonus = 0
    refreshDerived(state, true)
    local beforeRevive = magnitude(state.hpBig, state.hp, 0)
    local maximumHp = statMagnitude(state.stats, "hp")
    local diedEvent = {
        floor = floor,
        room = room,
        monsterId = monster.id,
    }
    addMagnitudeFields(diedEvent, "hp", "hpBig", BigNumber.Zero())
    addMagnitudeFields(diedEvent, "maxHp", "maxHpBig", maximumHp)
    events[#events + 1] = event("player_died", diedEvent)
    setPlayerHp(state, maximumHp)
    events[#events + 1] = event("battle_lost", {
        monster = monster.name,
        monsterId = monster.id,
        encounterKind = monster.encounter,
        floor = floor,
        room = room,
        floorDefeats = state.floorDefeats,
    })
    events[#events + 1] = event("floor_reset", {
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
    addMagnitudeFields(revivedEvent, "playerHp", "playerHpBig", state.hpBig)
    addMagnitudeFields(revivedEvent, "playerMaxHp", "playerMaxHpBig", maximumHp)
    events[#events + 1] = event("player_revived", revivedEvent)
    local healedEvent = {
        source = "revive",
    }
    addMagnitudeFields(healedEvent, "amount", "amountBig",
        BigNumber.Subtract(state.hpBig, beforeRevive))
    addMagnitudeFields(healedEvent, "playerHp", "playerHpBig", state.hpBig)
    addMagnitudeFields(healedEvent, "playerMaxHp", "playerMaxHpBig", maximumHp)
    events[#events + 1] = event("player_healed", healedEvent)

    local offline = context and context.offline == true
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
        events[#events + 1] = event("aid_pending", TableUtils.DeepCopy(aidPayload))
        events[#events + 1] = event("tower_aid_requested", aidPayload)
    end
end

local function resolvePlayerHit(state, monster, rng, events)
    local attack = attackDefinition(monster.sequenceIndex or 1, state.stats.atkSpeed)
    local hitIndex = Catalog.Clamp(TableUtils.ToInteger(monster.hitIndex, 1), 1, #attack.weights)
    local hitFrame = attack.hitFrames[hitIndex]
    local weight = attack.weights[hitIndex]
    local oldHp = magnitude(monster.hpBig, monster.hp, 0)
    local damage, critical, lucky = damageToMonster(state, monster, weight, rng)
    local effectiveDamage = BigNumber.Min(oldHp, damage)
    setMonsterMagnitude(monster, "hp", BigNumber.Subtract(oldHp, damage))
    local payload = {
        monsterId = monster.id,
        eventType = monster.eventType,
        encounterKind = monster.encounter,
        attackSerial = monster.attackSerial,
        sequenceIndex = monster.sequenceIndex,
        sequenceId = monster.sequenceId,
        hitIndex = hitIndex,
        hitFrame = hitFrame,
        weight = weight,
        critical = critical,
        lucky = lucky,
    }
    addMagnitudeFields(payload, "damage", "damageBig", damage)
    addMagnitudeFields(payload, "amount", "amountBig", damage)
    addMagnitudeFields(payload, "effectiveDamage", "effectiveDamageBig", effectiveDamage)
    addMagnitudeFields(payload, "monsterHp", "monsterHpBig", monster.hpBig)
    addMagnitudeFields(payload, "monsterMaxHp", "monsterMaxHpBig", monster.maxHpBig)
    events[#events + 1] = event("battle_hit", TableUtils.DeepCopy(payload))
    events[#events + 1] = event("player_attack_hit", TableUtils.DeepCopy(payload))
    events[#events + 1] = event("monster_damaged", TableUtils.DeepCopy(payload))
    payload.target = "monster"
    events[#events + 1] = event("damage_dealt", payload)
    if critical then
        local criticalEvent = {
            monsterId = monster.id,
            hitIndex = hitIndex,
        }
        addMagnitudeFields(criticalEvent, "amount", "amountBig", damage)
        events[#events + 1] = event("critical_hit", criticalEvent)
    end

    local lifeSteal = math.max(0, state.stats.lifeSteal or 0)
    local maximumHp = statMagnitude(state.stats, "hp")
    local currentHp = magnitude(state.hpBig, state.hp, maximumHp)
    local healed = BigNumber.Min(
        BigNumber.Subtract(maximumHp, currentHp),
        BigNumber.Floor(BigNumber.MultiplyScalar(effectiveDamage, lifeSteal)))
    if not BigNumber.IsZero(healed) then
        setPlayerHp(state, BigNumber.Add(currentHp, healed))
        local healPayload = {
            source = "life_steal",
            monsterId = monster.id,
        }
        addMagnitudeFields(healPayload, "amount", "amountBig", healed)
        addMagnitudeFields(healPayload, "playerHp", "playerHpBig", state.hpBig)
        addMagnitudeFields(healPayload, "playerMaxHp", "playerMaxHpBig", maximumHp)
        addMagnitudeFields(healPayload, "damage", "damageBig", effectiveDamage)
        events[#events + 1] = event("life_steal", TableUtils.DeepCopy(healPayload))
        events[#events + 1] = event("player_healed", healPayload)
    end

    hitIndex = hitIndex + 1
    if hitIndex <= #attack.weights then
        monster.hitIndex = hitIndex
        monster.hitFrame = attack.hitFrames[hitIndex]
        monster.phase = "windup"
        monster.phaseRemaining = math.max(CombatSequence.MIN_PHASE_SECONDS,
            attack.hitTimes[hitIndex] - attack.hitTimes[hitIndex - 1])
    else
        monster.hitIndex = #attack.weights
        monster.phase = "recovery"
        monster.phaseRemaining = math.max(CombatSequence.MIN_PHASE_SECONDS,
            attack.duration - attack.hitTimes[#attack.hitTimes])
        monster.recoverySeconds = monster.phaseRemaining
    end
end

local function resolveMonsterAttack(state, monster, events, context)
    local damage = damageToPlayer(state, monster)
    local currentHp = magnitude(state.hpBig, state.hp, statMagnitude(state.stats, "hp"))
    setPlayerHp(state, BigNumber.Subtract(currentHp, damage))
    local damagedEvent = {
        source = "monster_attack",
        monsterId = monster.id,
        encounterKind = monster.encounter,
        enraged = monster.enraged == true,
    }
    addMagnitudeFields(damagedEvent, "amount", "amountBig", damage)
    addMagnitudeFields(damagedEvent, "damage", "damageBig", damage)
    addMagnitudeFields(damagedEvent, "playerHp", "playerHpBig", state.hpBig)
    addMagnitudeFields(damagedEvent, "playerMaxHp", "playerMaxHpBig", statMagnitude(state.stats, "hp"))
    events[#events + 1] = event("player_damaged", damagedEvent)
    if BigNumber.IsZero(state.hpBig) then
        playerDeath(state, monster, events, context)
        return true
    end
    local speed = monster.enraged and Catalog.BOSS_ENRAGE_SPEED_MULTIPLIER or 1
    monster.nextMonsterAttackSeconds = Catalog.ENEMY_ATTACK_SECONDS / speed
    return false
end

local function finishVictory(state, monster, rng, now, events, context)
    events[#events + 1] = event("battle_won", {
        monsterId = monster.id,
        eventType = monster.eventType,
        encounterKind = monster.encounter,
        floor = state.floor,
        room = monster.room,
        elapsedSeconds = monster.elapsedSeconds,
    })
    events[#events + 1] = event("monster_defeated", {
        monsterId = monster.id,
        floor = state.floor,
        room = monster.room,
        kind = monster.encounter,
    })
    state.currentMonster = nil
    local completed, inventoryChanged = settleMonsterVictory(
        state,
        monster.encounter,
        rng,
        now,
        events,
        context
    )
    if completed and not (context and context.offline) then
        -- 在线移动由服务端下发的楼层路线配置驱动，战斗结算后不再用服务端计时器模拟走路。
        state.transitionRemaining = 0
    end
    return completed, inventoryChanged
end

local function advanceActiveCombat(state, rng, now, timeStep, events, context)
    local inventoryChanged = false
    local remaining = math.max(0, tonumber(timeStep) or 0)
    local guard = 0
    while state.currentMonster and guard < 1024 do
        guard = guard + 1
        local monster = state.currentMonster
        local rageRemaining = math.huge
        if (monster.encounter == "boss" or monster.encounter == "chapterBoss") and not monster.enraged then
            rageRemaining = math.max(0, Catalog.BOSS_ENRAGE_SECONDS - (monster.elapsedSeconds or 0))
        end
        local monsterAlive = not BigNumber.IsZero(magnitude(monster.hpBig, monster.hp, 0))
        local enemyRemaining = monsterAlive
            and math.max(0, tonumber(monster.nextMonsterAttackSeconds) or Catalog.ENEMY_ATTACK_SECONDS)
            or math.huge
        local phaseRemaining = math.max(0, tonumber(monster.phaseRemaining) or 0)
        local step = math.min(remaining, phaseRemaining, enemyRemaining, rageRemaining)
        if step > 0 then
            monster.phaseRemaining = math.max(0, phaseRemaining - step)
            if enemyRemaining < math.huge then
                monster.nextMonsterAttackSeconds = math.max(0, enemyRemaining - step)
            end
            monster.elapsedSeconds = (monster.elapsedSeconds or 0) + step
            remaining = remaining - step
        end

        local resolved = false
        if (monster.encounter == "boss" or monster.encounter == "chapterBoss") and not monster.enraged
            and (monster.elapsedSeconds or 0) >= Catalog.BOSS_ENRAGE_SECONDS - 1e-6
        then
            monster.enraged = true
            monster.nextMonsterAttackSeconds = (monster.nextMonsterAttackSeconds or Catalog.ENEMY_ATTACK_SECONDS)
                / Catalog.BOSS_ENRAGE_SPEED_MULTIPLIER
            events[#events + 1] = event("boss_enraged", {
                monsterId = monster.id,
                elapsedSeconds = monster.elapsedSeconds,
                damageMultiplier = Catalog.BOSS_ENRAGE_DAMAGE_MULTIPLIER,
                attackSpeedMultiplier = Catalog.BOSS_ENRAGE_SPEED_MULTIPLIER,
            })
            resolved = true
        end

        if state.currentMonster and (monster.phaseRemaining or 0) <= 1e-6 then
            if monster.phase == "recovery" then
                if BigNumber.IsZero(magnitude(monster.hpBig, monster.hp, 0)) then
                    local completed, changed = finishVictory(state, monster, rng, now, events, context)
                    inventoryChanged = inventoryChanged or changed
                    if not completed then
                        state.autoRun = false
                        state.pauseReason = "inventory_full"
                        return "inventory_full", inventoryChanged
                    end
                else
                    monster.attackSerial = monster.attackSerial + 1
                    local attack = randomAttack(state, monster, rng)
                    events[#events + 1] = attackStartedEvent(monster, attack)
                end
            else
                resolvePlayerHit(state, monster, rng, events)
            end
            resolved = true
        end

        if state.currentMonster
            and not BigNumber.IsZero(magnitude(monster.hpBig, monster.hp, 0))
            and (monster.nextMonsterAttackSeconds or 0) <= 1e-6
        then
            if resolveMonsterAttack(state, monster, events, context) then
                return "battle_lost", inventoryChanged
            end
            resolved = true
        end

        if not state.currentMonster then break end
        if remaining <= 1e-6 and not resolved then break end
        if step <= 0 and not resolved then break end
    end
    if not state.currentMonster then
        return state.pauseReason == "tower_aid" and "battle_lost" or "battle_won", inventoryChanged
    end
    return "combat_advanced", inventoryChanged
end

local resolveChest
local resolveMerchant
local resolveRandomEvent

local function advanceOnlineCombatWorking(state, rng, now, timeStep, context)
    local events = {}
    if not state.currentMonster then
        if state.pendingStoryGate then
            state.pauseReason = "story_gate"
            return state, "story_gate", { storyGateEvent(state.pendingStoryGate) }, false
        end
        local transition = math.max(0, tonumber(state.transitionRemaining) or 0)
        if transition > 0 then
            state.transitionRemaining = math.max(0, transition - math.max(0, tonumber(timeStep) or 0))
            return state, "encounter_transition", {
                event("encounter_transition", {
                    seconds = state.transitionRemaining,
                    floor = state.floor,
                    nextRoom = math.min(10, (state.position or 0) + 1),
                }),
            }, false
        end
        if #state.inventory >= Catalog.INVENTORY_CAP
            and state.inventoryPolicy.pauseOnFull
            and not hasAutoDispositionPolicy(state)
        then
            state.autoRun = false
            state.pauseReason = "inventory_full"
            return state, "inventory_full", {
                event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
            }, false
        end
        if state.aidPending and not (context and context.offline) then
            state.autoRun = false
            state.pauseReason = "tower_aid"
            return state, "tower_aid_pending", {
                event("tower_aid_pending", { floor = state.floor }),
            }, false
        end
        if not (context and context.offline) then
            return state, "awaiting_encounter", {}, false
        end
        if BigNumber.IsZero(magnitude(state.hpBig, state.hp, 0)) then
            setPlayerHp(state, statMagnitude(state.stats, "hp"))
        end
        if state.floor % 10 == 0 then
            local phase = state.position == 0 and "opening"
                or (state.position == 9 and "boss" or nil)
            if phase and maybeQueueStoryGate(state, math.floor(state.floor / 10), phase, context, events) then
                return state, "story_gate", events, false
            end
        end
        state.position = math.min(10, state.position + 1)
        local encounter = encounterFor(state.position, state.floor)
        state.currentEvent = encounter.eventType
        events[#events + 1] = event("cell_entered", {
            position = state.position,
            room = state.position,
            floor = state.floor,
            eventType = encounter.eventType,
            encounterKind = encounter.kind,
        })
        beginOnlineBattle(state, encounter.eventType, rng, events)
        return state, "battle_started", events, false
    end

    local kind, inventoryChanged = advanceActiveCombat(
        state,
        rng,
        now,
        timeStep or Catalog.COMBAT_TICK_SECONDS,
        events,
        context
    )
    return state, kind, events, inventoryChanged
end

local function resolveMonsterOffline(state, eventType, rng, now, events, context)
    beginOnlineBattle(state, eventType, rng, events)
    local inventoryChanged = false
    local guard = 0
    while state.currentMonster and guard < 120 do
        guard = guard + 1
        local kind, changed = advanceActiveCombat(state, rng, now, 60, events, context)
        inventoryChanged = inventoryChanged or changed
        if kind == "inventory_full" then return false, inventoryChanged end
    end
    return true, inventoryChanged
end

resolveChest = function(state, rng, now, events)
    local gold = Catalog.GetChestGold(
        state.floor,
        randomFloat(rng)
    )
    local fragments = randomInt(rng, 3, 12)
    addCurrency(state, "gold", gold)
    addCurrency(state, "fragments", fragments)
    events[#events + 1] = event("chest_reward", { gold = gold, fragments = fragments })
    if randomInt(rng, 1, 100) <= 35 then
        local added, _, inventoryAdded = addGeneratedDrop(
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
    if hasCurrency(state, "gold", price) then
        spendCurrency(state, "gold", price)
        addCurrency(state, "fragments", 10)
        events[#events + 1] = event("merchant_trade", { goldSpent = price, fragments = 10 })
    else
        events[#events + 1] = event("merchant_skipped", { price = price, reason = "insufficient_gold" })
    end
end

resolveRandomEvent = function(state, rng, events)
    local roll = randomInt(rng, 1, 4)
    if roll == 1 then
        local gold = Catalog.GetWishGold(state.floor)
        addCurrency(state, "gold", gold)
        events[#events + 1] = event("wish_pool", { gold = gold })
    elseif roll == 2 then
        local distance = randomInt(rng, 5, 10)
        state.position = math.min(99, state.position + distance)
        events[#events + 1] = event("teleport", { distance = distance, position = state.position })
    elseif roll == 3 then
        local maximumHp = statMagnitude(state.stats, "hp")
        local currentHp = magnitude(state.hpBig, state.hp, maximumHp)
        local healed = BigNumber.Min(
            BigNumber.Subtract(maximumHp, currentHp),
            BigNumber.Floor(BigNumber.MultiplyScalar(maximumHp, 0.18)))
        setPlayerHp(state, BigNumber.Add(currentHp, healed))
        local healPayload = { source = "altar" }
        addMagnitudeFields(healPayload, "amount", "amountBig", healed)
        addMagnitudeFields(healPayload, "hp", "hpBig", state.hpBig)
        addMagnitudeFields(healPayload, "maxHp", "maxHpBig", maximumHp)
        addMagnitudeFields(healPayload, "playerHp", "playerHpBig", state.hpBig)
        addMagnitudeFields(healPayload, "playerMaxHp", "playerMaxHpBig", maximumHp)
        events[#events + 1] = event("altar_heal", TableUtils.DeepCopy(healPayload))
        if not BigNumber.IsZero(healed) then
            events[#events + 1] = event("player_healed", healPayload)
        end
    else
        addCurrency(state, "fragments", 18)
        events[#events + 1] = event("abyss_echo", { fragments = 18 })
    end
end

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
    return event("story_gate", {
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
        events[#events + 1] = event("story_skipped", {
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

function GameEngine.SetAutoRun(inputState, enabled, now)
    if type(enabled) ~= "boolean" then
        return failure(inputState, now, "INVALID_ARGUMENT", "enabled must be a boolean")
    end
    local working = stateCopy(inputState, now)
    if enabled and working.aidPending then
        return failure(inputState, now, "TOWER_AID_PENDING", "claim tower aid before the third attempt", {
            event("tower_aid_pending", { floor = working.floor }),
        })
    end
    if enabled and #working.inventory >= Catalog.INVENTORY_CAP and working.inventoryPolicy.pauseOnFull and not hasAutoDispositionPolicy(working) then
        return failure(inputState, now, "INVENTORY_FULL", "inventory is full", {
            event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
        })
    end
    if working.autoRun == enabled then
        return noCommit(inputState, now, "auto_run_unchanged")
    end
    working.autoRun = enabled
    working.pauseReason = nil
    local events = { event("auto_run_changed", { enabled = enabled }) }
    local storyProgress = working.storyProgress or {}
    local automation = working.automationPolicy or {}
    if enabled and not storyProgress.introCompleted then
        if automation.autoSkipStory and working.interactionMode ~= "cinematic" then
            storyProgress.introCompleted = true
            working.storyProgress = storyProgress
            events[#events + 1] = event("story_skipped", {
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
    return finalize(inputState, working, now, "auto_run_changed", events, false, false)
end

local function advanceOneCellWorking(working, rng, now, context)
    local before = TableUtils.DeepCopy(working)
    if context and context.offline then working.transitionRemaining = 0 end
    if working.currentMonster then
        return advanceOnlineCombatWorking(working, rng, now, 60, context)
    end
    if working.pendingStoryGate then
        working.pauseReason = "story_gate"
        return working, "story_gate", { storyGateEvent(working.pendingStoryGate) }, false
    end
    if #working.inventory >= Catalog.INVENTORY_CAP and working.inventoryPolicy.pauseOnFull and not hasAutoDispositionPolicy(working) then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        return working, "inventory_full", {
            event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
        }, false
    end

    if BigNumber.IsZero(magnitude(working.hpBig, working.hp, 0)) then
        setPlayerHp(working, statMagnitude(working.stats, "hp"))
    end
    local storyEvents = {}
    if not (context and context.offline)
        and working.floor % 10 == 0
    then
        local phase = working.position == 0 and "opening"
            or (working.position == 9 and "boss" or nil)
        if phase and maybeQueueStoryGate(
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
    local encounter = encounterFor(working.position, working.floor)
    local eventType = encounter.eventType
    working.currentEvent = encounter.eventType
    local events = storyEvents
    events[#events + 1] =
        event("cell_entered", {
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
                event("inventory_full", {
                    capacity = Catalog.INVENTORY_CAP,
                    rollback = "cell_settlement",
                }),
            }, false
        end
        working = before
        working.position = math.min(10, working.position + 1)
        return working, "drop_skipped", {
            event("inventory_drop_skipped", { capacity = Catalog.INVENTORY_CAP }),
        }, false
    end

    refreshDerived(working)
    if #working.inventory >= Catalog.INVENTORY_CAP and working.inventoryPolicy.pauseOnFull and not hasAutoDispositionPolicy(working) then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        events[#events + 1] = event("inventory_full", { capacity = Catalog.INVENTORY_CAP })
    end
    return working, "cell_resolved", events, inventoryChanged
end

function GameEngine.AdvanceOneCell(inputState, rng, now)
    local working = stateCopy(inputState, now)
    local kind, events, inventoryChanged
    working, kind, events, inventoryChanged = advanceOneCellWorking(working, rng, now)
    return finalize(inputState, working, now, kind, events, inventoryChanged, false)
end

function GameEngine.EnterEncounter(inputState, request, rng, now)
    request = type(request) == "table" and request or {}
    local working = stateCopy(inputState, now)
    local expectedRoom = math.min(10, (working.position or 0) + 1)
    local expected = FloorRoute.GetEncounter(working.floor, expectedRoom)
    local expectedRouteId = FloorRoute.RouteId(working.floor)

    if not working.autoRun then
        return failure(inputState, now, "AUTO_RUN_DISABLED", "挂机尚未开启")
    end
    if working.pendingStoryGate then
        return failure(inputState, now, "STORY_GATE_PENDING", "剧情尚未完成")
    end
    if working.aidPending then
        return failure(inputState, now, "TOWER_AID_PENDING", "请先领取深渊援助")
    end
    if working.currentMonster then
        if working.currentMonster.id == request.encounterId then
            return noCommit(inputState, now, "encounter_already_started")
        end
        return failure(inputState, now, "BATTLE_IN_PROGRESS", "当前战斗尚未结束")
    end
    if request.routeId ~= expectedRouteId
        or not expected
        or request.encounterId ~= expected.encounterId
        or request.room ~= expectedRoom
    then
        return failure(inputState, now, "STALE_ENCOUNTER", "楼层路线已更新，请等待最新配置")
    end
    if #working.inventory >= Catalog.INVENTORY_CAP
        and working.inventoryPolicy.pauseOnFull
        and not hasAutoDispositionPolicy(working)
    then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        return finalize(inputState, working, now, "inventory_full", {
            event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
        }, false, false, true)
    end
    if BigNumber.IsZero(magnitude(working.hpBig, working.hp, 0)) then
        setPlayerHp(working, statMagnitude(working.stats, "hp"))
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
            return finalize(inputState, working, now, "story_gate", storyEvents, false, false, true)
        end
    end

    working.position = expectedRoom
    working.currentEvent = expected.eventType
    local events = {
        event("cell_entered", {
            position = expectedRoom,
            room = expectedRoom,
            floor = working.floor,
            routeId = expectedRouteId,
            encounterId = expected.encounterId,
            eventType = expected.eventType,
            encounterKind = expected.kind,
        }),
    }
    beginOnlineBattle(working, expected.eventType, rng, events)
    return finalize(inputState, working, now, "battle_started", events, false, false, true)
end

function GameEngine.AdvanceCombatTick(inputState, rng, now, timeStep)
    timeStep = tonumber(timeStep) or 0
    if timeStep <= 0 then
        return noCommit(inputState, now, "combat_tick_ignored")
    end
    local working = stateCopy(inputState, now)
    if not working.autoRun then
        return noCommit(inputState, now, "combat_paused")
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
    return finalize(inputState, working, now, kind, events, inventoryChanged, false, true)
end

function GameEngine.ClaimLootStash(inputState, now)
    local working = stateCopy(inputState, now)
    local count = #(working.lootStash or {})
    if count == 0 then
        return noCommit(inputState, now, "loot_stash_empty")
    end
    working.lootStash = {}
    return finalize(inputState, working, now, "loot_stash_claimed", {
        event("loot_stash_claimed", { count = count }),
    }, false, false)
end

function GameEngine.Equip(inputState, itemId, now)
    local working = stateCopy(inputState, now)
    local item = findItem(working, itemId)
    if not item then
        return failure(inputState, now, "ITEM_NOT_FOUND", "equipment item was not found")
    end
    if not Catalog.SLOT_BY_ID[item.slot] then
        return failure(inputState, now, "INVALID_ITEM", "item has no valid equipment slot")
    end
    if working.equipped[item.slot] == item.id then
        return noCommit(inputState, now, "already_equipped")
    end
    working.equipped[item.slot] = item.id
    local tradeabilityChanged = bindEquipmentOnSuccessfulEquip(item)
    removeFromLootStash(working, item.id)
    refreshDerived(working)
    return finalize(inputState, working, now, "equipment_changed", {
        event("equipment_equipped", { itemId = item.id, slot = item.slot }),
    }, tradeabilityChanged, true)
end

GameEngine.EquipItem = GameEngine.Equip

function GameEngine.Unequip(inputState, slotId, now)
    if not Catalog.SLOT_BY_ID[slotId] then
        return failure(inputState, now, "INVALID_SLOT", "unknown equipment slot")
    end
    local working = stateCopy(inputState, now)
    local item = findItem(working, working.equipped[slotId])
    if not item then
        return noCommit(inputState, now, "already_unequipped")
    end
    working.equipped[slotId] = nil
    refreshDerived(working)
    return finalize(inputState, working, now, "equipment_changed", {
        event("equipment_unequipped", { itemId = item.id, slot = slotId }),
    }, false, true)
end

GameEngine.UnequipItem = GameEngine.Unequip

function GameEngine.AutoEquip(inputState, now)
    local working = stateCopy(inputState, now)
    local events = {}
    local changed, tradeabilityChanged = optimizeWholeLoadout(working, now, events, true)
    if not changed then
        return noCommit(inputState, now, "auto_equip_unchanged")
    end
    events[#events + 1] = event("auto_equip", { evaluatedBy = "PowerEvaluator" })
    return finalize(inputState, working, now, "auto_equip", events, tradeabilityChanged, true)
end

GameEngine.AutoEquipBest = GameEngine.AutoEquip

function GameEngine.GetSellPreview(inputState, itemId)
    local item = findItem(inputState, itemId)
    if not item then
        return {
            ok = false,
            code = "ITEM_NOT_FOUND",
            reason = "equipment item was not found",
        }
    end
    local equipped = equippedIdSet(inputState)
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

function GameEngine.GetDecomposePreview(inputState, itemId)
    local item = findItem(inputState, itemId)
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

function GameEngine.Decompose(inputState, maximumRank, now, candidateIds)
    maximumRank = TableUtils.ToInteger(maximumRank, -1)
    if maximumRank < 1 or maximumRank >= #Catalog.RARITY_ORDER then
        return failure(inputState, now, "INVALID_ARGUMENT", "maximumRank must exclude myth equipment")
    end

    local working = stateCopy(inputState, now)
    local equipped = equippedIdSet(working)
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
    local gold = LargeNumber.Zero()
    for _, item in ipairs(working.inventory) do
        local rarity = Catalog.RARITIES[item.rarity]
        local explicitlySelected = selected == nil or selected[item.id] == true
        if explicitlySelected and rarity and rarity.rank <= maximumRank
            and not equipped[item.id] and not item.locked and not item.aidLocked then
            removed = removed + 1
            local refund = Catalog.GetDecomposeRefund(item, working.vipLevel)
            fragments = fragments + refund.fragments
            gold = LargeNumber.Add(gold, refund.gold)
            addCurrency(working, "gold", refund.gold)
        else
            kept[#kept + 1] = item
        end
    end
    if removed == 0 then
        return noCommit(inputState, now, "decompose_empty")
    end
    working.inventory = kept
    pruneLootStash(working)
    addCurrency(working, "fragments", fragments)
    local events = {
        event("equipment_decomposed", { count = removed, fragments = fragments, gold = gold }),
    }
    local recovered = drainOverflowLoot(working, events)
    refreshDerived(working)
    if recovered > 0 then events[#events + 1] = event("temporary_loot_recovered", { count = recovered }) end
    return finalize(inputState, working, now, "equipment_decomposed", events, true, false)
end

GameEngine.DecomposeByRank = GameEngine.Decompose

function GameEngine.Sell(inputState, maximumRank, now, candidateIds)
    maximumRank = TableUtils.ToInteger(maximumRank, -1)
    if maximumRank < 1 or maximumRank >= #Catalog.RARITY_ORDER then
        return failure(inputState, now, "INVALID_ARGUMENT", "maximumRank must exclude myth equipment")
    end
    local working = stateCopy(inputState, now)
    local equipped = equippedIdSet(working)
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
    if removed == 0 then return noCommit(inputState, now, "sell_empty") end
    working.inventory = kept
    pruneLootStash(working)
    addCurrency(working, "gold", gold)
    local events = { event("equipment_sold", { count = removed, gold = gold }) }
    local recovered = drainOverflowLoot(working, events)
    refreshDerived(working)
    if recovered > 0 then events[#events + 1] = event("temporary_loot_recovered", { count = recovered }) end
    return finalize(inputState, working, now, "equipment_sold", events, true, false)
end

GameEngine.SellByRank = GameEngine.Sell

weakestEquipmentSlots = function(state)
    local growth = TowerRules.Growth(state.floor)
    local ranked = {}
    for _, slot in ipairs(Catalog.SLOTS) do
        local item = findItem(state, state.equipped[slot.id])
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

local function aidEvaluation(state, floor)
    ---@type fun(stats: table, options: table): any
    local evaluatePower = PowerEvaluator.Evaluate
    local ok, result = pcall(evaluatePower, state.stats, { floor = floor })
    if not ok or type(result) ~= "table" then return {} end
    ---@cast result table
    return result
end

local function aidTargetsMet(evaluation, targetPower)
    local power = magnitude(evaluation.displayedPower, evaluation.displayedPowerNumber, 0)
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
        budgetBig = magnitude(item.budgetBig, item.budget, 0),
        atkBig = magnitude(item.atkBig, item.atk, 0),
        defBig = magnitude(item.defBig, item.def, 0),
        hpBig = magnitude(item.hpBig, item.hp, 0),
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
        item[field] = projectedMagnitude(value)
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
        refreshDerived(state)
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
    refreshDerived(state)
    return aidEvaluation(state, state.floor) or bestEvaluation
end

function GameEngine.ClaimAid(inputState, rng, now)
    if type(rng) == "number" and now == nil then
        now = rng
        rng = nil
    end
    local working = stateCopy(inputState, now)
    working.aidGrantedFloors = type(working.aidGrantedFloors) == "table"
        and working.aidGrantedFloors or {}
    if not working.aidPending then
        return failure(inputState, now, "NO_TOWER_AID", "tower aid is not pending")
    end
    if hasAidForFloor(working, working.floor) then
        return failure(inputState, now, "TOWER_AID_ALREADY_CLAIMED", "tower aid was already claimed on this floor")
    end

    refreshDerived(working)
    local beforeEvaluation = aidEvaluation(working, working.floor)
    local beforePower = magnitude(
        beforeEvaluation.displayedPower,
        beforeEvaluation.displayedPowerNumber or working.stats.power,
        0)
    local recommended = TowerRules.RecommendedPower(working.floor)
    local targetPower = BigNumber.Max(
        BigNumber.MultiplyScalar(beforePower, 1 + RewardPolicy.AID_MINIMUM_POWER_GAIN),
        BigNumber.MultiplyScalar(recommended, RewardPolicy.AID_TARGET_RECOMMENDED_RATIO))
    local highest = RarityCatalog.HighestUnlocked(working.floor)
    local rarity = type(highest) == "table" and highest.id or (highest or "rare")
    local weakest = weakestEquipmentSlots(working)
    local events = {}
    local grantedItems = {}
    local inventoryChanged = false
    local evaluation = beforeEvaluation

    for index = 1, math.min(2, #weakest) do
        local slotId = weakest[index].slot
        local added, item, changed = addGeneratedDrop(
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
            return failure(inputState, now, "INVENTORY_FULL", "clear inventory space before claiming tower aid", {
                event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
            })
        end
        item.setId = nil
        item.setEnabled = false
        working.equipped[slotId] = item.id
        bindEquipmentOnSuccessfulEquip(item)
        grantedItems[#grantedItems + 1] = item
        inventoryChanged = inventoryChanged or changed
        events[#events + 1] = event("tower_aid_equipment", {
            itemId = item.id,
            equipmentId = item.equipmentId,
            slot = slotId,
            rarity = item.rarity,
            floor = working.floor,
        })
        refreshDerived(working)
        evaluation = aidEvaluation(working, working.floor)
        if aidTargetsMet(evaluation, targetPower) then break end
    end

    -- 只做小幅校准，目标是刚好进入当前层“可挑战”线，而不是生成碾压装备。
    local tuned = grantedItems[#grantedItems]
    local tuneCount = 0
    while tuned and not aidTargetsMet(evaluation, targetPower) and tuneCount < 24 do
        tuneCount = tuneCount + 1
        multiplyItemMagnitude(tuned, "atk", 1.02)
        multiplyItemMagnitude(tuned, "def", 1.02)
        multiplyItemMagnitude(tuned, "hp", 1.02)
        tuned.budgetBig = BigNumber.MultiplyScalar(
            magnitude(tuned.budgetBig, tuned.budget, 0), 1.02)
        tuned.budget = projectedMagnitude(tuned.budgetBig)
        refreshDerived(working)
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
    addMagnitudeFields(aidClaimedPayload, "beforePower", "beforePowerBig", beforePower)
    addMagnitudeFields(
        aidClaimedPayload,
        "displayedPower",
        "displayedPowerBig",
        magnitude(evaluation.displayedPower, evaluation.displayedPowerNumber, working.stats.power))
    addMagnitudeFields(aidClaimedPayload, "targetPower", "targetPowerBig", targetPower)
    events[#events + 1] = event("tower_aid_claimed", aidClaimedPayload)
    local aidGrantedPayload = {
        floor = working.floor,
        itemCount = #grantedItems,
        targetMet = aidTargetsMet(evaluation, targetPower),
    }
    addMagnitudeFields(
        aidGrantedPayload,
        "displayedPower",
        "displayedPowerBig",
        magnitude(evaluation.displayedPower, evaluation.displayedPowerNumber, working.stats.power))
    events[#events + 1] = event("aid_granted", aidGrantedPayload)
    return finalize(inputState, working, now, "tower_aid_claimed", events, inventoryChanged, true)
end

GameEngine.ApplyAid = GameEngine.ClaimAid

function GameEngine.SetEquipmentLock(inputState, itemId, locked, now)
    if type(locked) ~= "boolean" then
        return failure(inputState, now, "INVALID_ARGUMENT", "locked must be a boolean")
    end
    local working = stateCopy(inputState, now)
    local item = findItem(working, itemId)
    if not item then return failure(inputState, now, "ITEM_NOT_FOUND", "equipment item was not found") end
    if item.locked == locked then return noCommit(inputState, now, "equipment_lock_unchanged") end
    item.locked = locked
    return finalize(inputState, working, now, "equipment_lock_changed", {
        event("equipment_lock_changed", { itemId = item.id, locked = locked }),
    }, true, false)
end

function GameEngine.SetInventoryPolicy(inputState, policy, now)
    if type(policy) ~= "table" then
        return failure(inputState, now, "INVALID_ARGUMENT", "inventory policy is required")
    end
    local working = stateCopy(inputState, now)
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
    return finalize(inputState, working, now, "inventory_policy_changed", {
        event("inventory_policy_changed", { inventoryPolicy = TableUtils.DeepCopy(working.inventoryPolicy) }),
    }, false, false)
end

function GameEngine.SetInteractionMode(inputState, mode, now)
    if mode ~= "normal" and mode ~= "cinematic" then
        return failure(inputState, now, "INVALID_INTERACTION_MODE", "mode must be normal or cinematic")
    end
    local working = stateCopy(inputState, now)
    if working.interactionMode == mode then
        return noCommit(inputState, now, "interaction_mode_unchanged")
    end
    working.interactionMode = mode
    return finalize(inputState, working, now, "interaction_mode_changed", {
        event("interaction_mode_changed", { mode = mode }),
    }, false, false)
end

function GameEngine.SetAutomationPolicy(inputState, policy, now)
    if type(policy) ~= "table"
        or type(policy.autoEquip) ~= "boolean"
        or type(policy.lootAutoEquip) ~= "boolean"
        or type(policy.autoSkipStory) ~= "boolean"
    then
        return failure(inputState, now, "INVALID_AUTOMATION_POLICY",
            "autoEquip, lootAutoEquip and autoSkipStory must be booleans")
    end
    local working = stateCopy(inputState, now)
    local nextPolicy = {
        autoEquip = policy.lootAutoEquip,
        lootAutoEquip = policy.lootAutoEquip,
        autoSkipStory = policy.autoSkipStory,
    }
    if TableUtils.DeepEqual(working.automationPolicy, nextPolicy) then
        return noCommit(inputState, now, "automation_policy_unchanged")
    end
    working.automationPolicy = nextPolicy
    return finalize(inputState, working, now, "automation_policy_changed", {
        event("automation_policy_changed", { policy = TableUtils.DeepCopy(nextPolicy) }),
    }, false, false)
end

function GameEngine.DecideEquip(inputState, decision, now)
    if type(decision) ~= "table" or (decision.action ~= "equip" and decision.action ~= "keep") then
        return failure(inputState, now, "INVALID_EQUIP_DECISION", "action must be equip or keep")
    end
    local working = stateCopy(inputState, now)
    local pending = working.pendingEquipDecision
    if type(pending) ~= "table" then
        return failure(inputState, now, "NO_EQUIP_DECISION", "there is no pending equipment decision")
    end
    if decision.itemId and decision.itemId ~= pending.itemId then
        return failure(inputState, now, "STALE_EQUIP_DECISION", "pending equipment item has changed")
    end
    local events = {}
    local equippedChanged = false
    local tradeabilityChanged = false
    if decision.action == "equip" then
        local item = findItem(working, pending.itemId)
        if not item then
            return failure(inputState, now, "ITEM_NOT_FOUND", "pending equipment item was not found")
        end
        local current = findItem(working, working.equipped[item.slot])
        if current and (current.locked or current.aidLocked) then
            return failure(inputState, now, "EQUIPMENT_LOCKED", "the equipped item cannot be replaced")
        end
        local before = evaluateLoadout(working, working.equipped, true)
        local candidateEquipped = TableUtils.DeepCopy(working.equipped)
        candidateEquipped[item.slot] = item.id
        local after = evaluateLoadout(working, candidateEquipped, true)
        if not upgradePasses(before, after, RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN) then
            working.pendingEquipDecision = nil
            return finalize(inputState, working, now, "equip_decision_stale", {
                event("equip_decision_applied", { action = "keep", itemId = item.id, stale = true }),
            }, false, false)
        end
        working.previousLoadout = {
            equipped = TableUtils.DeepCopy(working.equipped),
            createdAt = nowInteger(now),
            available = true,
        }
        working.equipped = candidateEquipped
        tradeabilityChanged = bindEquipmentOnSuccessfulEquip(item)
        removeFromLootStash(working, item.id)
        refreshDerived(working)
        equippedChanged = true
        local appliedPayload = {
            action = "equip",
            itemId = item.id,
            slot = item.slot,
            headroomDelta = (after.display.equivalentFloor or 0)
                - (before.display.equivalentFloor or 0),
        }
        addMagnitudeFields(
            appliedPayload,
            "displayedPower",
            "displayedPowerBig",
            magnitude(working.stats.displayedPower, working.stats.power, 0))
        addMagnitudeFields(
            appliedPayload,
            "displayedPowerDelta",
            "displayedPowerDeltaBig",
            displayedPowerDelta(before.display, after.display))
        events[#events + 1] = event("equip_decision_applied", appliedPayload)
    else
        events[#events + 1] = event("equip_decision_applied", {
            action = "keep",
            itemId = pending.itemId,
        })
    end
    working.pendingEquipDecision = nil
    return finalize(inputState, working, now, "equip_decided", events,
        tradeabilityChanged, equippedChanged)
end

function GameEngine.UndoEquip(inputState, now)
    local working = stateCopy(inputState, now)
    local backup = working.previousLoadout
    if type(backup) ~= "table" or backup.available ~= true or type(backup.equipped) ~= "table" then
        return failure(inputState, now, "NO_EQUIP_UNDO", "there is no equipment change to undo")
    end
    local restored = {}
    for slotId, itemId in pairs(backup.equipped) do
        local item = findItem(working, itemId)
        if item and item.slot == slotId then restored[slotId] = itemId end
    end
    working.equipped = restored
    backup.available = false
    working.previousLoadout = backup
    refreshDerived(working)
    local revertedPayload = {}
    addMagnitudeFields(
        revertedPayload,
        "displayedPower",
        "displayedPowerBig",
        magnitude(working.stats.displayedPower, working.stats.power, 0))
    return finalize(inputState, working, now, "equipment_reverted", {
        event("equipment_reverted", revertedPayload),
    }, false, true)
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
    events[#events + 1] = event(skipped and "story_skipped" or "story_completed", {
        storyId = gate.storyId,
        chapter = gate.chapter,
        phase = gate.phase,
    })
end

function GameEngine.AdvanceStory(inputState, action, now)
    if type(action) == "string" then action = { action = action } end
    if type(action) ~= "table" then
        return failure(inputState, now, "INVALID_STORY_ACTION", "story action is required")
    end
    local actionId = action.action
    if actionId ~= "next" and actionId ~= "skip" and actionId ~= "complete" then
        return failure(inputState, now, "INVALID_STORY_ACTION", "action must be next, skip, or complete")
    end
    local working = stateCopy(inputState, now)
    local gate = working.pendingStoryGate
    if type(gate) ~= "table" then
        return failure(inputState, now, "NO_STORY_GATE", "there is no pending story")
    end
    if action.storyId and action.storyId ~= gate.storyId then
        return failure(inputState, now, "STALE_STORY_GATE", "pending story has changed")
    end
    local currentLineIndex = gate.lineIndex or 1
    if actionId ~= "skip" then
        local expectedLineIndex = actionId == "next" and currentLineIndex + 1 or currentLineIndex
        if action.lineIndex ~= expectedLineIndex then
            return failure(inputState, now, "STALE_STORY_GATE", "pending story line has changed")
        end
    end
    local events = {}
    if actionId == "next" and currentLineIndex < #gate.lines then
        gate.lineIndex = currentLineIndex + 1
        working.pendingStoryGate = gate
        events[#events + 1] = event("story_advanced", {
            storyId = gate.storyId,
            chapter = gate.chapter,
            phase = gate.phase,
            lineIndex = gate.lineIndex,
            line = gate.lines[gate.lineIndex],
        })
    else
        completeStoryGate(working, gate, actionId == "skip", events)
    end
    return finalize(inputState, working, now, "story_advanced", events, false, false)
end

function GameEngine.AcknowledgeRules(inputState, ruleId, now)
    if type(ruleId) ~= "string" or #ruleId < 1 or #ruleId > 96
        or ruleId:match("^[%w%._:%-]+$") == nil
    then
        return failure(inputState, now, "INVALID_RULE_ID", "ruleId is invalid")
    end
    ruleId = StoryCatalog.NormalizeRuleId(ruleId)
    if not StoryCatalog.IsKnownRuleId(ruleId) then
        return failure(inputState, now, "UNKNOWN_RULE_ID", "ruleId is not registered")
    end
    local working = stateCopy(inputState, now)
    working.ruleAcknowledgements = type(working.ruleAcknowledgements) == "table"
        and working.ruleAcknowledgements or {}
    if working.ruleAcknowledgements[ruleId] == true then
        return noCommit(inputState, now, "rules_already_acknowledged")
    end
    working.ruleAcknowledgements[ruleId] = true
    return finalize(inputState, working, now, "rules_acknowledged", {
        event("rules_acknowledged", { ruleId = ruleId }),
    }, false, false)
end

local function StrengthenCost(item, enhance)
    return Catalog.GetStrengthenCost(item, enhance)
end

function GameEngine.GetStrengthenPreview(inputState, slotId)
    if not Catalog.SLOT_BY_ID[slotId] then
        return failure(inputState, os.time(), "INVALID_SLOT", "unknown equipment slot")
    end
    local working = stateCopy(inputState, os.time())
    local item = findItem(working, working.equipped[slotId])
    if not item then
        return failure(inputState, os.time(), "ITEM_NOT_FOUND", "slot has no equipped item")
    end
    local limit = math.max(1, math.floor(working.maxFloor / 10) + 1)
    local cost = StrengthenCost(item, item.enhance)
    local atMax = item.enhance >= limit
    local goldEnough = hasCurrency(working, "gold", cost.gold)
    local fragmentsEnough = hasCurrency(working, "fragments", cost.fragments)
    return {
        ok = true,
        code = "OK",
        data = {
            slot = slotId,
            itemId = item.id,
            itemName = item.name,
            currentEnhance = item.enhance,
            nextEnhance = math.min(limit, item.enhance + 1),
            enhanceLimit = limit,
            gold = cost.gold,
            goldOwned = LargeNumber.Normalize(working.gold),
            fragments = cost.fragments,
            fragmentsOwned = LargeNumber.Normalize(working.fragments),
            canStrengthen = not atMax and goldEnough and fragmentsEnough,
            atMax = atMax,
            goldEnough = goldEnough,
            fragmentsEnough = fragmentsEnough,
        },
    }
end

function GameEngine.Strengthen(inputState, slotId, now)
    if not Catalog.SLOT_BY_ID[slotId] then
        return failure(inputState, now, "INVALID_SLOT", "unknown equipment slot")
    end
    local working = stateCopy(inputState, now)
    local item = findItem(working, working.equipped[slotId])
    if not item then
        return failure(inputState, now, "ITEM_NOT_FOUND", "slot has no equipped item")
    end
    local limit = math.max(1, math.floor(working.maxFloor / 10) + 1)
    if item.enhance >= limit then
        return failure(inputState, now, "ENHANCE_LIMIT", "equipment reached the current strengthen limit")
    end
    local cost = StrengthenCost(item, item.enhance)
    local goldCost = cost.gold
    local fragmentCost = cost.fragments
    if not hasCurrency(working, "gold", goldCost) or not hasCurrency(working, "fragments", fragmentCost) then
        return failure(inputState, now, "INSUFFICIENT_RESOURCES", "not enough gold or fragments")
    end
    spendCurrency(working, "gold", goldCost)
    spendCurrency(working, "fragments", fragmentCost)
    item.enhance = item.enhance + 1
    item.investedGold = LargeNumber.Add(
        item.investedGold,
        goldCost
    )
    item.investedFragments = math.min(
        Catalog.MAX_VALUE,
        (item.investedFragments or 0) + fragmentCost
    )
    refreshDerived(working)
    return finalize(inputState, working, now, "equipment_strengthened", {
        event("equipment_strengthened", {
            itemId = item.id,
            enhance = item.enhance,
            goldCost = goldCost,
            fragmentCost = fragmentCost,
        }),
    }, true, false)
end

GameEngine.StrengthenSelected = GameEngine.Strengthen

local function StarCost(item, star)
    return Catalog.GetStarCost(item, star)
end

local function StarMaterials(state, item)
    local equipped = equippedIdSet(state)
    local materials = {}
    for index, candidate in ipairs(state.inventory or {}) do
        if candidate.id ~= item.id
            and candidate.equipmentId == item.equipmentId
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

function GameEngine.GetStarPreview(inputState, slotId)
    if not Catalog.SLOT_BY_ID[slotId] then
        return failure(inputState, os.time(), "INVALID_SLOT", "unknown equipment slot")
    end
    local working = stateCopy(inputState, os.time())
    local item = findItem(working, working.equipped[slotId])
    if not item then
        return failure(inputState, os.time(), "ITEM_NOT_FOUND", "slot has no equipped item")
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
    local goldEnough = hasCurrency(working, "gold", cost.gold)
    local fragmentsEnough = hasCurrency(working, "fragments", cost.fragments)
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

function GameEngine.Star(inputState, slotId, materialItemId, now)
    if not Catalog.SLOT_BY_ID[slotId] then
        return failure(inputState, now, "INVALID_SLOT", "unknown equipment slot")
    end
    local working = stateCopy(inputState, now)
    local item = findItem(working, working.equipped[slotId])
    if not item then
        return failure(inputState, now, "ITEM_NOT_FOUND", "slot has no equipped item")
    end
    if item.star >= 5 then
        return failure(inputState, now, "STAR_LIMIT", "equipment already has five stars")
    end

    if type(materialItemId) ~= "string" or materialItemId == "" then
        return failure(inputState, now, "MATERIAL_REQUIRED", "a star material item must be selected")
    end
    local _, duplicateIndex = FindStarMaterial(working, item, materialItemId)
    if not duplicateIndex then
        return failure(inputState, now, "DUPLICATE_REQUIRED", "an unequipped item with the same equipment, star level and rarity is required")
    end
    local cost = StarCost(item, item.star)
    if not hasCurrency(working, "gold", cost.gold)
        or not hasCurrency(working, "fragments", cost.fragments)
    then
        return failure(inputState, now, "INSUFFICIENT_RESOURCES", "not enough gold or fragments")
    end
    spendCurrency(working, "gold", cost.gold)
    spendCurrency(working, "fragments", cost.fragments)
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
    refreshDerived(working)
    return finalize(inputState, working, now, "equipment_starred", {
        event("equipment_starred", {
            itemId = item.id,
            consumedItemId = consumedId,
            star = item.star,
            previousStar = item.star - 1,
            goldCost = cost.gold,
            fragmentCost = cost.fragments,
        }),
    }, true, false)
end

GameEngine.StarSelected = GameEngine.Star

function GameEngine.TouchActive(inputState, now)
    now = nowInteger(now)
    local working = stateCopy(inputState, now)
    if now <= working.lastActiveAt then
        return noCommit(inputState, now, "active_unchanged")
    end
    return finalize(inputState, working, now, "active_touched", {
        event("active_touched", { lastActiveAt = now }),
    }, false, false)
end

function GameEngine.AccrueOffline(inputState, now)
    now = nowInteger(now)
    local working = stateCopy(inputState, now)
    local elapsed = math.max(0, now - working.lastActiveAt)
    if elapsed == 0 then
        return noCommit(inputState, now, "offline_unchanged")
    end
    local before = working.pendingOfflineSeconds
    working.pendingOfflineSeconds = math.min(Catalog.OFFLINE_MAX_SECONDS, before + elapsed)
    return finalize(inputState, working, now, "offline_accrued", {
        event("offline_accrued", {
            elapsedSeconds = elapsed,
            creditedSeconds = working.pendingOfflineSeconds - before,
            capped = working.pendingOfflineSeconds >= Catalog.OFFLINE_MAX_SECONDS,
        }),
    }, false, false, true)
end

GameEngine.PrepareLogin = GameEngine.AccrueOffline

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

local function offlineEncounterKind(floor, room)
    if room <= TowerRules.NORMAL_ENCOUNTERS then return "normal" end
    if room <= TowerRules.NORMAL_ENCOUNTERS + TowerRules.ELITE_ENCOUNTERS then return "elite" end
    return floor % 10 == 0 and "chapterBoss" or "boss"
end

local function offlineEncounterCounts(floor, position, cycles)
    local counts = { normal = 0, elite = 0, boss = 0, chapterBoss = 0 }
    local fullRounds = math.floor(cycles / TowerRules.ENCOUNTERS_PER_FLOOR)
    for room = 1, TowerRules.ENCOUNTERS_PER_FLOOR do
        local kind = offlineEncounterKind(floor, room)
        counts[kind] = counts[kind] + fullRounds
    end
    local remainder = cycles - fullRounds * TowerRules.ENCOUNTERS_PER_FLOOR
    for offset = 1, remainder do
        local room = (math.max(0, position) + offset - 1)
            % TowerRules.ENCOUNTERS_PER_FLOOR + 1
        local kind = offlineEncounterKind(floor, room)
        counts[kind] = counts[kind] + 1
    end
    return counts
end

local function pickOfflineDropKind(counts, rng)
    local totalWeight = 0
    for _, kind in ipairs({ "normal", "elite", "boss", "chapterBoss" }) do
        totalWeight = totalWeight + (counts[kind] or 0) * RewardPolicy.DropChance(kind, true)
    end
    if totalWeight <= 0 then return "normal" end
    local threshold = randomFloat(rng) * totalWeight
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
    now = nowInteger(now)
    local working = stateCopy(inputState, now)
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
        addCurrency(working, "gold", summary.gold)
    end
    if summary.exp > 0 then addExp(working, summary.exp, events) end
    events[#events + 1] = event("battle_reward", {
        gold = summary.gold,
        exp = summary.exp,
        rewardRate = Catalog.OFFLINE_REWARD_RATE,
        offline = true,
        batch = true,
        cycles = cycles,
        floor = floor,
    })

    local dropCount = math.floor(expectedDrops)
    if randomFloat(rng) < expectedDrops - dropCount then dropCount = dropCount + 1 end
    local availableSlots = math.max(0, Catalog.INVENTORY_CAP - #working.inventory)
    local generatedDrops = math.min(dropCount, availableSlots)
    local generatedChapterDrops = 0
    local generatedChapterRarities = {}

    for _ = 1, generatedDrops do
        local kind = pickOfflineDropKind(encounterCounts, rng)
        local rarity = RewardPolicy.RollRarity(
            kind,
            floor,
            randomFloat(rng),
            working.rewardPity)
        local weakSlots = {}
        local powerRatio = tonumber(working.stats and working.stats.powerRatio) or 0
        if powerRatio < 1 then
            local weakRanked = weakestEquipmentSlots(working)
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
                randomFloat(rng),
                randomFloat(rng)
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
    local _, boundOnOptimize = optimizeWholeLoadout(working, now, events)

    local bossCycles = encounterCounts.chapterBoss or 0
    local missedBossCycles = math.max(0, bossCycles - generatedChapterDrops)
    if floor % 10 == 0 and missedBossCycles > 0 then
        working.rewardPity = offlinePityAfterMisses(working.rewardPity, missedBossCycles, floor)
        events[#events + 1] = event("reward_pity_updated", {
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
    refreshDerived(working)

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
    events[#events + 1] = event("offline_collected", TableUtils.DeepCopy(reward))
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
function GameEngine.FreezeOfflineReward(inputState, now, rng)
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
function GameEngine.ClaimOfflineReward(inputState, ledger, now)
    now = nowInteger(now)
    if type(ledger) ~= "table" or type(ledger.reward) ~= "table" then
        return failure(inputState, now, "INVALID_OFFLINE_QUOTE", "offline reward ledger is invalid")
    end
    local working = stateCopy(inputState, now)
    local consumed = math.max(0, TableUtils.ToInteger(ledger.seconds, 0))
    if consumed <= 0
        or math.max(0, TableUtils.ToInteger(working.pendingOfflineSeconds, 0)) < consumed
    then
        return failure(inputState, now, "NO_OFFLINE_REWARD", "offline reward was already collected")
    end
    working.pendingOfflineSeconds = working.pendingOfflineSeconds - consumed

    local events = {}
    if not LargeNumber.IsZero(ledger.gold) then
        addCurrency(working, "gold", ledger.gold)
    end
    if (ledger.fragments or 0) > 0 then
        addCurrency(working, "fragments", ledger.fragments)
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
        recordEquipmentCollection(working, item)
        if #working.inventory < Catalog.INVENTORY_CAP then
            working.inventory[#working.inventory + 1] = item
            addToLootStash(working, item.id)
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
    events[#events + 1] = event("offline_collected", reward)

    refreshDerived(working)
    return finalize(
        inputState,
        working,
        now,
        "offline_collected",
        events,
        stored > 0 or overflowed > 0,
        false
    )
end

function GameEngine.GrantCurrency(inputState, currency, amount, now)
    if currency ~= "gold" and currency ~= "fragments" and currency ~= "mythShards" then
        return failure(inputState, now, "INVALID_CURRENCY", "currency is not grantable")
    end
    amount = TableUtils.ToInteger(amount, 0)
    if amount <= 0 or amount > 1000000000 then
        return failure(inputState, now, "INVALID_AMOUNT", "amount must be positive and within the grant limit")
    end
    local working = stateCopy(inputState, now)
    addCurrency(working, currency, amount)
    return finalize(inputState, working, now, "currency_granted", {
        event("currency_granted", { currency = currency, amount = amount }),
    }, false, false)
end

function GameEngine.GrantEquipment(inputState, specification, now)
    if type(specification) ~= "table" then
        return failure(inputState, now, "INVALID_ARGUMENT", "equipment specification is required")
    end
    local definition = Catalog.GetEquipmentDefinition(specification.equipmentId)
    if not definition then
        return failure(inputState, now, "INVALID_EQUIPMENT", "unknown equipment definition")
    end
    if specification.slot ~= nil and specification.slot ~= definition.slot then
        return failure(inputState, now, "INVALID_SLOT", "equipment slot does not match definition")
    end
    local working = stateCopy(inputState, now)
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
    local atkBig = magnitude(specification.atkBig, specification.atk, actual.atkBig)
    local defBig = magnitude(specification.defBig, specification.def, actual.defBig)
    local hpBig = magnitude(specification.hpBig, specification.hp, actual.hpBig)
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
        atk = projectedMagnitude(atkBig),
        def = projectedMagnitude(defBig),
        hp = projectedMagnitude(hpBig),
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
        acquiredAt = nowInteger(now),
        source = "admin_grant",
        investedGold = LargeNumber.Zero(),
        investedFragments = 0,
    }
    local events = {}
    recordEquipmentCollection(working, item)
    local hasRoom, handled = makeRoomForDrop(working, item, events)
    if not hasRoom then
        if handled then
            return finalize(inputState, working, now, "equipment_auto_disposed", events, false, false)
        end
        return failure(inputState, now, "INVENTORY_FULL", "inventory is full", {
            event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
        })
    end
    item.power = Catalog.GetItemPower(item)
    working.inventory[#working.inventory + 1] = item
    refreshDerived(working)
    if #working.inventory >= Catalog.INVENTORY_CAP and working.inventoryPolicy.pauseOnFull and not hasAutoDispositionPolicy(working) then
        working.autoRun = false
        working.pauseReason = "inventory_full"
    end
    events[#events + 1] = event("equipment_granted", {
        itemId = item.id,
        equipmentId = item.equipmentId,
        rarity = item.rarity,
        slot = definition.slot,
    })
    return finalize(inputState, working, now, "equipment_granted", events, true, false)
end

function GameEngine.AdjustProgress(inputState, adjustment, now)
    if type(adjustment) ~= "table" then
        return failure(inputState, now, "INVALID_ARGUMENT", "progress adjustment is required")
    end
    local working = stateCopy(inputState, now)
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
                return failure(inputState, now, "INVALID_PROGRESS", field .. " is outside the allowed range")
            end
            working[field] = value
            changed = true
        end
    end
    if not changed then
        return failure(inputState, now, "INVALID_ARGUMENT", "no supported progress field was supplied")
    end
    working.maxFloor = math.max(working.maxFloor, working.floor)
    while working.exp >= Catalog.NextExp(working.level) do
        working.exp = working.exp - Catalog.NextExp(working.level)
        working.level = working.level + 1
    end
    refreshDerived(working)
    setPlayerHp(working, statMagnitude(working.stats, "hp"))
    return finalize(inputState, working, now, "progress_adjusted", {
        event("progress_adjusted", { fields = TableUtils.DeepCopy(adjustment) }),
    }, false, false)
end

function GameEngine.GetMonster(state, eventType)
    local copy = stateCopy(state, state and state.updatedAt or nil)
    return monsterFor(copy, eventType)
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
    stateCopy = stateCopy,
    finalize = finalize,
    noCommit = noCommit,
    failure = failure,
    event = event,
    findItem = findItem,
    equippedIdSet = equippedIdSet,
    addCurrency = addCurrency,
    spendCurrency = spendCurrency,
    hasCurrency = hasCurrency,
}

return GameEngine
