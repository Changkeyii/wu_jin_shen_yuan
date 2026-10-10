local Factory = require("server.domain.StateFactory")
local Tutorial = require("server.domain.TutorialEngine")
local Equipment = require("server.domain.EquipmentEngine")
local Catalog = require("server.domain.Catalog")
local Transition = require("server.domain.PlayerTransition")
local LargeNumber = require("shared.LargeNumber")

local now = 1791446850
local function reachStrengthen()
    local state = Factory.Create(now)
    state.inventory, state.equipped = {}, {}
    state.gold, state.fragments = LargeNumber.Zero(), LargeNumber.Zero()
    Tutorial.OnKill(state, {}, now, function() return 0.5 end)
    assert(state.tutorial.step == 2)
    local weapon, armor
    for _, item in ipairs(state.inventory) do
        if item.slot == "weapon" then weapon = item else armor = item end
    end
    local equip = Equipment.Equip(state, weapon.id, now + 1)
    assert(equip.ok and equip.state.tutorial.step == 3)
    local decompose = Equipment.Decompose(equip.state, 1, now + 2, { armor.id })
    assert(decompose.ok and decompose.state.tutorial.step == 4)
    assert(LargeNumber.Compare(decompose.state.fragments, 5) == 0)
    assert(Catalog.GetStrengthenCost(weapon, 0).fragments == 8,
        "regression fixture must reproduce the 5 vs 8 fragment shortage")
    return decompose.state
end

local function assertFreeStrengthen(state)
    local beforeGold, beforeFragments = state.gold, state.fragments
    for _ = 1, 2 do
        local preview = Equipment.GetStrengthenPreview(state, "weapon")
        assert(preview.ok and preview.data.canStrengthen and preview.data.tutorialFree)
        assert(LargeNumber.IsZero(preview.data.gold) and preview.data.fragments == 0)
    end
    local result = Equipment.Strengthen(state, "weapon", now + 3)
    assert(result.ok and result.state.tutorial.step == 5)
    assert(not result.state.tutorial.completed, "feature tour must remain required")
    local weapon = Transition.FindItem(result.state, result.state.equipped.weapon)
    assert(weapon.enhance == 1)
    assert(LargeNumber.IsZero(weapon.investedGold) and weapon.investedFragments == 0,
        "free upgrade must not mint refundable investment")
    assert(LargeNumber.Compare(result.state.gold, beforeGold) == 0)
    assert(LargeNumber.Compare(result.state.fragments, beforeFragments) == 0)
    assert(state.tutorial.step == 4, "preview/action must not mutate input")
    assert(Transition.FindItem(state, state.equipped.weapon).enhance == 0)
    local progressed = false
    for _, event in ipairs(result.delta.events) do
        if event.kind == "tutorial_step" and event.step == 5 then progressed = true end
    end
    assert(progressed, "client must receive the feature-tour transition")
    local nextPreview = Equipment.GetStrengthenPreview(result.state, "weapon").data
    assert(not nextPreview.tutorialFree and not nextPreview.atMax,
        "subsequent upgrades must use the normal cost, without an early floor cap")
    local again = Equipment.Strengthen(result.state, "weapon", now + 4)
    assert(again.ok == nextPreview.canStrengthen)
    if again.ok then
        assert(LargeNumber.Compare(again.state.gold, LargeNumber.Subtract(result.state.gold, nextPreview.gold)) == 0)
        assert(LargeNumber.Compare(again.state.fragments, LargeNumber.Subtract(result.state.fragments, nextPreview.fragments)) == 0)
    end
    assert(Tutorial.Complete(result.state, {}, now + 5))
    assert(result.state.tutorial.completed)
end

assertFreeStrengthen(reachStrengthen())
-- Already-stuck saves do not re-run OnDecompose; preview and action must repair them directly.
for _, balance in ipairs({ 0, 5, 100 }) do
    local stuck = reachStrengthen()
    stuck.gold, stuck.fragments = LargeNumber.FromNumber(balance), LargeNumber.FromNumber(balance)
    assertFreeStrengthen(stuck)
end

-- Exclude ordinary equipment, other steps, other slots and subsequent upgrades.
local changes = {
    function(s, i) s.tutorial.completed = true end,
    function(s, i) s.tutorial.step = 3 end,
    function(s, i) s.tutorial.step = 5 end,
    function(s, i) i.source = "starter" end,
    function(s, i) i.rarity = "rare" end,
    function(s, i) i.level = 10; s.level = 10 end,
    function(s, i) i.enhance = 1; s.maxFloor = 20 end,
    function(s, i)
        for _, starter in ipairs(Factory.Create(now).inventory) do
            if starter.slot == "shoulder" then i.equipmentId = starter.equipmentId; break end
        end
        s.equipped.weapon = nil
        i.slot = "shoulder"
        s.equipped.shoulder = i.id
    end,
}
for _, change in ipairs(changes) do
    local state = reachStrengthen()
    local item = Transition.FindItem(state, state.equipped.weapon)
    change(state, item)
    state.gold, state.fragments = LargeNumber.Zero(), LargeNumber.Zero()
    local preview = Equipment.GetStrengthenPreview(state, item.slot)
    assert(preview.ok and not preview.data.tutorialFree and not preview.data.canStrengthen)
    assert(not Equipment.Strengthen(state, item.slot, now + 3).ok)
end

local normal = reachStrengthen()
normal.tutorial.completed = true
normal.gold, normal.fragments = LargeNumber.FromNumber(10000), LargeNumber.FromNumber(100)
local preview = Equipment.GetStrengthenPreview(normal, "weapon").data
local result = Equipment.Strengthen(normal, "weapon", now + 3)
assert(result.ok and not preview.tutorialFree)
assert(LargeNumber.Compare(result.state.gold, LargeNumber.Subtract(normal.gold, preview.gold)) == 0)
assert(LargeNumber.Compare(result.state.fragments, 100 - preview.fragments) == 0)
print("tutorial_strengthen: PASS")
