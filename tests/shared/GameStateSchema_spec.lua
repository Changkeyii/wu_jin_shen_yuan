local GameStateSchema = require("shared.GameStateSchema")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local GameEventSchema = require("shared.GameEventSchema")
local BigNumber = require("shared.BigNumber")

local Spec = {}

local function EmptySetProgress()
    local progress = {}
    for _, setId in ipairs(GameStateSchema.SET_IDS) do
        progress[setId] = {
            count = 0,
            regions = { weapon = 0, armor = 0, jewelry = 0, special = 0 },
            activeTiers = {
                ["3"] = false,
                ["6"] = false,
                ["9"] = false,
                ["12"] = false,
            },
            activeRegions = { armor = false, jewelry = false, special = false },
        }
    end
    return progress
end

local function CompleteStats()
    return {
        atk = 10,
        def = 0,
        hp = 1,
        atkBig = BigNumber.FromNumber(10),
        defBig = BigNumber.Zero(),
        hpBig = BigNumber.FromNumber(1),
        maxHpBig = BigNumber.FromNumber(1),
        crit = 0.10,
        critDmg = 1.5,
        atkSpeed = 1,
        lifeSteal = 0,
        bossDamage = 0,
        damageBonus = 0,
        trueDamageRate = 0,
        luckyChance = 0,
        luckyMultiplier = 1,
        moveSpeed = 0,
        skillDamage = 0,
        damageOverTime = 0,
        damageReduction = 0,
        lowHealthGuard = 0,
        permanentBonus = 0,
        setProgress = EmptySetProgress(),
        power = 999,
        displayedPower = BigNumber.FromNumber(999),
        recommendedPower = BigNumber.FromNumber(1000),
        nextChapterRecommendedPower = BigNumber.FromNumber(2000),
        powerRatio = 0.999,
        headroomFloors = 0,
        difficultyLabel = "challenge",
        equivalentFloor = 1,
        estimatedEasyFloor = 1,
        towerScore = 1,
        bossScore = 1,
        eliteScore = 1,
        dpsSafe = 1,
        ehp = 1,
    }
end

