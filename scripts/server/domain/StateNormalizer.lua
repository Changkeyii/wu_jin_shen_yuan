local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local GameStateSchema = require("shared.GameStateSchema")
local CombatSequence = require("shared.CombatSequence")
local LargeNumber = require("shared.LargeNumber")

local StateNormalizer = {}

local function clampInteger(value, minimum, maximum, fallback)
    local integer = TableUtils.ToInteger(value, fallback)
    return Catalog.Clamp(integer, minimum, maximum)
end

local function clampNumber(value, minimum, maximum, fallback)
    if not TableUtils.IsFiniteNumber(value) then
        return fallback
    end
    return Catalog.Clamp(value, minimum, maximum)
end

local function instanceUuidFromSequence(sequence)
    local value = math.max(1, TableUtils.ToInteger(sequence, 1))
    local hex = string.format("%012x", value)
    return string.format("00000000-0000-4000-8000-%s", hex)
end

local function nextEquipmentId(usedIds, nextId)
    nextId = math.max(1, nextId)
    local itemId
    repeat
        itemId = instanceUuidFromSequence(nextId)
        nextId = nextId + 1
    until not usedIds[itemId]
    return itemId, nextId
end

local function isInstanceUuid(value)
    return type(value) == "string"
        and #value == 36
        and string.match(value, "^[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+$") ~= nil
end

local function normalizeItemId(rawId, usedIds, nextId)
    if isInstanceUuid(rawId) and not usedIds[rawId] then
        return rawId, nextId
    end
    return nextEquipmentId(usedIds, nextId)
end

local function sanitizeEquipment(rawItem, itemId)
    local definition = Catalog.ResolveEquipment(rawItem)
    if not definition then return nil end
    return {
        id = itemId,
        equipmentId = definition.id,
        name = definition.name,
        slot = definition.slot,
        category = definition.category,
        rarity = definition.rarity,
        setId = definition.setId,
        level = clampInteger(rawItem.level, 1, 1000000, definition.level or 1),
        enhance = clampInteger(rawItem.enhance, 0, Catalog.MAX_ENHANCE, 0),
        star = clampInteger(rawItem.star, 0, Catalog.MAX_STAR, 0),
        locked = rawItem.locked == true,
        acquiredAt = math.max(0, TableUtils.ToInteger(rawItem.acquiredAt, 0)),
        source = type(rawItem.source) == "string" and rawItem.source:match("^[%w%._:%-]+$") and rawItem.source or "legacy",
        investedGold = clampInteger(rawItem.investedGold, 0, Catalog.MAX_VALUE, 0),
        investedFragments = clampInteger(rawItem.investedFragments, 0, Catalog.MAX_VALUE, 0),
    }
end

local function materialKind(item)
    local name = type(item.name) == "string" and item.name or ""
    if name:find("神话") or name:lower():find("myth") then
        return "mythShards"
    end
    if name:find("碎片") or name:lower():find("fragment") then
        return "fragments"
    end
    return nil
end

