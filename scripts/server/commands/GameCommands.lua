local CommandRouter = require("server.core.CommandRouter")
local GameEngine = require("server.domain.GameEngine")
local EquipmentDisposition = require("server.domain.EquipmentDisposition")
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
    required = { "autoEquip", "lootAutoEquip", "autoSkipStory" },
    allowUnknown = false,
    fields = {
        autoEquip = { type = "boolean" },
        lootAutoEquip = { type = "boolean" },
        autoSkipStory = { type = "boolean" },
    },
}

local function MutationResponse(result)
    if not result or not result.ok then return result end
    local data = result.data or {}
    local state = data.state or {}
    local responseData = {
        committed = data.committed == true,
        runtimeOnly = data.runtimeOnly == true,
        alreadyApplied = data.alreadyApplied == true,
        revision = state.revision,
    }
    for _, value in ipairs((data.delta and data.delta.events) or {}) do
        local kind = value.kind or value.type
        if kind == "equipment_decomposed" then
            responseData.reward = {
                gold = value.gold or 0,
                fragments = value.fragments or 0,
                count = value.count or 0,
            }
            break
        elseif kind == "equipment_sold" then
            responseData.reward = {
                gold = value.gold or 0,
                count = value.count or 0,
            }
            break
        end
    end
    return {
        ok = true,
        code = result.code,
        reason = result.reason,
        data = responseData,
    }
end

