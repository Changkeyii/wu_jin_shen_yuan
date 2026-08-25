local ServerClock = require("client.ServerClock")

local CountdownPresenter = {}

function CountdownPresenter.RemainingAt(expiresAt, now)
    return math.max(0, math.floor((tonumber(expiresAt) or 0) - (tonumber(now) or ServerClock.Now())))
end

function CountdownPresenter.FormatRemainingAt(expiresAt, now)
    local remaining = CountdownPresenter.RemainingAt(expiresAt, now)
    local hours = math.floor(remaining / 3600)
    local minutes = math.floor((remaining % 3600) / 60)
    local seconds = remaining % 60
    if hours > 0 then return string.format("%d:%02d:%02d", hours, minutes, seconds) end
    return string.format("%d:%02d", minutes, seconds)
end

function CountdownPresenter.CreateLocalAnchor(seconds, now)
    return (tonumber(now) or ServerClock.Now()) + math.max(0, tonumber(seconds) or 0)
end

return CountdownPresenter
