local CommandRouter = require("server.core.CommandRouter")
local ErrorCodes = require("shared.ErrorCodes")
local OperationQueue = require("server.core.OperationQueue")
local PlayerRegistry = require("server.core.PlayerRegistry")
local RateLimiter = require("server.core.RateLimiter")

local Spec = {}

local function decoder(value)
    if value == "one" then return { amount = 1 } end
    if value == "two" then return { amount = 2 } end
    if value == "empty" then return {} end
    error("invalid json")
end

local function encoder(value)
    return table.concat({ tostring(value.ok), tostring(value.code), tostring(value.reason or "") }, "|")
end

local function request(requestId, command, payloadJson)
    return {
        RequestId = requestId,
        Command = command,
        PayloadJson = payloadJson,
    }
end

function Spec.Run()
    local now = 0
    local registry = PlayerRegistry.New({ clock = function() return now end })
    local limiter = RateLimiter.New({ clock = function() return now end })
    local queue = OperationQueue.New()
    local sent = {}
    local router = CommandRouter.New({
        registry = registry,
        rateLimiter = limiter,
        operationQueue = queue,
        clock = function() return now end,
        decodeJson = decoder,
        encodeJson = encoder,
        send = function(connection, eventName, envelope)
            sent[#sent + 1] = { connection = connection, eventName = eventName, envelope = envelope }
        end,
    })

    local connection = {}
    registry:OnConnected(connection)
    registry:OnAuthenticated(connection, 7, "tester")
    assert(registry:MarkReady(connection))

    local executions = 0
    router:Register({
        name = "Grant",
        schema = {
            fields = { amount = { type = "integer", required = true, min = 1, max = 1 } },
            allowUnknown = false,
        },
        rate = { refillRate = 10, burst = 10 },
        handler = function(context, payload)
            executions = executions + 1
            assert(context.uid == 7)
            return { accepted = payload.amount }
        end,
    })

    assert(router:Dispatch(connection, request("req-1", "Grant", "one")))
    assert(executions == 1 and #sent == 1)
    assert(router:Dispatch(connection, request("req-1", "Grant", "one")))
    assert(executions == 1 and #sent == 2)
    assert(sent[1].envelope.payloadJson == sent[2].envelope.payloadJson)

    local invalid = router:Dispatch(connection, request("req-2", "Grant", "two"))
    assert(not invalid)
    assert(executions == 1)

    local deniedExecutions = 0
    router:Register({
        name = "AdminOnly",
        auth = "admin",
        schema = { fields = {}, allowUnknown = false },
        handler = function()
            deniedExecutions = deniedExecutions + 1
        end,
    })
    assert(not router:Dispatch(connection, request("req-3", "AdminOnly", "empty")))
    assert(deniedExecutions == 0)

    local reuse = router:Dispatch(connection, request("req-1", "Grant", "two"))
    assert(not reuse)
    assert(executions == 1)

    local asyncExecutions = 0
    local finishAsync = nil
    router:Register({
        name = "AsyncMutation",
        schema = { fields = {}, allowUnknown = false },
        async = true,
        handler = function(_, _, done)
            asyncExecutions = asyncExecutions + 1
            finishAsync = done
            return CommandRouter.PENDING
        end,
    })
    assert(router:Dispatch(connection, request("req-4", "AsyncMutation", "empty")))
    local duplicate, duplicateStatus = router:Dispatch(connection, request("req-4", "AsyncMutation", "empty"))
    assert(duplicate and duplicateStatus == "in_progress")
    assert(asyncExecutions == 1)

    local finishOldGeneration = finishAsync
    local replacementConnection = {}
    registry:OnConnected(replacementConnection)
    registry:OnAuthenticated(replacementConnection, 7, "replacement")
    assert(registry:MarkReady(replacementConnection))
    router:Clear(7)
    assert(router:Dispatch(replacementConnection, request("req-4", "AsyncMutation", "empty")))
    assert(asyncExecutions == 1)

    finishOldGeneration(true, { applied = true, generation = 1 })
    assert(asyncExecutions == 2)
    local finishNewGeneration = finishAsync
    finishNewGeneration(true, { applied = true, generation = 2 })

    local replayed, replayStatus = router:Dispatch(
        replacementConnection,
        request("req-4", "AsyncMutation", "empty")
    )
    assert(replayed and replayStatus == "replayed")
    assert(asyncExecutions == 2)
end

return Spec
