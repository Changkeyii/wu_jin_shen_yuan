local UIOverlay = {}

UIOverlay.Layer = {
    Loading = 1000,
    NonBlocking = 1800,
    Modal = 2200,
    Blocking = 3300,
    Tooltip = 3500,
    Reward = 3700,
    Tutorial = 4000,
}

local root_ = nil
local generation_ = 0
local entries_ = {}

local function RemoveNode(node)
    if node and node.parent then node.parent:RemoveChild(node) end
end

function UIOverlay.AttachRoot(root)
    root_ = root
    generation_ = generation_ + 1
    for key, entry in pairs(entries_) do
        if entry.recreate then
            entry.node = entry.recreate()
            if entry.node then
                entry.node:SetStyle({ zIndex = entry.zIndex })
                root_:AddChild(entry.node)
            else
                entries_[key] = nil
            end
        else
            entries_[key] = nil
        end
    end
end

function UIOverlay.Add(key, node, options)
    assert(type(key) == "string" and key ~= "", "UIOverlay key is required")
    assert(node, "UIOverlay node is required")
    options = options or {}
    UIOverlay.Remove(key)
    local zIndex = options.zIndex or UIOverlay.Layer[options.layer or "Modal"] or UIOverlay.Layer.Modal
    node:SetStyle({ zIndex = zIndex })
    entries_[key] = { node = node, zIndex = zIndex, recreate = options.recreate }
    if root_ then root_:AddChild(node) end
    return node
end

function UIOverlay.Replace(key, node, options)
    return UIOverlay.Add(key, node, options)
end

function UIOverlay.Remove(key)
    local entry = entries_[key]
    if not entry then return false end
    RemoveNode(entry.node)
    entries_[key] = nil
    return true
end

function UIOverlay.Has(key)
    return entries_[key] ~= nil
end

function UIOverlay.GetRoot()
    return root_
end

function UIOverlay.GetGeneration()
    return generation_
end

function UIOverlay.Reset()
    for key in pairs(entries_) do UIOverlay.Remove(key) end
    root_ = nil
    generation_ = 0
end

return UIOverlay
