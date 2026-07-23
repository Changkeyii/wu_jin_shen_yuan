local ErrorCodes = require("shared.ErrorCodes")
local NetworkProtocol = require("shared.NetworkProtocol")
local PlayerRegistryModule = require("server.core.PlayerRegistry")
local RateLimiterModule = require("server.core.RateLimiter")
local OperationQueueModule = require("server.core.OperationQueue")

local CommandRouter = {}
CommandRouter.__index = CommandRouter
CommandRouter.PENDING = OperationQueueModule.PENDING

local function defaultClock()
    local timeObject = _G["time"]
    if timeObject and type(timeObject.GetElapsedTime) == "function" then
        local ok, value = pcall(timeObject.GetElapsedTime, timeObject)
        if ok and type(value) == "number" then
            return value
        end
    end
    return os.clock()
end

local function responseBody(ok, value)
    if ok then
        if type(value) == "table" and value.ok == true then
            if value.code == nil then
                value.code = ErrorCodes.OK
            end
            return value
        end
        return ErrorCodes.Success(value)
    end

    if ErrorCodes.IsError(value) then
        return value
    end
    if type(value) == "table" and type(value.code) == "string" then
        return ErrorCodes.Make(value.code, value.reason, value.details)
    end
    if type(value) == "string" then
        return ErrorCodes.Make(ErrorCodes.OPERATION_FAILED, value)
    end
    return ErrorCodes.Make(ErrorCodes.OPERATION_FAILED)
end

local function defaultSend(connection, eventName, envelope)
    local eventData = NetworkProtocol.ToVariantMap(envelope)
    connection:SendRemoteEvent(eventName, true, eventData)
end

local function extractConnection(eventData)
    if eventData == nil then
        return nil
    end
    local okField, field = pcall(function()
        return eventData["Connection"]
    end)
    if okField and field ~= nil then
        -- UrhoX exposes VariantMap fields as Variant values in production,
        -- while unit tests and some hosts may provide the connection directly.
        local okMethod, getPtr = pcall(function() return field.GetPtr end)
        if okMethod and type(getPtr) == "function" then
            local okVariant, connection = pcall(getPtr, field, "Connection")
            if okVariant and connection ~= nil then
                return connection
            end
        else
            return field
        end
    end
    local okGetter, connection = pcall(function()
        if type(eventData.GetPtr) == "function" then
            return eventData:GetPtr("Connection")
        end
        return nil
    end)
    return okGetter and connection or nil
end

---@param options table|nil
---@return table
function CommandRouter.New(options)
    options = options or {}
    return setmetatable({
        _registry = options.registry or PlayerRegistryModule.Default,
        _rateLimiter = options.rateLimiter or RateLimiterModule.Default,
        _operationQueue = options.operationQueue or OperationQueueModule.Default,
        _protocol = options.protocol or NetworkProtocol,
        _decodeJson = options.decodeJson,
        _encodeJson = options.encodeJson,
        _authorize = options.authorize,
        _send = options.send or defaultSend,
        _clock = options.clock or defaultClock,
        _cacheSize = math.max(1, math.floor(options.cacheSize or 128)),
        _cacheTtl = math.max(1, options.cacheTtl or 10 * 60),
        _definitions = {},
        _cache = {},
        _pending = {},
    }, CommandRouter)
end

---@param definition table
---@return table
function CommandRouter:Register(definition)
    assert(type(definition) == "table", "command definition must be a table")
    local name = definition.name or definition.command
    assert(type(name) == "string" and name ~= "", "command definition.name is required")
    assert(type(definition.handler) == "function", "command definition.handler is required")
    assert(self._definitions[name] == nil, "command is already registered: " .. name)

    local stored = {}
    for key, value in pairs(definition) do
        stored[key] = value
    end
    stored.name = name
    if stored.serialized == nil then
        stored.serialized = stored.queue ~= false
    end
    self._definitions[name] = stored
    return stored
