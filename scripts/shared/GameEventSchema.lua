local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")

local GameEventSchema = {}

GameEventSchema.VERSION = 3
GameEventSchema.MAX_EVENTS = 128

local KNOWN = {
    abyss_echo = true,
    active_touched = true,
    aid_granted = true,
    aid_pending = true,
    altar_heal = true,
    attack_started = true,
    auto_equip = true,
    auto_run_changed = true,
    automation_policy_changed = true,
    battle_hit = true,
    battle_lost = true,
    battle_reward = true,
    battle_started = true,
    battle_won = true,
    boss_enraged = true,
    cell_entered = true,
    chapter_boss_defeated = true,
    chest_reward = true,
    critical_hit = true,
    currency_granted = true,
    currency_drop = true,
    damage_dealt = true,
    encounter_transition = true,
    equip_decision_applied = true,
    equipment_auto_disposed = true,
    equipment_decomposed = true,
    equipment_drop = true,
    equipment_equipped = true,
    equipment_granted = true,
    equipment_lock_changed = true,
    equipment_reverted = true,
    equipment_sold = true,
    equipment_starred = true,
    equipment_strengthened = true,
    equipment_unequipped = true,
    equipment_upgrade_available = true,
    floor_advanced = true,
    floor_completed = true,
    floor_recovery = true,
    player_attack_hit = true,
    player_damaged = true,
    player_healed = true,
    player_died = true,
    player_revived = true,
    floor_reset = true,
    interaction_mode_changed = true,
    inventory_drop_skipped = true,
    inventory_policy_changed = true,
    level_up = true,
    life_steal = true,
    loot_dropped = true,
    loot_settled = true,
    market_cancelled = true,
    market_listed = true,
    market_mail_collected = true,
    market_purchased = true,
    merchant_skipped = true,
    merchant_trade = true,
    monster_spawned = true,
    monster_damaged = true,
    monster_defeated = true,
    inventory_full = true,
    offline_accrued = true,
    offline_collected = true,
    permanent_growth = true,
    power_updated = true,
    progress_adjusted = true,
    reward_pity_updated = true,
    rules_acknowledged = true,
    story_completed = true,
    story_gate = true,
    story_advanced = true,
    story_skipped = true,
    teleport = true,
    temporary_loot_recovered = true,
    tower_aid_claimed = true,
    tower_aid_equipment = true,
    tower_aid_pending = true,
    tower_aid_requested = true,
    vip_level_up = true,
    wish_pool = true,
}

local REQUIRED = {
    equipment_upgrade_available = { "itemId" },
    inventory_policy_changed = { "inventoryPolicy" },
    player_attack_hit = { "hitIndex" },
    player_damaged = {},
    player_healed = { "source" },
    monster_spawned = { "floor", "room", "kind" },
    loot_dropped = { "rarity", "icon" },
    currency_drop = { "currency", "amount", "dropCount" },
    loot_settled = { "itemId", "outcome" },
    story_gate = { "storyId", "chapter", "phase", "lines" },
    story_advanced = { "storyId", "lineIndex", "line" },
    aid_granted = { "floor", "itemCount", "targetMet" },
    equipment_reverted = {},
    rules_acknowledged = { "ruleId" },
}

local REQUIRED_MAGNITUDES = {
    battle_started = {
        { "monsterHp", "monsterHpBig" },
        { "monsterMaxHp", "monsterMaxHpBig" },
    },
    battle_hit = {
        { "amount", "amountBig" },
        { "monsterHp", "monsterHpBig" },
        { "monsterMaxHp", "monsterMaxHpBig" },
    },
    critical_hit = { { "amount", "amountBig" } },
    damage_dealt = {
        { "amount", "amountBig" },
        { "monsterHp", "monsterHpBig" },
        { "monsterMaxHp", "monsterMaxHpBig" },
    },
    equipment_upgrade_available = { { "displayedPowerDelta", "displayedPowerDeltaBig" } },
    life_steal = {
        { "amount", "amountBig" },
        { "playerHp", "playerHpBig" },
        { "playerMaxHp", "playerMaxHpBig" },
    },
    monster_damaged = {
        { "amount", "amountBig" },
        { "monsterHp", "monsterHpBig" },
        { "monsterMaxHp", "monsterMaxHpBig" },
    },
    player_attack_hit = {
        { "amount", "amountBig" },
        { "monsterHp", "monsterHpBig" },
        { "monsterMaxHp", "monsterMaxHpBig" },
    },
    player_damaged = {
        { "amount", "amountBig" },
        { "hp", "hpBig" },
        { "maxHp", "maxHpBig" },
    },
    player_healed = {
        { "amount", "amountBig" },
        { "hp", "hpBig" },
        { "maxHp", "maxHpBig" },
    },
    player_revived = {
        { "playerHp", "playerHpBig" },
        { "playerMaxHp", "playerMaxHpBig" },
    },
    monster_spawned = {
        { "hp", "hpBig" },
        { "maxHp", "maxHpBig" },
    },
    equipment_reverted = { { "displayedPower", "displayedPowerBig" } },
}

