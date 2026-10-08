local ServerCloudGateway = require("server.dao.ServerCloudGateway")
local TableUtils = require("server.domain.TableUtils")

local FakeGateway = {}
FakeGateway.__index = FakeGateway
FakeGateway.CommitOperation = ServerCloudGateway.CommitOperation

local function Result(ok, data, code, reason)
    return {
        ok = ok == true,
        data = data or {},
        code = code or (ok and 0 or -1),
        reason = tostring(reason or ""),
    }
end

local function Bucket(store, userId)
    local key = tostring(userId)
    store[key] = store[key] or {}
    return store[key]
end

local function FindById(rows, field, value)
    for index, row in ipairs(rows) do
        if row[field] == value then return row, index end
    end
    return nil, nil
end

function FakeGateway.New()
    return setmetatable({
        scores = {},
        iscores = {},
        moneys = {},
        lists = {},
        items = {},
        messages = {},
        nextListId = 1000,
        nextItemId = 2000,
        nextMessageId = 3000,
        calls = {},
        commits = {},
        pendingCommits = {},
        failNextCommit = nil,
        failNextMessageSend = nil,
        persistNextCommitWithoutCallback = false,
        delayNextCommit = false,
    }, FakeGateway)
end

FakeGateway.new = FakeGateway.New

