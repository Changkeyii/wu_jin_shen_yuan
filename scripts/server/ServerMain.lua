local Protocol = require("shared.NetworkProtocol")
local ErrorCodes = require("shared.ErrorCodes")
local GameStateSchema = require("shared.GameStateSchema")
local GameEventSchema = require("shared.GameEventSchema")
local FloorRoute = require("shared.FloorRoute")
local ServerConfig = require("server.ServerConfig")
local PlayerRegistry = require("server.core.PlayerRegistry")
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
local operationQueue_ = nil
local router_ = nil
local gateway_ = nil
local repository_ = nil
local profileService_ = nil
local idleService_ = nil
local adminService_ = nil
local adminPolicy_ = nil
local snapshotTransferId_ = 0

local POWER_SNAPSHOT_FIELDS = {
    "displayedPower",
    "recommendedPower",
    "nextChapterRecommendedPower",
    "powerRatio",
    "headroomFloors",
    "difficultyLabel",
    "bossScore",
    "eliteScore",
    "estimatedEasyFloor",
}

local function NextSnapshotTransferId()
    snapshotTransferId_ = snapshotTransferId_ + 1
    return string.format("s-%d-%d", os.time(), snapshotTransferId_)
end

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
    if #envelope.payloadJson > Protocol.MAX_SERVER_PAYLOAD_BYTES then
        print("[Server] outbound payload rejected command=" .. tostring(command)
            .. " bytes=" .. tostring(#envelope.payloadJson)
            .. " limit=" .. tostring(Protocol.MAX_SERVER_PAYLOAD_BYTES))
        return false
    end
    local ok, reason = pcall(function()
        connection:SendRemoteEvent(eventName, true, Protocol.ToVariantMap(envelope))
    end)
    if not ok then print("[Server] send failed: " .. tostring(reason)) end
    return ok
end

local function BuildStatusPayload(state, code, reason, extra)
    local payload = extra and GameStateSchema.DeepCopy(extra) or {}
    payload.state = state
    payload.code = code or ErrorCodes.OK
    payload.reason = reason or ""
    return payload
end

local function SendStatus(connection, state, code, reason, extra)
    local payload = BuildStatusPayload(state, code, reason, extra)
    local entry = registry_ and registry_:GetByConnection(connection) or nil
    if not entry or not entry.ready then
        local terminal = state == "rejected" or state == "error" or state == "banned"
        if terminal then
            return SendPayload(connection, Protocol.EVENTS.STATUS, "Status", payload)
        end
        if entry then
            entry.metadata = entry.metadata or {}
            entry.metadata.pendingStatuses = entry.metadata.pendingStatuses or {}
            local pending = entry.metadata.pendingStatuses
            pending[#pending + 1] = payload
            while #pending > 4 do table.remove(pending, 1) end
        end
        print("[Server] status queued until ClientReady state=" .. tostring(state)
            .. " code=" .. tostring(payload.code)
            .. " reason=" .. tostring(payload.reason))
        return false
    end
    return SendPayload(connection, Protocol.EVENTS.STATUS, "Status", payload)
end

local function FlushPendingStatuses(entry)
    if not entry or not entry.ready or not entry.connection then return end
    local metadata = entry.metadata or {}
    local pending = metadata.pendingStatuses or {}
    metadata.pendingStatuses = {}
    entry.metadata = metadata
    for _, payload in ipairs(pending) do
        SendPayload(entry.connection, Protocol.EVENTS.STATUS, "Status", payload)
    end
end

local function CurrentEntry(userId)
    local entry = registry_:Get(userId)
    if entry and registry_:IsCurrent(entry) then return entry end
    return nil
end

local function CanonicalizeGameEvents(events)
    local result = {}
    for _, source in ipairs(type(events) == "table" and events or {}) do
        if type(source) ~= "table" then
            return nil, "game event must be a table"
        end
        local value = GameStateSchema.DeepCopy(source)
        local eventType = value.type or value.kind
        if type(eventType) ~= "string" or eventType == "" then
            return nil, "game event is missing its type"
        end
        value.type = eventType
        value.kind = value.kind or eventType

        -- Domain V3 events used explicit player/monster prefixes. Preserve
        -- those fields and add the V5 scalar/big aliases at the network edge.
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
    return result
end

local function AddPowerSnapshotFields(changes, state)
    local result = GameStateSchema.DeepCopy(changes or {})
    local stats = type(state) == "table" and state.stats or nil
    for _, fieldName in ipairs(POWER_SNAPSHOT_FIELDS) do
        if type(stats) == "table" and stats[fieldName] ~= nil then
            result[fieldName] = GameStateSchema.DeepCopy(stats[fieldName])
        elseif type(state) == "table" and state[fieldName] ~= nil then
            result[fieldName] = GameStateSchema.DeepCopy(state[fieldName])
        end
    end
    return result
end

local function BuildSnapshotChunkPayload(transferId, revision, chunkIndex, chunkCount, chunkItems, snapshot, events)
    local payload = {
        transferId = transferId,
        revision = revision,
        chunkIndex = chunkIndex,
        chunkCount = chunkCount,
        inventory = chunkItems,
    }
    if snapshot then
        payload.snapshot = snapshot
        payload.events = events or {}
    end
    return payload
end

local function SendSnapshot(userId, snapshotEvents)
    local entry = CurrentEntry(userId)
    local state = profileService_:GetState(userId)
    if not entry or not state then return nil end
    local snapshot = GameStateSchema.BuildSnapshot(state, {
        serverTime = os.time(),
        status = "ready",
        isAdmin = adminPolicy_:IsAdmin(userId),
        stats = state.stats,
        itemPower = GameEngine.GetItemPower,
        playerNickname = entry.nickname,
    })
    local stats = state.stats or {}
    snapshot.recommendedPower = snapshot.recommendedPower or stats.recommendedPower or 0
    snapshot.nextChapterRecommendedPower = snapshot.nextChapterRecommendedPower
        or stats.nextChapterRecommendedPower or snapshot.recommendedPower
    snapshot.powerRatio = snapshot.powerRatio or stats.powerRatio or 0
    snapshot.headroomFloors = snapshot.headroomFloors or stats.headroomFloors or 0
    snapshot.difficultyLabel = snapshot.difficultyLabel or stats.difficultyLabel or "危险"
    snapshot.bossScore = snapshot.bossScore or stats.bossScore or 0
    snapshot.eliteScore = snapshot.eliteScore or stats.eliteScore or 0
    snapshot.estimatedEasyFloor = snapshot.estimatedEasyFloor
        or stats.estimatedEasyFloor or state.floor or 1
    snapshot.floorRoute = FloorRoute.Build(state.floor)
    local snapshotEventsForState = GameStateSchema.BuildSnapshotEvents(state, snapshotEvents)
    local networkEvents, eventError = CanonicalizeGameEvents(snapshotEventsForState)
    if not networkEvents then
        print("[Server] rejected invalid snapshot events: " .. tostring(eventError))
        networkEvents = {}
    end
    snapshot.inventoryCapacity = ServerConfig.INVENTORY_CAP
    snapshot.logs = snapshot.logs or {
        "权威存档已同步，所有玩法结算由服务器执行。",
        "已载入12部位装备体系与五套史诗套装。",
    }
    snapshot.recentDamage = snapshot.recentDamage or "等待战斗结算"
    local valid, validationError = GameStateSchema.ValidateSnapshot(snapshot)
    if not valid then
        local details = validationError and validationError.details or nil
        local path = details and details.path or "$snapshot"
        local reason = "存档同步失败：字段 " .. tostring(path) .. " 数值非法"
        print("[ProfileDiag] uid=" .. tostring(userId)
            .. " snapshotValidationFailure"
            .. " path=" .. tostring(path)
            .. " reason=" .. tostring(validationError and validationError.reason))
        SendStatus(entry.connection, "error", validationError.code, reason, {
            validationPath = path,
        })
        return nil
    end
    local inventory = snapshot.inventory or {}
    local transferId = NextSnapshotTransferId()
    snapshot.inventory = nil
    local maxChunkBytes = Protocol.SNAPSHOT_CHUNK_TARGET_BYTES
    local chunks = {}
    local currentItems = {}
    local function FlushChunk()
        chunks[#chunks + 1] = currentItems
        currentItems = {}
    end
    for _, item in ipairs(inventory) do
        local candidate = {}
        for index, currentItem in ipairs(currentItems) do candidate[index] = currentItem end
        candidate[#candidate + 1] = item
        local probe = BuildSnapshotChunkPayload(
            transferId,
            snapshot.revision,
            #chunks + 1,
            1,
            candidate,
            #chunks == 0 and snapshot or nil,
            #chunks == 0 and networkEvents or nil
        )
        local probeJson = cjson.encode(probe)
        if #currentItems > 0 and #probeJson > maxChunkBytes then
            FlushChunk()
            currentItems[#currentItems + 1] = item
        else
            currentItems = candidate
        end
    end
    if #currentItems > 0 or #chunks == 0 then FlushChunk() end
    local chunkCount = #chunks
    for chunkIndex, chunkItems in ipairs(chunks) do
        local payload = BuildSnapshotChunkPayload(
            transferId,
            snapshot.revision,
            chunkIndex,
            chunkCount,
            chunkItems,
            chunkIndex == 1 and snapshot or nil,
            chunkIndex == 1 and networkEvents or nil
        )
        if not SendPayload(entry.connection, Protocol.EVENTS.SNAPSHOT, "GameSnapshotChunk", payload) then
            return nil
        end
    end
    snapshot.inventory = inventory
    print("[Server] snapshot sent uid=" .. tostring(userId)
        .. " inventory=" .. tostring(#inventory)
        .. " chunks=" .. tostring(chunkCount))
    return snapshot
end

local function SendDelta(userId, domainDelta)
    local entry = CurrentEntry(userId)
    local state = profileService_:GetState(userId)
    if not entry or not entry.ready or not state or not domainDelta then return false end
    local changes = AddPowerSnapshotFields(domainDelta.changes or domainDelta.changed or {}, state)
    changes.floorRoute = FloorRoute.Build(state.floor)
    local networkEvents, eventError = CanonicalizeGameEvents(domainDelta.events)
    if not networkEvents then
        print("[Server] rejected invalid delta events: " .. tostring(eventError))
        return SendSnapshot(userId) ~= nil
    end
    local inventoryChanged = domainDelta.inventoryChanged == true or domainDelta.equippedChanged == true
    if inventoryChanged then
        return SendSnapshot(userId, networkEvents) ~= nil
    end
    local delta = GameStateSchema.BuildDelta(state.revision, changes, {
        serverTime = os.time(),
        inventoryChanged = inventoryChanged,
        state = state,
    })
    delta.updatedAt = state.updatedAt
    delta.events = networkEvents
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

local FinalizeReady

local function ResolvePlayerNickname(entry)
    entry.metadata = entry.metadata or {}
    entry.metadata.nicknameResolved = false
    GetUserNickname {
        userIds = { entry.uid },
        onSuccess = function(nicknames)
            if not registry_:IsCurrent(entry) then return end
            local result = nicknames and nicknames[1]
            local nickname = result and result.nickname
            if type(nickname) ~= "string" or nickname == "" then
                SendStatus(entry.connection, "error", ErrorCodes.NOT_READY, "Tap nickname is empty")
                entry.connection:Disconnect(100)
                return
            end
            entry.nickname = nickname
            entry.metadata.nicknameResolved = true
            print("[Server] Tap nickname resolved uid=" .. tostring(entry.uid) .. " name=" .. nickname)
            if entry.ready then FinalizeReady(entry) end
        end,
        onError = function(errorCode)
            if not registry_:IsCurrent(entry) then return end
            print("[Server] Tap nickname query failed uid=" .. tostring(entry.uid) .. " code=" .. tostring(errorCode))
            SendStatus(entry.connection, "error", ErrorCodes.NOT_READY, "Tap nickname query failed")
            entry.connection:Disconnect(100)
        end,
    }
end

FinalizeReady = function(entry)
    if not entry or not registry_:IsCurrent(entry) then return end
    if not entry.metadata or entry.metadata.nicknameResolved ~= true then
        SendStatus(entry.connection, "syncing", ErrorCodes.NOT_READY, "loading Tap nickname")
        return
    end
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

local function MarkClientReady(entry, connection)
    if not entry or not connection then return false end
    entry.metadata = entry.metadata or {}
    entry.metadata.clientReady = true
    if not entry.authenticated or not registry_:IsCurrent(entry) then
        print("[Server] ClientReady queued until ClientIdentity")
        return false
    end
    connection.scene = scene_
    if not registry_:MarkReady(connection, true) then return false end
    FlushPendingStatuses(entry)
    print("[Server] ClientReady uid=" .. tostring(entry.uid))
    FinalizeReady(entry)
    return true
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
    local entry, replaced = registry_:OnAuthenticated(connection, userId, nil, { isAdmin = isAdmin })
    print("[Server] ClientIdentity uid=" .. tostring(userId) .. " generation=" .. tostring(entry.generation))
    ResolvePlayerNickname(entry)
    if entry.metadata and entry.metadata.clientReady then
        MarkClientReady(entry, connection)
    end

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
            print("[ProfileDiag] uid=" .. tostring(userId)
                .. " loadFailure code=" .. tostring(result.code)
                .. " reason=" .. tostring(result.reason)
                .. " action=disconnect")
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
    if not connection then return end
    local entry = registry_:GetByConnection(connection) or registry_:OnConnected(connection)
    MarkClientReady(entry, connection)
end

local function HandleClientDisconnected(eventType, eventData)
    local connection = ConnectionFrom(eventData)
    if not connection then return end
    local entry, wasCurrent = registry_:OnDisconnected(connection)
    if not entry then return end
    print("[Server] ClientDisconnected uid=" .. tostring(entry.uid) .. " current=" .. tostring(wasCurrent))
    if not wasCurrent or not entry.uid then return end
    profileService_:MarkDisconnected(entry.uid, entry.generation)
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
        idleService = idleService_,
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
