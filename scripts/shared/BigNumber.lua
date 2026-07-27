local BigNumber = {}

-- A serializable, non-negative base-10 scientific number.  Keeping the value
-- as a mantissa and exponent lets tower data grow far beyond Lua's double
-- range without ever evaluating an unsafe 10 ^ exponent.
BigNumber.MAX_NUMBER_LOG10 = 308.25471555991675
BigNumber.MIN_NUMBER_LOG10 = -323.3062153431158
BigNumber.MIN_SERIALIZED_EXPONENT = -1000000000
BigNumber.MAX_SERIALIZED_EXPONENT = 1000000000

local LOG10 = math.log(10)

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function zero()
    return { mantissa = 0, exponent = 0 }
end

local function scientific(mantissa, exponent)
    mantissa = tonumber(mantissa) or 0
    exponent = tonumber(exponent) or 0
    if not finite(mantissa) or not finite(exponent) or mantissa <= 0 then
        return zero()
    end

    local shift = math.floor(math.log(mantissa) / LOG10)
    mantissa = mantissa / (10 ^ shift)
    exponent = math.floor(exponent) + shift

    -- Floating-point rounding can put a normalized mantissa on a boundary.
    if mantissa >= 10 then
        mantissa = mantissa / 10
        exponent = exponent + 1
    elseif mantissa < 1 then
        mantissa = mantissa * 10
        exponent = exponent - 1
    end

    return { mantissa = mantissa, exponent = exponent }
end

function BigNumber.Zero()
    return zero()
end

function BigNumber.IsBigNumber(value)
    return type(value) == "table"
        and finite(tonumber(value.mantissa or value.m))
        and finite(tonumber(value.exponent or value.e))
end

-- Network and persistence boundaries must reject aliases and values that the
-- permissive arithmetic parser would otherwise normalize silently.
function BigNumber.ValidateCanonical(value, minimumExponent, maximumExponent)
    if type(value) ~= "table" then
        return false, "Big number must be a table"
    end
    for key in pairs(value) do
        if key ~= "mantissa" and key ~= "exponent" then
            return false, "Big number contains an unknown field"
        end
    end
    if not finite(value.mantissa) or not finite(value.exponent)
        or value.exponent ~= math.floor(value.exponent)
    then
        return false, "Big number must contain a finite mantissa and integer exponent"
    end
    minimumExponent = minimumExponent or BigNumber.MIN_SERIALIZED_EXPONENT
    maximumExponent = maximumExponent or BigNumber.MAX_SERIALIZED_EXPONENT
    if value.exponent < minimumExponent or value.exponent > maximumExponent then
        return false, "Big number exponent is out of range"
    end
    if value.mantissa == 0 then
        if value.exponent ~= 0 then
            return false, "Zero big number must use exponent 0"
        end
        return true
    end
    if value.mantissa < 1 or value.mantissa >= 10 then
        return false, "Big number mantissa must be normalized"
    end
    return true
end

function BigNumber.New(mantissa, exponent)
    return scientific(mantissa, exponent)
end

function BigNumber.FromNumber(value)
    value = tonumber(value) or 0
    if not finite(value) or value <= 0 then return zero() end
    return BigNumber.FromLog10(math.log(value) / LOG10)
end

function BigNumber.FromLog10(logarithm)
    logarithm = tonumber(logarithm)
    if not finite(logarithm) then return zero() end
    local exponent = math.floor(logarithm)
    return scientific(10 ^ (logarithm - exponent), exponent)
end

function BigNumber.Normalize(value)
    if type(value) == "number" then return BigNumber.FromNumber(value) end
    if not BigNumber.IsBigNumber(value) then return zero() end
    return scientific(value.mantissa or value.m, value.exponent or value.e)
end

function BigNumber.Clone(value)
    local normalized = BigNumber.Normalize(value)
    return { mantissa = normalized.mantissa, exponent = normalized.exponent }
end

function BigNumber.Min(left, right)
    if BigNumber.Compare(left, right) <= 0 then return BigNumber.Clone(left) end
    return BigNumber.Clone(right)
end

function BigNumber.Max(left, right)
    if BigNumber.Compare(left, right) >= 0 then return BigNumber.Clone(left) end
    return BigNumber.Clone(right)
end

function BigNumber.IsZero(value)
    return BigNumber.Normalize(value).mantissa == 0
end

function BigNumber.Log10(value)
    local normalized = BigNumber.Normalize(value)
    if normalized.mantissa == 0 then return -math.huge end
    return math.log(normalized.mantissa) / LOG10 + normalized.exponent
end

function BigNumber.ToNumber(value)
    local normalized = BigNumber.Normalize(value)
    if normalized.mantissa == 0 then return 0 end
    local logarithm = BigNumber.Log10(normalized)
    if logarithm > BigNumber.MAX_NUMBER_LOG10 then return nil end
    if logarithm < BigNumber.MIN_NUMBER_LOG10 then return 0 end
    local result = normalized.mantissa * (10 ^ normalized.exponent)
    if not finite(result) then return nil end
    return result
end

