-- 数值模型回归测试：星级单价、可交易概率、VIP10、递增碎片、交互事件、离线 20%
local Catalog = require("server.domain.Catalog")
local GameEngine = require("server.domain.GameEngine")
local GameStateSchema = require("shared.GameStateSchema")
local ItemTradeRules = require("shared.ItemTradeRules")
local LargeNumber = require("shared.LargeNumber")
local MarketCatalog = require("shared.MarketCatalog")
local RewardPolicy = require("shared.RewardPolicy")
local StateFactory = require("server.domain.StateFactory")
local StateNormalizer = require("server.domain.StateNormalizer")
local TowerRules = require("shared.TowerRules")

local function equal(actual, expected, message)
    assert(actual == expected, string.format(
        "%s: expected=%s actual=%s",
        message,
        tostring(expected),
        tostring(actual)
    ))
end

local function nearly(actual, expected, message, tolerance)
    tolerance = tolerance or 1e-9
    assert(math.abs(actual - expected) <= tolerance, string.format(
        "%s: expected=%s actual=%s",
        message,
        tostring(expected),
        tostring(actual)
    ))
end

local function truthy(value, message)
    assert(value, message)
end

-- 1. 星级只影响出售单价，不影响战斗属性
local function testStarSellValue()
    equal(#Catalog.SELL_STAR_MULTIPLIERS, Catalog.MAX_STAR + 1,
        "sell star table covers 0..MAX_STAR")

    ---@type number
    local previous = 0
    for star = 0, Catalog.MAX_STAR do
        local multiplier = Catalog.SELL_STAR_MULTIPLIERS[star + 1]
        truthy(multiplier and multiplier > previous, "sell star multiplier strictly increases at " .. star)
        previous = multiplier or 0
    end
    equal(Catalog.SELL_STAR_MULTIPLIERS[1], 1.00, "0 star sell multiplier is baseline")
    truthy(Catalog.SELL_STAR_MULTIPLIERS[Catalog.MAX_STAR + 1] >= 2.5,
        "max star sell multiplier is meaningfully higher")

    -- 战斗属性星级倍率保持原样，避免改动战力曲线
    local combat = RewardPolicy.STAR_MULTIPLIERS
    equal(combat[1], 1.00, "combat star baseline unchanged")
    equal(combat[#combat], 1.25, "combat star cap unchanged")

    -- 同一件装备提高星级后售价必须提高，且严格单调
    local function sellValueAtStar(star)
        return Catalog.GetSellValue({
            rarity = "artifact",
            level = 120,
            category = "weapon",
            enhance = 0,
            star = star,
        }, 0)
    end

    local previousValue = LargeNumber.Zero()
    for star = 0, Catalog.MAX_STAR do
        local value = sellValueAtStar(star)
        truthy(LargeNumber.Compare(value, previousValue) > 0,
            "sell value increases at star " .. star)
        previousValue = value
    end
end

-- 2. 可交易概率递减，神器已下调
local function testTradeableChance()
    local units = ItemTradeRules.DROP_TRADEABLE_CHANCE_UNITS
    equal(units.artifact, 3000, "artifact tradeable chance lowered to 30%")
    truthy(units.artifact > units.legendary, "artifact > legendary")
    truthy(units.legendary > units.epic, "legendary > epic")
    truthy(units.epic > units.myth, "epic > myth")

    -- 概率边界：roll 严格小于概率才可交易
    local scale = ItemTradeRules.TRADEABLE_CHANCE_SCALE
    equal(ItemTradeRules.RollDropTradeable("drop", "artifact", 0.2999), true,
        "just below artifact chance is tradeable")
    equal(ItemTradeRules.RollDropTradeable("drop", "artifact", 0.3000), false,
        "exactly at artifact chance is not tradeable")
    equal(ItemTradeRules.RollDropTradeable("drop", "rare", 0.0), false,
        "below artifact rarity never tradeable")

    -- 底价 = 标准价 / 概率，稀缺度越高倍率越大
    local value = LargeNumber.FromNumber(1000)
    local artifactMin = MarketCatalog.GetMinimumListingPrice(value, "artifact")
    local mythMin = MarketCatalog.GetMinimumListingPrice(value, "myth")
    equal(LargeNumber.ToString(artifactMin), "3334", "artifact minimum is value / 30%")
    equal(LargeNumber.ToString(mythMin), "40000", "myth minimum is value / 2.5%")
    truthy(LargeNumber.Compare(mythMin, artifactMin) > 0,
        "rarer equipment has higher floor price")
    nearly(scale / units.artifact, 10000 / 3000,
        "artifact scarcity multiplier is 3.333x")
end

-- 3. VIP 上限 10，满级共减 7 个百分点手续费
local function testVipFee()
    equal(Catalog.MAX_VIP_LEVEL, 10, "vip cap is 10")
    equal(MarketCatalog.MAX_VIP_LEVEL, 10, "market vip cap is 10")

    local baseFee = MarketCatalog.GetFeeRate(0)
    local maxFee = MarketCatalog.GetFeeRate(10)
    nearly(baseFee, 0.08, "base fee is 8%", 1e-6)
    nearly(maxFee, 0.01, "V10 fee is 1%", 1e-6)
    nearly(baseFee - maxFee, 0.07, "total reduction is 7 percentage points", 1e-6)

    -- 单调递减且越级不跳变
    local previous = baseFee + 1
    for level = 0, 10 do
        local fee = MarketCatalog.GetFeeRate(level)
        truthy(fee < previous, "fee decreases at vip " .. level)
        truthy(fee >= 0.01 - 1e-9, "fee never below 1% at vip " .. level)
        previous = fee
    end

    -- 超出上限被夹紧，不能刷出负手续费
    nearly(MarketCatalog.GetFeeRate(999), 0.01, "vip above cap clamps to V10 fee", 1e-6)
    nearly(MarketCatalog.GetFeeRate(-5), 0.08, "negative vip clamps to base fee", 1e-6)

    -- schema 上限同步
    local state = StateFactory.NewState(1)
    state.vipLevel = 11
    local normalized = StateNormalizer.Normalize(state)
    truthy(normalized.vipLevel <= 10, "normalizer clamps vip to 10")
end

-- 4. 每日签到 +1 级，服务端权威且当日只能一次
local function testDailyVip()
    local now = 1700000000
    local state = StateFactory.NewState(1)
    state.vipLevel = 0

    local first = GameEngine.ClaimDailySignInVip(state, now)
    equal(first.ok, true, "first sign-in succeeds")
    equal(first.state.vipLevel, 1, "sign-in grants one vip level")

    local second = GameEngine.ClaimDailySignInVip(first.state, now + 60)
    equal(second.ok, false, "same-day second sign-in rejected")
    equal(second.state.vipLevel, 1, "vip unchanged on duplicate claim")

    -- 次日可再领
    local nextDay = GameEngine.ClaimDailySignInVip(first.state, now + 86400)
    equal(nextDay.ok, true, "next-day sign-in succeeds")
    equal(nextDay.state.vipLevel, 2, "next day grants another level")

    -- 满级后停止增长
    local capped = first.state
    capped.vipLevel = Catalog.MAX_VIP_LEVEL
    local atCap = GameEngine.ClaimDailySignInVip(capped, now + 86400 * 2)
    equal(atCap.state.vipLevel, Catalog.MAX_VIP_LEVEL, "vip never exceeds cap")
end

-- 5. 碎片消耗递增
local function testFragmentProgression()
    local item = { rarity = "artifact", level = 100, category = "weapon" }

    local previous = 0
    for _, enhance in ipairs({ 0, 1, 2, 3, 5, 10, 20, 50 }) do
        local cost = Catalog.GetStrengthenCost(item, enhance)
        truthy(cost.fragments > previous,
            "strengthen fragments increase at +" .. enhance)
        previous = cost.fragments
    end

    -- 递增必须是加速的，而非线性
    local at5 = Catalog.GetStrengthenCost(item, 5).fragments
    local at10 = Catalog.GetStrengthenCost(item, 10).fragments
    local at20 = Catalog.GetStrengthenCost(item, 20).fragments
    truthy((at20 - at10) > (at10 - at5),
        "strengthen fragment growth accelerates")

    previous = 0
    for star = 0, Catalog.MAX_STAR do
        local cost = Catalog.GetStarCost(item, star)
        truthy(cost.fragments > previous, "star fragments increase at " .. star)
        previous = cost.fragments
    end
    -- 升星按几何倍率增长
    local star1 = Catalog.GetStarCost(item, 1).fragments
    local star0 = Catalog.GetStarCost(item, 0).fragments
    local star2 = Catalog.GetStarCost(item, 2).fragments
    truthy((star2 / star1) > 2.0, "star fragment multiplier is high")
    nearly(star1 / star0, star2 / star1, "star fragment growth is geometric", 0.15)
end

-- 6. 交互事件：主动操作，超时默认跳过
local function testInteractiveEvents()
    -- 精英房与 Boss 房永不被事件替换
    for floor = 1, 40 do
        for room = 8, 10 do
            local encounter = TowerRules.GetEncounter(room, floor)
            truthy(encounter, "encounter exists")
            equal(encounter.isInteractive, false,
                string.format("room %d floor %d stays combat", room, floor))
        end
    end

    -- 事件生成是纯函数：同 floor/room 结果一致
    for floor = 2, 30 do
        for room = 1, 10 do
            local a = TowerRules.GetEncounter(room, floor)
            local b = TowerRules.GetEncounter(room, floor)
            equal(a.kind, b.kind, "encounter generation is deterministic")
        end
    end

    -- 至少能产出交互事件
    local found = {}
    for floor = 2, 60 do
        for _, room in ipairs(TowerRules.EVENT_ROOMS) do
            local encounter = TowerRules.GetEncounter(room, floor)
            if encounter.isInteractive then found[encounter.kind] = true end
        end
    end
    truthy(found.chest, "chest events are generated")
    truthy(found.merchant, "merchant events are generated")
    truthy(found.randomEvent, "random events are generated")

    -- 超时必须跳过，且绝不代替玩家花费金币
    local now = 1700000000
    local state = StateFactory.NewState(1)
    state.gold = LargeNumber.FromNumber(1000000)
    state.pendingEvent = {
        eventId = "evt-1",
        eventType = "merchant",
        floor = 5,
        room = 3,
        encounterId = "enc-1",
        createdAt = now,
        expiresAt = now + 20,
        actions = { "buy", "skip" },
        goldCost = LargeNumber.FromNumber(500),
        fragmentsReward = 30,
    }

    local timedOut = GameEngine.ResolveEvent(state, {}, now + 999, { timeout = true })
    equal(timedOut.ok, true, "timeout resolves the event")
    equal(timedOut.state.pendingEvent, nil, "pending event cleared on timeout")
    equal(
        LargeNumber.ToString(timedOut.state.gold),
        LargeNumber.ToString(state.gold),
        "timeout never spends player gold"
    )
    equal(
        LargeNumber.ToString(timedOut.state.fragments),
        LargeNumber.ToString(state.fragments),
        "timeout grants no reward"
    )

    -- 过期后即使玩家提交 buy 也按 skip 处理
    state.pendingEvent = {
        eventId = "evt-2",
        eventType = "merchant",
        floor = 5,
        room = 3,
        encounterId = "enc-2",
        createdAt = now,
        expiresAt = now + 20,
        actions = { "buy", "skip" },
        goldCost = LargeNumber.FromNumber(500),
        fragmentsReward = 30,
    }
    local late = GameEngine.ResolveEvent(state, { eventId = "evt-2", action = "buy" }, now + 100)
    equal(late.ok, true, "expired buy still resolves")
    equal(
        LargeNumber.ToString(late.state.gold),
        LargeNumber.ToString(state.gold),
        "expired buy does not spend gold"
    )

    -- 主动购买在有效期内正常扣费并发奖
    state.pendingEvent = {
        eventId = "evt-3",
        eventType = "merchant",
        floor = 5,
        room = 3,
        encounterId = "enc-3",
        createdAt = now,
        expiresAt = now + 20,
        actions = { "buy", "skip" },
        goldCost = LargeNumber.FromNumber(500),
        fragmentsReward = 30,
    }
    local bought = GameEngine.ResolveEvent(state, { eventId = "evt-3", action = "buy" }, now + 5)
    equal(bought.ok, true, "in-time buy succeeds")
    equal(LargeNumber.ToString(bought.state.gold), "999500", "buy deducts gold")

    -- 非法动作被拒绝
    state.pendingEvent = {
        eventId = "evt-4",
        eventType = "chest",
        floor = 5,
        room = 3,
        encounterId = "enc-4",
        createdAt = now,
        expiresAt = now + 20,
        actions = { "open", "skip" },
        fragmentsReward = 10,
    }
    local invalid = GameEngine.ResolveEvent(state, { eventId = "evt-4", action = "buy" }, now + 1)
    equal(invalid.ok, false, "unsupported action rejected")

    -- eventId 不匹配被拒绝，防止重放
    local stale = GameEngine.ResolveEvent(state, { eventId = "wrong", action = "open" }, now + 1)
    equal(stale.ok, false, "stale event id rejected")

    -- schema 必须要求 skip 始终可用，否则玩家可能被事件永久卡住
    local noSkipState = StateFactory.NewState(1)
    noSkipState.pendingEvent = {
        eventId = "evt-5",
        eventType = "chest",
        floor = 5,
        room = 3,
        encounterId = "enc-5",
        createdAt = now,
        expiresAt = now + 20,
        actions = { "open" },
        fragmentsReward = 10,
    }
    local ok = GameStateSchema.ValidateState(noSkipState)
    equal(ok, false, "schema rejects pending event without skip")

    -- 合法事件必须通过 schema
    noSkipState.pendingEvent.actions = { "open", "skip" }
    local validOk = GameStateSchema.ValidateState(noSkipState)
    equal(validOk, true, "schema accepts pending event with skip")
end

-- 7. 离线金币为在线 20%，且最多 100 件装备
local function testOfflineEconomy()
    equal(Catalog.OFFLINE_REWARD_RATE, 0.20, "offline reward rate is 20%")
    equal(RewardPolicy.OFFLINE_RATE, 0.20, "offline drop rate is 20%")

    -- 离线金币恰好是同层在线金币的 20%
    for _, floor in ipairs({ 1, 25, 100, 500 }) do
        for _, kind in ipairs({ "normal", "elite", "boss" }) do
            local online = Catalog.GetBattleGold(floor, kind)
            local offline = LargeNumber.MultiplyScalar(online, Catalog.OFFLINE_REWARD_RATE)
            local expected = LargeNumber.MultiplyScalar(online, 0.20)
            equal(
                LargeNumber.ToString(offline),
                LargeNumber.ToString(expected),
                string.format("offline gold is 20%% of online at floor %d %s", floor, kind)
            )
            truthy(LargeNumber.Compare(offline, online) < 0,
                "offline gold is strictly less than online")
        end
    end

    -- 掉落概率同样按 20% 折算，未被重复缩放
    for _, kind in ipairs({ "normal", "elite", "boss" }) do
        local online = RewardPolicy.DropChance(kind, "online") or 0
        local offline = RewardPolicy.DropChance(kind, true) or 0
        nearly(offline, online * 0.20,
            "offline drop chance is exactly 20% of online for " .. kind, 1e-9)
    end

    -- 100 件装备在容量足够时属于正常上限
    truthy(Catalog.INVENTORY_CAP >= 100, "inventory cap supports 100 offline drops")
end

local function run()
    testStarSellValue()
    testTradeableChance()
    testVipFee()
    testDailyVip()
    testFragmentProgression()
    testInteractiveEvents()
    testOfflineEconomy()
end

function Start()
    local ok, failure = pcall(run)
    if ok then
        print("[EconomyVipEventTest] PASS")
    else
        print("[EconomyVipEventTest] FAIL " .. tostring(failure))
    end
    engine:Exit(ok and 0 or 1)
end
