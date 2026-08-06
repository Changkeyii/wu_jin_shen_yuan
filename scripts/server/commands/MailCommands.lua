-- MailCommands.lua
-- 玩家邮件命令：列表 / 详情 / 阅读 / 领取 / 一键领取 / 收藏 / 删除 / 一键删除。
-- 所有发放与状态以服务端为准。

local CommandRouter = require("server.core.CommandRouter")
local ServerConfig = require("server.ServerConfig")
local MailRules = require("shared.MailRules")

local MailCommands = {}

local MAIL_ID = { type = "string", minLength = 1, maxLength = MailRules.MAX_MAIL_ID_LEN, pattern = "^[%w%-_%.]+$" }
local EMPTY_SCHEMA = { type = "object", fields = {}, allowUnknown = false }

local function MailService(services)
    if not services or not services.mailService then return nil end
    return services.mailService
end

local function MailMutation(services, operation)
    return function(context, payload, done)
        local service = MailService(services)
        if not service then
            done(false, { code = "MAIL_UNAVAILABLE", reason = "邮件系统暂不可用" })
            return CommandRouter.PENDING
        end
        local resultSink = {}
        operation(context, payload, service, resultSink, function(result)
            local response = {
                ok = result.ok,
                code = result.ok and 0 or result.code,
                reason = result.reason,
                data = resultSink,
            }
            if result.ok and result.data and result.data.delta then
                services.sendDelta(context.uid, result.data.delta)
            end
            done(result.ok, response)
        end)
        return CommandRouter.PENDING
    end
end

function MailCommands.Register(router, services)
    router:Register({
        name = "Mail.List",
        schema = {
            type = "object",
            allowUnknown = false,
            fields = {
                scope = { type = "string", enum = { "all", "favorite" } },
            },
        },
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        handler = function(context, payload)
            local service = MailService(services)
            if not service then return false, { code = "MAIL_UNAVAILABLE", reason = "邮件系统暂不可用" } end
            local result = service:List(context.uid, payload and payload.scope == "favorite" and "favorite" or "all")
            return result.ok and { ok = true, data = result.data } or result
        end,
    })

    router:Register({
        name = "Mail.Detail",
        schema = {
            type = "object",
            required = { "mailId" },
            allowUnknown = false,
            fields = { mailId = MAIL_ID },
        },
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        handler = function(context, payload)
            local service = MailService(services)
            if not service then return false, { code = "MAIL_UNAVAILABLE", reason = "邮件系统暂不可用" } end
            local result = service:Detail(context.uid, payload.mailId)
            return result.ok and { ok = true, data = result.data } or result
        end,
    })

    router:Register({
        name = "Mail.Read",
        schema = {
            type = "object",
            required = { "mailId" },
            allowUnknown = false,
            fields = { mailId = MAIL_ID },
        },
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        async = true,
        handler = MailMutation(services, function(context, payload, service, sink, done)
            service:MarkRead(context.uid, payload.mailId, done)
        end),
    })

    router:Register({
        name = "Mail.Claim",
        schema = {
            type = "object",
            required = { "mailId" },
            allowUnknown = false,
            fields = { mailId = MAIL_ID },
        },
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        async = true,
        handler = MailMutation(services, function(context, payload, service, sink, done)
            service:Claim(context.uid, payload.mailId, done, sink)
        end),
    })

    router:Register({
        name = "Mail.ClaimAll",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        async = true,
        handler = MailMutation(services, function(context, payload, service, sink, done)
            service:ClaimAll(context.uid, done, sink)
        end),
    })

    router:Register({
        name = "Mail.Favorite",
        schema = {
            type = "object",
            required = { "mailId" },
            allowUnknown = false,
            fields = { mailId = MAIL_ID },
        },
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        async = true,
        handler = MailMutation(services, function(context, payload, service, sink, done)
            service:Favorite(context.uid, payload.mailId, done)
        end),
    })

    router:Register({
        name = "Mail.Unfavorite",
        schema = {
            type = "object",
            required = { "mailId" },
            allowUnknown = false,
            fields = { mailId = MAIL_ID },
        },
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        async = true,
        handler = MailMutation(services, function(context, payload, service, sink, done)
            service:Unfavorite(context.uid, payload.mailId, done)
        end),
    })

    router:Register({
        name = "Mail.Delete",
        schema = {
            type = "object",
            required = { "mailId" },
            allowUnknown = false,
            fields = { mailId = MAIL_ID },
        },
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        async = true,
        handler = MailMutation(services, function(context, payload, service, sink, done)
            service:Delete(context.uid, payload.mailId, done)
        end),
    })

    router:Register({
        name = "Mail.DeleteFavorited",
        schema = {
            type = "object",
            required = { "mailId" },
            allowUnknown = false,
            fields = { mailId = MAIL_ID },
        },
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        async = true,
        handler = MailMutation(services, function(context, payload, service, sink, done)
            service:UnfavoriteAndDelete(context.uid, payload.mailId, done)
        end),
    })

    router:Register({
        name = "Mail.DeleteRead",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.Leaderboard,
        serialized = false,
        async = true,
        handler = MailMutation(services, function(context, payload, service, sink, done)
            service:DeleteRead(context.uid, done, sink)
        end),
    })
end

return MailCommands
