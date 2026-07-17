local Protocol = require("shared.NetworkProtocol")
local ErrorCodes = require("shared.ErrorCodes")
local GameStateSchema = require("shared.GameStateSchema")
local ServerConfig = require("server.ServerConfig")
local PlayerRegistry = require("server.core.PlayerRegistry")
local AdmissionGuard = require("server.core.AdmissionGuard")
local RateLimiter = require("server.core.RateLimiter")
local CommandRouter = require("server.core.CommandRouter")
local OperationQueue = require("server.core.OperationQueue")
local AdminPolicy = require("server.core.AdminPolicy")
local ServerCloudGateway = require("server.dao.ServerCloudGateway")
local PlayerProfileRepository = require("server.repositories.PlayerProfileRepository")
local PlayerProfileService = require("server.services.PlayerProfileService")
local IdleRuntimeService = require("server.services.IdleRuntimeService")
local AdminService = require("server.services.AdminService")
local GameCommands = require("server.commands.GameCommands")
local AdminCommands = require("server.commands.AdminCommands")
local GameEngine = require("server.domain.GameEngine")

---@type Scene
local scene_ = nil
local registry_ = nil
local admission_ = nil
local operationQueue_ = nil
local router_ = nil
local gateway_ = nil
local repository_ = nil
local profileService_ = nil
local idleService_ = nil
local adminService_ = nil
local adminPolicy_ = nil

local function SeedAuthoritativeRandom()
    local seed = os.time()
    local timeObject = _G["time"]
    if timeObject and type(timeObject.GetSystemTime) == "function" then
        local ok, systemTime = pcall(timeObject.GetSystemTime, timeObject)
        if ok and type(systemTime) == "number" then
            seed = seed + math.floor(systemTime)
        end
    end
    for index = 1, #tostring(scene_) do
        seed = (seed * 131 + string.byte(tostring(scene_), index)) % 2147483647
    end
    math.randomseed(seed)
    math.random()
    math.random()
end

local function ConnectionFrom(eventData)
    if not eventData then return nil end
    local ok, connection = pcall(function()
        return eventData["Connection"]:GetPtr("Connection")
    end)
    if ok then return connection end
    ok, connection = pcall(function() return eventData:GetPtr("Connection", "Connection") end)
    return ok and connection or nil
end

local function SendPayload(connection, eventName, command, payload, requestId)
    if not connection then return false end
    local envelope, encodeError = Protocol.MakeEnvelope(requestId or "", command or "", payload, cjson.encode)
    if not envelope then
        print("[Server] JSON envelope error: " .. tostring(encodeError and encodeError.reason))
        return false
    end
    local ok, reason = pcall(function()
        connection:SendRemoteEvent(eventName, true, Protocol.ToVariantMap(envelope))
    end)
    if not ok then print("[Server] send failed: " .. tostring(reason)) end
    return ok
end

local function SendStatus(connection, state, code, reason, extra)
    local payload = extra or {}
    payload.state = state
    payload.code = code or ErrorCodes.OK
    payload.reason = reason or ""
    return SendPayload(connection, Protocol.EVENTS.STATUS, "Status", payload)
end

local function CurrentEntry(userId)
    local entry = registry_:Get(userId)
    if entry and registry_:IsCurrent(entry) then return entry end
    return nil
end

local function SendSnapshot(userId)
    local entry = CurrentEntry(userId)
    local state = profileService_:GetState(userId)
    if not entry or not state then return nil end
    local snapshot = GameStateSchema.BuildSnapshot(state, {
        serverTime = os.time(),
        status = "ready",
        isAdmin = adminPolicy_:IsAdmin(userId),
        stats = state.stats,
        itemPower = GameEngine.GetItemPower,
    })
    snapshot.inventoryCapacity = ServerConfig.INVENTORY_CAP
    snapshot.logs = snapshot.logs or {
        "权威存档已同步，所有玩法结算由服务器执行。",
        "已载入12部位装备体系与五套史诗套装。",
    }
    snapshot.recentDamage = snapshot.recentDamage or "等待战斗结算"
    local valid, validationError = GameStateSchema.ValidateSnapshot(snapshot)
    if not valid then
        SendStatus(entry.connection, "error", validationError.code, validationError.reason)
        return nil
    end
    SendPayload(entry.connection, Protocol.EVENTS.SNAPSHOT, "GameSnapshot", { snapshot = snapshot })
    return snapshot
end

