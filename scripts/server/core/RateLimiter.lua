local RateLimiter = {}
RateLimiter.__index = RateLimiter

local function defaultClock()
    local timeObject = _G["time"]
    if timeObject and type(timeObject.GetElapsedTime) == "function" then
        local ok, value = pcall(timeObject.GetElapsedTime, timeObject)
        if ok and type(value) == "number" then
            return value
        end
    end
    return os.clock()
end

local function normalizeRule(rule, explicitCost)
    if rule == nil then
        return nil
    end
    if type(rule) == "number" then
        rule = {
            refillRate = rule,
            burst = math.max(1, rule),
        }
    end
    assert(type(rule) == "table", "rate rule must be a number or table")
    local refillRate = tonumber(rule.refillRate or rule.rate or rule.ratePerSecond)
    local burst = tonumber(rule.burst or rule.capacity)
    local cost = tonumber(explicitCost or rule.cost or 1)
    assert(refillRate ~= nil and refillRate >= 0, "refillRate must be non-negative")
    assert(burst ~= nil and burst > 0, "burst must be positive")
    assert(cost ~= nil and cost > 0, "cost must be positive")
    return {
        refillRate = refillRate,
        burst = burst,
        cost = cost,
    }
end

---@param options table|nil
---@return table
function RateLimiter.New(options)
    options = options or {}
    return setmetatable({
        _clock = options.clock or defaultClock,
        _buckets = {},
    }, RateLimiter)
end

---@param uid number|string
---@param action string
---@param rule number|table|nil
---@param explicitCost number|nil
---@return boolean
---@return number
---@return number
function RateLimiter:Check(uid, action, rule, explicitCost)
    local normalized = normalizeRule(rule, explicitCost)
    if normalized == nil then
        return true, 0, math.huge
    end
    assert(uid ~= nil, "uid is required")
    assert(type(action) == "string" and action ~= "", "action is required")

    local playerKey = tostring(uid)
    local playerBuckets = self._buckets[playerKey]
    if playerBuckets == nil then
        playerBuckets = {}
        self._buckets[playerKey] = playerBuckets
    end

    local now = self._clock()
    local bucket = playerBuckets[action]
    if bucket == nil then
        bucket = {
            tokens = normalized.burst,
            lastRefill = now,
            refillRate = normalized.refillRate,
            burst = normalized.burst,
        }
        playerBuckets[action] = bucket
    else
        local elapsed = math.max(0, now - bucket.lastRefill)
        bucket.tokens = math.min(
            normalized.burst,
            bucket.tokens + elapsed * bucket.refillRate
        )
        bucket.lastRefill = now
        bucket.refillRate = normalized.refillRate
        bucket.burst = normalized.burst
        bucket.tokens = math.min(bucket.tokens, bucket.burst)
    end

    if bucket.tokens >= normalized.cost then
        bucket.tokens = bucket.tokens - normalized.cost
        return true, 0, bucket.tokens
    end

    local missing = normalized.cost - bucket.tokens
    local retryAfter = math.huge
    if normalized.refillRate > 0 then
        retryAfter = missing / normalized.refillRate
    end
    return false, retryAfter, bucket.tokens
end

RateLimiter.TryConsume = RateLimiter.Check

---@param uid number|string
---@param action string|nil
function RateLimiter:Clear(uid, action)
    local playerKey = tostring(uid)
    if action == nil then
        self._buckets[playerKey] = nil
        return
    end
    local playerBuckets = self._buckets[playerKey]
    if playerBuckets ~= nil then
        playerBuckets[action] = nil
        if next(playerBuckets) == nil then
            self._buckets[playerKey] = nil
        end
    end
end

function RateLimiter:Reset()
    self._buckets = {}
end

local defaultLimiter = RateLimiter.New()
local Module = {
    New = RateLimiter.New,
    Class = RateLimiter,
    Default = defaultLimiter,
}

for _, methodName in ipairs({ "Check", "TryConsume", "Clear", "Reset" }) do
    Module[methodName] = function(...)
        return defaultLimiter[methodName](defaultLimiter, ...)
    end
end

return Module
