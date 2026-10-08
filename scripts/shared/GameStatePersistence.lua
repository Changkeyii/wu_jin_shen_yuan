local RarityCatalog = require("shared.RarityCatalog")
local WishPoolDefinitions = require("shared.WishPoolDefinitions")
local AbyssDefinitions = require("shared.AbyssDefinitions")
local RewardClaimDefinitions = require("shared.RewardClaimDefinitions")
local ChallengeDefinitions = require("shared.ChallengeDefinitions")
local CampaignDefinitions = require("shared.CampaignDefinitions")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")
local Contracts = require("shared.GameStateContracts")
local Policy = require("shared.GameStatePolicy")
local TableUtils = require("shared.TableUtils")

local Persistence = {}
local GameStateSchema = {
    VERSION = Contracts.VERSION,
    MAX_LOGS = Policy.MAX_LOGS,
    MAX_APPLIED_GM_COMMANDS = Policy.MAX_APPLIED_GM_COMMANDS,
    MAX_GM_COMMAND_ID_LENGTH = Policy.MAX_GM_COMMAND_ID_LENGTH,
}
local PERSISTED_FIELDS = Contracts.PERSISTED_FIELDS
local deepCopy = TableUtils.DeepCopy
local copyArray = TableUtils.CopyArray

local function currentTime(now)
    if type(now) == "number" then return math.max(0, math.floor(now)) end
    if type(os.time) == "function" then return math.max(0, math.floor(os.time())) end
    return 0
end

local function normalizeCurrencyValue(value)
    if LargeNumber.IsLargeNumber(value) then
        return LargeNumber.Normalize(value)
    end
    if type(value) == "string" then
        return LargeNumber.FromString(value) or LargeNumber.Zero()
    end
    return LargeNumber.FromNumber(value)
end

--- 挂单镜像归一化。丢弃结构不完整的条目，保证 schema 校验不会因历史脏数据失败。
local function normalizeMarketListings(value)
    if type(value) ~= "table" then return {} end
    local listings = {}
    for _, entry in ipairs(value) do
        if type(entry) == "table" then
            local price = normalizeCurrencyValue(entry.price)
            local itemId = entry.itemId
            if not LargeNumber.IsZero(price)
                and type(itemId) == "string" and #itemId > 0
            then
                listings[#listings + 1] = {
                    itemId = itemId,
                    price = price,
                    standardValue = normalizeCurrencyValue(entry.standardValue),
                    minimumPrice = normalizeCurrencyValue(entry.minimumPrice),
                    minimumPriceVersion = math.max(1, math.floor(
                        tonumber(entry.minimumPriceVersion) or 1
                    )),
                    tradeableChanceUnits = math.max(0, math.min(10000,
                        math.floor(tonumber(entry.tradeableChanceUnits) or 0)
                    )),
                    feeRate = math.max(0, math.min(1, tonumber(entry.feeRate) or 0)),
                    feeUnits = math.max(0, math.min(1000,
                        math.floor(tonumber(entry.feeUnits)
                            or ((tonumber(entry.feeRate) or 0) * 1000 + 0.5)))),
                    rarity = type(entry.rarity) == "string" and entry.rarity or "epic",
                    slot = type(entry.slot) == "string" and entry.slot or "weapon",
                    level = math.max(1, math.floor(tonumber(entry.level) or 1)),
                    name = type(entry.name) == "string" and entry.name or nil,
                    listedAt = math.max(0, math.floor(tonumber(entry.listedAt) or 0)),
                    expiresAt = math.max(0, math.floor(tonumber(entry.expiresAt) or 0)),
                }
            end
        end
    end
    return listings
end

