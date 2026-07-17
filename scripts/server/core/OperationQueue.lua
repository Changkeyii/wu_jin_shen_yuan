local ErrorCodes = require("shared.ErrorCodes")

local OperationQueue = {}
OperationQueue.__index = OperationQueue
OperationQueue.PENDING = {}

local function reportError(instance, err)
    if instance._onError ~= nil then
        pcall(instance._onError, err)
    end
end

---@param options table|nil
---@return table
function OperationQueue.New(options)
    options = options or {}
    return setmetatable({
        _queues = {},
        _nextJobId = 0,
        _onError = options.onError,
    }, OperationQueue)
end

local function operationParts(operation, onComplete)
    if type(operation) == "function" then
        return operation, nil, onComplete
    end
    assert(type(operation) == "table", "operation must be a function or table")
    assert(type(operation.run) == "function", "operation.run must be a function")
    return operation.run, operation.async, onComplete or operation.onComplete
end

function OperationQueue:_finish(uidKey, queue, job, ok, result)
    if job.finished or queue.runningJob ~= job then
        return false
    end
    job.finished = true
    queue.runningJob = nil

    if not ok then
        local reason = type(result) == "table" and result.reason or result
        reportError(self, reason or "operation failed")
    end

    if job.onComplete ~= nil then
        local callbackOk, callbackError = pcall(job.onComplete, ok, result, job.id)
        if not callbackOk then
            reportError(self, callbackError)
        end
    end

    self:_drain(uidKey, queue)
    return true
end

function OperationQueue:_drain(uidKey, queue)
    if queue.draining or queue.runningJob ~= nil then
        return
    end
    queue.draining = true

    while queue.runningJob == nil and queue.head <= #queue.items do
        local job = queue.items[queue.head]
        queue.items[queue.head] = false
        queue.head = queue.head + 1
        queue.runningJob = job

        local function done(ok, result)
            if type(ok) ~= "boolean" then
                result = ok
                ok = true
            end
            return self:_finish(uidKey, queue, job, ok, result)
        end

        local callOk, first, second = pcall(job.run, done, job.id)
        if not callOk then
            done(false, ErrorCodes.Make(ErrorCodes.OPERATION_FAILED, tostring(first)))
        elseif not job.finished then
            if first == OperationQueue.PENDING then
                -- The operation will invoke done later.
            elseif type(first) == "boolean" then
                done(first, second)
            elseif first ~= nil then
                done(true, first)
            elseif job.async == false then
                done(true, nil)
            end
        end

        if queue.runningJob ~= nil then
            break
        end
    end

    if queue.runningJob == nil and queue.head > #queue.items then
        self._queues[uidKey] = nil
    elseif queue.head > 64 and queue.head > (#queue.items / 2) then
        local compacted = {}
        for index = queue.head, #queue.items do
            local item = queue.items[index]
            if item then
                compacted[#compacted + 1] = item
            end
        end
        queue.items = compacted
        queue.head = 1
    end
    queue.draining = false
end

---@param uid number|string
---@param operation function|table
---@param onComplete function|nil
---@return number
function OperationQueue:Enqueue(uid, operation, onComplete)
    assert(uid ~= nil, "uid is required")
    local run, async, callback = operationParts(operation, onComplete)
    local uidKey = tostring(uid)
    local queue = self._queues[uidKey]
    if queue == nil then
        queue = {
            items = {},
            head = 1,
            runningJob = nil,
            draining = false,
        }
        self._queues[uidKey] = queue
    end

    self._nextJobId = self._nextJobId + 1
    local job = {
        id = self._nextJobId,
        run = run,
        async = async,
        onComplete = callback,
        finished = false,
    }
    queue.items[#queue.items + 1] = job
    self:_drain(uidKey, queue)
    return job.id
end

---@param uid number|string
---@return boolean
function OperationQueue:IsBusy(uid)
    local queue = self._queues[tostring(uid)]
    return queue ~= nil and (queue.runningJob ~= nil or queue.head <= #queue.items)
end

---@param uid number|string
---@return number
function OperationQueue:PendingCount(uid)
    local queue = self._queues[tostring(uid)]
    if queue == nil then
        return 0
    end
    local count = queue.runningJob and 1 or 0
    for index = queue.head, #queue.items do
        if queue.items[index] then
            count = count + 1
        end
    end
    return count
end

---@param uid number|string
---@param reason string|nil
---@return number
function OperationQueue:Clear(uid, reason)
    local uidKey = tostring(uid)
    local queue = self._queues[uidKey]
    if queue == nil then
        return 0
    end
    local removed = 0
    local errorResult = ErrorCodes.Make(ErrorCodes.OPERATION_FAILED, reason or "Operation queue was cleared")
    for index = queue.head, #queue.items do
        local job = queue.items[index]
        if job then
            queue.items[index] = false
            job.finished = true
            removed = removed + 1
            if job.onComplete ~= nil then
                local ok, err = pcall(job.onComplete, false, errorResult, job.id)
                if not ok then
                    reportError(self, err)
                end
            end
        end
    end
    queue.head = #queue.items + 1
    if queue.runningJob == nil then
        self._queues[uidKey] = nil
    end
    return removed
end

function OperationQueue:Reset(reason)
    local keys = {}
    for uidKey in pairs(self._queues) do
        keys[#keys + 1] = uidKey
    end
    for _, uidKey in ipairs(keys) do
        self:Clear(uidKey, reason)
    end
end

local defaultQueue = OperationQueue.New()
local Module = {
    New = OperationQueue.New,
    Class = OperationQueue,
    Default = defaultQueue,
    PENDING = OperationQueue.PENDING,
}

for _, methodName in ipairs({ "Enqueue", "IsBusy", "PendingCount", "Clear", "Reset" }) do
    Module[methodName] = function(...)
        return defaultQueue[methodName](defaultQueue, ...)
    end
end

return Module
