local ErrorCodes = require("shared.ErrorCodes")
local NetworkProtocol = require("shared.NetworkProtocol")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local RarityCatalog = require("shared.RarityCatalog")
local GameEventSchema = require("shared.GameEventSchema")
local LargeNumber = require("shared.LargeNumber")
local Contracts = require("shared.GameStateContracts")
local Policy = require("shared.GameStatePolicy")
local Definitions = require("shared.GameStateDefinitions")
local Boundary = require("shared.GameStateBoundarySchemas")
local Progression = require("shared.GameProgression")
local TableUtils = require("shared.TableUtils")

local GameStateSchema = {
    VERSION = Contracts.VERSION,
    INVENTORY_CAP = Policy.INVENTORY_CAP,
}
local SNAPSHOT_FIELDS = Contracts.SNAPSHOT_FIELDS
local DELTA_FIELD_SET = Contracts.DELTA_FIELD_SET
local SNAPSHOT_FIELD_SET = Contracts.SNAPSHOT_FIELD_SET
local DELTA_ENVELOPE_FIELD_SET = Contracts.DELTA_ENVELOPE_FIELD_SET
local SNAPSHOT_VALUE_SCHEMAS = Boundary.SNAPSHOT_VALUE_SCHEMAS
local SNAPSHOT_ENVELOPE_SCHEMAS = Boundary.SNAPSHOT_ENVELOPE_SCHEMAS
local DELTA_ENVELOPE_SCHEMAS = Boundary.DELTA_ENVELOPE_SCHEMAS
local SNAPSHOT_REQUIRED_FIELDS = Boundary.SNAPSHOT_REQUIRED_FIELDS
local STORY_GATE_SCHEMA = Definitions.STORY_GATE_SCHEMA
local deepCopy = TableUtils.DeepCopy
local copyArray = TableUtils.CopyArray
local nextExp = Progression.NextExp

local function currentTime(now)
    if type(now) == "number" then return math.max(0, math.floor(now)) end
    if type(os.time) == "function" then return math.max(0, math.floor(os.time())) end
    return 0
end

---@param events table|nil
---@return table|nil
---@return string|nil
local function canonicalizeGameEvents(events)
    local result = {}
    for _, source in ipairs(type(events) == "table" and events or {}) do
        if type(source) ~= "table" then
            return nil, "game event must be a table"
        end
        local value = deepCopy(source)
        local eventType = value.type or value.kind
        if type(eventType) ~= "string" or eventType == "" then
            return nil, "game event is missing its type"
        end
        value.type = eventType
        value.kind = value.kind or eventType

        -- 兼容领域事件旧字段，并在网络边界补齐当前协议字段。
        if eventType == "player_damaged" or eventType == "player_healed" then
            value.amount = value.amount or value.damage
            value.amountBig = value.amountBig or value.damageBig
            value.hp = value.hp or value.playerHp
            value.maxHp = value.maxHp or value.playerMaxHp
            value.hpBig = value.hpBig or value.playerHpBig
            value.maxHpBig = value.maxHpBig or value.playerMaxHpBig
        elseif eventType == "player_attack_hit" then
            value.amount = value.amount or value.damage
            value.amountBig = value.amountBig or value.damageBig
            value.hitIndex = value.hitIndex or value.sequenceHitIndex
        elseif eventType == "battle_started" then
            if type(value.monster) == "string" and value.name == nil then
                value.name = value.monster
            end
            if type(value.monster) ~= "table" then value.monster = nil end
        elseif eventType == "monster_spawned" then
            local monster = type(value.monster) == "table" and value.monster or {}
            value.floor = value.floor or monster.floor
            value.room = value.room or monster.room
            value.kind = value.encounterKind or monster.encounterKind or monster.kind or "normal"
            value.hp = value.hp or value.monsterHp or monster.hp
            value.maxHp = value.maxHp or value.monsterMaxHp or monster.maxHp
            value.hpBig = value.hpBig or value.monsterHpBig or monster.hpBig
            value.maxHpBig = value.maxHpBig or value.monsterMaxHpBig or monster.maxHpBig
            if type(value.monster) ~= "table" then value.monster = nil end
        elseif eventType == "loot_dropped" then
            value.rarity = value.rarity or "common"
            value.icon = value.icon or value.iconPath or value.itemIcon or ""
        elseif eventType == "loot_settled" then
            value.outcome = value.outcome or value.destination
        end
        result[#result + 1] = value
    end
    local valid, reason = GameEventSchema.ValidateList(result, "$events")
    if not valid then return nil, reason end
    return result, nil
end

local function stateError(reason, path)
    return ErrorCodes.Make(ErrorCodes.INVALID_STATE, reason, path and { path = path } or nil)
end

local function networkItem(item)
    return {
        id = item.id,
        equipmentId = item.equipmentId,
        level = item.level,
        legacyLevel = item.legacyLevel,
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
        marketStandardValue = LargeNumber.IsLargeNumber(item.marketStandardValue)
            and LargeNumber.Normalize(item.marketStandardValue) or nil,
        marketMinimumPrice = LargeNumber.IsLargeNumber(item.marketMinimumPrice)
            and LargeNumber.Normalize(item.marketMinimumPrice) or nil,
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


---@param claims table
---@return table
-- Historical campaign entitlements remain on the server. The current reward
-- popup receives its exact IDs in events; sending all 120 old offers on every
-- update can exceed the 60 KiB envelope. Keep other sources' existing wire data.
local function NetworkRewardClaims(claims)
    local result = deepCopy(claims)
    result.receipts = {} -- Server-only idempotency history; do not inflate snapshots.
    local pending, latestCampaign = {}, nil
    for _, offer in ipairs(result.pending or {}) do
        if offer.source == "campaign" then latestCampaign = offer
        else pending[#pending + 1] = offer end
    end
    if latestCampaign then pending[#pending + 1] = latestCampaign end
    result.pending = pending
    return result
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
    if snapshot.rewardClaims then snapshot.rewardClaims = NetworkRewardClaims(snapshot.rewardClaims) end
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
        for index, item in ipairs(snapshot.inventory or {}) do
            -- Power evaluators may cache values on their input. Keep those
            -- private fields on domain items, outside the network snapshot.
            item.power = options.itemPower(state.inventory[index])
        end
    end
    if options.itemMarketQuote ~= nil then
        for index, item in ipairs(snapshot.inventory or {}) do
            local quote = options.itemMarketQuote(
                (state.inventory or {})[index] or item
            )
            if type(quote) == "table" then
                item.marketStandardValue = quote.standardValue
                item.marketMinimumPrice = quote.minimumPrice
            end
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
    if deltaChanges.rewardClaims then deltaChanges.rewardClaims = NetworkRewardClaims(deltaChanges.rewardClaims) end
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


local Wire = {
    BuildSnapshot = GameStateSchema.BuildSnapshot,
    BuildSnapshotEvents = GameStateSchema.BuildSnapshotEvents,
    BuildDelta = GameStateSchema.BuildDelta,
    CanonicalizeGameEvents = canonicalizeGameEvents,
    ValidateSnapshot = GameStateSchema.ValidateSnapshot,
    ValidateDelta = GameStateSchema.ValidateDelta,
}

return Wire
