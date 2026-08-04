local BigNumber = require("shared.BigNumber")
local RarityCatalog = require("shared.RarityCatalog")

local ItemSort = {}

local function numericValue(value, fallback)
    value = tonumber(value)
    if value == nil or value ~= value or value == math.huge or value == -math.huge then
        return fallback or 0
    end
    return value
end

local function itemLevel(item)
    return numericValue(
        item and (item.level or item.dropLevel or item.floor or item.tier),
        1
    )
end

local function itemPower(item)
    if type(item) ~= "table" then return 0 end
    return item.power
        or item.displayedPower
        or item.evaluatedPower
        or item.powerContribution
        or 0
end

local function compareNumberDescending(left, right)
    if left == right then return 0 end
    return left > right and -1 or 1
end

local function compareTextAscending(left, right)
    left = tostring(left or "")
    right = tostring(right or "")
    if left == right then return 0 end
    return left < right and -1 or 1
end

--- 比较两件物品的展示优先级。
--- 返回负数表示 left 应排在 right 前面。
function ItemSort.Compare(left, right)
    left = type(left) == "table" and left or {}
    right = type(right) == "table" and right or {}

    local compared = compareNumberDescending(
        RarityCatalog.Rank(left.rarity),
        RarityCatalog.Rank(right.rarity)
    )
    if compared ~= 0 then return compared end

    compared = compareNumberDescending(itemLevel(left), itemLevel(right))
    if compared ~= 0 then return compared end

    compared = compareNumberDescending(
        numericValue(left.enhance, 0),
        numericValue(right.enhance, 0)
    )
    if compared ~= 0 then return compared end

    compared = compareNumberDescending(
        numericValue(left.star, 0),
        numericValue(right.star, 0)
    )
    if compared ~= 0 then return compared end

    compared = BigNumber.Compare(itemPower(left), itemPower(right))
    if compared ~= 0 then return compared > 0 and -1 or 1 end

    compared = compareNumberDescending(
        numericValue(left.quantity, 1),
        numericValue(right.quantity, 1)
    )
    if compared ~= 0 then return compared end

    compared = compareNumberDescending(
        numericValue(left.acquiredAt, 0),
        numericValue(right.acquiredAt, 0)
    )
    if compared ~= 0 then return compared end

    return compareTextAscending(left.id, right.id)
end

function ItemSort.Less(left, right)
    return ItemSort.Compare(left, right) < 0
end

function ItemSort.Sort(items)
    table.sort(items, ItemSort.Less)
    return items
end

function ItemSort.SortListings(listings)
    table.sort(listings, function(left, right)
        local compared = ItemSort.Compare(left and left.item, right and right.item)
        if compared ~= 0 then return compared < 0 end
        return compareTextAscending(left and left.itemId, right and right.itemId) < 0
    end)
    return listings
end

return ItemSort
