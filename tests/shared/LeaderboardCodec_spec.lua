local Spec = {}

local MODULE_NAME = "shared.LeaderboardCodec"

local function FreshCodec()
    package.loaded[MODULE_NAME] = nil
    return require(MODULE_NAME)
end

local function AssertItem(actual, expected, message)
    assert(actual ~= nil, (message or "item") .. " is nil")
    for key, value in pairs(expected) do
        if type(value) == "number" then
            assert(math.abs((actual[key] or 0) - value) < 1e-4,
                (message or "item") .. " field " .. tostring(key) .. " mismatch: "
                .. tostring(actual[key]) .. " != " .. tostring(value))
        elseif type(value) == "boolean" then
            assert(actual[key] == value,
                (message or "item") .. " field " .. tostring(key) .. " mismatch")
        else
            assert(actual[key] == value,
                (message or "item") .. " field " .. tostring(key) .. " mismatch: "
                .. tostring(actual[key]) .. " != " .. tostring(value))
        end
    end
end

local function TestRoundTrip()
    local Codec = FreshCodec()
    local items = {
        {
            slot = "weapon",
            equipmentId = "sword_1",
            rarity = "epic",
            level = 12,
            enhance = 3,
            star = 2,
            quantity = 1,
            setId = "abyss",
            setEnabled = true,
            source = "boss_drop",
            atkBig = { mantissa = 5.234, exponent = 7 },
            defBig = { mantissa = 0, exponent = 0 },
            hpBig = 25000,
            crit = 0.15,
            critDmg = 0.5,
            atkSpeed = 0.12,
            lifeSteal = 0.03,
            damageReduction = 0.08,
            bossDamage = 0.2,
            coreAffixes = { "core.fury", "core.swiftness" },
            uniqueEffects = { "myth.tower_soul_resonance" },
        },
        {
            slot = "necklace",
            equipmentId = "necklace_7",
            rarity = "legendary",
            level = 20,
            enhance = 0,
            star = 1,
            quantity = 1,
            atkBig = 1234567,
            defBig = 890,
            hpBig = 0,
            crit = 0.0,
            critDmg = 0.0,
            atkSpeed = 0.0,
            lifeSteal = 0.0,
            damageReduction = 0.0,
            bossDamage = 0.0,
        },
    }

    local blob = Codec.Pack(items)
    assert(type(blob) == "string" and #blob > 0, "pack produced empty blob")

    local hex = Codec.ToHex(blob)
    assert(#hex == #blob * 2, "hex length mismatch")

    local decoded, err = Codec.Unpack(Codec.FromHex(hex))
    assert(decoded ~= nil, "unpack failed: " .. tostring(err))
    assert(#decoded == 2, "decoded count mismatch: " .. tostring(#decoded))

    AssertItem(decoded[1], {
        slot = "weapon",
        equipmentId = "sword_1",
        rarity = "epic",
        level = 12,
        enhance = 3,
        star = 2,
        quantity = 1,
        setId = "abyss",
        setEnabled = true,
        source = "boss_drop",
        crit = 0.15,
        critDmg = 0.5,
        atkSpeed = 0.12,
        lifeSteal = 0.03,
        damageReduction = 0.08,
        bossDamage = 0.2,
    }, "item 1")
    assert(decoded[1].coreAffixes[1] == "core.fury" and decoded[1].coreAffixes[2] == "core.swiftness",
        "item 1 coreAffixes mismatch")
    assert(decoded[1].uniqueEffects[1] == "myth.tower_soul_resonance",
        "item 1 uniqueEffects mismatch")
    assert(math.abs(decoded[1].atkBig.mantissa - 5.234) < 1e-4
        and decoded[1].atkBig.exponent == 7, "item 1 atkBig magnitude mismatch")
    assert(decoded[1].defBig.mantissa == 0, "item 1 defBig zero mismatch")
    assert(math.abs(decoded[1].hpBig.mantissa - 2.5) < 1e-4
        and decoded[1].hpBig.exponent == 4, "item 1 hpBig magnitude mismatch")

    AssertItem(decoded[2], {
        slot = "necklace",
        equipmentId = "necklace_7",
        rarity = "legendary",
        level = 20,
        enhance = 0,
        star = 1,
        quantity = 1,
        crit = 0.0,
    }, "item 2")
    assert(decoded[2].setId == nil, "item 2 setId should be nil")
    assert(decoded[2].source == nil, "item 2 source should be nil")
end

local function TestCorruptBlob()
    local Codec = FreshCodec()
    local items, err = Codec.Unpack("")
    assert(items == nil and err ~= nil, "empty blob must fail")

    local bad, err2 = Codec.Unpack("zz")
    assert(bad == nil and err2 ~= nil, "non-binary blob must fail")
end

local function TestMaxItems()
    local Codec = FreshCodec()
    local many = {}
    for index = 1, 20 do
        many[index] = { slot = "weapon", equipmentId = "w" .. tostring(index), rarity = "common", level = 1 }
    end
    local blob = Codec.Pack(many)
    local decoded = Codec.Unpack(blob)
    assert(decoded ~= nil and #decoded == Codec.MAX_ITEMS,
        "should cap at MAX_ITEMS, got " .. tostring(decoded and #decoded))
end

function Spec.Run()
    local oldModule = package.loaded[MODULE_NAME]
    local ok, reason = pcall(function()
        TestRoundTrip()
        TestCorruptBlob()
        TestMaxItems()
    end)
    package.loaded[MODULE_NAME] = oldModule
    assert(ok, reason)
end

return Spec
