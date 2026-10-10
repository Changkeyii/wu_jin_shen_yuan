local CommandRouter = require("server.core.CommandRouter")
local GameStateSchema = require("shared.GameStateSchema")
local ServerConfig = require("server.ServerConfig")
local MailRules = require("shared.MailRules")
local AdminMailDefinitions = require("shared.AdminMailDefinitions")

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

local function MailService(services)
    return services and services.mailService or nil
end

-- GM 邮件操作（auth = "admin"，服务端校验管理员）
local function AdminMailMutation(services, operation)
    return function(context, payload, done)
        local service = MailService(services)
        if not service then
            done(false, { code = "MAIL_UNAVAILABLE", reason = "邮件系统暂不可用" })
            return CommandRouter.PENDING
        end
        local targetUserId = tonumber(payload.targetUid)
        if not targetUserId then
            done(false, { code = "INVALID_UID", reason = "目标玩家编号无效" })
            return CommandRouter.PENDING
        end
        if not services.profileService:GetSession(targetUserId) then
            done(false, { code = "TARGET_OFFLINE", reason = "目标玩家未在线，暂不支持离线投递" })
            return CommandRouter.PENDING
        end
        local sink = {}
        operation(context, targetUserId, payload, service, sink, function(result)
            if result.ok and result.data and result.data.delta then
                services.sendDelta(targetUserId, result.data.delta)
            end
            local response = {
                ok = result.ok,
                code = result.ok and 0 or result.code,
                reason = result.reason,
                data = sink,
            }
            done(result.ok, response)
        end)
        return CommandRouter.PENDING
    end
end

function AdminCommands.Register(router, adminService, services)
    services = services or {}
    router:Register(Definition("Admin.QueryPlayer", {
        type = "object",
        required = { "targetUid" },
        allowUnknown = false,
        fields = { targetUid = UID },
    }, ServerConfig.RATES.AdminQuery, AsyncAdmin(adminService, "query")))

    router:Register(Definition("Admin.QueryByName", {
        type = "object",
        required = { "name" },
        allowUnknown = false,
        fields = { name = { type = "string", minLength = 1, maxLength = 32 } },
    }, ServerConfig.RATES.AdminQuery, AsyncAdmin(adminService, "query_by_name")))

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

    router:Register(Definition("Admin.SetAdFree", {
        type = "object", required = { "targetUid", "enabled", "reason" }, allowUnknown = false,
        fields = { targetUid = UID, enabled = { type = "boolean" }, reason = REASON },
    }, ServerConfig.RATES.AdminMutation, AsyncAdmin(adminService, "set_ad_free")))

    router:Register(Definition("Admin.MailDeliveryStatus", {
        type = "object", required = { "targetUid" }, allowUnknown = false, fields = { targetUid = UID,
            mailId = { type = "string", minLength = 1, maxLength = 128, pattern = "^[%w%._:%-]+$" } },
    }, ServerConfig.RATES.AdminQuery, function(context, payload, done)
        if not services.mailService then
            done(false, { code = "MAIL_UNAVAILABLE", reason = "邮件系统暂不可用" })
        else
            adminService:InspectMailDelivery(context.uid, payload.targetUid, services.mailService, function(result)
                done(result.ok, result)
            end, payload.mailId)
        end
        return CommandRouter.PENDING
    end))

    -- ============================================================
    -- 个人发件支持离线；邮箱查询/清理仍操作当前实例中的存档。
    -- ============================================================

    local ATTACH_SCHEMA = AdminMailDefinitions.ATTACH_SCHEMA

    router:Register(Definition("Admin.SendMail", AdminMailDefinitions.SEND_SCHEMA,
        ServerConfig.RATES.AdminMutation, AsyncAdmin(adminService, "send_mail")))

    router:Register(Definition("Admin.SendBroadcastMail", {
        type = "object",
        required = { "title", "body", "mailType" },
        allowUnknown = false,
        fields = {
            title = { type = "string", minLength = 1, maxLength = MailRules.MAX_TITLE },
            body = { type = "string", minLength = 1, maxLength = MailRules.MAX_BODY },
            mailType = { type = "string", enum = { "notice", "reward", "task", "ops", "special" } },
            sender = { type = "string", minLength = 1, maxLength = 32 },
            favorite = { type = "boolean" },
            expireDays = { type = "integer", min = 1, max = 3650 },
            attachments = ATTACH_SCHEMA,
        },
    }, ServerConfig.RATES.AdminMutation, function(context, payload, done)
        local service = MailService(services)
        if not service then
            done(false, { code = "MAIL_UNAVAILABLE", reason = "邮件系统暂不可用" })
            return CommandRouter.PENDING
        end
        local spec = {
            type = payload.mailType,
            title = payload.title,
            body = payload.body,
            sender = payload.sender,
            favorite = payload.favorite == true,
            reason = "全服邮件",
            attachments = payload.attachments,
        }
        if payload.expireDays then
            spec.expireAt = os.time() + payload.expireDays * 24 * 3600
        end
        local sink = {}
        service:SendBroadcast(spec, function(result)
            local response = {
                ok = result.ok,
                code = result.ok and 0 or result.code,
                reason = result.reason,
                data = sink,
            }
            if result.ok then
                -- 在线玩家投递成功后，推送轻量 mailSummary delta 刷新首页红点
                if services.sendDelta and sink.deliveredUsers then
                    for _, uid in ipairs(sink.deliveredUsers) do
                        services.sendDelta(uid, { changes = {} })
                    end
                end
                response.status = string.format(
                    "全服邮件已创建（批次 %s，在线 %d 人，本次新投递 %d 封，离线玩家登录后自动补发）",
                    tostring(sink.batchId or "-"),
                    tonumber(sink.totalOnline or 0),
                    tonumber(sink.delivered or 0)
                )
            end
            done(result.ok, response)
        end, sink)
        return CommandRouter.PENDING
    end))

    router:Register(Definition("Admin.MailList", {
        type = "object",
        required = { "targetUid" },
        allowUnknown = false,
        fields = { targetUid = UID },
    }, ServerConfig.RATES.AdminQuery, function(context, payload, done)
        local service = MailService(services)
        if not service then
            done(false, { code = "MAIL_UNAVAILABLE", reason = "邮件系统暂不可用" })
            return CommandRouter.PENDING
        end
        local targetUserId = tonumber(payload.targetUid)
        if not targetUserId then
            done(false, { code = "INVALID_UID", reason = "目标玩家编号无效" })
            return CommandRouter.PENDING
        end
        local result = service:List(targetUserId, "all")
        done(result.ok, result)
        return CommandRouter.PENDING
    end))

    router:Register(Definition("Admin.MailForceExpire", {
        type = "object",
        required = { "targetUid", "mailId" },
        allowUnknown = false,
        fields = {
            targetUid = UID,
            mailId = { type = "string", minLength = 1, maxLength = MailRules.MAX_MAIL_ID_LEN },
        },
    }, ServerConfig.RATES.AdminMutation, AdminMailMutation(services, function(context, targetUserId, payload, service, sink, done)
        service:ForceExpire(targetUserId, payload.mailId, done)
    end)))

    router:Register(Definition("Admin.MailCleanTest", {
        type = "object",
        required = { "targetUid" },
        allowUnknown = false,
        fields = { targetUid = UID },
    }, ServerConfig.RATES.AdminMutation, AdminMailMutation(services, function(context, targetUserId, payload, service, sink, done)
        service:CleanTest(targetUserId, done, sink)
    end)))
end

return AdminCommands
