local BigNumber = require("shared.BigNumber")
local RarityCatalog = require("shared.RarityCatalog")
local RewardPolicy = require("shared.RewardPolicy")

local Spec = {}

local function near(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s: expected %.12g, got %.12g", label or "value", expected, actual))
end

local function total(weights)
    local result = 0
    for _, id in ipairs(RarityCatalog.ORDER) do result = result + (weights[id] or 0) end
    return result
end

function Spec.Run()
    near(RewardPolicy.DropChance("normal", "online"), 0.12, 1e-12, "online drop")
    near(RewardPolicy.DropChance("normal", "offline"), 0.024, 1e-12, "offline drop")
    near(RewardPolicy.DropChance("elite", true), 0.07, 1e-12, "boolean offline drop")
    assert(RewardPolicy.ShouldDrop("normal", 0.0239, "offline"))
    assert(not RewardPolicy.ShouldDrop("normal", 0.024, "offline"))
    assert(RewardPolicy.ScaleFixedReward(101, "offline") == 20)

    local chapter1 = RewardPolicy.GetQualityWeights("chapterBoss", 1)
    local chapter10 = RewardPolicy.GetQualityWeights("chapterBoss", 10)
    local chapter30 = RewardPolicy.GetQualityWeights("chapterBoss", 30)
    local chapter50 = RewardPolicy.GetQualityWeights("chapterBoss", 50)
    local chapter100 = RewardPolicy.GetQualityWeights("chapterBoss", 100)
    near(total(chapter1), 100, 1e-9, "floor 1 weight total")
    assert(chapter1.rare == 100)
    assert(chapter10.artifact == 100)
    assert(chapter30.legendary == 100)
    near(chapter50.legendary, 92, 1e-12, "floor 50 legendary")
    near(chapter50.epic, 8, 1e-12, "floor 50 epic plus locked myth")
    near(chapter100.legendary, 92, 1e-12, "floor 100 legendary")
    near(chapter100.epic, 7.8, 1e-12, "floor 100 epic")
    near(chapter100.myth, 0.2, 1e-12, "floor 100 myth")

    assert(RewardPolicy.RollRarity("chapterBoss", 100, 0.0) == "legendary")
    assert(RewardPolicy.RollRarity("chapterBoss", 100, 0.92) == "epic")
    assert(RewardPolicy.RollRarity("chapterBoss", 100, 0.999) == "myth")

    local epicSoft = RewardPolicy.GetQualityWeights("chapterBoss", 100, { epicMisses = 9 })
    assert(epicSoft.epic > chapter100.epic and epicSoft.legendary < chapter100.legendary)
    near(total(epicSoft), 100, 1e-9, "soft pity total")
    local epicHard = RewardPolicy.GetQualityWeights("chapterBoss", 100, { epicMisses = 19 })
    near(epicHard.legendary, 0, 1e-12, "epic hard pity lower weight")
    near(epicHard.epic + epicHard.myth, 100, 1e-9, "epic hard pity guarantee")
    local mythHard = RewardPolicy.GetQualityWeights("chapterBoss", 100, { mythMisses = 99 })
    near(mythHard.myth, 100, 1e-9, "myth hard pity")

    local pity = RewardPolicy.UpdatePity({ epicMisses = 5, mythMisses = 20 }, "legendary")
    assert(pity.epicMisses == 6 and pity.mythMisses == 21)
    pity = RewardPolicy.UpdatePity(pity, "epic")
    assert(pity.epicMisses == 0 and pity.mythMisses == 22)
    pity = RewardPolicy.UpdatePity(pity, "myth")
    assert(pity.epicMisses == 0 and pity.mythMisses == 0)

    local slotWeightTotal = 0
    for _, slot in ipairs(RewardPolicy.SLOT_ORDER) do
        slotWeightTotal = slotWeightTotal + RewardPolicy.SLOT_WEIGHTS[slot]
    end
    assert(slotWeightTotal == 10000)
    near(RewardPolicy.RollMultiplier(0), 0.95, 1e-12, "minimum item roll")
    near(RewardPolicy.RollMultiplier(0.5), 1.00, 1e-12, "neutral item roll")
    near(RewardPolicy.RollMultiplier(1), 1.05, 1e-12, "maximum item roll")
    near(RewardPolicy.EnhanceMultiplier(0), 1, 1e-12, "zero enhance")
    near(RewardPolicy.EnhanceMultiplier(20), 1 + 0.35 * (1 - math.exp(-1)), 1e-12,
        "enhance curve")
    assert(RewardPolicy.EnhanceMultiplier(10000) <= 1.35 + 1e-12)
    near(RewardPolicy.StarMultiplier(5), 1.25, 1e-12, "five stars")

    near(RewardPolicy.ItemBudgetNumber("weapon", 1, "rare", 0.5, 0, 0),
        13175, 1e-9, "floor 1 rare weapon budget")
    local highBudget = RewardPolicy.ItemBudget("weapon", 100000, "myth", 1, 10000, 5)
    assert(highBudget.exponent > 600 and BigNumber.ToNumber(highBudget) == nil)

    local allSlots = { "weapon", "coat", "ring", "earring" }
    local weakSlots = { "coat", "ring", "earring" }
    assert(RewardPolicy.PickDropSlot(allSlots, weakSlots, 0.64, 0) == "coat")
    assert(RewardPolicy.PickDropSlot(allSlots, weakSlots, 0.64, 0.99) == "earring")
    assert(RewardPolicy.PickDropSlot(allSlots, weakSlots, 0.65, 0) == "weapon")
    assert(RewardPolicy.AutoEquipSurvivalMarginPasses(0.80, 0.80))
    assert(not RewardPolicy.AutoEquipSurvivalMarginPasses(0.80, 0.79))
    assert(RewardPolicy.AutoEquipSurvivalMarginPasses(2.00, 1.25))
    assert(not RewardPolicy.AutoEquipSurvivalMarginPasses(2.00, 1.24))
    assert(not RewardPolicy.ShouldGrantAid(1, false))
    assert(RewardPolicy.ShouldGrantAid(2, false))
    assert(not RewardPolicy.ShouldGrantAid(2, true))
end

return Spec
