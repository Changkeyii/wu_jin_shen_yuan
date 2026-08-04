local ErrorCodes = require("shared.ErrorCodes")
local NetworkProtocol = require("shared.NetworkProtocol")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local RarityCatalog = require("shared.RarityCatalog")
local GameEventSchema = require("shared.GameEventSchema")

local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")

local GameStateSchema = {}

GameStateSchema.VERSION = 5
GameStateSchema.INVENTORY_CAP = 300
GameStateSchema.TEMPORARY_LOOT_CAP = 60
GameStateSchema.LOOT_STASH_CAP = 60
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

GameStateSchema.RARITIES = RarityCatalog.ORDER
GameStateSchema.SET_IDS = { "nightmare", "lucky", "voyage", "abyss", "prophecy" }
GameStateSchema.EVENT_TYPES = { "monster", "elite", "chest", "merchant", "random", "boss", "chapter_boss" }

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
    "vipLevel",
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
    "mythShards",
    "autoRun",
    "pauseReason",
    "nextItemId",
    "inventory",
    "overflowLoot",
    "lootStash",
    "equipped",
    "consumables",
    "hp",
    "hpBig",
    "floorKillBonus",
    "permanentBonus",
    "inventoryPolicy",
    "automationPolicy",
    "interactionMode",
    "rewardPity",
    "storyProgress",
    "pendingStoryGate",
    "ruleAcknowledgements",
    "pendingEquipDecision",
    "previousLoadout",
    "currentMonster",
    "equipmentCollection",
    "marketListings",
    "appliedGmCommandIds",
}

local SNAPSHOT_FIELDS = {
    "level",
    "vipLevel",
    "exp",
    "floor",
    "maxFloor",
    "position",
    "transitionRemaining",
    "attemptId",
    "floorDefeats",
    "aidPending",
    "gold",
    "fragments",
    "mythShards",
    "autoRun",
    "pauseReason",
    "pendingOfflineSeconds",
    "inventory",
    "overflowLoot",
    "lootStash",
    "equipped",
    "consumables",
    "hp",
    "hpBig",
    "floorKillBonus",
    "permanentBonus",
    "inventoryPolicy",
    "automationPolicy",
    "interactionMode",
    "rewardPity",
    "storyProgress",
    "pendingStoryGate",
    "ruleAcknowledgements",
    "pendingEquipDecision",
    "previousLoadout",
    "currentMonster",
    "equipmentCollection",
    "marketListings",
    "floorRoute",
    "setProgress",
    "logs",
    "currentEvent",
    "recentDamage",
    "stats",
    "nextExp",
    "displayedPower",
    "recommendedPower",
    "nextChapterRecommendedPower",
    "powerRatio",
    "headroomFloors",
    "difficultyLabel",
    "bossScore",
    "eliteScore",
    "estimatedEasyFloor",
}

local DELTA_FIELD_SET = {}
for _, fieldName in ipairs(SNAPSHOT_FIELDS) do
    DELTA_FIELD_SET[fieldName] = true
end

local SNAPSHOT_FIELD_SET = {
    kind = true,
    schemaVersion = true,
    revision = true,
    updatedAt = true,
    serverTime = true,
    status = true,
    isAdmin = true,
    playerNickname = true,
    inventoryCapacity = true,
}
for _, fieldName in ipairs(SNAPSHOT_FIELDS) do
    SNAPSHOT_FIELD_SET[fieldName] = true
end

local DELTA_ENVELOPE_FIELD_SET = {
    kind = true,
    schemaVersion = true,
    revision = true,
    serverTime = true,
    updatedAt = true,
    inventoryChanged = true,
    changes = true,
    events = true,
    eventKind = true,
}

local function copyArray(value)
    local result = {}
    for index, item in ipairs(type(value) == "table" and value or {}) do result[index] = item end
    return result
end

local deepCopy

local function networkItem(item)
    return {
        id = item.id,
        equipmentId = item.equipmentId,
        level = item.level,
        enhance = item.enhance or 0,
        star = item.star or 0,
        locked = item.locked == true,
        acquiredAt = item.acquiredAt or 0,
        source = item.source or "legacy",
        tradeable = item.tradeable == true,
        statVersion = item.statVersion or 5,
        budget = item.budget,
        budgetBig = deepCopy(item.budgetBig),
        rarity = RarityCatalog.NormalizeId(item.rarity),
        setEnabled = item.setEnabled ~= false,
        setId = item.setId,
        roll = item.roll or 1,
        atk = item.atk,
        def = item.def,
        hp = item.hp,
        atkBig = deepCopy(item.atkBig),
        defBig = deepCopy(item.defBig),
        hpBig = deepCopy(item.hpBig),
        crit = item.crit,
        critDmg = item.critDmg,
        atkSpeed = item.atkSpeed,
        lifeSteal = item.lifeSteal,
        damageReduction = item.damageReduction,
        bossDamage = item.bossDamage,
        coreAffixes = copyArray(item.coreAffixes),
        uniqueEffect = item.uniqueEffect,
        aidLocked = item.aidLocked == true,
        aidFloor = item.aidFloor,
        investedGold = LargeNumber.IsLargeNumber(item.investedGold)
            and LargeNumber.Normalize(item.investedGold)
            or LargeNumber.FromNumber(item.investedGold),
        investedFragments = item.investedFragments or 0,
        power = item.power,
    }
end

