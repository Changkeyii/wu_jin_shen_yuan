local StateFactory = require("server.domain.StateFactory")
local GameEngine = require("server.domain.GameEngine")
local TableUtils = require("server.domain.TableUtils")
local Catalog = require("server.domain.Catalog")
local GameStateSchema = require("shared.GameStateSchema")

local PlayerProfileService = {}
PlayerProfileService.__index = PlayerProfileService

local OFFLINE_QUOTE_TTL_SECONDS = 60
local OFFLINE_QUOTE_RECEIPT_TTL_SECONDS = 10 * 60

local function Result(ok, data, code, reason)
    return { ok = ok == true, data = data or {}, code = code or (ok and 0 or -1), reason = tostring(reason or "") }
end

local function PrintValidationFailure(userId, stage, validationError)
    local details = validationError and validationError.details or nil
    print("[ProfileDiag] uid=" .. tostring(userId)
        .. " validationStage=" .. tostring(stage)
        .. " code=" .. tostring(validationError and validationError.code or nil)
        .. " reason=" .. tostring(validationError and validationError.reason or nil)
        .. " path=" .. tostring(details and details.path or nil))
end

function PlayerProfileService.New(options)
    options = options or {}
    assert(options.repository, "PlayerProfileService requires repository")
    return setmetatable({
        repository = options.repository,
        clock = options.clock or os.time,
        sessions = {},
        offlineQuoteCounter = 0,
    }, PlayerProfileService)
end

PlayerProfileService.new = PlayerProfileService.New

function PlayerProfileService:_finishLoad(userId, state, ban, warning, onComplete)
    print("[ProfileDiag] uid=" .. tostring(userId) .. " validateLoadedStateBegin")
    local valid, validationError = GameStateSchema.ValidateState(state)
    if not valid then
        PrintValidationFailure(userId, "loaded_state", validationError)
        onComplete(Result(false, {}, validationError.code, validationError.reason))
        return
    end
    print("[ProfileDiag] uid=" .. tostring(userId) .. " validateLoadedStateComplete")
    local proposalOk, proposalOrError = pcall(GameEngine.AccrueOffline, state, self.clock())
    if not proposalOk then
        onComplete(Result(false, {}, "OFFLINE_ACCRUAL_FAILED", tostring(proposalOrError)))
        return
    end
    local proposal = proposalOrError
    print("[ProfileDiag] uid=" .. tostring(userId)
        .. " offlineAccrualComplete commit=" .. tostring(proposal.commit and proposal.commit.kind))
    if proposal.ok then
        local proposalValid, proposalError = GameStateSchema.ValidateState(proposal.state)
        if not proposalValid then
            PrintValidationFailure(userId, "offline_accrual", proposalError)
            onComplete(Result(false, {}, proposalError.code, proposalError.reason))
            return
        end
    end
    if proposal.ok and proposal.commit and proposal.commit.kind ~= "none" then
        -- 登录不能等待云写回。离线秒数先放入当前权威会话，之后由正常玩法提交或断线检查点持久化。
        proposal.state.revision = state.revision
        proposal.state.updatedAt = state.updatedAt
        print("[ProfileDiag] uid=" .. tostring(userId)
            .. " offlineAccrualAttachedWithoutBlocking"
            .. " pendingOfflineSeconds=" .. tostring(proposal.state.pendingOfflineSeconds))
        onComplete(Result(true, {
            state = proposal.state,
            persistedState = state,
            ban = ban,
            warning = warning,
            offlineAccrualPending = true,
        }))
        return
    end
    if not proposal.ok then
        onComplete(Result(false, {}, proposal.error.code, proposal.error.reason))
        return
    end
    onComplete(Result(true, { state = state, ban = ban, warning = warning }))
end

function PlayerProfileService:Load(userId, onComplete)
    print("[ProfileDiag] uid=" .. tostring(userId) .. " loadBegin")
    self.repository:Load(userId, function(loadResult)
        if not loadResult.ok then
            print("[ProfileDiag] uid=" .. tostring(userId)
                .. " repositoryFailure code=" .. tostring(loadResult.code)
                .. " reason=" .. tostring(loadResult.reason))
            onComplete(loadResult)
            return
        end
        if loadResult.data.missing then
            local initial = StateFactory.Create(self.clock())
            self.repository:Create(userId, initial, function(createResult)
                if not createResult.ok then onComplete(createResult); return end
                onComplete(Result(true, {
                    state = createResult.data.state,
                    ban = loadResult.data.ban,
                    warning = createResult.data.warning,
                    created = true,
                }))
            end)
            return
        end
        self:_finishLoad(
            userId,
            loadResult.data.state,
            loadResult.data.ban,
            loadResult.data.warning,
            onComplete
        )
    end)
end

