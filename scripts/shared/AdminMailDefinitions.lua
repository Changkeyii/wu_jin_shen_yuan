local MailRules = require("shared.MailRules")
local GameStateSchema = require("shared.GameStateSchema")
local Protocol = require("shared.NetworkProtocol")
local TableUtils = require("shared.TableUtils")

---@class AdminMailDefinitions
local AdminMailDefinitions = {}

AdminMailDefinitions.ATTACH_SCHEMA = {
    type = "array", maxLength = MailRules.MAX_ATTACHMENTS,
    items = {
        type = "object", allowUnknown = false,
        fields = {
            kind = { type = "string", enum = { "currency", "equipment", "item" } },
            currency = { type = "string", enum = { "gold", "fragments" } },
            equipmentId = { type = "string", maxLength = 64 },
            itemId = { type = "string", minLength = 1, maxLength = 64 },
            slot = { type = "string", minLength = 1, maxLength = 32 },
            name = { type = "string", minLength = 1, maxLength = 64 },
            count = { type = "integer", min = 1, max = 1000000000 },
            level = { type = "integer", min = 1, max = 1000000 },
            rarity = { type = "string", enum = GameStateSchema.RARITIES },
        },
    },
}

AdminMailDefinitions.SEND_SCHEMA = {
    type = "object", required = { "targetUid", "title", "body", "mailType" }, allowUnknown = false,
    fields = {
        targetUid = { type = "string", minLength = 1, maxLength = 32, pattern = "^%d+$" },
        title = { type = "string", minLength = 1, maxLength = MailRules.MAX_TITLE },
        body = { type = "string", minLength = 1, maxLength = MailRules.MAX_BODY },
        mailType = { type = "string", enum = { "notice", "reward", "task", "ops", "special" } },
        sender = { type = "string", minLength = 1, maxLength = 32 },
        favorite = { type = "boolean" },
        expireDays = { type = "integer", min = 1, max = 3650 },
        batchId = { type = "string", minLength = 1, maxLength = 128 },
        attachments = AdminMailDefinitions.ATTACH_SCHEMA,
    },
}

function AdminMailDefinitions.BuildSpec(payload, now)
    local ok, err = Protocol.ValidatePayload(payload, AdminMailDefinitions.SEND_SCHEMA)
    if not ok then return nil, err end
    return {
        type = payload.mailType, title = payload.title, body = payload.body,
        sender = payload.sender, favorite = payload.favorite == true,
        batchId = payload.batchId or "gm_test", reason = "GM测试",
        -- Preserve the expiry chosen at send time across offline delivery/retries.
        expireAt = now + (payload.expireDays or MailRules.EXPIRY_DAYS[payload.mailType]) * 86400,
        attachments = TableUtils.DeepCopy(payload.attachments or {}),
    }
end

return AdminMailDefinitions