local function networkInventory(items)
    local result = {}
    for _, item in ipairs(items or {}) do
        result[#result + 1] = networkItem(item)
    end
    return result
end

deepCopy = function(value, seen)
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
    local exponent = math.max(1, tonumber(level) or 1) - 1
    local required = 100 * (1.15 ^ exponent)
    if required ~= required or required == math.huge or required == -math.huge then
        return 1000000000
    end
    return math.min(1000000000, math.floor(required))
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
    if valueType == "number"
        and value == math.floor(value)
        and value > 0
        and value <= LargeNumber.MAX_SAFE_INTEGER
    then
        return true
    end
    return false, "Equipment id must be a non-empty string or positive integer"
end

local function validateInstanceUuid(value)
    if type(value) ~= "string" then return false, "Equipment instance id must be a UUID string" end
    if not string.match(value, "^[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+$") then
        return false, "Equipment instance id must be a UUID string"
    end
    return true
end

local CURRENCY_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "high", "mid", "low" },
    fields = {
        high = { type = "integer", min = 0, max = LargeNumber.SEGMENT_MAX },
        mid = { type = "integer", min = 0, max = LargeNumber.SEGMENT_MAX },
        low = { type = "integer", min = 0, max = LargeNumber.SEGMENT_MAX },
    },
}

local function validateBigNumber(value)
    return BigNumber.ValidateCanonical(value)
end

local BIG_NUMBER_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "mantissa", "exponent" },
    fields = {
        mantissa = { type = "number", min = 0, max = 10 },
        exponent = {
            type = "integer",
            min = BigNumber.MIN_SERIALIZED_EXPONENT,
            max = BigNumber.MAX_SERIALIZED_EXPONENT,
        },
    },
    validate = validateBigNumber,
}

local function validateFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge,
        "Value must be finite"
end

local function validateNonnegativeNumber(value)
    local finite, reason = validateFiniteNumber(value)
    if not finite then return false, reason end
    return value >= 0, "Magnitude must be non-negative"
end

local function validateMagnitude(value)
    if type(value) == "number" then return validateNonnegativeNumber(value) end
    return validateBigNumber(value)
end

local FINITE_NUMBER_SCHEMA = { type = "number", validate = validateFiniteNumber }
local NONNEGATIVE_NUMBER_SCHEMA = { type = "number", validate = validateNonnegativeNumber }
local MAGNITUDE_SCHEMA = { type = "any", validate = validateMagnitude }
local SAFE_INTEGER_SCHEMA = {
    type = "integer",
    min = 0,
    max = LargeNumber.MAX_SAFE_INTEGER,
}
local NONNEGATIVE_RATIO_SCHEMA = {
    type = "number",
    min = 0,
    max = 1,
}

local FLOOR_ROUTE_ENCOUNTER_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "encounterId", "room", "distance", "kind", "eventType", "isBoss" },
    fields = {
        encounterId = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" },
        room = { type = "integer", min = 1, max = 10 },
        distance = { type = "number", min = 0, max = 100000 },
        kind = { type = "string", enum = { "normal", "elite", "boss", "chapterBoss" } },
        eventType = { type = "string", enum = { "monster", "elite", "boss" } },
        isBoss = { type = "boolean" },
    },
}

local FLOOR_ROUTE_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "version", "routeId", "floor", "moveSpeed", "triggerDistance", "encounters" },
    fields = {
        version = { type = "integer", min = 1, max = 1000 },
        routeId = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" },
        floor = { type = "integer", min = 1, max = 1000000 },
        moveSpeed = { type = "number", min = 1, max = 10000 },
        triggerDistance = { type = "number", min = 0, max = 10000 },
        encounters = {
            type = "array",
            minLength = 10,
            maxLength = 10,
            items = FLOOR_ROUTE_ENCOUNTER_SCHEMA,
        },
    },
}

local ITEM_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = {
        "id", "equipmentId", "level", "statVersion", "rarity", "setEnabled", "roll",
        "budgetBig", "atkBig", "defBig", "hpBig",
    },
    fields = {
        id = { type = "string", minLength = 36, maxLength = 36, validate = validateInstanceUuid },
        equipmentId = { type = "string", minLength = 36, maxLength = 36 },
        level = { type = "integer", min = 1, max = 1000000 },
        statVersion = { type = "integer", enum = { 5 } },
        budget = NONNEGATIVE_NUMBER_SCHEMA,
        budgetBig = BIG_NUMBER_SCHEMA,
        rarity = { type = "string", enum = GameStateSchema.RARITIES },
        setEnabled = { type = "boolean" },
        setId = { type = "string", enum = GameStateSchema.SET_IDS },
        roll = { type = "number", min = 0.90, max = 1.10 },
        atk = NONNEGATIVE_NUMBER_SCHEMA,
        def = NONNEGATIVE_NUMBER_SCHEMA,
        hp = NONNEGATIVE_NUMBER_SCHEMA,
        atkBig = BIG_NUMBER_SCHEMA,
        defBig = BIG_NUMBER_SCHEMA,
        hpBig = BIG_NUMBER_SCHEMA,
        crit = { type = "number", min = 0, max = 1 },
        critDmg = { type = "number", min = 0, max = 1000 },
        atkSpeed = { type = "number", min = 0, max = 100 },
        lifeSteal = { type = "number", min = 0, max = 1 },
        damageReduction = { type = "number", min = 0, max = 0.70 },
        bossDamage = { type = "number", min = 0, max = 1000 },
        coreAffixes = {
            type = "array", maxLength = 4,
            items = { type = "string", minLength = 1, maxLength = 64, pattern = "^[%w%._:%-]+$" },
        },
        uniqueEffect = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" },
        aidLocked = { type = "boolean" },
        aidFloor = { type = "integer", min = 1, max = 1000000000 },
        enhance = { type = "integer", min = 0, max = 1000 },
        star = { type = "integer", min = 0, max = 5 },
        locked = { type = "boolean" },
        acquiredAt = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
        source = { type = "string", minLength = 1, maxLength = 64, pattern = "^[%w%._:%-]+$" },
        tradeable = { type = "boolean" },
        investedGold = CURRENCY_SCHEMA,
        investedFragments = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
        power = MAGNITUDE_SCHEMA,
    },
}

