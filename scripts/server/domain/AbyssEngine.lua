local AbyssDefinitions = require("shared.AbyssDefinitions")
local RarityCatalog = require("shared.RarityCatalog")
local PlayerTransition = require("server.domain.PlayerTransition")
local RewardEngine = require("server.domain.RewardEngine")
local EquipmentEngine = require("server.domain.EquipmentEngine")
local DomainMath = require("server.domain.DomainMath")
local Catalog = require("server.domain.Catalog")
local RewardClaimEngine = require("server.domain.RewardClaimEngine")
local LargeNumber = require("shared.LargeNumber")
local QuestEngine = require("server.domain.QuestEngine")

local AbyssEngine = {}

local function ensureState(state)
    state.abyss = type(state.abyss) == "table"
        and state.abyss or AbyssDefinitions.NewState()
    return state.abyss
end

function AbyssEngine.GrantTickets(state, amount)
    local abyss = ensureState(state)
    local granted = math.max(0, math.floor(tonumber(amount) or 0))
    abyss.tickets = math.max(0, math.floor(tonumber(abyss.tickets) or 0))
        + granted
    return granted, abyss.tickets
end

local function makeRunId(state, source, now)
    return string.format(
        "abyss.%s.%d.%d",
        source,
        math.max(0, math.floor(tonumber(state.revision) or 0)) + 1,
        PlayerTransition.Now(now)
    )
end

local function dropFloor(state)
    return math.max(
        1,
        math.floor(tonumber(state.level) or 1),
        math.floor(tonumber(state.maxFloor) or state.floor or 1)
    )
end

local function qualityWeights(grade, floor)
    local weights = {}
    local highest = RarityCatalog.HighestUnlocked(floor).id
    for _, rarityId in ipairs(RarityCatalog.ORDER) do weights[rarityId] = 0 end
    for _, rarityId in ipairs(RarityCatalog.ORDER) do
        local amount = math.max(0, tonumber(grade.qualityWeights[rarityId]) or 0)
        if RarityCatalog.IsUnlocked(rarityId, floor) then
            weights[rarityId] = weights[rarityId] + amount
        else
            weights[highest] = weights[highest] + amount
        end
    end
    return weights
end

local function rollRarity(grade, floor, rng)
    local weights = qualityWeights(grade, floor)
    local total = 0
    for _, rarityId in ipairs(RarityCatalog.ORDER) do
        total = total + (weights[rarityId] or 0)
    end
    local threshold = DomainMath.RandomFloat(rng) * total
    local accumulated = 0
    local fallback = "common"
    for _, rarityId in ipairs(RarityCatalog.ORDER) do
        local amount = weights[rarityId] or 0
        if amount > 0 then fallback = rarityId end
        accumulated = accumulated + amount
        if threshold < accumulated then return rarityId end
    end
    return fallback
end

local function shouldDrop(abyss, grade, rng)
    if (abyss.dryStreak or 0) + 1 >= AbyssDefinitions.HARD_PITY_ATTEMPT then
        return true, true
    end
    return DomainMath.RandomFloat(rng) < grade.dropChance, false
end

local function updateHighestGrade(abyss, gradeId)
    if AbyssDefinitions.Rank(gradeId) > AbyssDefinitions.Rank(abyss.highestGrade) then
        abyss.highestGrade = gradeId
    end
end

