local CommandRouter = require("server.core.CommandRouter")
local GameEngine = require("server.domain.GameEngine")
local ServerConfig = require("server.ServerConfig")

local GameCommands = {}

local EMPTY_SCHEMA = { type = "object", fields = {}, allowUnknown = false }

local function AsyncMutation(services, operationName, mutator)
    return function(context, payload, done)
        services.profileService:Apply(context.uid, operationName, function(state, now)
            return mutator(state, payload, now)
        end, function(result)
            if result.ok and result.data.delta then services.sendDelta(context.uid, result.data.delta) end
            done(result.ok, result)
        end)
        return CommandRouter.PENDING
    end
end

function GameCommands.Register(router, services)
    router:Register({
        name = "Game.RequestSnapshot",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Snapshot,
        serialized = false,
        handler = function(context)
            local snapshot = services.sendSnapshot(context.uid)
            if not snapshot then return false, { code = "PROFILE_NOT_LOADED", reason = "profile is not loaded" } end
            return { status = "applied", revision = snapshot.revision }
        end,
    })

    router:Register({
        name = "Game.SetAutoRun",
        schema = {
            type = "object",
            required = { "enabled" },
            allowUnknown = false,
            fields = { enabled = { type = "boolean" } },
        },
        rate = ServerConfig.RATES.AutoRun,
        async = true,
        handler = AsyncMutation(services, "set auto run", function(state, payload, now)
            return GameEngine.SetAutoRun(state, payload.enabled, now)
        end),
    })

    router:Register({
        name = "Game.Equip",
        schema = {
            type = "object",
            required = { "itemId" },
            allowUnknown = false,
            fields = { itemId = { type = "string", minLength = 1, maxLength = 64 } },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "equip item", function(state, payload, now)
            return GameEngine.Equip(state, payload.itemId, now)
        end),
    })

    router:Register({
        name = "Game.AutoEquip",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "auto equip", function(state, payload, now)
            return GameEngine.AutoEquip(state, now)
        end),
    })

    router:Register({
        name = "Game.Decompose",
        schema = {
            type = "object",
            required = { "maxRank" },
            allowUnknown = false,
            fields = { maxRank = { type = "integer", min = 1, max = 4 } },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "decompose equipment", function(state, payload, now)
            return GameEngine.Decompose(state, payload.maxRank, now)
        end),
    })

    local slotSchema = {
        type = "string",
        enum = {
            "weapon", "shoulder", "coat", "pants", "belt", "shoes",
            "bracelet", "necklace", "ring", "support", "magicstone", "earring",
        },
    }
    router:Register({
        name = "Game.Unequip",
        schema = {
            type = "object",
            required = { "slot" },
            allowUnknown = false,
            fields = { slot = slotSchema },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "unequip equipment", function(state, payload, now)
            return GameEngine.Unequip(state, payload.slot, now)
        end),
    })

    router:Register({
        name = "Game.Strengthen",
        schema = {
            type = "object",
            required = { "slot" },
            allowUnknown = false,
            fields = { slot = slotSchema },
        },
        rate = ServerConfig.RATES.Progression,
        async = true,
        handler = AsyncMutation(services, "strengthen equipment", function(state, payload, now)
            return GameEngine.Strengthen(state, payload.slot, now)
        end),
    })
    router:Register({
        name = "Game.Star",
        schema = {
            type = "object",
            required = { "slot" },
            allowUnknown = false,
            fields = { slot = slotSchema },
        },
        rate = ServerConfig.RATES.Progression,
        async = true,
        handler = AsyncMutation(services, "star equipment", function(state, payload, now)
            return GameEngine.Star(state, payload.slot, now)
        end),
    })

    router:Register({
        name = "Game.CollectOffline",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.CollectOffline,
        async = true,
        handler = AsyncMutation(services, "collect offline reward", function(state, payload, now)
            return GameEngine.CollectOffline(state, now)
        end),
    })
end

return GameCommands
