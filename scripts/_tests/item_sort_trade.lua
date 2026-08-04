local Catalog = require("server.domain.Catalog")
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

local function currencyEqual(actual, expected, message)
    equal(
        LargeNumber.ToString(actual),
        LargeNumber.ToString(expected),
        message
    )
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

    equal(ItemTradeRules.GetTradeableChanceUnits("artifact"), 4000, "artifact chance")
    equal(ItemTradeRules.GetTradeableChanceUnits("legendary"), 1500, "legendary chance")
    equal(ItemTradeRules.GetTradeableChanceUnits("epic"), 700, "epic chance")
    equal(ItemTradeRules.GetTradeableChanceUnits("myth"), 250, "myth chance")
    equal(ItemTradeRules.GetTradeableChanceUnits("rare"), 0, "rare cannot roll tradeable")

    equal(ItemTradeRules.RollDropTradeable("monster_drop", "artifact", 0), true,
        "artifact zero roll")
    equal(ItemTradeRules.RollDropTradeable("boss_drop", "artifact", 0.399999), true,
        "artifact below boundary")
    equal(ItemTradeRules.RollDropTradeable("elite_drop", "artifact", 0.4), false,
        "artifact boundary excluded")
    equal(ItemTradeRules.RollDropTradeable("chest_drop", "legendary", 0.149999), true,
        "legendary below boundary")
    equal(ItemTradeRules.RollDropTradeable("chest_drop", "legendary", 0.15), false,
        "legendary boundary excluded")
    equal(ItemTradeRules.RollDropTradeable("boss_drop", "epic", 0.069999), true,
        "epic below boundary")
    equal(ItemTradeRules.RollDropTradeable("boss_drop", "epic", 0.07), false,
        "epic boundary excluded")
    equal(ItemTradeRules.RollDropTradeable("boss_drop", "myth", 0.024999), true,
        "myth below boundary")
    equal(ItemTradeRules.RollDropTradeable("boss_drop", "myth", 0.025), false,
        "myth boundary excluded")
    equal(ItemTradeRules.RollDropTradeable("monster_drop", "rare", 0), false,
        "below artifact never tradeable")
    equal(ItemTradeRules.RollDropTradeable("tower_aid", "myth", 0), false,
        "aid never tradeable")
    equal(ItemTradeRules.RollDropTradeable("admin_grant", "myth", 0), false,
        "grant never tradeable")

    currencyEqual(
        MarketCatalog.GetMinimumListingPrice(LargeNumber.FromNumber(1), "artifact"),
        LargeNumber.FromNumber(3),
        "artifact minimum rounds upward"
    )
    currencyEqual(
        MarketCatalog.GetMinimumListingPrice(LargeNumber.FromNumber(7), "epic"),
        LargeNumber.FromNumber(100),
        "epic exact ratio"
    )
    currencyEqual(
        MarketCatalog.GetMinimumListingPrice(LargeNumber.FromNumber(8), "epic"),
        LargeNumber.FromNumber(115),
        "epic fractional ratio rounds upward"
    )
    currencyEqual(
        MarketCatalog.GetMinimumListingPrice(LargeNumber.FromNumber(1), "myth"),
        LargeNumber.FromNumber(40),
        "myth scarcity multiplier"
    )
    currencyEqual(
        LargeNumber.MultiplyRatioCeil(
            LargeNumber.FromString("999999999999999999999999999"), 1, 2
        ),
        LargeNumber.FromString("500000000000000000000000000"),
        "large-number ceiling across segments"
    )
    currencyEqual(
        MarketCatalog.GetMinimumListingPrice(
            assert(LargeNumber.FromString("24999999999999999999999999")),
            "myth"
        ),
        assert(LargeNumber.FromString("999999999999999999999999960")),
        "large myth scarcity result fits without intermediate saturation"
    )

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

    local snapshot = GameStateSchema.BuildSnapshot(normalized, {
        itemMarketQuote = function(item)
            local value = Catalog.GetMarketStandardValue(item)
            return {
                standardValue = value,
                minimumPrice = MarketCatalog.GetMinimumListingPrice(
                    value,
                    item.rarity
                ),
            }
        end,
    })
    equal(snapshot.inventory[1].tradeable, true, "network field preserved")
    equal(snapshot.inventory[2].tradeable, false, "network legacy false")
    local snapshotStandardValue = Catalog.GetMarketStandardValue(
        normalized.inventory[1]
    )
    currencyEqual(snapshot.inventory[1].marketStandardValue,
        snapshotStandardValue, "snapshot carries authoritative standard value")
    currencyEqual(snapshot.inventory[1].marketMinimumPrice,
        MarketCatalog.GetMinimumListingPrice(
            snapshotStandardValue,
            normalized.inventory[1].rarity
        ), "snapshot carries authoritative minimum price")

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
    equal(unequippedItem and unequippedItem.tradeable, false,
        "unequip does not restore tradeable status")

    local reboundListing = MarketEngine.List(unequipped.state, {
        itemId = tradableId,
        price = LargeNumber.Max(),
        sellerUid = 123,
    }, now + 3)
    equal(reboundListing.ok, false, "equipped-once item listing rejected")
    equal(reboundListing.error.code, "ITEM_NOT_TRADABLE", "bound listing rejection code")

    local blocked = MarketEngine.List(normalized, {
        itemId = legacyId,
        price = LargeNumber.Max(),
        sellerUid = 123,
    }, now + 1)
    equal(blocked.ok, false, "legacy listing rejected")
    equal(blocked.error.code, "ITEM_NOT_TRADABLE", "legacy rejection code")

    local standardValue = Catalog.GetMarketStandardValue(normalized.inventory[1])
    local minimumPrice = MarketCatalog.GetMinimumListingPrice(
        standardValue,
        normalized.inventory[1].rarity
    )
    local belowMinimum, subtractOk = LargeNumber.Subtract(
        minimumPrice,
        LargeNumber.FromNumber(1)
    )
    equal(subtractOk, true, "minimum has predecessor")
    local inventoryCountBefore = #normalized.inventory
    local tooLow = MarketEngine.List(normalized, {
        itemId = tradableId,
        price = belowMinimum,
        sellerUid = 123,
    }, now + 1)
    equal(tooLow.ok, false, "minimum minus one rejected")
    equal(tooLow.error.code, "PRICE_BELOW_MINIMUM", "minimum rejection code")
    equal(#normalized.inventory, inventoryCountBefore, "rejected listing keeps input inventory")

    local allowed = MarketEngine.List(normalized, {
        itemId = tradableId,
        price = minimumPrice,
        sellerUid = 123,
    }, now + 1)
    equal(allowed.ok, true, "exact minimum accepted")
    equal(allowed.market.listingRecord.item.tradeable, true, "listing preserves field")
    currencyEqual(allowed.market.listingRecord.minimumPrice, minimumPrice,
        "listing snapshots minimum")
    equal(allowed.market.listingRecord.minimumPriceVersion, 1,
        "listing snapshots formula version")
    equal(allowed.market.listingRecord.tradeableChanceUnits, 1500,
        "listing snapshots probability")

    local artifactId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    local artifactState = StateNormalizer.Normalize(base, now)
    artifactState.inventory = {
        cloneItem(artifactState.inventory[1], artifactId, {
            rarity = "artifact",
            setEnabled = false,
            tradeable = true,
        }),
    }
    local artifactValue = Catalog.GetMarketStandardValue(artifactState.inventory[1])
    local artifactMinimum = MarketCatalog.GetMinimumListingPrice(
        artifactValue,
        "artifact"
    )
    local artifactAllowed = MarketEngine.List(artifactState, {
        itemId = artifactId,
        price = artifactMinimum,
        sellerUid = 123,
    }, now + 1)
    equal(artifactAllowed.ok, true, "artifact listing accepted")
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
