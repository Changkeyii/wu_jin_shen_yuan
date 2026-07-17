local Catalog = require("server.domain.Catalog")
local StateNormalizer = require("server.domain.StateNormalizer")
local TableUtils = require("server.domain.TableUtils")

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
    "currentEvent",
}

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
    state.hp = Catalog.Clamp(TableUtils.ToInteger(state.hp, state.stats.hp), 1, state.stats.hp)
    state.currentEvent = Catalog.GetCellType(math.max(1, state.position), state.floor)
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
        money = {
            abyss_gold = persisted.gold,
            abyss_fragments = persisted.fragments,
            abyss_myth_shards = persisted.mythShards,
        },
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
        if previous[field] ~= current[field] then
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

local function allocateItemId(state)
    local used = {}
    for _, item in ipairs(state.inventory) do
        used[item.id] = true
    end
    local itemId
    repeat
        itemId = string.format("eq-%06d", state.nextItemId)
        state.nextItemId = state.nextItemId + 1
    until not used[itemId]
    return itemId
end

local function generatedEquipment(state, minimumRarity, isBoss, rng)
    local floor = state.floor
    local roll = randomInt(rng, 1, 1000)
    local rarity = "common"
    local epicChance = math.min(650, 200 + math.floor(floor / 10) * 50)
    if minimumRarity == "myth" or (floor >= 100 and isBoss and roll <= 10) then
        rarity = "myth"
    elseif minimumRarity == "epic" or (isBoss and roll <= epicChance) or roll <= math.min(120, floor * 2) then
        rarity = "epic"
    elseif minimumRarity == "purple" or roll <= 360 then
        rarity = "purple"
    elseif roll <= 680 then
        rarity = "blue"
    end
    if minimumRarity and Catalog.RARITIES[minimumRarity]
        and Catalog.RARITIES[rarity].rank < Catalog.RARITIES[minimumRarity].rank then
        rarity = minimumRarity
    end

    local slot = Catalog.SLOTS[randomInt(rng, 1, #Catalog.SLOTS)]
    local setId = nil
    if rarity == "epic" or rarity == "myth" then
        setId = Catalog.SET_ORDER[randomInt(rng, 1, #Catalog.SET_ORDER)]
    end
    local base = floor * Catalog.RARITIES[rarity].multiplier
    local item = {
        id = nil,
        name = Catalog.RARITIES[rarity].name .. "·" .. (setId and Catalog.SETS[setId].shortName or "制式") .. "·" .. slot.name,
        slot = slot.id,
        category = slot.category,
        rarity = rarity,
        setId = setId,
        level = floor,
        atk = math.floor((slot.category == "weapon" and 20 or 6) + base * 3.4 + randomInt(rng, 0, 18)),
        def = math.floor((slot.category == "armor" and 18 or 5) + base * 2.4 + randomInt(rng, 0, 12)),
        hp = math.floor(60 + base * 18 + randomInt(rng, 0, 50)),
        crit = (slot.category == "jewelry" and 0.02 or 0) + (rarity == "epic" and 0.01 or 0) + (rarity == "myth" and 0.02 or 0),
        critDmg = (slot.category == "special" and 0.08 or 0) + (rarity == "myth" and 0.12 or 0),
        atkSpeed = (setId == "voyage" and 0.05 or 0) + (rarity == "myth" and 0.05 or 0),
        enhance = 0,
        star = 0,
    }
    if rarity == "myth" and setId then
        slot = Catalog.SLOT_BY_ID[Catalog.SETS[setId].mythSlot] or slot
        item.name = Catalog.SETS[setId].mythName
        item.slot = slot.id
        item.category = slot.category
    end
    item.id = allocateItemId(state)
    item.power = Catalog.GetItemPower(item)
    return item
end

local function addGeneratedDrop(state, minimumRarity, isBoss, rng, events)
    local item = generatedEquipment(state, minimumRarity, isBoss, rng)
    if #state.inventory >= Catalog.INVENTORY_CAP then
        return false, item
    end
    state.inventory[#state.inventory + 1] = item
    events[#events + 1] = event("equipment_drop", {
        itemId = item.id,
        name = item.name,
        rarity = item.rarity,
        slot = item.slot,
    })
    return true, item
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
    if (Catalog.GetSetCounts(state).voyage or 0) >= 5 then
        damage = damage * (1 - math.min(0.20, state.floor * 0.01))
    end
    return math.max(1, math.floor(damage))
end

local function simulateBattle(state, eventType, rng, events)
    refreshDerived(state)
    local monster = monsterFor(state, eventType)
    local monsterHp = monster.hp
    local playerHp = state.hp
    local hits = math.floor(1 + (state.stats.atkSpeed - 1.0) * 10 + 0.0001)
    hits = Catalog.Clamp(hits, 1, 3)
    local rounds = 0
    local lastDamage = 0
    local lastCritical = false
    local lastLucky = false

    while monsterHp > 0 and playerHp > 0 and rounds < 40 do
        rounds = rounds + 1
        for _ = 1, hits do
            state.hp = Catalog.Clamp(playerHp, 1, state.stats.hp)
            local damage, critical, lucky = damageToMonster(state, monster, eventType == "boss", rng)
            lastDamage = damage
            lastCritical = critical
            lastLucky = lucky
            monsterHp = monsterHp - damage
            if state.stats.lifeSteal > 0 then
                playerHp = math.min(state.stats.hp, playerHp + math.floor(damage * state.stats.lifeSteal))
            end
            if monsterHp <= 0 then
                break
            end
        end
        if monsterHp > 0 then
            playerHp = playerHp - damageToPlayer(state, monster)
        end
    end

    state.hp = Catalog.Clamp(playerHp, 0, state.stats.hp)
    events[#events + 1] = event("battle", {
        eventType = eventType,
        monster = monster.name,
        won = monsterHp <= 0,
        rounds = rounds,
        lastDamage = lastDamage,
        critical = lastCritical,
        lucky = lastLucky,
    })
    return monster, monsterHp <= 0
end

local function resolveMonster(state, eventType, rng, events)
    local monster, won = simulateBattle(state, eventType, rng, events)
    if not won then
        state.hp = math.max(1, math.floor(state.stats.hp * 0.35))
        events[#events + 1] = event("battle_lost", { monster = monster.name, retainedHpRate = 0.35 })
        return true, false
    end

    local isBoss = eventType == "boss"
    local isElite = eventType == "elite"
    local exp = math.floor((state.floor * 5 + 10) * (isBoss and 10 or (isElite and 2.3 or 1)))
    local gold = math.floor((state.floor * 8 + 25) * (isBoss and 8 or (isElite and 2 or 1)))
    state.gold = state.gold + gold
    addExp(state, exp, events)
    state.floorKillBonus = math.min(0.50, state.floorKillBonus + 0.01)
    events[#events + 1] = event("battle_reward", { gold = gold, exp = exp })

    local inventoryChanged = false
    local dropRoll = randomInt(rng, 1, 100)
    if isBoss then
        local added = addGeneratedDrop(state, "purple", true, rng, events)
        if not added then return false, inventoryChanged end
        inventoryChanged = true
        if state.floor >= 100 and randomInt(rng, 1, 100) == 1 then
            added = addGeneratedDrop(state, "myth", true, rng, events)
            if not added then return false, inventoryChanged end
            inventoryChanged = true
        end
    elseif isElite and dropRoll <= 48 then
        local added = addGeneratedDrop(state, "blue", false, rng, events)
        if not added then return false, inventoryChanged end
        inventoryChanged = true
    elseif dropRoll <= 22 then
        local added = addGeneratedDrop(state, nil, false, rng, events)
        if not added then return false, inventoryChanged end
        inventoryChanged = true
    end

    if isBoss then
        if (Catalog.GetSetCounts(state).prophecy or 0) >= 8 then
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

local function resolveChest(state, rng, events)
    local gold = math.floor(state.floor * 20 + randomInt(rng, 80, 260))
    local fragments = randomInt(rng, 3, 12)
    state.gold = state.gold + gold
    state.fragments = state.fragments + fragments
    events[#events + 1] = event("chest_reward", { gold = gold, fragments = fragments })
    if randomInt(rng, 1, 100) <= 35 then
        local added = addGeneratedDrop(state, "blue", false, rng, events)
        return added, added
    end
    return true, false
end

local function resolveMerchant(state, events)
    local price = math.floor(700 + state.floor * 35)
    if state.gold >= price then
        state.gold = state.gold - price
        state.fragments = state.fragments + 10
        events[#events + 1] = event("merchant_trade", { goldSpent = price, fragments = 10 })
    else
        events[#events + 1] = event("merchant_skipped", { price = price, reason = "insufficient_gold" })
    end
end

local function resolveRandomEvent(state, rng, events)
    local roll = randomInt(rng, 1, 4)
    if roll == 1 then
        local gold = 300 + state.floor * 15
        state.gold = state.gold + gold
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
        state.fragments = state.fragments + 18
        events[#events + 1] = event("abyss_echo", { fragments = 18 })
    end
end

function GameEngine.SetAutoRun(inputState, enabled, now)
    if type(enabled) ~= "boolean" then
        return failure(inputState, now, "INVALID_ARGUMENT", "enabled must be a boolean")
    end
    local working = stateCopy(inputState, now)
    if enabled and #working.inventory >= Catalog.INVENTORY_CAP then
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

function GameEngine.AdvanceOneCell(inputState, rng, now)
    local working = stateCopy(inputState, now)
    if #working.inventory >= Catalog.INVENTORY_CAP then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        return finalize(inputState, working, now, "inventory_full", {
            event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
        }, false, false)
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
        completed, inventoryChanged = resolveMonster(working, eventType, rng, events)
    elseif eventType == "chest" then
        completed, inventoryChanged = resolveChest(working, rng, events)
    elseif eventType == "merchant" then
        resolveMerchant(working, events)
    else
        resolveRandomEvent(working, rng, events)
    end

    if not completed then
        local paused = stateCopy(inputState, now)
        paused.autoRun = false
        paused.pauseReason = "inventory_full"
        return finalize(inputState, paused, now, "inventory_full", {
            event("inventory_full", {
                capacity = Catalog.INVENTORY_CAP,
                rollback = "cell_settlement",
            }),
        }, false, false)
    end

    refreshDerived(working)
    if #working.inventory >= Catalog.INVENTORY_CAP then
        working.autoRun = false
        working.pauseReason = "inventory_full"
        events[#events + 1] = event("inventory_full", { capacity = Catalog.INVENTORY_CAP })
    end
    return finalize(inputState, working, now, "cell_resolved", events, inventoryChanged, false)
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

function GameEngine.Decompose(inputState, maximumRank, now)
    maximumRank = TableUtils.ToInteger(maximumRank, -1)
    if maximumRank < 1 or maximumRank > 4 then
        return failure(inputState, now, "INVALID_ARGUMENT", "maximumRank must be between 1 and 4")
    end

    local working = stateCopy(inputState, now)
    local equipped = equippedIdSet(working)
    local kept = {}
    local removed = 0
    local fragments = 0
    for _, item in ipairs(working.inventory) do
        local rarity = Catalog.RARITIES[item.rarity]
        if rarity and rarity.rank <= maximumRank and not equipped[item.id] then
            removed = removed + 1
            fragments = fragments + rarity.fragments + (item.enhance or 0) * 2
        else
            kept[#kept + 1] = item
        end
    end
    if removed == 0 then
        return noCommit(inputState, now, "decompose_empty")
    end
    working.inventory = kept
    working.fragments = working.fragments + fragments
    if working.pauseReason == "inventory_full" then
        working.pauseReason = nil
    end
    refreshDerived(working)
    return finalize(inputState, working, now, "equipment_decomposed", {
        event("equipment_decomposed", { count = removed, fragments = fragments }),
    }, true, false)
end

GameEngine.DecomposeByRank = GameEngine.Decompose

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
    if working.gold < goldCost or working.fragments < fragmentCost then
        return failure(inputState, now, "INSUFFICIENT_RESOURCES", "not enough gold or fragments")
    end
    working.gold = working.gold - goldCost
    working.fragments = working.fragments - fragmentCost
    item.enhance = item.enhance + 1
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
        if candidate.id ~= item.id and candidate.name == item.name and not equipped[candidate.id] then
            duplicateIndex = index
            break
        end
    end
    if not duplicateIndex then
        return failure(inputState, now, "DUPLICATE_REQUIRED", "an unequipped item with the same name is required")
    end
    local consumedId = working.inventory[duplicateIndex].id
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

function GameEngine.CollectOffline(inputState, now)
    local working = stateCopy(inputState, now)
    local seconds = math.min(working.pendingOfflineSeconds, Catalog.OFFLINE_MAX_SECONDS)
    if seconds <= 0 then
        return failure(inputState, now, "NO_OFFLINE_REWARD", "there is no offline reward to collect")
    end
    local steps = math.floor(seconds / 5)
    local gold = math.floor(steps * (working.floor * 5 + 20) * 0.6)
    local exp = math.floor(steps * (working.floor * 5 + 10) * 0.6)
    local fragments = math.floor(steps / 18)
    working.gold = working.gold + gold
    working.fragments = working.fragments + fragments
    working.pendingOfflineSeconds = 0
    local events = {
        event("offline_collected", {
            seconds = seconds,
            gold = gold,
            exp = exp,
            fragments = fragments,
        }),
    }
    addExp(working, exp, events)
    refreshDerived(working)
    return finalize(inputState, working, now, "offline_collected", events, false, false)
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
    working[currency] = working[currency] + amount
    return finalize(inputState, working, now, "currency_granted", {
        event("currency_granted", { currency = currency, amount = amount }),
    }, false, false)
end

function GameEngine.GrantEquipment(inputState, specification, now)
    if type(specification) ~= "table" then
        return failure(inputState, now, "INVALID_ARGUMENT", "equipment specification is required")
    end
    if not Catalog.SLOT_BY_ID[specification.slot] then
        return failure(inputState, now, "INVALID_SLOT", "unknown equipment slot")
    end
    if not Catalog.RARITIES[specification.rarity] then
        return failure(inputState, now, "INVALID_RARITY", "unknown equipment rarity")
    end
    if specification.setId ~= nil and not Catalog.SETS[specification.setId] then
        return failure(inputState, now, "INVALID_SET", "unknown equipment set")
    end
    local working = stateCopy(inputState, now)
    if #working.inventory >= Catalog.INVENTORY_CAP then
        return failure(inputState, now, "INVENTORY_FULL", "inventory is full", {
            event("inventory_full", { capacity = Catalog.INVENTORY_CAP }),
        })
    end
    local slot = Catalog.SLOT_BY_ID[specification.slot]
    local function boundedStat(name, maximum)
        return Catalog.Clamp(TableUtils.ToInteger(specification[name], 0), 0, maximum)
    end
    local item = {
        id = allocateItemId(working),
        name = type(specification.name) == "string" and specification.name:sub(1, 80)
            or (Catalog.RARITIES[specification.rarity].name .. "·GM·" .. slot.name),
        slot = slot.id,
        category = slot.category,
        rarity = specification.rarity,
        setId = specification.setId,
        level = Catalog.Clamp(TableUtils.ToInteger(specification.level, working.floor), 1, 1000000),
        atk = boundedStat("atk", 100000000),
        def = boundedStat("def", 100000000),
        hp = boundedStat("hp", 100000000),
        crit = Catalog.Clamp(TableUtils.IsFiniteNumber(specification.crit) and specification.crit or 0, 0, 1),
        critDmg = Catalog.Clamp(TableUtils.IsFiniteNumber(specification.critDmg) and specification.critDmg or 0, 0, 10),
        atkSpeed = Catalog.Clamp(TableUtils.IsFiniteNumber(specification.atkSpeed) and specification.atkSpeed or 0, 0, 3),
        enhance = Catalog.Clamp(TableUtils.ToInteger(specification.enhance, 0), 0, 1000),
        star = Catalog.Clamp(TableUtils.ToInteger(specification.star, 0), 0, 5),
    }
    item.power = Catalog.GetItemPower(item)
    working.inventory[#working.inventory + 1] = item
    refreshDerived(working)
    if #working.inventory >= Catalog.INVENTORY_CAP then
        working.autoRun = false
        working.pauseReason = "inventory_full"
    end
    return finalize(inputState, working, now, "equipment_granted", {
        event("equipment_granted", { itemId = item.id, rarity = item.rarity, slot = item.slot }),
    }, true, false)
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
