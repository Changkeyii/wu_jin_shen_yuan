local LargeNumber = require("shared.LargeNumber")
local D = {}
D.ORDER = { "wishSupply", "lucky", "forge", "retry", "boss", "offline", "recycle", "journey" }
D.BOOST = 0.30
D.DAMAGE_REDUCTION = 0.15
D.REWARD_RULE_VERSION = 2
D.VERSION = 3
D.WISH_DAILY_LIMIT = 4
D.LUCKY_INTERVAL = 10
D.LUCKY_TICKETS = 2
D.WISH_SOURCES = "活动·许愿补给：每日4次广告依次得1、2、3、4张；幸运礼包：每首次通关10层解锁一次，广告领取2张。"
D.KINDS = {
    wishSupply = { title = "许愿补给", hint = "完成序章后开放，每日最多领取4次", detail = "每日4次广告依次获得1、2、3、4张，共10张。北京时间零点刷新；已生成的待领奖按原日期结算。" },
    lucky = { title = "幸运礼包", hint = "每首次通关10层解锁一次", detail = "首次通关10、20、30…层各获得一次机会，重复旧层不触发。每次广告领取2张许愿券，未领机会可累计。" },
    forge = { title = "塔灵锻造补给", hint = "完成序章后开放", detail = "强化成本的50%，金币最多15场普通战斗收益、碎片5～80；可重复领取。" },
    retry = { title = "败者再战礼包", hint = "同层首领连续失败两次后开放", detail = "下一场首领战攻击+30%、受到伤害降低15%，最多储存1次；战斗结束失效，不叠加。" },
    boss = { title = "首领战利品加赏", hint = "击败守层首领后开放", detail = "每次首领胜利可加领基础金币的100%，相当于该次首领金币翻倍，每笔仅领一次。" },
    offline = { title = "离线收益加成", hint = "领取离线收益后开放", detail = "每份离线结算可加领基础金币、碎片的50%，每笔仅领一次。" },
    recycle = { title = "背包整理补给", hint = "分解装备后开放", detail = "每批分解可加领基础碎片的50%，不含强化投入返还，每笔仅领一次。" },
    journey = { title = "探险里程礼包", hint = "序章后首次通过10个新楼层开放", detail = "每首次通过10个新楼层，领取5份达标层首领金币；碎片第10层30个，每10层增加5个，最多200个。" },
}
local function integer(value)
    value = tonumber(value) or 0
    if value ~= value or value == math.huge or value == -math.huge then return 0 end
    return math.max(0, math.min(1000000000000, math.floor(value)))
end
function D.JourneyFragments(floor)
    return math.min(200, 30 + math.max(0, math.floor(integer(floor) / 10) - 1) * 5)
end
function D.Reward(value)
    value = type(value) == "table" and value or {}
    return { gold = LargeNumber.Normalize(value.gold), fragments = integer(value.fragments),
        jars = integer(value.jars), boosts = integer(value.boosts), tickets = integer(value.tickets) }
end
function D.Normalize(value, clearedFloor)
    value = type(value) == "table" and value or {}
    local result = { nextId = math.max(1, integer(value.nextId)), lastClaim = tostring(value.lastClaim or ""):sub(1, 96),
        lossFloor = integer(value.lossFloor), losses = integer(value.losses), floors = integer(value.floors),
        version = D.VERSION, highestFloor = integer(value.highestFloor), lastEvents = {},
        wishDay = integer(value.wishDay), wishUsed = math.min(D.WISH_DAILY_LIMIT, integer(value.wishUsed)),
        luckyHighest = integer(value.luckyHighest or math.max(tonumber(clearedFloor) or 0, tonumber(value.highestFloor) or 0)),
        boostCharges = math.min(1, integer(value.boostCharges)), boostActive = value.boostActive == true, offers = {} }
    for _, kind in ipairs(D.ORDER) do
        if type(value.offers) == "table" and type(value.offers[kind]) == "table" then
            result.offers[kind] = D.Reward(value.offers[kind])
        end
    end
    for _, kind in ipairs(D.ORDER) do
        result.lastEvents[kind] = tostring(type(value.lastEvents) == "table" and value.lastEvents[kind] or ""):sub(1, 96)
    end
    local quote = value.quote
    if type(quote) == "table" and D.KINDS[quote.kind] and type(quote.id) == "string"
        and #quote.id <= 96 and quote.id:match("^gift%.%d+$") then
        result.quote = { id = quote.id, kind = quote.kind, reward = D.Reward(quote.reward) }
        result.quote.ruleVersion = math.min(D.REWARD_RULE_VERSION, math.max(1, integer(quote.ruleVersion)))
        result.quote.benefit = tostring(quote.benefit or ""):sub(1, 512)
        if quote.kind == "wishSupply" then result.quote.day = integer(quote.day) end
    end
    if (tonumber(value.version) or 1) < 2 and result.quote then
        result.offers[result.quote.kind] = nil
    end
    return result
end
function D.Schema(currency)
    local count = { type = "integer", min = 0, max = 1000000000000 }
    local reward = { type = "object", allowUnknown = false, required = { "gold", "fragments", "jars", "boosts" },
        fields = { gold = currency, fragments = count, jars = count, boosts = count, tickets = count } }
    local offers = {}
    for _, kind in ipairs(D.ORDER) do offers[kind] = reward end
    local eventFields = {}
    for _, kind in ipairs(D.ORDER) do eventFields[kind] = { type = "string", maxLength = 96 } end
    return { type = "object", allowUnknown = false,
        required = { "nextId", "lastClaim", "lossFloor", "losses", "floors", "boostCharges", "boostActive", "offers" },
        fields = { version = { type = "integer", min = 1, max = D.VERSION }, highestFloor = count,
            wishDay = count, wishUsed = { type = "integer", min = 0, max = D.WISH_DAILY_LIMIT }, luckyHighest = count,
            lastEvents = { type = "object", allowUnknown = false, fields = eventFields }, nextId = { type = "integer", min = 1, max = 1000000000000 },
            lastClaim = { type = "string", maxLength = 96 }, lossFloor = count, losses = count, floors = count,
            boostCharges = count, boostActive = { type = "boolean" },
            offers = { type = "object", allowUnknown = false, fields = offers },
            quote = { type = "object", allowUnknown = false, required = { "id", "kind", "reward" }, fields = {
                id = { type = "string", minLength = 1, maxLength = 96, pattern = "^gift%.%d+$" },
                kind = { type = "string", enum = D.ORDER }, reward = reward, day = count,
                ruleVersion = { type = "integer", min = 1, max = D.REWARD_RULE_VERSION },
                benefit = { type = "string", maxLength = 512 },
            } },
        } }
end
return D
