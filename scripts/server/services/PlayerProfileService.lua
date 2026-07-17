local StateFactory = require("server.domain.StateFactory")
local GameEngine = require("server.domain.GameEngine")
local TableUtils = require("server.domain.TableUtils")
local Catalog = require("server.domain.Catalog")
local GameStateSchema = require("shared.GameStateSchema")

local PlayerProfileService = {}
PlayerProfileService.__index = PlayerProfileService

local function Result(ok, data, code, reason)
    return { ok = ok == true, data = data or {}, code = code or (ok and 0 or -1), reason = tostring(reason or "") }
end

function PlayerProfileService.New(options)
    options = options or {}
    assert(options.repository, "PlayerProfileService requires repository")
    return setmetatable({
        repository = options.repository,
        clock = options.clock or os.time,
        sessions = {},
    }, PlayerProfileService)
end

PlayerProfileService.new = PlayerProfileService.New

function PlayerProfileService:_finishLoad(userId, state, ban, warning, onComplete)
    local valid, validationError = GameStateSchema.ValidateState(state)
    if not valid then
        onComplete(Result(false, {}, validationError.code, validationError.reason))
        return
    end
    local proposal = GameEngine.AccrueOffline(state, self.clock())
    if proposal.ok then
        local proposalValid, proposalError = GameStateSchema.ValidateState(proposal.state)
        if not proposalValid then
            onComplete(Result(false, {}, proposalError.code, proposalError.reason))
            return
        end
    end
    if proposal.ok and proposal.commit and proposal.commit.kind ~= "none" then
        self.repository:Commit(userId, state, proposal.state, "abyss offline accrual", function(commitResult)
            if not commitResult.ok then onComplete(commitResult); return end
            onComplete(Result(true, { state = proposal.state, ban = ban, warning = warning }))
        end)
        return
    end
    if not proposal.ok then
        onComplete(Result(false, {}, proposal.error.code, proposal.error.reason))
        return
    end
    onComplete(Result(true, { state = state, ban = ban, warning = warning }))
end

function PlayerProfileService:Load(userId, onComplete)
    self.repository:Load(userId, function(loadResult)
        if not loadResult.ok then onComplete(loadResult); return end
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
        ban = loadData.ban,
        ready = false,
        loadedAt = self.clock(),
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

    self.repository:Commit(userId, before, proposal.state, "abyss " .. tostring(operationName), function(commitResult)
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
        onComplete(Result(true, {
            state = session.state,
            delta = proposal.delta,
            committed = true,
            alreadyApplied = false,
        }))
    end)
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
    local proposal = touch(before, self.clock())
    if not proposal.ok or not proposal.commit or proposal.commit.kind == "none" then
        self.sessions[userId] = nil
        onComplete(Result(proposal.ok, { detached = true, persisted = false }, proposal.error and proposal.error.code, proposal.error and proposal.error.reason))
        return
    end
    self.repository:Commit(userId, before, proposal.state, "abyss disconnect checkpoint", function(result)
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
