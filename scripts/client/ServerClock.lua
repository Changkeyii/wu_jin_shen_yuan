local ServerClock = {}

local DAY_SECONDS = 24 * 60 * 60
local TIMEZONE_OFFSET_SECONDS = 8 * 60 * 60
local offsetSeconds_ = 0
local synced_ = false

function ServerClock.Sync(serverTime)
    local value = tonumber(serverTime)
    if not value or value <= 0 then return false end
    offsetSeconds_ = math.floor(value) - os.time()
    synced_ = true
    return true
end

function ServerClock.Now()
    return os.time() + (synced_ and offsetSeconds_ or 0)
end

function ServerClock.DayKey(now)
    return math.floor(((tonumber(now) or ServerClock.Now()) + TIMEZONE_OFFSET_SECONDS) / DAY_SECONDS)
end

function ServerClock.Reset()
    offsetSeconds_ = 0
    synced_ = false
end

return ServerClock
