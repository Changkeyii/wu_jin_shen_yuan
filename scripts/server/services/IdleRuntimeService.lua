local GameEngine = require("server.domain.GameEngine")
local Catalog = require("server.domain.Catalog")
local BigNumber = require("shared.BigNumber")

local IdleRuntimeService = {}
IdleRuntimeService.__index = IdleRuntimeService

function IdleRuntimeService.New(options)
    options = options or {}
    assert(options.operationQueue, "IdleRuntimeService requires operationQueue")
    assert(options.profileService, "IdleRuntimeService requires profileService")
    return setmetatable({
        operationQueue = options.operationQueue,
        profileService = options.profileService,
        onDelta = options.onDelta or function() end,
        onError = options.onError or function() end,
        rng = options.rng,
        elapsed = {},
        pending = {},
        combatPlayers = {},
        idlePlayers = {},
        pendingTimeoutPlayers = {},
    }, IdleRuntimeService)
end

IdleRuntimeService.new = IdleRuntimeService.New

function IdleRuntimeService:Reset(userId)
    self.elapsed[userId] = 0
end

function IdleRuntimeService:Remove(userId)
    self.elapsed[userId] = nil
    self.pending[userId] = nil
    self.combatPlayers[userId] = nil
    self.idlePlayers[userId] = nil
    self.pendingTimeoutPlayers[userId] = nil
end

-- 事件超时：服务端权威地按 skip 结算，不会代替玩家花费金币。
function IdleRuntimeService:_enqueueEventTimeout(userId, pendingEvent)
    if self.pending[userId] then return end
    local expiresAt = tonumber(pendingEvent and pendingEvent.expiresAt) or 0
    if os.time() <= expiresAt then return end

    local session = self.profileService:GetSession(userId)
    if not session or not self.profileService:IsOnline(userId) then return end
    local generation = session.generation
    local token = {}
    self.pending[userId] = token

    self.operationQueue:Enqueue(userId, function(done)
        local function finish()
            if self.pending[userId] == token then self.pending[userId] = nil end
            done()
        end
        local current = self.profileService:GetSession(userId)
        if not self.profileService:IsOnline(userId)
            or not current or current.generation ~= generation
            or not current.state.pendingEvent
        then finish(); return end

        self.profileService:ApplyRuntime(userId, "event timeout skip", function(state, now)
            return GameEngine.ResolveEvent(state, {}, now, { timeout = true })
        end, function(result)
            if result.ok then
                local delta = result.data and result.data.delta
                if delta and delta.events and #delta.events > 0 then
                    print("[IdleEvent] timeout skip uid=" .. tostring(userId))
                    self.onDelta(userId, delta)
                end
            else
                self.onError(userId, result)
            end
            finish()
        end)
    end)
end

function IdleRuntimeService:_enqueueTick(userId, elapsedSeconds)
    if self.pending[userId] then return end
    local queuedSession = self.profileService:GetSession(userId)
    if not queuedSession or not self.profileService:IsOnline(userId) then return end
    local generation = queuedSession.generation
    local token = {}
    self.pending[userId] = token
    local rng = self.rng
    self.operationQueue:Enqueue(userId, function(done)
        local function finish()
            if self.pending[userId] == token then self.pending[userId] = nil end
            done()
        end
        local session = self.profileService:GetSession(userId)
        if not self.profileService:IsOnline(userId)
            or not session or session.generation ~= generation
            or not session.state.autoRun
            or session.state.pendingStoryGate
            or session.state.pendingEvent
        then finish(); return end
        self.profileService:ApplyRuntime(userId, "auto combat tick", function(state, now)
            local current = self.profileService:GetSession(userId)
            if not self.profileService:IsOnline(userId)
                or not current or current.generation ~= generation
            then
                return {
                    ok = true,
                    state = state,
                    delta = { events = {}, changes = {} },
                    commit = { kind = "none" },
                }
            end
            return GameEngine.AdvanceCombatTick(state, rng, now, elapsedSeconds)
        end, function(result)
            if result.ok then
                local events = result.data.delta and result.data.delta.events or {}
                for _, value in ipairs(events) do
                    local kind = value.kind or value.type
                    if kind == "battle_started"
                        or kind == "battle_won"
                        or kind == "floor_advanced"
                    then
                        print("[IdleCombat] uid=" .. tostring(userId)
                            .. " event=" .. tostring(kind)
                            .. " floor=" .. tostring(result.data.state and result.data.state.floor)
                            .. " position=" .. tostring(result.data.state and result.data.state.position))
                    end
                end
                if #events > 0 then
                    self.onDelta(userId, result.data.delta)
                end
            else
                self.onError(userId, result)
            end
            finish()
        end)
    end)
end

function IdleRuntimeService:Update(timeStep)
    if type(timeStep) ~= "number" or timeStep <= 0 then return end
    local online = {}
    self.combatPlayers = {}
    self.idlePlayers = {}
    self.pendingTimeoutPlayers = {}
    for _, userId in ipairs(self.profileService:OnlineUserIds()) do
        online[userId] = true
        local state = self.profileService:GetState(userId)
        if state and state.pendingEvent then
            self.pendingTimeoutPlayers[userId] = true
        elseif state and state.autoRun and state.currentMonster
            and not state.pendingStoryGate and not state.pendingEvent then
            self.combatPlayers[userId] = true
        else
            self.idlePlayers[userId] = true
        end
        -- 超时结算交互事件：玩家未选择时服务端强制跳过
        if state and state.pendingEvent and not self.pending[userId] then
            self:_enqueueEventTimeout(userId, state.pendingEvent)
        end

        if self.combatPlayers[userId] then
            local elapsed =
                (self.elapsed[userId] or 0)
                + timeStep
            local interval =
                Catalog.STEP_SECONDS

            if state.currentMonster then
                local monster = state.currentMonster
                local nextPhase = math.max(0, tonumber(monster.phaseRemaining) or 0)
                local monsterHp = monster.hpBig or monster.hp
                local nextEnemy = not BigNumber.IsZero(monsterHp)
                    and math.max(0, tonumber(monster.nextMonsterAttackSeconds) or Catalog.ENEMY_ATTACK_SECONDS)
                    or math.huge
                local nextEnrage = math.huge
                if monster.isBoss and not monster.enraged then
                    nextEnrage = math.max(0,
                        Catalog.BOSS_ENRAGE_SECONDS - (tonumber(monster.elapsedSeconds) or 0))
                end
                interval = math.max(
                    Catalog.COMBAT_TICK_SECONDS,
                    math.min(nextPhase, nextEnemy, nextEnrage)
                )
            end

            if elapsed >= interval
                and not self.pending[userId]
            then
                elapsed = elapsed - interval
                self:_enqueueTick(
                    userId,
                    interval
                )
            end

            self.elapsed[userId] = elapsed
        else
            self.elapsed[userId] = 0
        end
    end
    for userId in pairs(self.elapsed) do
        if not online[userId] then self.elapsed[userId] = nil end
    end
end

return IdleRuntimeService
