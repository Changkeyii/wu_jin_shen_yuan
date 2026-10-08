local Catalog = require("server.domain.Catalog")
local StateNormalizer = require("server.domain.StateNormalizer")
local TableUtils = require("server.domain.TableUtils")
local InventoryState = require("server.domain.InventoryState")
local DomainMath = require("server.domain.DomainMath")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")

local PlayerTransition = {}

local SCALAR_DELTA_FIELDS = {
    "pendingOfflineSeconds", "level", "vipLevel", "dailyVip", "exp", "nextExp",
    "floor", "maxFloor", "position", "transitionRemaining", "gold", "fragments",
    "autoRun", "pauseReason", "hp", "hpBig", "floorDefeats", "aidPending",
    "aidGrantedFloors", "floorKillBonus", "permanentBonus", "inventoryPolicy",
    "automationPolicy", "interactionMode", "storyProgress", "pendingStoryGate",
    "ruleAcknowledgements", "pendingEquipDecision", "previousLoadout", "rewardPity",
    "currentMonster", "currentEvent", "lootStash",
    "quests",
    "activities",
    "wishPool",
    "abyss",
    "rewardClaims",
    "challenges",
    "campaign",
    -- 序章步骤必须随 delta 下发，否则客户端 view.tutorial 会一直停在快照值，
    -- 分解/强化教学的 tutorialSelection 与兜底推进都会失效。
    "tutorial",
    -- 广告扩容背包格数与当日广告次数。
    "inventoryBonusSlots",
    "inventoryExpand",
    "seasonRewardWeekKey",
    "seasonTitle",
    "seasonFrame",
}

function PlayerTransition.Now(now)
    return math.max(0, TableUtils.ToInteger(now, os.time()))
end

function PlayerTransition.Copy(state, now)
    return StateNormalizer.Normalize(TableUtils.DeepCopy(state), PlayerTransition.Now(now))
end

function PlayerTransition.ShallowClone(state, now)
    local clone = {}
    for key, value in pairs(state or {}) do
        clone[key] = value
    end
    clone.updatedAt = PlayerTransition.Now(now)
    clone.currentMonster = type(state.currentMonster) == "table" and TableUtils.DeepCopy(state.currentMonster) or state.currentMonster
    clone.stats = type(state.stats) == "table" and TableUtils.DeepCopy(state.stats) or state.stats
    clone.hpBig = state.hpBig
    clone.inventory = state.inventory
    clone.equipped = state.equipped
    clone.overflowLoot = state.overflowLoot
    clone.quests = state.quests
    return clone
end

function PlayerTransition.DetachInventory(state)
    if type(state.inventory) == "table" then
        state.inventory = TableUtils.DeepCopy(state.inventory)
    end
    if type(state.overflowLoot) == "table" then
        state.overflowLoot = TableUtils.DeepCopy(state.overflowLoot)
    end
    if type(state.equipped) == "table" then
        state.equipped = TableUtils.DeepCopy(state.equipped)
    end
    if type(state.lootStash) == "table" then
        state.lootStash = TableUtils.DeepCopy(state.lootStash)
    end
end

function PlayerTransition.Event(kind, fields)
    local value = fields or {}
    value.kind = kind
    return value
end

function PlayerTransition.AddCurrency(state, currency, amount)
    state[currency] = LargeNumber.Add(state[currency], amount)
end

function PlayerTransition.SpendCurrency(state, currency, amount)
    local nextValue, ok = LargeNumber.Subtract(state[currency], amount)
    if not ok then return false end
    state[currency] = nextValue
    return true
end

function PlayerTransition.HasCurrency(state, currency, amount)
    return LargeNumber.Compare(state[currency], amount) >= 0
end

function PlayerTransition.FindItem(state, itemId)
    return TableUtils.FindById(state.inventory, itemId)
end

function PlayerTransition.EquippedIdSet(state)
    local ids = {}
    for _, itemId in pairs(state.equipped) do ids[itemId] = true end
    return ids
end

function PlayerTransition.RefreshDerived(state, combatOnly)
    local previousMaximum = state.stats and (state.stats.hpBig or state.stats.hp) or 1
    local previousHp = DomainMath.Magnitude(state.hpBig, state.hp, previousMaximum)
    if not combatOnly then
        for _, item in ipairs(state.inventory) do item.power = Catalog.GetItemPower(item) end
        for _, item in ipairs(state.overflowLoot or {}) do item.power = Catalog.GetItemPower(item) end
        InventoryState.UpdateCollection(state)
    end
    state.nextExp = Catalog.NextExp(state.level)
    local previousStats = state.stats or {}
    state.stats = Catalog.CalculateStats(state, combatOnly and { skipPowerEvaluation = true } or nil)
    if combatOnly then
        for _, field in ipairs({
            "power", "displayedPower", "recommendedPower", "nextChapterRecommendedPower",
            "powerRatio", "headroomFloors", "difficultyLabel", "equivalentFloor",
            "estimatedEasyFloor", "towerScore", "bossScore", "eliteScore", "dpsSafe", "ehp",
        }) do
            state.stats[field] = previousStats[field]
        end
    end
    state.setProgress = TableUtils.DeepCopy(state.stats.setProgress or {})
    DomainMath.SetPlayerHp(state, BigNumber.Min(previousHp, DomainMath.StatMagnitude(state.stats, "hp")))
    if state.currentMonster then
        state.currentEvent = state.currentMonster.eventType
    else
        state.currentEvent = Catalog.GetCellType(math.max(1, state.position), state.floor)
    end
