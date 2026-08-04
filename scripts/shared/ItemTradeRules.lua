local ItemTradeRules = {}

ItemTradeRules.DROP_TRADEABLE_CHANCE = 0.025

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

function ItemTradeRules.RollDropTradeable(source, roll)
    if not ItemTradeRules.IsEligibleDropSource(source) then return false end
    roll = tonumber(roll)
    if roll == nil or roll ~= roll or roll == math.huge or roll == -math.huge then
        return false
    end
    return roll >= 0 and roll < ItemTradeRules.DROP_TRADEABLE_CHANCE
end

function ItemTradeRules.IsTradeable(item)
    return type(item) == "table" and item.tradeable == true
end

return ItemTradeRules
