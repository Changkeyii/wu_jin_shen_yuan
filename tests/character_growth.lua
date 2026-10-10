local Factory = require("server.domain.StateFactory")
local Normalizer = require("server.domain.StateNormalizer")
local Transition = require("server.domain.PlayerTransition")
local Progression = require("shared.GameProgression")
local Wish = require("server.domain.WishPoolEngine")
local Jars = require("shared.WishPoolDefinitions")
local Equipment = require("server.domain.EquipmentEngine")
local Rewards = require("server.domain.RewardEngine")
local Catalog = require("server.domain.Catalog")
local Schema = require("shared.GameStateSchema")
local Big = require("shared.BigNumber")
local Large = require("shared.LargeNumber")
local Tables = require("shared.TableUtils")
local now = 1791620000
local function state(level)
    local value = Factory.Create(now)
    value.tutorial.completed = true
    value.level = level or 1
    return value
end
local function valid(value)
    local ok, err = Schema.ValidateState(value)
    assert(ok, tostring(err and err.reason) .. ":" .. tostring(err and err.details and err.details.path))
    local snapshot = Schema.BuildSnapshot(value, { serverTime = now, playerNickname = "Growth test", playerUid = "1001", isAdmin = false })
    snapshot.logs, snapshot.recentDamage = {}, "Waiting"
    ok, err = Schema.ValidateSnapshot(snapshot)
    assert(ok, tostring(err and err.reason) .. ":" .. tostring(err and err.details and err.details.path))
end

-- Every eligible tier is selectable, including exact multiples and the next tier above a level.
for level = 1, 100 do
    local minimum = math.max(5, math.ceil(level / 5) * 5)
    assert(Jars.MinimumJarLevel(level) == minimum)
    assert(Jars.RandomLevel(function(a, b) return a end, level) == minimum)
    assert(Jars.RandomLevel(function(a, b) return b end, level) == 100)
    for tier = minimum, 100, 5 do
        assert(Jars.RandomLevel(function() return tier / 5 end, level) == tier)
    end
end
for level = 5, 100, 5 do
    local id = Jars.MakeJarId("combo", "myth", "weapon", nil, level)
    assert(Jars.ResolveJar(id).level == level)
end
for _, id in ipairs({ "jar.random.lv0", "jar.random.lv6", "jar.random.lv105", "jar.random.lv05", "jar.unknown.lv100" }) do
    assert(not Jars.ResolveJar(id))
end

-- Actual ten-pull rewards obey the current-level lower bound without changing quality pity.
for _, level in ipairs({ 1, 5, 35, 36, 99, 100 }) do
    local value = state(level)
    value.wishPool.tickets = 8
    local result = Wish.Wish(value, "ticket", now, function() return 0 end, 10)
    assert(result.ok)
    local total = 0
    for id, count in pairs(result.state.wishPool.jars) do
        local jar = assert(Jars.ResolveJar(id))
        assert(jar.level >= level and jar.level <= 100 and jar.level % 5 == 0 and not jar.legacy)
        total = total + count
    end
    assert(total == 10 and result.state.wishPool.tickets == 0 and value.wishPool.tickets == 8)
    valid(result.state)
end

