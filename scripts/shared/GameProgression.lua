local GameProgression = {}

function GameProgression.NextExp(level)
    local exponent = math.max(1, tonumber(level) or 1) - 1
    local required = 100 * (1.15 ^ exponent)
    if required ~= required or required == math.huge or required == -math.huge then
        return 1000000000
    end
    return math.min(1000000000, math.floor(required))
end

return GameProgression
