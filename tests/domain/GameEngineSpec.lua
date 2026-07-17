local Catalog = require("server.domain.Catalog")
local GameEngine = require("server.domain.GameEngine")
local StateFactory = require("server.domain.StateFactory")
local StateNormalizer = require("server.domain.StateNormalizer")
local TableUtils = require("server.domain.TableUtils")

local Spec = {}

local function queueRng(integers, floats)
    local rng = {
        integers = integers or {},
        floats = floats or {},
        integerIndex = 1,
        floatIndex = 1,
    }
    function rng:Int(minimum, maximum)
        local value = self.integers[self.integerIndex]
        self.integerIndex = self.integerIndex + 1
        if value == nil then
            return maximum
        end
        return math.max(minimum, math.min(maximum, value))
    end
    function rng:Float()
        local value = self.floats[self.floatIndex]
        self.floatIndex = self.floatIndex + 1
        return value == nil and 0.99 or value
    end
    return rng
end

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function assertTrue(value, message)
    if not value then
        error(message or "expected truthy value", 2)
    end
end

local function assertDeepEqual(actual, expected, message)
    if not TableUtils.DeepEqual(actual, expected) then
        error(message or "tables differ", 2)
    end
end

function Spec.InitialStateRepairsDemoData()
    local state = StateFactory.Create(1000)
    assertEqual(state.level, 21)
    assertEqual(state.exp, 464)
    assertEqual(state.nextExp, 1636)
    assertEqual(#state.inventory, 17)
    assertEqual(state.nextItemId, 18)
    assertEqual(state.equipped.pants, "eq-000010")
    local pants = TableUtils.FindById(state.inventory, state.equipped.pants)
    assertEqual(pants.slot, "pants")
    assertEqual(state.fragments, 520)
    for _, item in ipairs(state.inventory) do
        assertTrue(item.slot ~= nil, "inventory must only contain equipment")
        assertTrue(type(item.id) == "string", "equipment ids must be stable strings")
    end
    assertEqual(state.consumables.healthPotion, 12)
end

function Spec.NormalizerMigratesLegacyReferencesWithoutDuplicateMaterials()
    local coat = { id = 1, name = "legacy coat", slot = "coat", rarity = "epic", hp = 10 }
    local normalized = StateNormalizer.Normalize({
        level = 18,
        exp = 4200,
        fragments = 520,
        mythShards = 12,
        inventory = {
            coat,
            { id = 2, name = "深渊碎片", category = "material", rarity = "purple", quantity = 520 },
            { id = 3, name = "神话碎片", category = "material", rarity = "epic", quantity = 12 },
        },
        equipped = { pants = coat },
    }, 1000)
    assertEqual(normalized.level, 21)
    assertEqual(normalized.exp, 464)
    assertEqual(#normalized.inventory, 1)
    assertEqual(normalized.fragments, 520)
    assertEqual(normalized.mythShards, 12)
    local item = normalized.inventory[1]
    assertEqual(item.slot, "pants")
    assertEqual(normalized.equipped.pants, item.id)
end

function Spec.MutationsDoNotModifyInputAndBuildBatchCommit()
    local state = StateFactory.Create(1000)
    local before = TableUtils.DeepCopy(state)
    local proposal = GameEngine.SetAutoRun(state, false, 1001)
    assertTrue(proposal.ok)
    assertDeepEqual(state, before, "engine mutated its input")
    assertEqual(proposal.state.autoRun, false)
    assertEqual(proposal.state.revision, 1)
    assertEqual(proposal.commit.kind, "BatchCommit")
    assertEqual(proposal.commit.expectedRevision, 0)
    assertEqual(proposal.commit.scores.abyss_revision, 1)
    assertTrue(proposal.commit.lists.abyss_inventory ~= state.inventory)
    assertTrue(proposal.delta.changes == proposal.delta.changed)
end

function Spec.EquipUsesLogicalItemIds()
    local state = StateFactory.Create(1000)
    local proposal = GameEngine.Equip(state, "eq-000016", 1001)
    assertTrue(proposal.ok)
    assertEqual(proposal.state.equipped.weapon, "eq-000016")
    assertEqual(type(proposal.state.equipped.weapon), "string")
    assertEqual(proposal.delta.changes.equipped.weapon, "eq-000016")
    assertDeepEqual(state.equipped, StateFactory.Create(1000).equipped)
end

function Spec.AutoEquipSelectsHigherPowerItem()
    local state = StateFactory.Create(1000)
    local grant = GameEngine.GrantEquipment(state, {
        name = "test ultimate weapon",
        slot = "weapon",
        rarity = "myth",
        atk = 99999,
    }, 1001)
    assertTrue(grant.ok)
    local itemId = grant.state.inventory[#grant.state.inventory].id
    local proposal = GameEngine.AutoEquip(grant.state, 1002)
    assertTrue(proposal.ok)
    assertEqual(proposal.state.equipped.weapon, itemId)
end

function Spec.DecomposeSkipsEquippedAndAwardsFragments()
    local state = StateFactory.Create(1000)
    local grant = GameEngine.GrantEquipment(state, {
        name = "test common weapon",
        slot = "weapon",
        rarity = "common",
        atk = 1,
    }, 1001)
    local grantedId = grant.state.inventory[#grant.state.inventory].id
    local proposal = GameEngine.Decompose(grant.state, 1, 1002)
    assertTrue(proposal.ok)
    assertTrue(TableUtils.FindById(proposal.state.inventory, grantedId) == nil)
    assertTrue(TableUtils.FindById(proposal.state.inventory, proposal.state.equipped.magicstone) ~= nil)
    assertEqual(proposal.state.fragments, grant.state.fragments + 1)
end

function Spec.StrengthenPaysExactCostAndHonorsLimit()
    local state = StateFactory.Create(1000)
    local itemBefore = TableUtils.FindById(state.inventory, state.equipped.belt)
    assertEqual(itemBefore.enhance, 0)
    local proposal = GameEngine.Strengthen(state, "belt", 1001)
    assertTrue(proposal.ok)
    local itemAfter = TableUtils.FindById(proposal.state.inventory, proposal.state.equipped.belt)
    assertEqual(itemAfter.enhance, 1)
    assertEqual(proposal.state.gold, state.gold - 1200)
    assertEqual(proposal.state.fragments, state.fragments - 8)
    local rejected = GameEngine.Strengthen(proposal.state, "belt", 1002)
    assertEqual(rejected.ok, false)
    assertEqual(rejected.error.code, "ENHANCE_LIMIT")
    assertEqual(rejected.commit.kind, "none")
end

function Spec.StarConsumesUnequippedDuplicate()
    local state = StateFactory.Create(1000)
    local countBefore = #state.inventory
    local proposal = GameEngine.Star(state, "weapon", 1001)
    assertTrue(proposal.ok)
    assertEqual(#proposal.state.inventory, countBefore - 1)
    local weapon = TableUtils.FindById(proposal.state.inventory, proposal.state.equipped.weapon)
    assertEqual(weapon.star, 1)
    assertTrue(TableUtils.FindById(proposal.state.inventory, "eq-000017") == nil)
end

function Spec.AdvanceResolvesChestDeterministically()
    local state = StateFactory.Create(1000)
    local proposal = GameEngine.AdvanceOneCell(state, queueRng({ 80, 3, 100 }), 1003)
    assertTrue(proposal.ok)
    assertEqual(proposal.state.position, 88)
    assertEqual(proposal.state.currentEvent, "chest")
    assertEqual(proposal.state.gold, state.gold + 100)
    assertEqual(proposal.state.fragments, state.fragments + 3)
    assertEqual(#proposal.state.inventory, #state.inventory)
end

function Spec.BattleIsServerDeterministicWhenRngIsInjected()
    local state = StateFactory.Create(1000)
    state.position = 0
    local first = GameEngine.AdvanceOneCell(state, queueRng(), 1003)
    local second = GameEngine.AdvanceOneCell(state, queueRng(), 1003)
    assertTrue(first.ok and second.ok)
    assertDeepEqual(first.state, second.state)
    assertDeepEqual(first.delta.events, second.delta.events)
    assertEqual(first.state.position, 1)
    assertTrue(first.state.gold > state.gold)
end

function Spec.FullInventoryPausesWithoutAdvancingOrDropping()
    local state = StateFactory.Create(1000)
    local template = TableUtils.DeepCopy(state.inventory[1])
    while #state.inventory < Catalog.INVENTORY_CAP do
        local id = string.format("eq-%06d", state.nextItemId)
        state.nextItemId = state.nextItemId + 1
        local item = TableUtils.DeepCopy(template)
        item.id = id
        item.name = "capacity filler " .. id
        state.inventory[#state.inventory + 1] = item
    end
    state.autoRun = true
    local before = TableUtils.DeepCopy(state)
    local proposal = GameEngine.AdvanceOneCell(state, queueRng(), 1003)
    assertTrue(proposal.ok)
    assertEqual(proposal.state.position, before.position)
    assertEqual(#proposal.state.inventory, Catalog.INVENTORY_CAP)
    assertEqual(proposal.state.autoRun, false)
    assertEqual(proposal.state.pauseReason, "inventory_full")
    assertDeepEqual(state, before)
end

function Spec.MultiDropOverflowRollsBackTheWholeCell()
    local state = StateFactory.Create(1000)
    local template = TableUtils.DeepCopy(state.inventory[1])
    while #state.inventory < Catalog.INVENTORY_CAP - 1 do
        local id = string.format("eq-%06d", state.nextItemId)
        state.nextItemId = state.nextItemId + 1
        local item = TableUtils.DeepCopy(template)
        item.id = id
        item.name = "boss overflow filler " .. id
        state.inventory[#state.inventory + 1] = item
    end
    state.floor = 100
    state.maxFloor = 100
    state.position = 99
    state.permanentBonus = 1000
    state.hp = 1000000000

    local rng = { hundredRolls = 0 }
    function rng:Int(minimum, maximum)
        if minimum == 1 and maximum == 100 then
            self.hundredRolls = self.hundredRolls + 1
            return self.hundredRolls == 2 and 1 or 100
        end
        return maximum
    end
    function rng:Float()
        return 0.99
    end

    local proposal = GameEngine.AdvanceOneCell(state, rng, 1003)
    assertTrue(proposal.ok)
    assertEqual(proposal.state.position, 99)
    assertEqual(proposal.state.floor, 100)
    assertEqual(#proposal.state.inventory, Catalog.INVENTORY_CAP - 1)
    assertEqual(proposal.state.autoRun, false)
    assertEqual(proposal.state.pauseReason, "inventory_full")
    assertEqual(proposal.delta.events[1].rollback, "cell_settlement")
end

function Spec.OfflineAccrualCapsAtTwelveHoursAndCollectsOnce()
    local state = StateFactory.Create(1000)
    state.pendingOfflineSeconds = 0
    state.lastActiveAt = 1000
    local accrued = GameEngine.AccrueOffline(state, 1000 + Catalog.OFFLINE_MAX_SECONDS + 5000)
    assertTrue(accrued.ok)
    assertEqual(accrued.state.pendingOfflineSeconds, Catalog.OFFLINE_MAX_SECONDS)
    local collected = GameEngine.CollectOffline(accrued.state, 50001)
    assertTrue(collected.ok)
    assertEqual(collected.state.pendingOfflineSeconds, 0)
    assertTrue(collected.state.gold > accrued.state.gold)
    assertTrue(collected.state.level >= accrued.state.level)
    local duplicate = GameEngine.CollectOffline(collected.state, 50002)
    assertEqual(duplicate.ok, false)
    assertEqual(duplicate.error.code, "NO_OFFLINE_REWARD")
end

function Spec.TouchActivePersistsDisconnectTimeWithoutChangingAutoRun()
    local state = StateFactory.Create(1000)
    local touched = GameEngine.TouchActive(state, 1005)
    assertTrue(touched.ok)
    assertEqual(touched.state.lastActiveAt, 1005)
    assertEqual(touched.state.autoRun, state.autoRun)
    assertEqual(touched.commit.kind, "BatchCommit")
    local unchanged = GameEngine.TouchActive(touched.state, 1005)
    assertTrue(unchanged.ok)
    assertEqual(unchanged.commit.kind, "none")
    assertTrue(unchanged.delta.changes == unchanged.delta.changed)
end

return Spec
