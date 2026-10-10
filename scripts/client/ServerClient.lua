local Protocol = require("shared.NetworkProtocol")
local ErrorCodes = require("shared.ErrorCodes")
local GameStateSchema = require("shared.GameStateSchema")
local ServerClock = require("client.ServerClock")
local GameEventSchema = require("shared.GameEventSchema")
local GameStateAdapter = require("client.GameStateAdapter")

local ServerClient = {}
local EVENTS = Protocol.EVENTS

---@type Scene
local scene_ = nil
---@type Connection
local connection_ = nil
local started_ = false
local ready_ = false
local syncingConnection_ = nil
local requestCounter_ = 0
local listeners_ = {}
local pending_ = {}
local snapshotAssembly_ = nil
local deferredDeltas_ = {}
local MAX_DEFERRED_DELTAS = 128
local SNAPSHOT_ASSEMBLY_TIMEOUT = 30
local ApplyPreparedDelta
local snapshotRefreshRequested_ = false
local snapshotRefreshGeneration_ = 0
local syncElapsed_ = 0
local syncTimedOut_ = false
local SYNC_TIMEOUT_SECONDS = 30
local REQUEST_TIMEOUT_SECONDS = 30

local function CompletePending(requestId, result)
    local pending = pending_[requestId]
    pending_[requestId] = nil
    if pending and pending.callback then
        local ok, reason = pcall(pending.callback, result)
        if not ok then
            print("[ServerClient] request callback error: " .. tostring(reason))
        end
    end
end