function PlayerProfileService:Attach(userId, connection, generation, loadData)
    self.sessions[userId] = {
        userId = userId,
        connection = connection,
        generation = generation,
        state = loadData.state,
        persistedState = TableUtils.DeepCopy(loadData.persistedState or loadData.state),
        ban = loadData.ban,
        ready = false,
        loadedAt = self.clock(),
        offlineQuote = nil,
        offlineReceipts = {},
    }
    return self.sessions[userId]
end

function PlayerProfileService:MarkReady(userId, generation)
    local session = self.sessions[userId]
    if not session or session.generation ~= generation then return false end
    session.ready = true
    return true
end

function PlayerProfileService:GetSession(userId)
    return self.sessions[userId]
end

function PlayerProfileService:GetState(userId)
    local session = self.sessions[userId]
    return session and session.state or nil
end

function PlayerProfileService:IsOnline(userId)
    local session = self.sessions[userId]
    return session ~= nil and session.connection ~= nil and session.ready == true
end

function PlayerProfileService:MarkDisconnected(userId, generation)
    local session = self.sessions[userId]
    if not session or session.generation ~= generation then return false end
    session.connection = nil
    session.ready = false
    session.disconnectedAt = self.clock()
    return true
end

local function PruneOfflineReceipts(session, now)
    for token, receipt in pairs(session.offlineReceipts or {}) do
        if type(receipt) ~= "table" or (receipt.expiresAt or 0) <= now then
            session.offlineReceipts[token] = nil
        end
    end
end

function PlayerProfileService:_nextOfflineQuoteToken(userId, generation, now)
    self.offlineQuoteCounter = self.offlineQuoteCounter + 1
    return string.format(
        "oq-%s-%s-%d-%d-%08x%08x",
        tostring(userId),
        tostring(generation),
        now,
        self.offlineQuoteCounter,
        math.random(0, 0x7fffffff),
        math.random(0, 0x7fffffff)
    )
end

function PlayerProfileService:PreviewOffline(userId, onComplete)
    local session = self.sessions[userId]
    if not session or not session.state then
        onComplete(Result(false, {}, "PROFILE_NOT_LOADED", "player profile is not loaded"))
        return
    end
    local now = self.clock()
    PruneOfflineReceipts(session, now)
    local ok, proposal = pcall(GameEngine.PreviewOffline, session.state, now)
    if not ok then
        onComplete(Result(false, {}, "DOMAIN_ERROR", proposal))
        return
    end
    if type(proposal) ~= "table" or not proposal.ok then
        local errorValue = type(proposal) == "table" and proposal.error or nil
        onComplete(Result(false, {},
            errorValue and errorValue.code or "INVALID_PROPOSAL",
            errorValue and errorValue.reason or "offline preview failed"))
        return
    end
    local valid, validationError = GameStateSchema.ValidateState(proposal.previewState)
    if not valid then
        onComplete(Result(false, {}, validationError.code, validationError.reason))
        return
    end

    local token = self:_nextOfflineQuoteToken(userId, session.generation, now)
    session.offlineQuote = {
        token = token,
        generation = session.generation,
        revision = session.state.revision,
        pendingOfflineSeconds = session.state.pendingOfflineSeconds,
        lastActiveAt = session.state.lastActiveAt,
        issuedAt = now,
        expiresAt = now + OFFLINE_QUOTE_TTL_SECONDS,
        state = proposal.previewState,
        events = proposal.previewEvents,
        inventoryChanged = proposal.previewInventoryChanged == true,
        reward = proposal.preview,
        claiming = false,
    }
    print("[OfflineQuote] uid=" .. tostring(userId)
        .. " preview issued revision=" .. tostring(session.state.revision)
        .. " seconds=" .. tostring(proposal.preview.seconds)
        .. " processed=" .. tostring(proposal.preview.processedSeconds))
    onComplete(Result(true, {
        quoteToken = token,
        expiresAt = session.offlineQuote.expiresAt,
        preview = TableUtils.DeepCopy(proposal.preview),
    }))
end

