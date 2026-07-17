local TableUtils = {}

function TableUtils.DeepCopy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do
        copy[TableUtils.DeepCopy(key, seen)] = TableUtils.DeepCopy(child, seen)
    end
    return setmetatable(copy, getmetatable(value))
end

function TableUtils.DeepEqual(left, right, seen)
    if left == right then
        return true
    end
    if type(left) ~= type(right) or type(left) ~= "table" then
        return false
    end

    seen = seen or {}
    if seen[left] == right then
        return true
    end
    seen[left] = right

    for key, value in pairs(left) do
        if not TableUtils.DeepEqual(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

function TableUtils.FindById(items, itemId)
    for index, item in ipairs(items or {}) do
        if item.id == itemId then
            return item, index
        end
    end
    return nil, nil
end

function TableUtils.IsFiniteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function TableUtils.ToInteger(value, fallback)
    if not TableUtils.IsFiniteNumber(value) then
        return fallback
    end
    return math.floor(value)
end

return TableUtils
