local TableUtils = {}

function TableUtils.DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[TableUtils.DeepCopy(key, seen)] = TableUtils.DeepCopy(item, seen)
    end
    return copy
end

function TableUtils.CopyArray(value)
    local result = {}
    for index, item in ipairs(type(value) == "table" and value or {}) do
        result[index] = item
    end
    return result
end

return TableUtils
