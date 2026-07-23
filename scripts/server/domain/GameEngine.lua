local Catalog = require("server.domain.Catalog")
local StateNormalizer = require("server.domain.StateNormalizer")
local TableUtils = require("server.domain.TableUtils")
local CombatSequence = require("shared.CombatSequence")
local LargeNumber = require("shared.LargeNumber")

local GameEngine = {}

local SCALAR_DELTA_FIELDS = {
    "pendingOfflineSeconds",
    "level",
    "exp",
    "nextExp",
    "floor",
    "maxFloor",
    "position",
    "gold",
    "fragments",
    "mythShards",
    "autoRun",
    "pauseReason",
    "hp",
    "floorKillBonus",
    "permanentBonus",
    "inventoryPolicy",
    "currentMonster",
    "currentEvent",
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

local function refreshDerived(state)
    for _, item in ipairs(state.inventory) do
        item.power = Catalog.GetItemPower(item)
    end
    state.nextExp = Catalog.NextExp(state.level)
    state.stats = Catalog.CalculateStats(state)
    state.setProgress = TableUtils.DeepCopy(state.stats.setProgress or {})
    state.hp = Catalog.Clamp(TableUtils.ToInteger(state.hp, state.stats.hp), 1, state.stats.hp)
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

local function finalize(inputState, workingState, now, kind, events, inventoryChanged, equippedChanged)
    now = nowInteger(now)
    local previous = stateCopy(inputState, now)
    workingState.revision = previous.revision + 1
    workingState.updatedAt = now
    workingState.lastActiveAt = now
    workingState = StateNormalizer.Normalize(workingState, now)
    refreshDerived(workingState)
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

local function equippedIdSet(state)
    local ids = {}
    for _, itemId in pairs(state.equipped) do
        ids[itemId] = true
    end
    return ids
end

local function addExp(state, amount, events)
    state.exp = state.exp + math.max(0, TableUtils.ToInteger(amount, 0))
    local leveled = false
    while state.exp >= Catalog.NextExp(state.level) do
        state.exp = state.exp - Catalog.NextExp(state.level)
        state.level = state.level + 1
        leveled = true
        events[#events + 1] = event("level_up", { level = state.level })
    end
    state.nextExp = Catalog.NextExp(state.level)
    if leveled then
        state.stats = Catalog.CalculateStats(state)
        state.hp = state.stats.hp
    end
    return leveled
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
    local itemId
    repeat
        itemId = makeInstanceUuid()
    until not used[itemId]
    state.nextItemId = state.nextItemId + 1
    return itemId
end

local function generatedEquipment(state, minimumRarity, isBoss, rng, now, source)
    local floor = state.floor
    local roll = randomInt(rng, 1, 1000)
    local targetRarity = "epic"
    if minimumRarity == "myth" or (floor >= 100 and isBoss and roll <= 10) then
        targetRarity = "myth"
    end

    local candidates = {}
    for _, definition in ipairs(Catalog.EQUIPMENT_DEFINITIONS) do
        if definition.rarity == targetRarity then
            candidates[#candidates + 1] = definition
        end
    end
    local definition = candidates[randomInt(rng, 1, #candidates)]
    local item = {
        id = allocateItemId(state),
        equipmentId = definition.id,
        level = floor,
        enhance = 0,
        star = 0,
        locked = false,
        acquiredAt = nowInteger(now),
        source = source or (isBoss and "boss_drop" or "monster_drop"),
        investedGold = 0,
        investedFragments = 0,
    }
    return item
end

local function disposeEquipment(state, item, mode)
    if mode == "sell" then
        local gold = Catalog.GetSellValue(item)
        addCurrency(state, "gold", gold)
        return { gold = gold, fragments = 0 }
    end
    local refund = Catalog.GetDecomposeRefund(item)
    addCurrency(state, "gold", refund.gold)
    addCurrency(state, "fragments", refund.fragments)
    return refund
end

local function autoDispositionEnabled(state, item)
    local policy = state.inventoryPolicy or {}
    if item.rarity == "myth" then return false end
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

local function makeRoomForDrop(state, incoming, events)
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
        if not item.locked and not equipped[item.id] and autoDispositionEnabled(state, item) then
            disposalIndex = index
            break
        end
    end
    if not disposalIndex then
        if policy.pauseOnFull == false then
            events[#events + 1] = event("inventory_drop_skipped", {
                itemId = incoming.id,
                equipmentId = incoming.equipmentId,
                capacity = Catalog.INVENTORY_CAP,
            })
            return false, "skipped"
        end
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

local function addGeneratedDrop(state, minimumRarity, isBoss, rng, now, source, events)
    local item = generatedEquipment(state, minimumRarity, isBoss, rng, now, source)
    local hasRoom, handled = makeRoomForDrop(state, item, events)
    if not hasRoom then
        return handled == "consumed" or handled == "skipped", nil, false
    end
    state.inventory[#state.inventory + 1] = item
    local definition = Catalog.GetEquipmentDefinition(item.equipmentId)
    events[#events + 1] = event("equipment_drop", {
        itemId = item.id,
        equipmentId = item.equipmentId,
        name = definition and definition.name or "未知装备",
        rarity = definition and definition.rarity or "common",
        slot = definition and definition.slot or "",
    })
    return true, item, true
end

local function monsterFor(state, eventType)
    local eliteMultiplier = eventType == "elite" and 1.75 or 1.0
    local bossMultiplier = eventType == "boss" and 4.6 or 1.0
    return {
        name = eventType == "boss" and ("第" .. state.floor .. "层深渊领主")
            or (eventType == "elite" and "深渊精英" or "回廊怪物"),
        hp = math.floor((30 + state.floor * 15 + (state.floor / 5) ^ 2 * 4) * eliteMultiplier * bossMultiplier),
        atk = math.floor((8 + state.floor * 2.5 + (state.floor / 10) ^ 2 * 3) * eliteMultiplier * bossMultiplier),
        def = math.floor((5 + state.floor * 1.8 + (state.floor / 10) ^ 2 * 2) * eliteMultiplier * bossMultiplier),
    }
end

local function damageToMonster(state, monster, isBoss, rng)
    local stats = state.stats
    local mitigation = monster.def / (monster.def + 200 + state.floor * 5)
    local damage = stats.atk * (1 - mitigation) * (randomInt(rng, 95, 105) / 100)
    local critical = randomFloat(rng) < stats.crit
    local lucky = false
    if critical then
        damage = damage * stats.critDmg
    end
    if stats.luckyChance > 0 and randomFloat(rng) < stats.luckyChance then
        damage = damage * stats.luckyMultiplier
        lucky = true
    end
    if isBoss then
        damage = damage * (1 + stats.bossDamage)
    end
    damage = damage * (1 + stats.damageBonus)
    damage = damage + state.hp * stats.trueDamageRate
    return math.max(1, math.floor(damage)), critical, lucky
end

local function damageToPlayer(state, monster)
    local mitigation = state.stats.def / (state.stats.def + 200 + state.floor * 5)
    local damage = monster.atk * (1 - mitigation)
    damage = damage * (1 - (state.stats.damageReduction or 0))
    return math.max(1, math.floor(damage))
end

local function simulateOfflineBattle(state, eventType, rng)
    refreshDerived(state)
    local monster = monsterFor(state, eventType)
    local monsterHp = monster.hp
    local playerHp = state.hp
    local rounds = 0

    while monsterHp > 0 and playerHp > 0 and rounds < 120 do
        rounds = rounds + 1
        state.hp = Catalog.Clamp(playerHp, 1, state.stats.hp)
        local damage = damageToMonster(state, monster, eventType == "boss", rng)
        monsterHp = monsterHp - damage
        if state.stats.lifeSteal > 0 then
            playerHp = math.min(state.stats.hp, playerHp + math.floor(damage * state.stats.lifeSteal))
        end
        if monsterHp > 0 then
            playerHp = playerHp - damageToPlayer(state, monster)
        end
    end

    state.hp = Catalog.Clamp(playerHp, 0, state.stats.hp)
    return monster, monsterHp <= 0
end

local function settleMonsterVictory(state, eventType, rng, now, events)
    local isBoss = eventType == "boss"
    local isElite = eventType == "elite"
    local exp = math.floor((state.floor * 5 + 10) * (isBoss and 10 or (isElite and 2.3 or 1)))
    local gold = math.floor((state.floor * 8 + 25) * (isBoss and 8 or (isElite and 2 or 1)))
    addCurrency(state, "gold", gold)
    addExp(state, exp, events)
    state.floorKillBonus = math.min(0.50, state.floorKillBonus + 0.01)
    events[#events + 1] = event("battle_reward", { gold = gold, exp = exp })

    local inventoryChanged = false
    local dropRoll = randomInt(rng, 1, 100)
    if isBoss then
        local added, _, inventoryAdded = addGeneratedDrop(state, "purple", true, rng, now, "boss_drop", events)
        if not added then return false, inventoryChanged end
        inventoryChanged = inventoryChanged or inventoryAdded
        if state.floor >= 100 and randomInt(rng, 1, 100) == 1 then
            added, _, inventoryAdded = addGeneratedDrop(state, "myth", true, rng, now, "boss_drop", events)
            if not added then return false, inventoryChanged end
            inventoryChanged = inventoryChanged or inventoryAdded
        end
    elseif isElite and dropRoll <= 48 then
        local added, _, inventoryAdded = addGeneratedDrop(state, "blue", false, rng, now, "elite_drop", events)
        if not added then return false, inventoryChanged end
        inventoryChanged = inventoryChanged or inventoryAdded
    elseif dropRoll <= 22 then
        local added, _, inventoryAdded = addGeneratedDrop(state, nil, false, rng, now, "monster_drop", events)
        if not added then return false, inventoryChanged end
        inventoryChanged = inventoryChanged or inventoryAdded
    end

    if isBoss then
        if (Catalog.GetSetCounts(state).prophecy or 0) >= 12 then
            state.permanentBonus = state.permanentBonus + 0.005
            events[#events + 1] = event("permanent_growth", { amount = 0.005 })
        end
        state.floor = state.floor + 1
        state.maxFloor = math.max(state.maxFloor, state.floor)
        state.position = 0
        state.floorKillBonus = 0
        refreshDerived(state)
        state.hp = state.stats.hp
        events[#events + 1] = event("floor_advanced", { floor = state.floor })
    end
    return true, inventoryChanged
end

local function resolveMonsterOffline(state, eventType, rng, now, events)
    local monster, won = simulateOfflineBattle(state, eventType, rng)
    if not won then
        state.hp = math.max(1, math.floor(state.stats.hp * 0.35))
        events[#events + 1] = event("battle_lost", { monster = monster.name, retainedHpRate = 0.35 })
        return true, false
    end
    return settleMonsterVictory(state, eventType, rng, now, events)
end

local function randomAttack(state, monster, rng)
    local attack = CombatSequence.RandomAttack(function(minimum, maximum)
        return randomInt(rng, minimum, maximum)
    end, monster.lastSequenceIndex, state.stats.atkSpeed)
    monster.phase = "windup"
    monster.phaseRemaining = attack.windupSeconds
    monster.sequenceIndex = attack.sequenceIndex
    monster.sequenceId = attack.sequenceId
    monster.fps = attack.fps
    monster.hitFrame = attack.hitFrame
    monster.endFrame = attack.endFrame
    monster.recoverySeconds = attack.recoverySeconds
    monster.lastSequenceIndex = attack.sequenceIndex
    return attack
end

local function attackStartedEvent(monster, attack)
    return event("attack_started", {
        monsterId = monster.id,
        eventType = monster.eventType,
        attackSerial = monster.attackSerial,
        sequenceIndex = attack.sequenceIndex,
        sequenceId = attack.sequenceId,
        fps = attack.fps,
        hitFrame = attack.hitFrame,
        endFrame = attack.endFrame,
        windupSeconds = attack.windupSeconds,
        recoverySeconds = attack.recoverySeconds,
    })
end

local function beginOnlineBattle(state, eventType, rng, events)
    refreshDerived(state)
    local generated = monsterFor(state, eventType)
    local monster = {
        id = string.format("floor:%d:position:%d", state.floor, state.position),
        eventType = eventType,
        name = generated.name,
        hp = generated.hp,
        maxHp = generated.hp,
        atk = generated.atk,
        def = generated.def,
        phase = "windup",
        phaseRemaining = 0,
        attackSerial = 1,
        lastSequenceIndex = 0,
    }
    state.currentMonster = monster
    state.currentEvent = eventType
    local attack = randomAttack(state, monster, rng)
    events[#events + 1] = event("battle_started", {
        monsterId = monster.id,
        eventType = eventType,
        monster = monster.name,
        monsterHp = monster.hp,
        monsterMaxHp = monster.maxHp,
    })
    events[#events + 1] = attackStartedEvent(monster, attack)
end

local resolveChest
local resolveMerchant
local resolveRandomEvent

local function advanceOnlineCombatWorking(state, rng, now)
    local events = {}
    local inventoryChanged = false
    local monster = state.currentMonster

    if not monster then
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
        if state.hp <= 0 then
            state.hp = math.max(1, math.floor(state.stats.hp * 0.50))
        end
        state.position = math.min(100, state.position + 1)
        local eventType = Catalog.GetCellType(state.position, state.floor)
        state.currentEvent = eventType
        events[#events + 1] = event("cell_entered", {
            position = state.position,
            floor = state.floor,
            eventType = eventType,
        })
        if eventType == "monster" or eventType == "elite" or eventType == "boss" then
            beginOnlineBattle(state, eventType, rng, events)
            return state, "battle_started", events, false
        end
        local completed = true
        if eventType == "chest" then
            completed, inventoryChanged = resolveChest(state, rng, now, events)
        elseif eventType == "merchant" then
            resolveMerchant(state, events)
        else
            resolveRandomEvent(state, rng, events)
        end
        if not completed then
            state.autoRun = false
            state.pauseReason = "inventory_full"
            events[#events + 1] = event("inventory_full", { capacity = Catalog.INVENTORY_CAP })
            return state, "inventory_full", events, false
        end
        refreshDerived(state)
        return state, "cell_resolved", events, inventoryChanged
    end

    if monster.phase == "recovery" then
        monster.attackSerial = monster.attackSerial + 1
        local attack = randomAttack(state, monster, rng)
        events[#events + 1] = attackStartedEvent(monster, attack)
        return state, "attack_started", events, false
    end

    local damage, critical, lucky = damageToMonster(
        state,
        monster,
        monster.eventType == "boss",
        rng
    )
    monster.hp = math.max(0, monster.hp - damage)
    if state.stats.lifeSteal > 0 then
        state.hp = math.min(
            state.stats.hp,
            state.hp + math.floor(damage * state.stats.lifeSteal)
        )
    end
    events[#events + 1] = event("battle_hit", {
        monsterId = monster.id,
        eventType = monster.eventType,
        attackSerial = monster.attackSerial,
        sequenceIndex = monster.sequenceIndex,
        sequenceId = monster.sequenceId,
        hitFrame = monster.hitFrame,
        damage = damage,
        monsterHp = monster.hp,
        monsterMaxHp = monster.maxHp,
        critical = critical,
        lucky = lucky,
    })

    if monster.hp <= 0 then
        local eventType = monster.eventType
        events[#events + 1] = event("battle_won", {
            monsterId = monster.id,
            eventType = eventType,
        })
        state.currentMonster = nil
        local completed
        completed, inventoryChanged = settleMonsterVictory(state, eventType, rng, now, events)
        if not completed then
            state.autoRun = false
            state.pauseReason = "inventory_full"
            return state, "inventory_full", events, inventoryChanged
        end
        refreshDerived(state)
        return state, "battle_won", events, inventoryChanged
    end

    state.hp = state.hp - damageToPlayer(state, monster)
    if state.hp <= 0 then
        state.hp = math.max(1, math.floor(state.stats.hp * 0.35))
        monster.hp = monster.maxHp
        events[#events + 1] = event("battle_lost", {
            monster = monster.name,
            retainedHpRate = 0.35,
            monsterHp = monster.hp,
            monsterMaxHp = monster.maxHp,
        })
    end
    monster.phase = "recovery"
    monster.phaseRemaining = math.max(
        CombatSequence.MIN_PHASE_SECONDS,
        monster.recoverySeconds or CombatSequence.MIN_PHASE_SECONDS
    )
    return state, "battle_hit", events, false
end

resolveChest = function(state, rng, now, events)
    local gold = math.floor(state.floor * 20 + randomInt(rng, 80, 260))
    local fragments = randomInt(rng, 3, 12)
    addCurrency(state, "gold", gold)
    addCurrency(state, "fragments", fragments)
    events[#events + 1] = event("chest_reward", { gold = gold, fragments = fragments })
    if randomInt(rng, 1, 100) <= 35 then
        local added, _, inventoryAdded = addGeneratedDrop(state, "blue", false, rng, now, "chest_drop", events)
        return added, inventoryAdded
    end
    return true, false
end

resolveMerchant = function(state, events)
    local price = math.floor(700 + state.floor * 35)
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
        local gold = 300 + state.floor * 15
        addCurrency(state, "gold", gold)
        events[#events + 1] = event("wish_pool", { gold = gold })
    elseif roll == 2 then
        local distance = randomInt(rng, 5, 10)
        state.position = math.min(99, state.position + distance)
        events[#events + 1] = event("teleport", { distance = distance, position = state.position })
    elseif roll == 3 then
        local healed = math.floor(state.stats.hp * 0.18)
        state.hp = math.min(state.stats.hp, state.hp + healed)
        events[#events + 1] = event("altar_heal", { hp = healed })
    else
        addCurrency(state, "fragments", 18)
        events[#events + 1] = event("abyss_echo", { fragments = 18 })
    end
end

function GameEngine.SetAutoRun(inputState, enabled, now)
    if type(enabled) ~= "boolean" then
        return failure(inputState, now, "INVALID_ARGUMENT", "enabled must be a boolean")
    end
    local working = stateCopy(inputState, now)
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
    return finalize(inputState, working, now, "auto_run_changed", {
        event("auto_run_changed", { enabled = enabled }),
    }, false, false)
end

local function advanceOneCellWorking(working, rng, now)
    local before = TableUtils.DeepCopy(working)
    if working.currentMonster then
        return advanceOnlineCombatWorking(working, rng, now)
    end
    if #working.inventory >= Catalog.INVENTORY_CAP and working.inventoryPolicy.pauseOnFull and not hasAutoDispositionPolicy(working) then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        return working, "inventory_full", {
            event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
        }, false
    end

    if working.hp <= 0 then
        working.hp = math.floor(working.stats.hp * 0.50)
    end
    working.position = math.min(100, working.position + 1)
    local eventType = Catalog.GetCellType(working.position, working.floor)
    working.currentEvent = eventType
    local events = {
        event("cell_entered", { position = working.position, floor = working.floor, eventType = eventType }),
    }
    local completed = true
    local inventoryChanged = false

    if eventType == "monster" or eventType == "elite" or eventType == "boss" then
        completed, inventoryChanged = resolveMonsterOffline(working, eventType, rng, now, events)
    elseif eventType == "chest" then
        completed, inventoryChanged = resolveChest(working, rng, now, events)
    elseif eventType == "merchant" then
        resolveMerchant(working, events)
    else
        resolveRandomEvent(working, rng, events)
    end

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
        working.position = math.min(100, working.position + 1)
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
    if not working.currentMonster then
        local nextWorking, kind, events, inventoryChanged =
            advanceOnlineCombatWorking(
                working,
                rng,
                now
            )
        return finalize(
            inputState,
            nextWorking,
            now,
            kind,
            events,
            inventoryChanged,
            false
        )
    end

    local monster = working.currentMonster
    if monster.phaseRemaining > 0 then
        monster.phaseRemaining = math.max(0, monster.phaseRemaining - timeStep)
        if monster.phaseRemaining > 0 then
            return finalize(inputState, working, now, "combat_phase_waiting", {}, false, false)
        end
        if monster.phase == "recovery" then
            local attack = randomAttack(working, monster, rng)
            return finalize(inputState, working, now, "attack_started", {
                attackStartedEvent(monster, attack),
            }, false, false)
        end
    end

    local kind, events, inventoryChanged
    working, kind, events, inventoryChanged = advanceOnlineCombatWorking(working, rng, now)
    return finalize(inputState, working, now, kind, events, inventoryChanged, false)
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
    refreshDerived(working)
    return finalize(inputState, working, now, "equipment_changed", {
        event("equipment_equipped", { itemId = item.id, slot = item.slot }),
    }, false, true)
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
    local changed = 0
    for _, slot in ipairs(Catalog.SLOTS) do
        local current = findItem(working, working.equipped[slot.id])
        local best = current
        local bestPower = current and Catalog.GetItemPower(current) or -1
        for _, item in ipairs(working.inventory) do
            local power = item.slot == slot.id and Catalog.GetItemPower(item) or -1
            if power > bestPower then
                best = item
                bestPower = power
            end
        end
        if best and working.equipped[slot.id] ~= best.id then
            working.equipped[slot.id] = best.id
            changed = changed + 1
        end
    end
    if changed == 0 then
        return noCommit(inputState, now, "auto_equip_unchanged")
    end
    refreshDerived(working)
    return finalize(inputState, working, now, "auto_equip", {
        event("auto_equip", { changedSlots = changed }),
    }, false, true)
end

GameEngine.AutoEquipBest = GameEngine.AutoEquip

function GameEngine.Decompose(inputState, maximumRank, now, candidateIds)
    maximumRank = TableUtils.ToInteger(maximumRank, -1)
    if maximumRank < 1 or maximumRank > 4 then
        return failure(inputState, now, "INVALID_ARGUMENT", "maximumRank must be between 1 and 4")
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
    local gold = 0
    for _, item in ipairs(working.inventory) do
        local rarity = Catalog.RARITIES[item.rarity]
        local explicitlySelected = selected == nil or selected[item.id] == true
        if explicitlySelected and rarity and rarity.rank <= maximumRank
            and not equipped[item.id] and not item.locked then
            removed = removed + 1
            local refund = Catalog.GetDecomposeRefund(item)
            fragments = fragments + refund.fragments
            gold = gold + refund.gold
            addCurrency(working, "gold", refund.gold)
        else
            kept[#kept + 1] = item
        end
    end
    if removed == 0 then
        return noCommit(inputState, now, "decompose_empty")
    end
    working.inventory = kept
    addCurrency(working, "fragments", fragments)
    if working.pauseReason == "inventory_full" then
        working.pauseReason = nil
    end
    refreshDerived(working)
    return finalize(inputState, working, now, "equipment_decomposed", {
        event("equipment_decomposed", { count = removed, fragments = fragments, gold = gold }),
    }, true, false)
end

GameEngine.DecomposeByRank = GameEngine.Decompose

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
    local goldCost = 1200 + item.enhance * 900
    local fragmentCost = 8 + item.enhance * 5
    if not hasCurrency(working, "gold", goldCost) or not hasCurrency(working, "fragments", fragmentCost) then
        return failure(inputState, now, "INSUFFICIENT_RESOURCES", "not enough gold or fragments")
    end
    spendCurrency(working, "gold", goldCost)
    spendCurrency(working, "fragments", fragmentCost)
    item.enhance = item.enhance + 1
    item.investedGold = math.min(Catalog.MAX_VALUE, (item.investedGold or 0) + goldCost)
    item.investedFragments = math.min(Catalog.MAX_VALUE, (item.investedFragments or 0) + fragmentCost)
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

function GameEngine.Star(inputState, slotId, now)
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

    local equipped = equippedIdSet(working)
    local duplicateIndex = nil
    for index, candidate in ipairs(working.inventory) do
        if candidate.id ~= item.id
            and candidate.equipmentId == item.equipmentId
            and not candidate.locked
            and not equipped[candidate.id] then
            duplicateIndex = index
            break
        end
    end
    if not duplicateIndex then
        return failure(inputState, now, "DUPLICATE_REQUIRED", "an unequipped item with the same name is required")
    end
    local consumed = working.inventory[duplicateIndex]
    local consumedId = consumed.id
    local refund = Catalog.GetDecomposeRefund(consumed)
    item.investedGold = math.min(Catalog.MAX_VALUE, (item.investedGold or 0) + refund.gold)
    item.investedFragments = math.min(Catalog.MAX_VALUE, (item.investedFragments or 0) + refund.fragments)
    table.remove(working.inventory, duplicateIndex)
    item.star = item.star + 1
    if working.pauseReason == "inventory_full" then
        working.pauseReason = nil
    end
    refreshDerived(working)
    return finalize(inputState, working, now, "equipment_starred", {
        event("equipment_starred", { itemId = item.id, consumedItemId = consumedId, star = item.star }),
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
    }, false, false)
end

GameEngine.PrepareLogin = GameEngine.AccrueOffline

local function accumulateOfflineEvent(summary, value)
    if value.kind == "battle_reward" then
        summary.gold = summary.gold + (value.gold or 0)
        summary.exp = summary.exp + (value.exp or 0)
    elseif value.kind == "chest_reward" then
        summary.gold = summary.gold + (value.gold or 0)
        summary.fragments = summary.fragments + (value.fragments or 0)
    elseif value.kind == "merchant_trade" or value.kind == "abyss_echo" then
        summary.fragments = summary.fragments + (value.fragments or 0)
    elseif value.kind == "wish_pool" then
        summary.gold = summary.gold + (value.gold or 0)
    elseif value.kind == "equipment_auto_disposed" then
        summary.gold = summary.gold + (value.gold or 0)
        summary.fragments = summary.fragments + (value.fragments or 0)
    elseif value.kind == "equipment_drop" then
        summary.equipment = summary.equipment + 1
    end
end

function GameEngine.CollectOffline(inputState, now)
    now = nowInteger(now)
    local working = stateCopy(inputState, now)
    local seconds = math.min(working.pendingOfflineSeconds, Catalog.OFFLINE_MAX_SECONDS)
    local availableSteps = math.floor(seconds / Catalog.OFFLINE_STEP_SECONDS)
    if availableSteps <= 0 then
        return failure(inputState, now, "NO_OFFLINE_REWARD", "offline reward requires at least 15 seconds")
    end

    local summary = { gold = 0, exp = 0, fragments = 0, equipment = 0 }
    local processedSteps = 0
    local interrupted = false
    local inventoryChanged = false
    for _ = 1, availableSteps do
        local nextWorking, kind, stepEvents, stepInventoryChanged = advanceOneCellWorking(working, nil, now)
        if kind == "inventory_full" then
            working = nextWorking
            interrupted = true
            break
        end
        working = nextWorking
        processedSteps = processedSteps + 1
        inventoryChanged = inventoryChanged or stepInventoryChanged
        for _, value in ipairs(stepEvents or {}) do
            accumulateOfflineEvent(summary, value)
        end
        if working.pauseReason == "inventory_full" then
            interrupted = true
            break
        end
    end

    if processedSteps <= 0 then
        return failure(inputState, now, "INVENTORY_FULL", "inventory is full; clear space before collecting offline rewards")
    end

    local processedSeconds = math.floor(processedSteps * Catalog.OFFLINE_STEP_SECONDS)
    working.pendingOfflineSeconds = math.max(0, seconds - processedSeconds)
    return finalize(inputState, working, now, "offline_collected", {
        event("offline_collected", {
            seconds = seconds,
            processedSeconds = processedSeconds,
            remainingSeconds = working.pendingOfflineSeconds,
            rewardRate = Catalog.OFFLINE_REWARD_RATE,
            gold = summary.gold,
            exp = summary.exp,
            fragments = summary.fragments,
            equipment = summary.equipment,
            interrupted = interrupted,
        }),
    }, inventoryChanged, false)
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
    if specification.rarity ~= nil and specification.rarity ~= definition.rarity then
        return failure(inputState, now, "INVALID_RARITY", "equipment rarity does not match definition")
    end
    local working = stateCopy(inputState, now)
    local item = {
        id = allocateItemId(working),
        equipmentId = definition.id,
        level = Catalog.Clamp(TableUtils.ToInteger(specification.level, working.floor), 1, 1000000),
        enhance = Catalog.Clamp(TableUtils.ToInteger(specification.enhance, 0), 0, 1000),
        star = Catalog.Clamp(TableUtils.ToInteger(specification.star, 0), 0, Catalog.MAX_STAR),
        locked = specification.locked == true,
        acquiredAt = nowInteger(now),
        source = "admin_grant",
        investedGold = 0,
        investedFragments = 0,
    }
    local events = {}
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
        rarity = definition.rarity,
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
        position = { 0, 100 },
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
    working.hp = working.stats.hp
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

return GameEngine
