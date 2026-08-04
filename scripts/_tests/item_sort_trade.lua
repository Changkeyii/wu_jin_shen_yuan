local GameStateSchema = require("shared.GameStateSchema")
local ItemPresentation = require("shared.ItemPresentation")
local ItemSort = require("shared.ItemSort")
local ItemTradeRules = require("shared.ItemTradeRules")
local LargeNumber = require("shared.LargeNumber")
local MarketCatalog = require("shared.MarketCatalog")
local GameEngine = require("server.domain.GameEngine")
local MarketEngine = require("server.domain.MarketEngine")
local StateFactory = require("server.domain.StateFactory")
local StateNormalizer = require("server.domain.StateNormalizer")

local function equal(actual, expected, message)
    assert(actual == expected, string.format(
        "%s: expected=%s actual=%s",
        message,
        tostring(expected),
        tostring(actual)
    ))
end

local function cloneItem(item, id, overrides)
    local result = {}
    for key, value in pairs(item) do result[key] = value end
    result.id = id
    for key, value in pairs(overrides or {}) do result[key] = value end
    return result
end

local function run()
    local sorted = {
        { id = "c", rarity = "epic", level = 99, enhance = 99, star = 5 },
        { id = "b", rarity = "myth", level = 10, enhance = 1, star = 0 },
        { id = "a", rarity = "myth", level = 10, enhance = 2, star = 0 },
        { id = "d", rarity = "myth", level = 11, enhance = 0, star = 0 },
    }
    ItemSort.Sort(sorted)
    equal(sorted[1].id, "d", "higher level first inside rarity")
    equal(sorted[2].id, "a", "higher enhance next")
    equal(sorted[3].id, "b", "lower enhance follows")
    equal(sorted[4].id, "c", "rarity outranks all lower rarity stats")

    equal(ItemTradeRules.RollDropTradeable("monster_drop", 0), true, "zero roll")
    equal(ItemTradeRules.RollDropTradeable("boss_drop", 0.024999), true, "below boundary")
    equal(ItemTradeRules.RollDropTradeable("elite_drop", 0.025), false, "boundary excluded")
    equal(ItemTradeRules.RollDropTradeable("chest_drop", 0.99), false, "high roll")
    equal(ItemTradeRules.RollDropTradeable("tower_aid", 0), false, "aid never tradeable")
    equal(ItemTradeRules.RollDropTradeable("admin_grant", 0), false, "grant never tradeable")
    equal(MarketCatalog.IsListableItem({
        id = "future-stackable-item",
        rarity = "myth",
        tradeable = true,
    }), false, "non-equipment reserved for future")

    local now = 1785800000
    local base = StateFactory.Create(now)
    local template = base.inventory[1]
    local tradableId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    local legacyId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    local tradable = cloneItem(template, tradableId, {
        rarity = "legendary",
        setEnabled = false,
        source = "boss_drop",
        tradeable = true,
        locked = false,
        aidLocked = false,
        level = 30,
    })
    local legacy = cloneItem(template, legacyId, {
        rarity = "legendary",
        setEnabled = false,
        source = "legacy",
        tradeable = nil,
        locked = false,
        aidLocked = false,
        level = 30,
    })
    base.inventory = { tradable, legacy }
    base.equipped = {}
    base.equippedSlots = {}
    base.marketListings = {}
    base.gold = LargeNumber.FromNumber(100000)

    local normalized = StateNormalizer.Normalize(base, now)
    equal(normalized.inventory[1].tradeable, true, "explicit tradeable preserved")
    equal(normalized.inventory[2].tradeable, false, "legacy defaults false")
    equal(ItemPresentation.CategoryName("consumable"), "消耗品", "consumable category localized")
    equal(ItemPresentation.DisplayName(normalized.inventory[1]),
        "【可交易】" .. tostring(normalized.inventory[1].name), "tradeable name prefixed")
    equal(ItemPresentation.DisplayName(normalized.inventory[2]),
        tostring(normalized.inventory[2].name), "non-tradeable name unchanged")

    local persisted = GameStateSchema.ToPersistedState(normalized)
    equal(persisted.inventory[1].tradeable, true, "persisted field preserved")
    equal(persisted.inventory[2].tradeable, false, "persisted legacy false")

    local snapshot = GameStateSchema.BuildSnapshot(normalized, {})
    equal(snapshot.inventory[1].tradeable, true, "network field preserved")
    equal(snapshot.inventory[2].tradeable, false, "network legacy false")

    local equipped = GameEngine.Equip(normalized, tradableId, now + 1)
    equal(equipped.ok, true, "tradeable equipment can be equipped")
    local equippedItem = nil
    for _, item in ipairs(equipped.state.inventory) do
        if item.id == tradableId then equippedItem = item break end
    end
    equal(equippedItem and equippedItem.tradeable, false, "equipping consumes tradeable status")

    local unequipped = GameEngine.Unequip(equipped.state, equippedItem.slot, now + 2)
    equal(unequipped.ok, true, "bound equipment can be unequipped")
    local unequippedItem = nil
    for _, item in ipairs(unequipped.state.inventory) do
        if item.id == tradableId then unequippedItem = item break end
    end
    equal(unequippedItem and unequippedItem.tradeable, false, "unequip does not restore tradeable status")

    local reboundListing = MarketEngine.List(unequipped.state, {
        itemId = tradableId,
        price = LargeNumber.FromNumber(1000),
        sellerUid = 123,
    }, now + 3)
    equal(reboundListing.ok, false, "equipped-once item listing rejected")
    equal(reboundListing.error.code, "ITEM_NOT_TRADABLE", "bound listing rejection code")

    local blocked = MarketEngine.List(normalized, {
        itemId = legacyId,
        price = LargeNumber.FromNumber(1000),
        sellerUid = 123,
    }, now + 1)
    equal(blocked.ok, false, "legacy listing rejected")
    equal(blocked.error.code, "ITEM_NOT_TRADABLE", "legacy rejection code")

    local allowed = MarketEngine.List(normalized, {
        itemId = tradableId,
        price = LargeNumber.FromNumber(1000),
        sellerUid = 123,
    }, now + 1)
    equal(allowed.ok, true, "tradeable legendary listing accepted")
    equal(allowed.market.listingRecord.item.tradeable, true, "listing preserves field")

    local lowId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    local lowState = StateNormalizer.Normalize(base, now)
    lowState.inventory = {
        cloneItem(lowState.inventory[1], lowId, {
            rarity = "artifact",
            tradeable = true,
        }),
    }
    local lowBlocked = MarketEngine.List(lowState, {
        itemId = lowId,
        price = LargeNumber.FromNumber(1000),
        sellerUid = 123,
    }, now + 1)
    equal(lowBlocked.ok, false, "below legendary rejected")
    equal(lowBlocked.error.code, "RARITY_NOT_LISTABLE", "rarity rejection code")
end

function Start()
    local ok, failure = pcall(run)
    if ok then
        print("[ItemTradeTest] PASS")
    else
        print("[ItemTradeTest] FAIL " .. tostring(failure))
    end
    engine:Exit(ok and 0 or 1)
end