local INVENTORY_POLICY_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "pauseOnFull", "autoDecompose", "autoSell", "decomposeRarities", "sellRarities" },
    fields = {
        pauseOnFull = { type = "boolean" },
        autoDecompose = { type = "boolean" },
        autoSell = { type = "boolean" },
        decomposeRarities = {
            type = "object",
            allowUnknown = false,
            fields = {
                common = { type = "boolean" },
                advanced = { type = "boolean" },
                rare = { type = "boolean" },
                artifact = { type = "boolean" },
                legendary = { type = "boolean" },
                epic = { type = "boolean" },
                myth = { type = "boolean", enum = { false } },
            },
        },
        sellRarities = {
            type = "object",
            allowUnknown = false,
            fields = {
                common = { type = "boolean" },
                advanced = { type = "boolean" },
                rare = { type = "boolean" },
                artifact = { type = "boolean" },
                legendary = { type = "boolean" },
                epic = { type = "boolean" },
                myth = { type = "boolean", enum = { false } },
            },
        },
    },
}

local CURRENT_MONSTER_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = {
        "id",
        "eventType",
        "name",
        "hpBig",
        "maxHpBig",
        "atkBig",
        "defBig",
        "phase",
        "phaseRemaining",
        "attackSerial",
        "lastSequenceIndex",
        "room",
        "encounter",
        "hitIndex",
        "elapsedSeconds",
        "enraged",
        "nextMonsterAttackSeconds",
    },
    fields = {
        id = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" },
        eventType = { type = "string", enum = { "monster", "elite", "boss" } },
        name = { type = "string", minLength = 1, maxLength = 128 },
        hp = NONNEGATIVE_NUMBER_SCHEMA,
        maxHp = NONNEGATIVE_NUMBER_SCHEMA,
        atk = NONNEGATIVE_NUMBER_SCHEMA,
        def = NONNEGATIVE_NUMBER_SCHEMA,
        hpBig = BIG_NUMBER_SCHEMA,
        maxHpBig = BIG_NUMBER_SCHEMA,
        atkBig = BIG_NUMBER_SCHEMA,
        defBig = BIG_NUMBER_SCHEMA,
        phase = { type = "string", enum = { "windup", "recovery" } },
        phaseRemaining = { type = "number", min = 0, max = 60 },
        attackSerial = { type = "integer", min = 1, max = 1000000000 },
        sequenceIndex = { type = "integer", min = 1, max = 3 },
        sequenceId = { type = "string", enum = { "attackA", "attackB", "attackC" } },
        fps = { type = "integer", min = 1, max = 120 },
        hitFrame = { type = "integer", min = 1, max = 48 },
        endFrame = { type = "integer", min = 1, max = 48 },
        recoverySeconds = { type = "number", min = 0, max = 60 },
        lastSequenceIndex = { type = "integer", min = 0, max = 3 },
        room = { type = "integer", min = 1, max = 10 },
        encounter = { type = "string", enum = { "normal", "elite", "boss", "chapterBoss" } },
        hitIndex = { type = "integer", min = 0, max = 4 },
        elapsedSeconds = { type = "number", min = 0, max = 3600 },
        enraged = { type = "boolean" },
        nextMonsterAttackSeconds = { type = "number", min = 0, max = 60 },
        isChapterBoss = { type = "boolean" },
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
        if type(quantity) ~= "number"
            or quantity ~= math.floor(quantity)
            or quantity < 0
            or quantity > LargeNumber.MAX_SAFE_INTEGER
        then
            return false, "Consumable quantities must be non-negative integers"
        end
    end
    return true
end

local function validateUniqueFloors(value)
    local seen = {}
    for _, floor in ipairs(value) do
        if type(floor) ~= "number" or floor ~= math.floor(floor) or floor < 1 or floor > 1000000000 then
            return false, "Aid floors must be positive integers"
        end
        if seen[floor] then return false, "Aid floors must be unique" end
        seen[floor] = true
    end
    return true
end

local function validateAcknowledgements(value)
    for ruleId, acknowledged in pairs(value) do
        if type(ruleId) ~= "string" or #ruleId < 1 or #ruleId > 96
            or string.match(ruleId, "^[%w%._:%-]+$") == nil
            or acknowledged ~= true
        then
            return false, "Rule acknowledgements must map safe ids to true"
        end
    end
    return true
end

local function validateEquipmentCollection(value)
    local definitions = {}
    for _, definition in ipairs(EquipmentCatalog.GetAll()) do
        definitions[definition.id] = true
    end
    local count = 0
    for equipmentId, record in pairs(value) do
        count = count + 1
        if count > #EquipmentCatalog.GetAll() or not definitions[equipmentId] or type(record) ~= "table" then
            return false, "Equipment collection contains an invalid definition"
        end
        if not BigNumber.ValidateCanonical(record.powerBig) then
            return false, "Equipment collection power is invalid"
        end
        if type(record.level) ~= "number" or record.level ~= math.floor(record.level)
            or record.level < 1 or record.level > 1000000
            or type(record.enhance) ~= "number" or record.enhance ~= math.floor(record.enhance)
            or record.enhance < 0 or record.enhance > 1000
            or type(record.star) ~= "number" or record.star ~= math.floor(record.star)
            or record.star < 0 or record.star > 5
            or type(record.rarity) ~= "string"
        then
            return false, "Equipment collection record is invalid"
        end
    end
    return true
end

local function validateLootStash(value)
    local seen = {}
    for _, itemId in ipairs(value) do
        local key = tostring(itemId)
        if seen[key] then return false, "Loot stash item ids must be unique" end
        seen[key] = true
    end
    return true
end

local AUTOMATION_POLICY_SCHEMA = {
    type = "object", allowUnknown = false,
    required = { "autoEquip", "lootAutoEquip", "autoSkipStory" },
    fields = {
        autoEquip = { type = "boolean" },
        lootAutoEquip = { type = "boolean" },
        autoSkipStory = { type = "boolean" },
    },
}

local REWARD_PITY_SCHEMA = {
    type = "object", allowUnknown = false,
    required = { "epicMisses", "mythMisses" },
    fields = {
        epicMisses = { type = "integer", min = 0, max = 20 },
        mythMisses = { type = "integer", min = 0, max = 100 },
    },
}

local STORY_PROGRESS_SCHEMA = {
    type = "object", allowUnknown = false,
    required = { "introCompleted", "highestCompletedChapter", "contentVersion" },
    fields = {
        introCompleted = { type = "boolean" },
        highestCompletedChapter = { type = "integer", min = 0, max = 100000000 },
        contentVersion = { type = "integer", min = 1, max = 1000000 },
    },
}

local STORY_GATE_SCHEMA = {
    type = "object", allowUnknown = false,
    required = { "storyId", "chapter", "floor", "phase", "title", "lines", "lineIndex" },
    fields = {
        storyId = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" },
        chapter = { type = "integer", min = 0, max = 100000000 },
        floor = { type = "integer", min = 1, max = 1000000000 },
        phase = { type = "string", enum = { "prologue", "opening", "boss", "memory" } },
        title = { type = "string", minLength = 1, maxLength = 128 },
        lines = { type = "array", minLength = 1, maxLength = 32, items = { type = "string", minLength = 1, maxLength = 512 } },
        lineIndex = { type = "integer", min = 1, max = 32 },
    },
    validate = function(value)
        if value.lineIndex > #value.lines then
            return false, "Story line index exceeds the available lines"
        end
        return true
    end,
}

local PENDING_EQUIP_SCHEMA = {
    type = "object", allowUnknown = false,
    required = { "itemId", "createdAt", "displayedPowerDeltaBig" },
    fields = {
        itemId = { type = "string", minLength = 36, maxLength = 36, validate = validateInstanceUuid },
        createdAt = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
        oldTowerScore = { type = "number", min = 0, max = 1e300 },
        newTowerScore = { type = "number", min = 0, max = 1e300 },
        oldBossScore = { type = "number", min = 0, max = 1e300 },
        newBossScore = { type = "number", min = 0, max = 1e300 },
        displayedPowerDelta = FINITE_NUMBER_SCHEMA,
        displayedPowerDeltaBig = BIG_NUMBER_SCHEMA,
        headroomDelta = { type = "number", min = -1000000000, max = 1000000000 },
    },
}

local LOADOUT_BACKUP_SCHEMA = {
    type = "object", allowUnknown = false,
    required = { "equipped", "createdAt", "available" },
    fields = {
        equipped = { type = "object", validate = validateEquipped },
        createdAt = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
        available = { type = "boolean" },
    },
}

local SET_PROGRESS_ENTRY_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "count", "regions", "activeTiers", "activeRegions" },
    fields = {
        count = { type = "integer", min = 0, max = #GameStateSchema.SLOTS },
        regions = {
            type = "object",
            allowUnknown = false,
            required = { "weapon", "armor", "jewelry", "special" },
            fields = {
                weapon = { type = "integer", min = 0, max = 1 },
                armor = { type = "integer", min = 0, max = 5 },
                jewelry = { type = "integer", min = 0, max = 3 },
                special = { type = "integer", min = 0, max = 3 },
            },
        },
        activeTiers = {
            type = "object",
            allowUnknown = false,
            required = { "3", "6", "9", "12" },
            fields = {
                ["3"] = { type = "boolean" },
                ["6"] = { type = "boolean" },
                ["9"] = { type = "boolean" },
                ["12"] = { type = "boolean" },
            },
        },
        activeRegions = {
            type = "object",
            allowUnknown = false,
            required = { "armor", "jewelry", "special" },
            fields = {
                armor = { type = "boolean" },
                jewelry = { type = "boolean" },
                special = { type = "boolean" },
            },
        },
    },
}

