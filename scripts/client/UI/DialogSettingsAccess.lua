local UI = require("urhox-libs/UI")
local M = {}
local openSettings_ --[[@type function?]]
function M.Configure(callback) openSettings_ = callback end

-- The button is owned by the dialog, never the screen root. Its lifetime follows
-- the owner. Gear asset: 96x96, visible rect (18,18,73,60), rendered with contain.
function M.Attach(owner, outside, placement)
    local width = tonumber(owner.props and owner.props.width) or 1080
    local right = outside and -math.min(76, math.max(0, (1080 - width) / 2 - 8)) or 8
    local zIndex = 10
    for _, child in ipairs(owner.children or {}) do
        zIndex = math.max(zIndex, (tonumber(child.props and child.props.zIndex) or 0) + 1)
    end
    local props = {
        id = "recoverySideAccess", position = "absolute", right = right, top = "50%", marginTop = -48,
        width = 72, height = 96, zIndex = zIndex, clickable = true, alignItems = "center",
        onClick = function() if openSettings_ then openSettings_() end end,
        children = {
            UI.Panel { width = 72, height = 72,
                backgroundImage = "image/punk_idle_settings_icon_20260722080342.png",
                backgroundFit = "contain", pointerEvents = "none" },
            UI.Label { text = "设置", fontSize = 20, fontColor = "#FFFFFF", width = 72, height = 24,
                textAlign = "center", textStroke = { width = 2, color = "#000000" }, pointerEvents = "none" },
        },
    }
    if placement then
        for key, value in pairs(placement) do props[key] = value end
        if placement.left ~= nil then props.right = nil end
    end
    local button = UI.Panel(props)
    owner:AddChild(button)
    return button
end

function M.Wrap(frame)
    local stage = UI.Panel { position = "relative", width = frame.props.width, height = frame.props.height,
        pointerEvents = "box-none", overflow = "visible", children = { frame } }
    M.Attach(stage, true)
    return stage
end

-- Several dialogs may coexist, so allow each visible dialog's own control.
function M.AllowInTree(widget, allow)
    if not widget then return end
    if widget.id == "recoverySideAccess" or (widget.props and widget.props.id == "recoverySideAccess") then
        allow(widget)
        return
    end
    for _, child in ipairs(widget.children or {}) do M.AllowInTree(child, allow) end
end
return M
