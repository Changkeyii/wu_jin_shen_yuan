local Catalog = require("server.domain.Catalog")
local TrashTalk = require("shared.TrashTalk")
local TableUtils = require("server.domain.TableUtils")
local GameStateSchema = require("shared.GameStateSchema")
local CombatSequence = require("shared.CombatSequence")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local RarityCatalog = require("shared.RarityCatalog")
local StoryCatalog = require("shared.StoryCatalog")

local StateNormalizer = {}

local function clampInteger(value, minimum, maximum, fallback)
    local integer = TableUtils.ToInteger(value, fallback)
    return Catalog.Clamp(integer, minimum, maximum)
end

local function clampNumber(value, minimum, maximum, fallback)
    if not TableUtils.IsFiniteNumber(value) then
        return fallback
    end
    return Catalog.Clamp(value, minimum, maximum)
end

local function instanceUuidFromSequence(sequence)
    local value = math.max(1, TableUtils.ToInteger(sequence, 1))
    local hex = string.format("%012x", value)
    return string.format("00000000-0000-4000-8000-%s", hex)
end

local function nextEquipmentId(usedIds, nextId)
    nextId = math.max(1, nextId)
    local itemId
    repeat
        itemId = instanceUuidFromSequence(nextId)
        nextId = nextId + 1
    until not usedIds[itemId]
    return itemId, nextId
end

local function isInstanceUuid(value)
    return type(value) == "string"
        and #value == 36
        and string.match(value, "^[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+$") ~= nil
end

local function normalizeItemId(rawId, usedIds, nextId)
    if isInstanceUuid(rawId) and not usedIds[rawId] then
        return rawId, nextId
    end
    return nextEquipmentId(usedIds, nextId)
end

local STAR_MULTIPLIERS = { 1.00, 1.03, 1.07, 1.12, 1.18, 1.25 }

local function v4ProgressionMultiplier(enhance, star)
    local enhanceMultiplier = 1 + 0.35 * (1 - math.exp(-math.max(0, enhance or 0) / 20))
    return enhanceMultiplier * (STAR_MULTIPLIERS[math.max(0, math.min(5, star or 0)) + 1] or 1)
end

local function normalizeMagnitude(bigValue, numberValue, fallback)
    if BigNumber.IsBigNumber(bigValue) then return BigNumber.Normalize(bigValue) end
    if TableUtils.IsFiniteNumber(numberValue) and numberValue >= 0 then
        return BigNumber.FromNumber(numberValue)
    end
    return BigNumber.Clone(fallback or BigNumber.Zero())
end

local function projectMagnitude(value)
    return BigNumber.ToNumber(value)
end

local function rawBigNumberIssue(value, path, scope)
    local valid, reason = BigNumber.ValidateCanonical(value)
    if valid then return nil end
    return {
        scope = scope or "profile",
        path = path,
        reason = reason or "BigNumber is missing or invalid",
    }
end

local function validateRawEquipmentBigNumbers(items, path, scope)
    if type(items) ~= "table" then
        return false, { scope = scope, path = path, reason = "equipment list must be a table" }
    end
    for index, item in ipairs(items) do
        if type(item) ~= "table" then
            return false, {
                scope = scope,
                path = string.format("%s[%d]", path, index),
                reason = "equipment entry must be a table",
            }
        end
        for _, fieldName in ipairs({ "budgetBig", "atkBig", "defBig", "hpBig" }) do
            local itemPath = string.format("%s[%d].%s", path, index, fieldName)
            local issue = rawBigNumberIssue(item[fieldName], itemPath, scope)
            if issue then return false, issue end
        end
    end
    return true, nil
end

function StateNormalizer.ValidateRawV5BigNumbers(rawState)
    if type(rawState) ~= "table" then
        return false, { scope = "profile", path = "$profile", reason = "profile must be a table" }
    end
    if rawState.schemaVersion == nil then return true, nil end

    local sourceVersion = tonumber(rawState.schemaVersion)
    if not TableUtils.IsFiniteNumber(sourceVersion)
        or sourceVersion ~= math.floor(sourceVersion)
        or sourceVersion < 1
        or sourceVersion > GameStateSchema.VERSION
    then
        return false, {
            scope = "profile",
            path = "$profile.schemaVersion",
            reason = "unsupported or invalid schema version",
        }
    end
    if sourceVersion < 5 then return true, nil end

    local issue = rawBigNumberIssue(rawState.hpBig, "$profile.hpBig", "profile")
    if issue then return false, issue end

    local inventoryOk, inventoryIssue = validateRawEquipmentBigNumbers(
        rawState.inventory, "$profile.inventory", "inventory")
    if not inventoryOk then return false, inventoryIssue end
    local overflowOk, overflowIssue = validateRawEquipmentBigNumbers(
        rawState.overflowLoot, "$profile.overflowLoot", "profile")
    if not overflowOk then return false, overflowIssue end

    if rawState.currentMonster ~= nil then
        if type(rawState.currentMonster) ~= "table" then
            return false, {
                scope = "profile",
                path = "$profile.currentMonster",
                reason = "current monster must be a table",
            }
        end
        for _, fieldName in ipairs({ "hpBig", "maxHpBig", "atkBig", "defBig" }) do
            issue = rawBigNumberIssue(
                rawState.currentMonster[fieldName],
                "$profile.currentMonster." .. fieldName,
                "profile")
            if issue then return false, issue end
        end
    end

    if rawState.pendingEquipDecision ~= nil then
        if type(rawState.pendingEquipDecision) ~= "table" then
            return false, {
                scope = "profile",
                path = "$profile.pendingEquipDecision",
                reason = "pending equipment decision must be a table",
            }
        end
        issue = rawBigNumberIssue(
            rawState.pendingEquipDecision.displayedPowerDeltaBig,
            "$profile.pendingEquipDecision.displayedPowerDeltaBig",
            "profile")
        if issue then return false, issue end
    end

    return true, nil
