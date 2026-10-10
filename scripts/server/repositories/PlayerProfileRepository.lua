local ServerCloudGateway = require("server.dao.ServerCloudGateway")
local StateNormalizer = require("server.domain.StateNormalizer")
local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")

---@class PlayerProfileRepository
---@field gateway table<string, any>
---@field clock fun(): integer
---@field listIds table<integer, table>
---@field itemIds table<integer, table>
local PlayerProfileRepository = {}
PlayerProfileRepository.__index = PlayerProfileRepository

PlayerProfileRepository.Keys = {
    PROFILE = "abyss_profile",
    SCHEMA_VERSION = "abyss_schema_version",
    REVISION = "abyss_revision",
    UPDATED_AT = "abyss_updated_at",
    FLOOR = "abyss_floor",
    MAX_FLOOR = "abyss_max_floor",
    LEVEL = "abyss_level",
    POWER = "abyss_power",
    POWER_VALUE = "abyss_power_value",
    GOLD_HIGH = "abyss_gold_high",
    GOLD_MID = "abyss_gold_mid",
    GOLD_LOW = "abyss_gold_low",
    FRAGMENTS_HIGH = "abyss_fragments_high",
    FRAGMENTS_MID = "abyss_fragments_mid",
    FRAGMENTS_LOW = "abyss_fragments_low",
    BAN = "abyss_ban",
    INVENTORY = "abyss_inventory",
    CONSUMABLE = "abyss_consumable",
    HEALTH_POTION = "abyss_health_potion",
    ADMIN_AUDIT = "abyss_admin_audit",
    GM_COMMAND = "abyss_gm_command",
    PERSONAL_MAIL = "abyss_personal_mail_v2",
    PLAYER_ENTITLEMENT = "abyss_player_entitlement_v1",
    GM_RESULT = "abyss_gm_result",
}

local LOAD_KEYS = {
    PlayerProfileRepository.Keys.PROFILE,
    PlayerProfileRepository.Keys.SCHEMA_VERSION,
    PlayerProfileRepository.Keys.REVISION,
    PlayerProfileRepository.Keys.UPDATED_AT,
    PlayerProfileRepository.Keys.GOLD_HIGH,
    PlayerProfileRepository.Keys.GOLD_MID,
    PlayerProfileRepository.Keys.GOLD_LOW,
    PlayerProfileRepository.Keys.FRAGMENTS_HIGH,
    PlayerProfileRepository.Keys.FRAGMENTS_MID,
    PlayerProfileRepository.Keys.FRAGMENTS_LOW,
    PlayerProfileRepository.Keys.BAN,
}

local function Result(ok, data, code, reason)
    return {
        ok = ok == true,
        data = data or {},
        code = code or (ok and 0 or -1),
        reason = tostring(reason or ""),
    }
end

local function Integer(value, fallback)
    if type(value) ~= "number" or value ~= value then return fallback end
    return math.floor(value)
end

