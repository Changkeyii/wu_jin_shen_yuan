local CommandRouter = require("server.core.CommandRouter")
local GameStateSchema = require("shared.GameStateSchema")
local ServerConfig = require("server.ServerConfig")

local AdminCommands = {}

local UID = { type = "string", minLength = 1, maxLength = 32, pattern = "^%d+$" }
local REASON = { type = "string", minLength = 1, maxLength = 120 }

local function AsyncAdmin(adminService, action)
    return function(context, payload, done)
        adminService:Execute(context.uid, action, payload, function(result)
            done(result.ok, result)
        end)
        return CommandRouter.PENDING
    end
end

local function Definition(name, schema, rate, handler)
    return {
        name = name,
        auth = "admin",
        schema = schema,
        rate = rate,
        serialized = false,
        async = true,
        handler = handler,
    }
end

function AdminCommands.Register(router, adminService)
    router:Register(Definition("Admin.QueryPlayer", {
        type = "object",
        required = { "targetUid" },
        allowUnknown = false,
        fields = { targetUid = UID },
    }, ServerConfig.RATES.AdminQuery, AsyncAdmin(adminService, "query")))

    router:Register(Definition("Admin.GrantCurrency", {
        type = "object",
        required = { "targetUid", "currency", "amount", "reason" },
        allowUnknown = false,
        fields = {
            targetUid = UID,
            currency = { type = "string", enum = { "gold", "fragments" } },
            amount = { type = "integer", min = 1, max = 1000000 },
            reason = REASON,
        },
    }, ServerConfig.RATES.AdminMutation, AsyncAdmin(adminService, "grant_currency")))

    router:Register(Definition("Admin.GrantEquipment", {
        type = "object",
        required = { "targetUid", "slot", "rarity", "reason" },
        allowUnknown = false,
        fields = {
            targetUid = UID,
            slot = { type = "string", enum = GameStateSchema.SLOTS },
            rarity = { type = "string", enum = GameStateSchema.RARITIES },
            reason = REASON,
        },
    }, ServerConfig.RATES.AdminMutation, AsyncAdmin(adminService, "grant_equipment")))

    router:Register(Definition("Admin.AdjustProgress", {
        type = "object",
        required = { "targetUid", "floor", "position", "reason" },
        allowUnknown = false,
        fields = {
            targetUid = UID,
            floor = { type = "integer", min = 1, max = 100000 },
            position = { type = "integer", min = 0, max = 10 },
            reason = REASON,
        },
    }, ServerConfig.RATES.AdminMutation, AsyncAdmin(adminService, "adjust_progress")))

    router:Register(Definition("Admin.Ban", {
        type = "object",
        required = { "targetUid", "reason" },
        allowUnknown = false,
        fields = { targetUid = UID, reason = REASON },
    }, ServerConfig.RATES.AdminMutation, AsyncAdmin(adminService, "ban")))

    router:Register(Definition("Admin.Unban", {
        type = "object",
        required = { "targetUid", "reason" },
        allowUnknown = false,
        fields = { targetUid = UID, reason = REASON },
    }, ServerConfig.RATES.AdminMutation, AsyncAdmin(adminService, "unban")))

    router:Register(Definition("Admin.GetAudit", {
        type = "object",
        fields = {},
        allowUnknown = false,
    }, ServerConfig.RATES.AdminQuery, AsyncAdmin(adminService, "audit")))
end

return AdminCommands
