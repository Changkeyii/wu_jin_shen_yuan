local GameEventSchema = require("shared.GameEventSchema")
local LargeNumber = require("shared.LargeNumber")
local Contracts = require("shared.GameStateContracts")
local Policy = require("shared.GameStatePolicy")
local Definitions = require("shared.GameStateDefinitions")

local GameStateSchema = {
    VERSION = Contracts.VERSION,
    INVENTORY_CAP = Policy.INVENTORY_CAP,
    TEMPORARY_LOOT_CAP = Policy.TEMPORARY_LOOT_CAP,
    LOOT_STASH_CAP = Policy.LOOT_STASH_CAP,
    OFFLINE_MAX_SECONDS = Policy.OFFLINE_MAX_SECONDS,
    MAX_LOGS = Policy.MAX_LOGS,
    MAX_APPLIED_GM_COMMANDS = Policy.MAX_APPLIED_GM_COMMANDS,
    MAX_GM_COMMAND_ID_LENGTH = Policy.MAX_GM_COMMAND_ID_LENGTH,
    EVENT_TYPES = Contracts.EVENT_TYPES,
}
local PERSISTED_SCHEMA = nil
local CURRENCY_SCHEMA = Definitions.CURRENCY_SCHEMA
local BIG_NUMBER_SCHEMA = Definitions.BIG_NUMBER_SCHEMA
local FINITE_NUMBER_SCHEMA = Definitions.FINITE_NUMBER_SCHEMA
local NONNEGATIVE_NUMBER_SCHEMA = Definitions.NONNEGATIVE_NUMBER_SCHEMA
local MAGNITUDE_SCHEMA = Definitions.MAGNITUDE_SCHEMA
local SAFE_INTEGER_SCHEMA = Definitions.SAFE_INTEGER_SCHEMA
local FLOOR_ROUTE_SCHEMA = Definitions.FLOOR_ROUTE_SCHEMA
local ITEM_SCHEMA = Definitions.ITEM_SCHEMA
local INVENTORY_POLICY_SCHEMA = Definitions.INVENTORY_POLICY_SCHEMA
local DAILY_VIP_SCHEMA = Definitions.DAILY_VIP_SCHEMA
local AUTOMATION_POLICY_SCHEMA = Definitions.AUTOMATION_POLICY_SCHEMA
local REWARD_PITY_SCHEMA = Definitions.REWARD_PITY_SCHEMA
local STORY_PROGRESS_SCHEMA = Definitions.STORY_PROGRESS_SCHEMA
local STORY_GATE_SCHEMA = Definitions.STORY_GATE_SCHEMA
local PENDING_EVENT_SCHEMA = Definitions.PENDING_EVENT_SCHEMA
local PENDING_EQUIP_SCHEMA = Definitions.PENDING_EQUIP_SCHEMA
local LOADOUT_BACKUP_SCHEMA = Definitions.LOADOUT_BACKUP_SCHEMA
local SET_PROGRESS_SCHEMA = Definitions.SET_PROGRESS_SCHEMA
local STATS_SCHEMA = Definitions.STATS_SCHEMA
local MARKET_LISTINGS_SCHEMA = Definitions.MARKET_LISTINGS_SCHEMA
local CURRENT_MONSTER_SCHEMA = Definitions.CURRENT_MONSTER_SCHEMA
local validateUniqueFloors = Definitions.ValidateUniqueFloors
local validateLootStash = Definitions.ValidateLootStash
local validateEquipped = Definitions.ValidateEquipped
local validateConsumables = Definitions.ValidateConsumables
local validateAcknowledgements = Definitions.ValidateAcknowledgements
local validateEquipmentCollection = Definitions.ValidateEquipmentCollection
local validateAppliedGmCommandIds = Definitions.ValidateAppliedGmCommandIds

