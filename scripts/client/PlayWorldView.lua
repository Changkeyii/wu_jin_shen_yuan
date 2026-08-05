local PlayWorldView = {}

local ports_ = nil
local refs_ = {}
local currentPlayerImage_ = nil

local ATTACK_ANIMATION_SPEED_MULTIPLIER = 1.2

local function Clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function MovementFrame(frames, fps, animationTime, fallback)
    if not frames or #frames == 0 then return fallback end
    local index = math.floor((animationTime or 0) * (fps or 8)) % #frames + 1
    return frames[index]
end

local function AttackFrame(state)
    local frames = state.attackFrames
    if not frames or #frames == 0 then return state.fallbackImage end
    local hitFrame = Clamp(state.hitFrame or 1, 1, #frames)
    local endFrame = Clamp(state.endFrame or #frames, hitFrame, #frames)
    local windup = math.max(
        0.001,
        (state.windupSeconds or 0) / ATTACK_ANIMATION_SPEED_MULTIPLIER
    )
    local recovery = math.max(
        0.001,
        (state.recoverySeconds or 0) / ATTACK_ANIMATION_SPEED_MULTIPLIER
    )
    local frame
    if state.sequenceTime < windup then
        local progress = Clamp(state.sequenceTime / windup, 0, 1)
        frame = 1 + math.floor(progress * (hitFrame - 1))
    else
        local progress = Clamp((state.sequenceTime - windup) / recovery, 0, 1)
        frame = hitFrame + math.floor(progress * (endFrame - hitFrame))
    end
    return frames[Clamp(frame, 1, endFrame)]
end

function PlayWorldView.Configure(ports)
    ports_ = assert(ports)
end

function PlayWorldView.Build(metrics)
    local UI = ports_.UI
    local assets = ports_.assets
    refs_ = {bgTiles = {}, objects = {}}
    currentPlayerImage_ = nil
    refs_.bgTiles[1] = UI.Panel {
        position = "absolute", left = 0, top = ports_.bgTileTop,
        width = ports_.bgTileW, height = ports_.bgTileH,
        backgroundImage = assets.bg, backgroundFit = "cover",
    }
    refs_.bgTiles[2] = UI.Panel {
        position = "absolute", left = ports_.bgTileW, top = ports_.bgTileTop,
        width = ports_.bgTileW, height = ports_.bgTileH,
        backgroundImage = assets.bgMirror, backgroundFit = "cover",
    }
    refs_.bgTiles[3] = UI.Panel {
        position = "absolute", left = ports_.bgTileW * 2, top = ports_.bgTileTop,
        width = ports_.bgTileW, height = ports_.bgTileH,
        backgroundImage = assets.bg, backgroundFit = "cover",
    }
    refs_.playerShadow = UI.Panel {
        position = "absolute",
        left = metrics.playerScreenX + 168,
        top = metrics.roadY - 12,
        width = 118, height = 14,
        backgroundImage = assets.ui.characterShadow,
        backgroundFit = "contain",
    }
    local player = ports_.currentPlayer()
    refs_.player = UI.Panel {
        position = "absolute",
        left = metrics.playerScreenX,
        top = metrics.platformPlayerY,
        width = ports_.runW, height = ports_.runH,
        backgroundImage = player.sprite or player.icon,
        backgroundFit = "contain",
    }
    for index = 1, ports_.eventViewCount do
        refs_.objects[index] = UI.Panel {
            position = "absolute", left = 0, top = 0,
            width = ports_.enemySize, height = ports_.enemySize,
            backgroundImage = assets.enemies.slime,
            backgroundFit = "contain", visible = true,
        }
    end
    local nodes = {refs_.bgTiles[1], refs_.bgTiles[2], refs_.bgTiles[3]}
    for _, node in ipairs(refs_.objects) do nodes[#nodes + 1] = node end
    nodes[#nodes + 1] = refs_.playerShadow
    nodes[#nodes + 1] = refs_.player
    return nodes
end

function PlayWorldView.Update(state)
    if not refs_.player then return end
    local bgShift = -(state.presentationX % (ports_.bgTileW * 2))
    refs_.bgTiles[1]:SetStyle({left = bgShift, top = 0, height = state.metrics.height})
    refs_.bgTiles[2]:SetStyle({left = bgShift + ports_.bgTileW, top = 0, height = state.metrics.height})
    refs_.bgTiles[3]:SetStyle({left = bgShift + ports_.bgTileW * 2, top = 0, height = state.metrics.height})

    local player = ports_.currentPlayer()
    local movementFrames = state.visualAutoRun and player.run or player.idle
    local playerImage = state.isAttacking
        and AttackFrame {
            attackFrames = state.attackFrames,
            fallbackImage = player.icon,
            hitFrame = state.hitFrame,
            endFrame = state.endFrame,
            windupSeconds = state.windupSeconds,
            recoverySeconds = state.recoverySeconds,
            sequenceTime = state.sequenceTime,
        }
        or MovementFrame(movementFrames, state.activeFps, state.animationTime, player.icon)
    local walkBob = (state.visualAutoRun and not state.isAttacking)
        and math.sin(state.animationTime * 6.0) * 3
        or math.sin(state.animationTime * 2.0) * 2
    local walkLean = (state.visualAutoRun and not state.isAttacking)
        and math.sin(state.animationTime * 6.0) * 4
        or 0
    local attackPulse = state.isAttacking
        and math.max(0, math.sin(
            state.combatAnimationTime * 11.0 * ATTACK_ANIMATION_SPEED_MULTIPLIER
        ))
        or 0
    local actionLeft = state.playerScreenX - (ports_.runW - ports_.playerSize) * 0.42
    local actionTop = state.roadY - ports_.runH + 20
    local useActionBox = state.isAttacking or not state.isPicking
    local targetLeft = useActionBox and (actionLeft + state.activeParams.x) or state.playerScreenX
    local targetTop = useActionBox and (actionTop + state.activeParams.y) or state.platformPlayerY
    local targetW = useActionBox and state.activeParams.w or ports_.playerSize
    local targetH = useActionBox and state.activeParams.h or ports_.playerSize
    local targetScale = useActionBox and state.activeParams.scale or 1.0
    local playerStyle = {
        left = targetLeft + walkLean + attackPulse * 3,
        top = targetTop + walkBob - attackPulse * 2,
        width = targetW, height = targetH,
        scale = targetScale + (state.isAttacking and attackPulse * 0.04 or 0),
    }
    if playerImage ~= currentPlayerImage_ then
        playerStyle.backgroundImage = playerImage
        currentPlayerImage_ = playerImage
    end
    refs_.player:SetStyle(playerStyle)
    refs_.playerShadow:SetStyle({
        left = state.playerScreenX + 42 + walkLean + attackPulse * 3,
        top = state.roadY - 8,
    })

    for index, node in ipairs(refs_.objects) do
        local event = state.roadEvents[index]
        if event then
            local x = event.x - state.presentationX
            local size = event.kind == "enemy" and ports_.enemySize or ports_.lootSize
            local top = event.kind == "enemy"
                and (state.roadY - ports_.enemySize + ports_.enemyFootOffset(event.eventType))
                or (state.roadY - ports_.lootSize + ports_.lootFootOffset)
            local active = index == 1 and (state.isAttacking or state.isPicking)
            local pulse = active and math.sin(state.animationTime * 18) * 5 or 0
            node:SetStyle({
                visible = x > -180 and x < 1180,
                left = x, top = top + pulse,
                width = size, height = size,
                backgroundImage = event.image,
                opacity = index == 1 and state.isAttacking and 0.86 or 1.0,
                scale = active and 1.05 or 1.0,
            })
        else
            node:SetStyle({visible = false})
        end
    end
end

function PlayWorldView.Reset()
    refs_ = {}
    currentPlayerImage_ = nil
end

return PlayWorldView