local SET_PROGRESS_FIELDS = {}
for _, setId in ipairs(GameStateSchema.SET_IDS) do
    SET_PROGRESS_FIELDS[setId] = SET_PROGRESS_ENTRY_SCHEMA
end

local SET_PROGRESS_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = GameStateSchema.SET_IDS,
    fields = SET_PROGRESS_FIELDS,
}

local STATS_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = {
        "atkBig", "defBig", "hpBig", "maxHpBig",
        "crit", "critDmg", "atkSpeed", "lifeSteal", "bossDamage",
        "damageBonus", "trueDamageRate", "luckyChance", "luckyMultiplier",
        "moveSpeed", "skillDamage", "damageOverTime", "damageReduction",
        "lowHealthGuard", "permanentBonus", "setProgress", "power",
        "powerRatio", "headroomFloors", "difficultyLabel", "equivalentFloor",
        "estimatedEasyFloor", "towerScore", "bossScore", "eliteScore", "dpsSafe",
    },
    fields = {
        atk = NONNEGATIVE_NUMBER_SCHEMA,
        def = NONNEGATIVE_NUMBER_SCHEMA,
        hp = NONNEGATIVE_NUMBER_SCHEMA,
        atkBig = BIG_NUMBER_SCHEMA,
        defBig = BIG_NUMBER_SCHEMA,
        hpBig = BIG_NUMBER_SCHEMA,
        maxHpBig = BIG_NUMBER_SCHEMA,
        crit = NONNEGATIVE_RATIO_SCHEMA,
        critDmg = NONNEGATIVE_NUMBER_SCHEMA,
        atkSpeed = { type = "number", min = 0.5, max = 3 },
        lifeSteal = NONNEGATIVE_RATIO_SCHEMA,
        bossDamage = NONNEGATIVE_NUMBER_SCHEMA,
        damageBonus = NONNEGATIVE_NUMBER_SCHEMA,
        trueDamageRate = NONNEGATIVE_RATIO_SCHEMA,
        luckyChance = NONNEGATIVE_RATIO_SCHEMA,
        luckyMultiplier = NONNEGATIVE_NUMBER_SCHEMA,
        moveSpeed = NONNEGATIVE_NUMBER_SCHEMA,
        skillDamage = NONNEGATIVE_NUMBER_SCHEMA,
        damageOverTime = NONNEGATIVE_NUMBER_SCHEMA,
        damageReduction = { type = "number", min = 0, max = 0.70 },
        lowHealthGuard = NONNEGATIVE_RATIO_SCHEMA,
        permanentBonus = { type = "number", min = 0, max = 1000 },
        lowHealthDamage = NONNEGATIVE_RATIO_SCHEMA,
        luckyPity = { type = "integer", min = 0, max = 100 },
        moveBurst = NONNEGATIVE_RATIO_SCHEMA,
        enemyDamageReduction = NONNEGATIVE_RATIO_SCHEMA,
        permanentGrowthActive = { type = "boolean" },
        setProgress = SET_PROGRESS_SCHEMA,
        power = MAGNITUDE_SCHEMA,
        displayedPower = MAGNITUDE_SCHEMA,
        recommendedPower = MAGNITUDE_SCHEMA,
        nextChapterRecommendedPower = MAGNITUDE_SCHEMA,
        powerRatio = NONNEGATIVE_NUMBER_SCHEMA,
        headroomFloors = FINITE_NUMBER_SCHEMA,
        difficultyLabel = { type = "string", minLength = 1, maxLength = 32 },
        equivalentFloor = NONNEGATIVE_NUMBER_SCHEMA,
        estimatedEasyFloor = NONNEGATIVE_NUMBER_SCHEMA,
        towerScore = NONNEGATIVE_NUMBER_SCHEMA,
        bossScore = NONNEGATIVE_NUMBER_SCHEMA,
        eliteScore = NONNEGATIVE_NUMBER_SCHEMA,
        dpsSafe = NONNEGATIVE_NUMBER_SCHEMA,
        ehp = NONNEGATIVE_NUMBER_SCHEMA,
    },
}