PERSISTED_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = {
        "schemaVersion",
        "revision",
        "updatedAt",
        "lastActiveAt",
        "pendingOfflineSeconds",
        "level",
        "vipLevel",
        "dailyVip",
        "exp",
        "floor",
        "maxFloor",
        "position",
        "transitionRemaining",
        "attemptId",
        "floorDefeats",
        "aidPending",
        "aidGrantedFloors",
        "gold",
        "fragments",
        "autoRun",
        "nextItemId",
        "inventory",
        "overflowLoot",
        "lootStash",
        "equipped",
        "consumables",
        "hpBig",
        "floorKillBonus",
        "permanentBonus",
        "inventoryPolicy",
        "automationPolicy",
        "interactionMode",
        "rewardPity",
        "storyProgress",
        "ruleAcknowledgements",
        "equipmentCollection",
        "marketListings",
        "appliedGmCommandIds",
    },
    fields = {
        schemaVersion = { type = "integer", enum = { GameStateSchema.VERSION } },
        revision = SAFE_INTEGER_SCHEMA,
        updatedAt = SAFE_INTEGER_SCHEMA,
        lastActiveAt = SAFE_INTEGER_SCHEMA,
        pendingOfflineSeconds = { type = "integer", min = 0, max = GameStateSchema.OFFLINE_MAX_SECONDS },
        level = { type = "integer", min = 1, max = 1000000 },
        vipLevel = { type = "integer", min = 0, max = 10 },
        dailyVip = DAILY_VIP_SCHEMA,
        exp = { type = "integer", min = 0, max = 1000000000 },
        floor = { type = "integer", min = 1, max = 1000000000 },
        maxFloor = { type = "integer", min = 1, max = 1000000000 },
        position = { type = "integer", min = 0, max = 10 },
        transitionRemaining = { type = "number", min = 0, max = 60 },
        attemptId = SAFE_INTEGER_SCHEMA,
        floorDefeats = { type = "integer", min = 0, max = 1000000 },
        aidPending = { type = "boolean" },
        aidGrantedFloors = {
            type = "array", maxLength = 10000,
            items = { type = "integer", min = 1, max = 1000000000 },
            validate = validateUniqueFloors,
        },
        gold = CURRENCY_SCHEMA,
        fragments = CURRENCY_SCHEMA,
        autoRun = { type = "boolean" },
        pauseReason = { type = "string", maxLength = 64 },
        nextItemId = { type = "integer", min = 1, max = LargeNumber.MAX_SAFE_INTEGER },
        inventory = {
            type = "array",
            maxLength = GameStateSchema.INVENTORY_CAP,
            items = ITEM_SCHEMA,
        },
        overflowLoot = {
            type = "array",
            maxLength = GameStateSchema.TEMPORARY_LOOT_CAP,
            items = ITEM_SCHEMA,
        },
        lootStash = {
            type = "array",
            maxLength = GameStateSchema.LOOT_STASH_CAP,
            items = { type = "string", minLength = 1, maxLength = 64 },
            validate = validateLootStash,
        },
        equipped = { type = "object", validate = validateEquipped },
        consumables = { type = "object", validate = validateConsumables },
        hp = NONNEGATIVE_NUMBER_SCHEMA,
        hpBig = BIG_NUMBER_SCHEMA,
        floorKillBonus = { type = "number", min = 0, max = 1 },
        permanentBonus = { type = "number", min = 0, max = 1000 },
        inventoryPolicy = INVENTORY_POLICY_SCHEMA,
        automationPolicy = AUTOMATION_POLICY_SCHEMA,
        interactionMode = { type = "string", enum = { "normal", "cinematic" } },
        rewardPity = REWARD_PITY_SCHEMA,
        storyProgress = STORY_PROGRESS_SCHEMA,
        pendingStoryGate = STORY_GATE_SCHEMA,
        pendingEvent = PENDING_EVENT_SCHEMA,
        ruleAcknowledgements = { type = "object", validate = validateAcknowledgements },
        equipmentCollection = { type = "object", validate = validateEquipmentCollection },
        pendingEquipDecision = PENDING_EQUIP_SCHEMA,
        previousLoadout = LOADOUT_BACKUP_SCHEMA,
        currentMonster = CURRENT_MONSTER_SCHEMA, marketListings = MARKET_LISTINGS_SCHEMA,
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

local PERSISTED_VALUE_SCHEMAS = PERSISTED_SCHEMA.fields

local SNAPSHOT_VALUE_SCHEMAS = {
    level = PERSISTED_VALUE_SCHEMAS.level,
    vipLevel = PERSISTED_VALUE_SCHEMAS.vipLevel,
    dailyVip = PERSISTED_VALUE_SCHEMAS.dailyVip,
    exp = PERSISTED_VALUE_SCHEMAS.exp,
    floor = PERSISTED_VALUE_SCHEMAS.floor,
    maxFloor = PERSISTED_VALUE_SCHEMAS.maxFloor,
    position = PERSISTED_VALUE_SCHEMAS.position,
    transitionRemaining = PERSISTED_VALUE_SCHEMAS.transitionRemaining,
    attemptId = PERSISTED_VALUE_SCHEMAS.attemptId,
    floorDefeats = PERSISTED_VALUE_SCHEMAS.floorDefeats,
    aidPending = PERSISTED_VALUE_SCHEMAS.aidPending,
    gold = PERSISTED_VALUE_SCHEMAS.gold,
    fragments = PERSISTED_VALUE_SCHEMAS.fragments,
    autoRun = PERSISTED_VALUE_SCHEMAS.autoRun,
    pauseReason = PERSISTED_VALUE_SCHEMAS.pauseReason,
    pendingOfflineSeconds = PERSISTED_VALUE_SCHEMAS.pendingOfflineSeconds,
    inventory = PERSISTED_VALUE_SCHEMAS.inventory,
    overflowLoot = PERSISTED_VALUE_SCHEMAS.overflowLoot,
    lootStash = PERSISTED_VALUE_SCHEMAS.lootStash,
    equipped = PERSISTED_VALUE_SCHEMAS.equipped,
    consumables = PERSISTED_VALUE_SCHEMAS.consumables,
    hp = PERSISTED_VALUE_SCHEMAS.hp,
    hpBig = PERSISTED_VALUE_SCHEMAS.hpBig,
    floorKillBonus = PERSISTED_VALUE_SCHEMAS.floorKillBonus,
    permanentBonus = PERSISTED_VALUE_SCHEMAS.permanentBonus,
    inventoryPolicy = PERSISTED_VALUE_SCHEMAS.inventoryPolicy,
    automationPolicy = PERSISTED_VALUE_SCHEMAS.automationPolicy,
    interactionMode = PERSISTED_VALUE_SCHEMAS.interactionMode,
    rewardPity = PERSISTED_VALUE_SCHEMAS.rewardPity,
    storyProgress = PERSISTED_VALUE_SCHEMAS.storyProgress,
    pendingStoryGate = PERSISTED_VALUE_SCHEMAS.pendingStoryGate,
    pendingEvent = PERSISTED_VALUE_SCHEMAS.pendingEvent,
    ruleAcknowledgements = PERSISTED_VALUE_SCHEMAS.ruleAcknowledgements,
    equipmentCollection = PERSISTED_VALUE_SCHEMAS.equipmentCollection,
    pendingEquipDecision = PERSISTED_VALUE_SCHEMAS.pendingEquipDecision,
    previousLoadout = PERSISTED_VALUE_SCHEMAS.previousLoadout,
    currentMonster = PERSISTED_VALUE_SCHEMAS.currentMonster, marketListings = MARKET_LISTINGS_SCHEMA,
    floorRoute = FLOOR_ROUTE_SCHEMA,
    setProgress = SET_PROGRESS_SCHEMA,
    logs = {
        type = "array",
        maxLength = GameStateSchema.MAX_LOGS,
        items = { type = "string", maxLength = 256 },
    },
    currentEvent = { type = "string", enum = GameStateSchema.EVENT_TYPES },
    recentDamage = { type = "string", maxLength = 256 },
    stats = STATS_SCHEMA,
    nextExp = NONNEGATIVE_NUMBER_SCHEMA,
    displayedPower = MAGNITUDE_SCHEMA,
    recommendedPower = MAGNITUDE_SCHEMA,
    nextChapterRecommendedPower = MAGNITUDE_SCHEMA,
    powerRatio = NONNEGATIVE_NUMBER_SCHEMA,
    headroomFloors = FINITE_NUMBER_SCHEMA,
    difficultyLabel = { type = "string", minLength = 1, maxLength = 32 },
    bossScore = NONNEGATIVE_NUMBER_SCHEMA,
    eliteScore = NONNEGATIVE_NUMBER_SCHEMA,
    estimatedEasyFloor = NONNEGATIVE_NUMBER_SCHEMA,
}

local SNAPSHOT_ENVELOPE_SCHEMAS = {
    kind = { type = "string", enum = { "GameSnapshot" } },
    schemaVersion = PERSISTED_VALUE_SCHEMAS.schemaVersion,
    revision = PERSISTED_VALUE_SCHEMAS.revision,
    updatedAt = PERSISTED_VALUE_SCHEMAS.updatedAt,
    serverTime = SAFE_INTEGER_SCHEMA,
    status = { type = "string", enum = { "ready" } },
    isAdmin = { type = "boolean" },
    playerNickname = { type = "string", minLength = 1, maxLength = 128 },
    inventoryCapacity = {
        type = "integer",
        min = 1,
        max = GameStateSchema.INVENTORY_CAP,
    },
}

local DELTA_ENVELOPE_SCHEMAS = {
    kind = { type = "string", enum = { "GameDelta" } },
    schemaVersion = PERSISTED_VALUE_SCHEMAS.schemaVersion,
    revision = PERSISTED_VALUE_SCHEMAS.revision,
    serverTime = SAFE_INTEGER_SCHEMA,
    updatedAt = PERSISTED_VALUE_SCHEMAS.updatedAt,
    inventoryChanged = { type = "boolean" },
    changes = { type = "object" },
    events = {
        type = "array",
        maxLength = GameEventSchema.MAX_EVENTS,
        items = { type = "object" },
    },
    eventKind = {
        type = "string",
        minLength = 1,
        maxLength = 64,
        pattern = "^[%a][%w%._:%-]*$",
    },
}

local SNAPSHOT_REQUIRED_FIELDS = {
    "kind", "schemaVersion", "revision", "updatedAt", "serverTime", "status",
    "isAdmin", "playerNickname", "inventoryCapacity",
    "level", "vipLevel", "dailyVip", "exp", "floor", "maxFloor", "position", "transitionRemaining",
    "attemptId", "floorDefeats", "aidPending",
    "gold", "fragments", "autoRun", "pendingOfflineSeconds",
    "inventory", "overflowLoot", "lootStash", "equipped", "consumables", "hpBig",
    "floorKillBonus", "permanentBonus", "inventoryPolicy", "automationPolicy",
    "interactionMode", "rewardPity", "storyProgress", "ruleAcknowledgements",
    "logs", "currentEvent", "recentDamage", "stats", "nextExp",
    "displayedPower", "recommendedPower", "nextChapterRecommendedPower",
    "powerRatio", "headroomFloors", "difficultyLabel", "bossScore", "eliteScore",
    "estimatedEasyFloor",
}


local GameStateBoundarySchemas = {
    PERSISTED_SCHEMA = PERSISTED_SCHEMA,
    PERSISTED_VALUE_SCHEMAS = PERSISTED_VALUE_SCHEMAS,
    SNAPSHOT_VALUE_SCHEMAS = SNAPSHOT_VALUE_SCHEMAS,
    SNAPSHOT_ENVELOPE_SCHEMAS = SNAPSHOT_ENVELOPE_SCHEMAS,
    DELTA_ENVELOPE_SCHEMAS = DELTA_ENVELOPE_SCHEMAS,
    SNAPSHOT_REQUIRED_FIELDS = SNAPSHOT_REQUIRED_FIELDS,
}

return GameStateBoundarySchemas