end

---@param name string
---@return table|nil
function CommandRouter:GetDefinition(name)
    return self._definitions[name]
end

function CommandRouter:_sendEnvelope(connection, envelope)
    local ok, err = pcall(self._send, connection, self._protocol.EVENTS.RESPONSE, envelope)
    return ok, err
end

function CommandRouter:_makeEnvelope(requestId, command, body)
    return self._protocol.MakeEnvelope(requestId, command, body, self._encodeJson)
end

function CommandRouter:_sendError(connection, requestId, command, err)
    local body = responseBody(false, err)
    local envelope = self:_makeEnvelope(requestId or "", command or "", body)
    if envelope ~= nil then
        self:_sendEnvelope(connection, envelope)
    end
    return false, body
end

function CommandRouter:_pruneCache(uidKey)
    local cache = self._cache[uidKey]
    if cache == nil then
        return
    end
    local now = self._clock()
    local newOrder = {}
    for _, requestId in ipairs(cache.order) do
        local item = cache.byId[requestId]
        if item ~= nil and item.expiresAt > now then
            newOrder[#newOrder + 1] = requestId
        else
            cache.byId[requestId] = nil
        end
    end
    cache.order = newOrder
    if #newOrder == 0 then
        self._cache[uidKey] = nil
    end
end

function CommandRouter:_cacheResponse(uidKey, request, envelope)
    local cache = self._cache[uidKey]
    if cache == nil then
        cache = { byId = {}, order = {} }
        self._cache[uidKey] = cache
    end
    local existing = cache.byId[request.requestId]
    if existing == nil then
        cache.order[#cache.order + 1] = request.requestId
    end
    cache.byId[request.requestId] = {
        command = request.command,
        payloadJson = request.payloadJson,
        envelope = envelope,
        expiresAt = self._clock() + self._cacheTtl,
    }
    while #cache.order > self._cacheSize do
        local oldest = table.remove(cache.order, 1)
        cache.byId[oldest] = nil
    end
end

function CommandRouter:_checkReplay(uidKey, connection, request)
    self:_pruneCache(uidKey)
    local cache = self._cache[uidKey]
    local cached = cache and cache.byId[request.requestId] or nil
    if cached ~= nil then
        if cached.command ~= request.command or cached.payloadJson ~= request.payloadJson then
            return true, self:_sendError(
                connection,
                request.requestId,
                request.command,
                ErrorCodes.Make(ErrorCodes.REQUEST_ID_REUSED)
            )
        end
        self:_sendEnvelope(connection, cached.envelope)
        return true, true, "replayed"
    end

    local pendingByUid = self._pending[uidKey]
    local pending = pendingByUid and pendingByUid[request.requestId] or nil
    if pending ~= nil then
        if pending.command ~= request.command or pending.payloadJson ~= request.payloadJson then
            return true, self:_sendError(
                connection,
                request.requestId,
                request.command,
                ErrorCodes.Make(ErrorCodes.REQUEST_ID_REUSED)
            )
        end
        pending.connections[connection] = true
        return true, true, "in_progress"
    end
    return false, nil
end

function CommandRouter:_setPending(uidKey, request, context)
    local pendingByUid = self._pending[uidKey]
    if pendingByUid == nil then
        pendingByUid = {}
        self._pending[uidKey] = pendingByUid
    end
    pendingByUid[request.requestId] = {
        command = request.command,
        payloadJson = request.payloadJson,
        generation = context.generation,
        connections = { [context.connection] = true },
    }
end

function CommandRouter:_clearPending(uidKey, requestId, expectedGeneration)
    local pendingByUid = self._pending[uidKey]
    if pendingByUid == nil then
        return nil, false
    end
    local pending = pendingByUid[requestId]
    if pending == nil then
        return nil, false
    end
    if expectedGeneration ~= nil and pending.generation ~= expectedGeneration then
        return nil, false
    end
    pendingByUid[requestId] = nil
    if next(pendingByUid) == nil then
        self._pending[uidKey] = nil
    end
    return pending, true
end

function CommandRouter:_checkAuthorization(context, definition, payload)
    if definition.auth == "admin" and context.entry.isAdmin ~= true then
        return false, ErrorCodes.Make(ErrorCodes.FORBIDDEN)
    end

    local function runHook(hook)
        if hook == nil then
            return true, nil
        end
        local ok, allowed, codeOrError, reason = pcall(hook, context, definition, payload)
        if not ok then
            return false, ErrorCodes.Make(ErrorCodes.INTERNAL_ERROR, "Authorization hook failed")
        end
        if allowed ~= true then
            if ErrorCodes.IsError(codeOrError) then
                return false, codeOrError
            end
            local code = type(codeOrError) == "string" and codeOrError or ErrorCodes.FORBIDDEN
            return false, ErrorCodes.Make(code, reason)
        end
        return true, nil
    end

    local globallyAllowed, globalError = runHook(self._authorize)
    if not globallyAllowed then
        return false, globalError
    end
    local commandAllowed, commandError = runHook(definition.authorize)
    if not commandAllowed then
        return false, commandError
    end
    return true, nil
end

function CommandRouter:_execute(definition, context, payload, completed)
    if not self._registry:IsCurrent(context.entry)
        or context.entry.generation ~= context.generation
    then
        completed(false, ErrorCodes.Make(ErrorCodes.STALE_SESSION))
        return
    end
    if not definition.allowBeforeReady and not context.entry.ready then
        completed(false, ErrorCodes.Make(ErrorCodes.NOT_READY))
        return
    end

    local authorized, authError = self:_checkAuthorization(context, definition, payload)
    if not authorized then
        completed(false, authError)
        return
    end

    local finished = false
    local function handlerDone(ok, result)
        if finished then
            return false
        end
        finished = true
        if type(ok) ~= "boolean" then
            result = ok
            ok = true
        end
        completed(ok, result)
        return true
    end

    local callOk, first, second = pcall(definition.handler, context, payload, handlerDone)
    if not callOk then
        handlerDone(false, ErrorCodes.Make(ErrorCodes.INTERNAL_ERROR, tostring(first)))
    elseif not finished then
        if first == CommandRouter.PENDING then
            return
        elseif type(first) == "boolean" then
            handlerDone(first, second)
        elseif first ~= nil then
            if ErrorCodes.IsError(first) then
                handlerDone(false, first)
            else
                handlerDone(true, first)
            end
        elseif definition.async ~= true then
            handlerDone(true, nil)
        end
    end
end

function CommandRouter:_finish(connection, uidKey, request, generation, ok, result, cacheResponse)
    local pending, cleared = self:_clearPending(uidKey, request.requestId, generation)
    local body = responseBody(ok, result)
    local envelope, encodeError = self:_makeEnvelope(request.requestId, request.command, body)
    if envelope == nil then
        return self:_sendError(connection, request.requestId, request.command, encodeError)
    end
    if cacheResponse and cleared then
        self:_cacheResponse(uidKey, request, envelope)
    end
    local recipients = pending and pending.connections or { [connection] = true }
    for recipient in pairs(recipients) do
        self:_sendEnvelope(recipient, envelope)
    end
    return body.ok, body
end

---@param connection any
---@param eventData any
---@return boolean
---@return any
function CommandRouter:Dispatch(connection, eventData)
    local entry = self._registry:GetByConnection(connection)
    if entry == nil or not entry.authenticated then
        return self:_sendError(connection, "", "", ErrorCodes.Make(ErrorCodes.UNAUTHENTICATED))
    end
    if not self._registry:IsCurrent(entry) then
        return self:_sendError(connection, "", "", ErrorCodes.Make(ErrorCodes.STALE_SESSION))
    end

    local validRequest, request, requestError = self._protocol.ReadCommandEvent(eventData)
    if not validRequest then
        return self:_sendError(connection, "", "", requestError)
    end

    local definition = self._definitions[request.command]
    if definition == nil then
        return self:_sendError(
            connection,
            request.requestId,
            request.command,
            ErrorCodes.Make(ErrorCodes.UNKNOWN_COMMAND)
        )
    end
    if not definition.allowBeforeReady and not entry.ready then
        return self:_sendError(
            connection,
            request.requestId,
            request.command,
            ErrorCodes.Make(ErrorCodes.NOT_READY)
        )
    end

    local uidKey = tostring(entry.uid)
    local replayed, replayResult, replayStatus = self:_checkReplay(uidKey, connection, request)
    if replayed then
        return replayResult, replayStatus
    end

    local decoded, payload, decodeError = self._protocol.DecodePayload(request.payloadJson, self._decodeJson)
    if not decoded then
        return self:_sendError(connection, request.requestId, request.command, decodeError)
    end
    local schemaOk, schemaError = self._protocol.ValidatePayload(payload, definition.schema)
    if not schemaOk then
        return self:_sendError(connection, request.requestId, request.command, schemaError)
    end

    local context = {
        uid = entry.uid,
        connection = connection,
        entry = entry,
        generation = entry.generation,
        requestId = request.requestId,
        command = request.command,
        router = self,
    }
    local authorized, authError = self:_checkAuthorization(context, definition, payload)
    if not authorized then
        return self:_sendError(connection, request.requestId, request.command, authError)
    end

    local allowed, retryAfter = self._rateLimiter:Check(
        entry.uid,
        definition.rateKey or request.command,
        definition.rate
    )
    if not allowed then
        return self:_sendError(connection, request.requestId, request.command, ErrorCodes.Make(
            ErrorCodes.RATE_LIMITED,
            nil,
            { retryAfter = retryAfter }
        ))
    end

    self:_setPending(uidKey, request, context)
    local cacheResponse = definition.cacheResponse ~= false
    local function finish(ok, result)
        return self:_finish(connection, uidKey, request, context.generation, ok, result, cacheResponse)
    end

    if definition.serialized then
        local enqueueOk, jobIdOrError = pcall(function()
            return self._operationQueue:Enqueue(entry.uid, {
                async = true,
                run = function(queueDone)
                    self:_execute(definition, context, payload, queueDone)
                    return OperationQueueModule.PENDING
                end,
                onComplete = finish,
            })
        end)
        if not enqueueOk then
            self:_clearPending(uidKey, request.requestId, context.generation)
            return self:_sendError(connection, request.requestId, request.command, ErrorCodes.Make(
                ErrorCodes.SERVER_BUSY,
                tostring(jobIdOrError)
            ))
        end
        return true, { queued = true, jobId = jobIdOrError }
    end

    self:_execute(definition, context, payload, finish)
    return true, { queued = false }
end

---@param eventData any
---@return boolean
---@return any
function CommandRouter:DispatchEvent(eventData)
    return self:Dispatch(extractConnection(eventData), eventData)
end

---@param uid number|string
function CommandRouter:Clear(uid)
    local key = tostring(uid)
    self._cache[key] = nil
    self._pending[key] = nil
    self._rateLimiter:Clear(uid)
end

function CommandRouter:Reset()
    self._cache = {}
    self._pending = {}
    self._definitions = {}
end

local defaultRouter = CommandRouter.New()
local Module = {
    New = CommandRouter.New,
    Class = CommandRouter,
    Default = defaultRouter,
    PENDING = CommandRouter.PENDING,
}

for _, methodName in ipairs({ "Register", "GetDefinition", "Dispatch", "DispatchEvent", "Clear", "Reset" }) do
    Module[methodName] = function(...)
        return defaultRouter[methodName](defaultRouter, ...)
    end
end

return Module
