local Progression = require("tests.simulation.LongitudinalProgressionSimulator")
local CombatSimulator = require("tests.simulation.TowerBalanceSimulator")
local RewardPolicy = require("shared.RewardPolicy")
local Catalog = require("server.domain.Catalog")
local StateFactory = require("server.domain.StateFactory")

local Spec = {}

local function near(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.12g, got %.12g", label, expected, actual))
end

local function contains(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then return true end
    end
    return false
end

local function deepEqual(left, right, seen)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    seen = seen or {}
    if seen[left] == right then return true end
    seen[left] = right
    for key, value in pairs(left) do
        if not deepEqual(value, right[key], seen) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function emptyMetricCohort()
    return {
        mode = "auto",
        completedFloor = 100,
        maxFloorTarget = 100,
        blockSoftStuckRates = {},
        softStuckPer100Mean = 0,
        failuresBeforeClearP99 = 0,
        aidThirdAttempts = Progression.MINIMUM_AID_THIRD_ATTEMPTS - 1,
        aidThirdAttemptPassRate = 1,
        timeTo100Hours = nil,
        chapterUpgradeCounts = {},
        upgradesPer10P50 = 0,
        powerRatios = {},
        powerRatioP50 = 0,
        maximumFloorOnlyDisplayedPowerDelta = 0,
    }
end

local function assertTimeBreakdown(summary)
    for _, cohorts in ipairs({ summary.autoCohorts, summary.controlCohorts }) do
        for _, cohort in ipairs(cohorts) do
            local componentSeconds = cohort.combatSeconds
                + cohort.transitionSeconds
                + cohort.storySeconds
                + cohort.interactionSeconds
            near(cohort.totalHours * 3600, componentSeconds, 1e-7,
                cohort.mode .. " total time breakdown")
        end
    end
end

local function assertIncompleteCheckpointExcluded()
    local incomplete = {
        mode = "auto",
        completedFloor = 99,
        blockSoftStuckRates = { [1] = 4 },
        failureCounts = {},
        chapterUpgradeCounts = {},
        powerRatiosWithin1000 = {},
        floorOnlyDisplayDeltas = {},
        timeTo100Hours = nil,
        aidThirdAttempts = 0,
        aidThirdPasses = 0,
        chapters = {},
        powerRatios = { [10] = 1.1 },
        checkpointTimes = { [100] = 4.8 },
    }
    local aggregate = Progression._TestOnly.Aggregate({ maxFloor = 100 }, { incomplete })
    local checkpoint = aggregate.checkpoints[1]
    assert(checkpoint.softStuckSampleCount == 0,
        "an incomplete 100-floor block must not count as a soft-stuck sample")
    assert(checkpoint.powerRatioSampleCount == 0,
        "an unreached checkpoint must not count as a power-ratio sample")
    assert(checkpoint.cumulativeHoursSampleCount == 0,
        "an unreached checkpoint must not count as a time sample")
end

local function assertFailureReasonsRequireSamples()
    local cohort = emptyMetricCohort()
    local reasons = Progression._TestOnly.CohortFailureReasons(cohort)
    assert(#reasons == 0,
        "empty metric arrays and 99 passing aid samples must not create failure reasons")

    cohort.aidThirdAttempts = 0
    cohort.aidThirdAttemptPassRate = nil
    reasons = Progression._TestOnly.CohortFailureReasons(cohort)
    assert(#reasons == 0,
        "zero aid samples must not create a failure reason")

    cohort.aidThirdAttempts = 1
    cohort.aidThirdAttemptPassRate = 0
    reasons = Progression._TestOnly.CohortFailureReasons(cohort)
    assert(contains(reasons, "aid_third_attempt"),
        "one observed aid failure must remain replayable as a failure seed")

    local control = emptyMetricCohort()
    control.mode = "control"
    control.aidThirdAttempts = 1
    control.aidThirdAttemptPassRate = 0
    reasons = Progression._TestOnly.CohortFailureReasons(control)
    assert(contains(reasons, "aid_third_attempt"),
        "a control-branch aid failure must remain replayable because it affects the combined gate")

    local slow = emptyMetricCohort()
    slow.aidThirdAttempts = 0
    slow.aidThirdAttemptPassRate = nil
    slow.timeTo100Hours = Progression.GATES.floor100HoursP50Maximum + 0.01
    reasons = Progression._TestOnly.CohortFailureReasons(slow)
    assert(contains(reasons, "floor_100_hours"),
        "a cohort above the P50 upper bound must remain replayable")

    cohort.blockSoftStuckRates = { 0 }
    cohort.chapterUpgradeCounts = { 0 }
    cohort.powerRatios = { 0 }
    reasons = Progression._TestOnly.CohortFailureReasons(cohort)
    assert(contains(reasons, "soft_stuck_per_100"))
    assert(contains(reasons, "wearable_upgrades"))
    assert(contains(reasons, "power_ratio"))
    assert(contains(reasons, "aid_third_attempt"))
end

local function assertChapterMaintenanceContract(summary)
    local expectedEvents = 10
    local expectedSeconds = expectedEvents * Progression.INVENTORY_MAINTENANCE_SECONDS
    for _, cohorts in ipairs({ summary.autoCohorts, summary.controlCohorts }) do
        for _, cohort in ipairs(cohorts) do
            assert(cohort.inventoryMaintenanceEvents == expectedEvents,
                "a 100-floor cohort must perform exactly one maintenance interaction per chapter")
            assert(cohort.interactionSeconds == expectedSeconds,
                "chapter maintenance must count 30 seconds even when no item is removed")
        end
    end
end

local function assertInventoryBlockDoesNotTriggerMidChapterMaintenance()
    local originalCreate = StateFactory.Create
    local originalCapacity = Catalog.INVENTORY_CAP
    local originalSimulateEncounter = CombatSimulator.SimulateEncounter
    local originalShouldDrop = RewardPolicy.ShouldDrop
    local originalRollRarity = RewardPolicy.RollRarity

    StateFactory.Create = function(now)
        local state = originalCreate(now)
        for _, item in ipairs(state.inventory) do item.locked = true end
        return state
    end
    Catalog.INVENTORY_CAP = 12
    CombatSimulator.SimulateEncounter = function(_, _, _, options)
        return { success = true, remainingHp = options.maxHp, combatSeconds = 0 }
    end
    RewardPolicy.ShouldDrop = function() return true end
    RewardPolicy.RollRarity = function() return "myth" end

    local ok, reason = pcall(function()
        local replay = Progression.Replay(20260725, {
            maxFloor = 100,
            model = "aggregate",
        })
        for _, cohort in ipairs({ replay.auto, replay.control }) do
            assert(cohort.completedFloor == 0)
            assert(cohort.inventoryCapacityBlocks == 1)
            assert(cohort.inventoryBlockedFloor == 1)
            assert(cohort.inventoryMaintenanceEvents == 0,
                "a capacity block between chapters must not trigger hidden maintenance")
            assert(cohort.interactionSeconds == 0)
            assert(cohort.disposedDrops == 0,
                "the blocking legend+ drop must not be reported as silently disposed")
        end
    end)

    StateFactory.Create = originalCreate
    Catalog.INVENTORY_CAP = originalCapacity
    CombatSimulator.SimulateEncounter = originalSimulateEncounter
    RewardPolicy.ShouldDrop = originalShouldDrop
    RewardPolicy.RollRarity = originalRollRarity
    assert(ok, reason)
end

local function aggregateCohort(mode, aidAttempts, aidPasses)
    return {
        mode = mode,
        completedFloor = 100,
        blockSoftStuckRates = { 0 },
        failureCounts = {},
        chapterUpgradeCounts = {},
        powerRatiosWithin1000 = {},
        floorOnlyDisplayDeltas = {},
        timeTo100Hours = nil,
        aidThirdAttempts = aidAttempts,
        aidThirdPasses = aidPasses,
        chapters = {},
        powerRatios = {},
        checkpointTimes = {},
    }
end

local function assertAidAggregationIncludesBothBranches()
    local summary = Progression._TestOnly.Aggregate({ maxFloor = 100 }, {
        aggregateCohort("auto", 40, 40),
        aggregateCohort("control", 60, 59),
    })
    assert(summary.aidThirdAttempts == 100,
        "aid gate must include natural auto and control third attempts")
    assert(summary.aidThirdPasses == 99,
        "aid gate must include auto and control third-attempt passes")
end

local function assertFirstRoomUpgradeAffectsSecondRoom()
    local originalPrepareCombat = CombatSimulator.PrepareCombat
    local originalSimulateEncounter = CombatSimulator.SimulateEncounter
    local originalSimulateRoute = CombatSimulator.SimulateRoute
    local originalShouldDrop = RewardPolicy.ShouldDrop
    local originalRollRarity = RewardPolicy.RollRarity
    local floorOnePreparedStats = {}
    local dropCalls = 0

    CombatSimulator.PrepareCombat = function(stats, floor, bossKind)
        local prepared = originalPrepareCombat(stats, floor, bossKind)
        if floor == 1 then
            floorOnePreparedStats[#floorOnePreparedStats + 1] = {
                atk = stats.atk,
                def = stats.def,
                hp = stats.hp,
                towerScore = prepared.evaluation.towerScore,
            }
        end
        return prepared
    end
    CombatSimulator.SimulateEncounter = function(_, _, _, options)
        return { success = true, remainingHp = options.maxHp, combatSeconds = 0 }
    end
    CombatSimulator.SimulateRoute = function()
        return { success = true }
    end
    RewardPolicy.ShouldDrop = function()
        dropCalls = dropCalls + 1
        return dropCalls == 1
    end
    RewardPolicy.RollRarity = function()
        return "myth"
    end

    local ok, reason = pcall(function()
        local replay = Progression.Replay(20260724, {
            maxFloor = 100,
            model = "aggregate",
        })
        assert(replay.auto.autoEquipEvents > 0,
            "the forced first-room drop must be auto-equipped")
        assert(#floorOnePreparedStats >= 2,
            "the first two rooms must both prepare floor-one combat")
        assert(not deepEqual(floorOnePreparedStats[1], floorOnePreparedStats[2]),
            "room two must prepare combat from post-upgrade stats")
        assert(floorOnePreparedStats[2].towerScore > floorOnePreparedStats[1].towerScore,
            "the first-room upgrade must improve room-two prepared power")
    end)

    CombatSimulator.PrepareCombat = originalPrepareCombat
    CombatSimulator.SimulateEncounter = originalSimulateEncounter
    CombatSimulator.SimulateRoute = originalSimulateRoute
    RewardPolicy.ShouldDrop = originalShouldDrop
    RewardPolicy.RollRarity = originalRollRarity
    assert(ok, reason)
end

function Spec.Run()
    local originalComparisonTrials = Progression.AUTO_EQUIP_COMPARISON_TRIALS
    Progression.AUTO_EQUIP_COMPARISON_TRIALS = 1
    local ok, reason = pcall(function()
        assertIncompleteCheckpointExcluded()
        assertFailureReasonsRequireSamples()
        assertAidAggregationIncludesBothBranches()
        assertInventoryBlockDoesNotTriggerMidChapterMaintenance()
        assertFirstRoomUpgradeAffectsSecondRoom()

        local options = {
            seed = 20260723,
            samples = 1,
            maxFloor = 100,
            model = "aggregate",
        }
        local first = Progression.Run(options)
        local second = Progression.Run(options)
        assertTimeBreakdown(first)
        assertChapterMaintenanceContract(first)
        assert(deepEqual(first, second),
            "same-seed longitudinal runs must be end-to-end deterministic")
    end)
    Progression.AUTO_EQUIP_COMPARISON_TRIALS = originalComparisonTrials
    assert(ok, reason)
end

return Spec