local function SendDelta(userId, domainDelta)
    local entry = CurrentEntry(userId)
    local state = profileService_:GetState(userId)
    if not entry or not entry.ready or not state or not domainDelta then return false end
    local changes = domainDelta.changes or domainDelta.changed or {}
    local inventoryChanged = domainDelta.inventoryChanged == true or domainDelta.equippedChanged == true
    local delta = GameStateSchema.BuildDelta(state.revision, changes, {
        serverTime = os.time(),
        inventoryChanged = inventoryChanged,
        state = state,
    })
    delta.updatedAt = state.updatedAt
    delta.events = domainDelta.events or {}
    delta.eventKind = domainDelta.kind
    local valid, validationError = GameStateSchema.ValidateDelta(delta)
    if not valid then
        print("[Server] rejected invalid delta: " .. tostring(validationError.reason))
        return SendSnapshot(userId) ~= nil
    end
    return SendPayload(entry.connection, Protocol.EVENTS.DELTA, "GameDelta", { delta = delta })
end

local function DisconnectBanned(userId, ban)
    local entry = CurrentEntry(userId)
    if not entry then return end
    SendStatus(entry.connection, "banned", ErrorCodes.BANNED, (ban and ban.reason) or "account is banned")
    entry.connection:Disconnect(50)
end

local function SendAdminResult(userId, result)
    local entry = CurrentEntry(userId)
    if not entry or not entry.ready then return false end
    return SendStatus(entry.connection, "ready", ErrorCodes.OK, "", {
        adminResult = result,
    })
end

local function FinalizeReady(entry)
    if not entry or not registry_:IsCurrent(entry) then return end
    local session = profileService_:GetSession(entry.uid)
    if not session or session.generation ~= entry.generation then
        SendStatus(entry.connection, "syncing", ErrorCodes.NOT_READY, "profile is loading")
        return
    end
    if session.ban then DisconnectBanned(entry.uid, session.ban); return end
    profileService_:MarkReady(entry.uid, entry.generation)
    idleService_:Reset(entry.uid)
    SendStatus(entry.connection, "syncing", ErrorCodes.OK, "applying queued operations")
    adminService_:ProcessInbox(entry.uid, function(result)
        if not registry_:IsCurrent(entry) then return end
        local current = profileService_:GetSession(entry.uid)
        if not current or current.ban then DisconnectBanned(entry.uid, current and current.ban); return end
        if not result.ok then
            SendStatus(entry.connection, "error", result.code, result.reason)
            return
        end
        local snapshot = SendSnapshot(entry.uid)
        if snapshot then
            SendStatus(entry.connection, "ready", ErrorCodes.OK, "", {
                isAdmin = snapshot.isAdmin,
                revision = snapshot.revision,
            })
        end
    end)
end

local function HandleClientConnected(eventType, eventData)
    local connection = ConnectionFrom(eventData)
    if not connection then return end
    registry_:OnConnected(connection)
    print("[Server] ClientConnected")
end

local function HandleClientIdentity(eventType, eventData)
    local connection = ConnectionFrom(eventData)
    if not connection then return end
    local identity = connection.identity
    local userId = identity and identity["user_id"]:GetInt64() or 0
    if userId <= 0 then
        SendStatus(connection, "rejected", ErrorCodes.UNAUTHENTICATED, "authenticated user_id is missing")
        connection:Disconnect(50)
        return
    end

    local isAdmin = adminPolicy_:IsAdmin(userId)
    local entry, replaced, admissionError = admission_:Admit(connection, userId, nil, { isAdmin = isAdmin })
    if not entry then
        SendStatus(connection, "rejected", admissionError.code, admissionError.reason)
        connection:Disconnect(50)
        return
    end
    print("[Server] ClientIdentity uid=" .. tostring(userId) .. " generation=" .. tostring(entry.generation))

    local existingSession = profileService_:GetSession(userId)
    if existingSession then
        existingSession.connection = connection
        existingSession.generation = entry.generation
        existingSession.ready = false
        if replaced and replaced.connection and replaced.connection ~= connection then replaced.connection:Disconnect(50) end
        if entry.ready then FinalizeReady(entry) end
        return
    end

    if replaced and replaced.connection and replaced.connection ~= connection then replaced.connection:Disconnect(50) end
    SendStatus(connection, "syncing", ErrorCodes.OK, "loading profile")
    profileService_:Load(userId, function(result)
        if not registry_:IsCurrent(entry) then return end
        if not result.ok then
            SendStatus(connection, "error", result.code, result.reason)
            connection:Disconnect(100)
            return
        end
        if result.data.ban then
            SendStatus(connection, "banned", ErrorCodes.BANNED, result.data.ban.reason or "account is banned")
            connection:Disconnect(100)
            return
        end
        profileService_:Attach(userId, connection, entry.generation, result.data)
        entry.metadata.profileLoaded = true
        if entry.ready then FinalizeReady(entry) end
    end)
end

