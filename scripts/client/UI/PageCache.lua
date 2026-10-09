-- Owns page lifetime, including roots whose presenters only clear Lua references.
local PageCache = {}

function PageCache.Root(entry)
    if type(entry) == "table" and entry.GetRoot then return entry:GetRoot() end
    return entry
end

function PageCache.Destroy(entry)
    local root = PageCache.Root(entry)
    if root and root.parent then root:Remove() end
    if entry ~= root and type(entry) == "table" and entry.Destroy then
        pcall(entry.Destroy, entry)
    end
    -- Widget.Destroy is idempotent, including when the presenter already called it.
    if root and root.Destroy then root:Destroy() end
end

-- Keep the current and most recently visited page, never an unbounded history.
function PageCache.Trim(entries, recency, activeId, onEvict)
    local inactive = {}
    for id in pairs(entries) do
        if id ~= activeId then inactive[#inactive + 1] = id end
    end
    table.sort(inactive, function(a, b) return (recency[a] or 0) > (recency[b] or 0) end)
    for index = 2, #inactive do
        local id = inactive[index]
        if onEvict then onEvict(id) end
        PageCache.Destroy(entries[id])
        entries[id], recency[id] = nil, nil
    end
end

return PageCache