local function normalizeCurrencyValue(value)
    if LargeNumber.IsLargeNumber(value) then
        return LargeNumber.Normalize(value)
    end
    if type(value) == "string" then
        return LargeNumber.FromString(value) or LargeNumber.Zero()
    end
    return LargeNumber.FromNumber(value)
end

--- 挂单镜像归一化。丢弃结构不完整的条目，保证 schema 校验不会因历史脏数据失败。
local function normalizeMarketListings(value)
    if type(value) ~= "table" then return {} end
    local listings = {}
    for _, entry in ipairs(value) do
        if type(entry) == "table" then
            local price = normalizeCurrencyValue(entry.price)
            local itemId = entry.itemId
            if not LargeNumber.IsZero(price)
                and type(itemId) == "string" and #itemId > 0
            then
                listings[#listings + 1] = {
                    itemId = itemId,
                    price = price,
                    standardValue = normalizeCurrencyValue(entry.standardValue),
                    feeRate = math.max(0, math.min(1, tonumber(entry.feeRate) or 0)),
                    feeUnits = math.max(0, math.min(1000,
                        math.floor(tonumber(entry.feeUnits)
                            or ((tonumber(entry.feeRate) or 0) * 1000 + 0.5)))),
                    rarity = type(entry.rarity) == "string" and entry.rarity or "epic",
                    slot = type(entry.slot) == "string" and entry.slot or "weapon",
                    level = math.max(1, math.floor(tonumber(entry.level) or 1)),
                    name = type(entry.name) == "string" and entry.name or nil,
                    listedAt = math.max(0, math.floor(tonumber(entry.listedAt) or 0)),
                    expiresAt = math.max(0, math.floor(tonumber(entry.expiresAt) or 0)),
                }
            end
        end
    end
    return listings
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

--- 卖家自己的挂单镜像。云端账本是挂单存在性的权威来源，
--- 这份镜像用于挂单数上限校验与"我的挂单"展示，成交/退回的邮件被领取时同步移除。
--- 挂单标识直接复用装备自身的 itemId（uuid），避免依赖云端分配的 list_id。
local MARKET_LISTINGS_SCHEMA = {
    type = "array",
    maxLength = 64,
    items = {
        type = "object",
        allowUnknown = false,
        required = { "itemId", "price", "rarity", "slot", "level", "listedAt", "expiresAt" },
        fields = {
            itemId = { type = "string", minLength = 1, maxLength = 64 },
            price = CURRENCY_SCHEMA,
            standardValue = CURRENCY_SCHEMA,
            feeRate = { type = "number", min = 0, max = 1 },
            feeUnits = { type = "integer", min = 0, max = 1000 },
            rarity = { type = "string", minLength = 1, maxLength = 32 },
            slot = { type = "string", minLength = 1, maxLength = 32 },
            level = { type = "integer", min = 1, max = 1000000000 },
            name = { type = "string", maxLength = 64 },
            listedAt = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
            expiresAt = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
        },
    },
}

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
        "vipLevel",
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
        "mythShards",
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
        vipLevel = { type = "integer", min = 0, max = 40 },
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
        mythShards = CURRENCY_SCHEMA,
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

local PERSISTED_VALUE_SCHEMAS = GameStateSchema.PERSISTED_SCHEMA.fields

