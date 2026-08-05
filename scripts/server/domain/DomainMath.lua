local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local BigNumber = require("shared.BigNumber")

local DomainMath = {}

function DomainMath.Magnitude(bigValue, numberValue, fallback)
    if BigNumber.IsBigNumber(bigValue) then return BigNumber.Normalize(bigValue) end
    if BigNumber.IsBigNumber(numberValue) then return BigNumber.Normalize(numberValue) end
    if type(numberValue) == "number" and numberValue == numberValue
        and numberValue ~= math.huge and numberValue ~= -math.huge and numberValue >= 0
    then
        return BigNumber.FromNumber(numberValue)
    end
    return BigNumber.Clone(fallback or BigNumber.Zero())
end

function DomainMath.ProjectedMagnitude(value)
    return BigNumber.ToNumber(value)
end

function DomainMath.FloorDamage(value)
    return BigNumber.Max(BigNumber.Floor(value), BigNumber.FromNumber(1))
end

function DomainMath.StatMagnitude(stats, field)
    stats = type(stats) == "table" and stats or {}
    return DomainMath.Magnitude(stats[field .. "Big"], stats[field], 0)
end

function DomainMath.SetPlayerHp(state, value)
    state.hpBig = BigNumber.Clone(value)
    state.hp = DomainMath.ProjectedMagnitude(state.hpBig)
end

function DomainMath.SetMonsterMagnitude(monster, field, value)
    monster[field .. "Big"] = BigNumber.Clone(value)
    monster[field] = DomainMath.ProjectedMagnitude(value)
end

function DomainMath.AddMagnitudeFields(payload, field, bigField, value)
    payload[field] = DomainMath.ProjectedMagnitude(value)
    payload[bigField] = BigNumber.Clone(value)
    return payload
end

function DomainMath.DisplayedPowerDelta(before, after)
    local oldPower = DomainMath.Magnitude(
        before and before.displayedPower,
        before and before.displayedPowerNumber,
        0)
    local newPower = DomainMath.Magnitude(
        after and after.displayedPower,
        after and after.displayedPowerNumber,
        oldPower)
    return BigNumber.Subtract(newPower, oldPower)
end

function DomainMath.MultiplyItemMagnitude(item, field, scalar)
    local value = BigNumber.MultiplyScalar(
        DomainMath.Magnitude(item[field .. "Big"], item[field], 0), scalar)
    item[field .. "Big"] = value
    item[field] = DomainMath.ProjectedMagnitude(value)
end

function DomainMath.RandomInt(rng, minimum, maximum)
    local value
    if type(rng) == "table" and type(rng.Int) == "function" then
        value = rng:Int(minimum, maximum)
    elseif type(rng) == "table" and type(rng.NextInt) == "function" then
        value = rng:NextInt(minimum, maximum)
    elseif type(rng) == "function" then
        value = rng(minimum, maximum)
    else
        value = math.random(minimum, maximum)
    end
    value = TableUtils.ToInteger(value, minimum)
    return Catalog.Clamp(value, minimum, maximum)
end

function DomainMath.RandomFloat(rng)
    local value
    if type(rng) == "table" and type(rng.Float) == "function" then
        value = rng:Float()
    elseif type(rng) == "table" and type(rng.NextFloat) == "function" then
        value = rng:NextFloat()
    elseif type(rng) == "function" then
        value = rng()
    else
        value = math.random()
    end
    if not TableUtils.IsFiniteNumber(value) then value = 0 end
    return Catalog.Clamp(value, 0, 0.999999999)
end

return DomainMath
