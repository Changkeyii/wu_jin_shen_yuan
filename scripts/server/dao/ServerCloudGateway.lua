---@class ProjectServerCloudGateway
---@field cloud table?
---@field requestTotals table
local ServerCloudGateway = {}
ServerCloudGateway.__index = ServerCloudGateway

ServerCloudGateway.ErrorCode = {
    INVALID_ARGUMENT = -400,
    UNSUPPORTED_OPERATION = -422,
    UNAVAILABLE = -503,
}

ServerCloudGateway.BatchSetOperation = {
    SET = "set",
    SET_INT = "set_int",
    ADD = "add",
    DELETE = "delete",
}

ServerCloudGateway.CommitOperation = {
    SCORE_SET = "score_set",
    SCORE_SET_INT = "score_set_int",
    SCORE_ADD_INT = "score_add_int",
    SCORE_DELETE = "score_delete",
    SCORE_DELETE_INT = "score_delete_int",
    MONEY_ADD = "money_add",
    MONEY_COST = "money_cost",
    LIST_ADD = "list_add",
    LIST_MODIFY = "list_modify",
    LIST_MODIFY_KEY = "list_modify_key",
    LIST_DELETE = "list_delete",
    QUOTA_ADD = "quota_add",
    QUOTA_RESET = "quota_reset",
}

local function success(data)
    return {
        ok = true,
        data = data or {},
        code = 0,
        reason = "",
    }
end

local function failure(code, reason, data)
    return {
        ok = false,
        data = data or {},
        code = code or -1,
        reason = tostring(reason or "serverCloud request failed"),
    }
end

local function requireCompletion(onComplete)
    if type(onComplete) ~= "function" then
        error("ServerCloudGateway requires an onComplete callback", 3)
    end
end

local function finish(onComplete, result)
    onComplete(result)
    return result
end

local function eventsFor(onComplete, mapSuccess)
    requireCompletion(onComplete)
    return {
        ok = function(...)
            local data = {}
            if mapSuccess then
                data = mapSuccess(...) or {}
            end
            onComplete(success(data))
        end,
        error = function(code, reason)
            onComplete(failure(code, reason))
        end,
    }
end

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function validateUserId(userId)
    return isInteger(userId)
end

local function validateOperations(operations)
    return type(operations) == "table" and #operations > 0
end

---@param cloud? ServerCloud
---@return ProjectServerCloudGateway
function ServerCloudGateway.new(cloud)
    local instance = {
        cloud = cloud or _G["serverCloud"],
        requestTotals = { at = os.time(), read = 0, write = 0, peakRead = 0, peakWrite = 0 },
    }
    return setmetatable(instance, ServerCloudGateway)
end

ServerCloudGateway.New = ServerCloudGateway.new

function ServerCloudGateway:IsAvailable()
    return self.cloud ~= nil
end

function ServerCloudGateway:_requireCloud(onComplete)
    requireCompletion(onComplete)
    if self.cloud ~= nil then
        return true
    end
    finish(onComplete, failure(
        ServerCloudGateway.ErrorCode.UNAVAILABLE,
        "serverCloud is unavailable; this gateway only runs in server mode"
    ))
    return false
end

function ServerCloudGateway:_invalid(onComplete, reason)
    requireCompletion(onComplete)
    return finish(onComplete, failure(ServerCloudGateway.ErrorCode.INVALID_ARGUMENT, reason))
end

function ServerCloudGateway:_unsupported(onComplete, reason)
    requireCompletion(onComplete)
    return finish(onComplete, failure(ServerCloudGateway.ErrorCode.UNSUPPORTED_OPERATION, reason))
end

-- Score ---------------------------------------------------------------------

function ServerCloudGateway:ScoreGet(userId, key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "ScoreGet requires an integer userId and non-empty key")
    end
    self.cloud:Get(userId, key, eventsFor(onComplete, function(scores, iscores)
        return {
            scores = scores or {},
            iscores = iscores or {},
        }
    end))
end

function ServerCloudGateway:ScoreSet(userId, key, value, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "ScoreSet requires an integer userId and non-empty key")
    end
    self.cloud:Set(userId, key, value, eventsFor(onComplete))
end

