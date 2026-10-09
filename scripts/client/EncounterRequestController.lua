-- Automatic encounter requests must not retry once per render frame.
local Controller = {}
Controller.__index = Controller

local RETRYABLE = { RATE_LIMITED = true, SERVER_BUSY = true, REQUEST_TIMEOUT = true }

function Controller.New()
    local self = setmetatable({}, Controller)
    self:Reset()
    return self
end

function Controller:Reset()
    self.generation = (self.generation or 0) + 1
    self.pending = false
    self.failures = 0
    self.wait = 0
    self.stopped = false
end

function Controller.IsBlocked(game)
    return game.readOnly or not game.autoRun
        or game.pendingStoryGate or game.pendingStory
        or game.pendingEvent or game.aidPending or game.currentMonster
end

function Controller:Update(dt)
    self.wait = math.max(0, self.wait - math.max(0, tonumber(dt) or 0))
end

function Controller:Try(game, route, encounter, context)
    if Controller.IsBlocked(game) or self.pending or self.stopped or self.wait > 0 then
        return false
    end
    self.pending = true
    local generation = self.generation
    context.serverClient.EnterEncounter(route.routeId, encounter.encounterId, encounter.room, function(response)
        -- A new route, story/event gate, or connection supersedes this request.
        if generation ~= self.generation then return end
        if response and response.ok then return end

        self.pending = false
        self.failures = self.failures + 1
        local code = response and response.code
        if RETRYABLE[code] and self.failures < 3 then
            local retryAfter = tonumber(response.details and response.details.retryAfter) or 0
            if retryAfter ~= retryAfter then retryAfter = 0 end
            self.wait = math.max(2 ^ self.failures, retryAfter)
        else
            -- Business rejections need a state change/user action, not a retry loop.
            self.stopped = true
        end
        if self.failures == 1 then
            context.actionResult(response)
            if code ~= "NOT_READY" then context.serverClient.RequestSnapshot() end
        end
    end)
    return true
end

return Controller
