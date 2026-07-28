local Catalog = require("server.domain.Catalog")
local GameEngine = require("server.domain.GameEngine")
local StateFactory = require("server.domain.StateFactory")
local StateNormalizer = require("server.domain.StateNormalizer")
local TableUtils = require("server.domain.TableUtils")
local GameStateSchema = require("shared.GameStateSchema")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local PowerEvaluator = require("shared.PowerEvaluator")
local StoryCatalog = require("shared.StoryCatalog")
local FloorRoute = require("shared.FloorRoute")

local Spec = {}

local function queueRng(integers, floats)
    local rng = { integers = integers or {}, floats = floats or {}, integerIndex = 1, floatIndex = 1 }
    function rng:Int(minimum, maximum)
        local value = self.integers[self.integerIndex]
        self.integerIndex = self.integerIndex + 1
        if value == nil then return minimum end
        return math.max(minimum, math.min(maximum, value))
    end
    function rng:Float()
        local value = self.floats[self.floatIndex]
        self.floatIndex = self.floatIndex + 1
        return value == nil and 0.99 or value
    end
    return rng
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function assertTrue(value, message)
    if not value then error(message or "expected truthy value", 2) end
end

local function eventCount(events, kind)
    local count = 0
    for _, value in ipairs(events or {}) do
        if value.kind == kind or value.type == kind then count = count + 1 end
    end
    return count
end

local function findEvent(events, kind)
    for _, value in ipairs(events or {}) do
        if value.kind == kind or value.type == kind then return value end
    end
    return nil
end

local function currency(value)
    value = LargeNumber.Normalize(value)
    return value.high * LargeNumber.BASE * LargeNumber.BASE
        + value.mid * LargeNumber.BASE + value.low
end

local function skipIntro(state)
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
    }, rng or queueRng(), now)
end

