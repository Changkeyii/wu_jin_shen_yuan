local ServerCloudGateway = require("server.dao.ServerCloudGateway")
local StateNormalizer = require("server.domain.StateNormalizer")
local TableUtils = require("server.domain.TableUtils")

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
    BAN = "abyss_ban",
    GOLD = "abyss_gold",
    FRAGMENTS = "abyss_fragments",
    MYTH_SHARDS = "abyss_myth_shards",
    INVENTORY = "abyss_inventory",
    CONSUMABLE = "abyss_consumable",
    HEALTH_POTION = "abyss_health_potion",
    ADMIN_AUDIT = "abyss_admin_audit",
    GM_COMMAND = "abyss_gm_command",
    GM_RESULT = "abyss_gm_result",
}

local LOAD_KEYS = {
    PlayerProfileRepository.Keys.PROFILE,
    PlayerProfileRepository.Keys.SCHEMA_VERSION,
    PlayerProfileRepository.Keys.REVISION,
    PlayerProfileRepository.Keys.UPDATED_AT,
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

local function ListId(row)
    return Integer(row.list_id or row.listId or row.id, nil)
end

local function ItemId(row)
    return Integer(row.item_id or row.itemId or row.id, nil)
end

local function ProfileCore(state)
    local persisted = StateNormalizer.ToPersisted(state)
    persisted.inventory = nil
    persisted.gold = nil
    persisted.fragments = nil
    persisted.mythShards = nil
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
    local remaining = 4
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
    self.gateway:MoneyGet(userId, receive("money"))
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
        local moneys = result.data.money.moneys or {}
        local itemRows = result.data.items.items or {}

        if profile == nil then
            local hasOrphanedData = #inventoryRows > 0 or #itemRows > 0
                or (moneys[self.Keys.GOLD] or 0) ~= 0
                or (moneys[self.Keys.FRAGMENTS] or 0) ~= 0
                or (moneys[self.Keys.MYTH_SHARDS] or 0) ~= 0
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
        raw.gold = Integer(moneys[self.Keys.GOLD], 0)
        raw.fragments = Integer(moneys[self.Keys.FRAGMENTS], 0)
        raw.mythShards = Integer(moneys[self.Keys.MYTH_SHARDS], 0)
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

        local state = StateNormalizer.Normalize(raw, self.clock())
        self.listIds[userId] = listMap
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
    local operations = {
        { kind = operation.SCORE_SET, userId = userId, key = self.Keys.PROFILE, value = ProfileCore(newState) },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.SCHEMA_VERSION, value = newState.schemaVersion },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.REVISION, value = newState.revision },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.UPDATED_AT, value = newState.updatedAt },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.FLOOR, value = newState.floor },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.MAX_FLOOR, value = newState.maxFloor },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.LEVEL, value = newState.level },
        { kind = operation.SCORE_SET_INT, userId = userId, key = self.Keys.POWER, value = newState.stats.power },
    }

    local oldGold = oldState and oldState.gold or 0
    local oldFragments = oldState and oldState.fragments or 0
    local oldMyth = oldState and oldState.mythShards or 0
    local money = {
        { key = self.Keys.GOLD, before = oldGold, after = newState.gold },
        { key = self.Keys.FRAGMENTS, before = oldFragments, after = newState.fragments },
        { key = self.Keys.MYTH_SHARDS, before = oldMyth, after = newState.mythShards },
    }
    for _, change in ipairs(money) do
        local delta = change.after - change.before
        if delta > 0 then
            operations[#operations + 1] = { kind = operation.MONEY_ADD, userId = userId, key = change.key, amount = delta }
        elseif delta < 0 then
            operations[#operations + 1] = { kind = operation.MONEY_COST, userId = userId, key = change.key, amount = -delta }
        end
    end

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

function PlayerProfileRepository:Commit(userId, oldState, newState, description, onComplete)
    if oldState and newState.revision ~= oldState.revision + 1 then
        onComplete(Result(false, {}, "REVISION_MISMATCH", "new state revision must advance exactly once"))
        return
    end
    local operations, buildReason = self:_buildOperations(userId, oldState, newState)
    if not operations then
        onComplete(Result(false, {}, "PERSISTENCE_MAP_MISSING", buildReason))
        return
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