function StateNormalizer.Normalize(rawState, now)
    rawState = type(rawState) == "table" and rawState or {}
    now = math.max(0, TableUtils.ToInteger(now, os.time()))

    local state = {
        schemaVersion = Catalog.SCHEMA_VERSION,
        revision = math.max(0, TableUtils.ToInteger(rawState.revision, 0)),
        updatedAt = math.max(0, TableUtils.ToInteger(rawState.updatedAt, now)),
        lastActiveAt = math.max(0, TableUtils.ToInteger(rawState.lastActiveAt, now)),
        pendingOfflineSeconds = clampInteger(rawState.pendingOfflineSeconds or rawState.offlineSeconds, 0, Catalog.OFFLINE_MAX_SECONDS, 0),
        level = math.max(1, TableUtils.ToInteger(rawState.level, 1)),
        exp = math.max(0, TableUtils.ToInteger(rawState.exp, 0)),
        floor = math.max(1, TableUtils.ToInteger(rawState.floor, 1)),
        maxFloor = math.max(1, TableUtils.ToInteger(rawState.maxFloor, rawState.floor or 1)),
        position = clampInteger(rawState.position, 0, 100, 0),
        gold = LargeNumber.Normalize(rawState.gold),
        fragments = LargeNumber.Normalize(rawState.fragments),
        mythShards = LargeNumber.Normalize(rawState.mythShards),
        autoRun = rawState.autoRun == true,
        pauseReason = type(rawState.pauseReason) == "string" and rawState.pauseReason or nil,
        floorKillBonus = clampNumber(rawState.floorKillBonus, 0, 0.50, 0),
        permanentBonus = clampNumber(rawState.permanentBonus, 0, 1000, 0),
        inventoryPolicy = {
            pauseOnFull = true,
            autoDecompose = false,
            autoSell = false,
            decomposeRarities = {},
            sellRarities = {},
        },
        currentMonster = nil,
        nextItemId = math.max(1, TableUtils.ToInteger(rawState.nextItemId or rawState.itemSequence, 1)),
        inventory = {},
        equipped = {},
        consumables = {},
        appliedGmCommandIds = GameStateSchema.NormalizeAppliedGmCommandIds(rawState.appliedGmCommandIds),
    }

    local rawPolicy = type(rawState.inventoryPolicy) == "table" and rawState.inventoryPolicy or {}
    local legacyMode = rawPolicy.mode == "decompose" and "decompose" or (rawPolicy.mode == "sell" and "sell" or nil)
    local legacyRarities = type(rawPolicy.rarities) == "table" and rawPolicy.rarities or {}
    state.inventoryPolicy.pauseOnFull = rawPolicy.pauseOnFull ~= false and legacyMode == nil
    state.inventoryPolicy.autoDecompose = rawPolicy.autoDecompose == true or legacyMode == "decompose"
    state.inventoryPolicy.autoSell = (rawPolicy.autoSell == true or legacyMode == "sell")
        and not state.inventoryPolicy.autoDecompose
    local rawDecompose = type(rawPolicy.decomposeRarities) == "table" and rawPolicy.decomposeRarities or (legacyMode == "decompose" and legacyRarities or {})
    local rawSell = type(rawPolicy.sellRarities) == "table" and rawPolicy.sellRarities or (legacyMode == "sell" and legacyRarities or {})
    for _, rarityId in ipairs(Catalog.RARITY_ORDER) do
        state.inventoryPolicy.decomposeRarities[rarityId] = rarityId ~= "myth" and rawDecompose[rarityId] == true
        state.inventoryPolicy.sellRarities[rarityId] = rarityId ~= "myth" and rawSell[rarityId] == true
    end

    local rawMonster = type(rawState.currentMonster) == "table" and rawState.currentMonster or nil
    if rawMonster then
        local eventType = rawMonster.eventType
        local maxHp = clampInteger(rawMonster.maxHp, 1, 1000000000, 1)
        local phase = rawMonster.phase == "recovery" and "recovery" or "windup"
        local sequenceIndex = clampInteger(rawMonster.sequenceIndex, 1, CombatSequence.Count(), 1)
        local sequence = CombatSequence.Get(sequenceIndex)
        local hitFrame = clampInteger(rawMonster.hitFrame, 1, sequence.frameCount, sequence.hitFrames[1])
        local endFrame = clampInteger(rawMonster.endFrame, hitFrame, sequence.frameCount, sequence.endFrame)
        if eventType == "monster" or eventType == "elite" or eventType == "boss" then
            state.currentMonster = {
                id = type(rawMonster.id) == "string" and rawMonster.id or string.format("floor:%d:position:%d", state.floor, state.position),
                eventType = eventType,
                name = type(rawMonster.name) == "string" and rawMonster.name or "回廊怪物",
                hp = clampInteger(rawMonster.hp, 0, maxHp, maxHp),
                maxHp = maxHp,
                atk = clampInteger(rawMonster.atk, 0, 1000000000, 0),
                def = clampInteger(rawMonster.def, 0, 1000000000, 0),
                phase = phase,
                phaseRemaining = clampNumber(rawMonster.phaseRemaining, 0, 60, 0),
                attackSerial = clampInteger(rawMonster.attackSerial, 1, 1000000000, 1),
                sequenceIndex = sequenceIndex,
                sequenceId = sequence.id,
                fps = sequence.fps,
                hitFrame = hitFrame,
                endFrame = endFrame,
                recoverySeconds = clampNumber(rawMonster.recoverySeconds, 0, 60, CombatSequence.MIN_PHASE_SECONDS),
                lastSequenceIndex = clampInteger(rawMonster.lastSequenceIndex, 0, CombatSequence.Count(), sequenceIndex),
            }
        end
    end

    while state.exp >= Catalog.NextExp(state.level) do
        state.exp = state.exp - Catalog.NextExp(state.level)
        state.level = state.level + 1
    end
    state.nextExp = Catalog.NextExp(state.level)
    state.maxFloor = math.max(state.maxFloor, state.floor)

    local rawConsumables = type(rawState.consumables) == "table" and rawState.consumables or {}
    state.consumables.healthPotion = math.max(0, TableUtils.ToInteger(rawConsumables.healthPotion, 0))

    local usedIds = {}
    local legacyIdMap = {}
    local legacyObjectMap = {}
    local materialFallback = { fragments = 0, mythShards = 0 }
    local overflowCount = 0

    for _, rawItem in ipairs(type(rawState.inventory) == "table" and rawState.inventory or {}) do
        if type(rawItem) == "table" and (rawItem.equipmentId or Catalog.SLOT_BY_ID[rawItem.slot]) then
            local itemId
            itemId, state.nextItemId = normalizeItemId(rawItem.id, usedIds, state.nextItemId)
            local item = sanitizeEquipment(rawItem, itemId)
            if item then
                if #state.inventory < Catalog.INVENTORY_CAP then
                    state.inventory[#state.inventory + 1] = item
                    usedIds[itemId] = true
                    legacyObjectMap[rawItem] = itemId
                    if rawItem.id ~= nil then
                        legacyIdMap[tostring(rawItem.id)] = itemId
                    end
                else
                    overflowCount = overflowCount + 1
                end
            end
        elseif type(rawItem) == "table" and rawItem.category == "consumable" then
            state.consumables.healthPotion = state.consumables.healthPotion
                + math.max(0, TableUtils.ToInteger(rawItem.quantity, 0))
        elseif type(rawItem) == "table" and rawItem.category == "material" then
            local kind = materialKind(rawItem)
            if kind then
                materialFallback[kind] = materialFallback[kind]
                    + math.max(0, TableUtils.ToInteger(rawItem.quantity, 0))
            end
        end
    end

    if rawState.fragments == nil then
        state.fragments = LargeNumber.FromNumber(materialFallback.fragments)
    end
    if rawState.mythShards == nil then
        state.mythShards = LargeNumber.FromNumber(materialFallback.mythShards)
    end

    local byId = {}
    for _, item in ipairs(state.inventory) do
        byId[item.id] = item
    end
    local rawEquipped = type(rawState.equipped) == "table" and rawState.equipped
        or (type(rawState.equipment) == "table" and rawState.equipment or {})
    local equippedIds = {}
    for _, slot in ipairs(Catalog.SLOTS) do
        local rawValue = rawEquipped[slot.id]
        local itemId = nil
        local cameFromLegacyObject = type(rawValue) == "table"
        if cameFromLegacyObject then
            itemId = legacyObjectMap[rawValue]
                or (rawValue.id ~= nil and legacyIdMap[tostring(rawValue.id)] or nil)
        elseif rawValue ~= nil then
            itemId = byId[rawValue] and rawValue or legacyIdMap[tostring(rawValue)]
        end

        local item = itemId and byId[itemId] or nil
        if item and item.slot == slot.id and not equippedIds[item.id] then
            state.equipped[slot.id] = item.id
            equippedIds[item.id] = true
        end
    end

    local autoPolicyEnabled = (state.inventoryPolicy.autoDecompose or state.inventoryPolicy.autoSell)
        and (state.inventoryPolicy.decomposeRarities.common
            or state.inventoryPolicy.decomposeRarities.blue
            or state.inventoryPolicy.decomposeRarities.purple
            or state.inventoryPolicy.decomposeRarities.epic
            or state.inventoryPolicy.sellRarities.common
            or state.inventoryPolicy.sellRarities.blue
            or state.inventoryPolicy.sellRarities.purple
            or state.inventoryPolicy.sellRarities.epic)
    if overflowCount > 0 or (#state.inventory >= Catalog.INVENTORY_CAP and state.inventoryPolicy.pauseOnFull and not autoPolicyEnabled) then
        state.autoRun = false
        state.pauseReason = "inventory_full"
    elseif state.pauseReason == "inventory_full" and state.autoRun then
        state.pauseReason = nil
    end
    for _, item in ipairs(state.inventory) do
        item.power = Catalog.GetItemPower(item)
    end
    state.stats = Catalog.CalculateStats(state)
    local rawHp = TableUtils.ToInteger(rawState.hp, state.stats.hp)
    if rawHp <= 0 then
        rawHp = state.stats.hp
    end
    state.hp = Catalog.Clamp(rawHp, 1, state.stats.hp)
    state.currentEvent = state.currentMonster
        and state.currentMonster.eventType
        or Catalog.GetCellType(math.max(1, state.position), state.floor)
    return state
end

function StateNormalizer.ToPersisted(state)
    local normalized = StateNormalizer.Normalize(state, state.updatedAt)
    local persistedInventory = {}
    for _, item in ipairs(normalized.inventory) do
        persistedInventory[#persistedInventory + 1] = {
            id = item.id,
            equipmentId = item.equipmentId,
            level = item.level,
            enhance = item.enhance,
            star = item.star,
            locked = item.locked,
            acquiredAt = item.acquiredAt,
            source = item.source,
            investedGold = item.investedGold,
            investedFragments = item.investedFragments,
        }
    end
    local persisted = {
        schemaVersion = normalized.schemaVersion,
        revision = normalized.revision,
        updatedAt = normalized.updatedAt,
        lastActiveAt = normalized.lastActiveAt,
        pendingOfflineSeconds = normalized.pendingOfflineSeconds,
        level = normalized.level,
        exp = normalized.exp,
        floor = normalized.floor,
        maxFloor = normalized.maxFloor,
        position = normalized.position,
        gold = normalized.gold,
        fragments = normalized.fragments,
        mythShards = normalized.mythShards,
        autoRun = normalized.autoRun,
        pauseReason = normalized.pauseReason,
        hp = normalized.hp,
        floorKillBonus = normalized.floorKillBonus,
        permanentBonus = normalized.permanentBonus,
        inventoryPolicy = TableUtils.DeepCopy(normalized.inventoryPolicy),
        currentMonster = TableUtils.DeepCopy(normalized.currentMonster),
        nextItemId = normalized.nextItemId,
        inventory = persistedInventory,
        equipped = TableUtils.DeepCopy(normalized.equipped),
        consumables = TableUtils.DeepCopy(normalized.consumables),
        appliedGmCommandIds = TableUtils.DeepCopy(normalized.appliedGmCommandIds),
    }
    for _, item in ipairs(persisted.inventory) do
        item.power = nil
    end
    return persisted
end

return StateNormalizer
