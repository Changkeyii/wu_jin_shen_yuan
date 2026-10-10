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

local BATCH_SCHEMA = {
    type = "object", required = { "rewardIds" }, allowUnknown = false,
    fields = { rewardIds = { type = "array", minLength = 1, maxLength = 50,
        items = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" } } },
}

local function mutationResponse(result)
    if not result or not result.ok then return result end
    local data = result.data or {}
    local state = data.state or {}
    local receipts = {}
    for _, event in ipairs(data.delta and data.delta.events or {}) do
        if (event.kind or event.type) == "reward_ad_extra_claimed" then receipts[#receipts + 1] = event end
    end
    return {
        ok = true,
        code = result.code,
        reason = result.reason,
        data = {
            committed = data.committed == true,
            revision = state.revision,
            rewards = receipts,
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
    router:Register {
        name = "Reward.VerifyAdFree",
        schema = { type = "object", allowUnknown = false, fields = {} },
        rate = ServerConfig.RATES.Progression,
        handler = function(context)
            local state = services.profileService:GetState(context.uid)
            if not state or state.adFree ~= true then
                return false, { ok = false, code = "AD_FREE_REQUIRED", reason = "免广告身份未开启或已取消，请刷新后重试" }
            end
            return true, { ok = true, data = { adFree = true } }
        end,
    }
    require("server.commands.AdGiftCommands").Register(router, services)
    registerMutation(router, services, "Reward.ClaimAdExtras", BATCH_SCHEMA, "claim reward ad batch",
        function(state, payload, now) return RewardClaimEngine.ClaimAdExtras(state, payload.rewardIds, now) end)
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
