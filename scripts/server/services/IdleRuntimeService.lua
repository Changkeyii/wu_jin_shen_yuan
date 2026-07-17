local GameEngine = require("server.domain.GameEngine")
local Catalog = require("server.domain.Catalog")

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
    }, IdleRuntimeService)
end

IdleRuntimeService.new = IdleRuntimeService.New

function IdleRuntimeService:Reset(userId)
    self.elapsed[userId] = 0
end

function IdleRuntimeService:Remove(userId)
    self.elapsed[userId] = nil
end

function IdleRuntimeService:_enqueueTick(userId)
    local rng = self.rng
    self.operationQueue:Enqueue(userId, function(done)
        local session = self.profileService:GetSession(userId)
        if not session or not session.ready or not session.state.autoRun then done(); return end
        self.profileService:Apply(userId, "auto cell", function(state, now)
            return GameEngine.AdvanceOneCell(state, rng, now)
        end, function(result)
            if result.ok then
                self.onDelta(userId, result.data.delta)
            else
                self.onError(userId, result)
            end
            done()
        end)
    end)
end

function IdleRuntimeService:Update(timeStep)
    if type(timeStep) ~= "number" or timeStep <= 0 then return end
    local online = {}
    for _, userId in ipairs(self.profileService:OnlineUserIds()) do
        online[userId] = true
        local state = self.profileService:GetState(userId)
        if state and state.autoRun then
            local elapsed = (self.elapsed[userId] or 0) + timeStep
            if elapsed >= Catalog.STEP_SECONDS then
                elapsed = elapsed - Catalog.STEP_SECONDS
                self:_enqueueTick(userId)
            end
            self.elapsed[userId] = math.min(elapsed, Catalog.STEP_SECONDS)
        else
            self.elapsed[userId] = 0
        end
    end
    for userId in pairs(self.elapsed) do
        if not online[userId] then self.elapsed[userId] = nil end
    end
end

return IdleRuntimeService
