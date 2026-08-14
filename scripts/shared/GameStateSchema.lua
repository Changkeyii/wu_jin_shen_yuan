local Contracts = require("shared.GameStateContracts")
local Policy = require("shared.GameStatePolicy")
local Boundary = require("shared.GameStateBoundarySchemas")
local Persistence = require("shared.GameStatePersistence")
local Validation = require("shared.GameStateValidation")
local Wire = require("shared.GameStateWire")
local Progression = require("shared.GameProgression")
local TableUtils = require("shared.TableUtils")

local GameStateSchema = {
    VERSION = Contracts.VERSION,
    INVENTORY_CAP = Policy.INVENTORY_CAP,
    INVENTORY_HARD_CAP = Policy.INVENTORY_HARD_CAP or (Policy.INVENTORY_CAP + (Policy.INVENTORY_EXPAND_MAX_BONUS or 0)),
    TEMPORARY_LOOT_CAP = Policy.TEMPORARY_LOOT_CAP,
    LOOT_STASH_CAP = Policy.LOOT_STASH_CAP,
    OFFLINE_MAX_SECONDS = Policy.OFFLINE_MAX_SECONDS,
    MAX_LOGS = Policy.MAX_LOGS,
    MAX_APPLIED_GM_COMMANDS = Policy.MAX_APPLIED_GM_COMMANDS,
    MAX_GM_COMMAND_ID_LENGTH = Policy.MAX_GM_COMMAND_ID_LENGTH,
    SLOTS = Contracts.SLOTS,
    RARITIES = Contracts.RARITIES,
    SET_IDS = Contracts.SET_IDS,
    EVENT_TYPES = Contracts.EVENT_TYPES,
    PERSISTED_SCHEMA = Boundary.PERSISTED_SCHEMA,
    NewInitialState = Persistence.NewInitialState,
    ToPersistedState = Persistence.ToPersistedState,
    NormalizeState = Persistence.NormalizeState,
    NormalizeMarketListings = Persistence.NormalizeMarketListings,
    NormalizeAppliedGmCommandIds = Persistence.NormalizeAppliedGmCommandIds,
    ValidateState = Validation.ValidateState,
    ValidateStats = Validation.ValidateStats,
    BuildSnapshot = Wire.BuildSnapshot,
    BuildSnapshotEvents = Wire.BuildSnapshotEvents,
    BuildDelta = Wire.BuildDelta,
    ValidateSnapshot = Wire.ValidateSnapshot,
    ValidateDelta = Wire.ValidateDelta,
    DeepCopy = TableUtils.DeepCopy,
    NextExp = Progression.NextExp,
}

return GameStateSchema