function ServerCloudGateway:ScoreSetInt(userId, key, value, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) or not isInteger(value) then
        return self:_invalid(onComplete, "ScoreSetInt requires integer userId/value and a non-empty key")
    end
    self.cloud:SetInt(userId, key, value, eventsFor(onComplete))
end

function ServerCloudGateway:ScoreAdd(userId, key, delta, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) or not isInteger(delta) then
        return self:_invalid(onComplete, "ScoreAdd requires integer userId/delta and a non-empty key")
    end
    self.cloud:Add(userId, key, delta, eventsFor(onComplete))
end

function ServerCloudGateway:ScoreDelete(userId, key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "ScoreDelete requires an integer userId and non-empty key")
    end
    self.cloud:Delete(userId, key, eventsFor(onComplete))
end

-- Money ---------------------------------------------------------------------

function ServerCloudGateway:MoneyGet(userId, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) then
        return self:_invalid(onComplete, "MoneyGet requires an integer userId")
    end
    self.cloud.money:Get(userId, eventsFor(onComplete, function(moneys)
        return { moneys = moneys or {} }
    end))
end

function ServerCloudGateway:MoneyAdd(userId, key, amount, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) or not isInteger(amount) then
        return self:_invalid(onComplete, "MoneyAdd requires integer userId/amount and a non-empty key")
    end
    self.cloud.money:Add(userId, key, amount, eventsFor(onComplete))
end

function ServerCloudGateway:MoneyCost(userId, key, amount, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) or not isInteger(amount) or amount <= 0 then
        return self:_invalid(onComplete, "MoneyCost requires a positive integer amount")
    end
    self.cloud.money:Cost(userId, key, amount, eventsFor(onComplete))
end

-- List ----------------------------------------------------------------------

function ServerCloudGateway:ListGet(userId, key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "ListGet requires an integer userId and non-empty key")
    end
    self.cloud.list:Get(userId, key, eventsFor(onComplete, function(items)
        return { items = items or {} }
    end))
end