local function normalizeAppliedGmCommandIds(value)
    local reversed = {}
    local seen = {}
    if type(value) == "table" then
        for index = #value, 1, -1 do
            local commandId = value[index]
            if type(commandId) == "string"
                and #commandId >= 1
                and #commandId <= GameStateSchema.MAX_GM_COMMAND_ID_LENGTH
                and string.match(commandId, "^[%w%._:%-]+$") ~= nil
                and not seen[commandId]
            then
                seen[commandId] = true
                reversed[#reversed + 1] = commandId
                if #reversed >= GameStateSchema.MAX_APPLIED_GM_COMMANDS then break end
            end
        end
    end
    local normalized = {}
    for index = #reversed, 1, -1 do
        normalized[#normalized + 1] = reversed[index]
    end
    return normalized
end


---@param now number|nil
---@return table
function Persistence.NewInitialState(now)
    now = currentTime(now)
    return {
        schemaVersion = GameStateSchema.VERSION,
        revision = 0,
        updatedAt = now,
        lastActiveAt = now,
        pendingOfflineSeconds = 0,
        level = 1,
        vipLevel = 0,
        dailyVip = { signInDay = 0, adDay = 0 },
        trashTalkIndex = 0,
        exp = 0,
        floor = 1,
        maxFloor = 1,
        position = 0,
        transitionRemaining = 0,
        attemptId = 0,
        floorDefeats = 0,
        aidPending = false,
        aidGrantedFloors = {},
        gold = LargeNumber.Zero(),
        fragments = LargeNumber.Zero(),
        autoRun = false,
        nextItemId = 1,
        inventory = {},
        overflowLoot = {},
        lootStash = {},
        equipped = {},
        consumables = { healthPotion = 0 },
        hp = 1,
        hpBig = BigNumber.FromNumber(1),
        floorKillBonus = 0,
        permanentBonus = 0,
        inventoryPolicy = {
            pauseOnFull = true,
            autoDecompose = false,
            autoSell = false,
            decomposeRarities = { common = false, advanced = false, rare = false, artifact = false, legendary = false, epic = false, myth = false },
            sellRarities = { common = false, advanced = false, rare = false, artifact = false, legendary = false, epic = false, myth = false },
        },
        automationPolicy = { autoEquip = false, lootAutoEquip = false, autoSkipStory = false },
        interactionMode = "normal",
        rewardPity = { epicMisses = 0, mythMisses = 0 },
        wishPool = {
            tickets = WishPoolDefinitions.STARTER_TICKETS,
            jars = {},
            adDayKey = 0,
            adUsed = 0,
            totalWishes = 0,
            mythPity = 0,
            mythGuarantees = 0,
            characterPity = 0,
            ownedCharacters = { ember_blade = true },
            characterMarks = {},
        },
        abyss = AbyssDefinitions.NewState(),
        rewardClaims = RewardClaimDefinitions.NewState(),
        challenges = ChallengeDefinitions.NewState(),
        campaign = CampaignDefinitions.NewState(),
        seasonRewardWeekKey = 0,
        seasonTitle = "",
        seasonFrame = "",
        quests = {
            newbie = { claimed = {} },
            daily = { dayKey = 0, progress = {}, claimed = {} },
            achievement = { claimed = {} },
            questStats = {},
        },
        activities = {},
        storyProgress = { introCompleted = false, highestCompletedChapter = 0, contentVersion = 1 },
        pendingStoryGate = nil,
        pendingEvent = nil,
        ruleAcknowledgements = {},
        equipmentCollection = {}, marketListings = {},
        pendingEquipDecision = nil,
        previousLoadout = nil,
        appliedGmCommandIds = {},
        currentMonster = nil,
        logs = {},
        currentEvent = "monster",
        recentDamage = "",
        mails = {},
        mailCache = {},
        mailSeq = 1,
    }
end

---@param state table
---@return table
function Persistence.ToPersistedState(state)
    ---@type table<string, any>
    local persisted = {}
    for _, fieldName in ipairs(PERSISTED_FIELDS) do
        local value = state[fieldName]
        if fieldName == "inventory" or fieldName == "overflowLoot" then
            local items = {}
            for _, item in ipairs(value or {}) do
                items[#items + 1] = {
                    id = item.id,
                    equipmentId = item.equipmentId,
                    level = item.level,
                    enhance = item.enhance,
                    star = item.star,
                    locked = item.locked == true,
                    acquiredAt = item.acquiredAt or 0,
                    source = item.source or "legacy",
                    tradeable = item.tradeable == true,
                    statVersion = item.statVersion or 5,
                    budget = item.budget,
                    budgetBig = deepCopy(item.budgetBig),
                    rarity = RarityCatalog.NormalizeId(item.rarity),
                    setEnabled = item.setEnabled ~= false,
                    setId = item.setId,
                    roll = item.roll or 1,
                    atk = item.atk,
                    def = item.def,
                    hp = item.hp,
                    atkBig = deepCopy(item.atkBig),
                    defBig = deepCopy(item.defBig),
                    hpBig = deepCopy(item.hpBig),
                    crit = item.crit,
                    critDmg = item.critDmg,
                    atkSpeed = item.atkSpeed,
                    lifeSteal = item.lifeSteal,
                    damageReduction = item.damageReduction,
                    bossDamage = item.bossDamage,
                    coreAffixes = copyArray(item.coreAffixes),
                    uniqueEffect = item.uniqueEffect,
                    aidLocked = item.aidLocked == true,
                    aidFloor = item.aidFloor,
                    investedGold = LargeNumber.IsLargeNumber(item.investedGold)
                        and LargeNumber.Normalize(item.investedGold)
                        or LargeNumber.FromNumber(item.investedGold),
                    investedFragments = item.investedFragments or 0,
                }
            end
            persisted[fieldName] = items
        elseif value ~= nil then
            persisted[fieldName] = deepCopy(value)
        end
    end
    if persisted.nextItemId == nil and state.itemSequence ~= nil then
        local legacySequence = tonumber(state.itemSequence)
        if legacySequence ~= nil then
            persisted.nextItemId = math.max(1, math.floor(legacySequence) + 1)
        end
    end
    for _, item in ipairs(persisted.inventory or {}) do
        item.power = nil
    end
    for _, item in ipairs(persisted.overflowLoot or {}) do item.power = nil end
    return persisted
end

---@param rawState table|nil
---@param now number|nil
---@return table
function Persistence.NormalizeState(rawState, now)
    local normalized = Persistence.NewInitialState(now)
    if type(rawState) ~= "table" then
        return normalized
    end

    for _, fieldName in ipairs(PERSISTED_FIELDS) do
        if rawState[fieldName] ~= nil then
            normalized[fieldName] = deepCopy(rawState[fieldName])
        end
    end
    local sourceVersion = tonumber(rawState.schemaVersion) or 3
    normalized.schemaVersion = GameStateSchema.VERSION
    normalized.vipLevel = math.max(0, math.min(10, math.floor(tonumber(normalized.vipLevel) or 0)))
    normalized.dailyVip = type(normalized.dailyVip) == "table" and normalized.dailyVip or {}
    normalized.dailyVip.signInDay = math.max(0,
        math.floor(tonumber(normalized.dailyVip.signInDay) or 0))
    normalized.dailyVip.adDay = math.max(0,
        math.floor(tonumber(normalized.dailyVip.adDay) or 0))
    if sourceVersion < 4 then
        normalized.position = 0
        normalized.currentMonster = nil
        normalized.floorDefeats = 0
        normalized.aidPending = false
        normalized.storyProgress = {
            introCompleted = true,
            highestCompletedChapter = math.max(0, math.floor((math.max(1, normalized.maxFloor or 1) - 1) / 10)),
            contentVersion = 1,
        }
        local policy = type(rawState.inventoryPolicy) == "table" and rawState.inventoryPolicy or {}
        local oldDecompose = type(policy.decomposeRarities) == "table" and policy.decomposeRarities or {}
        local oldSell = type(policy.sellRarities) == "table" and policy.sellRarities or {}
        normalized.inventoryPolicy.decomposeRarities.advanced = oldDecompose.advanced == true or oldDecompose.blue == true
        normalized.inventoryPolicy.decomposeRarities.rare = oldDecompose.rare == true or oldDecompose.purple == true
        normalized.inventoryPolicy.sellRarities.advanced = oldSell.advanced == true or oldSell.blue == true
        normalized.inventoryPolicy.sellRarities.rare = oldSell.rare == true or oldSell.purple == true
    end
    if sourceVersion < 5 then
        normalized.hpBig = BigNumber.FromNumber(normalized.hp)
        for _, item in ipairs(normalized.inventory or {}) do
            item.statVersion = 5
            item.budgetBig = BigNumber.FromNumber(item.budget)
            item.atkBig = BigNumber.FromNumber(item.atk)
            item.defBig = BigNumber.FromNumber(item.def)
            item.hpBig = BigNumber.FromNumber(item.hp)
        end
        for _, item in ipairs(normalized.overflowLoot or {}) do
            item.statVersion = 5
            item.budgetBig = BigNumber.FromNumber(item.budget)
            item.atkBig = BigNumber.FromNumber(item.atk)
            item.defBig = BigNumber.FromNumber(item.def)
            item.hpBig = BigNumber.FromNumber(item.hp)
        end
        if type(normalized.currentMonster) == "table" then
            local monster = normalized.currentMonster
            monster.hpBig = BigNumber.FromNumber(monster.hp)
            monster.maxHpBig = BigNumber.FromNumber(monster.maxHp)
            monster.atkBig = BigNumber.FromNumber(monster.atk)
            monster.defBig = BigNumber.FromNumber(monster.def)
        end
        if type(normalized.pendingEquipDecision) == "table" then
            local decision = normalized.pendingEquipDecision
            decision.displayedPowerDeltaBig = BigNumber.FromNumber(
                math.max(0, tonumber(decision.displayedPowerDelta) or 0))
        end
    end
    if BigNumber.IsBigNumber(normalized.hpBig) then
        normalized.hp = BigNumber.ToNumber(normalized.hpBig)
    end
    normalized.marketListings = normalizeMarketListings(normalized.marketListings)
    normalized.appliedGmCommandIds = normalizeAppliedGmCommandIds(normalized.appliedGmCommandIds)
    if rawState.nextItemId == nil and rawState.itemSequence ~= nil then
        local legacySequence = tonumber(rawState.itemSequence)
        if legacySequence ~= nil then
            normalized.nextItemId = math.max(1, math.floor(legacySequence) + 1)
        end
    end
    normalized.logs = deepCopy(type(rawState.logs) == "table" and rawState.logs or {})
    normalized.currentEvent = rawState.currentEvent or normalized.currentEvent
    normalized.recentDamage = rawState.recentDamage or normalized.recentDamage
    normalized.stats = deepCopy(rawState.stats)
    normalized.nextExp = rawState.nextExp
    while #normalized.logs > GameStateSchema.MAX_LOGS do
        table.remove(normalized.logs)
    end
    return normalized
end


Persistence.NormalizeMarketListings = normalizeMarketListings
Persistence.NormalizeAppliedGmCommandIds = normalizeAppliedGmCommandIds

return Persistence