local function settleWorking(working, source, gradeId, ticketCost, runId, rng, now, events)
    local grade = AbyssDefinitions.Get(gradeId)
    local abyss = ensureState(working)
    local equipmentDropped, guaranteed = shouldDrop(abyss, grade, rng)
    local item = nil
    local inventoryChanged = false
    local rarity = nil

    local baseTicketValue = AbyssDefinitions.TicketCost(
        working.level,
        gradeId
    ) or 0
    local ticketRate = source == "random"
        and AbyssDefinitions.RANDOM_TICKET_REWARD_RATE
        or AbyssDefinitions.ACTIVE_TICKET_REFUND_RATE
    local ticketReward = math.ceil(baseTicketValue * ticketRate)
    AbyssEngine.GrantTickets(working, ticketReward)
    PlayerTransition.AddCurrency(working, "fragments", grade.fragments)
    local baseReward = {
        gold = LargeNumber.Zero(),
        exp = 0,
        fragments = grade.fragments,
        abyssTickets = ticketReward,
    }
    local offer = RewardClaimEngine.CreateAdOffer(
        working,
        {
            source = "abyss_settlement",
            sourceKey = runId,
            baseReward = baseReward,
            meta = {
                runId = runId,
                gradeId = gradeId,
                abyssSource = source,
            },
        },
        now
    )
    if offer then
        events[#events + 1] = PlayerTransition.Event(
            "reward_offer_pending",
            {
                rewardId = offer.id,
                source = offer.source,
                baseReward = offer.baseReward,
                extraReward = offer.extraReward,
            }
        )
    end
    if equipmentDropped then
        local floor = dropFloor(working)
        rarity = rollRarity(grade, floor, rng)
        local added, generated, changed = RewardEngine.AddGeneratedDrop(
            working,
            rarity,
            gradeId == "calamity",
            rng,
            now,
            source == "random" and "abyss_random" or "abyss_activity",
            events,
            {
                floor = floor,
                rollTradeable = true,
                requireInventory = source ~= "random",
            }
        )
        if not added then
            return false, "INVENTORY_FULL", "背包已满，请先分解、出售或扩容"
        end
        item = generated
        inventoryChanged = changed == true
        if item then
            local _, boundOnEquip = EquipmentEngine.ConsiderUpgrade(
                working,
                item,
                now,
                events
            )
            inventoryChanged = inventoryChanged or boundOnEquip
        end
        abyss.dryStreak = 0
        abyss.equipmentDrops = (abyss.equipmentDrops or 0) + 1
    else
        abyss.dryStreak = math.min(
            AbyssDefinitions.HARD_PITY_ATTEMPT - 1,
            (abyss.dryStreak or 0) + 1
        )
    end

    if source == "random" then
        abyss.randomRuns = (abyss.randomRuns or 0) + 1
        abyss.currentRandom = nil
    else
        abyss.activeRuns = (abyss.activeRuns or 0) + 1
    end
    updateHighestGrade(abyss, gradeId)
    QuestEngine.Track(working, "abyss_run", 1, now)

    events[#events + 1] = PlayerTransition.Event("abyss_completed", {
        runId = runId,
        source = source,
        gradeId = gradeId,
        ticketCost = ticketCost,
        fragments = grade.fragments,
        abyssTickets = ticketReward,
        equipmentDropped = equipmentDropped,
        itemId = item and item.id or nil,
        rarity = rarity,
        guaranteed = guaranteed,
        dryStreak = abyss.dryStreak,
    })

    print(string.format(
        "[Abyss] settle source=%s grade=%s dropped=%s rarity=%s dryStreak=%d",
        source,
        gradeId,
        tostring(equipmentDropped),
        tostring(rarity),
        abyss.dryStreak or 0
    ))
    return true, nil, nil, inventoryChanged
end

function AbyssEngine.EnterActivity(inputState, gradeId, now, rng)
    local grade = AbyssDefinitions.Get(gradeId)
    if not grade then
        return PlayerTransition.Failure(inputState, now, "INVALID_ABYSS_GRADE", "未知深渊档位")
    end
    if not AbyssDefinitions.IsUnlocked(gradeId, inputState.level) then
        return PlayerTransition.Failure(
            inputState,
            now,
            "ABYSS_GRADE_LOCKED",
            string.format("该深渊需达到 Lv.%d", grade.minLevel)
        )
    end
    if #inputState.inventory >= Catalog.GetInventoryCapacity(inputState)
        and not EquipmentEngine.HasAutoDispositionPolicy(inputState)
    then
        return PlayerTransition.Failure(
            inputState,
            now,
            "INVENTORY_FULL",
            "背包已满，请先分解、出售或点击容量后的 +50 扩容"
        )
    end

    local ticketCost = AbyssDefinitions.TicketCost(inputState.level, gradeId)
    local currentTickets = inputState.abyss and inputState.abyss.tickets
        or AbyssDefinitions.STARTER_TICKETS
    if currentTickets < ticketCost then
        return PlayerTransition.Failure(
            inputState,
            now,
            "ABYSS_TICKET_INSUFFICIENT",
            string.format("深渊票不足，需要 %d 张", ticketCost)
        )
    end

    local working = PlayerTransition.Copy(inputState, now)
    local abyss = ensureState(working)
    abyss.tickets = abyss.tickets - ticketCost
    local runId = makeRunId(working, "activity", now)
    local events = {
        PlayerTransition.Event("abyss_started", {
            runId = runId,
            source = "activity",
            gradeId = gradeId,
            ticketCost = ticketCost,
            dropChance = grade.dropChance,
        }),
    }
    local settled, code, reason, inventoryChanged = settleWorking(
        working,
        "activity",
        gradeId,
        ticketCost,
        runId,
        rng,
        now,
        events
    )
    if not settled then
        return PlayerTransition.Failure(inputState, now, code, reason)
    end

    print(string.format(
        "[Abyss] enter source=activity grade=%s level=%d cost=%d tickets=%d",
        gradeId,
        working.level,
        ticketCost,
        abyss.tickets
    ))
    return PlayerTransition.Finalize(
        inputState,
        working,
        now,
        "abyss_completed",
        events,
        inventoryChanged,
        false
    )
end

function AbyssEngine.RollRandomGrade(level, rng)
    local candidates = {}
    local total = 0
    for _, gradeId in ipairs(AbyssDefinitions.ORDER) do
        local grade = AbyssDefinitions.Get(gradeId)
        if AbyssDefinitions.IsUnlocked(gradeId, level) then
            total = total + grade.randomWeight
            candidates[#candidates + 1] = { grade = grade, accumulated = total }
        end
    end
    local threshold = DomainMath.RandomFloat(rng) * total
    for _, candidate in ipairs(candidates) do
        if threshold < candidate.accumulated then return candidate.grade.id end
    end
    return "rift"
end

AbyssEngine.SettleWorking = settleWorking
AbyssEngine.MakeRunId = makeRunId
return AbyssEngine