local SNAPSHOT_VALUE_SCHEMAS = {
    level = PERSISTED_VALUE_SCHEMAS.level,
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
    mythShards = PERSISTED_VALUE_SCHEMAS.mythShards,
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
    "level", "exp", "floor", "maxFloor", "position", "transitionRemaining",
    "attemptId", "floorDefeats", "aidPending",
    "gold", "fragments", "mythShards", "autoRun", "pendingOfflineSeconds",
    "inventory", "overflowLoot", "lootStash", "equipped", "consumables", "hpBig",
    "floorKillBonus", "permanentBonus", "inventoryPolicy", "automationPolicy",
    "interactionMode", "rewardPity", "storyProgress", "ruleAcknowledgements",
    "logs", "currentEvent", "recentDamage", "stats", "nextExp",
    "displayedPower", "recommendedPower", "nextChapterRecommendedPower",
    "powerRatio", "headroomFloors", "difficultyLabel", "bossScore", "eliteScore",
    "estimatedEasyFloor",
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
        pendingOfflineSeconds = 0,
        level = 1,
        vipLevel = 0,
        exp = 0,
        floor = 1,
        maxFloor = 1,
        position = 0,
        transitionRemaining = 0,
        attemptId = 0,
        floorDefeats = 0,
        aidPending = false,
        aidGrantedFloors = {},
        gold = LargeNumber.Zero(),
        fragments = LargeNumber.Zero(),
        mythShards = LargeNumber.Zero(),
        autoRun = false,
        nextItemId = 1,
        inventory = {},
        overflowLoot = {},
        lootStash = {},
        equipped = {},
        consumables = { healthPotion = 0 },
        hp = 1,
        hpBig = BigNumber.FromNumber(1),
        floorKillBonus = 0,
        permanentBonus = 0,
        inventoryPolicy = {
            pauseOnFull = true,
            autoDecompose = false,
            autoSell = false,
            decomposeRarities = { common = false, advanced = false, rare = false, artifact = false, legendary = false, epic = false, myth = false },
            sellRarities = { common = false, advanced = false, rare = false, artifact = false, legendary = false, epic = false, myth = false },
        },
        automationPolicy = { autoEquip = false, lootAutoEquip = false, autoSkipStory = false },
        interactionMode = "normal",
        rewardPity = { epicMisses = 0, mythMisses = 0 },
        storyProgress = { introCompleted = false, highestCompletedChapter = 0, contentVersion = 1 },
        pendingStoryGate = nil,
        ruleAcknowledgements = {},
        equipmentCollection = {}, marketListings = {},
        pendingEquipDecision = nil,
        previousLoadout = nil,
        appliedGmCommandIds = {},
        currentMonster = nil,
        logs = {},
        currentEvent = "monster",
        recentDamage = "",
    }
end

---@param state table
---@return table
function GameStateSchema.ToPersistedState(state)
    ---@type table<string, any>
    local persisted = {}
    for _, fieldName in ipairs(PERSISTED_FIELDS) do
        local value = state[fieldName]
        if fieldName == "inventory" or fieldName == "overflowLoot" then
            local items = {}
            for _, item in ipairs(value or {}) do
                items[#items + 1] = {
                    id = item.id,
                    equipmentId = item.equipmentId,
                    level = item.level,
                    enhance = item.enhance,
                    star = item.star,
                    locked = item.locked == true,
                    acquiredAt = item.acquiredAt or 0,
                    source = item.source or "legacy",
                    tradeable = item.tradeable == true,
                    statVersion = item.statVersion or 5,
                    budget = item.budget,
                    budgetBig = deepCopy(item.budgetBig),
                    rarity = RarityCatalog.NormalizeId(item.rarity),
                    setEnabled = item.setEnabled ~= false,
                    setId = item.setId,
                    roll = item.roll or 1,
                    atk = item.atk,
                    def = item.def,
                    hp = item.hp,
                    atkBig = deepCopy(item.atkBig),
                    defBig = deepCopy(item.defBig),
                    hpBig = deepCopy(item.hpBig),
                    crit = item.crit,
                    critDmg = item.critDmg,
                    atkSpeed = item.atkSpeed,
                    lifeSteal = item.lifeSteal,
                    damageReduction = item.damageReduction,
                    bossDamage = item.bossDamage,
                    coreAffixes = copyArray(item.coreAffixes),
                    uniqueEffect = item.uniqueEffect,
                    aidLocked = item.aidLocked == true,
                    aidFloor = item.aidFloor,
                    investedGold = LargeNumber.IsLargeNumber(item.investedGold)
                        and LargeNumber.Normalize(item.investedGold)
                        or LargeNumber.FromNumber(item.investedGold),
                    investedFragments = item.investedFragments or 0,
                }
            end
            persisted[fieldName] = items
        elseif value ~= nil then
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
    for _, item in ipairs(persisted.overflowLoot or {}) do item.power = nil end
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
    local sourceVersion = tonumber(rawState.schemaVersion) or 3
    normalized.schemaVersion = GameStateSchema.VERSION
    normalized.vipLevel = math.max(0, math.min(40, math.floor(tonumber(normalized.vipLevel) or 0)))
    if sourceVersion < 4 then
        normalized.position = 0
        normalized.currentMonster = nil
        normalized.floorDefeats = 0
        normalized.aidPending = false
        normalized.storyProgress = {
            introCompleted = true,
            highestCompletedChapter = math.max(0, math.floor((math.max(1, normalized.maxFloor or 1) - 1) / 10)),
            contentVersion = 1,
        }
        local policy = type(rawState.inventoryPolicy) == "table" and rawState.inventoryPolicy or {}
        local oldDecompose = type(policy.decomposeRarities) == "table" and policy.decomposeRarities or {}
        local oldSell = type(policy.sellRarities) == "table" and policy.sellRarities or {}
        normalized.inventoryPolicy.decomposeRarities.advanced = oldDecompose.advanced == true or oldDecompose.blue == true
        normalized.inventoryPolicy.decomposeRarities.rare = oldDecompose.rare == true or oldDecompose.purple == true
        normalized.inventoryPolicy.sellRarities.advanced = oldSell.advanced == true or oldSell.blue == true
        normalized.inventoryPolicy.sellRarities.rare = oldSell.rare == true or oldSell.purple == true
    end
    if sourceVersion < 5 then
        normalized.hpBig = BigNumber.FromNumber(normalized.hp)
        for _, item in ipairs(normalized.inventory or {}) do
            item.statVersion = 5
            item.budgetBig = BigNumber.FromNumber(item.budget)
            item.atkBig = BigNumber.FromNumber(item.atk)
            item.defBig = BigNumber.FromNumber(item.def)
            item.hpBig = BigNumber.FromNumber(item.hp)
        end
        for _, item in ipairs(normalized.overflowLoot or {}) do
            item.statVersion = 5
            item.budgetBig = BigNumber.FromNumber(item.budget)
            item.atkBig = BigNumber.FromNumber(item.atk)
            item.defBig = BigNumber.FromNumber(item.def)
            item.hpBig = BigNumber.FromNumber(item.hp)
        end
        if type(normalized.currentMonster) == "table" then
            local monster = normalized.currentMonster
            monster.hpBig = BigNumber.FromNumber(monster.hp)
            monster.maxHpBig = BigNumber.FromNumber(monster.maxHp)
            monster.atkBig = BigNumber.FromNumber(monster.atk)
            monster.defBig = BigNumber.FromNumber(monster.def)
        end
        if type(normalized.pendingEquipDecision) == "table" then
            local decision = normalized.pendingEquipDecision
            decision.displayedPowerDeltaBig = BigNumber.FromNumber(
                math.max(0, tonumber(decision.displayedPowerDelta) or 0))
        end
    end
    if BigNumber.IsBigNumber(normalized.hpBig) then
        normalized.hp = BigNumber.ToNumber(normalized.hpBig)
    end
    normalized.marketListings = normalizeMarketListings(normalized.marketListings)
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
        playerNickname = options.playerNickname,
        inventoryCapacity = options.inventoryCapacity or GameStateSchema.INVENTORY_CAP,
    }
    for _, fieldName in ipairs(SNAPSHOT_FIELDS) do
        if state[fieldName] ~= nil then
            snapshot[fieldName] = deepCopy(state[fieldName])
        end
    end

    snapshot.inventory = networkInventory(state.inventory)
    snapshot.overflowLoot = networkInventory(state.overflowLoot)
    snapshot.lootStash = deepCopy(state.lootStash or {})
    snapshot.equipped = deepCopy(state.equipped or {})
    snapshot.consumables = deepCopy(state.consumables or {})
    snapshot.nextExp = options.nextExp or snapshot.nextExp or nextExp(snapshot.level or 1)
    if options.stats ~= nil then
        snapshot.stats = deepCopy(options.stats)
    end
    local stats = snapshot.stats or {}
    for _, fieldName in ipairs({
        "displayedPower", "recommendedPower", "nextChapterRecommendedPower", "powerRatio",
        "headroomFloors", "difficultyLabel", "bossScore", "eliteScore", "estimatedEasyFloor",
    }) do
        if snapshot[fieldName] == nil and stats[fieldName] ~= nil then
            snapshot[fieldName] = deepCopy(stats[fieldName])
        end
    end
    snapshot.displayedPower = snapshot.displayedPower or stats.power or 0
    if options.itemPower ~= nil then
        for _, item in ipairs(snapshot.inventory or {}) do
            item.power = options.itemPower(item)
        end
    end
    return snapshot
