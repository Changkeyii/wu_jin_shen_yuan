--- 市场命令注册。沿用 CommandRouter 的 schema 校验 / 限流 / 重放缓存 / 按 uid 串行。
local CommandRouter = require("server.core.CommandRouter")
local MarketCatalog = require("shared.MarketCatalog")
local ServerConfig = require("server.ServerConfig")

local MarketCommands = {}

local ITEM_ID_SCHEMA = { type = "string", minLength = 1, maxLength = 64 }
local RARITY_SCHEMA = { type = "string", enum = { "epic", "myth" } }
local SLOT_SCHEMA = {
    type = "string",
    enum = {
        "weapon", "shoulder", "coat", "pants", "belt", "shoes",
        "bracelet", "necklace", "ring", "support", "magicstone", "earring",
    },
}

local EMPTY_SCHEMA = { type = "object", fields = {}, allowUnknown = false }
local CURRENCY_SCHEMA = {
    type = "object",
    allowUnknown = false,
    required = { "high", "mid", "low" },
    fields = {
        high = { type = "integer", min = 0, max = 999999999 },
        mid = { type = "integer", min = 0, max = 999999999 },
        low = { type = "integer", min = 0, max = 999999999 },
    },
}

--- 把领域层的变更结果整理成客户端可消费的响应。
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
            revision = state.revision,
            market = data.market,
        },
    }
end

function MarketCommands.Register(router, services)
    local market = services.marketService

    router:Register({
        name = "Market.Browse",
        schema = {
            type = "object",
            required = {},
            allowUnknown = false,
            fields = {
                rarity = RARITY_SCHEMA,
                slot = SLOT_SCHEMA,
                limit = { type = "integer", min = 1, max = 100 },
            },
        },
        rate = ServerConfig.RATES.MarketBrowse,
        async = true,
        handler = function(context, payload, done)
            local state = services.profileService:GetState(context.uid)
            if not state then
                done(false, { code = "PROFILE_NOT_LOADED", reason = "存档尚未加载" })
                return CommandRouter.PENDING
            end
            market:Browse({
                rarity = payload.rarity,
                slot = payload.slot,
                limit = payload.limit,
                viewerUid = context.uid,
                buyerFloor = state.floor,
            }, function(result)
                done(result.ok, result)
            end)
            return CommandRouter.PENDING
        end,
    })

    router:Register({
        name = "Market.List",
        schema = {
            type = "object",
            required = { "itemId", "price" },
            allowUnknown = false,
            fields = {
                itemId = ITEM_ID_SCHEMA,
                -- 价格不设玩法上下限，仅受三段货币容器的技术边界约束。
                price = CURRENCY_SCHEMA,
            },
        },
        rate = ServerConfig.RATES.MarketMutation,
        async = true,
        handler = function(context, payload, done)
            market:List(context.uid, payload, function(result)
                if result.ok and result.data and result.data.delta then
                    services.sendDelta(context.uid, result.data.delta)
                end
                local response = MutationResponse(result)
                done(response.ok, response)
            end)
            return CommandRouter.PENDING
        end,
    })

    router:Register({
        name = "Market.Cancel",
        schema = {
            type = "object",
            required = { "itemId" },
            allowUnknown = false,
            fields = { itemId = ITEM_ID_SCHEMA },
        },
        rate = ServerConfig.RATES.MarketMutation,
        async = true,
        handler = function(context, payload, done)
            market:Cancel(context.uid, payload, function(result)
                if result.ok and result.data and result.data.delta then
                    services.sendDelta(context.uid, result.data.delta)
                end
                local response = MutationResponse(result)
                done(response.ok, response)
            end)
            return CommandRouter.PENDING
        end,
    })

    router:Register({
        name = "Market.Buy",
        schema = {
            type = "object",
            required = { "itemId", "rarity", "slot" },
            allowUnknown = false,
            fields = {
                itemId = ITEM_ID_SCHEMA,
                rarity = RARITY_SCHEMA,
                slot = SLOT_SCHEMA,
                expectedPrice = CURRENCY_SCHEMA,
            },
        },
        rate = ServerConfig.RATES.MarketMutation,
        async = true,
        handler = function(context, payload, done)
            market:Buy(context.uid, payload, function(result)
                if result.ok and result.data and result.data.delta then
                    services.sendDelta(context.uid, result.data.delta)
                end
                local response = MutationResponse(result)
                done(response.ok, response)
            end)
            return CommandRouter.PENDING
        end,
    })

    router:Register({
        name = "Market.Mailbox",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.MarketQuery,
        async = true,
        handler = function(context, payload, done)
            market:Mailbox(context.uid, function(result)
                done(result.ok, result)
            end)
            return CommandRouter.PENDING
        end,
    })

    router:Register({
        name = "Market.Collect",
        schema = EMPTY_SCHEMA,
        rate = ServerConfig.RATES.MarketQuery,
        async = true,
        handler = function(context, payload, done)
            market:Collect(context.uid, function(result)
                if result.ok and result.data and result.data.delta then
                    services.sendDelta(context.uid, result.data.delta)
                end
                local response = MutationResponse(result)
                done(response.ok, response)
            end)
            return CommandRouter.PENDING
        end,
    })
end

return MarketCommands
