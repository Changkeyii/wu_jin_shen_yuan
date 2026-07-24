local CommandRouter = require("server.core.CommandRouter")
local GameEngine = require("server.domain.GameEngine")
local ServerConfig = require("server.ServerConfig")

local GameCommands = {}

local EMPTY_SCHEMA = { type = "object", fields = {}, allowUnknown = false }

local SAFE_ID_SCHEMA = {
    type = "string",
    minLength = 1,
    maxLength = 96,
    pattern = "^[%w%._:%-]+$",
}

local AUTOMATION_POLICY_SCHEMA = {
    type = "object",
    required = { "autoEquip", "autoSkipStory" },
    allowUnknown = false,
    fields = {
        autoEquip = { type = "boolean" },
        autoSkipStory = { type = "boolean" },
    },
}

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
        name = "Game.SetInteractionMode",
        schema = {
            type = "object",
            required = { "mode" },
            allowUnknown = false,
            fields = {
                mode = { type = "string", enum = { "normal", "cinematic" } },
            },
        },
        rate = ServerConfig.RATES.AutoRun,
        async = true,
        handler = AsyncMutation(services, "set interaction mode", function(state, payload, now)
            return GameEngine.SetInteractionMode(state, payload.mode, now)
        end),
    })

    router:Register({
        name = "Game.SetAutomationPolicy",
        schema = AUTOMATION_POLICY_SCHEMA,
        rate = ServerConfig.RATES.AutoRun,
        async = true,
        handler = AsyncMutation(services, "set automation policy", function(state, payload, now)
            return GameEngine.SetAutomationPolicy(state, payload, now)
        end),
    })

    router:Register({
        name = "Game.DecideEquip",
        schema = {
            type = "object",
            required = { "action" },
            allowUnknown = false,
            fields = {
                action = { type = "string", enum = { "equip", "keep" } },
                itemId = { type = "string", minLength = 36, maxLength = 36 },
            },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "decide equipment upgrade", function(state, payload, now)
            return GameEngine.DecideEquip(state, payload, now)
        end),
    })

    router:Register({
        name = "Game.UndoEquip",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "undo equipment change", function(state, payload, now)
            return GameEngine.UndoEquip(state, now)
        end),
    })

    router:Register({
        name = "Game.AdvanceStory",
        schema = {
            type = "object",
            required = { "action" },
            allowUnknown = false,
            fields = {
                action = { type = "string", enum = { "next", "skip", "complete" } },
                storyId = SAFE_ID_SCHEMA,
                lineIndex = { type = "integer", min = 1, max = 32 },
            },
        },
        rate = ServerConfig.RATES.AutoRun,
        async = true,
        handler = AsyncMutation(services, "advance story", function(state, payload, now)
            return GameEngine.AdvanceStory(state, payload, now)
        end),
    })

    router:Register({
        name = "Game.AcknowledgeRules",
        schema = {
            type = "object",
            required = { "ruleId" },
            allowUnknown = false,
            fields = { ruleId = SAFE_ID_SCHEMA },
        },
        rate = ServerConfig.RATES.AutoRun,
        async = true,
        handler = AsyncMutation(services, "acknowledge tower rules", function(state, payload, now)
            return GameEngine.AcknowledgeRules(state, payload.ruleId, now)
        end),
    })

    router:Register({
        name = "Game.ClaimAid",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "claim tower aid", function(state, payload, now)
            return GameEngine.ClaimAid(state, now)
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
            required = { "maxRank", "candidateIds" },
            allowUnknown = false,
            fields = {
                maxRank = { type = "integer", min = 1, max = 6 },
                candidateIds = {
                    type = "array",
                    minLength = 1,
                    maxLength = ServerConfig.INVENTORY_CAP,
                    items = { type = "string", minLength = 36, maxLength = 36 },
                },
            },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "decompose equipment", function(state, payload, now)
            return GameEngine.Decompose(state, payload.maxRank, now, payload.candidateIds)
        end),
    })

    router:Register({
        name = "Game.Sell",
        schema = {
            type = "object",
            required = { "maxRank", "candidateIds" },
            allowUnknown = false,
            fields = {
                maxRank = { type = "integer", min = 1, max = 6 },
                candidateIds = {
                    type = "array",
                    minLength = 1,
                    maxLength = ServerConfig.INVENTORY_CAP,
                    items = { type = "string", minLength = 36, maxLength = 36 },
                },
            },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "sell equipment", function(state, payload, now)
            return GameEngine.Sell(state, payload.maxRank, now, payload.candidateIds)
        end),
    })

    router:Register({
        name = "Game.SetEquipmentLock",
        schema = {
            type = "object",
            required = { "itemId", "locked" },
            allowUnknown = false,
            fields = {
                itemId = { type = "string", minLength = 36, maxLength = 36 },
                locked = { type = "boolean" },
            },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "set equipment lock", function(state, payload, now)
            return GameEngine.SetEquipmentLock(state, payload.itemId, payload.locked, now)
        end),
    })

    router:Register({
        name = "Game.SetInventoryPolicy",
        schema = {
            type = "object",
            required = { "pauseOnFull", "autoDecompose", "autoSell", "decomposeRarities", "sellRarities" },
            allowUnknown = false,
            fields = {
                pauseOnFull = { type = "boolean" },
                autoDecompose = { type = "boolean" },
                autoSell = { type = "boolean" },
                decomposeRarities = {
                    type = "object",
                    allowUnknown = false,
                    fields = {
                        common = { type = "boolean" }, advanced = { type = "boolean" },
                        rare = { type = "boolean" }, artifact = { type = "boolean" },
                        legendary = { type = "boolean" }, epic = { type = "boolean" },
                        myth = { type = "boolean", enum = { false } },
                    },
                },
                sellRarities = {
                    type = "object",
                    allowUnknown = false,
                    fields = {
                        common = { type = "boolean" }, advanced = { type = "boolean" },
                        rare = { type = "boolean" }, artifact = { type = "boolean" },
                        legendary = { type = "boolean" }, epic = { type = "boolean" },
                        myth = { type = "boolean", enum = { false } },
                    },
                },
            },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "set inventory policy", function(state, payload, now)
            return GameEngine.SetInventoryPolicy(state, payload, now)
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
