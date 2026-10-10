-- Avoid invalidating Yoga layout when the caller repeats unchanged presentation values.
local M = {}
local function equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k,v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
function M.Style(widget, style)
    if not widget then return end
    local props = widget.props or {}
    local changed
    for k,v in pairs(style) do
        if not equal(props[k], v) then
            changed = changed or {}
            changed[k] = v
        end
    end
    if changed then widget:SetStyle(changed) end
end
function M.Text(widget, text)
    if widget and (not widget.props or widget.props.text ~= text) then widget:SetText(text) end
end
return M
