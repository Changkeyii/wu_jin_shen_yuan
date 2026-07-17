local ErrorCodes = require("shared.ErrorCodes")
local NetworkProtocol = require("shared.NetworkProtocol")

local GameStateSchema = {}

GameStateSchema.VERSION = 1
GameStateSchema.INVENTORY_CAP = 300
GameStateSchema.OFFLINE_MAX_SECONDS = 12 * 60 * 60
GameStateSchema.MAX_LOGS = 40
GameStateSchema.MAX_APPLIED_GM_COMMANDS = 64
GameStateSchema.MAX_GM_COMMAND_ID_LENGTH = 96

GameStateSchema.SLOTS = {
    "weapon",
    "shoulder",
    "coat",
    "pants",
    "belt",
    "shoes",
    "bracelet",
    "necklace",
    "ring",
    "support",
    "magicstone",
    "earring",
}

GameStateSchema.RARITIES = { "common", "blue", "purple", "epic", "myth" }
GameStateSchema.SET_IDS = { "nightmare", "lucky", "voyage", "abyss", "prophecy" }
GameStateSchema.EVENT_TYPES = { "monster", "elite", "chest", "merchant", "random", "boss" }

local SLOT_SET = {}
for _, slot in ipairs(GameStateSchema.SLOTS) do
    SLOT_SET[slot] = true
end

local PERSISTED_FIELDS = {
    "schemaVersion",
    "revision",
    "updatedAt",
    "lastActiveAt",
    "pendingOfflineSeconds",
    "level",
    "exp",
    "floor",
    "maxFloor",
    "position",
    "gold",
    "fragments",
    "mythShards",
    "autoRun",
    "pauseReason",
    "nextItemId",
    "inventory",
    "equipped",
    "consumables",
    "hp",
    "floorKillBonus",
    "permanentBonus",
    "appliedGmCommandIds",
}

local SNAPSHOT_FIELDS = {
    "level",
    "exp",
    "floor",
    "maxFloor",
    "position",
    "gold",
    "fragments",
    "mythShards",
    "autoRun",
    "pauseReason",
    "pendingOfflineSeconds",
    "inventory",
    "equipped",
    "consumables",
    "hp",
    "floorKillBonus",
    "permanentBonus",
    "logs",
    "currentEvent",
    "recentDamage",
    "stats",
    "nextExp",
}

local DELTA_FIELD_SET = {}
for _, fieldName in ipairs(SNAPSHOT_FIELDS) do
    DELTA_FIELD_SET[fieldName] = true
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[deepCopy(key, seen)] = deepCopy(item, seen)
    end
    return copy
end

local function currentTime(now)
    if type(now) == "number" then
        return math.max(0, math.floor(now))
    end
    if type(os.time) == "function" then
        return math.max(0, math.floor(os.time()))
    end
    return 0
end

local function nextExp(level)
    return math.floor(100 * (1.15 ^ (math.max(1, level) - 1)))
end

local function stateError(reason, path)
    return ErrorCodes.Make(ErrorCodes.INVALID_STATE, reason, path and { path = path } or nil)
end

local function validateId(value)
    local valueType = type(value)
    if valueType == "string" then
        if #value < 1 or #value > 64 then
            return false, "Equipment id length is invalid"
        end
        return true
    end
    if valueType == "number" and value == math.floor(value) and value > 0 then
        return true
    end
    return false, "Equipment id must be a non-empty string or positive integer"
end

local ITEM_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "id", "name", "slot", "category", "rarity", "level" },
    fields = {
        id = { type = "any", validate = validateId },
        name = { type = "string", minLength = 1, maxLength = 96 },
        slot = { type = "string", enum = GameStateSchema.SLOTS },
        category = { type = "string", enum = { "weapon", "armor", "jewelry", "special" } },
        rarity = { type = "string", enum = GameStateSchema.RARITIES },
        setId = { type = "string", enum = GameStateSchema.SET_IDS },
        level = { type = "integer", min = 1, max = 1000000 },
        atk = { type = "integer", min = 0, max = 1000000000 },
        def = { type = "integer", min = 0, max = 1000000000 },
        hp = { type = "integer", min = 0, max = 1000000000 },
        crit = { type = "number", min = 0, max = 10 },
        critDmg = { type = "number", min = 0, max = 100 },
        atkSpeed = { type = "number", min = 0, max = 100 },
        enhance = { type = "integer", min = 0, max = 1000000 },
        star = { type = "integer", min = 0, max = 1000 },
    },
}