function PlayerProfileService:ClaimOffline(userId, quoteToken, onComplete)
    local session = self.sessions[userId]
    if not session or not session.state then
        onComplete(Result(false, {}, "PROFILE_NOT_LOADED", "player profile is not loaded"))
        return
    end
    local now = self.clock()
    PruneOfflineReceipts(session, now)
    local receipt = session.offlineReceipts and session.offlineReceipts[quoteToken]
    if receipt then
        onComplete(TableUtils.DeepCopy(receipt.result))
        return
    end
    local quote = session.offlineQuote
    if type(quote) ~= "table" or quote.token ~= quoteToken or quote.generation ~= session.generation then
        onComplete(Result(false, {}, "INVALID_OFFLINE_QUOTE", "offline quote is invalid"))
        return
    end
    if quote.expiresAt <= now then
        session.offlineQuote = nil
        onComplete(Result(false, {}, "OFFLINE_QUOTE_EXPIRED", "offline quote expired; request a new preview"))
        return
    end
    if quote.claiming then
        onComplete(Result(false, {}, "OFFLINE_QUOTE_IN_PROGRESS", "offline quote is already being claimed"))
        return
    end
    if quote.revision ~= session.state.revision
        or quote.pendingOfflineSeconds ~= session.state.pendingOfflineSeconds
        or quote.lastActiveAt ~= session.state.lastActiveAt
    then
        session.offlineQuote = nil
        onComplete(Result(false, {}, "STALE_OFFLINE_QUOTE", "offline quote no longer matches player state"))
        return
    end

    quote.claiming = true
    self:Apply(userId, "collect offline reward", function(state, timestamp)
        return GameEngine.CollectOfflineQuote(state, quote, timestamp)
    end, function(result)
        quote.claiming = false
        local current = self.sessions[userId]
        if result.ok and current == session then
            local replayResult = TableUtils.DeepCopy(result)
            session.offlineReceipts[quoteToken] = {
                expiresAt = self.clock() + OFFLINE_QUOTE_RECEIPT_TTL_SECONDS,
                result = replayResult,
            }
            session.offlineQuote = nil
            print("[OfflineQuote] uid=" .. tostring(userId)
                .. " claimed revision=" .. tostring(result.data.state and result.data.state.revision))
        elseif current == session and result.code ~= "CLOUD_ERROR" then
            session.offlineQuote = nil
        end
        onComplete(result)
    end)
end

