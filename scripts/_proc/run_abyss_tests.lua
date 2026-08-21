local AbyssDefinitions = require("shared.AbyssDefinitions")
local AbyssEngine = require("server.domain.AbyssEngine")
local CombatEngine = require("server.domain.CombatEngine")
local GameEngine = require("server.domain.GameEngine")
local StateFactory = require("server.domain.StateFactory")
local StateNormalizer = require("server.domain.StateNormalizer")
local FloorRoute = require("shared.FloorRoute")
local GameStateSchema = require("shared.GameStateSchema")
local GameEventSchema = require("shared.GameEventSchema")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local PlayerTransition = require("server.domain.PlayerTransition")
local RewardClaimEngine = require("server.domain.RewardClaimEngine")
local RewardEngine = require("server.domain.RewardEngine")
local ActivityEngine = require("server.domain.ActivityEngine")
local ChallengeEngine = require("server.domain.ChallengeEngine")
local ScoreLeaderboardService = require("server.services.ScoreLeaderboardService")

local function currencyNumber(value)
    local normalized = LargeNumber.Normalize(value)
    return normalized.high * LargeNumber.BASE * LargeNumber.BASE
        + normalized.mid * LargeNumber.BASE
        + normalized.low
end

local function queueRng(floats)
    local rng = { floats = floats or {}, index = 1 }
    function rng:Float()
        local value = self.floats[self.index]
        self.index = self.index + 1
        return value == nil and 0.99 or value
    end
    function rng:Int(minimum)
        return minimum
    end
    return rng
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format(
            "%s: expected %s, got %s",
            message or "值不一致",
            tostring(expected),
            tostring(actual)
        ))
    end
end

local function assertTrue(value, message)
    if not value then error(message or "预期条件成立") end
end

local function assertNetworkEvents(events)
    local networkEvents, reason =
        GameStateSchema.CanonicalizeGameEvents(events)
    assertTrue(networkEvents ~= nil, reason)
    local valid, validationReason =
        GameEventSchema.ValidateList(networkEvents)
    assertTrue(valid, validationReason)
    return networkEvents
end

local function findEvent(events, kind)
    for _, event in ipairs(events or {}) do
        if event.kind == kind or event.type == kind then return event end
    end
    return nil
end

local function readyState(now)
    local state = StateFactory.Create(now)
    state.tutorial.completed = true
    state.storyProgress.introCompleted = true
    state.pendingStoryGate = nil
    state.pauseReason = nil
    return state
end

local function enterNextEncounter(state, rng, now)
    local room = math.min(10, (state.position or 0) + 1)
    return GameEngine.EnterEncounter(state, {
        routeId = FloorRoute.RouteId(state.floor),
        encounterId = FloorRoute.EncounterId(state.floor, room),
        room = room,
    }, rng, now)
end

local function testDefinitions()
    local costs = {
        [1] = 40,
        [10] = 40,
        [11] = 50,
        [20] = 50,
        [21] = 60,
        [40] = 70,
        [41] = 80,
    }
    for level, expected in pairs(costs) do
        assertEqual(
            AbyssDefinitions.BaseTicketCost(level),
            expected,
            "等级阶梯消耗"
        )
    end
    assertEqual(AbyssDefinitions.TicketCost(21, "rift"), 60)
    assertEqual(AbyssDefinitions.TicketCost(21, "mutated"), 120)
    assertEqual(AbyssDefinitions.TicketCost(41, "calamity"), 240)
    assertEqual(AbyssDefinitions.DailyAdTickets(1), 96)
    local poolMin, poolMax = AbyssDefinitions.EquipmentLevelPool(21)
    assertEqual(poolMin, 21)
    assertEqual(poolMax, 30)
    assertTrue(not AbyssDefinitions.IsUnlocked("mutated", 19))
    assertTrue(AbyssDefinitions.IsUnlocked("mutated", 20))
    assertTrue(not AbyssDefinitions.IsUnlocked("calamity", 39))
    assertTrue(AbyssDefinitions.IsUnlocked("calamity", 40))
end

