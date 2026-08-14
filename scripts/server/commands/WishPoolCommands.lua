local CommandRouter = require("server.core.CommandRouter")
local WishPoolEngine = require("server.domain.WishPoolEngine")
local ServerConfig = require("server.ServerConfig")

local WishPoolCommands = {}

local EMPTY_SCHEMA = {
    type = "object",
    required = {},
    allowUnknown = false,
    fields = {},
}

local WISH_SCHEMA = {
    type = "object",
    required = {},
    allowUnknown = false,
    fields = {
        -- 1 = 单抽（1 券），10 = 十连（8 券）。缺省按单抽。
        count = { type = "integer", min = 1, max = 10 },
    },
}

local OPEN_JAR_SCHEMA = {
    type = "object",
    required = { "jarId" },
    allowUnknown = false,
    fields = {
        jarId = {
            type = "string",
            minLength = 1,
            maxLength = 96,
            pattern = "^jar%.[%w%._%-]+$",
        },
        count = { type = "integer", min = 1, max = 6 },
    },
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

function WishPoolCommands.Register(router, services)
    router:Register({
        name = "WishPool.WishWithTicket",
        schema = WISH_SCHEMA,
        rate = ServerConfig.RATES.Wish,
        handler = AsyncMutation(services, "wish with ticket", function(state, payload, now)
            return WishPoolEngine.Wish(state, "ticket", now, nil, payload and payload.count)
        end),
    })

    -- 广告许愿已下线：保留命令名仅返回明确失败，避免旧客户端静默误用。
    router:Register({
        name = "WishPool.WishWithAd",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Wish,
        handler = function(_, _, done)
            done(false, {
                ok = false,
                code = "WISH_AD_DISABLED",
                reason = "广告许愿已下线，请使用许愿券",
            })
            return true
        end,
    })

    router:Register({
        name = "WishPool.OpenJar",
        schema = OPEN_JAR_SCHEMA,
        rate = ServerConfig.RATES.Progression,
        handler = AsyncMutation(services, "open wish jar", function(state, payload, now)
            return WishPoolEngine.OpenJar(state, payload.jarId, now, nil, payload.count)
        end),
    })
end

return WishPoolCommands
