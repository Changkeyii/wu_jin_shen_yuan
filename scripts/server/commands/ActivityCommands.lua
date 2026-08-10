-- ActivityCommands.lua
-- 活动系统命令：签到 / 木桩打桩（开始/攻击/结束）/ 广告解锁额外次数。

local CommandRouter = require("server.core.CommandRouter")
local ActivityEngine = require("server.domain.ActivityEngine")
local ServerConfig = require("server.ServerConfig")

local ActivityCommands = {}

local ACTIVITY_ID_SCHEMA = {
    type = "string",
    minLength = 1,
    maxLength = 96,
    pattern = "^[%w%._:%-]+$",
}

local ACTIVITY_PAYLOAD_SCHEMA = {
    type = "object",
    required = { "activityId" },
    allowUnknown = false,
    fields = { activityId = ACTIVITY_ID_SCHEMA },
}

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

local function AsyncMutation(services, operationName, mutator)
    return function(context, payload, done)
        services.profileService:Apply(context.uid, operationName, function(state, now)
            return mutator(state, payload, now)
        end, function(result)
            if result.ok and result.data.delta then
                services.sendDelta(context.uid, result.data.delta)
            end
            local response = MutationResponse(result)
            done(response.ok, response)
        end)
        return CommandRouter.PENDING
    end
end

function ActivityCommands.Register(router, services)
    router:Register({
        name = "Activity.SignIn",
        schema = ACTIVITY_PAYLOAD_SCHEMA,
        rate = ServerConfig.RATES.DailyClaim,
        handler = AsyncMutation(services, "activity sign in", function(state, payload, now)
            return ActivityEngine.SignIn(state, payload.activityId, now)
        end),
    })

    router:Register({
        name = "Activity.UnlockExtraStrike",
        schema = ACTIVITY_PAYLOAD_SCHEMA,
        rate = ServerConfig.RATES.DailyClaim,
        handler = AsyncMutation(services, "activity unlock extra strike", function(state, payload, now)
            return ActivityEngine.UnlockExtraStrike(state, payload.activityId, now)
        end),
    })

    router:Register({
        name = "Activity.BeginStrike",
        schema = ACTIVITY_PAYLOAD_SCHEMA,
        rate = ServerConfig.RATES.Progression,
        handler = AsyncMutation(services, "activity begin strike", function(state, payload, now)
            return ActivityEngine.BeginStrike(state, payload.activityId, now)
        end),
    })

    -- 打桩攻击频率高（限流服务端 0.3s/次），给足余量。
    router:Register({
        name = "Activity.Strike",
        schema = ACTIVITY_PAYLOAD_SCHEMA,
        rate = { refillRate = 8, burst = 12 },
        handler = AsyncMutation(services, "activity strike", function(state, payload, now)
            return ActivityEngine.Strike(state, payload.activityId, now)
        end),
    })

    router:Register({
        name = "Activity.FinishStrike",
        schema = ACTIVITY_PAYLOAD_SCHEMA,
        rate = ServerConfig.RATES.Progression,
        handler = AsyncMutation(services, "activity finish strike", function(state, payload, now)
            return ActivityEngine.FinishStrike(state, payload.activityId, now)
        end),
    })
end

return ActivityCommands