local function validateEquipped(value)
    for slot, itemId in pairs(value) do
        if not SLOT_SET[slot] then
            return false, "Unknown equipment slot: " .. tostring(slot)
        end
        local ok = validateId(itemId)
        if not ok then
            return false, "Invalid equipment id for slot: " .. slot
        end
    end
    return true
end

local function validateConsumables(value)
    for itemId, quantity in pairs(value) do
        if type(itemId) ~= "string" or #itemId < 1 or #itemId > 64 then
            return false, "Consumable keys must be non-empty strings"
        end
        if type(quantity) ~= "number" or quantity ~= math.floor(quantity) or quantity < 0 then
            return false, "Consumable quantities must be non-negative integers"
        end
    end
    return true
end

local function normalizeAppliedGmCommandIds(value)
    local reversed = {}
    local seen = {}
    if type(value) == "table" then
        for index = #value, 1, -1 do
            local commandId = value[index]
            if type(commandId) == "string"
                and #commandId >= 1
                and #commandId <= GameStateSchema.MAX_GM_COMMAND_ID_LENGTH
                and string.match(commandId, "^[%w%._:%-]+$") ~= nil
                and not seen[commandId]
            then
                seen[commandId] = true
                reversed[#reversed + 1] = commandId
                if #reversed >= GameStateSchema.MAX_APPLIED_GM_COMMANDS then break end
            end
        end
    end
    local normalized = {}
    for index = #reversed, 1, -1 do
        normalized[#normalized + 1] = reversed[index]
    end
    return normalized
end

local function validateAppliedGmCommandIds(value)
    local seen = {}
    for _, commandId in ipairs(value) do
        if seen[commandId] then return false, "Applied GM command ids must be unique" end
        seen[commandId] = true
    end
    return true
end

GameStateSchema.PERSISTED_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = {
        "schemaVersion",
        "revision",
        "updatedAt",
        "lastActiveAt",
        "pendingOfflineSeconds",
        "level",
        "exp",
        "floor",
        "maxFloor",
        "position",
        "gold",
        "fragments",
        "mythShards",
        "autoRun",
        "nextItemId",
        "inventory",
        "equipped",
        "consumables",
        "hp",
        "floorKillBonus",
        "permanentBonus",
        "appliedGmCommandIds",
    },
    fields = {
        schemaVersion = { type = "integer", enum = { GameStateSchema.VERSION } },
        revision = { type = "integer", min = 0 },
        updatedAt = { type = "integer", min = 0 },
        lastActiveAt = { type = "integer", min = 0 },
        pendingOfflineSeconds = { type = "integer", min = 0, max = GameStateSchema.OFFLINE_MAX_SECONDS },
        level = { type = "integer", min = 1, max = 1000000 },
        exp = { type = "integer", min = 0, max = 1000000000 },
        floor = { type = "integer", min = 1, max = 1000000000 },
        maxFloor = { type = "integer", min = 1, max = 1000000000 },
        position = { type = "integer", min = 0, max = 100 },
        gold = { type = "integer", min = 0, max = 9007199254740991 },
        fragments = { type = "integer", min = 0, max = 9007199254740991 },
        mythShards = { type = "integer", min = 0, max = 9007199254740991 },
        autoRun = { type = "boolean" },
        pauseReason = { type = "string", maxLength = 64 },
        nextItemId = { type = "integer", min = 1, max = 9007199254740991 },
        inventory = {
            type = "array",
            maxLength = GameStateSchema.INVENTORY_CAP,
            items = ITEM_SCHEMA,
        },
        equipped = { type = "object", validate = validateEquipped },
        consumables = { type = "object", validate = validateConsumables },
        hp = { type = "integer", min = 0, max = 1000000000 },
        floorKillBonus = { type = "number", min = 0, max = 1 },
        permanentBonus = { type = "number", min = 0, max = 1000 },
        appliedGmCommandIds = {
            type = "array",
            maxLength = GameStateSchema.MAX_APPLIED_GM_COMMANDS,
            items = {
                type = "string",
                minLength = 1,
                maxLength = GameStateSchema.MAX_GM_COMMAND_ID_LENGTH,
                pattern = "^[%w%._:%-]+$",
            },
            validate = validateAppliedGmCommandIds,
        },
    },
}

---@param now number|nil
---@return table
function GameStateSchema.NewInitialState(now)
    now = currentTime(now)
    return {
        schemaVersion = GameStateSchema.VERSION,
        revision = 0,
        updatedAt = now,
        lastActiveAt = now,
        pendingOfflineSeconds = 4 * 60 * 60 + 18 * 60,
        level = 21,
        exp = 464,
        floor = 1,
        maxFloor = 1,
        position = 87,
        gold = 38600,
        fragments = 520,
        mythShards = 12,
        autoRun = true,
        nextItemId = 1,
        inventory = {},
        equipped = {},
        consumables = { healthPotion = 12 },
        hp = 1,
        floorKillBonus = 0.08,
        permanentBonus = 0.035,
        appliedGmCommandIds = {},
        logs = {},
        currentEvent = "monster",
        recentDamage = "",
    }
end

---@param state table
---@return table
function GameStateSchema.ToPersistedState(state)
    local persisted = {}
    for _, fieldName in ipairs(PERSISTED_FIELDS) do
        local value = state[fieldName]
        if value ~= nil then
            persisted[fieldName] = deepCopy(value)
        end
    end
    if persisted.nextItemId == nil and state.itemSequence ~= nil then
        local legacySequence = tonumber(state.itemSequence)
        if legacySequence ~= nil then
            persisted.nextItemId = math.max(1, math.floor(legacySequence) + 1)
        end
    end
    for _, item in ipairs(persisted.inventory or {}) do
        item.power = nil
    end
    return persisted
end

---@param rawState table|nil
---@param now number|nil
---@return table
function GameStateSchema.NormalizeState(rawState, now)
    local normalized = GameStateSchema.NewInitialState(now)
    if type(rawState) ~= "table" then
        return normalized
    end

    for _, fieldName in ipairs(PERSISTED_FIELDS) do
        if rawState[fieldName] ~= nil then
            normalized[fieldName] = deepCopy(rawState[fieldName])
        end
    end
    normalized.appliedGmCommandIds = normalizeAppliedGmCommandIds(normalized.appliedGmCommandIds)
    if rawState.nextItemId == nil and rawState.itemSequence ~= nil then
        local legacySequence = tonumber(rawState.itemSequence)
        if legacySequence ~= nil then
            normalized.nextItemId = math.max(1, math.floor(legacySequence) + 1)
        end
    end
    normalized.logs = deepCopy(type(rawState.logs) == "table" and rawState.logs or {})
    normalized.currentEvent = rawState.currentEvent or normalized.currentEvent
    normalized.recentDamage = rawState.recentDamage or normalized.recentDamage
    normalized.stats = deepCopy(rawState.stats)
    normalized.nextExp = rawState.nextExp
    while #normalized.logs > GameStateSchema.MAX_LOGS do
        table.remove(normalized.logs)
    end
    return normalized
end

---@param state table
---@return boolean
---@return table|nil
function GameStateSchema.ValidateState(state)
    if type(state) ~= "table" then
        return false, stateError("State must be a table", "$state")
    end

    local persisted = GameStateSchema.ToPersistedState(state)
    local ok, validationError = NetworkProtocol.ValidateValue(
        persisted,
        GameStateSchema.PERSISTED_SCHEMA,
        "$state"
    )
    if not ok then
        local path = validationError and validationError.details and validationError.details.path or "$state"
        return false, stateError(validationError and validationError.reason or "State validation failed", path)
    end

    if persisted.maxFloor < persisted.floor then
        return false, stateError("maxFloor cannot be lower than floor", "$state.maxFloor")
    end
    if persisted.exp >= nextExp(persisted.level) then
        return false, stateError("Experience must be normalized for the current level", "$state.exp")
    end

    local inventoryById = {}
    for index, item in ipairs(persisted.inventory) do
        local idKey = tostring(item.id)
        if inventoryById[idKey] ~= nil then
            return false, stateError("Equipment ids must be unique", "$state.inventory[" .. index .. "].id")
        end
        inventoryById[idKey] = item
    end

    local equippedIds = {}
    for slot, itemId in pairs(persisted.equipped) do
        local idKey = tostring(itemId)
        local item = inventoryById[idKey]
        if item == nil then
            return false, stateError("Equipped item is missing from inventory", "$state.equipped." .. slot)
        end
        if item.slot ~= slot then
            return false, stateError("Equipped item does not match its slot", "$state.equipped." .. slot)
        end
        if equippedIds[idKey] then
            return false, stateError("One item cannot occupy multiple slots", "$state.equipped." .. slot)
        end
        equippedIds[idKey] = true
    end

    if state.logs ~= nil then
        local logsOk, logsError = NetworkProtocol.ValidateValue(state.logs, {
            type = "array",
            maxLength = GameStateSchema.MAX_LOGS,
            items = { type = "string", maxLength = 256 },
        }, "$state.logs")
        if not logsOk then
            return false, stateError(logsError.reason, logsError.details and logsError.details.path)
        end
    end
    if state.currentEvent ~= nil then
        local eventOk = NetworkProtocol.ValidateValue(state.currentEvent, {
            type = "string",
            enum = GameStateSchema.EVENT_TYPES,
        }, "$state.currentEvent")
        if not eventOk then
            return false, stateError("Unknown current event", "$state.currentEvent")
        end
    end
    if state.recentDamage ~= nil and (type(state.recentDamage) ~= "string" or #state.recentDamage > 256) then
        return false, stateError("recentDamage must be a short string", "$state.recentDamage")
    end

    return true, nil
end

---@param state table
---@param options table|nil
---@return table
function GameStateSchema.BuildSnapshot(state, options)
    options = options or {}
    local snapshot = {
        kind = "GameSnapshot",
        schemaVersion = state.schemaVersion or GameStateSchema.VERSION,
        revision = state.revision or 0,
        updatedAt = state.updatedAt or 0,
        serverTime = currentTime(options.serverTime),
        status = options.status or "ready",
        isAdmin = options.isAdmin == true,
    }
    for _, fieldName in ipairs(SNAPSHOT_FIELDS) do
        if state[fieldName] ~= nil then
            snapshot[fieldName] = deepCopy(state[fieldName])
        end
    end

    snapshot.nextExp = options.nextExp or snapshot.nextExp or nextExp(snapshot.level or 1)
    if options.stats ~= nil then
        snapshot.stats = deepCopy(options.stats)
    end
    if options.itemPower ~= nil then
        for _, item in ipairs(snapshot.inventory or {}) do
            item.power = options.itemPower(item)
        end
    end
    return snapshot
end

---@param revision number
---@param changes table|nil
---@param options table|nil
---@return table
function GameStateSchema.BuildDelta(revision, changes, options)
    changes = changes or {}
    options = options or {}
    local deltaChanges = {}
    for fieldName, value in pairs(changes) do
        if DELTA_FIELD_SET[fieldName] then
            deltaChanges[fieldName] = deepCopy(value)
        end
    end

    local inventoryChanged = options.inventoryChanged == true
        or changes.inventory ~= nil
        or changes.equipped ~= nil
        or changes.consumables ~= nil
    if inventoryChanged and options.state ~= nil then
        deltaChanges.inventory = deepCopy(options.state.inventory or {})
        deltaChanges.equipped = deepCopy(options.state.equipped or {})
        deltaChanges.consumables = deepCopy(options.state.consumables or {})
    end

    return {
        kind = "GameDelta",
        schemaVersion = GameStateSchema.VERSION,
        revision = revision,
        serverTime = currentTime(options.serverTime),
        inventoryChanged = inventoryChanged,
        changes = deltaChanges,
    }
end

---@param snapshot table
---@return boolean
---@return table|nil
function GameStateSchema.ValidateSnapshot(snapshot)
    if type(snapshot) ~= "table" or snapshot.kind ~= "GameSnapshot" then
        return false, stateError("Invalid snapshot envelope", "$snapshot")
    end
    if type(snapshot.revision) ~= "number" or snapshot.revision < 0 or snapshot.revision ~= math.floor(snapshot.revision) then
        return false, stateError("Invalid snapshot revision", "$snapshot.revision")
    end
    if type(snapshot.inventory) ~= "table" or #snapshot.inventory > GameStateSchema.INVENTORY_CAP then
        return false, stateError("Invalid snapshot inventory", "$snapshot.inventory")
    end
    return true, nil
end

---@param delta table
---@return boolean
---@return table|nil
function GameStateSchema.ValidateDelta(delta)
    if type(delta) ~= "table" or delta.kind ~= "GameDelta" then
        return false, stateError("Invalid delta envelope", "$delta")
    end
    if type(delta.revision) ~= "number" or delta.revision < 0 or delta.revision ~= math.floor(delta.revision) then
        return false, stateError("Invalid delta revision", "$delta.revision")
    end
    if type(delta.changes) ~= "table" then
        return false, stateError("Delta changes must be a table", "$delta.changes")
    end
    for fieldName in pairs(delta.changes) do
        if not DELTA_FIELD_SET[fieldName] then
            return false, stateError("Delta contains an unknown field", "$delta.changes." .. tostring(fieldName))
        end
    end
    if delta.inventoryChanged then
        if type(delta.changes.inventory) ~= "table"
            or type(delta.changes.equipped) ~= "table"
            or type(delta.changes.consumables) ~= "table"
        then
            return false, stateError(
                "Inventory deltas must include full inventory, equipment, and consumables",
                "$delta.changes"
            )
        end
    end
    return true, nil
end

GameStateSchema.DeepCopy = deepCopy
GameStateSchema.NextExp = nextExp
GameStateSchema.NormalizeAppliedGmCommandIds = normalizeAppliedGmCommandIds

return GameStateSchema
