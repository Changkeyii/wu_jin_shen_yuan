local CommandRouter = require("server.core.CommandRouter")
local AbyssEngine = require("server.domain.AbyssEngine")
local ServerConfig = require("server.ServerConfig")

local AbyssCommands = {}

local ENTER_SCHEMA = {
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

local function asyncMutation(services, operationName, mutator)
    return function(context, payload, done)
        services.profileService:Apply(context.uid, operationName, function(state, now)
            return mutator(state, payload, now)
        end, function(result)
            if result.ok and result.data.delta then
                services.sendDelta(context.uid, result.data.delta)
            end
            local response = mutationResponse(result)
            done(response.ok, response)
        end)
        return CommandRouter.PENDING
    end
end

function AbyssCommands.Register(router, services)
    router:Register({
        name = "Activity.EnterAbyss",
        schema = ENTER_SCHEMA,
        rate = ServerConfig.RATES.Progression,
        handler = asyncMutation(services, "enter activity abyss", function(state, payload, now)
            return AbyssEngine.EnterActivity(state, payload.gradeId, now)
        end),
    })
end

return AbyssCommands