local function ScorePresence(scores, keys)
    local present = 0
    for _, key in ipairs(keys) do
        if scores[key] ~= nil then present = present + 1 end
    end
    return tostring(present) .. "/" .. tostring(#keys)
end

local function ReadLargeValue(scores, highKey, midKey, lowKey)
    return LargeNumber.FromSegments(
        Integer(scores[highKey], 0),
        Integer(scores[midKey], 0),
        Integer(scores[lowKey], 0)
    )
end

local function AppendLargeValueOperations(operations, operation, userId, highKey, midKey, lowKey, value)
    value = LargeNumber.Normalize(value)
    operations[#operations + 1] = { kind = operation.SCORE_SET_INT, userId = userId, key = highKey, value = value.high }
    operations[#operations + 1] = { kind = operation.SCORE_SET_INT, userId = userId, key = midKey, value = value.mid }
    operations[#operations + 1] = { kind = operation.SCORE_SET_INT, userId = userId, key = lowKey, value = value.low }
end

local function ListId(row)
    return Integer(row.list_id or row.listId or row.id, nil)
end

local function ItemId(row)
    return Integer(row.item_id or row.itemId or row.id, nil)
end

local function PrintInventoryDiagnostics(userId, inventoryRows, normalizedInventory)
    local normalizedCount = #(normalizedInventory or {})
    print("[ProfileDiag] uid=" .. tostring(userId)
        .. " inventoryRows=" .. tostring(#inventoryRows)
        .. " normalizedInventory=" .. tostring(normalizedCount)
        .. " cap=" .. tostring(Catalog.INVENTORY_CAP))
    for index, row in ipairs(inventoryRows) do
        local value = row.value
        local definition = type(value) == "table" and Catalog.ResolveEquipment(value) or nil
        local reason = definition and (index > Catalog.INVENTORY_CAP and "overflow" or "normalized") or "unresolved"
        print("[ProfileDiag] uid=" .. tostring(userId)
            .. " inventory[" .. tostring(index) .. "]"
            .. " listId=" .. tostring(ListId(row))
            .. " logicalId=" .. tostring(type(value) == "table" and value.id or nil)
            .. " equipmentId=" .. tostring(type(value) == "table" and value.equipmentId or nil)
            .. " name=" .. tostring(type(value) == "table" and value.name or nil)
            .. " slot=" .. tostring(type(value) == "table" and value.slot or nil)
            .. " setId=" .. tostring(type(value) == "table" and value.setId or nil)
            .. " rarity=" .. tostring(type(value) == "table" and value.rarity or nil)
            .. " resolution=" .. reason)
    end
end

local function PrintProfileSummary(userId, profile, scores, iscores, inventoryRows, itemRows)
    local profileType = type(profile)
    print("[ProfileDiag] uid=" .. tostring(userId)
        .. " profileType=" .. profileType
        .. " profileSchema=" .. tostring(profileType == "table" and profile.schemaVersion or nil)
        .. " scoreSchema=" .. tostring(iscores[PlayerProfileRepository.Keys.SCHEMA_VERSION])
        .. " revision=" .. tostring(iscores[PlayerProfileRepository.Keys.REVISION])
        .. " inventoryRows=" .. tostring(#inventoryRows)
        .. " itemRows=" .. tostring(#itemRows)
        .. " goldSegments=" .. ScorePresence(iscores, {
            PlayerProfileRepository.Keys.GOLD_HIGH,
            PlayerProfileRepository.Keys.GOLD_MID,
            PlayerProfileRepository.Keys.GOLD_LOW,
        })
        .. " fragmentSegments=" .. ScorePresence(iscores, {
            PlayerProfileRepository.Keys.FRAGMENTS_HIGH,
            PlayerProfileRepository.Keys.FRAGMENTS_MID,
            PlayerProfileRepository.Keys.FRAGMENTS_LOW,
        })
        .. " hasInventoryPolicy=" .. tostring(profileType == "table" and type(profile.inventoryPolicy) == "table")
        .. " hasCurrentMonster=" .. tostring(profileType == "table" and type(profile.currentMonster) == "table"))
end

local function ProfileCore(state)
    local persisted = StateNormalizer.ToPersisted(state)
    persisted.inventory = nil
    persisted.gold = nil
    persisted.fragments = nil
    persisted.consumables = nil
    return persisted
end

local function PersistedInventory(state)
    return StateNormalizer.ToPersisted(state).inventory
end

local function IndexInventory(items)
    local indexed = {}
    for _, item in ipairs(items or {}) do indexed[item.id] = item end
    return indexed
end

---@return PlayerProfileRepository
function PlayerProfileRepository.New(options)
    options = options or {}
    return setmetatable({
        gateway = options.gateway or ServerCloudGateway.New(),
        clock = options.clock or os.time,
        listIds = {},
        itemIds = {},
    }, PlayerProfileRepository)
end

PlayerProfileRepository.new = PlayerProfileRepository.New

function PlayerProfileRepository:_joinReads(userId, onComplete)
    local remaining = 3
    local finished = false
    local values = {}

    local function receive(name)
        return function(result)
            if finished then return end
            if not result.ok then
                finished = true
                onComplete(Result(false, { source = name }, result.code, result.reason))
                return
            end
            values[name] = result.data
            remaining = remaining - 1
            if remaining == 0 then
                finished = true
                onComplete(Result(true, values))
            end
        end
    end

    self.gateway:BatchGet(userId, LOAD_KEYS, receive("score"))
    self.gateway:ListGet(userId, self.Keys.INVENTORY, receive("inventory"))
    self.gateway:ItemGet(userId, self.Keys.CONSUMABLE, receive("items"))
end

function PlayerProfileRepository:Load(userId, onComplete)
    self:_joinReads(userId, function(result)
        if not result.ok then onComplete(result); return end

        local scores = result.data.score.scores or {}
        local iscores = result.data.score.iscores or {}
        local profile = scores[self.Keys.PROFILE]
        local inventoryRows = result.data.inventory.items or {}
        local itemRows = result.data.items.items or {}
        PrintProfileSummary(userId, profile, scores, iscores, inventoryRows, itemRows)

        if profile == nil then
            local hasOrphanedData = #inventoryRows > 0 or #itemRows > 0
                or iscores[self.Keys.GOLD_HIGH] ~= nil
                or iscores[self.Keys.GOLD_MID] ~= nil
                or iscores[self.Keys.GOLD_LOW] ~= nil
                or iscores[self.Keys.FRAGMENTS_HIGH] ~= nil
                or iscores[self.Keys.FRAGMENTS_MID] ~= nil
                or iscores[self.Keys.FRAGMENTS_LOW] ~= nil
                or iscores[self.Keys.REVISION] ~= nil
            if hasOrphanedData then
                onComplete(Result(false, {}, "ORPHANED_PROFILE", "profile header is missing while domain data exists"))
            else
                onComplete(Result(true, { missing = true, ban = scores[self.Keys.BAN] }))
            end
            return
        end
        if type(profile) ~= "table" then
            onComplete(Result(false, {}, "CORRUPT_PROFILE", "abyss_profile is not a table"))
            return
        end

        local raw = TableUtils.DeepCopy(profile)
        raw.schemaVersion = iscores[self.Keys.SCHEMA_VERSION] or raw.schemaVersion
        raw.revision = iscores[self.Keys.REVISION] or raw.revision
        raw.updatedAt = iscores[self.Keys.UPDATED_AT] or raw.updatedAt
        raw.gold = ReadLargeValue(iscores, self.Keys.GOLD_HIGH, self.Keys.GOLD_MID, self.Keys.GOLD_LOW)
        raw.fragments = ReadLargeValue(iscores, self.Keys.FRAGMENTS_HIGH, self.Keys.FRAGMENTS_MID, self.Keys.FRAGMENTS_LOW)
        raw.inventory = {}

        local listMap = {}
        for _, row in ipairs(inventoryRows) do
            local value = row.value
            local listId = ListId(row)
            if type(value) ~= "table" or type(value.id) ~= "string" or not listId then
                onComplete(Result(false, {}, "CORRUPT_INVENTORY", "inventory row is missing logical id or list id"))
                return
            end
            if listMap[value.id] then
                onComplete(Result(false, {}, "DUPLICATE_ITEM_ID", "duplicate logical equipment id in cloud list"))
                return
            end
            raw.inventory[#raw.inventory + 1] = TableUtils.DeepCopy(value)
            listMap[value.id] = listId
        end

        raw.consumables = { healthPotion = 0 }
        local itemMap = {}
        for _, row in ipairs(itemRows) do
            local key = row.key
            local count = math.max(0, Integer(row.count, 0))
            local cloudItemId = ItemId(row)
            if key == self.Keys.HEALTH_POTION or row.name == self.Keys.HEALTH_POTION then
                raw.consumables.healthPotion = raw.consumables.healthPotion + count
            end
            if cloudItemId then itemMap[row.name or key or tostring(cloudItemId)] = cloudItemId end
        end

        local rawValid, rawIssue = StateNormalizer.ValidateRawV5BigNumbers(raw)
        if not rawValid then
            local code = rawIssue and rawIssue.scope == "inventory"
                and "CORRUPT_INVENTORY" or "CORRUPT_PROFILE"
            local path = rawIssue and rawIssue.path or "$profile"
            local reason = rawIssue and rawIssue.reason or "invalid V5 BigNumber state"
            onComplete(Result(false, {}, code, path .. ": " .. tostring(reason)))
            return
        end

        print("[ProfileDiag] uid=" .. tostring(userId)
            .. " normalizeBegin"
            .. " level=" .. tostring(raw.level)
            .. " exp=" .. tostring(raw.exp)
            .. " floor=" .. tostring(raw.floor)
            .. " maxFloor=" .. tostring(raw.maxFloor)
            .. " inventoryRows=" .. tostring(#raw.inventory))
        local normalizeOk, stateOrError = pcall(StateNormalizer.Normalize, raw, self.clock())
        if not normalizeOk then
            onComplete(Result(false, {}, "CORRUPT_PROFILE",
                "profile normalization failed: " .. tostring(stateOrError)))
            return
        end
        local state = stateOrError
        print("[ProfileDiag] uid=" .. tostring(userId)
            .. " normalizeComplete"
            .. " level=" .. tostring(state.level)
            .. " exp=" .. tostring(state.exp)
            .. " floor=" .. tostring(state.floor))
        local normalizedInventory = state.inventory or {}
        if #normalizedInventory ~= #inventoryRows then
            PrintInventoryDiagnostics(userId, inventoryRows, normalizedInventory)
            onComplete(Result(false, {}, "CORRUPT_INVENTORY", "inventory rows could not be normalized without data loss"))
            return
        end
        local normalizedListMap = {}
        for index, row in ipairs(inventoryRows) do
            local normalizedItem = normalizedInventory[index]
            if normalizedItem then
                normalizedListMap[normalizedItem.id] = ListId(row)
            end
        end
        self.listIds[userId] = normalizedListMap
        self.itemIds[userId] = itemMap
        onComplete(Result(true, {
            missing = false,
            state = state,
            ban = scores[self.Keys.BAN],
            itemRows = TableUtils.DeepCopy(itemRows),
        }))
    end)
end

function PlayerProfileRepository:_buildOperations(userId, oldState, newState)
    local operation = self.gateway.CommitOperation
    local powerValue = newState.stats and (newState.stats.displayedPower or newState.stats.power) or 0
    local powerBig = BigNumber.Normalize(powerValue)
    local powerNumber = BigNumber.ToNumber(powerBig)
    ---@type table
    local powerProjection = {
        value = BigNumber.ToScientificString(powerBig, 12),
        mantissa = tonumber(powerBig.mantissa) or 0,
        exponent = tonumber(powerBig.exponent) or 0,
        high = powerNumber and select(1, LargeNumber.Split(powerNumber)) or 0,
        low = powerNumber and select(2, LargeNumber.Split(powerNumber)) or 0,
    }
    local operations = {
        { kind = operation.SCORE_SET, userId = userId, key = self.Keys.PROFILE, value = ProfileCore(newState) },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.SCHEMA_VERSION, value = newState.schemaVersion },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.REVISION, value = newState.revision },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.UPDATED_AT, value = newState.updatedAt },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.FLOOR, value = newState.floor },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.MAX_FLOOR, value = newState.maxFloor },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.LEVEL, value = newState.level },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.POWER, value = BigNumber.RankScore(powerBig, LargeNumber.MAX_CLOUD_INTEGER) },
        { kind = operation.SCORE_SET, userId = userId, key = self.Keys.POWER_VALUE, value = powerProjection },
    }
    AppendLargeValueOperations(operations, operation, userId, self.Keys.GOLD_HIGH, self.Keys.GOLD_MID, self.Keys.GOLD_LOW, newState.gold)
    AppendLargeValueOperations(operations, operation, userId, self.Keys.FRAGMENTS_HIGH, self.Keys.FRAGMENTS_MID, self.Keys.FRAGMENTS_LOW, newState.fragments)

    local oldItems = IndexInventory(oldState and PersistedInventory(oldState) or {})
    local newItems = IndexInventory(PersistedInventory(newState))
    local listMap = self.listIds[userId] or {}

    for itemId, item in pairs(newItems) do
        local previous = oldItems[itemId]
        if not previous then
            operations[#operations + 1] = {
                kind = operation.LIST_ADD,
                userId = userId,
                key = self.Keys.INVENTORY,
                value = item,
                resultKey = itemId,
            }
        elseif not TableUtils.DeepEqual(previous, item) then
            local listId = listMap[itemId]
            if not listId then return nil, "missing cloud list id for modified item " .. itemId end
            operations[#operations + 1] = { kind = operation.LIST_MODIFY, listId = listId, value = item }
        end
    end
    for itemId in pairs(oldItems) do
        if not newItems[itemId] then
            local listId = listMap[itemId]
            if not listId then return nil, "missing cloud list id for deleted item " .. itemId end
            operations[#operations + 1] = { kind = operation.LIST_DELETE, listId = listId }
        end
    end
    return operations
end

function PlayerProfileRepository:Commit(userId, oldState, newState, description, onComplete, extraOperations)
    if oldState and newState.revision <= oldState.revision then
        onComplete(Result(false, {}, "REVISION_MISMATCH", "new state revision must advance"))
        return
    end
    local operations, buildReason = self:_buildOperations(userId, oldState, newState)
    if not operations then
        onComplete(Result(false, {}, "PERSISTENCE_MAP_MISSING", buildReason))
        return
    end
    -- 领域层附带的跨域操作（市场账本、对方信箱）并入同一个 BatchCommit，
    -- 使"扣款 + 摘牌 + 对方入信箱"要么全部生效、要么全部回滚。
    for _, extraOperation in ipairs(extraOperations or {}) do
        operations[#operations + 1] = extraOperation
    end
    if #operations > 1000 then
        onComplete(Result(false, {}, "BATCH_TOO_LARGE", "transaction exceeds serverCloud operation limit"))
        return
    end

    self.gateway:BatchCommit(description or "abyss profile mutation", operations, function(result)
        if not result.ok then onComplete(result); return end
        local map = self.listIds[userId] or {}
        local oldIndex = IndexInventory(oldState and oldState.inventory or {})
        local newIndex = IndexInventory(newState.inventory or {})
        for itemId in pairs(oldIndex) do
            if not newIndex[itemId] then map[itemId] = nil end
        end
        for itemId, listId in pairs(result.data.listIds or {}) do map[itemId] = listId end
        self.listIds[userId] = map
        onComplete(Result(true, { state = newState, operationCount = #operations }))
    end)
end

function PlayerProfileRepository:Create(userId, initialState, onComplete)
    local state = StateNormalizer.Normalize(initialState, self.clock())
    state.revision = 1
    state.updatedAt = self.clock()
    state.lastActiveAt = state.updatedAt
    self.listIds[userId] = {}
    self:Commit(userId, nil, state, "abyss initial profile", function(result)
        if not result.ok then onComplete(result); return end
        local potionCount = state.consumables.healthPotion or 0
        if potionCount <= 0 then onComplete(result); return end
        self.gateway:ItemAdd(
            userId,
            self.Keys.CONSUMABLE,
            self.Keys.HEALTH_POTION,
            potionCount,
            { category = "consumable", displayName = "生命药水" },
            nil,
            nil,
            function(itemResult)
                if itemResult.ok then
                    self.itemIds[userId] = { [self.Keys.HEALTH_POTION] = itemResult.data.itemId }
                    result.data.itemProjection = "created"
                else
                    state.consumables.healthPotion = 0
                    result.data.warning = {
                        code = itemResult.code,
                        reason = itemResult.reason,
                        source = "serverCloud.item",
                    }
                end
                result.data.state = state
                onComplete(result)
            end
        )
    end)
end

function PlayerProfileRepository:SetHealthPotionCount(userId, targetCount, onComplete)
    targetCount = math.max(0, Integer(targetCount, 0))

    local function inspect(resultCode, resultReason)
        self.gateway:ItemGet(userId, self.Keys.CONSUMABLE, function(inspectResult)
            if not inspectResult.ok then
                onComplete(Result(false, {}, resultCode, resultReason))
                return
            end
            local actualCount = 0
            local itemMap = {}
            for _, row in ipairs(inspectResult.data.items or {}) do
                local key = row.key
                local name = row.name
                local itemId = ItemId(row)
                if key == self.Keys.HEALTH_POTION or name == self.Keys.HEALTH_POTION then
                    actualCount = actualCount + math.max(0, Integer(row.count, 0))
                    if itemId then itemMap[self.Keys.HEALTH_POTION] = itemId end
                end
            end
            self.itemIds[userId] = itemMap
            if resultCode then
                onComplete(Result(false, { actualCount = actualCount }, resultCode, resultReason))
            elseif actualCount ~= targetCount then
                onComplete(Result(
                    false,
                    { actualCount = actualCount },
                    "CONSUMABLE_COUNT_MISMATCH",
                    "health potion count did not reach the requested value"
                ))
            else
                onComplete(Result(true, { actualCount = actualCount }))
            end
        end)
    end

    self.gateway:ItemGet(userId, self.Keys.CONSUMABLE, function(result)
        if not result.ok then onComplete(result); return end

        local rows = {}
        local currentCount = 0
        for _, row in ipairs(result.data.items or {}) do
            local key = row.key
            local name = row.name
            if key == self.Keys.HEALTH_POTION or name == self.Keys.HEALTH_POTION then
                local count = math.max(0, Integer(row.count, 0))
                local itemId = ItemId(row)
                if count > 0 and itemId then
                    rows[#rows + 1] = { itemId = itemId, count = count }
                    currentCount = currentCount + count
                end
            end
        end

        if currentCount == targetCount then inspect(); return end
        if currentCount < targetCount then
            self.gateway:ItemAdd(
                userId,
                self.Keys.CONSUMABLE,
                self.Keys.HEALTH_POTION,
                targetCount - currentCount,
                { category = "consumable", displayName = "生命药水" },
                nil,
                nil,
                function(addResult)
                    if not addResult.ok then
                        inspect(addResult.code, addResult.reason)
                        return
                    end
                    inspect()
                end
            )
            return
        end

        local remaining = currentCount - targetCount
        local index = 1
        local function consumeNext()
            if remaining <= 0 then inspect(); return end
            local row = rows[index]
            index = index + 1
            if not row then
                inspect(
                    "CONSUMABLE_ROW_MISSING",
                    "health potion rows ended before the target count was reached"
                )
                return
            end
            local amount = math.min(remaining, row.count)
            self.gateway:ItemUse(userId, row.itemId, amount, function(useResult)
                if not useResult.ok then
                    inspect(useResult.code, useResult.reason)
                    return
                end
                remaining = remaining - amount
                consumeNext()
            end)
        end
        consumeNext()
    end)
end

function PlayerProfileRepository:SetBan(userId, banRecord, onComplete)
    local kind = banRecord and self.gateway.CommitOperation.SCORE_SET or self.gateway.CommitOperation.SCORE_DELETE
    local operation = { kind = kind, userId = userId, key = self.Keys.BAN }
    if banRecord then operation.value = TableUtils.DeepCopy(banRecord) end
    self.gateway:BatchCommit(banRecord and "abyss player ban" or "abyss player unban", { operation }, onComplete)
end

function PlayerProfileRepository:GetBan(userId, onComplete)
    self.gateway:ScoreGet(userId, self.Keys.BAN, function(result)
        if not result.ok then onComplete(result); return end
        onComplete(Result(true, { ban = (result.data.scores or {})[self.Keys.BAN] }))
    end)
end

return PlayerProfileRepository
