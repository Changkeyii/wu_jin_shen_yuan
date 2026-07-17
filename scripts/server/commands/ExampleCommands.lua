local CommandRouter = require("server.core.CommandRouter")
local ServerCloudExamples = require("server.examples.ServerCloudExamples")
local ServerConfig = require("server.ServerConfig")

local ExampleCommands = {}

function ExampleCommands.Register(router, services)
    router:Register({
        name = "Admin.RunCloudExamples",
        auth = "admin",
        serialized = false,
        async = true,
        cacheResponse = false,
        rate = { refillRate = 0.01, burst = 1 },
        schema = { type = "object", fields = {}, allowUnknown = false },
        handler = function(context, payload, done)
            ServerCloudExamples.Run({
                gateway = services.gateway,
                actorUserId = context.uid,
                isAdmin = function(userId) return services.adminPolicy:IsAdmin(userId) end,
                isPreview = ServerConfig.IsPreviewEnvironment,
            }, function(result)
                done(result.ok, result)
            end)
            return CommandRouter.PENDING
        end,
    })
end

return ExampleCommands
