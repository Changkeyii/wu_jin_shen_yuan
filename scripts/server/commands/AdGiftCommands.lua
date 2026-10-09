local Router = require("server.core.CommandRouter")
local Engine = require("server.domain.AdGiftEngine")
local D = require("shared.AdGiftDefinitions")
local Config = require("server.ServerConfig")
local T = require("server.domain.PlayerTransition")
local M = {}
function M.Register(router, services)
    router:Register {
        name = "Reward.ListGifts", schema = { type = "object", allowUnknown = false, fields = {} },
        rate = Config.RATES.Progression,
        handler = function(context)
            local state = services.profileService:GetState(context.uid)
            if not state then return false, { ok = false, reason = "角色尚未加载" } end
            local now = os.time()
            local working = T.Copy(state, now)
            local gifts = working.rewardClaims.gifts
            return true, { ok = true, data = { offers = Engine.List(working, now),
                wishUsed = gifts.wishDay == require("shared.WishPoolDefinitions").DayKey(now) and gifts.wishUsed or 0,
                luckyCount = math.floor(((gifts.offers.lucky and gifts.offers.lucky.tickets or 0)
                    + (gifts.quote and gifts.quote.kind == "lucky" and gifts.quote.reward.tickets or 0)) / D.LUCKY_TICKETS) } }
        end,
    }
    local function register(name, field, rule, action)
        router:Register {
            name = name, async = true, rate = Config.RATES.Progression,
            schema = { type = "object", allowUnknown = false, required = { field }, fields = { [field] = rule } },
            handler = function(context, payload, done)
                services.profileService:Apply(context.uid, name, function(state, now)
                    return action(state, payload[field], now)
                end, function(result)
                    if not result.ok then done(false, result); return end
                    local data = result.data or {}
                    if data.delta then services.sendDelta(context.uid, data.delta) end
                    local state = data.state or {}
                    local gifts = state.rewardClaims and state.rewardClaims.gifts or {}
                    done(true, { ok = true, data = { quote = gifts.quote, lastClaim = gifts.lastClaim,
                        committed = data.committed == true, revision = state.revision } })
                end)
                return Router.PENDING
            end,
        }
    end
    register("Reward.PrepareGift", "giftKind", { type = "string", enum = D.ORDER }, Engine.Prepare)
    register("Reward.ClaimGift", "token", { type = "string", minLength = 1, maxLength = 96, pattern = "^gift%.%d+$" }, Engine.Claim)
end
return M
