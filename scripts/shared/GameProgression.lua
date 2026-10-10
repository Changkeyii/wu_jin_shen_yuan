local LargeNumber = require("shared.LargeNumber")
local Balance = require("shared.GameBalance")
local BigNumber = require("shared.BigNumber")
local Progression = {}
Progression.VERSION = 2
Progression.MAX_LEVEL = 100
Progression.EQUIPMENT_STEP = 5
Progression.FINAL_FLOOR = 150
Progression.MASTERY_EXP_PER_FRAGMENT = 500
Progression.MASTERY_DAILY_FRAGMENTS = 300

local function integer(value, fallback, maximum)
    value = tonumber(value)
    if not value or value ~= value or math.abs(value) == math.huge then return fallback or 0 end
    return math.max(0, math.min(maximum or 1000000000, math.floor(value)))
end

function Progression.Level(value)
    return math.max(1, math.min(Progression.MAX_LEVEL, integer(value, 1)))
end

function Progression.EquipmentLevel(value)
    return math.max(5, math.floor(Progression.Level(value) / 5) * 5)
end

function Progression.NextExp(level)
    if Progression.Level(level) >= Progression.MAX_LEVEL then return 0 end
    return Balance.NextExp(level)
end

function Progression.NewGrowth()
    return { version = Progression.VERSION, legacyLevel = 0, legacyCoreFloor = 0,
        legacyExp = 0, masteryExp = 0, masteryDayKey = 0, masteryFragments = 0, trainingFraction = 0 }
end

function Progression.NormalizeGrowth(value)
    value = type(value) == "table" and value or {}
    return { version = Progression.VERSION, legacyLevel = integer(value.legacyLevel, 0, 1000000),
        legacyCoreFloor = integer(value.legacyCoreFloor, 0, 1000000), legacyExp = integer(value.legacyExp, 0),
        masteryExp = integer((tonumber(value.version) or 1) < 2
            and (tonumber(value.masteryExp) or 0) * Progression.MASTERY_EXP_PER_FRAGMENT / 1000000
            or value.masteryExp, 0, Progression.MASTERY_EXP_PER_FRAGMENT - 1),
        trainingFraction = math.max(0, math.min(0.999999999, tonumber(value.trainingFraction) or 0)),
        masteryDayKey = integer(value.masteryDayKey, 0),
        masteryFragments = integer(value.masteryFragments, 0, Progression.MASTERY_DAILY_FRAGMENTS) }
end

-- Keep historical achievements and freeze historical core power before applying the new cap.
function Progression.NormalizeState(state, now, migrate, balanceMigrate)
    if balanceMigrate and (tonumber(state.level) or 1) < 100 then
        local oldRequired = math.floor(100 * 1.15 ^ (Progression.Level(state.level) - 1))
        state.exp = math.floor(math.min(0.999999, (tonumber(state.exp) or 0) / oldRequired) * Progression.NextExp(state.level))
    end
    state.growth = Progression.NormalizeGrowth(state.growth)
    if migrate then
        state.growth.legacyLevel = math.max(state.growth.legacyLevel, integer(state.level, 1, 1000000))
        state.growth.legacyCoreFloor = math.max(state.growth.legacyCoreFloor, integer(state.maxFloor or state.floor, 1, 1000000))
        if integer(state.level, 1) >= Progression.MAX_LEVEL then
            state.growth.legacyExp = math.max(state.growth.legacyExp, integer(state.exp, 0))
        end
    end
    state.level = Progression.Level(state.level)
    Progression.AddExperience(state, 0, now)
end

function Progression.AddExperience(state, amount, now)
    state.growth = state.growth or Progression.NewGrowth()
    state.level = Progression.Level(state.level)
    local previous = state.level
    local remaining = integer(state.exp, 0) + integer(amount, 0, 1000000000000)
    while state.level < Progression.MAX_LEVEL do
        local required = Progression.NextExp(state.level)
        if remaining < required then break end
        remaining = remaining - required
        state.level = state.level + 1
    end
    local fragments = 0
    if state.level >= Progression.MAX_LEVEL then
        local growth = state.growth
        local day = math.floor((integer(now, 0, 9007199254740991) + 28800) / 86400)
        if day > growth.masteryDayKey then growth.masteryDayKey, growth.masteryFragments = day, 0 end
        local total = growth.masteryExp + remaining
        fragments = math.min(math.floor(total / Progression.MASTERY_EXP_PER_FRAGMENT),
            math.max(0, Progression.MASTERY_DAILY_FRAGMENTS - growth.masteryFragments))
        growth.masteryFragments = growth.masteryFragments + fragments
        growth.masteryExp = total % Progression.MASTERY_EXP_PER_FRAGMENT
        if fragments > 0 then
            state.fragments = LargeNumber.Add(LargeNumber.Normalize(state.fragments), LargeNumber.FromNumber(fragments))
        end
        remaining = 0
    end
    state.exp, state.nextExp = remaining, Progression.NextExp(state.level)
    return state.level - previous, fragments