local FIELD_RULES = {
    attack_started = {
        hitFrames = {
            kind = "array", minLength = 1, maxLength = 4,
            items = { kind = "integer", minimum = 1 },
        },
        hitWeights = {
            kind = "array", minLength = 1, maxLength = 4,
            items = { kind = "number", minimum = 0 },
        },
    },
    equipment_upgrade_available = {
        itemId = { kind = "string", minLength = 36, maxLength = 36,
            pattern = "^[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+%-[0-9a-fA-F]+$" },
        displayedPowerDelta = { kind = "magnitude" },
        displayedPowerDeltaBig = { kind = "bigNumber" },
    },
    inventory_policy_changed = {
        inventoryPolicy = { kind = "object" },
    },
    currency_drop = {
        currency = { kind = "enum", values = { gold = true, fragments = true, exp = true } },
        amount = { kind = "currencyAmount" },
        dropCount = { kind = "integer", minimum = 1, maximum = 24 },
    },
    loot_settled = {
        itemId = { kind = "string", minLength = 1, maxLength = 64 },
        outcome = { kind = "enum", values = {
            inventory = true, temporary_box = true, temporary_loot = true, auto_disposed = true,
        } },
    },
    story_advanced = {
        storyId = { kind = "string", minLength = 1, maxLength = 128 },
        lineIndex = { kind = "integer", minimum = 1 },
        line = { kind = "string", minLength = 1, maxLength = 512 },
    },
    aid_granted = {
        floor = { kind = "integer", minimum = 1 },
        itemCount = { kind = "integer", minimum = 0 },
        targetMet = { kind = "boolean" },
    },
    equipment_reverted = {
        displayedPower = { kind = "magnitude" },
        displayedPowerBig = { kind = "bigNumber" },
    },
    rules_acknowledged = {
        ruleId = { kind = "string", minLength = 1, maxLength = 96 },
    },
}

local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function currencyAmountMatches(value)
    if type(value) == "number" then
        return finite(value) and value >= 0
    end
    if not LargeNumber.IsLargeNumber(value) then return false end
    local normalized = LargeNumber.Normalize(value)
    return value.high == normalized.high
        and value.mid == normalized.mid
        and value.low == normalized.low
end

local function magnitudeMatches(value, allowNegative)
    if type(value) == "number" then
        return finite(value) and (allowNegative or value >= 0)
    end
    return BigNumber.ValidateCanonical(value)
end

local function fieldMatches(value, rule)
    if rule.kind == "string" then
        return type(value) == "string"
            and #value >= (rule.minLength or 0)
            and #value <= (rule.maxLength or math.huge)
            and (rule.pattern == nil or string.match(value, rule.pattern) ~= nil)
    elseif rule.kind == "integer" then
        return finite(value) and value == math.floor(value) and value >= (rule.minimum or -math.huge)
            and value <= (rule.maximum or math.huge)
    elseif rule.kind == "number" then
        return finite(value) and value >= (rule.minimum or -math.huge)
            and value <= (rule.maximum or math.huge)
    elseif rule.kind == "boolean" then
        return type(value) == "boolean"
    elseif rule.kind == "enum" then
        return rule.values[value] == true
    elseif rule.kind == "magnitude" then
        return magnitudeMatches(value, rule.allowNegative == true)
    elseif rule.kind == "currencyAmount" then
        return currencyAmountMatches(value)
    elseif rule.kind == "bigNumber" then
        return BigNumber.ValidateCanonical(value)
    elseif rule.kind == "object" then
        return type(value) == "table"
    elseif rule.kind == "array" then
        if type(value) ~= "table" then return false end
        local length = #value
        if length < (rule.minLength or 0) or length > (rule.maxLength or math.huge) then return false end
        for index, item in ipairs(value) do
            if rule.items and not fieldMatches(item, rule.items) then return false end
        end
        for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key > length or key ~= math.floor(key) then return false end
        end
        return true
    end
    return false
