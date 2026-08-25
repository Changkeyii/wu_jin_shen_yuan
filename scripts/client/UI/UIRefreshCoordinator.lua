local UIRefreshCoordinator = {}

local pending_ = {
    root = false,
    page = false,
    topBar = false,
    navigation = false,
}
local blocked_ = {}

function UIRefreshCoordinator.Request(scope)
    scope = scope or "page"
    if pending_[scope] ~= nil then pending_[scope] = true end
end

function UIRefreshCoordinator.Block(scope, key)
    scope = scope or "page"
    blocked_[scope] = blocked_[scope] or {}
    blocked_[scope][key or "default"] = true
end

function UIRefreshCoordinator.Unblock(scope, key)
    local block = blocked_[scope or "page"]
    if block then block[key or "default"] = nil end
end

function UIRefreshCoordinator.IsBlocked(scope)
    local block = blocked_[scope or "page"]
    return block and next(block) ~= nil or false
end

function UIRefreshCoordinator.Consume()
    local result = {
        root = pending_.root,
        page = pending_.page,
        topBar = pending_.topBar,
        navigation = pending_.navigation,
    }
    pending_.root = false
    pending_.topBar = false
    pending_.navigation = false
    if not UIRefreshCoordinator.IsBlocked("page") then
        pending_.page = false
    else
        result.page = false
    end
    if result.root then
        pending_.page = false
    end
    return result
end

function UIRefreshCoordinator.Reset()
    pending_ = { root = false, page = false, topBar = false, navigation = false }
    blocked_ = {}
end

return UIRefreshCoordinator