local function AsyncMutation(services, operationName, mutator)
    return function(context, payload, done)
        services.profileService:Apply(context.uid, operationName, function(state, now)
            return mutator(state, payload, now)
        end, function(result)
            if result.ok and result.data.delta then services.sendDelta(context.uid, result.data.delta) end
            local response = MutationResponse(result)
            done(response.ok, response)
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
        name = "Game.ClaimDailyVip",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.DailyClaim,
        async = true,
        handler = AsyncMutation(services, "claim daily VIP sign-in", function(state, payload, now)
            return GameEngine.ClaimDailySignInVip(state, now)
        end),
    })

    router:Register({
        name = "Game.ClaimDailyAdVip",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.DailyClaim,
        async = true,
        handler = AsyncMutation(services, "claim daily VIP ad", function(state, payload, now)
            return GameEngine.ClaimDailyAdVip(state, now)
        end),
    })

    router:Register({
        name = "Game.ResolveEvent",
        schema = {
            type = "object",
            required = { "eventId", "action" },
            allowUnknown = false,
            fields = {
                eventId = { type = "string", maxLength = 64 },
                action = { type = "string", enum = { "open", "buy", "accept", "skip" } },
            },
        },
        rate = ServerConfig.RATES.Encounter,
        async = true,
        handler = AsyncMutation(services, "resolve tower event", function(state, payload, now)
            return GameEngine.ResolveEvent(state, payload, now)
        end),
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
        name = "Game.EnterEncounter",
        schema = {
            type = "object",
            required = { "routeId", "encounterId", "room" },
            allowUnknown = false,
            fields = {
                routeId = SAFE_ID_SCHEMA,
                encounterId = SAFE_ID_SCHEMA,
                room = { type = "integer", min = 1, max = 10 },
            },
        },
        rate = ServerConfig.RATES.Encounter,
        async = true,
        handler = function(context, payload, done)
            services.profileService:ApplyRuntime(
                context.uid,
                "enter encounter",
                function(state, now)
                    return GameEngine.EnterEncounter(state, payload, nil, now)
                end,
                function(result)
                    if result.ok and result.data.delta then
                        services.sendDelta(context.uid, result.data.delta)
                    end
                    local response = MutationResponse(result)
                    done(response.ok, response)
                end
            )
            return CommandRouter.PENDING
        end,
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
        name = "Game.ClaimLootStash",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = AsyncMutation(services, "claim loot stash", function(state, payload, now)
            return GameEngine.ClaimLootStash(state, now)
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
        name = "Game.DispositionPreview",
        schema = {
            type = "object",
            required = { "mode", "candidateIds" },
            allowUnknown = false,
            fields = {
                mode = { type = "string", enum = { "sell", "decompose" } },
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
        handler = function(context, payload, done)
            local state = services.profileService:GetState(context.uid)
            local result = EquipmentDisposition.Preview(state, payload.mode, payload.candidateIds)
            done(result.ok, result)
            return CommandRouter.PENDING
        end,
    })

    router:Register({
        name = "Game.SellPreview",
        schema = {
            type = "object",
            required = { "itemId" },
            allowUnknown = false,
            fields = {
                itemId = { type = "string", minLength = 36, maxLength = 36 },
            },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = function(context, payload, done)
            local state = services.profileService:GetState(context.uid)
            local result = state
                and GameEngine.GetSellPreview(state, payload.itemId)
                or { ok = false, code = "PROFILE_NOT_LOADED", reason = "profile is not loaded" }
            done(result.ok, result)
            return CommandRouter.PENDING
        end,
    })

    router:Register({
        name = "Game.DecomposePreview",
        schema = {
            type = "object",
            required = { "itemId" },
            allowUnknown = false,
            fields = {
                itemId = { type = "string", minLength = 36, maxLength = 36 },
            },
        },
        rate = ServerConfig.RATES.Equipment,
        async = true,
        handler = function(context, payload, done)
            local state = services.profileService:GetState(context.uid)
            local result = state
                and GameEngine.GetDecomposePreview(state, payload.itemId)
                or { ok = false, code = "PROFILE_NOT_LOADED", reason = "profile is not loaded" }
            done(result.ok, result)
            return CommandRouter.PENDING
        end,
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
        name = "Game.StrengthenPreview",
        schema = {
            type = "object",
            required = { "slot" },
            allowUnknown = false,
            fields = { slot = slotSchema },
        },
        rate = ServerConfig.RATES.Progression,
        async = true,
        handler = function(context, payload, done)
            local state = services.profileService:GetState(context.uid)
            local result = state
                and GameEngine.GetStrengthenPreview(state, payload.slot)
                or { ok = false, code = "PROFILE_NOT_LOADED", reason = "profile is not loaded" }
            done(result.ok, result)
            return CommandRouter.PENDING
        end,
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
        name = "Game.StarPreview",
        schema = {
            type = "object",
            required = { "slot" },
            allowUnknown = false,
            fields = { slot = slotSchema },
        },
        rate = ServerConfig.RATES.Progression,
        async = true,
        handler = function(context, payload, done)
            local state = services.profileService:GetState(context.uid)
            local result = state
                and GameEngine.GetStarPreview(state, payload.slot)
                or { ok = false, code = "PROFILE_NOT_LOADED", reason = "profile is not loaded" }
            done(result.ok, result)
            return CommandRouter.PENDING
        end,
    })
    router:Register({
        name = "Game.Star",
        schema = {
            type = "object",
            required = { "slot", "materialItemId" },
            allowUnknown = false,
            fields = {
                slot = slotSchema,
                materialItemId = { type = "string", minLength = 1, maxLength = 64 },
            },
        },
        rate = ServerConfig.RATES.Progression,
        async = true,
        handler = AsyncMutation(services, "star equipment", function(state, payload, now)
            return GameEngine.Star(state, payload.slot, payload.materialItemId, now)
        end),
    })

    router:Register({
        name = "Game.PreviewOffline",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.PreviewOffline,
        async = true,
        handler = function(context, payload, done)
            services.profileService:PreviewOffline(
                context.uid,
                function(result)
                    done(result.ok, result)
                end
            )
            return CommandRouter.PENDING
        end,
    })

    router:Register({
        name = "Game.CollectOffline",
        schema = {
            type = "object",
            required = { "quoteToken" },
            allowUnknown = false,
            fields = {
                quoteToken = {
                    type = "string",
                    minLength = 16,
                    maxLength = 160,
                },
            },
        },
        rate = ServerConfig.RATES.CollectOffline,
        async = true,
        handler = function(context, payload, done)
            services.profileService:ClaimOffline(
                context.uid,
                payload.quoteToken,
                function(result)
                    local response = result
                    if result.ok then
                        local data = result.data or {}
                        if data.delta then
                            services.sendDelta(
                                context.uid,
                                data.delta
                            )
                        end
                        local reward = nil
                        for _, value in ipairs((data.delta and data.delta.events) or {}) do
                            if (value.kind or value.type) == "offline_collected" then
                                reward = value
                                break
                            end
                        end
                        response = {
                            ok = true,
                            code = result.code,
                            reason = result.reason,
                            data = {
                                committed = data.committed == true,
                                revision = data.state and data.state.revision or nil,
                                reward = reward,
                            },
                        }
                    end
                    done(response.ok, response)
                end
            )
            return CommandRouter.PENDING
        end,
    })
end

return GameCommands
