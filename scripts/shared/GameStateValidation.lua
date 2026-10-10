local ErrorCodes = require("shared.ErrorCodes")
local NetworkProtocol = require("shared.NetworkProtocol")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local Contracts = require("shared.GameStateContracts")
local Policy = require("shared.GameStatePolicy")
local Definitions = require("shared.GameStateDefinitions")
local Boundary = require("shared.GameStateBoundarySchemas")
local Persistence = require("shared.GameStatePersistence")
local Progression = require("shared.GameProgression")

local GameStateSchema = {
    ToPersistedState = Persistence.ToPersistedState,
    PERSISTED_SCHEMA = Boundary.PERSISTED_SCHEMA,
    MAX_LOGS = Policy.MAX_LOGS,
    EVENT_TYPES = Contracts.EVENT_TYPES,
}
local STATS_SCHEMA = Definitions.STATS_SCHEMA
local nextExp = Progression.NextExp
local function stateError(reason, path)
    return ErrorCodes.Make(ErrorCodes.INVALID_STATE, reason, path and { path = path } or nil)
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
    if (persisted.level < Progression.MAX_LEVEL and persisted.exp >= nextExp(persisted.level))
        or (persisted.level >= Progression.MAX_LEVEL and persisted.exp ~= 0) then
        return false, stateError("Experience must be normalized for the current level", "$state.exp")
    end

    ---@type table<string, table>
    local inventoryById = {}
    local allItemIds = {}
    for index, item in ipairs(persisted.inventory) do
        local idKey = tostring(item.id)
        if inventoryById[idKey] ~= nil then
            return false, stateError("Equipment ids must be unique", "$state.inventory[" .. index .. "].id")
        end
        local definition = EquipmentCatalog.Get(item.equipmentId)
        if not definition then
            return false, stateError("Unknown equipment definition", "$state.inventory[" .. index .. "].equipmentId")
        end
        if definition.id ~= item.equipmentId then
            return false, stateError("Equipment definition id mismatch", "$state.inventory[" .. index .. "].equipmentId")
        end
        inventoryById[idKey] = item
        allItemIds[idKey] = true
    end
    for index, item in ipairs(persisted.overflowLoot or {}) do
        local idKey = tostring(item.id)
        if allItemIds[idKey] then
            return false, stateError("Equipment ids must be unique across inventory and temporary loot", "$state.overflowLoot[" .. index .. "].id")
        end
        local definition = EquipmentCatalog.Get(item.equipmentId)
        if not definition then
            return false, stateError("Unknown equipment definition", "$state.overflowLoot[" .. index .. "].equipmentId")
        end
        allItemIds[idKey] = true
    end

    for index, itemId in ipairs(persisted.lootStash or {}) do
        if not inventoryById[tostring(itemId)] then
            return false, stateError("Loot stash item is missing from inventory", "$state.lootStash[" .. index .. "]")
        end
    end

    local equippedIds = {}
    for slot, itemId in pairs(persisted.equipped) do
        local idKey = tostring(itemId)
        local item = inventoryById[idKey]
        if item == nil then
            return false, stateError("Equipped item is missing from inventory", "$state.equipped." .. slot)
        end
        local definition = EquipmentCatalog.Get(item.equipmentId)
        if not definition or definition.slot ~= slot then
            return false, stateError("Equipped item does not match its slot", "$state.equipped." .. slot)
        end
        if not Progression.CanEquip(persisted, item) then
            return false, stateError("Character level is below equipment requirement", "$state.equipped." .. slot)
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

---@param stats table
---@param path string|nil
---@return boolean
---@return table|nil
function GameStateSchema.ValidateStats(stats, path)
    path = path or "$stats"
    local ok, validationError = NetworkProtocol.ValidateValue(stats, STATS_SCHEMA, path)
    if ok then return true, nil end
    return false, stateError(
        validationError and validationError.reason or "Stats validation failed",
        validationError and validationError.details and validationError.details.path or path)
end


local Validation = {
    ValidateState = GameStateSchema.ValidateState,
    ValidateStats = GameStateSchema.ValidateStats,
}

return Validation