function FakeGateway:_record(name, detail)
    self.calls[#self.calls + 1] = { name = name, detail = TableUtils.DeepCopy(detail) }
end

function FakeGateway:FailNextCommit(code, reason)
    self.failNextCommit = { code = code or "CLOUD_FAILED", reason = reason or "cloud commit failed" }
end

function FakeGateway:DelayNextCommit()
    self.delayNextCommit = true
end

function FakeGateway:FailNextMessageSend(key, code, reason)
    self.failNextMessageSend = {
        key = key,
        code = code or "MESSAGE_SEND_FAILED",
        reason = reason or "message send failed",
    }
end

function FakeGateway:PersistNextCommitWithoutCallback()
    self.persistNextCommitWithoutCallback = true
end

function FakeGateway:ResolveNextCommit(ok, code, reason)
    local pending = table.remove(self.pendingCommits, 1)
    assert(pending, "no delayed commit is pending")
    pending(ok ~= false, code, reason)
end

function FakeGateway:BatchGet(userId, keys, onComplete)
    self:_record("BatchGet", { userId = userId, keys = keys })
    onComplete(Result(true, {
        scores = TableUtils.DeepCopy(Bucket(self.scores, userId)),
        iscores = TableUtils.DeepCopy(Bucket(self.iscores, userId)),
    }))
end

function FakeGateway:ScoreGet(userId, key, onComplete)
    self:_record("ScoreGet", { userId = userId, key = key })
    local scores = Bucket(self.scores, userId)
    onComplete(Result(true, { scores = { [key] = TableUtils.DeepCopy(scores[key]) } }))
end

function FakeGateway:MoneyGet(userId, onComplete)
    self:_record("MoneyGet", { userId = userId })
    onComplete(Result(true, { moneys = TableUtils.DeepCopy(Bucket(self.moneys, userId)) }))
end

function FakeGateway:ListGet(userId, key, onComplete)
    self:_record("ListGet", { userId = userId, key = key })
    local rows = {}
    for _, row in ipairs(self.lists) do
        if row.userId == userId and row.key == key then
            rows[#rows + 1] = TableUtils.DeepCopy(row)
        end
    end
    onComplete(Result(true, { items = rows }))
end

function FakeGateway:ListAdd(userId, key, value, onComplete)
    self:_record("ListAdd", { userId = userId, key = key, value = value })
    self.nextListId = self.nextListId + 1
    local row = {
        list_id = self.nextListId,
        userId = userId,
        key = key,
        value = TableUtils.DeepCopy(value),
    }
    self.lists[#self.lists + 1] = row
    onComplete(Result(true, { listId = row.list_id }))
end

function FakeGateway:ItemGet(userId, key, onComplete)
    self:_record("ItemGet", { userId = userId, key = key })
    local rows = {}
    for _, row in ipairs(self.items) do
        if row.userId == userId and (key == nil or row.key == key) then
            rows[#rows + 1] = TableUtils.DeepCopy(row)
        end
    end
    onComplete(Result(true, { items = rows }))
end

function FakeGateway:ItemAdd(userId, key, name, count, value, expireType, expireTime, onComplete)
    self:_record("ItemAdd", {
        userId = userId,
        key = key,
        name = name,
        count = count,
        value = value,
    })
    self.nextItemId = self.nextItemId + 1
    local row = {
        item_id = self.nextItemId,
        userId = userId,
        key = key,
        name = name,
        count = count,
        value = TableUtils.DeepCopy(value),
    }
    self.items[#self.items + 1] = row
    onComplete(Result(true, { itemId = row.item_id }))
end

function FakeGateway:MessageSend(userId, key, targetUserId, value, onComplete)
    self:_record("MessageSend", {
        userId = userId,
        key = key,
        targetUserId = targetUserId,
        value = value,
    })
    local injectedFailure = self.failNextMessageSend
    if injectedFailure and (injectedFailure.key == nil or injectedFailure.key == key) then
        self.failNextMessageSend = nil
        onComplete(Result(false, {}, injectedFailure.code, injectedFailure.reason))
        return
    end
    self.nextMessageId = self.nextMessageId + 1
    self.messages[#self.messages + 1] = {
        message_id = self.nextMessageId,
        userId = targetUserId,
        senderUid = userId,
        key = key,
        value = TableUtils.DeepCopy(value),
        read = false,
    }
    onComplete(Result(true))
end

function FakeGateway:MessageGet(userId, key, read, onComplete)
    self:_record("MessageGet", { userId = userId, key = key, read = read })
    local rows = {}
    for _, row in ipairs(self.messages) do
        if row.userId == userId and row.key == key and row.read == read then
            rows[#rows + 1] = TableUtils.DeepCopy(row)
        end
    end
    onComplete(Result(true, { messages = rows }))
end

function FakeGateway:MessageMarkRead(messageId, onComplete)
    self:_record("MessageMarkRead", { messageId = messageId })
    local row = FindById(self.messages, "message_id", messageId)
    if not row then
        onComplete(Result(false, {}, "MESSAGE_NOT_FOUND", "message does not exist"))
        return
    end
    row.read = true
    onComplete(Result(true))
end

function FakeGateway:BatchCommit(description, operations, onComplete)
    self:_record("BatchCommit", { description = description, operations = operations })
    self.commits[#self.commits + 1] = {
        description = description,
        operations = TableUtils.DeepCopy(operations),
    }

    local staged = {
        scores = TableUtils.DeepCopy(self.scores),
        iscores = TableUtils.DeepCopy(self.iscores),
        moneys = TableUtils.DeepCopy(self.moneys),
        lists = TableUtils.DeepCopy(self.lists),
        nextListId = self.nextListId,
    }
    local listIds = {}
    local operation = self.CommitOperation

    local function stage()
        for _, entry in ipairs(operations or {}) do
            if entry.kind == operation.SCORE_SET then
                Bucket(staged.scores, entry.userId)[entry.key] = TableUtils.DeepCopy(entry.value)
            elseif entry.kind == operation.SCORE_SET_INT then
                Bucket(staged.iscores, entry.userId)[entry.key] = entry.value
            elseif entry.kind == operation.SCORE_DELETE then
                Bucket(staged.scores, entry.userId)[entry.key] = nil
            elseif entry.kind == operation.SCORE_DELETE_INT then
                Bucket(staged.iscores, entry.userId)[entry.key] = nil
            elseif entry.kind == operation.MONEY_ADD then
                local money = Bucket(staged.moneys, entry.userId)
                money[entry.key] = (money[entry.key] or 0) + entry.amount
            elseif entry.kind == operation.MONEY_COST then
                local money = Bucket(staged.moneys, entry.userId)
                if (money[entry.key] or 0) < entry.amount then
                    return false, "INSUFFICIENT_MONEY", "fake money balance is insufficient"
                end
                money[entry.key] = money[entry.key] - entry.amount
            elseif entry.kind == operation.LIST_ADD then
                staged.nextListId = staged.nextListId + 1
                staged.lists[#staged.lists + 1] = {
                    list_id = staged.nextListId,
                    userId = entry.userId,
                    key = entry.key,
                    value = TableUtils.DeepCopy(entry.value),
                }
                if entry.resultKey then listIds[entry.resultKey] = staged.nextListId end
            elseif entry.kind == operation.LIST_MODIFY then
                local row = FindById(staged.lists, "list_id", entry.listId)
                if not row then return false, "LIST_NOT_FOUND", "fake list row does not exist" end
                row.value = TableUtils.DeepCopy(entry.value)
            elseif entry.kind == operation.LIST_MODIFY_KEY then
                local row = FindById(staged.lists, "list_id", entry.listId)
                if not row then return false, "LIST_NOT_FOUND", "fake list row does not exist" end
                row.key = entry.key
            elseif entry.kind == operation.LIST_DELETE then
                local _, index = FindById(staged.lists, "list_id", entry.listId)
                if not index then return false, "LIST_NOT_FOUND", "fake list row does not exist" end
                table.remove(staged.lists, index)
            end
        end
        return true
    end

    local stagedOk, stagedCode, stagedReason = stage()
    local injectedFailure = self.failNextCommit
    self.failNextCommit = nil

    local function resolve(ok, code, reason)
        if injectedFailure then
            onComplete(Result(false, {}, injectedFailure.code, injectedFailure.reason))
            return
        end
        if not stagedOk then
            onComplete(Result(false, {}, stagedCode, stagedReason))
            return
        end
        if not ok then
            onComplete(Result(false, {}, code or "CLOUD_FAILED", reason or "cloud commit failed"))
            return
        end
        self.scores = staged.scores
        self.iscores = staged.iscores
        self.moneys = staged.moneys
        self.lists = staged.lists
        self.nextListId = staged.nextListId
        if self.persistNextCommitWithoutCallback then
            self.persistNextCommitWithoutCallback = false
            return
        end
        onComplete(Result(true, { listIds = listIds }))
    end

    if self.delayNextCommit then
        self.delayNextCommit = false
        self.pendingCommits[#self.pendingCommits + 1] = resolve
    else
        resolve(true)
    end
end

return FakeGateway
