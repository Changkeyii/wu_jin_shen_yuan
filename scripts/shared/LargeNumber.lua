local BigNumber = require("shared.BigNumber")

local LargeNumber = {}

LargeNumber.BASE = 1000000000
LargeNumber.SEGMENT_MAX = LargeNumber.BASE - 1
LargeNumber.MAX_SAFE_INTEGER = 9007199254740991
LargeNumber.MAX_CLOUD_INTEGER = 2147483647

local DISPLAY_UNITS = { "", "万", "亿", "兆", "京", "垓", "秭" }

local function segment(value)
    value = tonumber(value) or 0
    if value ~= value or value == math.huge or value == -math.huge then return 0 end
    return math.max(0, math.min(LargeNumber.SEGMENT_MAX, math.floor(value)))
end

local function currency(high, mid, low)
    return {
        high = segment(high),
        mid = segment(mid),
        low = segment(low),
    }
end

function LargeNumber.Clamp(value)
    value = tonumber(value) or 0
    if value ~= value or value == math.huge or value == -math.huge then return 0 end
    return math.max(0, math.min(LargeNumber.MAX_SAFE_INTEGER, math.floor(value)))
end

function LargeNumber.Zero()
    return currency(0, 0, 0)
end

function LargeNumber.FromSegments(high, mid, low)
    return currency(high, mid, low)
end

function LargeNumber.FromNumber(value)
    value = LargeNumber.Clamp(value)
    local mid = math.floor(value / LargeNumber.BASE)
    local low = value - mid * LargeNumber.BASE
    return currency(0, mid, low)
end

