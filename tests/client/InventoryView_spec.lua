local InventoryView = require("client.InventoryView")

local Spec = {}

local function AssertEqual(actual, expected, message)
    assert(
        actual == expected,
        (message or "value mismatch")
            .. ": expected "
            .. tostring(expected)
            .. ", got "
            .. tostring(actual)
    )
end

local function TestShortNamesRemainComplete()
    AssertEqual(
        InventoryView.EllipsizeName(
            "预言戒指",
            8
        ),
        "预言戒指",
        "short Chinese names must remain complete"
    )
end

local function TestLongNamesUseVisibleEllipsis()
    AssertEqual(
        InventoryView.EllipsizeName(
            "吞噬深渊的古代祭祀长袍",
            8
        ),
        "吞噬深渊的古代祭…",
        "long Chinese names must use a visible ellipsis"
    )
end

local function TestMixedUtf8NamesRemainValid()
    AssertEqual(
        InventoryView.EllipsizeName(
            "MK-II深渊核心",
            7
        ),
        "MK-II深渊…",
        "mixed UTF-8 names must be shortened by characters"
    )
end

local function TestHighItemLevelsRemainComplete()
    AssertEqual(
        InventoryView.ItemLevelText({
            level = 1000000,
        }),
        "Lv1000000",
        "item levels must never be abbreviated"
    )
end

function Spec.Run()
    TestShortNamesRemainComplete()
    TestLongNamesUseVisibleEllipsis()
    TestMixedUtf8NamesRemainValid()
    TestHighItemLevelsRemainComplete()
end

return Spec