end

local function sanitizeAffixes(value)
    local result = {}
    for _, affix in ipairs(type(value) == "table" and value or {}) do
        if type(affix) == "string" and #affix >= 1 and #affix <= 64 and affix:match("^[%w%._:%-]+$") then
            result[#result + 1] = affix
            if #result >= 4 then break end
        end
    end
    return result
end

local function sanitizeEquipment(rawItem, itemId, sourceVersion)
    local definition = Catalog.ResolveEquipment(rawItem)
    if not definition then return nil end
    local level = clampInteger(rawItem.level, 1, 1000000, definition.level or 1)
    local enhance = clampInteger(rawItem.enhance, 0, Catalog.MAX_ENHANCE, 0)
    local star = clampInteger(rawItem.star, 0, Catalog.MAX_STAR, 0)
    local rarity = RarityCatalog.NormalizeId(rawItem.rarity or definition.rarity)
    local setEnabled = rawItem.setEnabled
    if type(setEnabled) ~= "boolean" then
        setEnabled = RarityCatalog.Rank(rarity) >= RarityCatalog.Rank("epic")
    end
    local progression = v4ProgressionMultiplier(enhance, star)
    local atk = tonumber(rawItem.atk)
    local def = tonumber(rawItem.def)
    local hp = tonumber(rawItem.hp)
    local crit = tonumber(rawItem.crit)
    local critDmg = tonumber(rawItem.critDmg)
    local atkSpeed = tonumber(rawItem.atkSpeed)
    if (sourceVersion or 3) < 4 then
        local oldProgression = 1 + (level - 1) * 0.06 + enhance * 0.05 + star * 0.10
        atk = math.floor((definition.atk or 0) * oldProgression) / progression
        def = math.floor((definition.def or 0) * oldProgression) / progression
        hp = math.floor((definition.hp or 0) * oldProgression) / progression
        crit = (definition.crit or 0) + star * 0.002
        critDmg = (definition.critDmg or 0) + star * 0.01
        atkSpeed = (definition.atkSpeed or 0) + enhance * 0.001
    end
    local atkBig = normalizeMagnitude(rawItem.atkBig, atk, definition.atk or 0)
    local defBig = normalizeMagnitude(rawItem.defBig, def, definition.def or 0)
    local hpBig = normalizeMagnitude(rawItem.hpBig, hp, definition.hp or 0)
    local budgetBig = normalizeMagnitude(rawItem.budgetBig, rawItem.budget, 0)
    if BigNumber.IsZero(budgetBig) and (sourceVersion or 3) < 4 then
        budgetBig = BigNumber.FromNumber(
            math.max(0, atk or 0) * 7
                + math.max(0, def or 0) * 3
                + math.max(0, hp or 0) * 0.55
                + math.max(0, crit or 0) * 2000
                + math.max(0, critDmg or 0) * 900
                + math.max(0, atkSpeed or 0) * 650)
    end
    return {
        id = itemId,
        equipmentId = definition.id,
        name = definition.name,
        slot = definition.slot,
        category = definition.category,
        rarity = rarity,
        setEnabled = setEnabled,
        setId = setEnabled and (rawItem.setId or definition.setId) or nil,
        roll = clampNumber(rawItem.roll, 0.90, 1.10, 1.0),
        atk = projectMagnitude(atkBig),
        def = projectMagnitude(defBig),
        hp = projectMagnitude(hpBig),
        atkBig = atkBig,
        defBig = defBig,
        hpBig = hpBig,
        crit = clampNumber(crit, 0, 1, definition.crit or 0),
        critDmg = clampNumber(critDmg, 0, 1000, definition.critDmg or 0),
        atkSpeed = clampNumber(atkSpeed, 0, 100, definition.atkSpeed or 0),
        lifeSteal = clampNumber(rawItem.lifeSteal, 0, 1, 0),
        damageReduction = clampNumber(rawItem.damageReduction, 0, 0.70, 0),
        bossDamage = clampNumber(rawItem.bossDamage, 0, 1000, 0),
        coreAffixes = sanitizeAffixes(rawItem.coreAffixes),
        uniqueEffect = type(rawItem.uniqueEffect) == "string" and rawItem.uniqueEffect:match("^[%w%._:%-]+$") and rawItem.uniqueEffect or nil,
        aidLocked = rawItem.aidLocked == true,
        aidFloor = rawItem.aidFloor and clampInteger(rawItem.aidFloor, 1, 1000000000, 1) or nil,
        level = level,
        enhance = enhance,
        star = star,
        locked = rawItem.locked == true,
        acquiredAt = math.max(0, TableUtils.ToInteger(rawItem.acquiredAt, 0)),
        source = type(rawItem.source) == "string" and rawItem.source:match("^[%w%._:%-]+$") and rawItem.source or "legacy",
        tradeable = rawItem.tradeable == true,
        statVersion = 5,
        budget = projectMagnitude(budgetBig),
        budgetBig = budgetBig,
        investedGold = LargeNumber.IsLargeNumber(
            rawItem.investedGold
        ) and LargeNumber.Normalize(rawItem.investedGold)
            or LargeNumber.FromNumber(rawItem.investedGold),
        investedFragments = clampInteger(rawItem.investedFragments, 0, Catalog.MAX_VALUE, 0),
    }
end

local function materialKind(item)
    local name = type(item.name) == "string" and item.name or ""
    if name:find("碎片") or name:lower():find("fragment") then
        return "fragments"
    end
    return nil
end

local function sanitizeAidFloors(value)
    local result = {}
    local seen = {}
    for _, floor in ipairs(type(value) == "table" and value or {}) do
        floor = clampInteger(floor, 1, 1000000000, 1)
        if not seen[floor] then
            seen[floor] = true
            result[#result + 1] = floor
            if #result >= 10000 then break end
        end
    end
    return result
end

local function sanitizeRuleAcknowledgements(value)
    local result = {}
    for ruleId, acknowledged in pairs(type(value) == "table" and value or {}) do
        if acknowledged == true
            and type(ruleId) == "string"
            and #ruleId >= 1
            and #ruleId <= 96
            and ruleId:match("^[%w%._:%-]+$")
        then
            result[StoryCatalog.NormalizeRuleId(ruleId)] = true
        end
    end
    return result
end

local function sanitizeAutomationPolicy(value)
    local supplied = type(value) == "table"
    value = supplied and value or {}
    local lootAutoEquip = supplied and value.lootAutoEquip == true
    return {
        autoEquip = lootAutoEquip,
        lootAutoEquip = lootAutoEquip,
        autoSkipStory = value.autoSkipStory == true,
    }
end

local function sanitizeEquipmentCollection(value)
    local result = {}
    for equipmentId, record in pairs(type(value) == "table" and value or {}) do
        if Catalog.GetEquipmentDefinition(equipmentId) and type(record) == "table" then
            local powerBig = BigNumber.Normalize(record.powerBig or record.power or 0)
            result[equipmentId] = {
                powerBig = powerBig,
                level = clampInteger(record.level, 1, 1000000, 1),
                enhance = clampInteger(record.enhance, 0, Catalog.MAX_ENHANCE, 0),
                star = clampInteger(record.star, 0, Catalog.MAX_STAR, 0),
                rarity = RarityCatalog.NormalizeId(record.rarity),
            }
        end
    end
    return result
end

local function sanitizeRewardPity(value)
    value = type(value) == "table" and value or {}
    return {
        epicMisses = clampInteger(value.epicMisses or value.epicChapterMisses, 0, 20, 0),
        mythMisses = clampInteger(value.mythMisses or value.mythChapterMisses, 0, 100, 0),
    }
end

local function sanitizeStoryProgress(value, sourceVersion, maxFloor)
    value = type(value) == "table" and value or {}
    local migrated = sourceVersion < 4
    return {
        introCompleted = migrated or value.introCompleted == true,
        highestCompletedChapter = migrated
            and math.max(0, math.floor((math.max(1, maxFloor) - 1) / 10))
            or clampInteger(value.highestCompletedChapter, 0, 100000000, 0),
        contentVersion = clampInteger(value.contentVersion, 1, 1000000, StoryCatalog.VERSION),
    }
end

local function sanitizeStoryGate(value)
    if type(value) ~= "table" then return nil end
    local phase = value.phase
    if phase == "prologue" then
        return {
            storyId = StoryCatalog.PROLOGUE.id,
            chapter = 0,
            floor = 1,
            phase = "prologue",
            title = StoryCatalog.PROLOGUE.title,
            lines = TableUtils.DeepCopy(StoryCatalog.PROLOGUE.lines),
            lineIndex = clampInteger(value.lineIndex, 1, #StoryCatalog.PROLOGUE.lines, 1),
        }
    end
    if phase ~= "opening" and phase ~= "boss" and phase ~= "memory" then return nil end
    local chapter = clampInteger(value.chapter, 1, 100000000, math.max(1, math.floor((tonumber(value.floor) or 10) / 10)))
    local gate = StoryCatalog.GetGate(chapter, phase)
    gate.lineIndex = clampInteger(value.lineIndex, 1, #gate.lines, 1)
    return gate
end

local PENDING_EVENT_TYPES = {
    chest = true,
    merchant = true,
    randomEvent = true,
}

local PENDING_EVENT_ACTIONS = {
    open = true,
    buy = true,
    accept = true,
    skip = true,
}

-- 交互事件必须保留 skip：超时结算只会跳过，永不代替玩家消费。
local function sanitizePendingEvent(value)
    if type(value) ~= "table" then return nil end
    local eventType = value.eventType
    if not PENDING_EVENT_TYPES[eventType] then return nil end
    local eventId = value.eventId
    if type(eventId) ~= "string"
        or #eventId < 1
        or #eventId > 96
        or not eventId:match("^[%w%._:%-]+$")
    then
        return nil
    end
    local encounterId = value.encounterId
    if type(encounterId) ~= "string" or #encounterId < 1 or #encounterId > 96 then
        return nil
    end

    local actions = {}
    local hasSkip = false
    for _, action in ipairs(type(value.actions) == "table" and value.actions or {}) do
        if PENDING_EVENT_ACTIONS[action] and #actions < 4 then
            actions[#actions + 1] = action
            if action == "skip" then hasSkip = true end
        end
    end
    if not hasSkip then actions[#actions + 1] = "skip" end

    local createdAt = math.max(0, TableUtils.ToInteger(value.createdAt, 0))
    return {
        eventId = eventId,
        eventType = eventType,
        floor = clampInteger(value.floor, 1, 1000000000, 1),
        room = clampInteger(value.room, 1, 10, 1),
        encounterId = encounterId,
        createdAt = createdAt,
        expiresAt = math.max(createdAt, TableUtils.ToInteger(value.expiresAt, createdAt)),
        actions = actions,
        title = type(value.title) == "string" and #value.title >= 1
            and value.title:sub(1, 64) or nil,
        description = type(value.description) == "string" and #value.description >= 1
            and value.description:sub(1, 256) or nil,
        goldCost = LargeNumber.IsLargeNumber(value.goldCost)
            and LargeNumber.Normalize(value.goldCost) or nil,
        fragmentsReward = value.fragmentsReward ~= nil
            and clampInteger(value.fragmentsReward, 0, 1000000000, 0) or nil,
        variant = value.variant ~= nil
            and clampInteger(value.variant, 1, 8, 1) or nil,
    }
end

local function sanitizeDailyVip(value)
    value = type(value) == "table" and value or {}
    return {
        signInDay = math.max(0, TableUtils.ToInteger(value.signInDay, 0)),
        adDay = math.max(0, TableUtils.ToInteger(value.adDay, 0)),
    }
end

local function safePauseReason(value)
    if type(value) ~= "string" or #value > 64 then return nil end
    return value
end

function StateNormalizer.Normalize(rawState, now)
    rawState = type(rawState) == "table" and rawState or {}
    now = math.max(0, TableUtils.ToInteger(now, os.time()))
    local sourceVersion = clampInteger(rawState.schemaVersion, 1, Catalog.SCHEMA_VERSION, 3)
    local normalizedFloor = math.max(1, TableUtils.ToInteger(rawState.floor, 1))
    local normalizedMaxFloor = math.max(normalizedFloor, TableUtils.ToInteger(rawState.maxFloor, normalizedFloor))

    local state = {
        schemaVersion = Catalog.SCHEMA_VERSION,
        revision = math.max(0, TableUtils.ToInteger(rawState.revision, 0)),
        updatedAt = math.max(0, TableUtils.ToInteger(rawState.updatedAt, now)),
        lastActiveAt = math.max(0, TableUtils.ToInteger(rawState.lastActiveAt, now)),
        pendingOfflineSeconds = clampInteger(rawState.pendingOfflineSeconds or rawState.offlineSeconds, 0, Catalog.OFFLINE_MAX_SECONDS, 0),
        level = clampInteger(rawState.level, 1, 1000000, 1),
        vipLevel = clampInteger(rawState.vipLevel, 0, Catalog.MAX_VIP_LEVEL, 0),
        dailyVip = sanitizeDailyVip(rawState.dailyVip),
        trashTalkIndex = clampInteger(rawState.trashTalkIndex, 0, TrashTalk.MAX - 1, 0),
        exp = clampInteger(rawState.exp, 0, 1000000000, 0),
        floor = normalizedFloor,
        maxFloor = normalizedMaxFloor,
        position = sourceVersion < 4 and 0 or clampInteger(rawState.position, 0, 10, 0),
        transitionRemaining = sourceVersion < 4 and 0
            or clampNumber(rawState.transitionRemaining, 0, 60, 0),
        attemptId = clampInteger(rawState.attemptId, 0, Catalog.MAX_VALUE, 0),
        floorDefeats = sourceVersion < 4 and 0 or clampInteger(rawState.floorDefeats, 0, 1000000, 0),
        aidPending = sourceVersion >= 4 and rawState.aidPending == true,
        aidGrantedFloors = sourceVersion < 4 and {} or sanitizeAidFloors(rawState.aidGrantedFloors),
        gold = LargeNumber.Normalize(rawState.gold),
        fragments = LargeNumber.Normalize(rawState.fragments),
        autoRun = rawState.autoRun == true,
        pauseReason = safePauseReason(rawState.pauseReason),
        floorKillBonus = clampNumber(rawState.floorKillBonus, 0, 0.50, 0),
        permanentBonus = clampNumber(rawState.permanentBonus, 0, 1000, 0),
        inventoryPolicy = {
            pauseOnFull = true,
            autoDecompose = false,
            autoSell = false,
            decomposeRarities = {},
            sellRarities = {},
        },
        currentMonster = nil,
        nextItemId = math.max(1, TableUtils.ToInteger(rawState.nextItemId or rawState.itemSequence, 1)),
        inventory = {},
        overflowLoot = {},
        lootStash = {},
        equipped = {},
        consumables = {},
        automationPolicy = sanitizeAutomationPolicy(rawState.automationPolicy),
        interactionMode = rawState.interactionMode == "cinematic" and "cinematic" or "normal",
        rewardPity = sanitizeRewardPity(rawState.rewardPity),
        storyProgress = sanitizeStoryProgress(rawState.storyProgress, sourceVersion, normalizedMaxFloor),
        pendingStoryGate = sourceVersion < 4 and nil or sanitizeStoryGate(rawState.pendingStoryGate),
        pendingEvent = sanitizePendingEvent(rawState.pendingEvent),
        ruleAcknowledgements = sanitizeRuleAcknowledgements(rawState.ruleAcknowledgements),
        equipmentCollection = sanitizeEquipmentCollection(rawState.equipmentCollection), marketListings = GameStateSchema.NormalizeMarketListings(rawState.marketListings),
        pendingEquipDecision = nil,
        previousLoadout = nil,
        appliedGmCommandIds = GameStateSchema.NormalizeAppliedGmCommandIds(rawState.appliedGmCommandIds),
    }

    local rawPolicy = type(rawState.inventoryPolicy) == "table" and rawState.inventoryPolicy or {}
    local legacyMode = rawPolicy.mode == "decompose" and "decompose" or (rawPolicy.mode == "sell" and "sell" or nil)
    local legacyRarities = type(rawPolicy.rarities) == "table" and rawPolicy.rarities or {}
    state.inventoryPolicy.pauseOnFull = rawPolicy.pauseOnFull ~= false and legacyMode == nil
    state.inventoryPolicy.autoDecompose = rawPolicy.autoDecompose == true or legacyMode == "decompose"
    state.inventoryPolicy.autoSell = (rawPolicy.autoSell == true or legacyMode == "sell")
        and not state.inventoryPolicy.autoDecompose
    local rawDecompose = type(rawPolicy.decomposeRarities) == "table" and rawPolicy.decomposeRarities or (legacyMode == "decompose" and legacyRarities or {})
    local rawSell = type(rawPolicy.sellRarities) == "table" and rawPolicy.sellRarities or (legacyMode == "sell" and legacyRarities or {})
    for _, rarityId in ipairs(Catalog.RARITY_ORDER) do
        local legacyId = rarityId == "advanced" and "blue"
            or (rarityId == "rare" and "purple" or (rarityId == "myth" and "mythic" or nil))
        state.inventoryPolicy.decomposeRarities[rarityId] = rarityId ~= "myth"
            and (rawDecompose[rarityId] == true or (legacyId and rawDecompose[legacyId] == true) or false)
        state.inventoryPolicy.sellRarities[rarityId] = rarityId ~= "myth"
            and (rawSell[rarityId] == true or (legacyId and rawSell[legacyId] == true) or false)
    end

    local rawMonster = sourceVersion >= 4 and type(rawState.currentMonster) == "table" and rawState.currentMonster or nil
    if rawMonster then
        local eventType = rawMonster.eventType
        local maxHpBig = normalizeMagnitude(rawMonster.maxHpBig, rawMonster.maxHp, 1)
        if BigNumber.IsZero(maxHpBig) then maxHpBig = BigNumber.FromNumber(1) end
        local hpBig = BigNumber.Min(
            normalizeMagnitude(rawMonster.hpBig, rawMonster.hp, maxHpBig), maxHpBig)
        local atkBig = normalizeMagnitude(rawMonster.atkBig, rawMonster.atk, 0)
        local defBig = normalizeMagnitude(rawMonster.defBig, rawMonster.def, 0)
        local phase = rawMonster.phase == "recovery" and "recovery" or "windup"
        local sequenceIndex = clampInteger(rawMonster.sequenceIndex, 1, CombatSequence.Count(), 1)
        local sequence = CombatSequence.Get(sequenceIndex)
        local hitIndex = clampInteger(rawMonster.hitIndex, 0, #sequence.hitFrames, 0)
        local hitFrame = clampInteger(rawMonster.hitFrame, 1, sequence.frameCount, sequence.hitFrames[math.max(1, hitIndex)] or sequence.hitFrames[1])
        local endFrame = clampInteger(rawMonster.endFrame, hitFrame, sequence.frameCount, sequence.endFrame)
        if eventType == "monster" or eventType == "elite" or eventType == "boss" then
            local room = clampInteger(rawMonster.room, 1, 10, math.max(1, state.position))
            local encounter = rawMonster.encounter == "chapter_boss" and "chapterBoss" or rawMonster.encounter
            if encounter ~= "normal" and encounter ~= "elite" and encounter ~= "boss" and encounter ~= "chapterBoss" then
                encounter = eventType == "monster" and "normal"
                    or (eventType == "elite" and "elite"
                    or ((rawMonster.isChapterBoss == true or (room == 10 and state.floor % 10 == 0)) and "chapterBoss" or "boss"))
            end
            state.currentMonster = {
                id = type(rawMonster.id) == "string" and rawMonster.id or string.format("floor:%d:position:%d", state.floor, state.position),
                eventType = eventType,
                name = type(rawMonster.name) == "string" and rawMonster.name or "回廊怪物",
                hp = projectMagnitude(hpBig),
                maxHp = projectMagnitude(maxHpBig),
                atk = projectMagnitude(atkBig),
                def = projectMagnitude(defBig),
                hpBig = hpBig,
                maxHpBig = maxHpBig,
                atkBig = atkBig,
                defBig = defBig,
                phase = phase,
                phaseRemaining = clampNumber(rawMonster.phaseRemaining, 0, 60, 0),
                attackSerial = clampInteger(rawMonster.attackSerial, 1, 1000000000, 1),
                sequenceIndex = sequenceIndex,
                sequenceId = sequence.id,
                fps = sequence.fps,
                hitFrame = hitFrame,
                endFrame = endFrame,
                recoverySeconds = clampNumber(rawMonster.recoverySeconds, 0, 60, CombatSequence.MIN_PHASE_SECONDS),
                lastSequenceIndex = clampInteger(rawMonster.lastSequenceIndex, 0, CombatSequence.Count(), sequenceIndex),
                room = room,
                encounter = encounter,
                hitIndex = hitIndex,
                elapsedSeconds = clampNumber(rawMonster.elapsedSeconds, 0, 3600, 0),
                enraged = rawMonster.enraged == true,
                nextMonsterAttackSeconds = clampNumber(rawMonster.nextMonsterAttackSeconds, 0, 60, Catalog.ENEMY_ATTACK_SECONDS),
                isChapterBoss = encounter == "chapterBoss",
            }
        end
    end

    local levelUps = 0
    local maxLevelUpsPerNormalize = 10000
    while levelUps < maxLevelUpsPerNormalize do
        local requiredExp = Catalog.NextExp(state.level)
        if not TableUtils.IsFiniteNumber(requiredExp) or requiredExp <= 0 then
            print("[ProfileDiag] invalid nextExp during normalization level=" .. tostring(state.level)
                .. " exp=" .. tostring(state.exp))
            state.exp = 0
            break
        end
        if state.exp < requiredExp then break end
        state.exp = state.exp - requiredExp
        state.level = math.min(1000000, state.level + 1)
        levelUps = levelUps + 1
        if state.level >= 1000000 then
            state.exp = 0
            break
        end
    end
    if levelUps >= maxLevelUpsPerNormalize then
        local requiredExp = Catalog.NextExp(state.level)
        state.exp = TableUtils.IsFiniteNumber(requiredExp) and requiredExp > 0
            and math.min(state.exp, math.max(0, requiredExp - 1)) or 0
        print("[ProfileDiag] capped excessive level normalization level=" .. tostring(state.level)
            .. " exp=" .. tostring(state.exp))
    end
    state.nextExp = Catalog.NextExp(state.level)
    state.maxFloor = math.max(state.maxFloor, state.floor)

    local rawConsumables = type(rawState.consumables) == "table" and rawState.consumables or {}
    state.consumables.healthPotion = math.max(0, TableUtils.ToInteger(rawConsumables.healthPotion, 0))

    local usedIds = {}
    local legacyIdMap = {}
    local legacyObjectMap = {}
    local materialFallback = { fragments = 0 }
    local droppedOverflowCount = 0

    local function appendEquipment(rawItem, preferredTarget, isInventorySource)
        local itemId
        itemId, state.nextItemId = normalizeItemId(rawItem.id, usedIds, state.nextItemId)
        local item = sanitizeEquipment(rawItem, itemId, sourceVersion)
        if not item then return end
        usedIds[itemId] = true

        local target = preferredTarget
        if target == state.inventory and #state.inventory >= Catalog.INVENTORY_CAP then
            target = state.overflowLoot
        end
        if target == state.overflowLoot and #state.overflowLoot >= GameStateSchema.TEMPORARY_LOOT_CAP then
            droppedOverflowCount = droppedOverflowCount + 1
            return
        end
        target[#target + 1] = item
        if isInventorySource and target == state.inventory then
            legacyObjectMap[rawItem] = itemId
            if rawItem.id ~= nil then legacyIdMap[tostring(rawItem.id)] = itemId end
        end
    end

    for _, rawItem in ipairs(type(rawState.inventory) == "table" and rawState.inventory or {}) do
        if type(rawItem) == "table" and (rawItem.equipmentId or Catalog.SLOT_BY_ID[rawItem.slot]) then
            appendEquipment(rawItem, state.inventory, true)
        elseif type(rawItem) == "table" and rawItem.category == "consumable" then
            state.consumables.healthPotion = state.consumables.healthPotion
                + math.max(0, TableUtils.ToInteger(rawItem.quantity, 0))
        elseif type(rawItem) == "table" and rawItem.category == "material" then
            local kind = materialKind(rawItem)
            if kind then
                materialFallback[kind] = materialFallback[kind]
                    + math.max(0, TableUtils.ToInteger(rawItem.quantity, 0))
            end
        end
    end
    for _, rawItem in ipairs(type(rawState.overflowLoot) == "table" and rawState.overflowLoot or {}) do
        if type(rawItem) == "table" and (rawItem.equipmentId or Catalog.SLOT_BY_ID[rawItem.slot]) then
            appendEquipment(rawItem, state.overflowLoot, false)
        end
    end

    if rawState.fragments == nil then
        state.fragments = LargeNumber.FromNumber(materialFallback.fragments)
    end

    local byId = {}
    for _, item in ipairs(state.inventory) do
        byId[item.id] = item
    end
    for _, rawItemId in ipairs(type(rawState.lootStash) == "table" and rawState.lootStash or {}) do
        local itemId = byId[rawItemId] and rawItemId or legacyIdMap[tostring(rawItemId)]
        if itemId and #state.lootStash < GameStateSchema.LOOT_STASH_CAP then
            state.lootStash[#state.lootStash + 1] = itemId
        end
    end

    local rawEquipped = type(rawState.equipped) == "table" and rawState.equipped
        or (type(rawState.equipment) == "table" and rawState.equipment or {})
    local equippedIds = {}
    for _, slot in ipairs(Catalog.SLOTS) do
        local rawValue = rawEquipped[slot.id]
        local itemId = nil
        local cameFromLegacyObject = type(rawValue) == "table"
        if cameFromLegacyObject then
            itemId = legacyObjectMap[rawValue]
                or (rawValue.id ~= nil and legacyIdMap[tostring(rawValue.id)] or nil)
        elseif rawValue ~= nil then
            itemId = byId[rawValue] and rawValue or legacyIdMap[tostring(rawValue)]
        end

        local item = itemId and byId[itemId] or nil
        if item and item.slot == slot.id and not equippedIds[item.id] then
            state.equipped[slot.id] = item.id
            equippedIds[item.id] = true
        end
    end

    local rawPendingEquip = type(rawState.pendingEquipDecision) == "table" and rawState.pendingEquipDecision or nil
    if rawPendingEquip and byId[rawPendingEquip.itemId] then
        local powerDeltaBig = normalizeMagnitude(
            rawPendingEquip.displayedPowerDeltaBig,
            rawPendingEquip.displayedPowerDelta,
            BigNumber.Zero())
        state.pendingEquipDecision = {
            itemId = rawPendingEquip.itemId,
            createdAt = math.max(0, TableUtils.ToInteger(rawPendingEquip.createdAt, now)),
            oldTowerScore = clampNumber(rawPendingEquip.oldTowerScore, 0, 1e300, nil),
            newTowerScore = clampNumber(rawPendingEquip.newTowerScore, 0, 1e300, nil),
            oldBossScore = clampNumber(rawPendingEquip.oldBossScore, 0, 1e300, nil),
            newBossScore = clampNumber(rawPendingEquip.newBossScore, 0, 1e300, nil),
            displayedPowerDelta = projectMagnitude(powerDeltaBig),
            displayedPowerDeltaBig = powerDeltaBig,
            headroomDelta = clampNumber(rawPendingEquip.headroomDelta, -1000000000, 1000000000, nil),
        }
    end

    local rawPrevious = type(rawState.previousLoadout) == "table" and rawState.previousLoadout or nil
    if rawPrevious then
        local backupEquipped = {}
        local backupIds = {}
        local rawBackupEquipped = type(rawPrevious.equipped) == "table" and rawPrevious.equipped or {}
        for _, slot in ipairs(Catalog.SLOTS) do
            local itemId = rawBackupEquipped[slot.id]
            local item = itemId and byId[itemId] or nil
            if item and item.slot == slot.id and not backupIds[itemId] then
                backupEquipped[slot.id] = itemId
                backupIds[itemId] = true
            end
        end
        state.previousLoadout = {
            equipped = backupEquipped,
            createdAt = math.max(0, TableUtils.ToInteger(rawPrevious.createdAt, now)),
            available = rawPrevious.available == true,
        }
    end

    for _, item in ipairs(state.inventory) do
        if item.aidLocked and item.aidFloor and state.floor > item.aidFloor then item.aidLocked = false end
    end
    if state.aidPending then
        for _, floor in ipairs(state.aidGrantedFloors) do
            if floor == state.floor then state.aidPending = false break end
        end
    end

    local autoPolicyEnabled = false
    if state.inventoryPolicy.autoDecompose or state.inventoryPolicy.autoSell then
        for _, rarityId in ipairs(Catalog.RARITY_ORDER) do
            if state.inventoryPolicy.decomposeRarities[rarityId] or state.inventoryPolicy.sellRarities[rarityId] then
                autoPolicyEnabled = true
                break
            end
        end
    end
    if #state.overflowLoot > 0
        or droppedOverflowCount > 0
        or (#state.inventory >= Catalog.INVENTORY_CAP and state.inventoryPolicy.pauseOnFull and not autoPolicyEnabled)
    then
        state.autoRun = false
        state.pauseReason = "inventory_full"
    elseif state.pauseReason == "inventory_full" and state.autoRun then
        state.pauseReason = nil
    end
    for _, item in ipairs(state.inventory) do
        item.power = Catalog.GetItemPower(item)
    end
    for _, item in ipairs(state.overflowLoot) do item.power = Catalog.GetItemPower(item) end
    for _, item in ipairs(state.inventory) do
        local powerBig = BigNumber.Normalize(item.power)
        local record = state.equipmentCollection[item.equipmentId]
        if not record or BigNumber.Compare(powerBig, record.powerBig) > 0 then
            state.equipmentCollection[item.equipmentId] = {
                powerBig = powerBig,
                level = item.level,
                enhance = item.enhance,
                star = item.star,
                rarity = item.rarity,
            }
        end
    end
    for _, item in ipairs(state.overflowLoot) do
        local powerBig = BigNumber.Normalize(item.power)
        local record = state.equipmentCollection[item.equipmentId]
        if not record or BigNumber.Compare(powerBig, record.powerBig) > 0 then
            state.equipmentCollection[item.equipmentId] = {
                powerBig = powerBig,
                level = item.level,
                enhance = item.enhance,
                star = item.star,
                rarity = item.rarity,
            }
        end
    end
    local rawStats = type(rawState.stats) == "table" and rawState.stats or nil
    local rawStatsValid = false
    if sourceVersion >= 5 and rawStats then
        rawStatsValid = GameStateSchema.ValidateStats(rawStats, "$state.stats")
    end
    if rawStatsValid and not BigNumber.IsZero(rawStats.hpBig) then
        state.stats = TableUtils.DeepCopy(rawStats)
        state.stats.setProgress = Catalog.GetSetProgress(state)
    else
        state.stats = Catalog.CalculateStats(state)
    end
    local maximumHp = state.stats.hpBig or BigNumber.FromNumber(state.stats.hp)
    local rawHp = sourceVersion < 4
        and maximumHp
        or normalizeMagnitude(rawState.hpBig, rawState.hp, maximumHp)
    state.hpBig = BigNumber.Min(rawHp, maximumHp)
    state.hp = projectMagnitude(state.hpBig)
    state.currentEvent = state.currentMonster
        and state.currentMonster.eventType
        or Catalog.GetCellType(math.max(1, state.position), state.floor)
    return state
end

function StateNormalizer.ToPersisted(state)
    local normalized = StateNormalizer.Normalize(state, state.updatedAt)
    return GameStateSchema.ToPersistedState(normalized)
end

return StateNormalizer
