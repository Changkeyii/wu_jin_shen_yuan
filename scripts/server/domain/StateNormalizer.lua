local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local GameStateSchema = require("shared.GameStateSchema")

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

local function nextEquipmentId(usedIds, nextId)
    nextId = math.max(1, nextId)
    while usedIds[string.format("eq-%06d", nextId)] do
        nextId = nextId + 1
    end
    local itemId = string.format("eq-%06d", nextId)
    return itemId, nextId + 1
end

local function normalizeItemId(rawId, usedIds, nextId)
    local candidate = nil
    if type(rawId) == "string" and rawId ~= "" then
        candidate = rawId
    elseif type(rawId) == "number" and rawId > 0 then
        candidate = string.format("eq-%06d", math.floor(rawId))
    end

    if not candidate or usedIds[candidate] then
        return nextEquipmentId(usedIds, nextId)
    end

    local suffix = candidate:match("^eq%-(%d+)$")
    if suffix then
        nextId = math.max(nextId, (tonumber(suffix) or 0) + 1)
    end
    return candidate, nextId
end

local function sanitizeEquipment(rawItem, itemId)
    local slot = Catalog.SLOT_BY_ID[rawItem.slot]
    if not slot then
        return nil
    end
    local rarity = Catalog.RARITIES[rawItem.rarity] and rawItem.rarity or "common"
    local setId = Catalog.SETS[rawItem.setId] and rawItem.setId or nil
    return {
        id = itemId,
        name = type(rawItem.name) == "string" and rawItem.name:sub(1, 96)
            or (Catalog.RARITIES[rarity].name .. "·" .. slot.name),
        slot = slot.id,
        category = slot.category,
        rarity = rarity,
        setId = setId,
        level = clampInteger(rawItem.level, 1, 1000000, 1),
        atk = clampInteger(rawItem.atk, 0, 1000000000, 0),
        def = clampInteger(rawItem.def, 0, 1000000000, 0),
        hp = clampInteger(rawItem.hp, 0, 1000000000, 0),
        crit = clampNumber(rawItem.crit, 0, 10, 0),
        critDmg = clampNumber(rawItem.critDmg, 0, 100, 0),
        atkSpeed = clampNumber(rawItem.atkSpeed, 0, 100, 0),
        enhance = clampInteger(rawItem.enhance, 0, 1000000, 0),
        star = clampInteger(rawItem.star, 0, 5, 0),
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
        gold = math.max(0, TableUtils.ToInteger(rawState.gold, 0)),
        fragments = math.max(0, TableUtils.ToInteger(rawState.fragments, 0)),
        mythShards = math.max(0, TableUtils.ToInteger(rawState.mythShards, 0)),
        autoRun = rawState.autoRun == true,
        pauseReason = type(rawState.pauseReason) == "string" and rawState.pauseReason or nil,
        floorKillBonus = clampNumber(rawState.floorKillBonus, 0, 0.50, 0),
        permanentBonus = clampNumber(rawState.permanentBonus, 0, 1000, 0),
        nextItemId = math.max(1, TableUtils.ToInteger(rawState.nextItemId or rawState.itemSequence, 1)),
        inventory = {},
        equipped = {},
        consumables = {},
        appliedGmCommandIds = GameStateSchema.NormalizeAppliedGmCommandIds(rawState.appliedGmCommandIds),
    }

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
        if type(rawItem) == "table" and Catalog.SLOT_BY_ID[rawItem.slot] then
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
        state.fragments = materialFallback.fragments
    end
    if rawState.mythShards == nil then
        state.mythShards = materialFallback.mythShards
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
        if item and cameFromLegacyObject and item.slot ~= slot.id then
            item.slot = slot.id
            item.category = slot.category
        end
        if item and item.slot == slot.id and not equippedIds[item.id] then
            state.equipped[slot.id] = item.id
            equippedIds[item.id] = true
        end
    end

    if overflowCount > 0 or #state.inventory >= Catalog.INVENTORY_CAP then
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
    state.currentEvent = Catalog.GetCellType(math.max(1, state.position), state.floor)
    return state
end

function StateNormalizer.ToPersisted(state)
    local normalized = StateNormalizer.Normalize(state, state.updatedAt)
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
        nextItemId = normalized.nextItemId,
        inventory = TableUtils.DeepCopy(normalized.inventory),
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