local function HandleClientReady(eventType, eventData)
    local connection = ConnectionFrom(eventData)
    local entry = connection and registry_:GetByConnection(connection) or nil
    if not entry or not entry.authenticated or not registry_:IsCurrent(entry) then
        if connection then SendStatus(connection, "rejected", ErrorCodes.UNAUTHENTICATED, "identity handshake is incomplete") end
        return
    end
    connection.scene = scene_
    if not registry_:MarkReady(connection, true) then return end
    print("[Server] ClientReady uid=" .. tostring(entry.uid))
    FinalizeReady(entry)
end

local function HandleClientDisconnected(eventType, eventData)
    local connection = ConnectionFrom(eventData)
    if not connection then return end
    local entry, wasCurrent = admission_:Release(connection)
    if not entry then return end
    print("[Server] ClientDisconnected uid=" .. tostring(entry.uid) .. " current=" .. tostring(wasCurrent))
    if not wasCurrent or not entry.uid then return end
    idleService_:Remove(entry.uid)
    router_:Clear(entry.uid)
    operationQueue_:Enqueue(entry.uid, function(done)
        profileService_:TouchAndDetach(entry.uid, entry.generation, function(result)
            if not result.ok then print("[Server] disconnect save failed: " .. tostring(result.reason)) end
            done()
        end)
    end)
end

local function HandleCommand(eventType, eventData)
    router_:DispatchEvent(eventData)
end

local function HandleUpdate(eventType, eventData)
    local timeStep = eventData:GetFloat("TimeStep")
    idleService_:Update(timeStep)
    adminService_:Update(timeStep)
end

local function InitializeServices()
    registry_ = PlayerRegistry.New()
    adminPolicy_ = AdminPolicy.New({ adminUserIds = { 1379670410 } })
    admission_ = AdmissionGuard.New({
        registry = registry_,
        maxPlayers = ServerConfig.LOGICAL_MAX_PLAYERS,
        isAdmin = function(userId) return adminPolicy_:IsAdmin(userId) end,
        bypassAdmins = true,
    })
    operationQueue_ = OperationQueue.New({
        onError = function(reason) print("[OperationQueue] " .. tostring(reason)) end,
    })
    gateway_ = ServerCloudGateway.New(serverCloud)
    repository_ = PlayerProfileRepository.New({ gateway = gateway_ })
    profileService_ = PlayerProfileService.New({ repository = repository_ })
    idleService_ = IdleRuntimeService.New({
        operationQueue = operationQueue_,
        profileService = profileService_,
        onDelta = SendDelta,
        onError = function(userId, result)
            local entry = CurrentEntry(userId)
            if entry then SendStatus(entry.connection, "error", result.code, result.reason) end
        end,
    })
    adminService_ = AdminService.New({
        gateway = gateway_,
        repository = repository_,
        profileService = profileService_,
        operationQueue = operationQueue_,
        adminPolicy = adminPolicy_,
        onDelta = SendDelta,
        onBanned = DisconnectBanned,
        onAdminResult = SendAdminResult,
    })
    router_ = CommandRouter.New({
        registry = registry_,
        rateLimiter = RateLimiter.New(),
        operationQueue = operationQueue_,
        decodeJson = cjson.decode,
        encodeJson = cjson.encode,
        cacheSize = ServerConfig.REQUEST_CACHE_SIZE,
        cacheTtl = ServerConfig.REQUEST_CACHE_TTL_SECONDS,
        authorize = function(context)
            local session = profileService_:GetSession(context.uid)
            if session and session.ban then return false, ErrorCodes.BANNED, session.ban.reason end
            return true
        end,
    })

    local commandServices = {
        profileService = profileService_,
        sendSnapshot = SendSnapshot,
        sendDelta = SendDelta,
    }
    GameCommands.Register(router_, commandServices)
    AdminCommands.Register(router_, adminService_)
    -- 示例云变量命令依赖未随项目发布的示例模块，正式服务端不注册。
end

function Start()
    scene_ = Scene()
    scene_:CreateComponent("Octree", LOCAL)
    SeedAuthoritativeRandom()
    Protocol.RegisterServerEvents()
    InitializeServices()

    SubscribeToEvent("ClientConnected", HandleClientConnected)
    SubscribeToEvent("ClientIdentity", HandleClientIdentity)
    SubscribeToEvent(Protocol.EVENTS.CLIENT_READY, HandleClientReady)
    SubscribeToEvent("ClientDisconnected", HandleClientDisconnected)
    SubscribeToEvent(Protocol.EVENTS.COMMAND, HandleCommand)
    SubscribeToEvent("Update", HandleUpdate)

    print("[Server] 无尽深渊挂机录 authority started")
    print("[Server] serverCloud available=" .. tostring(serverCloud ~= nil))
    print("[Server] persistentWorldKey=" .. ServerConfig.GetPersistentWorldKey())
end

function Stop()
    UnsubscribeFromAllEvents()
    if scene_ then scene_:Dispose(); scene_ = nil end
end