end

---@param state table
---@param events table|nil
---@return table
function GameStateSchema.BuildSnapshotEvents(state, events)
    local result = {}
    for _, value in ipairs(type(events) == "table" and events or {}) do
        local eventType = type(value) == "table" and (value.type or value.kind) or nil
        if eventType ~= "story_gate" then
            result[#result + 1] = deepCopy(value)
        end
    end

    local gate = type(state) == "table" and state.pendingStoryGate or nil
    if type(gate) == "table" then
        result[#result + 1] = {
            type = "story_gate",
            kind = "story_gate",
            storyId = gate.storyId,
            chapter = gate.chapter,
            floor = gate.floor,
            phase = gate.phase,
            title = gate.title,
            lines = deepCopy(gate.lines),
            lineIndex = gate.lineIndex,
        }
    end
    return result
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
        or changes.overflowLoot ~= nil
        or changes.lootStash ~= nil
        or changes.equipped ~= nil
        or changes.consumables ~= nil
    if inventoryChanged and options.state ~= nil then
        deltaChanges.inventory = networkInventory(options.state.inventory or {})
        deltaChanges.overflowLoot = networkInventory(options.state.overflowLoot or {})
        deltaChanges.lootStash = deepCopy(options.state.lootStash or {})
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

local function validateBoundaryValue(value, schema, path)
    local ok, validationError = NetworkProtocol.ValidateValue(value, schema, path)
    if ok then return true, nil end
    return false, stateError(
        validationError and validationError.reason or "Boundary value is invalid",
        validationError and validationError.details and validationError.details.path or path)
end

local function validateBoundaryFields(container, schemas, path)
    for fieldName, schema in pairs(schemas) do
        if container[fieldName] ~= nil then
            local ok, validationError = validateBoundaryValue(
                container[fieldName], schema, path .. "." .. fieldName)
            if not ok then return false, validationError end
        end
    end
    return true, nil
end

local function validateNetworkLoadout(inventory, overflowLoot, equipped, path)
    local inventoryById = {}
    local allItemIds = {}
    for index, item in ipairs(inventory or {}) do
        local id = tostring(item.id)
        if allItemIds[id] then
            return false, stateError("Equipment ids must be unique", path .. ".inventory[" .. index .. "].id")
        end
        local definition = EquipmentCatalog.Get(item.equipmentId)
        if not definition then
            return false, stateError("Unknown equipment definition", path .. ".inventory[" .. index .. "].equipmentId")
        end
        allItemIds[id] = true
        inventoryById[id] = { definition = definition }
    end
    for index, item in ipairs(overflowLoot or {}) do
        local id = tostring(item.id)
        if allItemIds[id] then
            return false, stateError(
                "Equipment ids must be unique across inventory and temporary loot",
                path .. ".overflowLoot[" .. index .. "].id")
        end
        if not EquipmentCatalog.Get(item.equipmentId) then
            return false, stateError(
                "Unknown equipment definition",
                path .. ".overflowLoot[" .. index .. "].equipmentId")
        end
        allItemIds[id] = true
    end
    local equippedIds = {}
    for slot, itemId in pairs(equipped or {}) do
        local id = tostring(itemId)
        local entry = inventoryById[id]
        if not entry then
            return false, stateError("Equipped item is missing from inventory", path .. ".equipped." .. slot)
        end
        if entry.definition.slot ~= slot then
            return false, stateError("Equipped item does not match its slot", path .. ".equipped." .. slot)
        end
        if equippedIds[id] then
            return false, stateError("One item cannot occupy multiple slots", path .. ".equipped." .. slot)
        end
        equippedIds[id] = true
    end
    return true, nil
end

---@param snapshot table
---@return boolean
---@return table|nil
function GameStateSchema.ValidateSnapshot(snapshot)
    if type(snapshot) ~= "table" or snapshot.kind ~= "GameSnapshot" then
        return false, stateError("Invalid snapshot envelope", "$snapshot")
    end
    for fieldName in pairs(snapshot) do
        if not SNAPSHOT_FIELD_SET[fieldName] then
            return false, stateError(
                "Snapshot contains an unknown field",
                "$snapshot." .. tostring(fieldName)
            )
        end
    end
    if snapshot.schemaVersion ~= GameStateSchema.VERSION then
        return false, stateError("Unsupported snapshot schema version", "$snapshot.schemaVersion")
    end
    if type(snapshot.revision) ~= "number"
        or snapshot.revision < 0
        or snapshot.revision > LargeNumber.MAX_SAFE_INTEGER
        or snapshot.revision ~= math.floor(snapshot.revision)
    then
        return false, stateError("Invalid snapshot revision", "$snapshot.revision")
    end
    for _, fieldName in ipairs(SNAPSHOT_REQUIRED_FIELDS) do
        if snapshot[fieldName] == nil then
            return false, stateError("Snapshot is missing a required field", "$snapshot." .. fieldName)
        end
    end
    local envelopeOk, envelopeError = validateBoundaryFields(
        snapshot, SNAPSHOT_ENVELOPE_SCHEMAS, "$snapshot")
    if not envelopeOk then return false, envelopeError end
    local fieldsOk, fieldsError = validateBoundaryFields(snapshot, SNAPSHOT_VALUE_SCHEMAS, "$snapshot")
    if not fieldsOk then return false, fieldsError end
    local loadoutOk, loadoutError = validateNetworkLoadout(
        snapshot.inventory, snapshot.overflowLoot, snapshot.equipped, "$snapshot")
    if not loadoutOk then return false, loadoutError end
    if type(snapshot.playerNickname) ~= "string" or snapshot.playerNickname == "" or #snapshot.playerNickname > 128 then
        return false, stateError("Invalid snapshot player nickname", "$snapshot.playerNickname")
    end
    local gateOk, gateError = NetworkProtocol.ValidateValue(
        snapshot.pendingStoryGate,
        STORY_GATE_SCHEMA,
        "$snapshot.pendingStoryGate"
    )
    if not gateOk then
        return false, stateError(
            gateError and gateError.reason or "Invalid pending story gate",
            gateError and gateError.details and gateError.details.path or "$snapshot.pendingStoryGate"
        )
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
    for fieldName in pairs(delta) do
        if not DELTA_ENVELOPE_FIELD_SET[fieldName] then
            return false, stateError(
                "Delta contains an unknown envelope field",
                "$delta." .. tostring(fieldName)
            )
        end
    end
    if delta.schemaVersion ~= GameStateSchema.VERSION then
        return false, stateError("Unsupported delta schema version", "$delta.schemaVersion")
    end
    if type(delta.revision) ~= "number"
        or delta.revision < 0
        or delta.revision > LargeNumber.MAX_SAFE_INTEGER
        or delta.revision ~= math.floor(delta.revision)
    then
        return false, stateError("Invalid delta revision", "$delta.revision")
    end
    if type(delta.changes) ~= "table" then
        return false, stateError("Delta changes must be a table", "$delta.changes")
    end
    if type(delta.inventoryChanged) ~= "boolean" then
        return false, stateError("Delta inventoryChanged must be a boolean", "$delta.inventoryChanged")
    end
    local envelopeOk, envelopeError = validateBoundaryFields(
        delta, DELTA_ENVELOPE_SCHEMAS, "$delta")
    if not envelopeOk then return false, envelopeError end
    for fieldName in pairs(delta.changes) do
        if not DELTA_FIELD_SET[fieldName] then
            return false, stateError("Delta contains an unknown field", "$delta.changes." .. tostring(fieldName))
        end
    end
    local fieldsOk, fieldsError = validateBoundaryFields(
        delta.changes, SNAPSHOT_VALUE_SCHEMAS, "$delta.changes")
    if not fieldsOk then return false, fieldsError end
    if delta.inventoryChanged then
        if type(delta.changes.inventory) ~= "table"
            or type(delta.changes.overflowLoot) ~= "table"
            or type(delta.changes.equipped) ~= "table"
            or type(delta.changes.consumables) ~= "table"
        then
            return false, stateError(
                "Inventory deltas must include full inventory, equipment, and consumables",
                "$delta.changes"
            )
        end
        local loadoutOk, loadoutError = validateNetworkLoadout(
            delta.changes.inventory,
            delta.changes.overflowLoot,
            delta.changes.equipped,
            "$delta.changes")
        if not loadoutOk then return false, loadoutError end
    elseif delta.changes.inventory ~= nil
        or delta.changes.overflowLoot ~= nil
        or delta.changes.equipped ~= nil
        or delta.changes.consumables ~= nil
    then
        return false, stateError(
            "Inventory fields require inventoryChanged",
            "$delta.inventoryChanged")
    end
    local gateOk, gateError = NetworkProtocol.ValidateValue(
        delta.changes.pendingStoryGate,
        STORY_GATE_SCHEMA,
        "$delta.changes.pendingStoryGate"
    )
    if not gateOk then
        return false, stateError(
            gateError and gateError.reason or "Invalid pending story gate delta",
            gateError and gateError.details and gateError.details.path
                or "$delta.changes.pendingStoryGate"
        )
    end
    if delta.events ~= nil then
        local eventsOk, eventsReason = GameEventSchema.ValidateList(delta.events, "$delta.events")
        if not eventsOk then return false, stateError(eventsReason, "$delta.events") end
    end
    return true, nil
end

GameStateSchema.DeepCopy = deepCopy
GameStateSchema.NextExp = nextExp
GameStateSchema.NormalizeMarketListings = normalizeMarketListings
GameStateSchema.NormalizeAppliedGmCommandIds = normalizeAppliedGmCommandIds

return GameStateSchema