function PlayerProfileService:OnlineUserIds()
    local result = {}
    for userId, session in pairs(self.sessions) do
        if session.ready and session.connection then result[#result + 1] = userId end
    end
    return result
end

function PlayerProfileService:Snapshot(userId, isAdmin)
    local session = self.sessions[userId]
    if not session then return nil end
    local snapshot = TableUtils.DeepCopy(session.state)
    snapshot.appliedGmCommandIds = nil
    snapshot.isAdmin = isAdmin == true
    snapshot.serverTime = self.clock()
    snapshot.inventoryCapacity = Catalog.INVENTORY_CAP
    snapshot.logs = snapshot.logs or {
        "权威存档已同步，所有玩法结算由服务器执行。",
        "已载入12部位装备体系与五套史诗套装。",
    }
    snapshot.recentDamage = snapshot.recentDamage or "等待战斗结算"
    return snapshot
end

local function HasAppliedGmCommand(state, commandId)
    for _, appliedId in ipairs(state.appliedGmCommandIds or {}) do
        if appliedId == commandId then return true end
    end
    return false
end

local function AppendAppliedGmCommand(state, commandId)
    local commandIds = TableUtils.DeepCopy(state.appliedGmCommandIds or {})
    while #commandIds >= GameStateSchema.MAX_APPLIED_GM_COMMANDS do
        table.remove(commandIds, 1)
    end
    commandIds[#commandIds + 1] = commandId
    state.appliedGmCommandIds = commandIds
end

function PlayerProfileService:_apply(userId, operationName, commandId, mutator, onComplete)
    local session = self.sessions[userId]
    if not session or not session.state then
        onComplete(Result(false, {}, "PROFILE_NOT_LOADED", "player profile is not loaded"))
        return
    end
    local before = session.state
    local persistedBefore = session.persistedState or before
    if commandId and HasAppliedGmCommand(before, commandId) then
        onComplete(Result(true, {
            state = before,
            committed = false,
            alreadyApplied = true,
            status = "alreadyApplied",
        }))
        return
    end
    local ok, proposal = pcall(mutator, before, self.clock())
    if not ok then
        onComplete(Result(false, {}, "DOMAIN_ERROR", proposal))
        return
    end
    if type(proposal) ~= "table" then
        onComplete(Result(false, {}, "INVALID_PROPOSAL", "domain operation did not return a proposal"))
        return
    end
    if not proposal.ok then
        onComplete(Result(false, { delta = proposal.delta }, proposal.error.code, proposal.error.reason))
        return
    end
    if commandId then
        if not proposal.commit or proposal.commit.kind == "none" then
            onComplete(Result(
                false,
                {},
                "IDEMPOTENCY_REQUIRES_COMMIT",
                "idempotent operation must produce a persistent mutation"
            ))
            return
        end
        AppendAppliedGmCommand(proposal.state, commandId)
    end
    local valid, validationError = GameStateSchema.ValidateState(proposal.state)
    if not valid then
        onComplete(Result(false, {}, validationError.code, validationError.reason))
        return
    end
    if not proposal.commit or proposal.commit.kind == "none" then
        onComplete(Result(true, { state = before, delta = proposal.delta, committed = false }))
        return
    end

    self.repository:Commit(userId, persistedBefore, proposal.state, "abyss " .. tostring(operationName), function(commitResult)
        if not commitResult.ok then
            onComplete(Result(false, { rollbackRevision = before.revision }, commitResult.code, commitResult.reason))
            return
        end
        local current = self.sessions[userId]
        if current ~= session then
            onComplete(Result(false, {}, "STALE_SESSION", "session changed while cloud transaction was pending"))
            return
        end
        session.state = proposal.state
        session.persistedState = TableUtils.DeepCopy(proposal.state)
        onComplete(Result(true, {
            state = session.state,
            delta = proposal.delta,
            committed = true,
            alreadyApplied = false,
        }))
    end)
end

function PlayerProfileService:ApplyRuntime(userId, operationName, mutator, onComplete)
    local session = self.sessions[userId]
    if not session or not session.state then
        onComplete(Result(false, {}, "PROFILE_NOT_LOADED", "玩家存档尚未加载"))
        return
    end
    local before = session.state
    local ok, proposal = pcall(mutator, before, self.clock())
    if not ok then
        onComplete(Result(false, {}, "DOMAIN_ERROR", proposal))
        return
    end
    if type(proposal) ~= "table" or not proposal.ok then
        local errorValue = type(proposal) == "table" and proposal.error or nil
        onComplete(Result(false, {},
            errorValue and errorValue.code or "INVALID_PROPOSAL",
            errorValue and errorValue.reason or "运行时状态更新失败"))
        return
    end
    local valid, validationError = GameStateSchema.ValidateState(proposal.state)
    if not valid then
        onComplete(Result(false, {}, validationError.code, validationError.reason))
        return
    end
    if self.sessions[userId] ~= session then
        onComplete(Result(false, {}, "STALE_SESSION", "玩家会话已变化"))
        return
    end
    session.state = proposal.state
    onComplete(Result(true, {
        state = session.state,
        delta = proposal.delta,
        committed = false,
        runtimeOnly = true,
        operation = operationName,
    }))
end

function PlayerProfileService:Apply(userId, operationName, mutator, onComplete)
    return self:_apply(userId, operationName, nil, mutator, onComplete)
end

function PlayerProfileService:ApplyOnce(userId, commandId, operationName, mutator, onComplete)
    if type(commandId) ~= "string"
        or #commandId < 1
        or #commandId > GameStateSchema.MAX_GM_COMMAND_ID_LENGTH
        or string.match(commandId, "^[%w%._:%-]+$") == nil
    then
        onComplete(Result(false, {}, "INVALID_COMMAND_ID", "GM command id is invalid"))
        return
    end
    return self:_apply(userId, operationName, commandId, mutator, onComplete)
end

function PlayerProfileService:TouchAndDetach(userId, generation, onComplete)
    local session = self.sessions[userId]
    if not session or session.generation ~= generation then
        onComplete(Result(true, { detached = false, stale = true }))
        return
    end
    local touch = GameEngine.TouchActive
    if not touch then
        self.sessions[userId] = nil
        onComplete(Result(true, { detached = true, persisted = false }))
        return
    end
    local before = session.state
    local persistedBefore = session.persistedState or before
    local proposal = touch(before, self.clock())
    if not proposal.ok or not proposal.commit or proposal.commit.kind == "none" then
        self.sessions[userId] = nil
        onComplete(Result(proposal.ok, { detached = true, persisted = false }, proposal.error and proposal.error.code, proposal.error and proposal.error.reason))
        return
    end
    self.repository:Commit(userId, persistedBefore, proposal.state, "abyss disconnect checkpoint", function(result)
        if self.sessions[userId] == session then self.sessions[userId] = nil end
        if result.ok then
            onComplete(Result(true, { detached = true, persisted = true }))
        else
            onComplete(result)
        end
    end)
end

function PlayerProfileService:DropSession(userId, generation)
    local session = self.sessions[userId]
    if session and session.generation == generation then self.sessions[userId] = nil; return true end
    return false
end

function PlayerProfileService:Inspect(userId, onComplete)
    local online = self.sessions[userId]
    if online then
        onComplete(Result(true, { online = true, state = TableUtils.DeepCopy(online.state), ban = online.ban }))
        return
    end
    self.repository:Load(userId, function(result)
        if not result.ok then onComplete(result); return end
        if result.data.missing then
            onComplete(Result(true, { online = false, missing = true, ban = result.data.ban }))
        else
            onComplete(Result(true, {
                online = false,
                missing = false,
                state = result.data.state,
                ban = result.data.ban,
            }))
        end
    end)
end

return PlayerProfileService