local function testActivitySettlement()
    local state = readyState(1000)
    local fragmentsBefore = currencyNumber(state.fragments)
    local result = AbyssEngine.EnterActivity(
        state,
        "rift",
        1001,
        queueRng({ 0.99 })
    )
    assertTrue(result.ok, "裂隙深渊应可进入")
    assertEqual(result.state.abyss.tickets, 90, "扣票后返还 10 张")
    assertEqual(result.state.abyss.activeRuns, 1)
    assertEqual(result.state.abyss.dryStreak, 1)
    assertEqual(
        currencyNumber(result.state.fragments),
        fragmentsBefore + 12,
        "发放裂隙碎片"
    )
    local completed = findEvent(result.delta.events, "abyss_completed")
    assertTrue(completed ~= nil)
    assertEqual(completed.ticketCost, 40)
    assertEqual(completed.abyssTickets, 10)
    assertEqual(completed.equipmentDropped, false)
    assertEqual(#result.state.rewardClaims.pending, 1)
    assertEqual(
        result.state.rewardClaims.pending[1].extraReward.abyssTickets,
        40
    )
    assertTrue(GameStateSchema.ValidateState(result.state))
    assertNetworkEvents(result.delta.events)

    local locked = AbyssEngine.EnterActivity(
        state,
        "mutated",
        1002,
        queueRng()
    )
    assertTrue(not locked.ok)
    assertEqual(locked.error.code, "ABYSS_GRADE_LOCKED")
    assertEqual(state.abyss.tickets, 120, "失败不得修改输入状态")

    state.abyss.tickets = 39
    local insufficient = AbyssEngine.EnterActivity(
        state,
        "rift",
        1003,
        queueRng()
    )
    assertTrue(not insufficient.ok)
    assertEqual(insufficient.error.code, "ABYSS_TICKET_INSUFFICIENT")
    assertEqual(state.abyss.tickets, 39)
end

local function testHardPity()
    local state = readyState(2000)
    state.abyss.dryStreak = 5
    local inventoryBefore = #state.inventory
    local result = AbyssEngine.EnterActivity(
        state,
        "rift",
        2001,
        queueRng({ 0.0 })
    )
    assertTrue(result.ok)
    assertEqual(result.state.abyss.dryStreak, 0)
    assertEqual(result.state.abyss.equipmentDrops, 1)
    assertEqual(#result.state.inventory, inventoryBefore + 1)
    local completed = findEvent(result.delta.events, "abyss_completed")
    assertTrue(completed and completed.equipmentDropped)
    assertTrue(completed.guaranteed)
    assertTrue(completed.itemId ~= nil)
    assertTrue(GameStateSchema.ValidateState(result.state))
    assertNetworkEvents(result.delta.events)
end

local function fillInventory(state)
    local template = state.inventory[1]
    local capacity = 300
    while #state.inventory < capacity do
        local copy = {}
        for key, value in pairs(template) do
            copy[key] = type(value) == "table"
                and GameStateSchema.DeepCopy(value) or value
        end
        copy.id = string.format(
            "00000000-0000-4000-9000-%012x",
            #state.inventory + 1000
        )
        copy.locked = true
        state.inventory[#state.inventory + 1] = copy
    end
end

local function fillTemporaryLoot(state)
    state.overflowLoot = state.overflowLoot or {}
    local template = state.inventory[1]
    while #state.overflowLoot
        < GameStateSchema.TEMPORARY_LOOT_CAP
    do
        local copy = GameStateSchema.DeepCopy(template)
        copy.id = string.format(
            "00000000-0000-4000-a000-%012x",
            #state.overflowLoot + 5000
        )
        copy.locked = true
        state.overflowLoot[#state.overflowLoot + 1] = copy
    end
end

local function testFullInventoryRollback()
    local state = readyState(2500)
    fillInventory(state)
    state.inventoryPolicy.pauseOnFull = false
    state.abyss.dryStreak = 5
    local ticketsBefore = state.abyss.tickets
    local fragmentsBefore = currencyNumber(state.fragments)
    local result = AbyssEngine.EnterActivity(
        state,
        "rift",
        2501,
        queueRng({ 0.0 })
    )
    assertTrue(not result.ok)
    assertEqual(result.error.code, "INVENTORY_FULL")
    assertEqual(state.abyss.tickets, ticketsBefore)
    assertEqual(state.abyss.dryStreak, 5)
    assertEqual(currencyNumber(state.fragments), fragmentsBefore)
end

local function testRandomAbyssFullInventoryRollback()
    local state = readyState(2800)
    state.autoRun = true
    state.abyss.dryStreak = 5
    state.inventoryPolicy.pauseOnFull = false

    local started = enterNextEncounter(
        state,
        queueRng({ 0.0, 0.0 }),
        2801
    )
    assertTrue(started.ok)
    assertTrue(started.state.abyss.currentRandom ~= nil)
    fillInventory(started.state)
    fillTemporaryLoot(started.state)

    local monsterId = started.state.currentMonster.id
    local runId = started.state.abyss.currentRandom.runId
    local goldBefore = currencyNumber(started.state.gold)
    local fragmentsBefore = currencyNumber(
        started.state.fragments
    )
    local expBefore = started.state.exp
    local killBonusBefore = started.state.floorKillBonus
    local randomRunsBefore = started.state.abyss.randomRuns
    local equipmentDropsBefore =
        started.state.abyss.equipmentDrops

    local events = {}
    local callbacks = {
        settleVictory = function(
            working,
            monster,
            rng,
            now,
            outEvents
        )
            PlayerTransition.AddCurrency(
                working,
                "gold",
                LargeNumber.FromNumber(10)
            )
            working.exp = working.exp + 10
            working.floorKillBonus =
                working.floorKillBonus + 0.01
            outEvents[#outEvents + 1] =
                PlayerTransition.Event(
                    "battle_reward",
                    {
                        gold = LargeNumber.FromNumber(10),
                        exp = 10,
                        rewardRate = 1,
                        offline = false,
                    }
                )
            local settled = AbyssEngine.SettleWorking(
                working,
                "random",
                monster.abyssGradeId,
                0,
                monster.abyssRunId,
                rng,
                now,
                outEvents
            )
            return settled, false
        end,
        handlePlayerDeath = function() end,
    }
    started.state.currentMonster.hp = 0
    started.state.currentMonster.hpBig = BigNumber.Zero()
    started.state.currentMonster.phase = "recovery"
    started.state.currentMonster.phaseRemaining = 0
    local inputSnapshot = GameStateSchema.DeepCopy(
        started.state
    )
    local operation = CombatEngine.AdvanceActiveCombat(
        started.state,
        queueRng({ 0.0 }),
        2802,
        60,
        events,
        { offline = false },
        callbacks
    )
    local failed = PlayerTransition.Finalize(
        inputSnapshot,
        started.state,
        2802,
        operation,
        events,
        false,
        false,
        true
    )
    assertTrue(failed.ok)
    assertEqual(failed.delta.operation, "inventory_full")
    assertTrue(failed.state.currentMonster ~= nil)
    assertEqual(failed.state.currentMonster.id, monsterId)
    assertTrue(failed.state.abyss.currentRandom ~= nil)
    assertEqual(
        failed.state.abyss.currentRandom.runId,
        runId
    )
    assertEqual(currencyNumber(failed.state.gold), goldBefore)
    assertEqual(
        currencyNumber(failed.state.fragments),
        fragmentsBefore
    )
    assertEqual(failed.state.exp, expBefore)
    assertEqual(
        failed.state.floorKillBonus,
        killBonusBefore
    )
    assertEqual(
        failed.state.abyss.randomRuns,
        randomRunsBefore
    )
    assertEqual(
        failed.state.abyss.equipmentDrops,
        equipmentDropsBefore
    )
    assertEqual(failed.state.abyss.dryStreak, 5)
    assertEqual(failed.state.autoRun, false)
    assertEqual(failed.state.pauseReason, "inventory_full")
    assertTrue(findEvent(
        failed.delta.events,
        "inventory_full"
    ) ~= nil)
    assertTrue(findEvent(
        failed.delta.events,
        "battle_won"
    ) == nil)
    assertTrue(findEvent(
        failed.delta.events,
        "abyss_completed"
    ) == nil)
    assertTrue(GameStateSchema.ValidateState(failed.state))
    assertNetworkEvents(failed.delta.events)

    local restored = StateNormalizer.Normalize(
        StateNormalizer.ToPersisted(failed.state),
        2803
    )
    assertTrue(restored.currentMonster ~= nil)
    assertTrue(restored.abyss.currentRandom ~= nil)
    assertEqual(
        restored.currentMonster.abyssRunId,
        restored.abyss.currentRandom.runId
    )
end

local function testRewardedFiveTimesOffer()
    local state = readyState(3500)
    local offer = RewardClaimEngine.CreateAdOffer(
        state,
        {
            source = "task",
            sourceKey = "task:test:five-times",
            baseReward = {
                gold = LargeNumber.FromNumber(100),
                exp = 10,
                fragments = 5,
                abyssTickets = 20,
            },
        },
        3501
    )
    assertTrue(offer ~= nil)
    assertEqual(currencyNumber(offer.extraReward.gold), 400)
    assertEqual(offer.extraReward.exp, 40)
    assertEqual(offer.extraReward.fragments, 20)
    assertEqual(offer.extraReward.abyssTickets, 80)

    local goldBefore = currencyNumber(state.gold)
    local fragmentsBefore = currencyNumber(state.fragments)
    local ticketsBefore = state.abyss.tickets
    local result = RewardClaimEngine.ClaimAdExtra(
        state,
        offer.id,
        3502
    )
    assertTrue(result.ok)
    assertEqual(currencyNumber(result.state.gold), goldBefore + 400)
    assertEqual(
        currencyNumber(result.state.fragments),
        fragmentsBefore + 20
    )
    assertEqual(result.state.abyss.tickets, ticketsBefore + 80)
    assertEqual(#result.state.rewardClaims.pending, 0)
    assertTrue(findEvent(
        result.delta.events,
        "reward_ad_extra_claimed"
    ) ~= nil)
    assertNetworkEvents(result.delta.events)

    local duplicate = RewardClaimEngine.ClaimAdExtra(
        result.state,
        offer.id,
        3503
    )
    assertTrue(not duplicate.ok)
    assertEqual(duplicate.error.code, "REWARD_OFFER_NOT_FOUND")

    local persisted = StateNormalizer.ToPersisted(result.state)
    local restored = StateNormalizer.Normalize(persisted, 3504)
    assertTrue(GameStateSchema.ValidateState(restored))
end

local function testSigninTicketsAndExclusiveGifts()
    local state = readyState(3600)
    local signed = ActivityEngine.SignIn(
        state,
        "act_signin_newbie_7",
        3601
    )
    assertTrue(signed.ok)
    assertEqual(signed.state.abyss.tickets, 160)
    assertEqual(#signed.state.rewardClaims.pending, 1)
    assertEqual(
        signed.state.rewardClaims.pending[1].baseReward.abyssTickets,
        40
    )
    assertEqual(
        signed.state.rewardClaims.pending[1].extraReward.abyssTickets,
        160
    )
    assertNetworkEvents(signed.delta.events)

    local daily = RewardClaimEngine.ClaimExclusiveAdGift(
        signed.state,
        "daily",
        3602
    )
    assertTrue(daily.ok)
    assertEqual(daily.state.abyss.tickets, 256)
    assertEqual(daily.state.rewardClaims.exclusive.dailyClaimed, 1)
    local second = RewardClaimEngine.ClaimExclusiveAdGift(
        daily.state,
        "daily",
        3603
    )
    assertTrue(second.ok)
    local third = RewardClaimEngine.ClaimExclusiveAdGift(
        second.state,
        "daily",
        3604
    )
    assertTrue(third.ok)
    assertEqual(third.state.rewardClaims.exclusive.dailyClaimed, 3)
    local fourth = RewardClaimEngine.ClaimExclusiveAdGift(
        third.state,
        "daily",
        3605
    )
    assertTrue(not fourth.ok)
    assertEqual(fourth.error.code, "AD_GIFT_ALREADY_CLAIMED")
    local weekly = RewardClaimEngine.ClaimExclusiveAdGift(
        third.state,
        "weekly",
        3606
    )
    assertTrue(not weekly.ok)
    assertEqual(weekly.error.code, "INVALID_AD_GIFT")
    assertNetworkEvents(third.delta.events)
end

local function testRandomAbyssRoundTripAndSettlement()
    local state = readyState(3000)
    state.autoRun = true
    local started = enterNextEncounter(
        state,
        queueRng({ 0.0, 0.0 }),
        3001
    )
    assertTrue(started.ok)
    assertTrue(started.state.currentMonster ~= nil)
    assertEqual(started.state.currentMonster.abyssSource, "random")
    assertEqual(started.state.currentMonster.abyssGradeId, "rift")
    assertTrue(started.state.abyss.currentRandom ~= nil)
    assertEqual(
        started.state.abyss.randomCooldownBattles,
        AbyssDefinitions.RANDOM_COOLDOWN_BATTLES
    )
    assertTrue(findEvent(started.delta.events, "abyss_random_spawned") ~= nil)
    assertNetworkEvents(started.delta.events)

    local restored = StateNormalizer.Normalize(
        StateNormalizer.ToPersisted(started.state),
        3002
    )
    assertEqual(
        restored.currentMonster.abyssRunId,
        started.state.currentMonster.abyssRunId
    )
    assertEqual(restored.currentMonster.abyssGradeId, "rift")
    assertTrue(restored.abyss.currentRandom ~= nil)
    assertTrue(GameStateSchema.ValidateState(restored))

    local fragmentsBefore = currencyNumber(restored.fragments)
    local won = GameEngine.AdvanceCombatTick(
        restored,
        queueRng(),
        3003,
        60
    )
    assertTrue(won.ok)
    assertTrue(won.state.currentMonster == nil)
    assertTrue(won.state.abyss.currentRandom == nil)
    assertEqual(won.state.abyss.randomRuns, 1)
    assertEqual(
        won.state.abyss.randomCooldownBattles,
        AbyssDefinitions.RANDOM_COOLDOWN_BATTLES
    )
    assertEqual(
        currencyNumber(won.state.fragments),
        fragmentsBefore + 12
    )
    local completed = findEvent(won.delta.events, "abyss_completed")
    assertTrue(completed ~= nil)
    assertEqual(completed.source, "random")
    assertEqual(completed.ticketCost, 0)
    assertTrue(GameStateSchema.ValidateState(won.state))
    assertNetworkEvents(won.delta.events)

    won.state.autoRun = true
    local nextBattle = enterNextEncounter(
        won.state,
        queueRng({ 0.0 }),
        3004
    )
    assertTrue(nextBattle.ok)
    assertTrue(findEvent(
        nextBattle.delta.events,
        "abyss_random_spawned"
    ) == nil, "冷却期间不得再次生成随机深渊")
    local nextWon = GameEngine.AdvanceCombatTick(
        nextBattle.state,
        queueRng(),
        3005,
        60
    )
    assertTrue(nextWon.ok)
    assertEqual(
        nextWon.state.abyss.randomCooldownBattles,
        AbyssDefinitions.RANDOM_COOLDOWN_BATTLES - 1
    )
end

local function testStrikeDamageRanksIndependently()
    local state = readyState(4100)
    local started = ActivityEngine.BeginStrike(state, "act_daily_gold", 4101)
    assertTrue(started.ok, "打桩应可开始")
    started.state.activities.act_daily_gold.session.damage = 3600
    local finished = ActivityEngine.FinishStrike(started.state, "act_daily_gold", 4102)
    assertTrue(finished.ok)
    assertEqual(finished.state.challenges.bestStrikeDamage, 3600)
    assertTrue(GameStateSchema.ValidateState(finished.state))
    assertNetworkEvents(finished.delta.events)

    local board = ScoreLeaderboardService.New({
        boardId = "damage",
        keyScore = "lb_dmg",
        keyNick = "lb_dmg_nick",
        clock = function() return 1 end,
    })
    board:Upsert(1, "A", 100)
    board:Upsert(2, "B", 300)
    board:Upsert(1, "A", 50)
    local list = board:GetTop(1)
    assertEqual(list[1].score, 300)
    assertEqual(list[2].score, 100)
    board:Upsert(3, "C", 0)
    assertEqual(board:Count(), 2)
end

local function testAbyssBossChallengeSettle()
    local state = readyState(4200)
    local started = ChallengeEngine.BeginBoss(state, "rift", 4201)
    assertTrue(started.ok, "深渊 Boss 应可开启")
    assertEqual(started.state.abyss.tickets, 80)
    assertTrue(started.state.challenges.bossSession ~= nil)
    assertTrue(GameStateSchema.ValidateState(started.state))
    assertNetworkEvents(started.delta.events)

    started.state.challenges.bossSession.hp = 0
    started.state.challenges.bossSession.damage = 5000
    local killed = ChallengeEngine.FinishBoss(started.state, 4202)
    assertTrue(killed.ok)
    assertEqual(killed.state.challenges.bestBossDamage, 5000)
    assertEqual(killed.state.challenges.bossKills, 1)
    assertTrue(killed.state.challenges.bossSession == nil)
    local completed = findEvent(killed.delta.events, "abyss_completed")
    assertTrue(completed ~= nil)
    assertEqual(completed.source, "boss")
    assertTrue(GameStateSchema.ValidateState(killed.state))
    assertNetworkEvents(killed.delta.events)

    local failState = readyState(4300)
    local failStart = ChallengeEngine.BeginBoss(failState, "rift", 4301)
    failStart.state.challenges.bossSession.hp = 1000
    failStart.state.challenges.bossSession.maxHp = 1000
    failStart.state.challenges.bossSession.damage = 120
    local failed = ChallengeEngine.FinishBoss(failStart.state, 4302)
    assertTrue(failed.ok)
    assertTrue(findEvent(failed.delta.events, "abyss_boss_failed") ~= nil)
    assertEqual(failed.state.challenges.bestBossDamage, 120)
    assertEqual(failed.state.challenges.bossKills, 0)
    assertTrue(failed.state.challenges.bossSession == nil)
    assertTrue(GameStateSchema.ValidateState(failed.state))
    assertNetworkEvents(failed.delta.events)
end

local function testOfflineRewardHasNoAdOffer()
    local state = readyState(5000)
    state.pendingOfflineSeconds = 120
    local claimed = RewardEngine.ClaimOfflineReward(state, {
        seconds = 60,
        gold = LargeNumber.FromNumber(100),
        exp = 10,
        fragments = 5,
        items = {},
        reward = {
            gold = LargeNumber.FromNumber(100),
            exp = 10,
            fragments = 5,
        },
    }, 5001)
    assertTrue(claimed.ok, "离线收益应可领取")
    assertEqual(#claimed.state.rewardClaims.pending, 0)
    assertTrue(findEvent(claimed.delta.events, "reward_offer_pending") == nil)
    assertTrue(findEvent(claimed.delta.events, "offline_collected") ~= nil)
    assertTrue(GameStateSchema.ValidateState(claimed.state))
    assertNetworkEvents(claimed.delta.events)

    local rejected = RewardClaimEngine.CreateAdOffer(state, {
        source = "offline",
        sourceKey = "offline:should-reject",
        baseReward = {
            gold = LargeNumber.FromNumber(100),
            exp = 1,
            fragments = 1,
        },
    }, 5002)
    assertTrue(rejected == nil, "离线收益不得生成激励广告")
end

function Start()
    local tests = {
        { name = "definitions", run = testDefinitions },
        { name = "activity settlement", run = testActivitySettlement },
        { name = "hard pity", run = testHardPity },
        { name = "full inventory rollback", run = testFullInventoryRollback },
        { name = "rewarded five times offer", run = testRewardedFiveTimesOffer },
        {
            name = "signin tickets and exclusive gifts",
            run = testSigninTicketsAndExclusiveGifts,
        },
        {
            name = "random abyss full inventory rollback",
            run = testRandomAbyssFullInventoryRollback,
        },
        {
            name = "random abyss round trip and settlement",
            run = testRandomAbyssRoundTripAndSettlement,
        },
        {
            name = "strike damage ranks independently",
            run = testStrikeDamageRanksIndependently,
        },
        {
            name = "abyss boss challenge settle",
            run = testAbyssBossChallengeSettle,
        },
        {
            name = "offline reward has no ad offer",
            run = testOfflineRewardHasNoAdOffer,
        },
    }
    local ok, reason = pcall(function()
        for _, test in ipairs(tests) do
            test.run()
            print("[abyss-tests] PASS " .. test.name)
        end
    end)
    if ok then
        print(string.format(
            "[abyss-tests] passed: %d/%d",
            #tests,
            #tests
        ))
    else
        print("[abyss-tests] FAILED: " .. tostring(reason))
    end
    engine:Exit()
end
