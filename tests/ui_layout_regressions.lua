-- Code-level UI contracts; no engine preview or gameplay automation.
local function Widget(props)
    local w = { props = props or {}, children = {}, id = props and props.id }
    function w:AddChild(c) self.children[#self.children + 1] = c; c.parent = self end
    function w:RemoveChild(c)
        for i, child in ipairs(self.children) do if child == c then table.remove(self.children, i); c.parent = nil; break end end
    end
    function w:ClearChildren() for _, c in ipairs(self.children) do c.parent = nil end; self.children = {} end
    function w:Destroy() if self.parent then self.parent:RemoveChild(self) end; self.destroyed = true end
    function w:Hide() self.props.visible = false end
    function w:Show() self.props.visible = true end
    function w:SetText(t) self.props.text = t end
    function w:SetStyle(p) for k, v in pairs(p) do self.props[k] = v end end
    for _, c in ipairs(w.props.children or {}) do w:AddChild(c) end
    return w
end
local function Find(w, key, value)
    if w.props[key] == value then return w end
    for _, c in ipairs(w.children) do local found = Find(c, key, value); if found then return found end end
end
local safe, scale, screenHeight = { top = 36, left = 0, right = 0, bottom = 24 }, 0.5, 1920
local toast = { props = { position = "top-right" }, RenderToast = function(_, _, item, x, y, width, height)
    item.layout = { x = x, y = y, width = width, height = height }
end }
local UI = {
    Panel = Widget, Label = Widget, ScrollView = Widget, SafeAreaView = Widget, VirtualList = Widget,
    GetSafeAreaInsets = function() return safe end,
    GetScale = function() return scale end,
    GetWidth = function() return 1080 end,
    GetHeight = function() return screenHeight end,
    Toast = { GetGlobal = function() return toast end, Show = function() end },
}
package.loaded["urhox-libs/UI"] = UI
package.loaded["urhox-libs/Video"] = { VideoPlayer = Widget }
local colors = setmetatable({}, { __index = function() return { 255, 255, 255, 255 } end })
package.loaded["client.Theme"] = { Colors = colors, CONFIG = { DesignH = 1920 } }
package.loaded["client.ViewAssets"] = {
    ASSETS = { ui = { bg = "background", panelLarge = "panel", panelCompact = "compact" } },
    LAYOUT = { TOP_ZONE_HEIGHT = 310, BOTTOM_ZONE_HEIGHT = 170 },
}
local function Text(text, _, _, props) props = props or {}; props.text = text; return Widget(props) end
package.loaded["client.ViewKit"] = { Txt = Text, CompactTxt = Text, MultiTxt = Text, ActionButton = Widget,
    BackButton = function(p) p.text = "返回"; p.position = "absolute"; p.left = 0; p.width = 84; return Widget(p) end }
package.loaded["client.ItemSlotBase"] = { Icon = function(_, _, props) return Widget(props) end }
local state = { campaign = { highestUnlockedChapter = 1, completedStages = {} } }
package.loaded["client.GameStateAdapter"] = { GetViewState = function() return state end }
package.loaded["client.NavigationController"] = { SwitchPage = function() end }
local pending, calls = nil, 0
package.loaded["client.ServerClient"] = { CampaignPlayStage = function(id, mode, callback)
    calls = calls + 1; pending = { id = id, mode = mode, callback = callback }
end }
_G.graphics = { height = 960 }
_G.sdk = { GetNativeExitMenuRect = function() return { bottom = 0.05 } end }
local Layout = require("client.UI.UILayout")
assert(Layout.OverlayInsets().top == 96, "same capsule bottom as GameView, with no extra margin")
local ToastLayout = require("client.UI.ToastLayout")
ToastLayout.Install(); ToastLayout.Install()
local item = {}
toast:RenderToast(nil, item, 740, 20, 320, 56, 8, 1)
assert(item.layout.y == 96 and item.layout.x + 320 <= 1040)
toast:RenderToast(nil, item, 740, 86, 320, 56, 8, 1)
assert(item.layout.y == 162, "stack spacing must survive the offset")
sdk = nil; safe.top = 0
toast:RenderToast(nil, item, 740, 20, 320, 56, 8, 1)
assert(item.layout.y == 0, "no extra top spacing on a screen without insets")
safe.top = 110
assert(Layout.OverlayInsets().top == 110)
toast.props.position = "bottom"
toast:RenderToast(nil, item, 380, 1844, 320, 56, 8, 1)
assert(item.layout.y + 56 == 1920 - 64)

local Codex = require("client.EquipmentCodexView")
local codex = Codex.Build({ game = {}, C = colors, compactTxt = Text, txt = Text, rarityColor = function() return colors.text end })
local grid = assert(Find(codex, "id", "codexGrid")).props
assert(grid.position == "absolute" and grid.overflow == "hidden")
assert(grid.top >= 216 + 62 + 20 and grid.bottom >= 24)
for _, height in ipairs({ 720, 1080, 1440, 1800 }) do
    assert(height - grid.top - grid.bottom > 0, "viewport must stay within the page below filters")
end
assert(1080 - grid.left - grid.right >= 465 * 2 + 16)

package.loaded["client.LoadingController"] = {
    PrefetchMedia = function() end,
    CancelPrefetch = function() end,
    EnsureMediaReady = function(_, _, callback) callback() end,
    EnsurePlayAssetsReady = function(callback) callback() end,
}
local Campaign = require("client.CampaignView")
local root = Widget({})
Campaign.AttachRoot(root)
local page = Campaign.BuildPage()
local list = assert(Find(page:GetRoot(), "id", "campaignChapters"))
assert(list.props.flexBasis == 0 and list.props.overflow == "hidden")
local chapter = list.children[1].children[1]
local used = chapter.props.padding * 2 + chapter.props.gap * (#chapter.children - 1)
for _, child in ipairs(chapter.children) do used = used + child.props.height end
assert(used <= chapter.props.height, "chapter cards/summary must fit their parent")
Find(page:GetRoot(), "text", "推荐关卡").props.onClick()
local frame = assert(Find(root, "id", "campaignDetailFrame"))
assert(frame.props.flexBasis == 0 and frame.props.height == nil, "safe-area spacer must not add to a 100% child")
assert(Find(frame, "id", "campaignDetailBody").props.overflow == "hidden")
assert(Find(frame, "text", "每日回响"), "uncompleted stages must retain the echo action")
-- Complete the opening stage and refresh only chapter content, retaining the scroll object.
state.campaign.completedStages["main:c01:a"] = { bestStars = 3 }
page:Update()
assert(Find(page:GetRoot(), "id", "campaignChapters") == list)
Find(frame, "text", "返回章节").props.onClick()
assert(#root.children == 0)
Find(page:GetRoot(), "text", "推荐关卡").props.onClick()
assert(Find(root, "text", "开始挑战"), "continue should move to the newly unlocked battle")
local echo = Find(root, "text", "每日回响")
echo.props.onClick(); echo.props.onClick()
assert(calls == 1, "pending reward must not issue duplicate requests")
Find(root, "text", "返回章节").props.onClick()
pending.callback({ ok = true })
assert(#root.children == 0, "late response must not reopen a closed detail")

local back, settle, destroyed
package.loaded['client.CampaignBattleView'] = { Create = function(stage, onBack, onSettled)
    back, settle = onBack, onSettled
    return { root = Widget({}), Destroy = function() destroyed = true end }
end }
-- A first-clear response must leave the current detail instance available for
-- the reward confirmation; confirming closes both detail and battle layers.
state.campaign.completedStages = {}
page:Update()
Find(page:GetRoot(), "text", "推荐关卡").props.onClick()
Find(root, "text", "开始挑战").props.onClick()
Find(root, "text", "跳过").parent.props.onClick()
local returnFromReward = assert(Campaign.GetRewardReturnHandler('main:c01:a'))
state.campaign.completedStages['main:c01:a'] = { bestStars = 3 }
settle({ won = true })
assert(Campaign.GetRewardReturnHandler('main:c01:a'), 'response must not replace reward-bound detail')
returnFromReward()
assert(#root.children == 0 and Find(page:GetRoot(), 'id', 'campaignChapters') == list)

-- An old queued reward cannot close a new detail, even for the same stage.
Find(page:GetRoot(), 'text', '推荐关卡').props.onClick()
local stale = assert(Campaign.GetRewardReturnHandler('main:c01:b'))
Find(root, 'text', '返回章节').props.onClick()
Find(page:GetRoot(), 'text', '推荐关卡').props.onClick()
stale()
assert(Find(root, 'id', 'campaignDetailFrame'))
Find(root, 'text', '开始挑战').props.onClick()
local confirmBattle = assert(Campaign.GetRewardReturnHandler('main:c01:b'))
settle({ won = true })
assert(#root.children == 2, 'first-clear battle waits for reward confirmation')
confirmBattle()
assert(destroyed and #root.children == 0)

-- Previously rewarded victories return without a blank reward dialog.
state.campaign.completedStages['main:c01:b'] = { bestStars = 3 }
-- Open the completed battle through its chapter card.
page:Update()
Find(page:GetRoot(), 'text', '门厅试炼').parent.props.onClick()
Find(root, 'text', '再次挑战').props.onClick()
settle({ won = true })
assert(#root.children == 0)
Find(page:GetRoot(), 'text', '门厅试炼').parent.props.onClick()
Find(root, 'text', '再次挑战').props.onClick()
settle({ won = false })
assert(#root.children == 2, 'defeat must not be treated as a rewarded victory')
back()
assert(#root.children == 0, 'manual retreat returns directly to chapter list')

Find(page:GetRoot(), 'text', '第一声回应').parent.props.onClick()
Find(root, 'text', '再次挑战').props.onClick()
Find(root, 'text', '跳过').parent.props.onClick()
settle({ won = true })
assert(#root.children == 0, 'story replay returns without waiting for a nonexistent reward')
print("ui_layout_regressions: PASS")
