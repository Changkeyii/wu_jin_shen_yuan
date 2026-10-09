-- ChallengeCommands.lua
-- 深渊 Boss 挑战命令：开始 / 攻击 / 结束。伤害由服务端权威累计。

local CommandRouter = require("server.core.CommandRouter")
local ChallengeEngine = require("server.domain.ChallengeEngine")
local ServerConfig = require("server.ServerConfig")

local ChallengeCommands = {}

local GRADE_SCHEMA = {
    type = "object",
    required = { "gradeId" },
    allowUnknown = false,
    fields = {
        gradeId = {
            type = "string",
            enum = { "rift", "mutated", "calamity" },
        },
    },
}

local EMPTY_SCHEMA = { type = "object", fields = {}, allowUnknown = false }

local function MutationResponse(result)
    if not result or not result.ok then return result end
    local data = result.data or {}
    local state = data.state or {}
    return {
        ok = true,
        code = result.code,
        reason = result.reason,
        data = {
            committed = data.committed == true,
            runtimeOnly = data.runtimeOnly == true,
            revision = state.revision,
        },
    }
end

local function AsyncMutation(services, operationName, mutator, afterSuccess)
    return function(context, payload, done)
        services.profileService:Apply(context.uid, operationName, function(state, now)
            return mutator(state, payload, now)
        end, function(result)
            if result.ok and result.data.delta then
                services.sendDelta(context.uid, result.data.delta)
            end
            if result.ok and afterSuccess then
                afterSuccess(context.uid, result)
            end
            local response = MutationResponse(result)
            done(response.ok, response)
        end)
        return CommandRouter.PENDING
    end
end

function ChallengeCommands.Register(router, services)
    router:Register({
        name = "Activity.BeginAbyssBoss",
        schema = GRADE_SCHEMA,
        rate = ServerConfig.RATES.Progression,
        handler = AsyncMutation(services, "begin abyss boss", function(state, payload, now)
            return ChallengeEngine.BeginBoss(state, payload.gradeId, now)
        end),
    })

    router:Register({
        name = "Activity.StrikeAbyssBoss",
        schema = EMPTY_SCHEMA,
        rate = { refillRate = 80, burst = 120 },
        handler = AsyncMutation(services, "strike abyss boss", function(state, payload, now)
            return ChallengeEngine.StrikeBoss(state, now)
        end, function(userId, result)
            if not result or not result.ok then return end
            local events = result.data and result.data.delta and result.data.delta.events or {}
            for _, event in ipairs(events) do
                if (event.kind or event.type) == "abyss_boss_finished"
                    and services.refreshBossLeaderboard
                then
                    services.refreshBossLeaderboard(userId)
                    return
                end
            end
        end),
    })

    router:Register({
        name = "Activity.FinishAbyssBoss",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Progression,
        handler = AsyncMutation(services, "finish abyss boss", function(state, payload, now)
            return ChallengeEngine.FinishBoss(state, now)
        end, function(userId)
            if services.refreshBossLeaderboard then
                services.refreshBossLeaderboard(userId)
            end
        end),
    })
end

return ChallengeCommands
