local RateLimiter = require("server.core.RateLimiter")

local Spec = {}

function Spec.Run()
    local now = 0
    local limiter = RateLimiter.New({ clock = function() return now end })
    local rule = { refillRate = 0.1, burst = 1 }

    local first = limiter:Check(1, "offline", rule)
    assert(first)

    local second, retryAfter = limiter:Check(1, "offline", rule)
    assert(not second)
    assert(math.abs(retryAfter - 10) < 0.0001)

    now = 9.9
    assert(not limiter:Check(1, "offline", rule))
    now = 10
    assert(limiter:Check(1, "offline", rule))

    assert(limiter:Check(2, "offline", rule))
    limiter:Clear(1)
    assert(limiter:Check(1, "offline", rule))
end

return Spec
