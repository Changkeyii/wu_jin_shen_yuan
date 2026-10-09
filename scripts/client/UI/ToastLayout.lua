local UI = require("urhox-libs/UI")
local UILayout = require("client.UI.UILayout")

local ToastLayout = {}

function ToastLayout.Install()
    local toast = UI.Toast.GetGlobal()
    if toast._safeLayoutInstalled then return end
    toast._safeLayoutInstalled = true
    -- SDK Toast.Render 使用固定的 20px 屏幕边距，不读取安全区或 Show 的 position。
    -- 在项目层复用单条渲染入口调整坐标，原组件仍负责队列、动画、关闭和命中框。
    local renderToast = toast.RenderToast
    toast.RenderToast = function(self, nvg, item, x, y, width, height, radius, alpha)
        local inset = UILayout.OverlayInsets()
        local position = self.props.position or "top-right"
        if position:find("bottom") then
            y = y - (inset.bottom - 20)
        else
            y = y + (inset.top - 20)
        end
        local screenWidth = UI.GetWidth()
        width = math.min(width, math.max(1, screenWidth - inset.left - inset.right))
        x = math.max(inset.left, math.min(x, screenWidth - inset.right - width))
        return renderToast(self, nvg, item, x, y, width, height, radius, alpha)
    end
end

return ToastLayout
