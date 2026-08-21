local CommandRouter = require("server.core.CommandRouter")
local RewardClaimEngine = require("server.domain.RewardClaimEngine")
local ServerConfig = require("server.ServerConfig")

local RewardClaimCommands = {}

local CLAIM_SCHEMA = {
    type = "object",
    required = { "rewardId" },
    allowUnknown = false,
    fields = {
        rewardId = {
            type = "string",
            minLength = 1,
            maxLength = 96,
            pattern = "^[%w%._:%-]+$",
        },
    },
}

local GIFT_SCHEMA = {
    type = "object",
    required = { "giftId" },
    allowUnknown = false,
    fields = {
        giftId = {
            type = "string",
            enum = {
                "daily",
            },
        },
    },
}

local function mutationResponse(result)
    if not result or not result.ok then return result end
    local data = result.data or {}
    local state = data.state or {}
    return {
        ok = true,
        code = result.code,
        reason = result.reason,
        data = {
            committed = data.committed == true,
            revision = state.revision,
        },
    }
end

local function registerMutation(router, services, name, schema, operation, mutator)
    router:Register({
        name = name,
        schema = schema,
        rate = ServerConfig.RATES.DailyClaim,
        handler = function(context, payload, done)
            services.profileService:Apply(
                context.uid,
                operation,
                function(state, now)
                    return mutator(state, payload, now)
                end,
                function(result)
                    if result.ok and result.data.delta then
                        services.sendDelta(context.uid, result.data.delta)
                    end
                    local response = mutationResponse(result)
                    done(response.ok, response)
                end
            )
            return CommandRouter.PENDING
        end,
    })
end

function RewardClaimCommands.Register(router, services)
    registerMutation(
        router,
        services,
        "Reward.ClaimAdExtra",
        CLAIM_SCHEMA,
        "claim rewarded ad extra",
        function(state, payload, now)
            return RewardClaimEngine.ClaimAdExtra(
                state,
                payload.rewardId,
                now
            )
        end
    )
    registerMutation(
        router,
        services,
        "Reward.ClaimExclusiveAdGift",
        GIFT_SCHEMA,
        "claim exclusive ad gift",
        function(state, payload, now)
            return RewardClaimEngine.ClaimExclusiveAdGift(
                state,
                payload.giftId,
                now
            )
        end
    )
end

return RewardClaimCommands
