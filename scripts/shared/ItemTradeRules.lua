local ItemTradeRules = {}

--- 可交易资格按最终品质独立判定，使用万分比整数避免小数配置漂移。
ItemTradeRules.TRADEABLE_CHANCE_SCALE = 10000
ItemTradeRules.DROP_TRADEABLE_CHANCE_UNITS = {
    artifact = 3000,
    legendary = 1500,
    epic = 700,
    myth = 250,
}

local ELIGIBLE_DROP_SOURCES = {
    monster_drop = true,
    elite_drop = true,
    boss_drop = true,
    chapter_boss_drop = true,
    chest_drop = true,
}

function ItemTradeRules.IsEligibleDropSource(source)
    return ELIGIBLE_DROP_SOURCES[source] == true
end

---@param rarityId string|nil
---@return integer
function ItemTradeRules.GetTradeableChanceUnits(rarityId)
    return ItemTradeRules.DROP_TRADEABLE_CHANCE_UNITS[rarityId] or 0
end

---@param rarityId string|nil
---@return number
function ItemTradeRules.GetTradeableChance(rarityId)
    return ItemTradeRules.GetTradeableChanceUnits(rarityId)
        / ItemTradeRules.TRADEABLE_CHANCE_SCALE
end

---@param rarityId string|nil
---@return number
function ItemTradeRules.GetScarcityMultiplier(rarityId)
    local units = ItemTradeRules.GetTradeableChanceUnits(rarityId)
    if units <= 0 then return 0 end
    return ItemTradeRules.TRADEABLE_CHANCE_SCALE / units
end

---@param source string|nil
---@param rarityId string|nil
---@param roll number|nil
---@return boolean
function ItemTradeRules.RollDropTradeable(source, rarityId, roll)
    if not ItemTradeRules.IsEligibleDropSource(source) then return false end
    local chanceUnits = ItemTradeRules.GetTradeableChanceUnits(rarityId)
    if chanceUnits <= 0 then return false end
    roll = tonumber(roll)
    if roll == nil or roll ~= roll or roll == math.huge or roll == -math.huge then
        return false
    end
    return roll >= 0
        and roll * ItemTradeRules.TRADEABLE_CHANCE_SCALE < chanceUnits
end

function ItemTradeRules.IsTradeable(item)
    return type(item) == "table" and item.tradeable == true
end

return ItemTradeRules
