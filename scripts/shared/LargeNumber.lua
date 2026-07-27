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
