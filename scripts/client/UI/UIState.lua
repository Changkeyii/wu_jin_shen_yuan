local UIState = {}

local pages_ = {}

local function PageState(pageId)
    local state = pages_[pageId]
    if state then return state end
    state = {}
    pages_[pageId] = state
    return state
end

function UIState.GetPage(pageId)
    return PageState(tostring(pageId or "default"))
end

function UIState.ResetPage(pageId)
    pages_[tostring(pageId or "default")] = {}
end

function UIState.Reset()
    pages_ = {}
end

return UIState
