-- QuestCommands.lua
-- 任务系统命令：单领 / 一键领取。服务端权威判定完成与发放奖励。

local CommandRouter = require("server.core.CommandRouter")
local QuestEngine = require("server.domain.QuestEngine")
local ServerConfig = require("server.ServerConfig")

local QuestCommands = {}

local EMPTY_SCHEMA = { type = "object", fields = {}, allowUnknown = false }

local QUEST_ID_SCHEMA = {
    type = "string",
    minLength = 1,
    maxLength = 96,
    pattern = "^[%w%._:%-]+$",
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
            alreadyApplied = data.alreadyApplied == true,
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

function QuestCommands.Register(router, services)
    router:Register({
        name = "Quest.Claim",
        schema = {
            type = "object",
            required = { "questId" },
            allowUnknown = false,
            fields = { questId = QUEST_ID_SCHEMA },
        },
        rate = ServerConfig.RATES.DailyClaim,
        handler = AsyncMutation(services, "claim quest", function(state, payload, now)
            return QuestEngine.Claim(state, payload.questId, now)
        end),
    })

    router:Register({
        name = "Quest.ClaimAll",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.DailyClaim,
        handler = AsyncMutation(services, "claim all quests", function(state, payload, now)
            return QuestEngine.ClaimAll(state, now)
        end),
    })
end

return QuestCommands