function LargeNumber.FromString(value)
    local text = tostring(value or ""):match("^%s*(.-)%s*$")
    if text == nil or text == "" or text:match("^%d+$") == nil then
        return nil, "金额必须是整数"
    end
    text = text:gsub("^0+", "")
    if text == "" then return LargeNumber.Zero() end
    if #text > 27 then return nil, "金额超出可表示范围" end
    text = string.rep("0", 27 - #text) .. text
    return currency(
        tonumber(text:sub(1, 9)) or 0,
        tonumber(text:sub(10, 18)) or 0,
        tonumber(text:sub(19, 27)) or 0
    )
end

function LargeNumber.IsLargeNumber(value)
    return type(value) == "table"
        and value.high ~= nil
        and value.mid ~= nil
        and value.low ~= nil
end

function LargeNumber.Max()
    return currency(
        LargeNumber.SEGMENT_MAX,
        LargeNumber.SEGMENT_MAX,
        LargeNumber.SEGMENT_MAX
    )
end

function LargeNumber.IsZero(value)
    if type(value) ~= "table" then
        value = tonumber(value) or 0
        return value <= 0 or value ~= value
    end
    value = LargeNumber.Normalize(value)
    return value.high == 0 and value.mid == 0 and value.low == 0
end

-- Converts the non-negative scientific representation used by tower growth
-- into the fixed 27-digit currency container without routing through an
-- unsafe Lua integer. Values at or above 1e27 saturate by design.
function LargeNumber.FromBigNumber(value)
    local normalized = BigNumber.Floor(value)
    if BigNumber.IsZero(normalized) then return LargeNumber.Zero() end
    if normalized.exponent >= 27 then return LargeNumber.Max() end
    if normalized.exponent < 0 then return LargeNumber.Zero() end

    local coefficient = string.format("%.15f", normalized.mantissa)
        :gsub("%.", "")
        :gsub("0+$", "")
    if coefficient == "" then return LargeNumber.Zero() end

    local digitCount = normalized.exponent + 1
    local digits
    if #coefficient >= digitCount then
        digits = coefficient:sub(1, digitCount)
    else
        digits = coefficient .. string.rep("0", digitCount - #coefficient)
    end
    digits = string.rep("0", 27 - #digits) .. digits

    return currency(
        tonumber(digits:sub(1, 9)) or 0,
        tonumber(digits:sub(10, 18)) or 0,
        tonumber(digits:sub(19, 27)) or 0
    )
end

function LargeNumber.ToBigNumber(value)
    value = LargeNumber.Normalize(value)
    if LargeNumber.IsZero(value) then return BigNumber.Zero() end
    local text = LargeNumber.ToString(value)
    local leading = text:sub(1, math.min(16, #text))
    local mantissa = tonumber(leading) / (10 ^ (#leading - 1))
    return BigNumber.New(mantissa, #text - 1)
end

function LargeNumber.ToSafeNumber(value)
    if type(value) ~= "table" then return LargeNumber.Clamp(value) end
    value = LargeNumber.Normalize(value)
    if value.high > 0 then return LargeNumber.MAX_SAFE_INTEGER end
    local result = value.mid * LargeNumber.BASE + value.low
    return math.min(LargeNumber.MAX_SAFE_INTEGER, result)
end

function LargeNumber.Normalize(value)
    if type(value) ~= "table" then return LargeNumber.Zero() end
    return currency(value.high, value.mid, value.low)
end

function LargeNumber.Compare(left, right)
    left = LargeNumber.Normalize(left)
    right = type(right) == "table" and LargeNumber.Normalize(right) or LargeNumber.FromNumber(right)
    if left.high ~= right.high then return left.high < right.high and -1 or 1 end
    if left.mid ~= right.mid then return left.mid < right.mid and -1 or 1 end
    if left.low ~= right.low then return left.low < right.low and -1 or 1 end
    return 0
end

function LargeNumber.Add(left, right)
    left = LargeNumber.Normalize(left)
    right = type(right) == "table" and LargeNumber.Normalize(right) or LargeNumber.FromNumber(right)

    local low = left.low + right.low
    local carry = math.floor(low / LargeNumber.BASE)
    low = low % LargeNumber.BASE

    local mid = left.mid + right.mid + carry
    carry = math.floor(mid / LargeNumber.BASE)
    mid = mid % LargeNumber.BASE

    local high = left.high + right.high + carry
    if high >= LargeNumber.BASE then
        return currency(LargeNumber.SEGMENT_MAX, LargeNumber.SEGMENT_MAX, LargeNumber.SEGMENT_MAX)
    end
    return currency(high, mid, low)
end

function LargeNumber.MultiplyRatio(value, numerator, denominator)
    value = LargeNumber.Normalize(value)
    numerator = math.max(0, math.floor(tonumber(numerator) or 0))
    denominator = math.max(1, math.floor(tonumber(denominator) or 1))
    if numerator == 0 or LargeNumber.IsZero(value) then
        return LargeNumber.Zero()
    end

    local function multiplySegment(segmentValue, carry)
        local product = segmentValue * numerator + carry
        return product % LargeNumber.BASE, math.floor(product / LargeNumber.BASE)
    end

    local low, carry = multiplySegment(value.low, 0)
    local mid
    mid, carry = multiplySegment(value.mid, carry)
    local high
    high, carry = multiplySegment(value.high, carry)
    if carry > 0 or high >= LargeNumber.BASE then return LargeNumber.Max() end

    local function divideStep(remainder, segmentValue)
        local combined = remainder * LargeNumber.BASE + segmentValue
        return math.floor(combined / denominator), combined % denominator
    end

    local quotientHigh, remainder = divideStep(0, high)
    local quotientMid
    quotientMid, remainder = divideStep(remainder, mid)
    local quotientLow
    quotientLow = divideStep(remainder, low)
    return currency(quotientHigh, quotientMid, quotientLow)
end

function LargeNumber.MultiplyScalar(value, scalar)
    scalar = tonumber(scalar) or 0
    if scalar <= 0 or scalar ~= scalar
        or scalar == math.huge or scalar == -math.huge
    then
        return LargeNumber.Zero()
    end
    return LargeNumber.FromBigNumber(
        BigNumber.MultiplyScalar(LargeNumber.ToBigNumber(value), scalar)
    )
end

function LargeNumber.Subtract(left, right)
    left = LargeNumber.Normalize(left)
    right = type(right) == "table" and LargeNumber.Normalize(right) or LargeNumber.FromNumber(right)
    if LargeNumber.Compare(left, right) < 0 then return LargeNumber.Zero(), false end

    local high = left.high
    local mid = left.mid
    local low = left.low - right.low
    if low < 0 then
        low = low + LargeNumber.BASE
        mid = mid - 1
    end
    mid = mid - right.mid
    if mid < 0 then
        mid = mid + LargeNumber.BASE
        high = high - 1
    end
    high = high - right.high
    return currency(high, mid, low), true
end

function LargeNumber.ToString(value)
    value = LargeNumber.Normalize(value)
    if value.high > 0 then
        return string.format("%d%09d%09d", value.high, value.mid, value.low)
    end
    if value.mid > 0 then
        return string.format("%d%09d", value.mid, value.low)
    end
    return tostring(value.low)
end

function LargeNumber.Split(value)
    value = LargeNumber.Clamp(value)
    local high = math.floor(value / LargeNumber.BASE)
    local low = value - high * LargeNumber.BASE
    return high, low
end

function LargeNumber.Join(high, low)
    high = math.max(0, math.floor(tonumber(high) or 0))
    low = math.max(0, math.floor(tonumber(low) or 0))
    return LargeNumber.Clamp(high * LargeNumber.BASE + low)
end

function LargeNumber.RankScore(value)
    value = LargeNumber.Clamp(value)
    if value <= 0 then return 0 end
    local exponent = math.floor(math.log(value) / math.log(10))
    local mantissa = math.floor(value / (10 ^ exponent) * 10000000)
    return math.min(LargeNumber.MAX_CLOUD_INTEGER, exponent * 100000000 + mantissa)
end

local function formatCurrency(value)
    local text = LargeNumber.ToString(value)
    local unitIndex = math.floor((#text - 1) / 4) + 1
    if unitIndex <= 1 then return text end
    unitIndex = math.min(unitIndex, #DISPLAY_UNITS)

    local wholeDigits = ((#text - 1) % 4) + 1
    local decimalDigits = wholeDigits >= 3 and 0 or (wholeDigits == 2 and 1 or 2)
    local significant = text:sub(1, wholeDigits + decimalDigits)
    local scaled = tonumber(significant) / (10 ^ decimalDigits)
    local format = decimalDigits == 0 and "%.0f%s" or (decimalDigits == 1 and "%.1f%s" or "%.2f%s")
    return string.format(format, scaled, DISPLAY_UNITS[unitIndex])
end

function LargeNumber.Format(value)
    if type(value) == "table" then return formatCurrency(value) end
    value = LargeNumber.Clamp(value)
    local unitIndex = 1
    local scaled = value
    while scaled >= 10000 and unitIndex < #DISPLAY_UNITS do
        scaled = scaled / 10000
        unitIndex = unitIndex + 1
    end
    if unitIndex == 1 then return tostring(value) end
    if scaled >= 100 then return string.format("%.0f%s", scaled, DISPLAY_UNITS[unitIndex]) end
    if scaled >= 10 then return string.format("%.1f%s", scaled, DISPLAY_UNITS[unitIndex]) end
    return string.format("%.2f%s", scaled, DISPLAY_UNITS[unitIndex])
end

return LargeNumber
