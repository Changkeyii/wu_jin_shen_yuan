local currentDialog, opened
local function widget(props)
    local w = { props = props or {}, children = props and props.children or {} }
    function w:SetStyle(style) for key, value in pairs(style) do self.props[key] = value end end
    function w:SetText(value) self.props.text = value end
    return w
end
package.loaded["urhox-libs/UI"] = { Panel = widget }
package.loaded["client.Theme"] = { Colors = {} }
package.loaded["client.ViewAssets"] = { ASSETS = { ui = {} }, LAYOUT = { TOP_ZONE_HEIGHT = 288 } }
package.loaded["client.ViewKit"] = {
    Txt = function(text, _, _, props) props.text = text; return widget(props) end,
    FormatInt = tostring,
}
package.loaded["client.MailController"] = { OnHomeTitleClick = function() end }
package.loaded["client.CommonPromptDialog"] = { Show = function(options) currentDialog = options; return true end }
package.loaded["client.AdGiftController"] = { Open = function() opened = true end }
local game = { floor = 9, level = 3, gold = 100, fragments = 20, wishPool = { tickets = 8 } }
package.loaded["client.GameStateAdapter"] = { GetViewState = function() return game end }
local Top = require("client.TopBarView")
local Tips = require("client.ResourceTips")
local refs = {}
local bar = Top.Build(game, refs)
local hits = {}
for _, child in ipairs(bar.children) do
    local kind = (child.props.id or ""):match("^resourceTip_(.+)$")
    if kind then hits[kind] = child end
end
for _, kind in ipairs({ "floor", "level", "gold", "fragments" }) do
    local hit = assert(hits[kind])
    assert(hit.props.clickable and hit.props.width == 210 and hit.props.height == 42)
    assert(hit.children[1].props.pointerEvents == "none")
    hit.props.onClick()
    assert(currentDialog.queueKey == "resource_tip" and #currentDialog.lines == 2)
    assert(currentDialog.message:find(tostring(game[kind]), 1, true))
end
game = { floor = 12, level = 7, gold = 991, fragments = 500, wishPool = { tickets = 10 } }
Top.Update(game, refs)
hits.gold.props.onClick()
assert(currentDialog.message == "持有：991", "cached bar reads latest values")
Tips.Show("wish_ticket")
assert(currentDialog.message == "持有：10")
assert(currentDialog.lines[2]:find("1、2、3、4", 1, true) and currentDialog.lines[2]:find("10层", 1, true))
assert(not opened and game.wishPool.tickets == 10, "opening tips must not consume tickets or start ads")
currentDialog.onConfirm()
assert(opened)
print("resource_tips: PASS (hit regions, current values, acquisition details, explicit navigation)")
