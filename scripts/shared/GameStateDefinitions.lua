local EquipmentCatalog = require("shared.EquipmentCatalog")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")
local Contracts = require("shared.GameStateContracts")

local GameStateSchema = {
    SLOTS = Contracts.SLOTS,
    RARITIES = Contracts.RARITIES,
    SET_IDS = Contracts.SET_IDS,
}
local SLOT_SET = {}
for _, slot in ipairs(Contracts.SLOTS) do SLOT_SET[slot] = true end

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
        kind = { type = "string", enum = { "normal", "elite", "boss", "chapterBoss", "chest", "merchant", "randomEvent" } },
        eventType = { type = "string", enum = { "monster", "elite", "boss", "chest", "merchant", "randomEvent" } },
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
        marketStandardValue = CURRENCY_SCHEMA,
        marketMinimumPrice = CURRENCY_SCHEMA,
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

local DAILY_VIP_SCHEMA = {
    type = "object", allowUnknown = false,
    required = { "signInDay", "adDay" },
    fields = {
        signInDay = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
        adDay = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
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

local PENDING_EVENT_SCHEMA = {
    type = "object", allowUnknown = false,
    required = { "eventId", "eventType", "floor", "room", "encounterId", "createdAt", "expiresAt", "actions" },
    fields = {
        eventId = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" },
        eventType = { type = "string", enum = { "chest", "merchant", "randomEvent" } },
        floor = { type = "integer", min = 1, max = 1000000000 },
        room = { type = "integer", min = 1, max = 10 },
        encounterId = { type = "string", minLength = 1, maxLength = 96 },
        createdAt = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
        expiresAt = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
        actions = {
            type = "array", minLength = 1, maxLength = 4,
            items = { type = "string", enum = { "open", "buy", "accept", "skip" } },
        },
        title = { type = "string", minLength = 1, maxLength = 64 },
        description = { type = "string", minLength = 1, maxLength = 256 },
        goldCost = CURRENCY_SCHEMA,
        fragmentsReward = { type = "integer", min = 0, max = 1000000000 },
        variant = { type = "integer", min = 1, max = 8 },
    },
    validate = function(value)
        if value.expiresAt < value.createdAt then
            return false, "pendingEvent expiresAt precedes createdAt"
        end
        local hasSkip = false
        for _, action in ipairs(value.actions) do
            if action == "skip" then hasSkip = true end
        end
        if not hasSkip then
            return false, "pendingEvent must always allow skip"
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


local function validateAppliedGmCommandIds(value)
    local seen = {}
    for _, commandId in ipairs(value) do
        if seen[commandId] then return false, "Applied GM command ids must be unique" end
        seen[commandId] = true
    end
    return true
end

-- 全服邮件送达标记：{ batchId = true }。batchId 上限 128 字符，最多保留 512 条。
local function validateReceivedBroadcasts(value)
    if type(value) ~= "table" then return false, "Received broadcasts must be an object" end
    local count = 0
    for batchId, flag in pairs(value) do
        if type(batchId) ~= "string" or #batchId < 1 or #batchId > 128 then
            return false, "Broadcast batch id must be a string of length 1..128"
        end
        if flag ~= true then return false, "Broadcast receipt flag must be true" end
        count = count + 1
        if count > 512 then return false, "Received broadcast receipts exceed limit" end
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
            minimumPrice = CURRENCY_SCHEMA,
            minimumPriceVersion = { type = "integer", min = 1, max = 1000 },
            tradeableChanceUnits = { type = "integer", min = 0, max = 10000 },
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


local QUEST_COUNTER_SCHEMA = {
    type = "integer",
    min = 0,
    max = LargeNumber.MAX_SAFE_INTEGER,
}

-- 任务系统存档：新手/每日/成就三块 + 累计计数器。
local QUESTS_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "newbie", "daily", "achievement", "questStats" },
    fields = {
        newbie = {
            type = "object",
            allowUnknown = false,
            required = { "claimed" },
            fields = {
                claimed = { type = "object", allowUnknown = true },
            },
        },
        daily = {
            type = "object",
            allowUnknown = false,
            required = { "dayKey", "progress", "claimed" },
            fields = {
                dayKey = { type = "integer", min = 0, max = LargeNumber.MAX_SAFE_INTEGER },
                progress = {
                    type = "object",
                    allowUnknown = false,
                    fields = {
                        monster_kill = QUEST_COUNTER_SCHEMA,
                        elite_kill = QUEST_COUNTER_SCHEMA,
                        boss_kill = QUEST_COUNTER_SCHEMA,
                        item_pickup = QUEST_COUNTER_SCHEMA,
                        chest_open = QUEST_COUNTER_SCHEMA,
                        decompose = QUEST_COUNTER_SCHEMA,
                        sell = QUEST_COUNTER_SCHEMA,
                        floor_advance = QUEST_COUNTER_SCHEMA,
                    },
                },
                claimed = { type = "object", allowUnknown = true },
            },
        },
        achievement = {
            type = "object",
            allowUnknown = false,
            required = { "claimed" },
            fields = {
                claimed = { type = "object", allowUnknown = true },
            },
        },
        questStats = {
            type = "object",
            allowUnknown = false,
            fields = {
                monster_kill = QUEST_COUNTER_SCHEMA,
                elite_kill = QUEST_COUNTER_SCHEMA,
                boss_kill = QUEST_COUNTER_SCHEMA,
                item_pickup = QUEST_COUNTER_SCHEMA,
                chest_open = QUEST_COUNTER_SCHEMA,
                decompose = QUEST_COUNTER_SCHEMA,
                sell = QUEST_COUNTER_SCHEMA,
                floor_advance = QUEST_COUNTER_SCHEMA,
            },
        },
    },
}


local Definitions = {
    CURRENCY_SCHEMA = CURRENCY_SCHEMA,
    BIG_NUMBER_SCHEMA = BIG_NUMBER_SCHEMA,
    FINITE_NUMBER_SCHEMA = FINITE_NUMBER_SCHEMA,
    NONNEGATIVE_NUMBER_SCHEMA = NONNEGATIVE_NUMBER_SCHEMA,
    MAGNITUDE_SCHEMA = MAGNITUDE_SCHEMA,
    SAFE_INTEGER_SCHEMA = SAFE_INTEGER_SCHEMA,
    NONNEGATIVE_RATIO_SCHEMA = NONNEGATIVE_RATIO_SCHEMA,
    FLOOR_ROUTE_SCHEMA = FLOOR_ROUTE_SCHEMA,
    ITEM_SCHEMA = ITEM_SCHEMA,
    INVENTORY_POLICY_SCHEMA = INVENTORY_POLICY_SCHEMA,
    CURRENT_MONSTER_SCHEMA = CURRENT_MONSTER_SCHEMA,
    AUTOMATION_POLICY_SCHEMA = AUTOMATION_POLICY_SCHEMA,
    DAILY_VIP_SCHEMA = DAILY_VIP_SCHEMA,
    REWARD_PITY_SCHEMA = REWARD_PITY_SCHEMA,
    STORY_PROGRESS_SCHEMA = STORY_PROGRESS_SCHEMA,
    STORY_GATE_SCHEMA = STORY_GATE_SCHEMA,
    PENDING_EVENT_SCHEMA = PENDING_EVENT_SCHEMA,
    PENDING_EQUIP_SCHEMA = PENDING_EQUIP_SCHEMA,
    QUESTS_SCHEMA = QUESTS_SCHEMA,
    LOADOUT_BACKUP_SCHEMA = LOADOUT_BACKUP_SCHEMA,
    SET_PROGRESS_SCHEMA = SET_PROGRESS_SCHEMA,
    STATS_SCHEMA = STATS_SCHEMA,
    MARKET_LISTINGS_SCHEMA = MARKET_LISTINGS_SCHEMA,
    ValidateUniqueFloors = validateUniqueFloors,
    ValidateLootStash = validateLootStash,
    ValidateEquipped = validateEquipped,
    ValidateConsumables = validateConsumables,
    ValidateAcknowledgements = validateAcknowledgements,
    ValidateEquipmentCollection = validateEquipmentCollection,
    ValidateAppliedGmCommandIds = validateAppliedGmCommandIds,
    ValidateReceivedBroadcasts = validateReceivedBroadcasts,
}

return Definitions
