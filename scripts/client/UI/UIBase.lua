local UI = require("urhox-libs/UI")

---@class UIBase : Widget
---@overload fun(props?: WidgetProps): UIBase
---@field props WidgetProps
---@field new fun(self, props?: WidgetProps): UIBase
local UIBase = UI.Widget:Extend("UIBase")

---@param props WidgetProps?
function UIBase:Init(props)
    UI.Widget.Init(self, props or {})
    self.visible_ = false
    self.mounted_ = false
end

function UIBase:OnShow(_)
    self.visible_ = true
end

function UIBase:OnHide()
    self.visible_ = false
end

function UIBase:Refresh(_)
    return false
end

function UIBase:IsVisible()
    return self.visible_ == true
end

function UIBase:Mount(parent)
    if self.mounted_ then return end
    parent:AddChild(self)
    self.mounted_ = true
end

function UIBase:Unmount()
    if not self.mounted_ then return end
    self:Remove()
    self.mounted_ = false
end

function UIBase:Destroy()
    self:OnHide()
    self.mounted_ = false
    UI.Widget.Destroy(self)
end

return UIBase