function ServerCloudGateway:ListGetById(listId, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isInteger(listId) then
        return self:_invalid(onComplete, "ListGetById requires an integer listId")
    end
    self.cloud.list:GetById(listId, eventsFor(onComplete, function(items)
        return { items = items or {} }
    end))
end

local function invokeWithReturnedId(invoke, field, onComplete)
    requireCompletion(onComplete)
    local invoking = true
    local returnedId = nil
    local pending = nil

    local events = {
        ok = function(callbackId)
            local deliver = function()
                local id = returnedId
                if id == nil then id = callbackId end
                onComplete(success({ [field] = id }))
            end
            if invoking then pending = deliver else deliver() end
        end,
        error = function(code, reason)
            local deliver = function()
                onComplete(failure(code, reason))
            end
            if invoking then pending = deliver else deliver() end
        end,
    }

    returnedId = invoke(events)
    invoking = false
    if pending then pending() end
end

function ServerCloudGateway:ListAdd(userId, key, value, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "ListAdd requires an integer userId and non-empty key")
    end
    invokeWithReturnedId(function(events)
        return self.cloud.list:Add(userId, key, value, events)
    end, "listId", onComplete)
end

function ServerCloudGateway:ListModify(listId, value, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isInteger(listId) then
        return self:_invalid(onComplete, "ListModify requires an integer listId")
    end
    self.cloud.list:Modify(listId, value, eventsFor(onComplete))
end

function ServerCloudGateway:ListModifyKey(listId, key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isInteger(listId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "ListModifyKey requires an integer listId and non-empty key")
    end
    self.cloud.list:ModifyKey(listId, key, eventsFor(onComplete))
end

function ServerCloudGateway:ListDelete(listId, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isInteger(listId) then
        return self:_invalid(onComplete, "ListDelete requires an integer listId")
    end
    self.cloud.list:Delete(listId, eventsFor(onComplete))
end

-- Item ----------------------------------------------------------------------

function ServerCloudGateway:ItemGet(userId, key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or (key ~= nil and not isNonEmptyString(key)) then
        return self:_invalid(onComplete, "ItemGet requires an integer userId and optional non-empty key")
    end
    self.cloud.item:Get(userId, key, eventsFor(onComplete, function(items)
        return { items = items or {} }
    end))
end

function ServerCloudGateway:ItemAdd(userId, key, name, count, value, expireType, expireTime, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) or not isNonEmptyString(name)
        or not isInteger(count) or count <= 0 then
        return self:_invalid(onComplete, "ItemAdd requires userId, key, name, and a positive integer count")
    end
    invokeWithReturnedId(function(events)
        return self.cloud.item:Add(
            userId, key, name, count, value, expireType, expireTime, events
        )
    end, "itemId", onComplete)
end

function ServerCloudGateway:ItemUse(userId, itemId, count, onComplete)
    if not self:_requireCloud(onComplete) then return end
    count = count or 1
    if not validateUserId(userId) or not isInteger(itemId) or not isInteger(count) or count <= 0 then
        return self:_invalid(onComplete, "ItemUse requires integer ids and a positive integer count")
    end
    self.cloud.item:Use(userId, itemId, count, eventsFor(onComplete))
end

-- Message -------------------------------------------------------------------

local function embeddedMessageEvents(onComplete, mapSuccess)
    requireCompletion(onComplete)
    return {
        ok = function(...)
            local data, code, reason = mapSuccess(...)
            if code ~= nil and code ~= 0 then
                onComplete(failure(code, reason, data))
                return
            end
            onComplete(success(data))
        end,
        error = function(code, reason)
            onComplete(failure(code, reason))
        end,
    }
end

function ServerCloudGateway:MessageSend(userId, key, targetUserId, value, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not validateUserId(targetUserId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "MessageSend requires sender/target user IDs and a non-empty key")
    end
    self.cloud.message:Send(userId, key, targetUserId, value, embeddedMessageEvents(
        onComplete,
        function(errorCode, errorDesc)
            return {}, errorCode, errorDesc
        end
    ))
end

function ServerCloudGateway:MessageGet(userId, key, read, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) or type(read) ~= "boolean" then
        return self:_invalid(onComplete, "MessageGet requires userId, key, and a boolean read filter")
    end
    self.cloud.message:Get(userId, key, read, eventsFor(onComplete, function(messages)
        return { messages = messages or {} }
    end))
end

function ServerCloudGateway:MessageMarkRead(messageId, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isInteger(messageId) then
        return self:_invalid(onComplete, "MessageMarkRead requires an integer messageId")
    end
    self.cloud.message:MarkRead(messageId, embeddedMessageEvents(
        onComplete,
        function(errorCode, errorDesc)
            return {}, errorCode, errorDesc
        end
    ))
end

function ServerCloudGateway:MessageDelete(messageId, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isInteger(messageId) then
        return self:_invalid(onComplete, "MessageDelete requires an integer messageId")
    end
    self.cloud.message:Delete(messageId, embeddedMessageEvents(
        onComplete,
        function(result, errorCode, errorDesc)
            return { result = result }, errorCode, errorDesc
        end
    ))
end

-- Quota ---------------------------------------------------------------------

function ServerCloudGateway:QuotaGet(userId, key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "QuotaGet requires an integer userId and non-empty key")
    end
    self.cloud.quota:Get(userId, key, eventsFor(onComplete, function(entries)
        return { entries = entries or {} }
    end))
end

function ServerCloudGateway:QuotaAdd(userId, key, value, limit, refreshType, refreshCount, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) or not isInteger(value)
        or not isInteger(limit) then
        return self:_invalid(onComplete, "QuotaAdd requires integer userId/value/limit and a non-empty key")
    end
    self.cloud.quota:Add(
        userId, key, value, limit, refreshType, refreshCount, eventsFor(onComplete)
    )
end

function ServerCloudGateway:QuotaReset(userId, key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "QuotaReset requires an integer userId and non-empty key")
    end
    self.cloud.quota:Reset(userId, key, eventsFor(onComplete))
end

-- Rank ----------------------------------------------------------------------

function ServerCloudGateway:RankGetList(key, start, count, orderAsc, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isNonEmptyString(key) or not isInteger(start) or start < 1
        or not isInteger(count) or count <= 0
        or (orderAsc ~= nil and type(orderAsc) ~= "boolean") then
        return self:_invalid(onComplete, "RankGetList requires key, 1-based start, and positive count")
    end
    local events = eventsFor(onComplete, function(rankList)
        return { rankList = rankList or {} }
    end)
    if orderAsc == nil then
        self.cloud:GetRankList(key, start, count, events)
    else
        self.cloud:GetRankList(key, start, count, orderAsc, events)
    end
end

function ServerCloudGateway:RankGetUser(userId, key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not isNonEmptyString(key) then
        return self:_invalid(onComplete, "RankGetUser requires an integer userId and non-empty key")
    end
    self.cloud:GetUserRank(userId, key, eventsFor(onComplete, function(rank, score)
        return { rank = rank, score = score }
    end))
end

function ServerCloudGateway:RankGetTotal(key, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isNonEmptyString(key) then
        return self:_invalid(onComplete, "RankGetTotal requires a non-empty key")
    end
    self.cloud:GetRankTotal(key, eventsFor(onComplete, function(total)
        return { total = total or 0 }
    end))
end

-- Batch ---------------------------------------------------------------------

function ServerCloudGateway:BatchGet(userIds, keys, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if type(keys) ~= "table" or #keys == 0 then
        return self:_invalid(onComplete, "BatchGet requires at least one key")
    end
    for _, key in ipairs(keys) do
        if not isNonEmptyString(key) then
            return self:_invalid(onComplete, "BatchGet keys must be non-empty strings")
        end
    end

    if validateUserId(userIds) then
        local batch = self.cloud:BatchGet(userIds)
        for _, key in ipairs(keys) do batch:Key(key) end
        batch:Fetch(eventsFor(onComplete, function(scores, iscores)
            return {
                scores = scores or {},
                iscores = iscores or {},
            }
        end))
        return
    end

    if type(userIds) ~= "table" or #userIds == 0 then
        return self:_invalid(onComplete, "BatchGet requires one userId or a non-empty userId array")
    end
    local batch = self.cloud:BatchGet()
    for _, userId in ipairs(userIds) do
        if not validateUserId(userId) then
            return self:_invalid(onComplete, "BatchGet user IDs must be integers")
        end
        batch:Player(userId)
    end
    for _, key in ipairs(keys) do batch:Key(key) end
    batch:Fetch(eventsFor(onComplete, function(results)
        return { results = results or {} }
    end))
end

local batchSetHandlers = {
    [ServerCloudGateway.BatchSetOperation.SET] = function(batch, op)
        batch:Set(op.key, op.value)
    end,
    [ServerCloudGateway.BatchSetOperation.SET_INT] = function(batch, op)
        batch:SetInt(op.key, op.value)
    end,
    [ServerCloudGateway.BatchSetOperation.ADD] = function(batch, op)
        batch:Add(op.key, op.delta)
    end,
    [ServerCloudGateway.BatchSetOperation.DELETE] = function(batch, op)
        batch:Delete(op.key)
    end,
}

function ServerCloudGateway:BatchSet(userId, operations, description, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not validateUserId(userId) or not validateOperations(operations)
        or not isNonEmptyString(description) then
        return self:_invalid(onComplete, "BatchSet requires userId, operations, and description")
    end
    for _, operation in ipairs(operations) do
        if type(operation) ~= "table" or not batchSetHandlers[operation.kind]
            or not isNonEmptyString(operation.key) then
            return self:_unsupported(onComplete, "BatchSet contains an unsupported operation")
        end
    end

    local batch = self.cloud:BatchSet(userId)
    for _, operation in ipairs(operations) do
        batchSetHandlers[operation.kind](batch, operation)
    end
    -- BatchSet is a batched write. This gateway does not claim transaction semantics for it.
    batch:Save(description, eventsFor(onComplete))
end

local commitHandlers = {
    [ServerCloudGateway.CommitOperation.SCORE_SET] = function(commit, op)
        commit:ScoreSet(op.userId, op.key, op.value)
    end,
    [ServerCloudGateway.CommitOperation.SCORE_SET_INT] = function(commit, op)
        commit:ScoreSetInt(op.userId, op.key, op.value)
    end,
    [ServerCloudGateway.CommitOperation.SCORE_ADD_INT] = function(commit, op)
        commit:ScoreAddInt(op.userId, op.key, op.delta)
    end,
    [ServerCloudGateway.CommitOperation.SCORE_DELETE] = function(commit, op)
        commit:ScoreDelete(op.userId, op.key)
    end,
    [ServerCloudGateway.CommitOperation.SCORE_DELETE_INT] = function(commit, op)
        commit:ScoreDeleteInt(op.userId, op.key)
    end,
    [ServerCloudGateway.CommitOperation.MONEY_ADD] = function(commit, op)
        commit:MoneyAdd(op.userId, op.key, op.amount)
    end,
    [ServerCloudGateway.CommitOperation.MONEY_COST] = function(commit, op)
        commit:MoneyCost(op.userId, op.key, op.amount)
    end,
    [ServerCloudGateway.CommitOperation.LIST_ADD] = function(commit, op, listIds)
        local _, listId = commit:ListAdd(op.userId, op.key, op.value)
        listIds[op.resultKey or (#listIds + 1)] = listId
    end,
    [ServerCloudGateway.CommitOperation.LIST_MODIFY] = function(commit, op)
        commit:ListModify(op.listId, op.value)
    end,
    [ServerCloudGateway.CommitOperation.LIST_MODIFY_KEY] = function(commit, op)
        commit:ListModifyKey(op.listId, op.key)
    end,
    [ServerCloudGateway.CommitOperation.LIST_DELETE] = function(commit, op)
        commit:ListDelete(op.listId)
    end,
    [ServerCloudGateway.CommitOperation.QUOTA_ADD] = function(commit, op)
        commit:QuotaAdd(
            op.userId, op.key, op.value, op.limit, op.refreshType, op.refreshCount
        )
    end,
    [ServerCloudGateway.CommitOperation.QUOTA_RESET] = function(commit, op)
        commit:QuotaReset(op.userId, op.key)
    end,
}

function ServerCloudGateway:BatchCommit(description, operations, onComplete)
    if not self:_requireCloud(onComplete) then return end
    if not isNonEmptyString(description) or not validateOperations(operations) then
        return self:_invalid(onComplete, "BatchCommit requires a description and operations")
    end
    for _, operation in ipairs(operations) do
        if type(operation) ~= "table" or not commitHandlers[operation.kind] then
            return self:_unsupported(onComplete, "BatchCommit contains an unsupported operation")
        end
    end

    local commit = self.cloud:BatchCommit(description)
    local listIds = {}
    for _, operation in ipairs(operations) do
        commitHandlers[operation.kind](commit, operation, listIds)
    end

    -- BatchCommit is the only gateway operation documented as an atomic transaction.
    commit:Commit(eventsFor(onComplete, function()
        return { listIds = listIds }
    end))
end

ServerCloudGateway.Success = success
ServerCloudGateway.Failure = failure

-- Count gateway REQUESTS across gameplay, mail, rankings and administration.
-- The platform's actual limiting scope/operation accounting must be verified
-- against a development cloud; this is instrumentation, not a guessed hard cap.
function ServerCloudGateway:RequestTotals()
    local totals = self.requestTotals
    if os.time() >= totals.at + 60 then
        totals.peakRead = math.max(totals.peakRead, totals.read)
        totals.peakWrite = math.max(totals.peakWrite, totals.write)
        totals.at, totals.read, totals.write = os.time(), 0, 0
    end
    return { at = totals.at, read = totals.read, write = totals.write,
        peakRead = totals.peakRead, peakWrite = totals.peakWrite,
        accounting = "gateway-requests", platformScopeVerified = false }
end
local reads = { ScoreGet=true, MoneyGet=true, ListGet=true, ListGetById=true, ItemGet=true,
    MessageGet=true, QuotaGet=true, RankGetList=true, RankGetUser=true, RankGetTotal=true, BatchGet=true }
local methods = { "ScoreGet", "ScoreSet", "ScoreSetInt", "ScoreAdd", "ScoreDelete", "MoneyGet", "MoneyAdd", "MoneyCost",
    "ListGet", "ListGetById", "ListAdd", "ListModify", "ListModifyKey", "ListDelete", "ItemGet", "ItemAdd", "ItemUse",
    "MessageSend", "MessageGet", "MessageMarkRead", "MessageDelete", "QuotaGet", "QuotaAdd", "QuotaReset",
    "RankGetList", "RankGetUser", "RankGetTotal", "BatchGet", "BatchSet", "BatchCommit" }
for _, name in ipairs(methods) do
    local invoke = ServerCloudGateway[name]
    ServerCloudGateway[name] = function(self, ...)
        self:RequestTotals()
        local kind = reads[name] and "read" or "write"
        self.requestTotals[kind] = self.requestTotals[kind] + 1
        return invoke(self, ...)
    end
end

return ServerCloudGateway
