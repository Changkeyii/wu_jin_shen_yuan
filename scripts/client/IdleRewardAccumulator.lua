local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")

local IdleRewardAccumulator = {}

local function ToBigAmount(value)
    if LargeNumber.IsLargeNumber(value) then
        return LargeNumber.ToBigNumber(value)
    end
    return value or 0
end

function IdleRewardAccumulator.New()
    return {
        gold = BigNumber.Zero(),
        exp = BigNumber.Zero(),
        fragments = BigNumber.Zero(),
        equipmentItems = {},
        equipmentCount = 0,
        equipmentById = {},
        battles = 0,
        abyssRuns = 0,
    }
end

function IdleRewardAccumulator.HasValue(summary)
    return type(summary) == "table" and (
        not BigNumber.IsZero(summary.gold)
        or not BigNumber.IsZero(summary.exp)
        or not BigNumber.IsZero(summary.fragments)
        or #(summary.equipmentItems or {}) > 0
    )
end

function IdleRewardAccumulator.IsRewardEvent(kind)
    return kind == "battle_reward"
        or kind == "equipment_drop"
        or kind == "equipment_granted"
        or kind == "chest_reward"
        or kind == "merchant_trade"
        or kind == "wish_pool"
        or kind == "abyss_echo"
        or kind == "abyss_completed"
        or kind == "equipment_auto_disposed"
end

function IdleRewardAccumulator.Accumulate(summary, events, options)
    options = options or {}
    for _, value in ipairs(events or {}) do
        local kind = value.kind or value.type
        if kind == "battle_reward" then
            summary.gold = BigNumber.Add(summary.gold, value.gold or 0)
            summary.exp = BigNumber.Add(summary.exp, value.exp or 0)
            summary.battles = summary.battles + 1
        elseif kind == "chest_reward" then
            summary.gold = BigNumber.Add(summary.gold, value.gold or 0)
            summary.fragments = BigNumber.Add(summary.fragments, value.fragments or 0)
        elseif kind == "merchant_trade" or kind == "abyss_echo" then
            summary.fragments = BigNumber.Add(summary.fragments, value.fragments or 0)
        elseif kind == "abyss_completed" then
            summary.fragments = BigNumber.Add(summary.fragments, value.fragments or 0)
            summary.abyssRuns = (summary.abyssRuns or 0) + 1
        elseif kind == "wish_pool" then
            summary.gold = BigNumber.Add(summary.gold, value.gold or 0)
        elseif kind == "equipment_auto_disposed" then
            summary.gold = BigNumber.Add(
                summary.gold,
                ToBigAmount(value.gold)
            )
            summary.fragments = BigNumber.Add(
                summary.fragments,
                ToBigAmount(value.fragments)
            )
        elseif kind == "equipment_drop" or kind == "equipment_granted" then
            local itemId = tostring(value.itemId or value.equipmentId or "")
            if itemId ~= "" and not summary.equipmentById[itemId] then
                summary.equipmentCount = (summary.equipmentCount or 0) + 1
                if #summary.equipmentItems >= 100 then goto next_event end
                summary.equipmentById[itemId] = true
                local item = options.getItemById and options.getItemById(value.itemId) or nil
                item = item or value
                summary.equipmentItems[#summary.equipmentItems + 1] = {
                    itemId = itemId,
                    icon = options.itemImage and options.itemImage(item) or value.icon,
                    name = value.name or item.name or "装备",
                    rarity = value.rarity or item.rarity or "common",
                    item = { name = item.name, rarity = item.rarity, level = item.level, slot = item.slot },
                }
            end
        end
        ::next_event::
    end
    return summary
end

function IdleRewardAccumulator.Merge(target, source)
    target.gold = BigNumber.Add(target.gold, source.gold)
    target.exp = BigNumber.Add(target.exp, source.exp)
    target.fragments = BigNumber.Add(target.fragments, source.fragments)
    target.battles = (target.battles or 0) + (source.battles or 0)
    target.abyssRuns = (target.abyssRuns or 0) + (source.abyssRuns or 0)
    target.equipmentCount = (target.equipmentCount or 0) + (source.equipmentCount or #(source.equipmentItems or {}))
    for _, value in ipairs(source.equipmentItems or {}) do
        if #target.equipmentItems >= 100 then break end
        local itemId = tostring(value.itemId or "")
        if itemId == "" or not target.equipmentById[itemId] then
            if itemId ~= "" then target.equipmentById[itemId] = true end
            target.equipmentItems[#target.equipmentItems + 1] = value
        end
    end
    return target
end

return IdleRewardAccumulator