end

local MAGNITUDE_FIELDS = {
    amount = true,
    damage = true,
    effectiveDamage = true,
    hp = true,
    maxHp = true,
    playerHp = true,
    playerMaxHp = true,
    monsterHp = true,
    monsterMaxHp = true,
    targetHp = true,
    targetMaxHp = true,
    displayedPower = true,
    displayedPowerDelta = true,
    beforePower = true,
    targetPower = true,
}

local SIGNED_MAGNITUDE_FIELDS = { displayedPowerDelta = true }

local function validateMagnitudeFields(value, path, seen, currencyAmountAtRoot)
    if type(value) ~= "table" then return true end
    seen = seen or {}
    if seen[value] then return true end
    seen[value] = true
    for key, child in pairs(value) do
        local childPath = path .. "." .. tostring(key)
        if type(key) == "string" and key:sub(-3) == "Big" then
            local valid, reason = BigNumber.ValidateCanonical(child)
            if not valid then return false, childPath .. " is invalid: " .. tostring(reason) end
        elseif type(key) == "string" and MAGNITUDE_FIELDS[key] then
            local matches = currencyAmountAtRoot and key == "amount"
                and currencyAmountMatches(child)
                or magnitudeMatches(child, SIGNED_MAGNITUDE_FIELDS[key] == true)
            if not matches then
                return false, childPath .. " is invalid"
            end
        elseif type(child) == "table" then
            local valid, reason = validateMagnitudeFields(child, childPath, seen, false)
            if not valid then return false, reason end
        end
    end
    return true
end

function GameEventSchema.IsKnown(eventType) return KNOWN[eventType] == true end

function GameEventSchema.Validate(event, path)
    path = path or "$event"
    if type(event) ~= "table" then return false, path .. " must be a table" end
    if type(event.type) ~= "string" or #event.type < 1 or #event.type > 64 then
        return false, path .. ".type is invalid"
    end
    if not KNOWN[event.type] then return false, path .. ".type is unknown" end
    if event.attemptId ~= nil and (not finite(event.attemptId) or event.attemptId < 0) then
        return false, path .. ".attemptId is invalid"
    end
    for _, field in ipairs(REQUIRED[event.type] or {}) do
        if event[field] == nil then return false, path .. "." .. field .. " is required" end
    end
    for _, alternatives in ipairs(REQUIRED_MAGNITUDES[event.type] or {}) do
        local regularField, bigField = alternatives[1], alternatives[2]
        if event[regularField] == nil and event[bigField] == nil then
            return false, path .. "." .. regularField .. " or " .. bigField .. " is required"
        end
    end
    for field, rule in pairs(FIELD_RULES[event.type] or {}) do
        if event[field] ~= nil and not fieldMatches(event[field], rule) then
            return false, path .. "." .. field .. " is invalid"
        end
    end
    if event.lines ~= nil then
        if type(event.lines) ~= "table" or #event.lines > 32 then return false, path .. ".lines is invalid" end
        for index, line in ipairs(event.lines) do
            if type(line) ~= "string" or #line > 512 then
                return false, string.format("%s.lines[%d] is invalid", path, index)
            end
        end
    end
    local magnitudesOk, magnitudeReason = validateMagnitudeFields(
        event,
        path,
        nil,
        event.type == "currency_drop"
    )
    if not magnitudesOk then return false, magnitudeReason end
    return true
end

function GameEventSchema.ValidateList(events, path)
    path = path or "$events"
    if type(events) ~= "table" or #events > GameEventSchema.MAX_EVENTS then
        return false, path .. " is invalid"
    end
    for index, event in ipairs(events) do
        local ok, reason = GameEventSchema.Validate(event, string.format("%s[%d]", path, index))
        if not ok then return false, reason end
    end
    return true
end

GameEventSchema.KNOWN = KNOWN
return GameEventSchema