-- High-level jars are openable, retain their exact level, and cannot bypass any equip route.
local value = state(35)
value.wishPool.jars["jar.combo.weapon.epic.lv100"] = 1
local opened = Wish.OpenJar(value, "jar.combo.weapon.epic.lv100", now, function() return 0 end, 1)
assert(opened.ok and value.wishPool.jars["jar.combo.weapon.epic.lv100"] == 1)
local item = opened.state.inventory[#opened.state.inventory]
assert(item.level == 100 and item.rarity == "epic" and not item.legacyLevel)
assert(not Equipment.Equip(opened.state, item.id, now + 3).ok)
local invalidLoadout = Tables.DeepCopy(opened.state)
invalidLoadout.equipped.weapon = item.id
assert(not Schema.ValidateState(invalidLoadout))
local sanitized = Normalizer.Normalize(Schema.ToPersistedState(invalidLoadout), now)
assert(sanitized.equipped.weapon ~= item.id and sanitized.inventory[#sanitized.inventory].id == item.id)
valid(sanitized)
local automatic = Equipment.AutoEquip(opened.state, now + 3)
assert(not automatic.ok or automatic.state.equipped.weapon ~= item.id)
opened.state.level = 100
local equip = Equipment.Equip(opened.state, item.id, now + 3)
assert(equip.ok and equip.state.equipped.weapon == item.id)
valid(equip.state)

-- A full bag does not consume a jar or auto-sell/decompose its valuable result.
value = state(100)
local exemplar = value.inventory[1]
while #value.inventory < Catalog.GetInventoryCapacity(value) do
    local clone = Tables.DeepCopy(exemplar)
    clone.id = string.format("00000000-0000-4000-8000-%012x", #value.inventory + 100)
    value.inventory[#value.inventory + 1] = clone
end
value.inventoryPolicy.autoSell, value.inventoryPolicy.sellRarities.epic = true, true
value.wishPool.jars["jar.rarity.epic.lv100"] = 2
local full = Wish.OpenJar(value, "jar.rarity.epic.lv100", now, nil, 2)
assert(not full.ok and value.wishPool.jars["jar.rarity.epic.lv100"] == 2)

-- Set constraints survive rarity fallback and random slot selection.
for _, setId in ipairs({ "nightmare", "lucky", "voyage", "abyss", "prophecy" }) do
    value = state(100)
    local id = Jars.MakeJarId("set", nil, nil, setId, 100)
    value.wishPool.jars[id] = 6
    local result = Wish.OpenJar(value, id, now, function() return 0.5 end, 6)
    assert(result.ok)
    for index = #result.state.inventory - 5, #result.state.inventory do
        assert(result.state.inventory[index].setId == setId and result.state.inventory[index].level == 100)
    end
    valid(result.state)
end

-- Combat/drop generation reaches finite five-level tiers; floor progression cannot grow the core.
for _, level in ipairs({ 1, 9, 35, 36, 99, 100 }) do
    value = state(level)
    value.floor, value.maxFloor = 999999, 999999
    local before = Catalog.CalculateStats(value)
    local ok, drop = Rewards.AddGeneratedDrop(value, "epic", false, nil, now, "boss_drop", {}, { floor = 999999 })
    assert(ok and drop.level == Progression.EquipmentLevel(level))
    value.maxFloor = 1000000
    local after = Catalog.CalculateStats(value)
    assert(Big.Compare(before.atkBig, after.atkBig) == 0)
end

-- Cap crossing uses the bounded mastery conversion, persisted daily accounting, and isolated clones.
value = state(99)
local gained = Progression.AddExperience(value, Progression.NextExp(99) + 2000000, now)
assert(gained == 1 and value.level == 100 and value.exp == 0 and value.nextExp == 0)
assert(value.growth.masteryFragments == 2)
for _ = 1, 3 do Progression.AddExperience(value, 1000000000, now) end
assert(value.level == 100 and value.growth.masteryFragments == 100)
local persisted = Schema.ToPersistedState(value)
local restored = Normalizer.Normalize(persisted, now)
assert(restored.growth.masteryFragments == 100)
local cloned = Transition.ShallowClone(restored, now + 86400)
Progression.AddExperience(cloned, 1000000, now + 86400)
assert(restored.growth.masteryFragments == 100 and cloned.growth.masteryFragments == 1)
valid(cloned)

-- Migration archives historical level/core and retains equipment stats/investments and jar stock.
value = state(1)
value.schemaVersion = 10
value.level, value.maxFloor, value.floor = 280, 888, 888
value.inventory[1].level, value.inventory[1].enhance, value.inventory[1].star = 777, 300, 5
value.inventory[1].investedGold = Large.FromNumber(123456)
value.wishPool.jars["jar.rarity.myth"] = 7
local before = Tables.DeepCopy(value.inventory[1])
local migrated = Normalizer.Normalize(Schema.ToPersistedState(value), now)
assert(migrated.level == 100 and migrated.growth.legacyLevel == 280 and migrated.growth.legacyCoreFloor == 888)
assert(migrated.inventory[1].level == 100 and migrated.inventory[1].legacyLevel == 777)
assert(Big.Compare(migrated.inventory[1].atkBig, before.atkBig) == 0)
assert(migrated.inventory[1].enhance == 300 and migrated.inventory[1].star == 5)
assert(Large.Compare(migrated.inventory[1].investedGold, before.investedGold) == 0)
assert(migrated.wishPool.jars["jar.rarity.myth"] == 7)
assert(Large.Compare(Catalog.GetSellValue(migrated.inventory[1], 0), Catalog.GetSellValue(before, 0)) == 0)
assert(Large.Compare(Catalog.GetStrengthenCost(migrated.inventory[1], 301).gold, Catalog.GetStrengthenCost(before, 301).gold) == 0)
assert(Catalog.GetDecomposeRefund(migrated.inventory[1], 0).fragments == Catalog.GetDecomposeRefund(before, 0).fragments)
migrated.maxFloor = 999
local again = Normalizer.Normalize(Schema.ToPersistedState(migrated), now)
assert(again.growth.legacyCoreFloor == 888 and again.growth.legacyLevel == 280)
valid(again)

-- Generic grants select only eligible tiers; an already owned lower tier stays unchanged.
value = state(36)
value.wishPool.jars["jar.random.lv5"] = 1
assert(Jars.GrantJars(value, "jar.random", 2, function(a) return a end) == "jar.random.lv40")
assert(value.wishPool.jars["jar.random.lv5"] == 1 and value.wishPool.jars["jar.random.lv40"] == 2)
assert(Jars.GrantJars(value, "jar.random.lv100", 1) == "jar.random.lv100")

-- Recycling is an ordinary atomic mutation; no insufficient-stock grant and no input mutation.
value = state(100)
value.wishPool.jars["jar.random.lv5"] = 2
local originalFragments = Large.Normalize(value.fragments)
local recycled = Wish.RecycleJar(value, "jar.random.lv5", 2, now)
assert(recycled.ok and not recycled.state.wishPool.jars["jar.random.lv5"])
assert(value.wishPool.jars["jar.random.lv5"] == 2 and Large.Compare(value.fragments, originalFragments) == 0)
assert(not Wish.RecycleJar(recycled.state, "jar.random.lv5", 1, now + 3).ok)
valid(recycled.state)

-- Graduation requires twelve distinct parts from one set, a matching myth and a completed boss.
value = state(100)
assert(Progression.BuildGoal(value).stage == "set")
for _, definition in ipairs(require("shared.EquipmentCatalog").GetAll()) do
    if definition.setId == "nightmare" then
        value.inventory[#value.inventory + 1] = { equipmentId = definition.id, slot = definition.slot,
            level = 100, rarity = "epic", setId = "nightmare", setEnabled = true }
    end
end
assert(Progression.BuildGoal(value).stage == "myth")
value.inventory[#value.inventory].rarity = "myth"
value.maxFloor = 150
assert(Progression.BuildGoal(value).stage == "challenge")
value.maxFloor = 151
assert(Progression.BuildGoal(value).stage == "complete")
print("character_growth: PASS (cap, tier bounds, actual draws/open/equip, rollback, legacy, mastery and graduation)")