end

-- Return integer XP while preserving sub-point progress across commits and reconnects.
function Progression.TrainingExp(state, seconds, offline)
    state.growth = state.growth or Progression.NewGrowth()
    seconds = math.max(0, tonumber(seconds) or 0)
    local level, exp = Progression.Level(state.level), (tonumber(state.exp) or 0) + (state.growth.trainingFraction or 0)
    local earned = 0
    while seconds > 0.000001 do
        local reference = math.min(99, level)
        local rate = Balance.NextExp(reference) / Balance.LevelSeconds(reference)
        if level >= 100 then
            earned = earned + seconds * rate * (offline and 0.2 or 1)
            break
        end
        local needed = Progression.NextExp(level) - exp
        local used = math.min(seconds, math.max(0, needed) / rate)
        local gained = used * rate
        earned, exp, seconds = earned + gained, exp + gained, seconds - used
        if exp + 0.0000001 >= Progression.NextExp(level) then
            exp, level = 0, level + 1
        else break end
    end
    local total = earned + (state.growth.trainingFraction or 0)
    local whole = math.floor(total + 0.00000001)
    state.growth.trainingFraction = math.max(0, total - whole)
    return whole
end

function Progression.CoreGrowth(state)
    local current = Balance.EquipmentGrowth(Progression.Level(state.level))
    local historical = tonumber((state.growth or {}).legacyCoreFloor) or 0
    local old = BigNumber.FromLog10(math.max(0, historical - 1) / 50 * math.log(2) / math.log(10))
    return BigNumber.Max(current, old)
end

function Progression.CoreLevel(state)
    return math.max(Progression.Level(state.level), integer((state.growth or {}).legacyCoreFloor, 0, 1000000))
end

function Progression.RequiredEquipmentLevel(item)
    -- Historical equipment remains usable; the first tier is available from level 1.
    if item and item.legacyLevel then return 1 end
    local level = Progression.EquipmentLevel(item and item.level)
    return level == 5 and 1 or level
end

function Progression.CanEquip(state, item)
    return Progression.Level(state.level) >= Progression.RequiredEquipmentLevel(item)
end

function Progression.BuildGoal(state)
    local Equipment = require("shared.EquipmentCatalog")
    local Rarity = require("shared.RarityCatalog")
    local slots = { "weapon", "shoulder", "coat", "pants", "belt", "shoes",
        "bracelet", "necklace", "ring", "support", "magicstone", "earring" }
    local sets = {}
    for _, id in ipairs({ "nightmare", "lucky", "voyage", "abyss", "prophecy" }) do
        sets[id] = { id = id, slots = {}, count = 0, myth = false }
    end
    for _, item in ipairs(state.inventory or {}) do
        local definition = Equipment.Get(item.equipmentId)
        local id = item.setId or (definition and definition.setId)
        local set = id and sets[id]
        if set and (tonumber(item.level) or 0) >= Progression.MAX_LEVEL
            and item.setEnabled ~= false and Rarity.Rank(item.rarity) >= Rarity.Rank("epic") then
            if not set.slots[item.slot] then set.slots[item.slot], set.count = true, set.count + 1 end
            if item.rarity == "myth" then set.myth = true end
        end
    end
    local best = sets.nightmare
    for _, id in ipairs({ "lucky", "voyage", "abyss", "prophecy" }) do
        if sets[id].count > best.count or (sets[id].count == best.count and sets[id].myth and not best.myth) then best = sets[id] end
    end
    local missing = {}
    for _, slot in ipairs(slots) do if not best.slots[slot] then missing[#missing + 1] = slot end end
    local level = Progression.Level(state.level)
    local passed = (tonumber(state.maxFloor) or 1) > Progression.FINAL_FLOOR
    local stage, label, progress = "challenge", "通关第150层终局挑战", tostring(math.min(150, math.max(0, (state.maxFloor or 1) - 1))) .. "/150层"
    if level < Progression.MAX_LEVEL then
        stage, label = "level", "达到" .. math.min(100, (math.floor(level / 20) + 1) * 20) .. "级"
        progress = "Lv." .. level .. "/100"
    elseif best.count < 12 then stage, label, progress = "set", "集齐100级毕业套装", best.count .. "/12件"
    elseif not best.myth then stage, label, progress = "myth", "获得毕业套装的神话装备", "神话0/1"
    elseif passed then stage, label, progress = "complete", "毕业目标已完成", "继续冲层与完善词条" end
    return { stage = stage, label = label, progress = progress, setId = best.id,
        setCount = best.count, hasMyth = best.myth, missingSlots = missing, challengePassed = passed }
end

return Progression