local function FailAllPending(code, reason)
    local requestIds = {}
    for requestId in pairs(pending_) do
        requestIds[#requestIds + 1] = requestId
    end
    for _, requestId in ipairs(requestIds) do
        CompletePending(requestId, {
            ok = false,
            code = code,
            reason = reason,
        })
    end
end

local function UpdatePendingRequests(dt)
    local expired = {}
    for requestId, pending in pairs(pending_) do
        pending.elapsed = pending.elapsed + dt
        if pending.elapsed >= pending.timeout then
            expired[#expired + 1] = requestId
        end
    end
    for _, requestId in ipairs(expired) do
        local pending = pending_[requestId]
        local command = pending and pending.command or "unknown"
        print("[ServerClient] request timeout requestId="
            .. tostring(requestId)
            .. " command="
            .. tostring(command))
        CompletePending(requestId, {
            ok = false,
            code = ErrorCodes.REQUEST_TIMEOUT,
            reason = "服务器响应超时，请稍后重试",
        })
    end
end

local function DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do
        copy[DeepCopy(key, seen)] = DeepCopy(child, seen)
    end
    return copy
end

-- V5 uses `type` as the authoritative event discriminator. The current view
-- adapter still consumes `kind`, so preserve any encounter kind separately
-- and expose the discriminator under both names at the client boundary.
local function PrepareEventsForClient(events)
    if type(events) ~= "table" then return nil, "events must be a table" end
    local prepared = {}
    for index, source in ipairs(events) do
        if type(source) ~= "table" then
            return nil, string.format("events[%d] must be a table", index)
        end
        local value = DeepCopy(source)
        local eventType = value.type or value.kind
        if type(eventType) ~= "string" or eventType == "" then
            return nil, string.format("events[%d] has no event type", index)
        end
        value.type = eventType
        if value.kind ~= nil and value.kind ~= eventType and value.encounterKind == nil then
            value.encounterKind = value.kind
        end
        value.kind = eventType
        prepared[#prepared + 1] = value
    end
    local valid, reason = GameEventSchema.ValidateList(prepared, "$events")
    if not valid then return nil, reason end
    return prepared
end

local function Emit(name, payload)
    local handlers = listeners_[name]
    if not handlers then return end
    local copy = {}
    for _, handler in ipairs(handlers) do copy[#copy + 1] = handler end
    for _, handler in ipairs(copy) do
        local ok, reason = pcall(handler, payload)
        if not ok then print("[ServerClient] listener error: " .. tostring(reason)) end
    end
end

local function DecodePayload(eventData)
    local encoded = eventData[Protocol.FIELDS.PAYLOAD_JSON]:GetString()
    if encoded == "" then return {} end
    local ok, value = pcall(cjson.decode, encoded)
    if not ok or type(value) ~= "table" then
        return nil, "invalid server JSON"
    end
    return value
end

local function NewRequestId()
    requestCounter_ = requestCounter_ + 1
    return string.format("c-%d-%d", os.time(), requestCounter_)
end

local function SendReady()
    local connection = connection_
    if not connection then return false, "server connection unavailable" end

    local encoded, payloadJson = pcall(cjson.encode, { protocolVersion = Protocol.VERSION })
    if not encoded then return false, "ready payload is not JSON encodable" end

    local data = VariantMap()
    data[Protocol.FIELDS.REQUEST_ID] = Variant(NewRequestId())
    data[Protocol.FIELDS.PAYLOAD_JSON] = Variant(payloadJson)
    local sent, reason = pcall(function()
        connection:SendRemoteEvent(EVENTS.CLIENT_READY, true, data)
    end)
    if not sent then return false, tostring(reason) end
    return true
end

local function HandleResponse(eventType, eventData)
    if not started_ or not connection_ then return end
    local payload, reason = DecodePayload(eventData)
    if not payload then
        Emit("error", { code = ErrorCodes.INVALID_PAYLOAD, reason = reason })
        return
    end
    local requestId = payload.requestId or eventData[Protocol.FIELDS.REQUEST_ID]:GetString()
    CompletePending(requestId, payload)
    Emit("response", payload)
end

local function DrainDeferredDeltas()
    local deltas = deferredDeltas_
    deferredDeltas_ = {}
    table.sort(deltas, function(a, b) return a.revision < b.revision end)
    for _, delta in ipairs(deltas) do ApplyPreparedDelta(delta) end
end

local function ApplyCompleteSnapshot(snapshot, events)
    local valid, validationError = GameStateSchema.ValidateSnapshot(snapshot)
    if not valid then
        Emit("error", {
            code = ErrorCodes.INVALID_STATE,
            reason = validationError and validationError.reason or "invalid assembled snapshot",
            path = validationError and validationError.details and validationError.details.path or nil,
        })
        return false
    end
    local currentRevision = GameStateAdapter.GetRevision()
    ServerClock.Sync(snapshot.serverTime)
    local alreadyReady = GameStateAdapter.GetViewState().connectionState == "ready"
    if snapshot.revision and alreadyReady and (snapshot.revision < currentRevision
        or (snapshot.revision == currentRevision and not snapshotRefreshRequested_)) then
        print("[ServerClient] ignored stale snapshot revision=" .. tostring(snapshot.revision)
            .. " current=" .. tostring(currentRevision))
        return false
    end
    -- An explicitly requested equal-revision snapshot repairs presentation/request
    -- state. Its rewards and combat events were already consumed; do not replay them.
    local snapshotEvents = alreadyReady and snapshot.revision == currentRevision and {} or (events or {})
    local preparedEvents, eventReason = PrepareEventsForClient(snapshotEvents)
    if not preparedEvents then
        Emit("error", { code = ErrorCodes.INVALID_STATE, reason = eventReason })
        return false
    end
    local ok, applyReason = GameStateAdapter.ApplySnapshot(snapshot)
    if not ok then
        Emit("error", { code = ErrorCodes.INVALID_STATE, reason = applyReason })
        return false
    end
    GameStateAdapter.ApplySnapshotEvents(preparedEvents)
    ready_ = true
    syncingConnection_ = nil
    snapshotAssembly_ = nil
    snapshotRefreshRequested_ = false
    GameStateAdapter.SetConnectionState("ready")
    Emit("snapshot", GameStateAdapter.GetViewState())
    if #preparedEvents > 0 then
        Emit("delta", { state = GameStateAdapter.GetViewState(), events = preparedEvents })
    end
    -- Deltas received during a chunk transfer depend on this full state.
    -- Apply death/drop events first, then subsequent revisions, exactly once.
    DrainDeferredDeltas()
    Emit("ready", GameStateAdapter.GetViewState())
    return true
end

local function HandleSnapshot(eventType, eventData)
    if not started_ or not connection_ then return end
    local payload, reason = DecodePayload(eventData)
    if not payload then
        Emit("error", { code = ErrorCodes.INVALID_PAYLOAD, reason = reason })
        return
    end
    if payload.chunkCount ~= nil then
        local transferId = payload.transferId
        local revision = payload.revision
        local chunkIndex = payload.chunkIndex
        local chunkCount = payload.chunkCount
        if type(transferId) ~= "string"
            or transferId == ""
            or type(revision) ~= "number"
            or revision < 0
            or revision ~= math.floor(revision)
            or type(chunkIndex) ~= "number"
            or chunkIndex < 1
            or chunkIndex ~= math.floor(chunkIndex)
            or type(chunkCount) ~= "number"
            or chunkCount < 1
            or chunkCount ~= math.floor(chunkCount)
            or chunkIndex > chunkCount
            or type(payload.inventory) ~= "table"
        then
            Emit("error", { code = ErrorCodes.INVALID_PAYLOAD, reason = "invalid snapshot chunk metadata" })
            return
        end
        local currentRevision = GameStateAdapter.GetRevision()
        if ready_ and (revision < currentRevision
            or revision == currentRevision and not snapshotRefreshRequested_) then return end
        if snapshotAssembly_ and revision < snapshotAssembly_.revision then return end
        if not snapshotAssembly_
            or snapshotAssembly_.transferId ~= transferId
            or snapshotAssembly_.revision ~= revision
        then
            snapshotAssembly_ = {
                transferId = transferId,
                revision = revision,
                chunkCount = chunkCount,
                received = {},
                chunks = {},
                snapshot = nil,
                events = {},
                elapsed = 0,
            }
        end
        local assembly = snapshotAssembly_
        if assembly.chunkCount ~= chunkCount then
            Emit("error", { code = ErrorCodes.INVALID_PAYLOAD, reason = "snapshot chunk count changed" })
            snapshotAssembly_ = nil
            return
        end
        if payload.snapshot then
            if chunkIndex ~= 1 or assembly.snapshot then
                Emit("error", { code = ErrorCodes.INVALID_PAYLOAD, reason = "invalid snapshot metadata chunk" })
                return
            end
            if type(payload.events) ~= "table" then
                Emit("error", { code = ErrorCodes.INVALID_PAYLOAD, reason = "invalid snapshot events" })
                return
            end
            assembly.snapshot = payload.snapshot
            assembly.events = payload.events
        end
        if not assembly.received[chunkIndex] then
            assembly.received[chunkIndex] = true
            assembly.chunks[chunkIndex] = payload.inventory
        end
        local receivedCount = 0
        for index = 1, assembly.chunkCount do
            if assembly.received[index] then receivedCount = receivedCount + 1 end
        end
        Emit("snapshotProgress", { received = receivedCount, total = assembly.chunkCount })
        if receivedCount < assembly.chunkCount or not assembly.snapshot then return end
        local inventory = {}
        for index = 1, assembly.chunkCount do
            if not assembly.received[index] then return end
            for _, item in ipairs(assembly.chunks[index]) do inventory[#inventory + 1] = item end
        end
        assembly.snapshot.inventory = inventory
        ApplyCompleteSnapshot(assembly.snapshot, assembly.events)
        return
    end
    ApplyCompleteSnapshot(payload.snapshot or payload, payload.events or {})
end

ApplyPreparedDelta = function(delta)
    if delta.revision <= GameStateAdapter.GetRevision() then return end
    ServerClock.Sync(delta.serverTime)
    local ok, applyReason = GameStateAdapter.ApplyDelta(delta)
    if not ok then
        Emit("error", { code = ErrorCodes.INVALID_STATE, reason = applyReason })
        ServerClient.RequestSnapshot()
        return
    end
    Emit("delta", { state = GameStateAdapter.GetViewState(), events = delta.events or {} })
end

local function HandleDelta(eventType, eventData)
    if not started_ or not connection_ or not ready_ then return end
    local payload, reason = DecodePayload(eventData)
    if not payload then
        Emit("error", { code = ErrorCodes.INVALID_PAYLOAD, reason = reason })
        return
    end
    local delta = payload.delta or payload
    local valid, validationError = GameStateSchema.ValidateDelta(delta)
    if not valid then
        Emit("error", {
            code = ErrorCodes.INVALID_STATE,
            reason = validationError and validationError.reason or "invalid delta",
            path = validationError and validationError.details and validationError.details.path or nil,
        })
        ServerClient.RequestSnapshot()
        return
    end
    if delta.revision <= GameStateAdapter.GetRevision() then return end
    local preparedEvents, eventReason = PrepareEventsForClient(delta.events or {})
    if not preparedEvents then
        Emit("error", { code = ErrorCodes.INVALID_STATE, reason = eventReason })
        ServerClient.RequestSnapshot()
        return
    end
    delta.events = preparedEvents
    if snapshotAssembly_ then
        -- Advancing the revision now would make the still-incomplete death
        -- snapshot look stale and strand the client on a zero-HP monster.
        deferredDeltas_[#deferredDeltas_ + 1] = delta
        if #deferredDeltas_ >= MAX_DEFERRED_DELTAS then
            snapshotAssembly_ = nil
            deferredDeltas_ = {}
            print("[ServerClient] snapshot delta backlog exceeded; requesting fresh state")
            ServerClient.RequestSnapshot()
        end
        return
    end
    ApplyPreparedDelta(delta)
end

local function HandleStatus(eventType, eventData)
    if not started_ or not connection_ then return end
    local payload = DecodePayload(eventData) or { state = "error" }
    local state = payload.state
    if state then GameStateAdapter.SetConnectionState(state) end
    if state == "rejected" or state == "error" or state == "banned" then
        Emit("error", {
            code = payload.code or ErrorCodes.OPERATION_FAILED,
            reason = payload.reason or "常驻服连接失败",
        })
        return
    end
    Emit("status", payload)
    if type(payload.adminResult) == "table" then
        Emit("adminResult", payload.adminResult)
    end
end

---@param connection Connection
---@return boolean
---@return string|nil
local function BeginSync(connection)
    if not started_ then return false, "client is stopped" end
    if not connection then return false, "server connection unavailable" end
    if syncingConnection_ == connection and connection_ == connection then
        return true
    end

    ready_ = false
    syncElapsed_ = 0
    syncTimedOut_ = false
    snapshotAssembly_ = nil
    deferredDeltas_ = {}
    FailAllPending(ErrorCodes.NOT_READY, "连接已重置，请重新操作")
    snapshotRefreshRequested_ = false
    pending_ = {}
    connection_ = connection
    syncingConnection_ = connection
    connection_.scene = scene_
    GameStateAdapter.SetConnectionState("syncing")
    Emit("status", {
        state = "syncing",
        code = ErrorCodes.OK,
        reason = "server connected; waiting for authoritative snapshot",
    })

    local sent, reason = SendReady()
    if not sent then
        if syncingConnection_ == connection then syncingConnection_ = nil end
        if connection_ == connection then connection_ = nil end
        GameStateAdapter.SetConnectionState("disconnected")
        Emit("error", { code = ErrorCodes.NOT_READY, reason = reason })
        return false, reason
    end

    Emit("connected", GameStateAdapter.GetViewState())
    return true
end

---@param eventType StringHash|string
---@param eventData ServerConnectedEventData
local function HandleConnected(eventType, eventData)
    if not started_ then return end
    local connection = network:GetServerConnection()
    if not connection then
        ready_ = false
        connection_ = nil
        FailAllPending(ErrorCodes.NOT_READY, "常驻服连接不可用，请重新操作")
        pending_ = {}
        GameStateAdapter.SetConnectionState("disconnected")
        Emit("error", { code = ErrorCodes.NOT_READY, reason = "server connected without an available connection" })
        return
    end
    BeginSync(connection)
end

---@param eventType StringHash|string
---@param eventData ServerDisconnectedEventData
local function HandleDisconnected(eventType, eventData)
    if not started_ then return end
    ready_ = false
    syncElapsed_ = 0
    syncTimedOut_ = false
    snapshotAssembly_ = nil
    deferredDeltas_ = {}
    syncingConnection_ = nil
    snapshotRefreshRequested_ = false
    connection_ = nil
    FailAllPending(ErrorCodes.NOT_READY, "与常驻服的连接已断开，请重新操作")
    pending_ = {}
    GameStateAdapter.SetConnectionState("disconnected")
    Emit("disconnected", GameStateAdapter.GetViewState())
end

function ServerClient.Update(dt)
    if not started_ then return end
    dt = math.max(0, dt or 0)
    UpdatePendingRequests(dt)
    if snapshotAssembly_ then
        snapshotAssembly_.elapsed = snapshotAssembly_.elapsed + dt
        if snapshotAssembly_.elapsed >= SNAPSHOT_ASSEMBLY_TIMEOUT then
            snapshotAssembly_ = nil
            deferredDeltas_ = {}
            print("[ServerClient] incomplete snapshot timed out; requesting fresh state")
            if ready_ then ServerClient.RequestSnapshot() end
        end
    end
    if ready_ then return end
    syncElapsed_ = syncElapsed_ + dt
    if syncTimedOut_ or syncElapsed_ < SYNC_TIMEOUT_SECONDS then return end
    syncTimedOut_ = true
    ready_ = false
    snapshotAssembly_ = nil
    GameStateAdapter.SetConnectionState("error")
    Emit("error", {
        code = ErrorCodes.NOT_READY,
        reason = "连接常驻服超时，请检查常驻服状态后重试",
    })
end

function ServerClient.Start()
    if started_ then
        if not connection_ then
            local connection = network:GetServerConnection()
            if connection then return BeginSync(connection) end
        end
        return true
    end
    started_ = true
    ready_ = false
    syncElapsed_ = 0
    syncTimedOut_ = false
    snapshotAssembly_ = nil
    deferredDeltas_ = {}
    pending_ = {}
    GameStateAdapter.Reset()
    GameStateAdapter.SetConnectionState("syncing")

    if not scene_ then
        scene_ = Scene()
        scene_:CreateComponent("Octree", LOCAL)
    end

    Protocol.RegisterClientEvents()
    SubscribeToEvent(EVENTS.RESPONSE, HandleResponse)
    SubscribeToEvent(EVENTS.SNAPSHOT, HandleSnapshot)
    SubscribeToEvent(EVENTS.DELTA, HandleDelta)
    SubscribeToEvent(EVENTS.STATUS, HandleStatus)
    SubscribeToEvent("ServerReady", HandleConnected)
    SubscribeToEvent("ServerConnected", HandleConnected)
    SubscribeToEvent("ServerDisconnected", HandleDisconnected)

    local connection = network:GetServerConnection()
    if connection then return BeginSync(connection) end

    connection_ = nil
    Emit("status", {
        state = "syncing",
        code = ErrorCodes.OK,
        reason = "waiting for server connection",
    })
    return true
end

function ServerClient.Stop()
    if not started_ then return end
    UnsubscribeFromEvent(EVENTS.RESPONSE)
    UnsubscribeFromEvent(EVENTS.SNAPSHOT)
    UnsubscribeFromEvent(EVENTS.DELTA)
    UnsubscribeFromEvent(EVENTS.STATUS)
    UnsubscribeFromEvent("ServerReady")
    UnsubscribeFromEvent("ServerConnected")
    UnsubscribeFromEvent("ServerDisconnected")
    pending_ = {}
    snapshotAssembly_ = nil
    deferredDeltas_ = {}
    listeners_ = {}
    snapshotRefreshRequested_ = false
    syncingConnection_ = nil
    connection_ = nil
    if scene_ then scene_:Dispose(); scene_ = nil end
    ready_ = false
    started_ = false
end

function ServerClient.ClearPresentationRequests()
    pending_ = {}
    listeners_ = {}
end
function ServerClient.RetryConnection()
    local connection = network:GetServerConnection()
    if connection then return BeginSync(connection) end
    return false
end
function ServerClient.IsReady()
    return ready_ and connection_ ~= nil
end

function ServerClient.On(name, handler)
    assert(type(handler) == "function", "handler must be a function")
    listeners_[name] = listeners_[name] or {}
    local handlers = listeners_[name]
    handlers[#handlers + 1] = handler
    return function()
        for index = #handlers, 1, -1 do
            if handlers[index] == handler then table.remove(handlers, index) end
        end
    end
end

function ServerClient.Send(command, payload, callback)
    if not connection_ or not ready_ then
        local result = { ok = false, code = ErrorCodes.NOT_READY, reason = "server snapshot not ready" }
        if callback then callback(result) end
        return nil, result.reason
    end
    local requestId = NewRequestId()
    local ok, payloadJson = pcall(cjson.encode, payload or {})
    if not ok then
        local result = {
            ok = false,
            code = ErrorCodes.INVALID_JSON,
            reason = "请求数据编码失败",
        }
        if callback then callback(result) end
        return nil, result.reason
    end
    if #payloadJson > Protocol.MAX_PAYLOAD_BYTES then
        local result = {
            ok = false,
            code = ErrorCodes.PAYLOAD_TOO_LARGE,
            reason = "请求数据超过大小限制",
        }
        if callback then callback(result) end
        return nil, result.reason
    end

    local data = VariantMap()
    data[Protocol.FIELDS.REQUEST_ID] = Variant(requestId)
    data[Protocol.FIELDS.COMMAND] = Variant(command)
    data[Protocol.FIELDS.PAYLOAD_JSON] = Variant(payloadJson)
    if callback then pending_[requestId] = {
        callback = callback,
        command = command,
        elapsed = 0,
        timeout = REQUEST_TIMEOUT_SECONDS,
    } end
    local sent, sendReason = pcall(function()
        connection_:SendRemoteEvent(EVENTS.COMMAND, true, data)
    end)
    if not sent then
        pending_[requestId] = nil
        local result = {
            ok = false,
            code = ErrorCodes.OPERATION_FAILED,
            reason = "failed to send server command: " .. tostring(sendReason),
        }
        if callback then callback(result) end
        return nil, result.reason
    end
    return requestId
end

function ServerClient.RequestSnapshot(callback)
    snapshotRefreshGeneration_ = snapshotRefreshGeneration_ + 1
    local generation = snapshotRefreshGeneration_
    snapshotRefreshRequested_ = true
    return ServerClient.Send("Game.RequestSnapshot", {}, function(response)
        if generation == snapshotRefreshGeneration_ and (not response or not response.ok) then
            snapshotRefreshRequested_ = false
        end
        if callback then callback(response) end
    end)
end
function ServerClient.WishWithTicket(count, callback)
    if type(count) == "function" then
        callback = count
        count = 1
    end
    local drawCount = math.floor(tonumber(count) or 1)
    if drawCount ~= 10 then drawCount = 1 end
    return ServerClient.Send("WishPool.WishWithTicket", { count = drawCount }, callback)
end
-- 广告许愿已下线；保留空实现避免旧调用点报错。
function ServerClient.WishWithAd(callback)
    if callback then
        callback({
            ok = false,
            code = "WISH_AD_DISABLED",
            reason = "广告许愿已下线，请使用许愿券",
        })
    end
    return nil
end
function ServerClient.OpenWishJar(jarId, count, callback)
    local payload = { jarId = tostring(jarId) }
    if count and tonumber(count) then
        payload.count = math.max(1, math.min(6, math.floor(tonumber(count))))
    end
    return ServerClient.Send("WishPool.OpenJar", payload, callback)
end
function ServerClient.RecycleWishJar(jarId, count, callback)
    return ServerClient.Send("WishPool.RecycleJar", {
        jarId = tostring(jarId), count = math.max(1, math.min(6, math.floor(tonumber(count) or 1))),
    }, callback)
end
function ServerClient.ClaimDailyVip(callback) return ServerClient.Send("Game.ClaimDailyVip", {}, callback) end
function ServerClient.ClaimDailyAdVip(callback) return ServerClient.Send("Game.ClaimDailyAdVip", {}, callback) end
function ServerClient.GetLeaderboard(callback, board)
    local payload = {}
    if board and board ~= "power" then payload.board = tostring(board) end
    return ServerClient.Send("Leaderboard.GetTop", payload, callback)
end
function ServerClient.GetLeaderboardDetail(userId, callback)
    return ServerClient.Send("Leaderboard.GetDetail", { userId = tostring(userId) }, callback)
end
function ServerClient.SetTrashTalk(index, callback)
    return ServerClient.Send("Leaderboard.SetTrashTalk", { index = math.floor(tonumber(index) or 0) }, callback)
end
function ServerClient.MailList(scope, callback)
    return ServerClient.Send("Mail.List", { scope = scope == "favorite" and "favorite" or "all" }, callback)
end
function ServerClient.MailDetail(mailId, callback)
    return ServerClient.Send("Mail.Detail", { mailId = tostring(mailId) }, callback)
end
function ServerClient.MailRead(mailId, callback)
    return ServerClient.Send("Mail.Read", { mailId = tostring(mailId) }, callback)
end
function ServerClient.MailClaim(mailId, callback)
    return ServerClient.Send("Mail.Claim", { mailId = tostring(mailId) }, callback)
end
function ServerClient.MailClaimAll(callback)
    return ServerClient.Send("Mail.ClaimAll", {}, callback)
end
function ServerClient.MailFavorite(mailId, favorite, callback)
    return ServerClient.Send(favorite and "Mail.Favorite" or "Mail.Unfavorite", { mailId = tostring(mailId) }, callback)
end
function ServerClient.MailDelete(mailId, callback)
    return ServerClient.Send("Mail.Delete", { mailId = tostring(mailId) }, callback)
end
function ServerClient.MailDeleteFavorited(mailId, callback)
    return ServerClient.Send("Mail.DeleteFavorited", { mailId = tostring(mailId) }, callback)
end
function ServerClient.MailDeleteRead(callback)
    return ServerClient.Send("Mail.DeleteRead", {}, callback)
end
-- GM 邮件
function ServerClient.AdminSendMail(payload, callback)
    return ServerClient.Send("Admin.SendMail", payload, callback)
end
function ServerClient.AdminSendBroadcastMail(payload, callback)
    return ServerClient.Send("Admin.SendBroadcastMail", payload, callback)
end
function ServerClient.AdminMailList(targetUid, callback)
    return ServerClient.Send("Admin.MailList", { targetUid = tostring(targetUid) }, callback)
end
function ServerClient.AdminMailForceExpire(targetUid, mailId, callback)
    return ServerClient.Send("Admin.MailForceExpire", { targetUid = tostring(targetUid), mailId = tostring(mailId) }, callback)
end
function ServerClient.AdminMailCleanTest(targetUid, callback)
    return ServerClient.Send("Admin.MailCleanTest", { targetUid = tostring(targetUid) }, callback)
end
function ServerClient.ResolveEvent(eventId, action, callback)
    return ServerClient.Send("Game.ResolveEvent", { eventId = eventId, action = action }, callback)
end
function ServerClient.AutoRun(enabled, callback) return ServerClient.Send("Game.SetAutoRun", { enabled = enabled }, callback) end
function ServerClient.EnterEncounter(routeId, encounterId, room, callback)
    return ServerClient.Send("Game.EnterEncounter", {
        routeId = routeId,
        encounterId = encounterId,
        room = room,
    }, callback)
end
function ServerClient.SetInteractionMode(mode, callback)
    return ServerClient.Send("Game.SetInteractionMode", { mode = mode }, callback)
end
function ServerClient.SetAutomationPolicy(policy, callback)
    return ServerClient.Send("Game.SetAutomationPolicy", policy, callback)
end
function ServerClient.DecideEquip(action, itemId, callback)
    local payload = { action = action }
    if itemId ~= nil then payload.itemId = itemId end
    return ServerClient.Send("Game.DecideEquip", payload, callback)
end
function ServerClient.UndoEquip(callback) return ServerClient.Send("Game.UndoEquip", {}, callback) end
function ServerClient.CampaignPlayStage(stageId, action, callback)
    local resolved = "complete"
    if action == "challenge" or action == "sweep" or action == "echo" then
        resolved = action
    end
    return ServerClient.Send("Game.CampaignPlayStage", {
        stageId = tostring(stageId),
        action = resolved,
    }, callback)
end
function ServerClient.AdvanceStory(action, storyId, lineIndex, callback)
    local payload = { action = action }
    if storyId ~= nil then payload.storyId = storyId end
    if lineIndex ~= nil then payload.lineIndex = lineIndex end
    return ServerClient.Send("Game.AdvanceStory", payload, callback)
end
function ServerClient.AcknowledgeRules(ruleId, callback)
    return ServerClient.Send("Game.AcknowledgeRules", { ruleId = ruleId }, callback)
end
function ServerClient.ClaimAid(callback) return ServerClient.Send("Game.ClaimAid", {}, callback) end
function ServerClient.ClaimLootStash(callback) return ServerClient.Send("Game.ClaimLootStash", {}, callback) end
function ServerClient.ExpandInventoryByAd(callback)
    return ServerClient.Send("Game.ExpandInventoryByAd", {}, callback)
end
function ServerClient.DispositionPreview(mode, candidateIds, callback)
    return ServerClient.Send("Game.DispositionPreview", {
        mode = mode,
        candidateIds = candidateIds,
    }, callback)
end
function ServerClient.SellPreview(itemId, callback)
    return ServerClient.Send("Game.SellPreview", { itemId = itemId }, callback)
end
function ServerClient.Sell(maxRank, candidateIds, callback)
    return ServerClient.Send("Game.Sell", { maxRank = maxRank, candidateIds = candidateIds }, callback)
end
function ServerClient.Equip(itemId, callback) return ServerClient.Send("Game.Equip", { itemId = itemId }, callback) end
function ServerClient.Unequip(slot, callback) return ServerClient.Send("Game.Unequip", { slot = slot }, callback) end
function ServerClient.AutoEquip(callback) return ServerClient.Send("Game.AutoEquip", {}, callback) end
function ServerClient.ResetTutorialLoadout(callback)
    return ServerClient.Send("Game.ResetTutorialLoadout", {}, callback)
end
function ServerClient.CompleteTutorial(callback)
    return ServerClient.Send("Game.CompleteTutorial", {}, callback)
end
function ServerClient.DecomposePreview(itemId, callback)
    return ServerClient.Send("Game.DecomposePreview", { itemId = itemId }, callback)
end
function ServerClient.Decompose(maxRank, candidateIds, callback)
    return ServerClient.Send("Game.Decompose", { maxRank = maxRank, candidateIds = candidateIds }, callback)
end
function ServerClient.SetEquipmentLock(itemId, locked, callback)
    return ServerClient.Send("Game.SetEquipmentLock", { itemId = itemId, locked = locked }, callback)
end
function ServerClient.SetInventoryPolicy(policy, callback)
    return ServerClient.Send("Game.SetInventoryPolicy", policy, callback)
end
function ServerClient.StrengthenPreview(slot, callback)
    return ServerClient.Send("Game.StrengthenPreview", { slot = slot }, callback)
end
function ServerClient.Strengthen(slot, callback) return ServerClient.Send("Game.Strengthen", { slot = slot }, callback) end
function ServerClient.StarPreview(slot, callback)
    return ServerClient.Send("Game.StarPreview", { slot = slot }, callback)
end
function ServerClient.Star(slot, materialItemId, callback)
    return ServerClient.Send("Game.Star", { slot = slot, materialItemId = materialItemId }, callback)
end
function ServerClient.ClaimRewardAdExtra(rewardId, callback)
    return ServerClient.Send(
        "Reward.ClaimAdExtra",
        { rewardId = rewardId },
        callback
    )
end
function ServerClient.ClaimRewardAdExtras(rewardIds, callback)
    return ServerClient.Send("Reward.ClaimAdExtras", { rewardIds = rewardIds }, callback)
end
function ServerClient.CampaignTrial(stageId, action, trialId, page, callback)
    return ServerClient.Send("Game.CampaignTrial", {
        stageId = stageId, action = action, trialId = trialId, page = page,
    }, callback)
end
function ServerClient.ListAdGifts(callback)
    return ServerClient.Send("Reward.ListGifts", {}, callback)
end
function ServerClient.PrepareAdGift(kind, callback)
    return ServerClient.Send("Reward.PrepareGift", { giftKind = kind }, callback)
end
function ServerClient.ClaimAdGift(token, callback)
    return ServerClient.Send("Reward.ClaimGift", { token = token }, callback)
end
function ServerClient.ClaimExclusiveAdGift(giftId, callback)
    return ServerClient.Send(
        "Reward.ClaimExclusiveAdGift",
        { giftId = giftId },
        callback
    )
end
function ServerClient.PreviewOffline(callback)
    return ServerClient.Send("Game.PreviewOffline", {}, callback)
end
function ServerClient.CollectOffline(quoteToken, callback)
    return ServerClient.Send(
        "Game.CollectOffline",
        { quoteToken = quoteToken },
        callback
    )
end
function ServerClient.AdminQuery(uid, callback) return ServerClient.Send("Admin.QueryPlayer", { targetUid = tostring(uid) }, callback) end
function ServerClient.AdminQueryByName(name, callback)
    return ServerClient.Send("Admin.QueryByName", { name = tostring(name) }, callback)
end
function ServerClient.AdminGrantCurrency(uid, currency, amount, reason, callback)
    return ServerClient.Send("Admin.GrantCurrency", { targetUid = tostring(uid), currency = currency, amount = amount, reason = reason }, callback)
end
function ServerClient.AdminGrantEquipment(uid, slot, rarity, reason, callback)
    return ServerClient.Send("Admin.GrantEquipment", { targetUid = tostring(uid), slot = slot, rarity = rarity, reason = reason }, callback)
end
function ServerClient.AdminAdjustProgress(uid, floor, position, reason, callback)
    return ServerClient.Send("Admin.AdjustProgress", { targetUid = tostring(uid), floor = floor, position = position, reason = reason }, callback)
end
function ServerClient.AdminBan(uid, reason, callback) return ServerClient.Send("Admin.Ban", { targetUid = tostring(uid), reason = reason }, callback) end
function ServerClient.AdminUnban(uid, reason, callback) return ServerClient.Send("Admin.Unban", { targetUid = tostring(uid), reason = reason }, callback) end
function ServerClient.AdminAudit(callback) return ServerClient.Send("Admin.GetAudit", {}, callback) end
function ServerClient.AdminSetAdFree(uid, enabled, reason, callback)
    return ServerClient.Send("Admin.SetAdFree", { targetUid = tostring(uid), enabled = enabled, reason = reason }, callback)
end
function ServerClient.VerifyAdFree(callback) return ServerClient.Send("Reward.VerifyAdFree", {}, callback) end
function ServerClient.AdminMailDeliveryStatus(uid, callback, mailId)
    return ServerClient.Send("Admin.MailDeliveryStatus", { targetUid = tostring(uid), mailId = mailId }, callback)
end

-- 市场 -----------------------------------------------------------------------
function ServerClient.MarketBrowse(query, callback)
    local payload = {}
    if query then
        if query.rarity ~= nil then payload.rarity = query.rarity end
        if query.slot ~= nil then payload.slot = query.slot end
        if query.limit ~= nil then payload.limit = query.limit end
    end
    return ServerClient.Send("Market.Browse", payload, callback)
end
function ServerClient.MarketList(itemId, price, callback)
    return ServerClient.Send("Market.List", { itemId = itemId, price = price }, callback)
end
function ServerClient.MarketCancel(itemId, callback)
    return ServerClient.Send("Market.Cancel", { itemId = itemId }, callback)
end
function ServerClient.MarketBuy(listing, callback)
    return ServerClient.Send("Market.Buy", {
        itemId = listing.itemId,
        rarity = listing.rarity,
        slot = listing.slot,
        expectedPrice = listing.price,
    }, callback)
end
function ServerClient.MarketMailbox(callback) return ServerClient.Send("Market.Mailbox", {}, callback) end
function ServerClient.MarketCollect(callback) return ServerClient.Send("Market.Collect", {}, callback) end

return ServerClient
