local CombatSimulator = require("tests.simulation.TowerBalanceSimulator")
local Catalog = require("server.domain.Catalog")
local GameEngine = require("server.domain.GameEngine")
local StateFactory = require("server.domain.StateFactory")
local PowerEvaluator = require("shared.PowerEvaluator")
local BigNumber = require("shared.BigNumber")
local RarityCatalog = require("shared.RarityCatalog")
local RewardPolicy = require("shared.RewardPolicy")
local StoryCatalog = require("shared.StoryCatalog")
local TowerRules = require("shared.TowerRules")

local Progression = {}

Progression.VERSION = 3
Progression.DEFAULT_SAMPLES = 10
Progression.QUICK_SAMPLES = 1
Progression.DEFAULT_MAX_FLOOR = 1000
Progression.MAX_ATTEMPTS_PER_FLOOR = 20
Progression.FAILURE_SEED_LIMIT = 64
Progression.METHOD = "production-ordered-progression-v3"
Progression.MINIMUM_COHORT_SAMPLES = 10
Progression.MINIMUM_FLOOR_SAMPLES = 1000
Progression.MINIMUM_CHECKPOINT_SAMPLES = 100
Progression.MINIMUM_AID_THIRD_ATTEMPTS = 100
Progression.AUTO_EQUIP_COMPARISON_TRIALS = 16
Progression.MINIMUM_AUTO_EQUIP_PAIRED_TRIALS_PER_CHAPTER = 128
Progression.STORY_SECONDS_PER_LINE = 20
Progression.STORY_GATE_OVERHEAD_SECONDS = 3
Progression.INVENTORY_MAINTENANCE_SECONDS = 30
Progression.INVENTORY_CANDIDATES_PER_SLOT = 6

Progression.GATES = {
    softStuckPer100Minimum = 3,
    softStuckPer100Maximum = 5,
    failuresBeforeClearP99Maximum = 2,
    aidThirdAttemptPassRateMinimum = 0.99,
    floor100HoursP50Minimum = 4.5,
    floor100HoursP50Maximum = 5.2,
    floor100HoursP90Maximum = 6.0,
    upgradesPer10P50Minimum = 12,
    upgradesPer10P50Maximum = 18,
    powerRatioP50Minimum = 1.05,
    powerRatioP50Maximum = 1.12,
    autoEquipChapterDeclineMaximum = 0.01,
    floorOnlyDisplayedPowerDeltaMaximum = 0.001,
}

local CORE_AFFIX_POOL = {
    "core.fury", "core.guard", "core.vitality", "core.swiftness",
    "core.vampirism", "core.boss_hunter",
}

local DISPOSABLE_RARITIES = {
    common = true,
    advanced = true,
    rare = true,
    artifact = true,
}

local function copyArray(source)
    local result = {}
    for index, value in ipairs(source or {}) do result[index] = value end
    return result
end

local function shallowCopy(source)
    local result = {}
    for key, value in pairs(source or {}) do result[key] = value end
    return result
end

local function mean(values)
    if #values == 0 then return 0 end
    local total = 0
    for _, value in ipairs(values) do total = total + value end
    return total / #values
end

