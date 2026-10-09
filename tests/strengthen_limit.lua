local Factory = require("server.domain.StateFactory")
local Equipment = require("server.domain.EquipmentEngine")
local Catalog = require("server.domain.Catalog")
local Transition = require("server.domain.PlayerTransition")
local LargeNumber = require("shared.LargeNumber")

local now = 1791446850
local state = Factory.Create(now)
state.tutorial.completed = true
state.maxFloor = 1
state.gold = LargeNumber.Max()
state.fragments = LargeNumber.FromNumber(1e12)
for level = 0, 5 do
    local item = Transition.FindItem(state, state.equipped.weapon)
    item.enhance = level
    local preview = Equipment.GetStrengthenPreview(state, "weapon").data
    assert(preview.enhanceLimit == Catalog.MAX_ENHANCE and preview.canStrengthen and not preview.atMax)
    local result = Equipment.Strengthen(state, "weapon", now + level)
    assert(result.ok)
    assert(Transition.FindItem(result.state, result.state.equipped.weapon).enhance == level + 1)
    assert(LargeNumber.Compare(result.state.gold, LargeNumber.Subtract(state.gold, preview.gold)) == 0)
    assert(LargeNumber.Compare(result.state.fragments, LargeNumber.Subtract(state.fragments, preview.fragments)) == 0)
    state = result.state
end
-- Last upgrade survives normalization and cannot be purchased past the stored/stat cap.
Transition.FindItem(state, state.equipped.weapon).enhance = Catalog.MAX_ENHANCE - 1
state.gold = LargeNumber.Max()
local last = Equipment.Strengthen(state, "weapon", now + 20)
assert(last.ok)
assert(Transition.FindItem(last.state, last.state.equipped.weapon).enhance == Catalog.MAX_ENHANCE)
for _, floor in ipairs({ 1, 10000 }) do
    last.state.maxFloor = floor
    local preview = Equipment.GetStrengthenPreview(last.state, "weapon").data
    assert(preview.atMax and not preview.canStrengthen and preview.nextEnhance == Catalog.MAX_ENHANCE)
    local denied = Equipment.Strengthen(last.state, "weapon", now + 21)
    assert(not denied.ok and denied.error.code == "ENHANCE_LIMIT")
end
local poor = Factory.Create(now)
poor.tutorial.completed = true
Transition.FindItem(poor, poor.equipped.weapon).enhance = 1
poor.gold, poor.fragments = LargeNumber.Zero(), LargeNumber.Zero()
assert(not Equipment.GetStrengthenPreview(poor, "weapon").data.atMax)
assert(Equipment.Strengthen(poor, "weapon", now).error.code == "INSUFFICIENT_RESOURCES")
print("strengthen_limit: PASS")