function BigNumber.Compare(left, right)
    left = BigNumber.Normalize(left)
    right = BigNumber.Normalize(right)
    if left.mantissa == 0 then return right.mantissa == 0 and 0 or -1 end
    if right.mantissa == 0 then return 1 end
    if left.exponent ~= right.exponent then
        return left.exponent < right.exponent and -1 or 1
    end
    if left.mantissa == right.mantissa then return 0 end
    return left.mantissa < right.mantissa and -1 or 1
end

function BigNumber.Add(left, right)
    left = BigNumber.Normalize(left)
    right = BigNumber.Normalize(right)
    if left.mantissa == 0 then return right end
    if right.mantissa == 0 then return left end
    if left.exponent < right.exponent then left, right = right, left end
    local difference = left.exponent - right.exponent
    if difference > 16 then return left end
    return scientific(left.mantissa + right.mantissa * (10 ^ -difference), left.exponent)
end

function BigNumber.Subtract(left, right)
    left = BigNumber.Normalize(left)
    right = BigNumber.Normalize(right)
    if BigNumber.Compare(left, right) <= 0 then return zero() end
    local difference = left.exponent - right.exponent
    if difference > 16 then return left end
    return scientific(left.mantissa - right.mantissa * (10 ^ -difference), left.exponent)
end

function BigNumber.Floor(value)
    local normalized = BigNumber.Normalize(value)
    if normalized.mantissa == 0 or normalized.exponent < 0 then return zero() end
    -- Above 1e16 a double cannot represent the fractional component anyway.
    if normalized.exponent > 15 then return normalized end
    local number = BigNumber.ToNumber(normalized)
    return number and BigNumber.FromNumber(math.floor(number)) or normalized
end

function BigNumber.Multiply(left, right)
    left = BigNumber.Normalize(left)
    right = BigNumber.Normalize(right)
    if left.mantissa == 0 or right.mantissa == 0 then return zero() end
    return scientific(left.mantissa * right.mantissa, left.exponent + right.exponent)
end

function BigNumber.MultiplyScalar(value, scalar)
    scalar = tonumber(scalar) or 0
    if not finite(scalar) or scalar <= 0 then return zero() end
    local normalized = BigNumber.Normalize(value)
    if normalized.mantissa == 0 then return zero() end
    return scientific(normalized.mantissa * scalar, normalized.exponent)
end

function BigNumber.Divide(left, right)
    left = BigNumber.Normalize(left)
    right = BigNumber.Normalize(right)
    if left.mantissa == 0 or right.mantissa == 0 then return zero() end
    return scientific(left.mantissa / right.mantissa, left.exponent - right.exponent)
end

function BigNumber.Pow(value, power)
    power = tonumber(power)
    if not finite(power) then return zero() end
    local logarithm = BigNumber.Log10(value)
    if logarithm == -math.huge then return power == 0 and BigNumber.FromNumber(1) or zero() end
    return BigNumber.FromLog10(logarithm * power)
end

function BigNumber.LogRatio(left, right)
    local rightLogarithm = BigNumber.Log10(right)
    if rightLogarithm == -math.huge then return nil end
    return BigNumber.Log10(left) - rightLogarithm
end

function BigNumber.Ratio(left, right)
    local logarithm = BigNumber.LogRatio(left, right)
    if logarithm == nil then return nil end
    if logarithm > BigNumber.MAX_NUMBER_LOG10 then return math.huge end
    if logarithm < BigNumber.MIN_NUMBER_LOG10 then return 0 end
    return 10 ^ logarithm
end

function BigNumber.ToScientificString(value, decimals)
    local normalized = BigNumber.Normalize(value)
    if normalized.mantissa == 0 then return "0" end
    decimals = math.max(0, math.min(12, math.floor(tonumber(decimals) or 3)))
    return string.format("%." .. decimals .. "fe%+d", normalized.mantissa, normalized.exponent)
end

function BigNumber.Format(value, significantDigits)
    local normalized = BigNumber.Normalize(value)
    if normalized.mantissa == 0 then return "0" end
    significantDigits = math.max(2, math.min(12, math.floor(tonumber(significantDigits) or 4)))
    local number = BigNumber.ToNumber(normalized)
    if number and normalized.exponent < 6 then
        if normalized.exponent >= 3 then return string.format("%.0f", number) end
        local decimals = math.max(0, significantDigits - normalized.exponent - 1)
        return string.format("%." .. decimals .. "f", number)
    end
    return string.format("%." .. (significantDigits - 1) .. "fe%+d", normalized.mantissa, normalized.exponent)
end

-- Compact monotonic projection for integer-only ranking services. The full
-- value must still be persisted separately because this intentionally loses
-- precision once the exponent reaches the service limit.
function BigNumber.RankScore(value, maximum)
    local normalized = BigNumber.Normalize(value)
    if normalized.mantissa == 0 then return 0 end
    maximum = math.max(0, math.floor(tonumber(maximum) or 2147483647))
    local exponent = math.max(0, normalized.exponent)
    local score = exponent * 1000000 + math.floor(normalized.mantissa * 100000)
    return math.min(maximum, score)
end

return BigNumber
