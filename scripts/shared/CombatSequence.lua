local CombatSequence = {}

CombatSequence.SEQUENCES = {
    {
        id = "attackA",
        frameCount = 48,
        fps = 16,
        hitFrames = { 14, 16, 18, 20 },
        endFrame = 32,
    },
    {
        id = "attackB",
        frameCount = 48,
        fps = 16,
        hitFrames = { 16, 20, 22, 24 },
        endFrame = 36,
    },
    {
        id = "attackC",
        frameCount = 48,
        fps = 16,
        hitFrames = { 12, 14, 16, 18 },
        endFrame = 32,
    },
}

CombatSequence.TRAVEL_SECONDS = 0.55
CombatSequence.MIN_PHASE_SECONDS = 0.08

local function Clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

function CombatSequence.Get(index)
    return CombatSequence.SEQUENCES[index]
end

function CombatSequence.Count()
    return #CombatSequence.SEQUENCES
end

function CombatSequence.RandomAttack(rngInt, previousIndex, attackSpeed)
    local count = CombatSequence.Count()
    local index = rngInt(1, count)
    if count > 1 and previousIndex and index == previousIndex then
        index = index % count + 1
    end

    local sequence = CombatSequence.SEQUENCES[index]
    local hitFrame = sequence.hitFrames[rngInt(1, #sequence.hitFrames)]
    local speed = Clamp(tonumber(attackSpeed) or 1, 0.5, 3.0)
    local windupSeconds = math.max(
        CombatSequence.MIN_PHASE_SECONDS,
        (hitFrame - 1) / sequence.fps / speed
    )
    local recoverySeconds = math.max(
        CombatSequence.MIN_PHASE_SECONDS,
        (sequence.endFrame - hitFrame + 1) / sequence.fps / speed
    )

    return {
        sequenceIndex = index,
        sequenceId = sequence.id,
        frameCount = sequence.frameCount,
        fps = sequence.fps,
        hitFrame = hitFrame,
        endFrame = sequence.endFrame,
        windupSeconds = windupSeconds,
        recoverySeconds = recoverySeconds,
    }
end

return CombatSequence