function Spec.Run()
    assert(#GameStateSchema.SLOTS == 12)

    local state = GameStateSchema.NewInitialState(100)
    local valid, err = GameStateSchema.ValidateState(state)
    assert(valid, err and err.reason)
    assert(state.level == 1 and state.exp == 0)
    assert(state.pendingOfflineSeconds <= GameStateSchema.OFFLINE_MAX_SECONDS)
    assert(#state.appliedGmCommandIds == 0)

    local definition = EquipmentCatalog.GetAll()[1]
    local item = {
        id = "00000000-0000-4000-8000-000000000001",
        equipmentId = definition.id,
        name = "Test Weapon",
        slot = definition.slot,
        category = definition.category,
        rarity = "epic",
        level = 1,
        statVersion = 5,
        budgetBig = BigNumber.FromNumber(999),
        setEnabled = true,
        setId = definition.setId,
        roll = 1,
        atk = 10,
        def = 0,
        hp = 0,
        atkBig = BigNumber.FromNumber(10),
        defBig = BigNumber.Zero(),
        hpBig = BigNumber.Zero(),
        crit = 0,
        critDmg = 0,
        atkSpeed = 0,
        enhance = 0,
        star = 0,
        power = 999,
    }
    state.inventory = { item }
    state.equipped = { [definition.slot] = item.id }
    state.nextItemId = 2
    state.stats = CompleteStats()
    state.setProgress = GameStateSchema.DeepCopy(state.stats.setProgress)
    state.nextExp = GameStateSchema.NextExp(state.level)
    state.pendingStoryGate = {
        storyId = "tower-prologue",
        chapter = 0,
        floor = 1,
        phase = "prologue",
        title = "万灵塔苏醒",
        lines = { "第一句", "第二句" },
        lineIndex = 2,
    }
    assert(GameStateSchema.ValidateState(state))

    local persisted = GameStateSchema.ToPersistedState(state)
    assert(persisted.stats == nil and persisted.nextExp == nil)
    assert(persisted.inventory[1].power == nil)
    assert(persisted.equipped[definition.slot] == item.id)
    assert(type(persisted.appliedGmCommandIds) == "table")

    local snapshot = GameStateSchema.BuildSnapshot(state, {
        serverTime = 101,
        isAdmin = true,
        playerNickname = "schema-spec",
    })
    assert(snapshot.kind == "GameSnapshot")
    assert(snapshot.isAdmin == true)
    assert(snapshot.stats.power == 999)
    assert(snapshot.inventory[1].power == 999)
    assert(snapshot.appliedGmCommandIds == nil)
    assert(snapshot.pendingStoryGate.storyId == state.pendingStoryGate.storyId)
    assert(snapshot.pendingStoryGate.lineIndex == 2)
    assert(GameStateSchema.ValidateSnapshot(snapshot))

    for _, fieldName in ipairs({
        "updatedAt", "serverTime", "status", "isAdmin", "playerNickname",
        "inventoryCapacity", "level", "exp", "floor", "maxFloor", "position",
        "transitionRemaining", "attemptId", "floorDefeats", "aidPending", "gold",
        "fragments", "mythShards", "autoRun", "pendingOfflineSeconds", "inventory",
        "overflowLoot", "equipped", "consumables", "hpBig", "floorKillBonus",
        "permanentBonus", "inventoryPolicy", "automationPolicy", "interactionMode",
        "rewardPity", "storyProgress", "ruleAcknowledgements", "logs", "currentEvent",
        "recentDamage", "stats", "nextExp", "displayedPower", "recommendedPower",
        "nextChapterRecommendedPower", "powerRatio", "headroomFloors", "difficultyLabel",
        "bossScore", "eliteScore", "estimatedEasyFloor",
    }) do
        local incomplete = GameStateSchema.DeepCopy(snapshot)
        incomplete[fieldName] = nil
        assert(not GameStateSchema.ValidateSnapshot(incomplete), "missing required snapshot field: " .. fieldName)
    end

    local invalidSnapshotValues = {
        updatedAt = -1,
        serverTime = -1,
        status = "loading",
        isAdmin = "yes",
        inventoryCapacity = 0,
        level = {},
        exp = -1,
        floor = 0,
        maxFloor = 0,
        position = {},
        transitionRemaining = math.huge,
        attemptId = -1,
        floorDefeats = -1,
        aidPending = 1,
        gold = 40000,
        fragments = {},
        mythShards = "invalid",
        autoRun = 1,
        pauseReason = {},
        pendingOfflineSeconds = GameStateSchema.OFFLINE_MAX_SECONDS + 1,
        inventory = "invalid",
        overflowLoot = "invalid",
        equipped = "invalid",
        consumables = "invalid",
        hp = -1,
        floorKillBonus = 2,
        permanentBonus = -1,
        inventoryPolicy = "invalid",
        automationPolicy = "invalid",
        interactionMode = "invalid",
        rewardPity = "invalid",
        storyProgress = "invalid",
        pendingStoryGate = "invalid",
        ruleAcknowledgements = "invalid",
        pendingEquipDecision = "invalid",
        previousLoadout = "invalid",
        currentMonster = "invalid",
        setProgress = "invalid",
        logs = 1,
        currentEvent = "invalid",
        recentDamage = {},
        stats = "invalid",
        nextExp = math.huge,
        recommendedPower = -1,
        nextChapterRecommendedPower = -1,
        powerRatio = -1,
        headroomFloors = math.huge,
        difficultyLabel = {},
        bossScore = -1,
        eliteScore = -1,
        estimatedEasyFloor = -1,
    }
    for fieldName, invalidValue in pairs(invalidSnapshotValues) do
        local corrupted = GameStateSchema.DeepCopy(snapshot)
        corrupted[fieldName] = invalidValue
        assert(not GameStateSchema.ValidateSnapshot(corrupted), "invalid snapshot field: " .. fieldName)
    end

    local unsafeRevisionSnapshot = GameStateSchema.DeepCopy(snapshot)
    unsafeRevisionSnapshot.revision = 9007199254740992
    assert(not GameStateSchema.ValidateSnapshot(unsafeRevisionSnapshot))

    local incompleteStats = GameStateSchema.DeepCopy(snapshot)
    incompleteStats.stats.atkSpeed = nil
    assert(not GameStateSchema.ValidateSnapshot(incompleteStats))
    local unknownStats = GameStateSchema.DeepCopy(snapshot)
    unknownStats.stats.futureStat = 1
    assert(not GameStateSchema.ValidateSnapshot(unknownStats))
    local invalidSetProgress = GameStateSchema.DeepCopy(snapshot)
    invalidSetProgress.stats.setProgress.nightmare.regions.armor = 6
    assert(not GameStateSchema.ValidateSnapshot(invalidSetProgress))

    local wrongVersionSnapshot = GameStateSchema.DeepCopy(snapshot)
    wrongVersionSnapshot.schemaVersion = GameStateSchema.VERSION + 1
    assert(not GameStateSchema.ValidateSnapshot(wrongVersionSnapshot))

    local unknownFieldSnapshot = GameStateSchema.DeepCopy(snapshot)
    unknownFieldSnapshot.futureServerField = true
    assert(not GameStateSchema.ValidateSnapshot(unknownFieldSnapshot))

    local invalidGateSnapshot = GameStateSchema.DeepCopy(snapshot)
    invalidGateSnapshot.pendingStoryGate.lineIndex = #invalidGateSnapshot.pendingStoryGate.lines + 1
    assert(not GameStateSchema.ValidateSnapshot(invalidGateSnapshot))

    local snapshotEvents = GameStateSchema.BuildSnapshotEvents(state, {
        {
            type = "story_gate", kind = "story_gate", storyId = "stale",
            chapter = 99, phase = "memory", lines = { "陈旧剧情" },
        },
        { type = "battle_won", kind = "battle_won" },
    })
    assert(#snapshotEvents == 2 and snapshotEvents[1].type == "battle_won")
    assert(snapshotEvents[2].type == "story_gate")
    assert(snapshotEvents[2].storyId == state.pendingStoryGate.storyId)
    assert(snapshotEvents[2].lineIndex == state.pendingStoryGate.lineIndex)
    assert(GameEventSchema.ValidateList(snapshotEvents))
    snapshotEvents[2].lines[1] = "客户端副本"
    assert(state.pendingStoryGate.lines[1] == "第一句")

    state.pendingStoryGate = nil
    local eventsWithoutGate = GameStateSchema.BuildSnapshotEvents(state, snapshotEvents)
    assert(#eventsWithoutGate == 1 and eventsWithoutGate[1].type == "battle_won")

    local delta = GameStateSchema.BuildDelta(2, {
        gold = { high = 0, mid = 0, low = 40000 },
    }, {
        inventoryChanged = true,
        state = state,
        serverTime = 102,
    })
    assert(delta.kind == "GameDelta" and delta.revision == 2)
    assert(delta.inventoryChanged)
    assert(#delta.changes.inventory == 1)
    assert(GameStateSchema.ValidateDelta(delta))

    local unsafeRevisionDelta = GameStateSchema.DeepCopy(delta)
    unsafeRevisionDelta.revision = 9007199254740992
    assert(not GameStateSchema.ValidateDelta(unsafeRevisionDelta))

    for fieldName, invalidValue in pairs({
        position = {},
        logs = 1,
        gold = 40000,
        powerRatio = {},
        inventoryPolicy = "invalid",
        setProgress = "invalid",
    }) do
        local invalidFieldDelta = GameStateSchema.DeepCopy(delta)
        invalidFieldDelta.changes[fieldName] = invalidValue
        assert(not GameStateSchema.ValidateDelta(invalidFieldDelta), "invalid delta field: " .. fieldName)
    end

    local invalidDeltaEnvelope = GameStateSchema.DeepCopy(delta)
    invalidDeltaEnvelope.serverTime = math.huge
    assert(not GameStateSchema.ValidateDelta(invalidDeltaEnvelope))
    invalidDeltaEnvelope = GameStateSchema.DeepCopy(delta)
    invalidDeltaEnvelope.eventKind = "bad event kind"
    assert(not GameStateSchema.ValidateDelta(invalidDeltaEnvelope))

    local wrongVersionDelta = GameStateSchema.DeepCopy(delta)
    wrongVersionDelta.schemaVersion = GameStateSchema.VERSION + 1
    assert(not GameStateSchema.ValidateDelta(wrongVersionDelta))

    local unknownEnvelopeDelta = GameStateSchema.DeepCopy(delta)
    unknownEnvelopeDelta.futureEnvelopeField = true
    assert(not GameStateSchema.ValidateDelta(unknownEnvelopeDelta))

    local invalidGateDelta = GameStateSchema.DeepCopy(delta)
    invalidGateDelta.changes.pendingStoryGate = GameStateSchema.DeepCopy(snapshot.pendingStoryGate)
    invalidGateDelta.changes.pendingStoryGate.lines = {}
    assert(not GameStateSchema.ValidateDelta(invalidGateDelta))

    local highMagnitude = BigNumber.New(1.25, 600)
    local highSnapshot = GameStateSchema.DeepCopy(snapshot)
    highSnapshot.hp = nil
    highSnapshot.hpBig = BigNumber.Clone(highMagnitude)
    highSnapshot.displayedPower = BigNumber.Clone(highMagnitude)
    highSnapshot.stats.atk = nil
    highSnapshot.stats.def = nil
    highSnapshot.stats.hp = nil
    highSnapshot.stats.atkBig = BigNumber.Clone(highMagnitude)
    highSnapshot.stats.defBig = BigNumber.Clone(highMagnitude)
    highSnapshot.stats.hpBig = BigNumber.Clone(highMagnitude)
    highSnapshot.stats.maxHpBig = BigNumber.Clone(highMagnitude)
    highSnapshot.stats.power = BigNumber.Clone(highMagnitude)
    highSnapshot.stats.displayedPower = BigNumber.Clone(highMagnitude)
    highSnapshot.inventory[1].power = BigNumber.Clone(highMagnitude)
    highSnapshot.currentMonster = {
        id = "monster:100000:1",
        eventType = "monster",
        name = "High Floor Monster",
        hpBig = BigNumber.Clone(highMagnitude),
        maxHpBig = BigNumber.Clone(highMagnitude),
        atkBig = BigNumber.Clone(highMagnitude),
        defBig = BigNumber.Clone(highMagnitude),
        phase = "windup",
        phaseRemaining = 0,
        attackSerial = 1,
        lastSequenceIndex = 0,
        room = 1,
        encounter = "normal",
        hitIndex = 1,
        elapsedSeconds = 0,
        enraged = false,
        nextMonsterAttackSeconds = 3,
    }
    highSnapshot.pendingEquipDecision = {
        itemId = item.id,
        createdAt = 103,
        displayedPowerDeltaBig = BigNumber.Clone(highMagnitude),
    }
    assert(GameStateSchema.ValidateSnapshot(highSnapshot))

    local invalidBigNumbers = {
        { mantissa = 10, exponent = 1 },
        { mantissa = 0, exponent = 1 },
        { mantissa = -1, exponent = 1 },
        { mantissa = 1, exponent = 1.5 },
        { mantissa = 1, exponent = BigNumber.MAX_SERIALIZED_EXPONENT + 1 },
        { mantissa = 1, exponent = BigNumber.MIN_SERIALIZED_EXPONENT - 1 },
        { mantissa = 0 / 0, exponent = 0 },
        { mantissa = math.huge, exponent = 0 },
        { m = 1, e = 600 },
    }
    for _, invalidBig in ipairs(invalidBigNumbers) do
        local corrupted = GameStateSchema.DeepCopy(highSnapshot)
        corrupted.hpBig = invalidBig
        assert(not GameStateSchema.ValidateSnapshot(corrupted))
    end

    local corruptedItem = GameStateSchema.DeepCopy(highSnapshot)
    corruptedItem.inventory[1].atkBig = { mantissa = 12, exponent = 600 }
    assert(not GameStateSchema.ValidateSnapshot(corruptedItem))
    local corruptedStats = GameStateSchema.DeepCopy(highSnapshot)
    corruptedStats.stats.atkBig = { mantissa = 1, exponent = 1.25 }
    assert(not GameStateSchema.ValidateSnapshot(corruptedStats))
    local corruptedMonster = GameStateSchema.DeepCopy(highSnapshot)
    corruptedMonster.currentMonster.hpBig = { mantissa = 0, exponent = 3 }
    assert(not GameStateSchema.ValidateSnapshot(corruptedMonster))
    local corruptedPower = GameStateSchema.DeepCopy(highSnapshot)
    corruptedPower.displayedPower = math.huge
    assert(not GameStateSchema.ValidateSnapshot(corruptedPower))

    state.pendingEquipDecision = {
        itemId = item.id,
        createdAt = 103,
        displayedPowerDeltaBig = BigNumber.Clone(highMagnitude),
    }
    assert(GameStateSchema.ValidateState(state))
    local pendingPersisted = GameStateSchema.ToPersistedState(state)
    assert(BigNumber.ValidateCanonical(pendingPersisted.pendingEquipDecision.displayedPowerDeltaBig))
    local pendingSnapshot = GameStateSchema.BuildSnapshot(state, {
        serverTime = 103,
        playerNickname = "schema-spec",
    })
    assert(GameStateSchema.ValidateSnapshot(pendingSnapshot))
    local highDelta = GameStateSchema.BuildDelta(3, {
        hpBig = BigNumber.Clone(highMagnitude),
        stats = GameStateSchema.DeepCopy(highSnapshot.stats),
        currentMonster = GameStateSchema.DeepCopy(highSnapshot.currentMonster),
        displayedPower = BigNumber.Clone(highMagnitude),
        pendingEquipDecision = GameStateSchema.DeepCopy(state.pendingEquipDecision),
    }, {
        inventoryChanged = true,
        state = state,
        serverTime = 104,
    })
    assert(GameStateSchema.ValidateDelta(highDelta))
    local invalidDeltaItem = GameStateSchema.DeepCopy(highDelta)
    invalidDeltaItem.changes.inventory[1].hpBig = { mantissa = 10, exponent = 2 }
    assert(not GameStateSchema.ValidateDelta(invalidDeltaItem))
    local invalidDeltaHp = GameStateSchema.DeepCopy(highDelta)
    invalidDeltaHp.changes.hpBig = { mantissa = 1, exponent = math.huge }
    assert(not GameStateSchema.ValidateDelta(invalidDeltaHp))
    local invalidDeltaMonster = GameStateSchema.DeepCopy(highDelta)
    invalidDeltaMonster.changes.currentMonster.defBig = { mantissa = 1, exponent = 1.5 }
    assert(not GameStateSchema.ValidateDelta(invalidDeltaMonster))
    local invalidDeltaStats = GameStateSchema.DeepCopy(highDelta)
    invalidDeltaStats.changes.stats.hpBig = { mantissa = -2, exponent = 10 }
    assert(not GameStateSchema.ValidateDelta(invalidDeltaStats))
    local invalidPendingDelta = GameStateSchema.DeepCopy(highDelta)
    invalidPendingDelta.changes.pendingEquipDecision.displayedPowerDeltaBig = { mantissa = 0, exponent = 2 }
    assert(not GameStateSchema.ValidateDelta(invalidPendingDelta))
    local malformedLoadoutDelta = GameStateSchema.DeepCopy(highDelta)
    malformedLoadoutDelta.changes.inventory = { 123 }
    local validationCallOk, malformedLoadoutValid = pcall(
        GameStateSchema.ValidateDelta, malformedLoadoutDelta)
    assert(validationCallOk, "malformed loadout deltas must return a validation error instead of throwing")
    assert(not malformedLoadoutValid)

    local bigOnlyEvents = {
        {
            type = "battle_started",
            monsterHpBig = BigNumber.Clone(highMagnitude),
            monsterMaxHpBig = BigNumber.Clone(highMagnitude),
        },
        {
            type = "player_attack_hit", hitIndex = 1,
            amountBig = BigNumber.Clone(highMagnitude),
            monsterHpBig = BigNumber.Clone(highMagnitude),
            monsterMaxHpBig = BigNumber.Clone(highMagnitude),
        },
        {
            type = "player_damaged",
            amountBig = BigNumber.Clone(highMagnitude),
            hpBig = BigNumber.Clone(highMagnitude),
            maxHpBig = BigNumber.Clone(highMagnitude),
        },
        {
            type = "player_healed", source = "life_steal",
            amountBig = BigNumber.Clone(highMagnitude),
            hpBig = BigNumber.Clone(highMagnitude),
            maxHpBig = BigNumber.Clone(highMagnitude),
        },
        {
            type = "monster_spawned", floor = 100000, room = 1, kind = "normal",
            hpBig = BigNumber.Clone(highMagnitude),
            maxHpBig = BigNumber.Clone(highMagnitude),
        },
        {
            type = "equipment_reverted",
            displayedPowerBig = BigNumber.Clone(highMagnitude),
        },
        {
            type = "equipment_upgrade_available",
            itemId = item.id,
            displayedPowerDeltaBig = BigNumber.Clone(highMagnitude),
        },
    }
    assert(GameEventSchema.ValidateList(bigOnlyEvents))
    assert(not GameEventSchema.Validate({ type = "player_attack_hit", hitIndex = 1 }))
    assert(not GameEventSchema.Validate({
        type = "player_attack_hit", hitIndex = 1, amount = {},
    }))
    assert(not GameEventSchema.Validate({
        type = "player_attack_hit", hitIndex = 1, amount = 1,
        amountBig = { mantissa = 10, exponent = 1 },
    }))
    assert(not GameEventSchema.Validate({
        type = "player_damaged", amount = math.huge, hp = 1, maxHp = 1,
    }))
    assert(not GameEventSchema.Validate({
        type = "equipment_reverted", displayedPower = { corrupt = true },
    }))
    assert(not GameEventSchema.Validate({
        type = "equipment_upgrade_available",
        itemId = item.id,
    }))
    assert(not GameEventSchema.Validate({
        type = "attack_started",
        hitFrames = 1,
    }))
    assert(not GameEventSchema.Validate({
        type = "inventory_policy_changed",
        inventoryPolicy = 1,
    }))

    assert(GameEventSchema.IsKnown("temporary_loot_recovered"))
    assert(GameEventSchema.IsKnown("rules_acknowledged"))
    assert(GameEventSchema.Validate({
        type = "loot_settled",
        itemId = "00000000-0000-4000-8000-000000000001",
        outcome = "temporary_box",
    }))
    assert(not GameEventSchema.Validate({
        type = "loot_settled",
        itemId = "00000000-0000-4000-8000-000000000001",
        outcome = "lost",
    }))
    assert(not GameEventSchema.Validate({
        type = "story_advanced", storyId = "intro", lineIndex = 1.5, line = "bad",
    }))
    local unknownValid, unknownReason = GameEventSchema.Validate({ type = "future_server_event" })
    assert(not unknownValid)
    assert(unknownReason == "$event.type is unknown")

    local engineFile = assert(io.open("scripts/server/domain/GameEngine.lua", "rb"))
    local engineSource = engineFile:read("*a")
    engineFile:close()
    local staticEventTypes = { story_completed = true }
    for eventType in engineSource:gmatch('event%s*%(%s*"([a-z_]+)"') do
        staticEventTypes[eventType] = true
    end
    local staticEventCount = 0
    for eventType in pairs(staticEventTypes) do
        staticEventCount = staticEventCount + 1
        assert(GameEventSchema.IsKnown(eventType), "missing server event schema: " .. eventType)
    end
    assert(staticEventCount == 74, "server event coverage audit must be updated")

    state.equipped[definition.slot] = "missing"
    local mismatch = GameStateSchema.ValidateState(state)
    assert(not mismatch)
end

return Spec