local function percentile(values, probability)
    if #values == 0 then return 0 end
    local sorted = copyArray(values)
    table.sort(sorted)
    local position = 1 + (#sorted - 1) * math.max(0, math.min(1, probability))
    local lower, upper = math.floor(position), math.ceil(position)
    if lower == upper then return sorted[lower] end
    local fraction = position - lower
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
end

local function maximum(values)
    local result = 0
    for _, value in ipairs(values or {}) do result = math.max(result, value) end
    return result
end

local function indexItems(state)
    local result = {}
    for _, item in ipairs(state.inventory or {}) do result[item.id] = item end
    return result
end

local function findItem(state, itemId, itemById)
    if itemById then return itemById[itemId] end
    for _, item in ipairs(state.inventory or {}) do
        if item.id == itemId then return item end
    end
    return nil
end

local function equippedIds(state)
    local result = {}
    for _, itemId in pairs(state.equipped or {}) do result[itemId] = true end
    return result
end

local function nextChapterFloor(floor)
    return (math.floor(math.max(1, floor) / 10) + 1) * 10
end

local function loadoutInventory(equipped, itemById)
    local result = {}
    for _, slot in ipairs(Catalog.SLOTS) do
        local item = itemById[equipped[slot.id]]
        if item then result[#result + 1] = item end
    end
    return result
end

local function loadoutState(state, equipped, itemById)
    itemById = itemById or indexItems(state)
    return {
        level = state.level,
        floor = state.floor,
        maxFloor = state.maxFloor,
        floorKillBonus = state.floorKillBonus,
        permanentBonus = state.permanentBonus,
        inventory = loadoutInventory(equipped, itemById),
        equipped = equipped,
    }
end

local function evaluateLoadout(state, equipped, itemById)
    local view = loadoutState(state, equipped, itemById)
    local stats = Catalog.CalculateStats(view, { skipPowerEvaluation = true })
    local score = PowerEvaluator.EvaluateAtFloor(
        stats,
        nextChapterFloor(state.floor),
        { bossKind = "chapterBoss" })
    return {
        stats = stats,
        score = score,
        setProgress = stats.setProgress,
    }
end

local function loadoutKey(equipped)
    local result = {}
    for index, slot in ipairs(Catalog.SLOTS) do
        result[index] = tostring(equipped[slot.id] or "")
    end
    return table.concat(result, "\31")
end

local function breaksActiveSetTier(beforeProgress, afterProgress)
    for setId, before in pairs(beforeProgress or {}) do
        local after = afterProgress and afterProgress[setId] or nil
        for _, tier in ipairs({ 3, 6, 9, 12 }) do
            local key = tostring(tier)
            if before.activeTiers and before.activeTiers[key]
                and not (after and after.activeTiers and after.activeTiers[key])
            then
                return true
            end
        end
    end
    return false
end

local function upgradePasses(before, after, minimumGain)
    local oldScore = tonumber(before.score.towerScore) or 0
    local newScore = tonumber(after.score.towerScore) or 0
    local required = oldScore > 0 and oldScore * (1 + (minimumGain or 0.02)) or 0
    return newScore >= required
        and (tonumber(after.score.bossScore) or 0) >= (tonumber(before.score.bossScore) or 0)
        and (tonumber(after.score.eliteScore) or 0)
            >= (tonumber(before.score.eliteScore) or 0)
                * RewardPolicy.AUTO_EQUIP_MINIMUM_ELITE_RETENTION
        and RewardPolicy.AutoEquipSurvivalMarginPasses(
            before.score.bossSurvivalMargin,
            after.score.bossSurvivalMargin)
        and not breaksActiveSetTier(before.setProgress, after.setProgress)
end

local function considerUpgrade(state, item, autoEquip)
    if not item or item.aidLocked then return false, false, nil end
    local itemById = indexItems(state)
    local current = findItem(state, state.equipped[item.slot], itemById)
    if current and (current.locked or current.aidLocked) then return false, false, nil end
    local before = evaluateLoadout(state, state.equipped, itemById)
    local candidateEquipped = shallowCopy(state.equipped)
    candidateEquipped[item.slot] = item.id
    local after = evaluateLoadout(state, candidateEquipped, itemById)
    local oldScore = tonumber(before.score.towerScore) or 0
    local newScore = tonumber(after.score.towerScore) or 0
    local wearable = newScore > oldScore and upgradePasses(before, after, 0)
    if not upgradePasses(before, after, RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN) then
        return wearable, false, nil
    end
    if autoEquip then state.equipped = candidateEquipped end
    return wearable, autoEquip, autoEquip and { before = before, after = after } or nil
end

local function optimizeWholeLoadout(state, autoEquip)
    if not autoEquip then return false end
    local itemById = indexItems(state)
    local evaluations = {}
    local function evaluate(equipped)
        local key = loadoutKey(equipped)
        if not evaluations[key] then
            evaluations[key] = evaluateLoadout(state, equipped, itemById)
        end
        return evaluations[key]
    end
    local originalEquipped = shallowCopy(state.equipped)
    local original = evaluate(originalEquipped)
    local selected = shallowCopy(originalEquipped)
    local candidatesBySlot = {}
    for _, slot in ipairs(Catalog.SLOTS) do candidatesBySlot[slot.id] = {} end
    for _, candidate in ipairs(state.inventory) do
        local candidates = candidatesBySlot[candidate.slot]
        if candidates and not candidate.aidLocked then candidates[#candidates + 1] = candidate end
    end
    for _, candidates in pairs(candidatesBySlot) do
        table.sort(candidates, function(left, right)
            local comparison = Catalog.CompareItemPower(left, right)
            if comparison == 0 then return left.id < right.id end
            return comparison > 0
        end)
    end

    for _, slot in ipairs(Catalog.SLOTS) do
        local current = findItem(state, selected[slot.id], itemById)
        if not (current and (current.locked or current.aidLocked)) then
            local bestEquipped = selected
            local best = evaluate(selected)
            local candidates = candidatesBySlot[slot.id]
            for index = 1, math.min(6, #candidates) do
                local proposal = shallowCopy(selected)
                proposal[slot.id] = candidates[index].id
                local evaluated = evaluate(proposal)
                if upgradePasses(best, evaluated, 0)
                    and (tonumber(evaluated.score.towerScore) or 0)
                        > (tonumber(best.score.towerScore) or 0)
                then
                    best = evaluated
                    bestEquipped = proposal
                end
            end
            selected = bestEquipped
        end
    end

    local optimized = evaluate(selected)
    local changedSlots = 0
    for _, slot in ipairs(Catalog.SLOTS) do
        if originalEquipped[slot.id] ~= selected[slot.id] then
            changedSlots = changedSlots + 1
        end
    end
    if changedSlots == 0
        or not upgradePasses(original, optimized, RewardPolicy.AUTO_EQUIP_MINIMUM_GAIN)
    then
        return false, nil
    end
    state.equipped = selected
    return true, { before = original, after = optimized }, changedSlots
end

local function weakestSlots(state)
    local growth = TowerRules.GrowthNumber(state.floor) or 1
    local ranked = {}
    local itemById = indexItems(state)
    for _, slot in ipairs(Catalog.SLOTS) do
        local item = findItem(state, state.equipped[slot.id], itemById)
        local score = -1
        if item then
            local stats = Catalog.GetItemEffectiveStats(item)
            score = stats.atk / math.max(1, 90 * growth)
                + stats.def / math.max(1, 85 * growth)
                + stats.hp / math.max(1, 2200 * growth)
        end
        ranked[#ranked + 1] = { slot = slot.id, score = score }
    end
    table.sort(ranked, function(left, right)
        if left.score == right.score then return left.slot < right.slot end
        return left.score < right.score
    end)
    return ranked
end

local function definitionCandidates(rarityId, slotId)
    local candidates, fallback = {}, {}
    for _, definition in ipairs(Catalog.EQUIPMENT_DEFINITIONS) do
        if not slotId or definition.slot == slotId then
            fallback[#fallback + 1] = definition
            if RarityCatalog.NormalizeId(definition.rarity) == rarityId then
                candidates[#candidates + 1] = definition
            end
        end
    end
    return #candidates > 0 and candidates or fallback
end

local function rollCoreAffixes(rarityId, rng, actual)
    local rarity = RarityCatalog.Get(rarityId)
    local count = math.max(0, math.floor(tonumber(rarity and rarity.coreAffixCount) or 0))
    local pool, result = copyArray(CORE_AFFIX_POOL), {}
    for _ = 1, math.min(count, #pool) do
        local affix = table.remove(pool, rng:Integer(1, #pool))
        result[#result + 1] = affix
        if affix == "core.fury" then
            actual.atkBig = BigNumber.MultiplyScalar(actual.atkBig, 1.03)
            actual.atk = BigNumber.ToNumber(actual.atkBig)
        elseif affix == "core.guard" then
            actual.defBig = BigNumber.MultiplyScalar(actual.defBig, 1.04)
            actual.def = BigNumber.ToNumber(actual.defBig)
        elseif affix == "core.vitality" then
            actual.hpBig = BigNumber.MultiplyScalar(actual.hpBig, 1.04)
            actual.hp = BigNumber.ToNumber(actual.hpBig)
        elseif affix == "core.swiftness" then actual.atkSpeed = (actual.atkSpeed or 0) + 0.03
        elseif affix == "core.vampirism" then actual.lifeSteal = (actual.lifeSteal or 0) + 0.01
        elseif affix == "core.boss_hunter" then actual.bossDamage = (actual.bossDamage or 0) + 0.05 end
    end
    return result
end

local function allocateSimulationItemId(state)
    local serial = math.max(1, math.floor(tonumber(state.nextItemId) or 1))
    state.nextItemId = serial + 1
    return string.format("00000000-0000-4000-8000-%012x", serial)
end

local function generatedItem(state, rarityId, rng, floor, slotId, source)
    local candidates = definitionCandidates(rarityId, slotId)
    if #candidates == 0 then return nil end
    local definition = candidates[rng:Integer(1, #candidates)]
    local itemRoll = rng:Integer(9500, 10500) / 10000
    local actual = Catalog.CreateItemStats(definition, floor, rarityId, itemRoll, 0, 0)
    local affixes = rollCoreAffixes(rarityId, rng, actual)
    local uniqueEffect = rarityId == "myth" and "myth.tower_soul_resonance" or nil
    if uniqueEffect then actual.bossDamage = (actual.bossDamage or 0) + 0.08 end
    return {
        id = allocateSimulationItemId(state),
        equipmentId = definition.id,
        name = definition.name,
        slot = definition.slot,
        category = definition.category,
        level = floor,
        enhance = 0,
        star = 0,
        locked = false,
        acquiredAt = floor,
        source = source,
        investedGold = 0,
        investedFragments = 0,
        rarity = rarityId,
        setId = actual.setId,
        setEnabled = actual.setEnabled == true,
        statVersion = 5,
        roll = actual.roll,
        budget = actual.budget,
        budgetBig = actual.budgetBig,
        atk = actual.atk,
        def = actual.def,
        hp = actual.hp,
        atkBig = actual.atkBig,
        defBig = actual.defBig,
        hpBig = actual.hpBig,
        crit = actual.crit,
        critDmg = actual.critDmg,
        atkSpeed = actual.atkSpeed,
        lifeSteal = actual.lifeSteal,
        damageReduction = actual.damageReduction,
        bossDamage = actual.bossDamage,
        coreAffixes = affixes,
        uniqueEffect = uniqueEffect,
    }
end

local function maintainInventory(state)
    local protected = equippedIds(state)
    local candidatesBySlot = {}
    for _, slot in ipairs(Catalog.SLOTS) do candidatesBySlot[slot.id] = {} end
    for _, item in ipairs(state.inventory) do
        if item.locked or item.aidLocked then
            protected[item.id] = true
        elseif not protected[item.id] and candidatesBySlot[item.slot] then
            candidatesBySlot[item.slot][#candidatesBySlot[item.slot] + 1] = item
        end
    end
    for _, candidates in pairs(candidatesBySlot) do
        table.sort(candidates, function(left, right)
            local comparison = Catalog.CompareItemPower(left, right)
            if comparison == 0 then return left.id < right.id end
            return comparison > 0
        end)
        for index = 1, math.min(Progression.INVENTORY_CANDIDATES_PER_SLOT, #candidates) do
            protected[candidates[index].id] = true
        end
    end

    local retained, removed = {}, 0
    for _, item in ipairs(state.inventory) do
        if protected[item.id] then
            retained[#retained + 1] = item
        else
            removed = removed + 1
        end
    end
    state.inventory = retained
    return removed
end

local function applyInventoryMaintenance(state, counters)
    local removed = maintainInventory(state)
    counters.inventoryMaintenanceEvents = counters.inventoryMaintenanceEvents + 1
    counters.interactionSeconds = counters.interactionSeconds
        + Progression.INVENTORY_MAINTENANCE_SECONDS
    if removed > 0 then
        counters.inventoryItemsRemoved = counters.inventoryItemsRemoved + removed
        counters.disposedDrops = counters.disposedDrops + removed
    end
    return removed
end

local function addToInventory(state, item)
    if #state.inventory < Catalog.INVENTORY_CAP then
        state.inventory[#state.inventory + 1] = item
        return true, false
    end
    if DISPOSABLE_RARITIES[item.rarity] then return false, false end
    local equipped = equippedIds(state)
    for index, candidate in ipairs(state.inventory) do
        if not equipped[candidate.id]
            and not candidate.locked
            and not candidate.aidLocked
            and DISPOSABLE_RARITIES[candidate.rarity]
        then
            table.remove(state.inventory, index)
            state.inventory[#state.inventory + 1] = item
            return true, false
        end
    end
    return false, true
end

local function recordAutoEquipComparison(
    chapter,
    comparison,
    floor,
    cohortSeed,
    eventIndex,
    model)
    if not comparison then return end
    local targetFloor = nextChapterFloor(floor)
    local beforePrepared = CombatSimulator.PrepareCombat(
        comparison.before.stats, targetFloor, "chapterBoss")
    local afterPrepared = CombatSimulator.PrepareCombat(
        comparison.after.stats, targetFloor, "chapterBoss")
    chapter.autoEquipAccepted = (chapter.autoEquipAccepted or 0) + 1
    chapter.autoEquipPairedTrials = chapter.autoEquipPairedTrials or 0
    chapter.autoEquipBeforeSuccesses = chapter.autoEquipBeforeSuccesses or 0
    chapter.autoEquipAfterSuccesses = chapter.autoEquipAfterSuccesses or 0
    for trial = 1, Progression.AUTO_EQUIP_COMPARISON_TRIALS do
        local trialSeed = CombatSimulator.NormalizeSeed(
            cohortSeed + eventIndex * 1000003 + floor * 1009 + trial * 97)
        local before = CombatSimulator.SimulateRoute(
            beforePrepared,
            CombatSimulator.Rng.New(trialSeed),
            { model = model })
        local after = CombatSimulator.SimulateRoute(
            afterPrepared,
            CombatSimulator.Rng.New(trialSeed),
            { model = model })
        chapter.autoEquipPairedTrials = chapter.autoEquipPairedTrials + 1
        if before.success then
            chapter.autoEquipBeforeSuccesses = chapter.autoEquipBeforeSuccesses + 1
        end
        if after.success then
            chapter.autoEquipAfterSuccesses = chapter.autoEquipAfterSuccesses + 1
        end
    end
end

local function settleDrop(
    state,
    kind,
    rng,
    floor,
    autoEquip,
    belowRecommended,
    counters,
    chapter,
    cohortSeed,
    model)
    local droppedRarity = nil
    if RewardPolicy.ShouldDrop(kind, rng:Next()) then
        droppedRarity = RewardPolicy.RollRarity(kind, floor, rng:Next(), state.rewardPity)
        counters.rarityDrops[droppedRarity] = (counters.rarityDrops[droppedRarity] or 0) + 1
        chapter.rarityDrops[droppedRarity] = (chapter.rarityDrops[droppedRarity] or 0) + 1
        local slotId = nil
        if belowRecommended then
            local ranked, weak, all = weakestSlots(state), {}, {}
            for index = 1, math.min(3, #ranked) do weak[index] = ranked[index].slot end
            for index, slot in ipairs(Catalog.SLOTS) do all[index] = slot.id end
            slotId = RewardPolicy.PickDropSlot(all, weak, rng:Next(), rng:Next())
        end
        local source = kind == "chapterBoss" and "chapter_boss_drop"
            or (kind == "boss" and "boss_drop" or (kind == "elite" and "elite_drop" or "monster_drop"))
        local item = generatedItem(state, droppedRarity, rng, floor, slotId, source)
        local added, inventoryBlocked = false, false
        if item then
            added, inventoryBlocked = addToInventory(state, item)
            if inventoryBlocked then
                counters.inventoryCapacityBlocks = counters.inventoryCapacityBlocks + 1
                counters.inventoryBlockedFloor = counters.inventoryBlockedFloor or floor
                return true
            end
        end
        if item and added then
            counters.drops = counters.drops + 1
            local available, equipped, comparison = considerUpgrade(state, item, autoEquip)
            if available then counters.wearableUpgrades = counters.wearableUpgrades + 1 end
            if equipped then
                counters.autoEquipEvents = counters.autoEquipEvents + 1
                counters.autoEquipComparisons = counters.autoEquipComparisons + 1
                recordAutoEquipComparison(
                    chapter,
                    comparison,
                    floor,
                    cohortSeed,
                    counters.autoEquipComparisons,
                    model)
            end
        else
            counters.disposedDrops = counters.disposedDrops + 1
        end
    end

    if kind == "chapterBoss" then
        state.rewardPity = RewardPolicy.UpdatePity(state.rewardPity, droppedRarity)
        if floor < (RarityCatalog.Get("epic").unlockFloor or 50) then
            state.rewardPity.epicMisses = 0
        end
        if floor < (RarityCatalog.Get("myth").unlockFloor or 100) then
            state.rewardPity.mythMisses = 0
        end
    end
    return false
end

local function routeKinds(floor)
    local result = {}
    for _ = 1, 7 do result[#result + 1] = "normal" end
    for _ = 1, 2 do result[#result + 1] = "elite" end
    result[#result + 1] = floor % 10 == 0 and "chapterBoss" or "boss"
    return result
end

local function storySeconds(lines)
    return Progression.STORY_GATE_OVERHEAD_SECONDS
        + #(lines or {}) * Progression.STORY_SECONDS_PER_LINE
end

local function chapterStorySeconds(floor)
    if floor % 10 ~= 0 then return 0 end
    local total = 0
    for _, phase in ipairs({ "opening", "boss", "memory" }) do
        total = total + storySeconds(StoryCatalog.GetGateForFloor(floor, phase).lines)
    end
    return total
end

local function refreshStats(state, recoverToFull)
    local currentHp = tonumber(state.hp)
    state.stats = Catalog.CalculateStats(state, { skipPowerEvaluation = true })
    if recoverToFull or currentHp == nil then
        state.hp = state.stats.hp
    else
        state.hp = math.max(0, math.min(currentHp, state.stats.hp))
    end
    return state.stats
end

local function belowRecommendedPower(stats, floor)
    local evaluation = PowerEvaluator.EvaluateAtFloor(stats, floor)
    return (tonumber(evaluation.towerScore) or 0) < 1
end

local function configureState(autoEquip)
    local state = StateFactory.Create(0)
    state.automationPolicy = { autoEquip = autoEquip, lootAutoEquip = autoEquip, autoSkipStory = false }
    state.storyProgress.introCompleted = true
    state.inventoryPolicy = {
        pauseOnFull = false,
        autoDecompose = true,
        autoSell = false,
        decomposeRarities = {
            common = true, advanced = true, rare = true, artifact = true,
            legendary = false, epic = false, myth = false,
        },
        sellRarities = {
            common = false, advanced = false, rare = false, artifact = false,
            legendary = false, epic = false, myth = false,
        },
    }
    refreshStats(state, true)
    return state
end

local function chapterRecord(chapters, floor)
    local chapter = math.floor((floor - 1) / 10) + 1
    chapters[chapter] = chapters[chapter] or {
        chapter = chapter,
        attempts = 0,
        successes = 0,
        upgrades = 0,
        autoEquipAccepted = 0,
        autoEquipPairedTrials = 0,
        autoEquipBeforeSuccesses = 0,
        autoEquipAfterSuccesses = 0,
        rarityDrops = {},
    }
    return chapters[chapter]
end

local function floorOnlyDisplayDelta(stats, floor, current)
    current = current or PowerEvaluator.Evaluate(stats, { floor = floor })
    local nextFloor = PowerEvaluator.Evaluate(stats, { floor = floor + 1 })
    local left = tonumber(current.displayedPowerNumber) or 0
    local right = tonumber(nextFloor.displayedPowerNumber) or 0
    if left == right then return 0 end
    return math.abs(left - right) / math.max(1e-12, math.abs(left), math.abs(right))
end

local function clearFloor(state, floor)
    if (Catalog.GetSetCounts(state).prophecy or 0) >= 12 then
        state.permanentBonus = (state.permanentBonus or 0) + 0.005
    end
    for _, item in ipairs(state.inventory) do
        if item.aidLocked and (item.aidFloor or floor) <= floor then item.aidLocked = false end
    end
    state.floor = floor + 1
    state.maxFloor = math.max(state.maxFloor, state.floor)
    state.position = 0
    state.floorDefeats = 0
    state.aidPending = false
    state.floorKillBonus = 0
    refreshStats(state, true)
end

local function claimAid(state, rng, now)
    state.floorDefeats = math.max(2, state.floorDefeats or 0)
    state.aidPending = true
    refreshStats(state, false)
    local result = GameEngine.ClaimAid(state, rng, now)
    if not result.ok then
        return nil, result.error and result.error.reason or "aid claim failed"
    end
    local itemCount, targetMet = 0, false
    for _, event in ipairs(result.delta.events or {}) do
        if event.kind == "tower_aid_claimed" then
            itemCount = event.itemCount or 0
            targetMet = event.targetMet == true
        end
    end
    return result.state, nil, itemCount, targetMet
end

local function elapsedSeconds(counters)
    return counters.combatSeconds
        + counters.transitionSeconds
        + counters.storySeconds
        + counters.interactionSeconds
end

local function simulateBranch(cohortSeed, autoEquip, options)
    math.randomseed(CombatSimulator.NormalizeSeed(cohortSeed))
    local rng = CombatSimulator.Rng.New(cohortSeed)
    local state = configureState(autoEquip)
    local mode = autoEquip and "auto" or "control"
    local chapters, blocks = {}, {}
    local failureCounts, powerRatios, powerRatiosWithin1000 = {}, {}, {}
    local checkpointTimes = {}
    local floorOnlyDisplayDeltas = {}
    local thirdAttemptFailures = {}
    local counters = {
        drops = 0,
        disposedDrops = 0,
        wearableUpgrades = 0,
        autoEquipEvents = 0,
        autoEquipComparisons = 0,
        inventoryCapacityBlocks = 0,
        inventoryBlockedFloor = nil,
        inventoryMaintenanceEvents = 0,
        inventoryItemsRemoved = 0,
        aidClaims = 0,
        aidItems = 0,
        aidTargetsMet = 0,
        aidThirdAttempts = 0,
        aidThirdPasses = 0,
        totalAttempts = 0,
        successfulAttempts = 0,
        softStuckFloors = 0,
        combatSeconds = 0,
        transitionSeconds = 0,
        storySeconds = storySeconds(StoryCatalog.PROLOGUE.lines),
        interactionSeconds = 0,
        rarityDrops = {},
    }
    for _, rarityId in ipairs(RarityCatalog.ORDER) do counters.rarityDrops[rarityId] = 0 end
    local timeTo100Hours = nil
    local maximumDisplayDelta = 0
    local hardStuckFloor = nil

    while state.floor <= options.maxFloor do
        local floor = state.floor
        local failuresThisFloor = 0
        local aidClaimedThisFloor = false
        local cleared = false
        while not cleared and failuresThisFloor < Progression.MAX_ATTEMPTS_PER_FLOOR do
            counters.totalAttempts = counters.totalAttempts + 1
            local chapter = chapterRecord(chapters, floor)
            chapter.attempts = chapter.attempts + 1
            local trialSeed = rng.state
            local isAidThirdAttempt = aidClaimedThisFloor and failuresThisFloor == 2
            local kinds = routeKinds(floor)
            local upgradesBefore = counters.wearableUpgrades
            local inventoryBlocked = false
            local routeSuccess = true
            local deathRoom = nil
            for room, kind in ipairs(kinds) do
                state.position = room
                local stats = refreshStats(state, false)
                local belowRecommended = belowRecommendedPower(stats, floor)
                local prepared = CombatSimulator.PrepareCombat(
                    stats,
                    floor,
                    floor % 10 == 0 and "chapterBoss" or "boss")
                local encounter = CombatSimulator.SimulateEncounter(
                    prepared,
                    kind,
                    rng,
                    {
                        model = options.model,
                        playerHp = state.hp,
                        maxHp = stats.hp,
                    })
                counters.combatSeconds = counters.combatSeconds + encounter.combatSeconds
                if not encounter.success then
                    routeSuccess = false
                    deathRoom = room
                    state.hp = 0
                    break
                end

                state.hp = encounter.remainingHp
                counters.transitionSeconds = counters.transitionSeconds + Catalog.STEP_SECONDS
                state.floorKillBonus = math.min(0.50, (state.floorKillBonus or 0) + 0.01)
                inventoryBlocked = settleDrop(
                    state,
                    kind,
                    rng,
                    floor,
                    autoEquip,
                    belowRecommended,
                    counters,
                    chapter,
                    cohortSeed,
                    options.model)
                if inventoryBlocked then break end
                if room == 10 then
                    local optimized, comparison, changedSlots = optimizeWholeLoadout(
                        state, autoEquip)
                    if optimized then
                        counters.wearableUpgrades = counters.wearableUpgrades + changedSlots
                        counters.autoEquipEvents = counters.autoEquipEvents + 1
                        counters.autoEquipComparisons = counters.autoEquipComparisons + 1
                        recordAutoEquipComparison(
                            chapter,
                            comparison,
                            floor,
                            cohortSeed,
                            counters.autoEquipComparisons,
                            options.model)
                    end
                    if floor % 10 == 0 then applyInventoryMaintenance(state, counters) end
                end
            end
            chapter.upgrades = chapter.upgrades + (counters.wearableUpgrades - upgradesBefore)

            if inventoryBlocked then
                hardStuckFloor = floor
                break
            end

            if routeSuccess then
                counters.successfulAttempts = counters.successfulAttempts + 1
                chapter.successes = chapter.successes + 1
                if failuresThisFloor > 0 then counters.softStuckFloors = counters.softStuckFloors + 1 end
                failureCounts[#failureCounts + 1] = failuresThisFloor
                if isAidThirdAttempt then
                    counters.aidThirdAttempts = counters.aidThirdAttempts + 1
                    counters.aidThirdPasses = counters.aidThirdPasses + 1
                end
                counters.storySeconds = counters.storySeconds + chapterStorySeconds(floor)
                clearFloor(state, floor)
                local finalStats = state.stats
                if floor % 10 == 0 then
                    local floorEvaluation = PowerEvaluator.Evaluate(finalStats, { floor = floor })
                    local powerRatio = tonumber(floorEvaluation.powerRatio) or 0
                    powerRatios[#powerRatios + 1] = powerRatio
                    if floor <= 1000 then
                        powerRatiosWithin1000[#powerRatiosWithin1000 + 1] = powerRatio
                    end
                    local displayDelta = floorOnlyDisplayDelta(finalStats, floor, floorEvaluation)
                    floorOnlyDisplayDeltas[#floorOnlyDisplayDeltas + 1] = displayDelta
                    maximumDisplayDelta = math.max(maximumDisplayDelta, displayDelta)
                end
                local block = math.floor((floor - 1) / 100) + 1
                blocks[block] = blocks[block] or { softStuckFloors = 0, completedFloors = 0 }
                blocks[block].completedFloors = blocks[block].completedFloors + 1
                if failuresThisFloor > 0 then
                    blocks[block].softStuckFloors = blocks[block].softStuckFloors + 1
                end
                if floor % 100 == 0 then
                    checkpointTimes[floor] = elapsedSeconds(counters) / 3600
                end
                if floor == 100 then timeTo100Hours = checkpointTimes[floor] end
                cleared = true
            else
                failuresThisFloor = failuresThisFloor + 1
                state.floorDefeats = failuresThisFloor
                state.position = 0
                state.floorKillBonus = 0
                refreshStats(state, true)
                if failuresThisFloor == 2 then
                    local nextState, reason, itemCount, targetMet = claimAid(
                        state, rng, counters.totalAttempts)
                    if not nextState then
                        hardStuckFloor = floor
                        thirdAttemptFailures[#thirdAttemptFailures + 1] = {
                            floor = floor,
                            room = deathRoom,
                            trialSeed = trialSeed,
                            reason = reason,
                        }
                        break
                    end
                    state = nextState
                    aidClaimedThisFloor = true
                    counters.aidClaims = counters.aidClaims + 1
                    counters.aidItems = counters.aidItems + itemCount
                    if targetMet then counters.aidTargetsMet = counters.aidTargetsMet + 1 end
                elseif isAidThirdAttempt then
                    counters.aidThirdAttempts = counters.aidThirdAttempts + 1
                    thirdAttemptFailures[#thirdAttemptFailures + 1] = {
                        floor = floor,
                        room = deathRoom,
                        trialSeed = trialSeed,
                        reason = "third_attempt_failed",
                    }
                end
            end
        end
        if not cleared then
            hardStuckFloor = hardStuckFloor or floor
            failureCounts[#failureCounts + 1] = failuresThisFloor
            break
        end
    end

    local completedFloor = math.min(options.maxFloor, state.floor - 1)
    local chapterUpgradeCounts = {}
    for chapter = 1, math.floor(completedFloor / 10) do
        local row = chapters[chapter]
        if row then chapterUpgradeCounts[#chapterUpgradeCounts + 1] = row.upgrades end
    end
    local blockSoftStuckCounts = {}
    local blockSoftStuckRates = {}
    for block = 1, math.ceil(options.maxFloor / 100) do
        local source = blocks[block]
        if source and source.completedFloors >= 100 then
            blockSoftStuckCounts[block] = source.softStuckFloors
            blockSoftStuckRates[block] = source.softStuckFloors * 100 / source.completedFloors
        end
    end

    return {
        progressionVersion = Progression.VERSION,
        simulatorVersion = CombatSimulator.VERSION,
        rewardPolicyVersion = RewardPolicy.VERSION,
        storyCatalogVersion = StoryCatalog.VERSION,
        powerEvaluatorVersion = PowerEvaluator.VERSION,
        catalogVersion = Catalog.SCHEMA_VERSION,
        method = Progression.METHOD,
        cohortSeed = CombatSimulator.NormalizeSeed(cohortSeed),
        mode = mode,
        maxFloorTarget = options.maxFloor,
        completedFloor = completedFloor,
        hardStuckFloor = hardStuckFloor,
        timeTo100Hours = timeTo100Hours,
        totalHours = elapsedSeconds(counters) / 3600,
        combatSeconds = counters.combatSeconds,
        transitionSeconds = counters.transitionSeconds,
        storySeconds = counters.storySeconds,
        interactionSeconds = counters.interactionSeconds,
        totalAttempts = counters.totalAttempts,
        successfulAttempts = counters.successfulAttempts,
        attemptSuccessRate = counters.totalAttempts > 0
            and counters.successfulAttempts / counters.totalAttempts or 0,
        softStuckFloors = counters.softStuckFloors,
        softStuckPer100Mean = mean(blockSoftStuckRates),
        maxFailuresOnFloor = maximum(failureCounts),
        failuresBeforeClearP99 = percentile(failureCounts, 0.99),
        aidClaims = counters.aidClaims,
        aidItems = counters.aidItems,
        aidTargetPassRate = counters.aidClaims > 0
            and counters.aidTargetsMet / counters.aidClaims or nil,
        aidThirdAttempts = counters.aidThirdAttempts,
        aidThirdPasses = counters.aidThirdPasses,
        aidThirdAttemptPassRate = counters.aidThirdAttempts > 0
            and counters.aidThirdPasses / counters.aidThirdAttempts or nil,
        drops = counters.drops,
        disposedDrops = counters.disposedDrops,
        rarityDrops = counters.rarityDrops,
        epicPityMisses = state.rewardPity and state.rewardPity.epicMisses or 0,
        mythPityMisses = state.rewardPity and state.rewardPity.mythMisses or 0,
        wearableUpgrades = counters.wearableUpgrades,
        autoEquipEvents = counters.autoEquipEvents,
        autoEquipComparisons = counters.autoEquipComparisons,
        inventoryCapacityBlocks = counters.inventoryCapacityBlocks,
        inventoryBlockedFloor = counters.inventoryBlockedFloor,
        inventoryMaintenanceEvents = counters.inventoryMaintenanceEvents,
        inventoryItemsRemoved = counters.inventoryItemsRemoved,
        upgradesPer10P50 = percentile(chapterUpgradeCounts, 0.50),
        powerRatioP50 = percentile(powerRatios, 0.50),
        powerRatioP10 = percentile(powerRatios, 0.10),
        powerRatioP90 = percentile(powerRatios, 0.90),
        maximumFloorOnlyDisplayedPowerDelta = maximumDisplayDelta,
        chapters = chapters,
        blocks = blocks,
        checkpointTimes = checkpointTimes,
        failureCounts = failureCounts,
        powerRatios = powerRatios,
        powerRatiosWithin1000 = powerRatiosWithin1000,
        floorOnlyDisplayDeltas = floorOnlyDisplayDeltas,
        chapterUpgradeCounts = chapterUpgradeCounts,
        blockSoftStuckCounts = blockSoftStuckCounts,
        blockSoftStuckRates = blockSoftStuckRates,
        thirdAttemptFailures = thirdAttemptFailures,
    }
end

local function gate(id, value, minimum, maximum, sampleCount, minimumSampleCount)
    sampleCount = math.max(0, math.floor(tonumber(sampleCount) or 0))
    minimumSampleCount = math.max(1, math.floor(tonumber(minimumSampleCount) or 1))
    local measured = sampleCount >= minimumSampleCount
    local thresholdPass = (minimum == nil or value >= minimum)
        and (maximum == nil or value <= maximum)
    return {
        id = id,
        value = value,
        minimum = minimum,
        maximum = maximum,
        sampleCount = sampleCount,
        minimumSampleCount = minimumSampleCount,
        measured = measured,
        thresholdPass = thresholdPass,
        pass = measured and thresholdPass,
        status = not measured and "INCONCLUSIVE" or (thresholdPass and "PASS" or "FAIL"),
    }
end

local function aggregate(options, cohorts)
    local auto, control = {}, {}
    for _, cohort in ipairs(cohorts) do
        if cohort.mode == "auto" then auto[#auto + 1] = cohort else control[#control + 1] = cohort end
    end

    local softRates, failureCounts, time100 = {}, {}, {}
    local upgradeCounts, powerRatios, displayDeltas = {}, {}, {}
    local aidThirdAttempts, aidThirdPasses = 0, 0
    local autoCompletionFailures, controlCompletionFailures = 0, 0
    for _, cohort in ipairs(auto) do
        for _, value in ipairs(cohort.blockSoftStuckRates) do softRates[#softRates + 1] = value end
        for _, value in ipairs(cohort.failureCounts) do failureCounts[#failureCounts + 1] = value end
        for _, value in ipairs(cohort.chapterUpgradeCounts) do upgradeCounts[#upgradeCounts + 1] = value end
        for _, value in ipairs(cohort.powerRatiosWithin1000) do powerRatios[#powerRatios + 1] = value end
        for _, value in ipairs(cohort.floorOnlyDisplayDeltas) do
            displayDeltas[#displayDeltas + 1] = value
        end
        if cohort.timeTo100Hours then time100[#time100 + 1] = cohort.timeTo100Hours end
        aidThirdAttempts = aidThirdAttempts + cohort.aidThirdAttempts
        aidThirdPasses = aidThirdPasses + cohort.aidThirdPasses
        if cohort.completedFloor < options.maxFloor then
            autoCompletionFailures = autoCompletionFailures + 1
        end
    end
    for _, cohort in ipairs(control) do
        aidThirdAttempts = aidThirdAttempts + cohort.aidThirdAttempts
        aidThirdPasses = aidThirdPasses + cohort.aidThirdPasses
        if cohort.completedFloor < options.maxFloor then
            controlCompletionFailures = controlCompletionFailures + 1
        end
    end
    local completionFailures = autoCompletionFailures + controlCompletionFailures

    local chapters = {}
    local minimumAutoDelta = math.huge
    local minimumChapterPairedTrials = math.huge
    local comparisonChapterCount = 0
    local totalAutoEquipAccepted = 0
    local totalAutoEquipPairedTrials = 0
    for chapter = 1, math.floor(options.maxFloor / 10) do
        local row = {
            chapter = chapter,
            floorStart = (chapter - 1) * 10 + 1,
            floorEnd = chapter * 10,
            autoAttempts = 0,
            autoSuccesses = 0,
            autoCohortSamples = 0,
            controlAttempts = 0,
            controlSuccesses = 0,
            controlCohortSamples = 0,
            autoEquipAccepted = 0,
            autoEquipPairedTrials = 0,
            autoEquipBeforeSuccesses = 0,
            autoEquipAfterSuccesses = 0,
            rarityDrops = {},
            upgradeCounts = {},
        }
        for _, rarityId in ipairs(RarityCatalog.ORDER) do row.rarityDrops[rarityId] = 0 end
        for _, cohort in ipairs(auto) do
            local source = cohort.chapters[chapter]
            if source then
                row.autoCohortSamples = row.autoCohortSamples + 1
                row.autoAttempts = row.autoAttempts + source.attempts
                row.autoSuccesses = row.autoSuccesses + source.successes
                if cohort.completedFloor >= chapter * 10 then
                    row.upgradeCounts[#row.upgradeCounts + 1] = source.upgrades
                end
                row.autoEquipAccepted = row.autoEquipAccepted
                    + (source.autoEquipAccepted or 0)
                row.autoEquipPairedTrials = row.autoEquipPairedTrials
                    + (source.autoEquipPairedTrials or 0)
                row.autoEquipBeforeSuccesses = row.autoEquipBeforeSuccesses
                    + (source.autoEquipBeforeSuccesses or 0)
                row.autoEquipAfterSuccesses = row.autoEquipAfterSuccesses
                    + (source.autoEquipAfterSuccesses or 0)
                for _, rarityId in ipairs(RarityCatalog.ORDER) do
                    row.rarityDrops[rarityId] = row.rarityDrops[rarityId]
                        + ((source.rarityDrops and source.rarityDrops[rarityId]) or 0)
                end
            end
        end
        for _, cohort in ipairs(control) do
            local source = cohort.chapters[chapter]
            if source then
                row.controlCohortSamples = row.controlCohortSamples + 1
                row.controlAttempts = row.controlAttempts + source.attempts
                row.controlSuccesses = row.controlSuccesses + source.successes
            end
        end
        row.autoSuccessRate = row.autoAttempts > 0 and row.autoSuccesses / row.autoAttempts or 0
        row.controlSuccessRate = row.controlAttempts > 0
            and row.controlSuccesses / row.controlAttempts or 0
        row.unpairedAutoControlDelta = row.autoSuccessRate - row.controlSuccessRate
        row.autoEquipBeforeSuccessRate = row.autoEquipPairedTrials > 0
            and row.autoEquipBeforeSuccesses / row.autoEquipPairedTrials or 0
        row.autoEquipAfterSuccessRate = row.autoEquipPairedTrials > 0
            and row.autoEquipAfterSuccesses / row.autoEquipPairedTrials or 0
        row.autoEquipDelta = row.autoEquipAfterSuccessRate - row.autoEquipBeforeSuccessRate
        row.upgradesSampleCount = #row.upgradeCounts
        row.upgradesP50 = percentile(row.upgradeCounts, 0.50)
        totalAutoEquipAccepted = totalAutoEquipAccepted + row.autoEquipAccepted
        totalAutoEquipPairedTrials = totalAutoEquipPairedTrials + row.autoEquipPairedTrials
        if row.autoEquipPairedTrials > 0 then
            comparisonChapterCount = comparisonChapterCount + 1
            minimumAutoDelta = math.min(minimumAutoDelta, row.autoEquipDelta)
            minimumChapterPairedTrials = math.min(
                minimumChapterPairedTrials,
                row.autoEquipPairedTrials)
        end
        row.upgradeCounts = nil
        chapters[#chapters + 1] = row
    end
    if minimumAutoDelta == math.huge then minimumAutoDelta = 0 end
    if minimumChapterPairedTrials == math.huge then minimumChapterPairedTrials = 0 end

    local checkpoints = {}
    for checkpoint = 100, options.maxFloor, 100 do
        local block = checkpoint / 100
        local blockSoft, checkpointPower, checkpointTime = {}, {}, {}
        for _, cohort in ipairs(auto) do
            if cohort.completedFloor >= checkpoint then
                if cohort.blockSoftStuckRates[block] ~= nil then
                    blockSoft[#blockSoft + 1] = cohort.blockSoftStuckRates[block]
                end
                local ratioIndex = checkpoint / 10
                if cohort.powerRatios[ratioIndex] then
                    checkpointPower[#checkpointPower + 1] = cohort.powerRatios[ratioIndex]
                end
                if cohort.checkpointTimes[checkpoint] then
                    checkpointTime[#checkpointTime + 1] = cohort.checkpointTimes[checkpoint]
                end
            end
        end
        checkpoints[#checkpoints + 1] = {
            checkpointFloor = checkpoint,
            softStuckSampleCount = #blockSoft,
            softStuckPer100Mean = mean(blockSoft),
            softStuckPer100P50 = percentile(blockSoft, 0.50),
            softStuckPer100P90 = percentile(blockSoft, 0.90),
            powerRatioSampleCount = #checkpointPower,
            powerRatioP50 = percentile(checkpointPower, 0.50),
            powerRatioP10 = percentile(checkpointPower, 0.10),
            powerRatioP90 = percentile(checkpointPower, 0.90),
            cumulativeHoursSampleCount = #checkpointTime,
            cumulativeHoursP50 = percentile(checkpointTime, 0.50),
            cumulativeHoursP90 = percentile(checkpointTime, 0.90),
        }
    end

    local gates = Progression.GATES
    local gateRows = {
        gate("soft_stuck_per_100_mean", mean(softRates),
            gates.softStuckPer100Minimum, gates.softStuckPer100Maximum,
            #softRates, Progression.MINIMUM_CHECKPOINT_SAMPLES),
        gate("failures_before_clear_p99", percentile(failureCounts, 0.99),
            nil, gates.failuresBeforeClearP99Maximum,
            #failureCounts, Progression.MINIMUM_FLOOR_SAMPLES),
        gate("aid_third_attempt_pass_rate",
            aidThirdAttempts > 0 and aidThirdPasses / aidThirdAttempts or 0,
            gates.aidThirdAttemptPassRateMinimum, nil,
            aidThirdAttempts, Progression.MINIMUM_AID_THIRD_ATTEMPTS),
        gate("floor_100_hours_p50", percentile(time100, 0.50),
            gates.floor100HoursP50Minimum, gates.floor100HoursP50Maximum,
            #time100, Progression.MINIMUM_COHORT_SAMPLES),
        gate("floor_100_hours_p90", percentile(time100, 0.90),
            nil, gates.floor100HoursP90Maximum,
            #time100, Progression.MINIMUM_COHORT_SAMPLES),
        gate("wearable_upgrades_per_10_p50", percentile(upgradeCounts, 0.50),
            gates.upgradesPer10P50Minimum, gates.upgradesPer10P50Maximum,
            #upgradeCounts, Progression.MINIMUM_CHECKPOINT_SAMPLES),
        gate("power_ratio_within_1000_p50", percentile(powerRatios, 0.50),
            gates.powerRatioP50Minimum, gates.powerRatioP50Maximum,
            #powerRatios, Progression.MINIMUM_CHECKPOINT_SAMPLES),
        gate("auto_equip_minimum_chapter_delta", minimumAutoDelta,
            -gates.autoEquipChapterDeclineMaximum, nil,
            minimumChapterPairedTrials,
            Progression.MINIMUM_AUTO_EQUIP_PAIRED_TRIALS_PER_CHAPTER),
        gate("floor_only_displayed_power_delta_maximum",
            maximum(displayDeltas),
            nil, gates.floorOnlyDisplayedPowerDeltaMaximum,
            #displayDeltas, 1),
        gate("auto_cohort_completion_failures", autoCompletionFailures, nil, 0,
            #auto, 1),
    }

    local passed = true
    for _, row in ipairs(gateRows) do if not row.pass then passed = false end end
    return {
        passed = passed,
        gates = gateRows,
        chapters = chapters,
        checkpoints = checkpoints,
        autoCohorts = auto,
        controlCohorts = control,
        aidThirdAttempts = aidThirdAttempts,
        aidThirdPasses = aidThirdPasses,
        completionFailures = completionFailures,
        autoCompletionFailures = autoCompletionFailures,
        controlCompletionFailures = controlCompletionFailures,
        comparisonChapterCount = comparisonChapterCount,
        totalAutoEquipAccepted = totalAutoEquipAccepted,
        totalAutoEquipPairedTrials = totalAutoEquipPairedTrials,
        minimumChapterPairedTrials = minimumChapterPairedTrials,
    }
end

local function cohortFailureReasons(cohort)
    local gates = Progression.GATES
    local reasons = {}
    local aidThirdAttempts = math.max(0, tonumber(cohort.aidThirdAttempts) or 0)
    local aidThirdAttemptPassRate = tonumber(cohort.aidThirdAttemptPassRate)
    if cohort.completedFloor < cohort.maxFloorTarget then reasons[#reasons + 1] = "incomplete" end
    if aidThirdAttempts > 0
        and aidThirdAttemptPassRate
        and aidThirdAttemptPassRate < gates.aidThirdAttemptPassRateMinimum
    then
        reasons[#reasons + 1] = "aid_third_attempt"
    end
    if cohort.mode ~= "auto" then return reasons end
    if type(cohort.blockSoftStuckRates) == "table"
        and next(cohort.blockSoftStuckRates) ~= nil
        and (cohort.softStuckPer100Mean < gates.softStuckPer100Minimum
            or cohort.softStuckPer100Mean > gates.softStuckPer100Maximum)
    then reasons[#reasons + 1] = "soft_stuck_per_100" end
    if cohort.failuresBeforeClearP99 > gates.failuresBeforeClearP99Maximum then
        reasons[#reasons + 1] = "failures_p99"
    end
    if cohort.timeTo100Hours and (cohort.timeTo100Hours < gates.floor100HoursP50Minimum
        or cohort.timeTo100Hours > gates.floor100HoursP50Maximum)
    then reasons[#reasons + 1] = "floor_100_hours" end
    if type(cohort.chapterUpgradeCounts) == "table"
        and next(cohort.chapterUpgradeCounts) ~= nil
        and (cohort.upgradesPer10P50 < gates.upgradesPer10P50Minimum
            or cohort.upgradesPer10P50 > gates.upgradesPer10P50Maximum)
    then reasons[#reasons + 1] = "wearable_upgrades" end
    if type(cohort.powerRatios) == "table"
        and next(cohort.powerRatios) ~= nil
        and (cohort.powerRatioP50 < gates.powerRatioP50Minimum
            or cohort.powerRatioP50 > gates.powerRatioP50Maximum)
    then reasons[#reasons + 1] = "power_ratio" end
    if cohort.maximumFloorOnlyDisplayedPowerDelta
        > gates.floorOnlyDisplayedPowerDeltaMaximum
    then reasons[#reasons + 1] = "floor_display_delta" end
    return reasons
end

function Progression.Run(options)
    options = options or {}
    local samples = math.max(1, math.floor(tonumber(options.samples) or Progression.DEFAULT_SAMPLES))
    local maxFloor = math.max(100, math.floor(tonumber(options.maxFloor) or Progression.DEFAULT_MAX_FLOOR))
    local baseSeed = CombatSimulator.NormalizeSeed(options.seed)
    local actual = {
        samples = samples,
        maxFloor = maxFloor,
        seed = baseSeed,
        model = options.model or "aggregate",
    }
    local cohorts = {}
    for index = 1, samples do
        local cohortSeed = CombatSimulator.NormalizeSeed(baseSeed + index * 300007)
        cohorts[#cohorts + 1] = simulateBranch(cohortSeed, true, actual)
        cohorts[#cohorts + 1] = simulateBranch(cohortSeed, false, actual)
    end
    local summary = aggregate(actual, cohorts)
    summary.samples = samples
    summary.maxFloor = maxFloor
    summary.seed = baseSeed
    summary.model = actual.model
    summary.version = Progression.VERSION
    summary.method = Progression.METHOD
    summary.catalogVersion = Catalog.SCHEMA_VERSION
    summary.storyCatalogVersion = StoryCatalog.VERSION
    summary.branchComparisonDesign = "same-starting-seed-conditional-rng-streams"
    summary.branchPairedRandomStream = false
    summary.autoEquipGateDesign = "accepted-upgrade-common-random-number-pairs"
    summary.autoEquipGatePairedRandomStream = true
    summary.failureSeeds = {}
    local replayCandidates = {}
    for _, cohort in ipairs(summary.autoCohorts) do replayCandidates[#replayCandidates + 1] = cohort end
    for _, cohort in ipairs(summary.controlCohorts) do replayCandidates[#replayCandidates + 1] = cohort end
    for _, cohort in ipairs(replayCandidates) do
        local reasons = cohortFailureReasons(cohort)
        if #reasons > 0 and #summary.failureSeeds < Progression.FAILURE_SEED_LIMIT then
            summary.failureSeeds[#summary.failureSeeds + 1] = {
                progressionVersion = Progression.VERSION,
                method = Progression.METHOD,
                cohortSeed = cohort.cohortSeed,
                mode = cohort.mode,
                reasons = table.concat(reasons, ";"),
                completedFloor = cohort.completedFloor,
                hardStuckFloor = cohort.hardStuckFloor,
                inventoryCapacityBlocks = cohort.inventoryCapacityBlocks,
                inventoryBlockedFloor = cohort.inventoryBlockedFloor,
                timeTo100Hours = cohort.timeTo100Hours,
                softStuckPer100Mean = cohort.softStuckPer100Mean,
                failuresBeforeClearP99 = cohort.failuresBeforeClearP99,
                upgradesPer10P50 = cohort.upgradesPer10P50,
                powerRatioP50 = cohort.powerRatioP50,
                maximumFloorOnlyDisplayedPowerDelta = cohort.maximumFloorOnlyDisplayedPowerDelta,
            }
        end
    end
    return summary
end

function Progression.Replay(cohortSeed, options)
    options = options or {}
    local actual = {
        maxFloor = math.max(100, math.floor(tonumber(options.maxFloor) or Progression.DEFAULT_MAX_FLOOR)),
        model = options.model or "aggregate",
    }
    return {
        auto = simulateBranch(cohortSeed, true, actual),
        control = simulateBranch(cohortSeed, false, actual),
    }
end

Progression._TestOnly = {
    Aggregate = aggregate,
    CohortFailureReasons = cohortFailureReasons,
}

return Progression