local function highFloorLoadout(floor)
    local state = skipIntro(StateFactory.Create(1000))
    state.floor = floor
    state.maxFloor = floor
    state.position = 1
    state.inventory = {}
    state.equipped = {}
    local definitionsBySlot = {}
    for _, definition in ipairs(Catalog.EQUIPMENT_DEFINITIONS) do
        if not definitionsBySlot[definition.slot] then definitionsBySlot[definition.slot] = definition end
    end
    for index, slot in ipairs(Catalog.SLOTS) do
        local definition = assert(definitionsBySlot[slot.id])
        local generated = Catalog.CreateItemStats(definition, floor, "myth", 1.05, 0, 0)
        local item = {
            id = string.format("00000000-0000-4000-8000-%012x", index),
            equipmentId = definition.id,
            name = definition.name,
            slot = definition.slot,
            category = definition.category,
            rarity = "myth",
            level = floor,
            enhance = 0,
            star = 0,
            locked = false,
            acquiredAt = 1000 + index,
            source = "high_floor_spec",
            investedGold = 0,
            investedFragments = 0,
            coreAffixes = {},
        }
        for key, value in pairs(generated) do item[key] = TableUtils.DeepCopy(value) end
        state.inventory[#state.inventory + 1] = item
        state.equipped[slot.id] = item.id
    end
    state.nextItemId = #state.inventory + 1
    state.stats = Catalog.CalculateStats(state)
    state.hp = nil
    state.hpBig = BigNumber.Clone(state.stats.hpBig)
    return state
end

function Spec.InitialStateIsACompleteEasyLoadout()
    local state = StateFactory.Create(1000)
    assertEqual(state.schemaVersion, 5)
    assertEqual(#state.inventory, 12)
    assertEqual(state.nextItemId, 13)
    for _, slot in ipairs(Catalog.SLOTS) do assertTrue(state.equipped[slot.id] ~= nil, slot.id) end
    assertTrue(state.stats.powerRatio >= 1.05 and state.stats.powerRatio <= 1.20)
    local valid, reason = GameStateSchema.ValidateState(state)
    assertTrue(valid, reason and reason.reason)
end

function Spec.NormalizerMigratesV3WithoutWeakeningOrKeepingInflightCombat()
    local definition = Catalog.EQUIPMENT_DEFINITIONS[1]
    local normalized = StateNormalizer.Normalize({
        schemaVersion = 3,
        floor = 20,
        maxFloor = 20,
        position = 7,
        currentMonster = { eventType = "boss", hp = 1, maxHp = 1 },
        nextItemId = 2,
        inventory = {{
            id = 1,
            equipmentId = definition.id,
            rarity = "blue",
            level = 10,
            enhance = 3,
            star = 1,
        }},
        equipped = { [definition.slot] = 1 },
    }, 1000)
    assertEqual(normalized.schemaVersion, 5)
    assertEqual(normalized.position, 0)
    assertTrue(normalized.currentMonster == nil)
    assertEqual(normalized.inventory[1].rarity, "advanced")
    assertEqual(normalized.inventory[1].statVersion, 5)
    assertTrue(normalized.inventory[1].atk > 0 or normalized.inventory[1].hp > 0)
    assertTrue(normalized.storyProgress.introCompleted)
    assertTrue(GameStateSchema.ValidateState(normalized))
end

function Spec.NormalizerMigratesV4ScalarMagnitudesWithoutChangingTheirValues()
    local original = skipIntro(StateFactory.Create(1000))
    local raw = StateNormalizer.ToPersisted(original)
    raw.schemaVersion = 4
    local expectedHp = raw.hp
    raw.hpBig = nil
    local expectedItems = {}
    for index, item in ipairs(raw.inventory) do
        expectedItems[index] = {
            budget = item.budget,
            atk = item.atk,
            def = item.def,
            hp = item.hp,
        }
        item.statVersion = 4
        item.budgetBig = nil
        item.atkBig = nil
        item.defBig = nil
        item.hpBig = nil
    end

    local migrated = StateNormalizer.Normalize(raw, 1001)
    assertEqual(migrated.schemaVersion, 5)
    assertEqual(BigNumber.Compare(migrated.hpBig, BigNumber.FromNumber(expectedHp)), 0)
    for index, item in ipairs(migrated.inventory) do
        local expected = expectedItems[index]
        assertEqual(BigNumber.Compare(item.budgetBig, BigNumber.FromNumber(expected.budget)), 0)
        assertEqual(BigNumber.Compare(item.atkBig, BigNumber.FromNumber(expected.atk)), 0)
        assertEqual(BigNumber.Compare(item.defBig, BigNumber.FromNumber(expected.def)), 0)
        assertEqual(BigNumber.Compare(item.hpBig, BigNumber.FromNumber(expected.hp)), 0)
    end
    assertTrue(GameStateSchema.ValidateState(migrated))
end

function Spec.PrologueGatePausesCombatWithoutMutatingInput()
    local state = StateFactory.Create(1000)
    local before = TableUtils.DeepCopy(state)
    local enabled = GameEngine.SetAutoRun(state, true, 1001)
    assertTrue(enabled.ok)
    assertTrue(TableUtils.DeepEqual(state, before), "engine mutated input")
    assertTrue(enabled.state.pendingStoryGate ~= nil)
    assertEqual(enabled.state.pendingStoryGate.phase, "prologue")
    local blocked = GameEngine.AdvanceCombatTick(enabled.state, queueRng(), 1002, 1)
    assertTrue(blocked.ok)
    assertEqual(blocked.state.position, 0)
    assertEqual(blocked.delta.kind, "GameDelta")
    assertEqual(blocked.delta.operation, "story_gate")
    local skipped = GameEngine.AdvanceStory(blocked.state, { action = "skip" }, 1003)
    assertTrue(skipped.ok)
    assertTrue(skipped.state.storyProgress.introCompleted)
end

function Spec.EnterEncounterRejectsStaleOrSkippedRouteTargets()
    local state = skipIntro(StateFactory.Create(1000))
    state.autoRun = true

    local stale = GameEngine.EnterEncounter(state, {
        routeId = FloorRoute.RouteId(2),
        encounterId = FloorRoute.EncounterId(2, 1),
        room = 1,
    }, queueRng(), 1001)
    assertTrue(not stale.ok)
    assertEqual(stale.error.code, "STALE_ENCOUNTER")

    local skipped = GameEngine.EnterEncounter(state, {
        routeId = FloorRoute.RouteId(1),
        encounterId = FloorRoute.EncounterId(1, 2),
        room = 2,
    }, queueRng(), 1002)
    assertTrue(not skipped.ok)
    assertEqual(skipped.error.code, "STALE_ENCOUNTER")

    local started = enterNextEncounter(state, queueRng(), 1003)
    assertTrue(started.ok)
    assertEqual(started.state.position, 1)
    assertEqual(started.state.currentMonster.id, FloorRoute.EncounterId(1, 1))
end

function Spec.OnlineAttackAlwaysSettlesFourConfiguredHits()
    local state = skipIntro(StateFactory.Create(1000))
    state.autoRun = true
    local started = enterNextEncounter(state, queueRng(), 1001)
    assertTrue(started.ok and started.state.currentMonster ~= nil)
    local won = GameEngine.AdvanceCombatTick(started.state, queueRng(), 1002, 60)
    assertTrue(won.ok)
    local hitCount = eventCount(won.delta.events, "player_attack_hit")
    assertTrue(hitCount >= 4 and hitCount % 4 == 0)
    assertEqual(eventCount(won.delta.events, "monster_defeated"), 1)
    assertEqual(won.state.transitionRemaining, 0)
    assertTrue(won.state.currentMonster == nil)
end

function Spec.LevelUpDoesNotHealPlayer()
    local state = skipIntro(StateFactory.Create(1000))
    state.autoRun = true
    state.exp = Catalog.NextExp(state.level) - 1
    state.hp = math.floor(state.stats.hp * 0.50)
    local levelBefore = state.level

    local started = enterNextEncounter(state, queueRng(), 1001)
    assertTrue(started.ok and started.state.currentMonster ~= nil)
    local won = GameEngine.AdvanceCombatTick(started.state, queueRng(), 1002, 60)

    assertTrue(won.ok)
    assertTrue(won.state.level > levelBefore)
    assertTrue(won.state.hp < won.state.stats.hp, "level-up must not restore player HP")
    assertEqual(eventCount(won.delta.events, "player_healed"), 0)
end

function Spec.LevelUpEmitsNormalizedProgressPayload()
    local state = skipIntro(StateFactory.Create(1000))
    state.autoRun = true
    state.exp = Catalog.NextExp(state.level) - 1
    local started = enterNextEncounter(state, queueRng(), 1001)
    assertTrue(started.ok)
    local won = GameEngine.AdvanceCombatTick(started.state, queueRng(), 1002, 60)
    assertTrue(won.ok)
    local levelUp = findEvent(won.delta.events, "level_up")
    assertTrue(levelUp ~= nil)
    assertTrue(levelUp.levelsGained >= 1)
    assertEqual(levelUp.level, won.state.level)
    assertEqual(levelUp.exp, won.state.exp)
    assertEqual(levelUp.nextExp, won.state.nextExp)
    assertTrue(won.state.exp < Catalog.NextExp(won.state.level))
end

function Spec.CurrentMonsterRoundTripsWithChapterBossIdentity()
    local state = skipIntro(StateFactory.Create(1000))
    state.floor = 10
    state.maxFloor = 10
    state.position = 9
    state.ruleAcknowledgements["story:1:boss"] = true
    state.ruleAcknowledgements["story:1:opening"] = true
    state.autoRun = true
    local started = enterNextEncounter(state, queueRng(), 1001)
    assertTrue(started.ok and started.state.currentMonster ~= nil)
    assertEqual(started.state.currentMonster.encounter, "chapterBoss")
    local restored = StateNormalizer.Normalize(StateNormalizer.ToPersisted(started.state), 1002)
    assertEqual(restored.currentMonster.encounter, "chapterBoss")
    assertTrue(restored.currentMonster.isChapterBoss)
    assertTrue(GameStateSchema.ValidateState(restored))
end

function Spec.TwoOnlineDeathsResetFloorAndExposeAid()
    local state = skipIntro(StateFactory.Create(1000))
    state.autoRun = true
    state.floorKillBonus = 0.20
    for defeat = 1, 2 do
        local started = enterNextEncounter(state, queueRng(), 1010 + defeat * 2)
        assertTrue(started.ok)
        started.state.currentMonster.atk = 1e9
        started.state.currentMonster.def = 1e9
        started.state.currentMonster.hp = 1e9
        started.state.currentMonster.maxHp = 1e9
        started.state.currentMonster.atkBig = BigNumber.FromNumber(1e9)
        started.state.currentMonster.defBig = BigNumber.FromNumber(1e9)
        started.state.currentMonster.hpBig = BigNumber.FromNumber(1e9)
        started.state.currentMonster.maxHpBig = BigNumber.FromNumber(1e9)
        started.state.currentMonster.nextMonsterAttackSeconds = 0
        local lost = GameEngine.AdvanceCombatTick(started.state, queueRng(), 1011 + defeat * 2, 60)
        assertTrue(lost.ok)
        state = lost.state
        assertEqual(state.position, 0)
        assertEqual(state.floorDefeats, defeat)
        assertEqual(state.floorKillBonus, 0)
        assertTrue(state.currentMonster == nil)
        assertEqual(eventCount(lost.delta.events, "player_died"), 1)
    end
    assertTrue(state.aidPending)
    assertEqual(state.pauseReason, "tower_aid")
    local aided = GameEngine.ClaimAid(state, queueRng(), 1020)
    assertTrue(aided.ok)
    assertTrue(not aided.state.aidPending)
    assertEqual(aided.state.aidGrantedFloors[1], 1)
    assertTrue(eventCount(aided.delta.events, "aid_granted") == 1)
    local claimed = findEvent(aided.delta.events, "tower_aid_claimed")
    assertTrue(claimed ~= nil)
    assertTrue(claimed.itemCount >= 1 and claimed.itemCount <= 2)
    assertTrue(claimed.targetMet == true)
    assertTrue(BigNumber.Compare(
        claimed.displayedPowerBig or claimed.displayedPower,
        claimed.targetPowerBig or claimed.targetPower
    ) >= 0)
end

function Spec.FullInventoryMovesBossDropToTemporaryLoot()
    local state = skipIntro(StateFactory.Create(1000))
    local template = TableUtils.DeepCopy(state.inventory[1])
    while #state.inventory < Catalog.INVENTORY_CAP do
        local item = TableUtils.DeepCopy(template)
        item.id = string.format("00000000-0000-4000-9000-%012x", #state.inventory + 1000)
        item.locked = false
        item.aidLocked = false
        state.inventory[#state.inventory + 1] = item
    end
    state.inventoryPolicy.pauseOnFull = false
    state.position = 9
    state.autoRun = true
    local started = enterNextEncounter(state, queueRng(), 1001)
    local won = GameEngine.AdvanceCombatTick(started.state, queueRng(), 1002, 60)
    assertTrue(won.ok)
    assertEqual(#won.state.inventory, Catalog.INVENTORY_CAP)
    assertEqual(#won.state.overflowLoot, 1)
    assertEqual(won.state.pauseReason, "inventory_full")
    assertTrue(not won.state.autoRun)
    local settled = findEvent(won.delta.events, "loot_settled")
    assertTrue(settled ~= nil)
    assertEqual(settled.outcome, "temporary_box")
end

function Spec.OfflineRewardsApplyTwentyPercentExactlyOnce()
    local onlineState = skipIntro(StateFactory.Create(1000))
    local online = GameEngine.AdvanceOneCell(onlineState, queueRng({}, { 0.99, 0.99 }), 1001)
    assertTrue(online.ok)
    local onlineGold = currency(online.state.gold) - currency(onlineState.gold)

    local offlineState = skipIntro(StateFactory.Create(1000))
    offlineState.pendingOfflineSeconds = Catalog.OFFLINE_STEP_SECONDS
    local offline = GameEngine.CollectOffline(offlineState, 1001)
    assertTrue(offline.ok)
    local offlineGold = currency(offline.state.gold) - currency(offlineState.gold)
    assertEqual(offlineGold, math.floor(onlineGold * Catalog.OFFLINE_REWARD_RATE))
    assertEqual(offline.state.pendingOfflineSeconds, 0)
    local collected = findEvent(offline.delta.events, "offline_collected")
    assertTrue(collected ~= nil)
    assertEqual(collected.rewardRate, Catalog.OFFLINE_REWARD_RATE)
    assertEqual(collected.floor, offlineState.floor)
    assertTrue(collected.fixedFloor)
    assertTrue(type(collected.equipmentItems) == "table")
end

function Spec.OfflinePreviewDoesNotMutateAndQuoteMatchesClaim()
    local state = skipIntro(StateFactory.Create(1000))
    state.pendingOfflineSeconds = Catalog.OFFLINE_STEP_SECONDS * 4
    local before = TableUtils.DeepCopy(state)
    local preview = GameEngine.PreviewOffline(state, 1001, queueRng())

    assertTrue(preview.ok)
    assertTrue(TableUtils.DeepEqual(state, before), "preview mutated the source state")
    assertEqual(preview.commit.kind, "none")
    assertTrue(type(preview.preview) == "table")
    assertTrue(type(preview.previewState) == "table")

    local quote = {
        revision = state.revision,
        pendingOfflineSeconds = state.pendingOfflineSeconds,
        lastActiveAt = state.lastActiveAt,
        state = preview.previewState,
        events = preview.previewEvents,
        inventoryChanged = preview.previewInventoryChanged,
        reward = preview.preview,
    }
    local claimed = GameEngine.CollectOfflineQuote(state, quote, 1002)
    assertTrue(claimed.ok)
    local collected = findEvent(claimed.delta.events, "offline_collected")
    assertTrue(collected ~= nil)
    assertEqual(collected.gold, preview.preview.gold)
    assertEqual(collected.exp, preview.preview.exp)
    assertEqual(collected.fragments, preview.preview.fragments)
    assertEqual(collected.equipment, preview.preview.equipment)
    assertEqual(claimed.state.pendingOfflineSeconds, preview.preview.remainingSeconds)
end

function Spec.OfflineQuoteRejectsStateChanges()
    local state = skipIntro(StateFactory.Create(1000))
    state.pendingOfflineSeconds = Catalog.OFFLINE_STEP_SECONDS * 2
    local preview = GameEngine.PreviewOffline(state, 1001, queueRng())
    assertTrue(preview.ok)
    local quote = {
        revision = state.revision,
        pendingOfflineSeconds = state.pendingOfflineSeconds,
        lastActiveAt = state.lastActiveAt,
        state = preview.previewState,
        events = preview.previewEvents,
        inventoryChanged = preview.previewInventoryChanged,
        reward = preview.preview,
    }
    state.revision = state.revision + 1
    local claimed = GameEngine.CollectOfflineQuote(state, quote, 1002)
    assertTrue(not claimed.ok)
    assertEqual(claimed.error.code, "STALE_OFFLINE_QUOTE")
end

function Spec.OfflineBatchSettlementIsConstantShapeAndUsesCurrentFloorEquipmentLevel()
    local state = skipIntro(StateFactory.Create(1000))
    state.floor = 30
    state.maxFloor = 30
    state.position = 3
    state.pendingOfflineSeconds = Catalog.OFFLINE_MAX_SECONDS
    state.pendingStoryGate = nil
    state.pauseReason = nil
    local before = TableUtils.DeepCopy(state)
    local preview = GameEngine.PreviewOffline(state, 1001, queueRng({}, { 0.99 }))

    assertTrue(preview.ok)
    assertTrue(TableUtils.DeepEqual(state, before), "batch preview mutated the source state")
    assertEqual(preview.preview.processedSeconds, Catalog.OFFLINE_MAX_SECONDS)
    assertEqual(preview.preview.remainingSeconds, 0)
    assertEqual(preview.preview.floor, 30)
    assertTrue(preview.preview.fixedFloor)
    assertTrue(#preview.previewEvents < 100, "offline preview emitted per-cycle events")
    assertTrue(preview.preview.equipment <= Catalog.INVENTORY_CAP - #state.inventory)
    for _, item in ipairs(preview.preview.equipmentItems) do
        assertEqual(item.level, 30, "offline equipment must use the current floor")
    end
end

function Spec.OfflineBatchSettlementKeepsShortAndLongRewardRatesConsistent()
    local short = skipIntro(StateFactory.Create(1000))
    short.pendingOfflineSeconds = Catalog.OFFLINE_STEP_SECONDS
    local long = TableUtils.DeepCopy(short)
    long.pendingOfflineSeconds = Catalog.OFFLINE_MAX_SECONDS

    local shortResult = GameEngine.CollectOffline(short, 1001, queueRng({}, { 0.99 }))
    local longResult = GameEngine.CollectOffline(long, 1001, queueRng({}, { 0.99 }))
    assertTrue(shortResult.ok and longResult.ok)
    assertEqual(shortResult.state.pendingOfflineSeconds, 0)
    assertEqual(longResult.state.pendingOfflineSeconds, 0)
    assertEqual(eventCount(longResult.delta.events, "offline_collected"), 1)
    assertEqual(eventCount(longResult.delta.events, "battle_reward"), 1)
    assertEqual(eventCount(longResult.delta.events, "battle_hit"), 0)
    assertEqual(eventCount(longResult.delta.events, "monster_spawned"), 0)
    assertTrue(longResult.state.floor == shortResult.state.floor)
end

function Spec.OfflineBatchDropCountRespectsInventoryCapacity()
    local state = skipIntro(StateFactory.Create(1000))
    local template = TableUtils.DeepCopy(state.inventory[1])
    while #state.inventory < Catalog.INVENTORY_CAP - 1 do
        local item = TableUtils.DeepCopy(template)
        item.id = string.format("00000000-0000-4000-9000-%012x", #state.inventory + 1000)
        state.inventory[#state.inventory + 1] = item
    end
    state.pendingOfflineSeconds = Catalog.OFFLINE_MAX_SECONDS
    state.inventoryPolicy.pauseOnFull = true
    local result = GameEngine.CollectOffline(state, 1001, queueRng({}, { 0.99 }))
    assertTrue(result.ok)
    local reward = findEvent(result.delta.events, "offline_collected")
    assertEqual(reward.generatedEquipment, 1)
    assertEqual(reward.discardedEquipment, reward.droppedEquipment - 1)
    assertEqual(#result.state.inventory, Catalog.INVENTORY_CAP)
    assertEqual(result.state.pauseReason, "inventory_full")
end

function Spec.OfflineRewardsRepeatCurrentFloorWithoutAdvancing()
    local state = skipIntro(StateFactory.Create(1000))
    state.floor = 10
    state.maxFloor = 10
    state.position = 9
    state.pendingOfflineSeconds = Catalog.OFFLINE_STEP_SECONDS * 12
    state.pendingStoryGate = nil
    state.pauseReason = nil
    state.ruleAcknowledgements = {}

    local offline = GameEngine.CollectOffline(state, 1001)
    assertTrue(offline.ok)
    assertEqual(offline.state.floor, 10)
    assertEqual(offline.state.maxFloor, 10)
    assertTrue(offline.state.position >= 0 and offline.state.position <= 9)
    assertTrue(findEvent(offline.delta.events, "floor_advanced") == nil)
    assertTrue(offline.state.pendingStoryGate == nil)
    local collected = findEvent(offline.delta.events, "offline_collected")
    assertTrue(collected ~= nil)
    assertEqual(collected.floor, 10)
    assertTrue(collected.fixedFloor)
end

function Spec.ChapterOpeningAndBossStoryGatesAreAuthoritative()
    local state = skipIntro(StateFactory.Create(1000))
    state.floor = 10
    state.maxFloor = 10
    state.position = 0
    state.autoRun = true
    local opening = enterNextEncounter(state, queueRng(), 1001)
    assertTrue(opening.ok)
    assertEqual(opening.state.pendingStoryGate.phase, "opening")
    local skipped = GameEngine.AdvanceStory(opening.state, { action = "skip" }, 1002)
    assertTrue(skipped.ok)
    skipped.state.position = 9
    skipped.state.currentMonster = nil
    skipped.state.transitionRemaining = 0
    local boss = enterNextEncounter(skipped.state, queueRng(), 1003)
    assertTrue(boss.ok)
    assertEqual(boss.state.pendingStoryGate.phase, "boss")
end

function Spec.StoryCatalogKeepsChapterAndFloorLookupsDistinct()
    local chapterSix = StoryCatalog.GetChapter(6)
    assertEqual(chapterSix.id, "chapter_0006")
    assertEqual(chapterSix.floor, 60)

    local chapterTen = StoryCatalog.GetChapter(10)
    assertEqual(chapterTen.id, "chapter_0010")
    assertEqual(chapterTen.floor, 100)

    local floorOneHundred = StoryCatalog.GetChapterForFloor(100)
    assertEqual(floorOneHundred.id, chapterTen.id)
    assertEqual(floorOneHundred.floor, chapterTen.floor)

    local gate = StoryCatalog.GetGateForFloor(100, "opening")
    assertEqual(gate.storyId, "chapter_0010:opening")
    assertEqual(gate.chapter, 10)
    assertEqual(gate.floor, 100)
end

function Spec.HighChapterStoryGateUsesTheProductionChapterNumber()
    local state = skipIntro(StateFactory.Create(1000))
    state.floor = 100
    state.maxFloor = 100
    state.position = 0
    state.autoRun = true

    local opening = enterNextEncounter(state, queueRng(), 1001)
    assertTrue(opening.ok)
    assertEqual(opening.state.pendingStoryGate.storyId, "chapter_0010:opening")
    assertEqual(opening.state.pendingStoryGate.chapter, 10)
    assertEqual(opening.state.pendingStoryGate.floor, 100)

    local restored = StateNormalizer.Normalize(StateNormalizer.ToPersisted(opening.state), 1002)
    assertEqual(restored.pendingStoryGate.storyId, "chapter_0010:opening")
    assertEqual(restored.pendingStoryGate.chapter, 10)
    assertEqual(restored.pendingStoryGate.floor, 100)
end

function Spec.HighFloorCombatUsesBigNumberStateWithoutScalarFallback()
    local definition = Catalog.EQUIPMENT_DEFINITIONS[1]
    local generated = Catalog.CreateItemStats(definition, 100000, "myth", 1.05, 0, 0)
    assertEqual(generated.statVersion, 5)
    assertTrue(generated.atk == nil, "high-floor attack must not use a zero scalar alias")
    assertTrue(BigNumber.Compare(generated.atkBig, BigNumber.Zero()) > 0)
    assertTrue(generated.atkBig.exponent > 300)

    local state = highFloorLoadout(100000)
    state.ruleAcknowledgements["story:10000:opening"] = true
    state.ruleAcknowledgements["story:10000:boss"] = true
    local adjusted = GameEngine.AdjustProgress(state, {
        floor = 100000,
        maxFloor = 100000,
        position = 9,
    }, 1001)
    assertTrue(adjusted.ok)
    assertTrue(adjusted.state.hp == nil)
    assertTrue(adjusted.state.stats.atk == nil)
    assertTrue(BigNumber.Compare(adjusted.state.hpBig, BigNumber.Zero()) > 0)
    assertEqual(#adjusted.state.inventory, #Catalog.SLOTS)
    for _, item in ipairs(adjusted.state.inventory) do
        assertTrue(item.budget == nil and item.atk == nil and item.def == nil and item.hp == nil)
        assertTrue(BigNumber.ValidateCanonical(item.budgetBig))
        assertTrue(BigNumber.ValidateCanonical(item.atkBig))
        assertTrue(BigNumber.ValidateCanonical(item.defBig))
        assertTrue(BigNumber.ValidateCanonical(item.hpBig))
    end
    for _, slot in ipairs(Catalog.SLOTS) do
        assertTrue(adjusted.state.equipped[slot.id] ~= nil)
    end
    assertTrue(GameStateSchema.ValidateState(adjusted.state))

    adjusted.state.autoRun = true
    local started = enterNextEncounter(adjusted.state, queueRng(), 1002)
    assertTrue(started.ok and started.state.currentMonster ~= nil)
    assertTrue(started.state.currentMonster.hp == nil)
    assertTrue(started.state.currentMonster.atk == nil)
    assertTrue(started.state.currentMonster.hpBig.exponent > 300)

    local persisted = StateNormalizer.ToPersisted(started.state)
    local restored = StateNormalizer.Normalize(persisted, 1003)
    assertEqual(BigNumber.Compare(
        restored.currentMonster.hpBig, started.state.currentMonster.hpBig), 0)
    local restoredById = {}
    for _, item in ipairs(restored.inventory) do restoredById[item.id] = item end
    for _, item in ipairs(started.state.inventory) do
        local restoredItem = restoredById[item.id]
        assertTrue(restoredItem ~= nil)
        assertEqual(BigNumber.Compare(restoredItem.budgetBig, item.budgetBig), 0)
        assertEqual(BigNumber.Compare(restoredItem.atkBig, item.atkBig), 0)
        assertEqual(BigNumber.Compare(restoredItem.defBig, item.defBig), 0)
        assertEqual(BigNumber.Compare(restoredItem.hpBig, item.hpBig), 0)
    end
    for _, slot in ipairs(Catalog.SLOTS) do
        assertEqual(restored.equipped[slot.id], started.state.equipped[slot.id])
    end
    assertTrue(GameStateSchema.ValidateState(restored))

    local advanced = GameEngine.AdvanceCombatTick(restored, queueRng(), 1004, 60)
    assertTrue(advanced.ok)
    assertTrue(GameStateSchema.ValidateState(advanced.state))
    local damageEvent = findEvent(advanced.delta.events, "player_damaged")
    assertTrue(damageEvent and BigNumber.IsBigNumber(damageEvent.amountBig))
end

function Spec.FullModelAutoEquipAndUndoUseOneAuthoritativeLoadout()
    local state = skipIntro(StateFactory.Create(1000))
    local definition = Catalog.GetEquipmentDefinition(state.inventory[1].equipmentId)
    local granted = GameEngine.GrantEquipment(state, {
        equipmentId = definition.id,
        rarity = "myth",
        atk = 10000,
        level = 1,
    }, 1001)
    assertTrue(granted.ok)
    local itemId = granted.state.inventory[#granted.state.inventory].id
    local equipped = GameEngine.AutoEquip(granted.state, 1002)
    assertTrue(equipped.ok)
    assertEqual(equipped.state.equipped[definition.slot], itemId)
    assertTrue(equipped.state.previousLoadout.available)
    local undone = GameEngine.UndoEquip(equipped.state, 1003)
    assertTrue(undone.ok)
    assertTrue(undone.state.equipped[definition.slot] ~= itemId)
    assertEqual(eventCount(undone.delta.events, "equipment_reverted"), 1)
end

function Spec.StoryLineIndexAndRuleIdsAreAuthoritative()
    local state = StateFactory.Create(1000)
    local enabled = GameEngine.SetAutoRun(state, true, 1001)
    local gate = enabled.state.pendingStoryGate
    local advanced = GameEngine.AdvanceStory(enabled.state, {
        action = "next", storyId = gate.storyId, lineIndex = 2,
    }, 1002)
    assertTrue(advanced.ok)
    assertEqual(advanced.state.pendingStoryGate.lineIndex, 2)

    local stale = GameEngine.AdvanceStory(advanced.state, {
        action = "next", storyId = gate.storyId, lineIndex = 2,
    }, 1003)
    assertTrue(not stale.ok)
    assertEqual(stale.error.code, "STALE_STORY_GATE")

    local acknowledged = GameEngine.AcknowledgeRules(state, "tower-v2", 1004)
    assertTrue(acknowledged.ok)
    assertTrue(acknowledged.state.ruleAcknowledgements[StoryCatalog.RULE_ID])
end

return Spec
