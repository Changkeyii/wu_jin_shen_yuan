local UIManager = {}

local pages_ = {}
local activePageId_ = nil
local container_ = nil

local function DestroyPage(page)
    if page.root and page.root.parent then page.root:Remove() end
    if page.instance and page.instance.Destroy then
        page.instance:Destroy()
    elseif page.root and page.root.Destroy then
        page.root:Destroy()
    end
    page.root = nil
    page.instance = nil
end

function UIManager.AttachContainer(container, invalidate)
    container_ = container
    for _, page in pairs(pages_) do
        if invalidate then
            DestroyPage(page)
        elseif page.root and page.root.parent then
            page.root:Remove()
        end
    end
    if activePageId_ then
        local page = pages_[activePageId_]
        if page and page.root then container_:AddChild(page.root) end
    end
end

function UIManager.Register(pageId, factory, options)
    options = options or {}
    pages_[pageId] = {
        factory = assert(factory, "UIManager page factory is required"),
        cache = options.cache ~= false,
        root = nil,
        instance = nil,
    }
end

local function EnsurePage(pageId, state)
    local page = pages_[pageId]
    if not page then return nil end
    if page.instance and page.root then return page end
    local instance = page.factory(state)
    local root = instance
    if type(instance) == "table" and instance.GetRoot then root = instance:GetRoot() end
    assert(root, "UIManager page factory must return a widget or page instance")
    page.instance = instance
    page.root = root
    return page
end

function UIManager.Show(pageId, state)
    local old = activePageId_ and pages_[activePageId_] or nil
    if old and activePageId_ ~= pageId and old.instance then
        if old.instance.OnHide then old.instance:OnHide() end
        if old.root and old.root.parent then old.root:Remove() end
        if not old.cache then DestroyPage(old) end
    end
    activePageId_ = pageId
    local page = EnsurePage(pageId, state)
    if not page then return nil end
    if container_ and page.root.parent ~= container_ then container_:AddChild(page.root) end
    if page.instance.OnShow then page.instance:OnShow(state) end
    return page.root
end

function UIManager.Rebuild(pageId, state)
    local page = pages_[pageId]
    if not page then return nil end
    DestroyPage(page)
    return UIManager.Show(pageId, state)
end

function UIManager.Update(dt)
    local page = activePageId_ and pages_[activePageId_] or nil
    if page and page.instance and page.instance.Update then page.instance:Update(dt) end
end

function UIManager.Reset()
    for _, page in pairs(pages_) do DestroyPage(page) end
    pages_ = {}
    activePageId_ = nil
    container_ = nil
end

return UIManager