end

local function BuildCommit(previousRevision, state)
    local persisted = StateNormalizer.ToPersisted(state)
    return {
        kind = "BatchCommit",
        expectedRevision = previousRevision,
        revision = persisted.revision,
        scores = {
            abyss_schema_version = persisted.schemaVersion,
            abyss_revision = persisted.revision,
            abyss_updated_at = persisted.updatedAt,
            abyss_last_active_at = persisted.lastActiveAt,
            abyss_pending_offline_seconds = persisted.pendingOfflineSeconds,
            abyss_level = persisted.level,
            abyss_exp = persisted.exp,
            abyss_floor = persisted.floor,
            abyss_max_floor = persisted.maxFloor,
            abyss_position = persisted.position,
            abyss_auto_run = persisted.autoRun and 1 or 0,
            abyss_pause_reason = persisted.pauseReason == "inventory_full" and 1 or 0,
            abyss_hp = persisted.hp,
            abyss_floor_kill_bonus = persisted.floorKillBonus,
            abyss_permanent_bonus = persisted.permanentBonus,
            abyss_next_item_id = persisted.nextItemId,
        },
        money = {},
        lists = {
            abyss_inventory = persisted.inventory,
            abyss_equipped = persisted.equipped,
        },
        items = { abyss_health_potion = persisted.consumables.healthPotion or 0 },
    }
end

local function BuildDelta(previous, current, kind, events, inventoryChanged, equippedChanged)
    local changed = {}
    for _, field in ipairs(SCALAR_DELTA_FIELDS) do
        if not TableUtils.DeepEqual(previous[field], current[field]) then
            if field == "pauseReason" and current[field] == nil then
                changed[field] = ""
            else
                changed[field] = current[field]
            end
        end
    end
    if not TableUtils.DeepEqual(previous.stats, current.stats) then
        changed.stats = TableUtils.DeepCopy(current.stats)
    end
    if not TableUtils.DeepEqual(previous.consumables, current.consumables) then
        changed.consumables = TableUtils.DeepCopy(current.consumables)
    end
    local delta = {
        kind = "GameDelta",
        operation = kind,
        schemaVersion = Catalog.SCHEMA_VERSION,
        revision = current.revision,
        updatedAt = current.updatedAt,
        changed = changed,
        changes = changed,
        events = TableUtils.DeepCopy(events or {}),
        inventoryCount = #current.inventory,
        inventoryChanged = inventoryChanged == true,
        equippedChanged = equippedChanged == true,
    }
    if inventoryChanged then
        if current.inventoryPatch then
            changed.inventoryPatch = TableUtils.DeepCopy(current.inventoryPatch)
            changed.equipped = TableUtils.DeepCopy(current.equipped)
            changed.consumables = TableUtils.DeepCopy(current.consumables)
        else
            changed.inventory = TableUtils.DeepCopy(current.inventory)
            changed.equipped = TableUtils.DeepCopy(current.equipped)
            changed.consumables = TableUtils.DeepCopy(current.consumables)
        end
    end
    if equippedChanged then changed.equipped = TableUtils.DeepCopy(current.equipped) end
    return delta
end

function PlayerTransition.Finalize(inputState, workingState, now, kind, events, inventoryChanged, equippedChanged, combatOnly)
    now = PlayerTransition.Now(now)
    local previousRevision = math.max(0, TableUtils.ToInteger(inputState and inputState.revision, 0))
    workingState.revision = previousRevision + 1
    workingState.updatedAt = now
    workingState.lastActiveAt = now
    if combatOnly == true then
        PlayerTransition.RefreshDerived(workingState, true)
        local previous = {
            revision = previousRevision,
            inventory = inputState.inventory,
            equipped = inputState.equipped,
            consumables = inputState.consumables,
            stats = inputState.stats,
        }
        for _, field in ipairs(SCALAR_DELTA_FIELDS) do
            previous[field] = inputState[field]
        end
        return {
            ok = true,
            state = workingState,
            delta = BuildDelta(previous, workingState, kind, events, inventoryChanged, equippedChanged),
            commit = { kind = "none", expectedRevision = previousRevision },
        }
    end
    local previous = PlayerTransition.Copy(inputState, now)
    workingState = StateNormalizer.Normalize(workingState, now)
    PlayerTransition.RefreshDerived(workingState, false)
    return {
        ok = true,
        state = workingState,
        delta = BuildDelta(previous, workingState, kind, events, inventoryChanged, equippedChanged),
        commit = BuildCommit(previous.revision, workingState),
    }
end

function PlayerTransition.NoCommit(inputState, now, kind, events)
    local copy = PlayerTransition.Copy(inputState, now)
    local changed = {}
    return {
        ok = true,
        state = copy,
        delta = {
            kind = "GameDelta",
            operation = kind or "noop",
            schemaVersion = Catalog.SCHEMA_VERSION,
            revision = copy.revision,
            updatedAt = copy.updatedAt,
            changed = changed,
            changes = changed,
            events = TableUtils.DeepCopy(events or {}),
            inventoryCount = #copy.inventory,
            inventoryChanged = false,
            equippedChanged = false,
        },
        commit = { kind = "none", expectedRevision = copy.revision },
    }
end

function PlayerTransition.Failure(inputState, now, code, reason, events)
    local proposal = PlayerTransition.NoCommit(inputState, now, "rejected", events)
    proposal.ok = false
    proposal.error = { code = code, reason = reason }
    return proposal
end

return PlayerTransition
