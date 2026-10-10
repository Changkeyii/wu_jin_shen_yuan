-- Actual adapter/domain/view integration; replace native rendering and transport only.
local function Widget(p)
    local w = { props = p or {}, children = {}, state = {scrollY = 0, scrollX = 0} }
    function w:AddChild(c) self.children[#self.children + 1] = c; c.parent = self end
    function w:RemoveChild(c) for i,v in ipairs(self.children) do if v == c then table.remove(self.children,i); return end end end
    function w:SetStyle(s) for k,v in pairs(s) do self.props[k] = v end end
    function w:SetText(t) self.props.text = t end
    function w:SetVisible(v) self.props.visible = v end
    function w:SetScrollDirect(x, y) self.state.scrollX, self.state.scrollY = x, y end
    function w:Animate() end
    function w:StopAnimation() end
    function w:Destroy() self.destroyed = true end
    for _, c in ipairs(w.props.children or {}) do w:AddChild(c) end
    return w
end
package.loaded['urhox-libs/UI'] = { Panel = Widget, ScrollView = Widget, Label = Widget,
    Theme = {ExtendTheme = function(_, p) return p end}, Toast = {Show = function() end} }
local function Text(t, _, _, p) p = p or {}; p.text = t; return Widget(p) end
local function Button(t, _, _, _, cb, disabled) return Widget{text = t, onClick = cb, disabled = disabled} end
package.loaded['client.ViewKit'] = {Txt = Text, CompactTxt = Text, MultiTxt = Text,
    ImageButton = Button, FormatInt = tostring, ShortenText = function(t) return t end}
package.loaded['client.TutorialController'] = {IsActive = function() return false end}
package.loaded['client.CommonPromptDialog'] = {}
package.loaded['client.ItemTips'] = {}
package.loaded['client.RewardDialogView'] = {}
package.loaded['client.InventoryFullPrompt'] = {}
package.loaded['client.EquipmentQuickFilter'] = {Matches = function() return true end}
package.loaded['client.EquipmentRecycleFilter'] = {}
package.loaded['client.EquipmentIcon'] = Widget
package.loaded['client.BackpackItemSlot'] = {}
package.loaded['client.EquipmentItemSlot'] = {}
package.loaded['client.ItemSlotBase'] = {Icon = function(_, item, p)
    p = p or {}; p.itemId = item and item.id; return Widget(p)
end}
local lastGrid
package.loaded['client.UI.GridVirtualList'] = {
    Build = function(p) lastGrid = Widget{}; lastGrid.scrollView_ = Widget{}; lastGrid.data = p.data; return lastGrid end,
    UpdateData = function(w, data) w.data = data end,
}
package.loaded['client.InventoryGridView'] = {Build = function() return Widget{} end, UpdateData = function() end}
local now = 1791630000
local Factory = require('server.domain.StateFactory')
local Engine = require('server.domain.GameEngine')
local Adapter = require('client.GameStateAdapter')
local Tables = require('shared.TableUtils')
local state = Factory.Create(now)
state.tutorial.completed = true
state.equipped = {}
require('server.domain.PlayerTransition').RefreshDerived(state)
assert(Adapter.ApplySnapshot(state))
local game = Adapter.GetViewState()
local selected, slot, pageScroll, gridScroll = game.inventory[1].id, 'weapon', 0, 0
local refreshes, snapshots, loseDelta = 0, 0, false
local page
local function Refresh()
    game = Adapter.GetViewState()
    refreshes = refreshes + 1
    if page and not page:Update(game) then page:Destroy(); page = nil end
end
package.loaded['client.ServerClient'] = {
    AutoEquip = function(cb)
        local result = Engine.AutoEquip(state, now)
        assert(result.ok); state = result.state
        if not loseDelta then assert(Adapter.ApplyDelta(result.delta)) end
        cb{ok = true, data = {committed = result.commit.kind ~= 'none'}}
    end,
    RequestSnapshot = function() snapshots = snapshots + 1; assert(Adapter.ApplySnapshot(state)); Refresh() end,
}
local actions = require('client.EquipmentActionController').Configure {
    getGame = function() return game end, inventoryState = {}, requestPageRefresh = Refresh,
    actionResult = function(r) return r and r.ok end,
}
local Theme = require('client.Theme')
local Assets = require('client.ViewAssets').ASSETS
local Item = require('client.ItemView')
local function FindItem(id) for _, v in ipairs(game.inventory) do if v.id == id then return v end end end
local view = {
    C = Theme.Colors, assets = Assets, slots = Theme.Slots, clipboard = {},
    playerNickname = 'tester', characterPortrait = Assets.player.icon,
    rarityColor = Item.RarityColor, rarityName = Item.RarityName, slotName = Item.SlotName,
    itemPowerText = Item.ItemPowerText, itemImage = Item.ItemImage, itemLevelText = Item.ItemLevelText,
    isEquipped = function(v) return Item.IsEquipped(game,v) end,
    shortenText = function(t) return t end, compactTxt = Text, txt = Text, formatInt = tostring, imageButton = Button,
}
local uiState = {
    game = game, getSelectedSlot = function() return slot end, setSelectedSlot = function(v) slot = v end,
    getSelectedInventoryId = function() return selected end, setSelectedInventoryId = function(v) selected = v end,
    getEquipmentScrollY = function() return gridScroll end, setEquipmentScrollY = function(v) gridScroll = v end,
    getEquipmentPageScrollY = function() return pageScroll end, setEquipmentPageScrollY = function(v) pageScroll = v end,
    getItemById = FindItem,
}
local Loadout = require('client.EquipmentLoadoutView')
local function Build() uiState.game = game; page = Loadout.Build{view = view, state = uiState, actions = {}, tips = {}} end
local function Find(w, f)
    if f(w) then return w end
    for _, c in ipairs(w.children) do local found = Find(c, f); if found then return found end end
end
Build()
page:GetRoot().state.scrollY = 240; lastGrid.scrollView_.state.scrollY = 80
local oldPage = page
local expectedSelection = selected
actions.AutoEquipBest()
assert(not page and oldPage:GetRoot().destroyed, 'unchanged selection must invalidate stale equipped slots')
assert(selected == expectedSelection and slot == 'weapon' and pageScroll == 240 and gridScroll == 80)
assert(snapshots == 1)
Build()
assert(page:GetRoot().state.scrollY == 240)
assert(Find(page:GetRoot(), function(w) return w.props.text == '卸' end), 'fresh worn slots render immediately')
assert(Find(page:GetRoot(), function(w) return w.props.text == '战力 ' .. tostring(game.displayedPower or game.stats.power) end))
local retained = page
actions.AutoEquipBest()
assert(page == retained and snapshots == 1, 'no-op equip must not rebuild or add snapshot reads')

-- Same-table changes must be noticed, while unrelated currency updates stay retained.
local changed = Tables.DeepCopy(game)
changed.inventory[#changed.inventory + 1] = {id = 'material', category = 'material'}
changed.gold = 100
assert(page:Update(changed))
changed.equipped.weapon.enhance = (changed.equipped.weapon.enhance or 0) + 1
assert(not page:Update(changed), 'enhance update must refresh slots with unchanged equipment ID')

-- Missing delta is recovered by the command's authoritative snapshot fallback.
state.equipped = {}; require('server.domain.PlayerTransition').RefreshDerived(state)
assert(Adapter.ApplySnapshot(state)); game = Adapter.GetViewState(); Build(); loseDelta = true
actions.AutoEquipBest()
assert(not page and snapshots == 2)
Build(); assert(next(game.equipped))

-- Bag detail also observes the same selected item's worn/locked state.
local ctx = {
    UI = package.loaded['urhox-libs/UI'], C = Theme.Colors, ASSETS = Assets,
    SET_ORDER = Theme.SetOrder, SETS = Theme.Sets, SLOTS = Theme.Slots, CATEGORIES = Theme.Categories,
    game = game, getSelectedCategory = function() return 'all' end,
    getSelectedSlot = uiState.getSelectedSlot, setSelectedSlot = uiState.setSelectedSlot,
    getSelectedInventoryId = uiState.getSelectedInventoryId, setSelectedInventoryId = uiState.setSelectedInventoryId,
    getInventoryTabScrollX = function() return 0 end, setInventoryTabScrollX = function() end,
    getEquipmentScrollY = uiState.getEquipmentScrollY, setEquipmentScrollY = uiState.setEquipmentScrollY,
    getEquipmentPageScrollY = uiState.getEquipmentPageScrollY, setEquipmentPageScrollY = uiState.setEquipmentPageScrollY,
    getItemById = FindItem, rarityColor = Item.RarityColor, rarityName = Item.RarityName,
    slotName = Item.SlotName, itemPower = function() return 1 end, itemPowerText = Item.ItemPowerText,
    itemImage = Item.ItemImage, isEquipped = view.isEquipped,
    compactTxt = Text, txt = Text, imageButton = Button, formatInt = tostring,
}
local bag = require('client.InventoryView').BuildInventoryPage(ctx)
game.inventory[1].locked = not game.inventory[1].locked
assert(not bag:Update(game), 'bag detail must refresh when selected item changes in place')
print('equipment_page_refresh: PASS (auto-equip, no-op, scroll, enhance, lost delta, bag detail)')
