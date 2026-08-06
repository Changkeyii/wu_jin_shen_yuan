local StateNormalizer = require("server.domain.StateNormalizer")
local GameStateSchema = require("shared.GameStateSchema")
local Catalog = require("server.domain.Catalog")
local LargeNumber = require("shared.LargeNumber")

local StateFactory = {}

local function starterLoadout(now)
    local definitionBySlot = {}
    for _, definition in ipairs(Catalog.EQUIPMENT_DEFINITIONS) do
        if not definitionBySlot[definition.slot] then definitionBySlot[definition.slot] = definition end
    end

    local inventory = {}
    local equipped = {}
    for index, slot in ipairs(Catalog.SLOTS) do
        local definition = assert(definitionBySlot[slot.id], "missing starter equipment definition: " .. slot.id)
        local stats = Catalog.CreateItemStats(definition, 1, "rare", 1.0, 0, 0)
        local itemId = string.format("00000000-0000-4000-8000-%012x", index)
        inventory[#inventory + 1] = {
            id = itemId,
            equipmentId = definition.id,
            level = 1,
            rarity = "rare",
            setEnabled = false,
            setId = nil,
            roll = stats.roll,
            statVersion = 5,
            budget = stats.budget,
            budgetBig = stats.budgetBig,
            atk = stats.atk,
            def = stats.def,
            hp = stats.hp,
            atkBig = stats.atkBig,
            defBig = stats.defBig,
            hpBig = stats.hpBig,
            crit = stats.crit,
            critDmg = stats.critDmg,
            atkSpeed = stats.atkSpeed,
            lifeSteal = stats.lifeSteal,
            damageReduction = stats.damageReduction,
            bossDamage = stats.bossDamage,
            coreAffixes = {},
            enhance = 0,
            star = 0,
            locked = false,
            acquiredAt = now,
            source = "starter",
            investedGold = LargeNumber.Zero(),
            investedFragments = 0,
        }
        equipped[slot.id] = itemId
    end
    return inventory, equipped
end

function StateFactory.Create(now)
    now = math.max(0, math.floor(now or os.time()))
    local inventory, equipped = starterLoadout(now)
    return StateNormalizer.Normalize({
        schemaVersion = GameStateSchema.VERSION,
        revision = 0,
        updatedAt = now,
        lastActiveAt = now,
        pendingOfflineSeconds = 0,
        level = 1,
        vipLevel = 0,
        dailyVip = { signInDay = 0, adDay = 0 },
        trashTalkIndex = 0,
        exp = 0,
        floor = 1,
        maxFloor = 1,
        position = 0,
        autoRun = false,
        floorKillBonus = 0,
        permanentBonus = 0,
        nextItemId = #inventory + 1,
        inventory = inventory,
        equipped = equipped,
        consumables = { healthPotion = 0 },
        appliedGmCommandIds = {},
        mails = {},
        mailCache = {},
        mailSeq = 1,
    }, now)
end

StateFactory.CreateInitialState = StateFactory.Create

return StateFactory
