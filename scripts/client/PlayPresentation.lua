local PlayPresentation = {}
local CombatSequence = require("shared.CombatSequence")
local BigNumber = require("shared.BigNumber")
local PlayEffects = require("client.PlayEffects")
local PlayHud = require("client.PlayHud")
local PlayWorldView = require("client.PlayWorldView")

local context_ = nil
local refs_ = {}
local roadEvents_ = {}
local activeRouteId_ = nil
local pendingEncounterId_ = nil
local transitioningFloor_ = nil
local presentationX_ = 0
local animationTime_ = 0
local combatAnimationTime_ = 0
local combatSequenceStartTime_ = 0
local combatSequenceIndex_ = nil
local combatHitFrame_ = nil
local combatEndFrame_ = nil
local combatWindupSeconds_ = 0
local combatRecoverySeconds_ = 0
local lastAttackSoundKey_ = nil
local lastLootSoundKey_ = nil
local currentMonsterHp_ = 0
local currentMonsterMaxHp_ = 1
local currentEventLocked_ = false
local currentAttackFrames_ = nil
local finisherGhostTimer_ = 0
local rewardOrigin_ = nil
local lastEventType_ = "monster"
local requestedAutoRun_ = nil
local pendingAutoRun_ = nil
local sessionAutoStartAttempted_ = false

local metrics_ = { width = 1080, height = 1400, enemyAnchorX = 820 }
local Clamp

-- 前向声明：终结技大范围特效，实现在 CreatePage 之后。
local spawnFinisherEffect = nil

local function C()
    return context_.colors
end

local function MagnitudeRatio(value, maximum)
    if type(value) == "table" or type(maximum) == "table" then
        return Clamp(BigNumber.Ratio(value or 0, maximum or 1) or 0, 0, 1)
    end
    return Clamp((value or 0) / math.max(1, maximum or 1), 0, 1)
end

local function Assets()
    return context_.assets
end

local function Game()
    return context_.getGame()
end

Clamp = function(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function EnemyFootOffset(eventType)
    return eventType == "boss" and 7 or 12
end

local function EnemyImageForStep(step, eventType)
    local assets = Assets()
    if eventType == "boss" then return assets.enemies.boss end
    if eventType == "elite" then return assets.enemies.skeleton end
    local value = step % 3
    if value == 0 then return assets.enemies.slime end
    if value == 1 then return assets.enemies.goblin end
    return assets.enemies.skeleton
end

local function EncounterStopDistance(route, room)
    local encounter = route
        and route.encounters
        and route.encounters[room]
    local distance = encounter and tonumber(encounter.distance)
    if not distance then return nil end

    local triggerDistance = tonumber(route.triggerDistance)
        or context_.eventTriggerDistance
        or 0
    return math.max(0, distance - triggerDistance)
end

local function CurrentFloorRouteStep(game)
    local position = Clamp(
        math.floor(tonumber(game.position) or 0),
        0,
        10
    )
    if position >= 10 then return 10 end

    local route = game.floorRoute
    local fromDistance = position == 0
        and 0
        or EncounterStopDistance(route, position)
    local toDistance = EncounterStopDistance(route, position + 1)
    if not fromDistance
        or not toDistance
        or toDistance <= fromDistance
    then
        return position
    end

    local movementProgress = Clamp(
        (presentationX_ - fromDistance)
            / (toDistance - fromDistance),
        0,
        1
    )
    return position + movementProgress
end

local function ApplyFloorRoute(route, position, currentMonster)
    if type(route) ~= "table" or type(route.encounters) ~= "table" then
        return false
    end
    position = math.max(0, math.floor(tonumber(position) or 0))
    local firstRoom = currentMonster and position or (position + 1)
    if activeRouteId_ == route.routeId
        and roadEvents_[1]
        and roadEvents_[1].room == firstRoom
    then
        for _, event in ipairs(roadEvents_) do
            event.x = context_.playerScreenX + event.distance
        end
        return true
    end
    activeRouteId_ = route.routeId
    pendingEncounterId_ = nil
    local completedEncounter = route.encounters[position]
    presentationX_ = completedEncounter
        and math.max(0, completedEncounter.distance - route.triggerDistance)
        or 0
    roadEvents_ = {}
    for _, encounter in ipairs(route.encounters) do
        if encounter.room >= firstRoom then
            roadEvents_[#roadEvents_ + 1] = {
                id = encounter.encounterId,
                encounterId = encounter.encounterId,
                room = encounter.room,
                distance = encounter.distance,
                x = context_.playerScreenX + encounter.distance,
                kind = "enemy",
                eventType = encounter.eventType,
                image = EnemyImageForStep(encounter.room, encounter.eventType),
            }
        end
    end
    if transitioningFloor_ == route.floor then
        context_.loadingController.CompleteFloorTransition(route.floor)
        transitioningFloor_ = nil
    end
    return true
end

local function EnsureRoadEvents()
    local game = Game()
    ApplyFloorRoute(game.floorRoute, game.position or 0, game.currentMonster)
end

local function AlignCurrentRoadEvent(eventType)
    EnsureRoadEvents()
    local current = roadEvents_[1]
    if not current then return end
    current.kind = "enemy"
    current.eventType = eventType
    current.image = EnemyImageForStep(current.room or 1, eventType)
end

local function AdvanceRoadEvent()
    local current = roadEvents_[1]
    if current then
        pendingEncounterId_ = nil
        table.remove(roadEvents_, 1)
    end
    currentEventLocked_ = false
    currentAttackFrames_ = nil
end

local function ClearCombatPresentation(advanceLockedEvent)
    if advanceLockedEvent and currentEventLocked_ and roadEvents_[1] and roadEvents_[1].kind == "enemy" then
        AdvanceRoadEvent()
    else
        currentEventLocked_ = false
        currentAttackFrames_ = nil
    end
    combatAnimationTime_ = 0
    combatSequenceStartTime_ = 0
    combatSequenceIndex_ = nil
    combatHitFrame_ = nil
    combatEndFrame_ = nil
    combatWindupSeconds_ = 0
    combatRecoverySeconds_ = 0
    lastAttackSoundKey_ = nil
    currentMonsterHp_ = 0
    currentMonsterMaxHp_ = 1
    PlayEffects.ResetCombatFeedback()
end

local function ActionResult(response, successMessage)
    return context_.actionResult(response, successMessage)
end

local function RefreshMetrics()
    local width = metrics_.width
    local height = metrics_.height
    if refs_.root and refs_.root.GetLayout then
        local layout = refs_.root:GetLayout()
        if layout and layout.w and layout.w > 0 then width = layout.w end
        if layout and layout.h and layout.h > 0 then height = layout.h end
    elseif context_.getMiddleDesignHeight then
        height = context_.getMiddleDesignHeight()
    end
    width = math.max(640, width or 1080)
    height = math.max(520, height or 1400)
    local groundY = Clamp(height * 0.72, height - 290, height - 150)
    metrics_ = {
        width = width,
        height = height,
        groundY = groundY,
        playerAnchorX = width * 0.22,
        enemyAnchorX = width * 0.76,
    }
    context_.playerScreenX = math.floor(metrics_.playerAnchorX - context_.playerSize * 0.5)
    context_.roadY = math.floor(groundY)
    context_.platformPlayerY = math.floor(groundY - context_.runH + 21)
    context_.bgTileTop = 0
    context_.bgTileH = height
    return metrics_
end

local function SetAutoRun(enabled)
    if pendingAutoRun_ then return false end
    requestedAutoRun_ = enabled
    pendingAutoRun_ = true
    if enabled then
        context_.loadingController.EnsurePlayAssetsReady(function()
            context_.serverClient.AutoRun(true, function(response)
                pendingAutoRun_ = nil
                if not response or not response.ok then
                    requestedAutoRun_ = nil
                    ActionResult(response)
                    return
                end
                ActionResult(response, "登塔已开始")
                context_.serverClient.RequestSnapshot(function(snapshotResponse)
                    if not snapshotResponse or not snapshotResponse.ok then
                        print("[Play] auto-run enabled; waiting for authoritative delta")
                    end
                end)
            end)
        end)
    else
        ClearCombatPresentation(false)
        context_.serverClient.AutoRun(false, function(response)
            pendingAutoRun_ = nil
            if not response or not response.ok then
                requestedAutoRun_ = nil
                ActionResult(response)
                return
            end
            requestedAutoRun_ = false
            ActionResult(response, "登塔已暂停")
            context_.serverClient.RequestSnapshot()
        end)
    end
    return true
end

local function RequestAutoRunChange(enabled)
    if context_ and context_.requestAutoRunChange then
        return context_.requestAutoRunChange(enabled, function()
            return SetAutoRun(enabled)
        end)
    end
    return SetAutoRun(enabled)
end

local function CurrentEnemyScreenPosition()
    local current = roadEvents_[1]
    if not current then
        if rewardOrigin_ then return rewardOrigin_.x, rewardOrigin_.y end
        return metrics_.enemyAnchorX - context_.enemySize * 0.5,
            context_.roadY - context_.enemySize
    end
    return current.x - presentationX_,
        context_.roadY - context_.enemySize + EnemyFootOffset(current.eventType)
end

local function CurrentRewardScreenPosition()
    if rewardOrigin_ then
        return rewardOrigin_.x, rewardOrigin_.y
    end
    return CurrentEnemyScreenPosition()
end

local function DisplayLootText(text, maxChars)
    if context_ and context_.shortenText then
        return context_.shortenText(
            text,
            maxChars or 18
        )
    end
    return tostring(text or "")
end

local function TriggerPickupVisual(image, startX, startY, text, rarity, outcome, sourceId)
    local enemyX, enemyY = CurrentRewardScreenPosition()
    PlayEffects.TriggerPickup {
        image = image or Assets().items.crystal,
        startX = startX or (enemyX + context_.enemySize * 0.5 - context_.lootSize * 0.5),
        startY = startY or Clamp(
            enemyY + context_.enemySize * 0.45 - context_.lootSize * 0.5,
            32,
            metrics_.height - context_.lootSize - 96
        ),
        text = text or "获得道具",
        rarity = rarity or "common",
        outcome = outcome,
        sourceId = sourceId,
    }
end

local function ScheduleAttackDamageText(text, eventType, isBurst)
    local enemyX, enemyY = CurrentEnemyScreenPosition()
    PlayEffects.AddEnemyDamage(
        text or "命中",
        enemyX + context_.enemySize * 0.5 - 180,
        enemyY - 72,
        0,
        isBurst and 3 or 1
    )
    lastEventType_ = eventType or lastEventType_
end

local function TriggerCombatVisual(text, eventType, isBurst)
    lastEventType_ = eventType or lastEventType_
    local enemyX, enemyY = CurrentEnemyScreenPosition()
    PlayEffects.ShowFloating(
        text,
        enemyX + context_.enemySize * 0.5 - 180,
        enemyY - 36,
        isBurst
    )
end

local function SetCombatSequence(
    sequenceIndex,
    hitFrame,
    attackSerial,
    windupSeconds,
    recoverySeconds,
    endFrame
)
    local resolvedIndex = sequenceIndex or 1
    local sequence = CombatSequence.Get(
        resolvedIndex
    )
    if not sequence then return end
    local job = context_.currentPlayer()
    local frameSet = job.attackFrameSets
        and job.attackFrameSets[resolvedIndex]
    if not frameSet and resolvedIndex >= 4 then
        -- 终结技：暂用第二套攻击帧（动作差异明显）+ 残影/发光/范围特效表现
        frameSet = job.attackFrameSets and job.attackFrameSets[2]
    end
    currentAttackFrames_ = frameSet or job.attackFrames
    combatSequenceIndex_ = resolvedIndex
    combatHitFrame_ = hitFrame or sequence.hitFrames[1]
    combatEndFrame_ = endFrame or sequence.endFrame
    combatWindupSeconds_ = math.max(
        0.001,
        tonumber(windupSeconds)
            or tonumber(sequence.windupSeconds)
            or ((combatHitFrame_ - 1) / sequence.fps)
    )
    combatRecoverySeconds_ = math.max(
        0.001,
        tonumber(recoverySeconds)
            or tonumber(sequence.recoverySeconds)
            or ((combatEndFrame_ - combatHitFrame_ + 1) / sequence.fps)
    )
    lastAttackSoundKey_ = tostring(attackSerial or lastAttackSoundKey_ or "")
    combatAnimationTime_ = 0
    combatSequenceStartTime_ = 0
    -- 终结技：触发大范围特效
    if resolvedIndex >= 4 then
        spawnFinisherEffect()
    end
end

local function CreatePage()
    local assets = Assets()
    local game = Game()
    EnsureRoadEvents()
    refs_ = {objects = {}, bgTiles = {}}
    RefreshMetrics()
    if game.currentMonster then
        currentMonsterHp_ = game.currentMonster.hpBig or game.currentMonster.hp or currentMonsterHp_
        currentMonsterMaxHp_ = game.currentMonster.maxHpBig or game.currentMonster.maxHp
            or game.currentMonster.hpBig or game.currentMonster.hp or currentMonsterMaxHp_
    end
    local sceneChildren = PlayWorldView.Build {
        playerScreenX = context_.playerScreenX,
        roadY = context_.roadY,
        platformPlayerY = context_.platformPlayerY,
    }
    for _, node in ipairs(PlayEffects.BuildNodes()) do
        sceneChildren[#sceneChildren + 1] = node
    end

    local root = context_.UI.Panel {
        width = "100%", height = "100%", position = "relative",
        overflow = "hidden", backgroundImage = assets.bg,
        backgroundFit = "cover", children = sceneChildren,
    }
    refs_.root = root
    local lootText, lootIcon, lootRarity = PlayEffects.GetLootDisplay()
    for _, node in ipairs(PlayHud.Build {
        readOnly = game.readOnly,
        stashCount = #(game.lootStash or {}),
        lootText = lootText,
        lootIcon = lootIcon,
        lootRarity = lootRarity,
    }) do
        root:AddChild(node)
    end
    PlayPresentation.Update(0)
    return root
end

-- 终结技大范围特效：金色冲击波 + 横扫光弧 + 纵向光柱 + 角色发光 + 震屏（程序化表现，无额外素材）
spawnFinisherEffect = function()
    local root = refs_.root
    if not root then return end
    local effectLayer = context_.UI.Panel {
        position = "absolute",
        left = 0, top = 0, right = 0, bottom = 0,
        pointerEvents = "none",
    }
    root:AddChild(effectLayer)

    local function spawn(node, keyframes, duration, delay)
        effectLayer:AddChild(node)
        node:Animate {
            keyframes = keyframes,
            duration = duration,
            delay = delay or 0,
            easing = "easeOut",
            onComplete = function()
                if node.parent then node.parent:RemoveChild(node) end
            end,
        }
    end

    -- 全屏冲击波圆环
    spawn(
        context_.UI.Panel {
            position = "absolute",
            left = 50, right = 50, top = 110, bottom = 110,
            opacity = 0,
            scale = 0.3,
            borderWidth = 8,
            borderColor = { 255, 224, 130, 235 },
            borderRadius = 32,
            boxShadow = {
                color = { 255, 200, 90, 210 },
                offsetX = 0, offsetY = 0, blurRadius = 46,
            },
        },
        {
            [0] = { opacity = 0, scale = 0.3 },
            [0.32] = { opacity = 0.95, scale = 1.0 },
            [1] = { opacity = 0, scale = 1.28 },
        },
        0.95,
        0
    )

    -- 第二重冲击环（外圈扩散，迟发增强爆发感）
    spawn(
        context_.UI.Panel {
            position = "absolute",
            left = 80, right = 80, top = 150, bottom = 150,
            opacity = 0,
            scale = 0.45,
            borderWidth = 5,
            borderColor = { 255, 180, 90, 200 },
            borderRadius = 40,
            boxShadow = {
                color = { 255, 150, 60, 160 },
                offsetX = 0, offsetY = 0, blurRadius = 34,
            },
        },
        {
            [0] = { opacity = 0, scale = 0.45 },
            [0.3] = { opacity = 0.8, scale = 1.05 },
            [1] = { opacity = 0, scale = 1.35 },
        },
        1.1,
        0.22
    )

    -- 横扫光弧（贯穿画面）
    spawn(
        context_.UI.Panel {
            position = "absolute",
            left = 30, right = 30, top = 430, height = 10,
            opacity = 0,
            scale = 0.2,
            backgroundColor = { 255, 236, 170, 240 },
            boxShadow = {
                color = { 255, 205, 100, 235 },
                offsetX = 0, offsetY = 0, blurRadius = 30,
            },
        },
        {
            [0] = { opacity = 0, scale = 0.2 },
            [0.25] = { opacity = 1, scale = 1.0 },
            [1] = { opacity = 0, scale = 1.3 },
        },
        0.8,
        0.08
    )

    -- 纵向光柱（中心爆发）
    spawn(
        context_.UI.Panel {
            position = "absolute",
            left = 470, width = 140, top = 30, height = 1340,
            opacity = 0,
            backgroundColor = { 255, 232, 150, 70 },
            boxShadow = {
                color = { 255, 212, 120, 160 },
                offsetX = 0, offsetY = 0, blurRadius = 44,
            },
        },
        {
            [0] = { opacity = 0 },
            [0.3] = { opacity = 0.85 },
            [1] = { opacity = 0 },
        },
        1.0,
        0.1
    )

    -- 角色金色发光（终结技期间）
    local player = PlayWorldView.GetPlayerNode()
    if player then
        local originalShadow = player.props and player.props.boxShadow
        player:SetStyle({
            boxShadow = {
                color = { 255, 214, 110, 220 },
                offsetX = 0, offsetY = 0, blurRadius = 46,
            },
        })
        player:Animate {
            keyframes = {
                [0] = { opacity = 1 },
                [1] = { opacity = 1 },
            },
            duration = 1.1,
            delay = 0,
            onComplete = function()
                player:SetStyle({
                    boxShadow = originalShadow,
                })
            end,
        }
    end

    -- 震屏（页面抖动）
    root:Animate {
        keyframes = {
            [0] = { translateX = 0 },
            [0.12] = { translateX = -9 },
            [0.26] = { translateX = 7 },
            [0.4] = { translateX = -4 },
            [0.55] = { translateX = 2 },
            [1] = { translateX = 0 },
        },
        duration = 0.55,
        easing = "easeOut",
    }

    -- 特效层自身收尾清理
    local function cleanup()
        if effectLayer.parent then effectLayer.parent:RemoveChild(effectLayer) end
    end
    effectLayer:Animate {
        keyframes = { [0] = { opacity = 1 }, [1] = { opacity = 1 } },
        duration = 1.3,
        delay = 0,
        onComplete = cleanup,
    }
end

-- 终结技残影拖尾：在角色位置生成金色能量残影，淡出消散
local function spawnFinisherGhost()
    local root = refs_.root
    local metrics = PlayWorldView.GetPlayerMetrics()
    if not root or not metrics then return end
    local ghost = context_.UI.Panel {
        position = "absolute",
        left = metrics.left - 12,
        top = metrics.top - 12,
        width = metrics.width + 24,
        height = metrics.height + 24,
        opacity = 0.4,
        pointerEvents = "none",
        backgroundColor = { 255, 222, 130, 80 },
        borderRadius = 36,
        boxShadow = {
            color = { 255, 200, 90, 170 },
            offsetX = 0, offsetY = 0, blurRadius = 40,
        },
    }
    root:AddChild(ghost)
    ghost:Animate {
        keyframes = {
            [0] = { opacity = 0.4, translateX = 0 },
            [1] = { opacity = 0, translateX = -26 },
        },
        duration = 0.5,
        easing = "easeOut",
        onComplete = function()
            if ghost.parent then ghost.parent:RemoveChild(ghost) end
        end,
    }
end

local function Update(dt)
    if not refs_.root then return end
    local game = Game()
    RefreshMetrics()
    local authoritativeMonster = game.currentMonster
    if authoritativeMonster then
        currentMonsterHp_ = authoritativeMonster.hpBig or authoritativeMonster.hp or currentMonsterHp_
        currentMonsterMaxHp_ = authoritativeMonster.maxHpBig or authoritativeMonster.maxHp
            or authoritativeMonster.hpBig or authoritativeMonster.hp or currentMonsterMaxHp_
    elseif not currentEventLocked_ then
        currentMonsterHp_ = 0
        currentMonsterMaxHp_ = 1
    end
    EnsureRoadEvents()
    animationTime_ = animationTime_ + dt
    combatAnimationTime_ = currentEventLocked_ and (combatAnimationTime_ + dt) or 0
    -- 终结技残影拖尾：攻击进行期间持续生成金色能量残影
    if currentEventLocked_ and combatSequenceIndex_ and combatSequenceIndex_ >= 4 then
        finisherGhostTimer_ = finisherGhostTimer_ + dt
        if finisherGhostTimer_ >= 0.09 then
            finisherGhostTimer_ = 0
            spawnFinisherGhost()
        end
    else
        finisherGhostTimer_ = 0
    end
    if requestedAutoRun_ ~= nil and game.autoRun == requestedAutoRun_ then requestedAutoRun_ = nil; pendingAutoRun_ = nil end
    local visualAutoRun = game.autoRun
    if requestedAutoRun_ ~= nil then visualAutoRun = requestedAutoRun_ end
    local route = game.floorRoute
    local triggerDistance = route and route.triggerDistance or context_.eventTriggerDistance
    local moveSpeed = route and route.moveSpeed or context_.presentationSpeed
    local current = roadEvents_[1]
    local currentDistance = current and (current.x - presentationX_ - context_.playerScreenX) or 9999
    local reachedEnemy = current
        and current.kind == "enemy"
        and currentDistance <= triggerDistance
    if visualAutoRun
        and reachedEnemy
        and not currentEventLocked_
        and pendingEncounterId_ ~= current.encounterId
        and route
    then
        pendingEncounterId_ = current.encounterId
        context_.serverClient.EnterEncounter(
            route.routeId,
            current.encounterId,
            current.room,
            function(response)
                if not response or not response.ok then
                    pendingEncounterId_ = nil
                    ActionResult(response)
                    context_.serverClient.RequestSnapshot()
                end
            end
        )
    end
    local shouldStopForEvent = current
        and current.kind == "enemy"
        and (currentEventLocked_ or reachedEnemy)
    local speed = (visualAutoRun and not shouldStopForEvent) and moveSpeed or 0
    local nextPresentationX = presentationX_ + speed * dt
    local stopDistance = current and tonumber(current.distance)
    if speed > 0 and current and current.kind == "enemy" and stopDistance then
        presentationX_ = math.min(
            nextPresentationX,
            math.max(0, stopDistance - triggerDistance)
        )
    else
        presentationX_ = nextPresentationX
    end
    currentDistance = current and (current.x - presentationX_ - context_.playerScreenX) or 9999
    local inTriggerRange = current and currentDistance <= triggerDistance
    local waitingForBattle = visualAutoRun
        and current
        and current.kind == "enemy"
        and inTriggerRange
        and not currentEventLocked_
    if current and inTriggerRange
        and not currentEventLocked_
        and current.kind ~= "enemy"
    then
        local pickupText = current.eventType == "chest"
            and "打开宝箱"
            or "获得道具"
        TriggerPickupVisual(
            current.image,
            current.x - presentationX_,
            context_.roadY
                - context_.lootSize
                + 4,
            pickupText
        )
        AdvanceRoadEvent()
    end
    if current and currentEventLocked_ and current.kind == "enemy" and not visualAutoRun then
        ClearCombatPresentation(false)
    end

    local currentEvent = roadEvents_[1]
    local distance = currentEvent and (currentEvent.x - presentationX_ - context_.playerScreenX) or 9999
    local isAttacking = currentEventLocked_
        and currentEvent
        and currentEvent.kind == "enemy"
        and combatSequenceIndex_ ~= nil
    local isPicking = currentEvent
        and currentEvent.kind == "loot"
        and distance <= context_.eventTriggerDistance
    local job = context_.currentPlayer()
    local attackFrames = currentAttackFrames_
        or job.attackFrames
        or {job.attack or job.sprite or job.icon}
    local activeParams = isAttacking
        and context_.getAttackParams(currentAttackFrames_ or attackFrames, job)
        or context_.getRunParams()
    local sequence = CombatSequence.Get(combatSequenceIndex_ or 1) or {}
    PlayWorldView.Update {
        metrics = metrics_,
        presentationX = presentationX_,
        roadEvents = roadEvents_,
        visualAutoRun = visualAutoRun,
        isAttacking = isAttacking,
        isPicking = isPicking,
        attackFrames = currentAttackFrames_ or attackFrames,
        hitFrame = combatHitFrame_,
        endFrame = combatEndFrame_,
        windupSeconds = combatWindupSeconds_,
        recoverySeconds = combatRecoverySeconds_,
        sequenceTime = math.max(0, combatAnimationTime_ - combatSequenceStartTime_),
        activeFps = isAttacking and sequence.fps or (visualAutoRun and activeParams.fps or 8),
        activeParams = activeParams,
        animationTime = animationTime_,
        combatAnimationTime = combatAnimationTime_,
        playerScreenX = context_.playerScreenX,
        roadY = context_.roadY,
        platformPlayerY = context_.platformPlayerY,
    }
    local lootText, lootIcon, lootRarity = PlayEffects.GetLootDisplay()
    local playerMaxHp = game.playerMaxHp
        or (game.stats and (game.stats.hpBig or game.stats.hp)) or 1
    local playerHp = game.hpBig or game.hp or 0
    local hasMonster = game.currentMonster ~= nil or currentEventLocked_
    local displayMaxHp = hasMonster and currentMonsterMaxHp_ or 0
    local displayHp = hasMonster and currentMonsterHp_ or 0
    local monster = game.currentMonster
    PlayHud.Update {
        floor = game.floor,
        room = game.room,
        floorRouteStep = CurrentFloorRouteStep(game),
        lootText = lootText,
        lootIcon = lootIcon,
        lootRarity = lootRarity,
        playerHp = playerHp,
        playerMaxHp = playerMaxHp,
        playerHpRatio = MagnitudeRatio(playerHp, playerMaxHp),
        enemyHp = displayHp,
        enemyMaxHp = displayMaxHp,
        enemyHpRatio = MagnitudeRatio(displayHp, displayMaxHp),
        enemyName = DisplayLootText(
            (monster and (monster.name or monster.encounterKind or monster.eventType)) or "等待敌人",
            16
        ),
        displayedPower = game.displayedPower or (game.stats and game.stats.power),
        recommendedPower = game.recommendedPower,
        powerRatio = game.powerRatio,
        estimatedEasyFloor = game.estimatedEasyFloor,
        difficultyLabel = game.difficultyLabel,
        pendingAutoRun = pendingAutoRun_,
        visualAutoRun = visualAutoRun,
        readOnly = game.readOnly,
        assetsLoading = context_.loadingController.IsPlayAssetLoading(),
    }
    PlayEffects.Update(dt, {
        metrics = metrics_,
        playerScreenX = context_.playerScreenX,
        playerSize = context_.playerSize,
        roadY = context_.roadY,
        platformPlayerY = context_.platformPlayerY,
    })
end

function PlayPresentation.Configure(context)
    context_ = context
    PlayEffects.Configure(context)
    PlayWorldView.Configure {
        UI = context.UI,
        assets = context.assets,
        currentPlayer = context.currentPlayer,
        bgTileTop = context.bgTileTop,
        bgTileW = context.bgTileW,
        bgTileH = context.bgTileH,
        runW = context.runW,
        runH = context.runH,
        playerSize = context.playerSize,
        enemySize = context.enemySize,
        lootSize = context.lootSize,
        lootFootOffset = context.lootFootOffset,
        eventViewCount = context.eventViewCount,
        enemyFootOffset = EnemyFootOffset,
    }
    PlayHud.Configure {
        UI = context.UI,
        colors = context.colors,
        assets = context.assets,
        compactTxt = context.compactTxt,
        imageProgress = context.imageProgress,
        setImageProgress = context.setImageProgress,
        formatInt = context.formatInt,
        rarities = context.rarities,
        onOpenLootStash = function()
            if not Game().readOnly and context_.openLootStash then context_.openLootStash() end
        end,
        onOpenIdleSettings = function()
            if not Game().readOnly and context_.openIdleSettings then context_.openIdleSettings() end
        end,
        onShowTowerRules = function()
            if context_.showTowerRules then context_.showTowerRules() end
        end,
        onToggleAutoRun = function()
            local game = Game()
            if game.readOnly or context_.loadingController.IsPlayAssetLoading() or pendingAutoRun_ then return end
            local currentAutoRun = requestedAutoRun_ ~= nil and requestedAutoRun_ or game.autoRun
            RequestAutoRunChange(not currentAutoRun)
        end,
    }
end

function PlayPresentation.BuildPage()
    return CreatePage()
end

function PlayPresentation.Update(dt)
    Update(dt or 0)
end

local function NormalizedEventType(value)
    local eventType = value.eventType or value.encounterKind or "monster"
    if eventType == "normal" then return "monster" end
    if eventType == "chapterBoss" then return "boss" end
    return eventType
end

local function LootIcon(value)
    if type(value.icon) == "string" and value.icon ~= "" then return value.icon end
    if context_.itemImage then
        return context_.itemImage(value.item or value)
    end
    return Assets().items.chest
end

function PlayPresentation.HandleDelta(payload)
    local game = Game()
    local seenVisualEvents = {}
    local seenLootItems = {}
    for _, value in ipairs((payload and payload.events) or {}) do
        local kind = value.kind or value.type
        if kind == "cell_entered" then
            lastEventType_ = NormalizedEventType(value)
            AlignCurrentRoadEvent(lastEventType_)
        elseif kind == "auto_run_changed" then
            requestedAutoRun_ = nil
            pendingAutoRun_ = nil
            if value.enabled == false then ClearCombatPresentation(false) end
        elseif kind == "battle_started" or kind == "monster_spawned" then
            rewardOrigin_ = nil
            pendingEncounterId_ = value.monsterId or pendingEncounterId_
            local eventType = NormalizedEventType(value)
            lastEventType_ = eventType
            AlignCurrentRoadEvent(eventType)
            currentEventLocked_ = true
            currentMonsterHp_ = value.monsterHpBig or value.hpBig
                or (value.monster and value.monster.hpBig)
                or value.monsterHp or value.hp or (value.monster and value.monster.hp) or 0
            currentMonsterMaxHp_ = value.monsterMaxHpBig or value.maxHpBig
                or (value.monster and value.monster.maxHpBig)
                or value.monsterMaxHp or value.maxHp
                or (value.monster and value.monster.maxHp) or currentMonsterHp_ or 1
        elseif kind == "attack_started" then
            currentEventLocked_ = true
            local attackKey = tostring(value.attackSerial or value.eventId or value.sequenceIndex or "")
            if attackKey ~= "" and attackKey ~= lastAttackSoundKey_ and context_.playFeedback then
                lastAttackSoundKey_ = attackKey
                context_.playFeedback("combatAttack")
            end
            local sequenceIndex = value.sequenceIndex or tonumber(value.sequenceId)
                or ({A = 1, B = 2, C = 3, D = 4})[value.sequenceId]
            SetCombatSequence(
                sequenceIndex,
                value.hitFrame or (value.hitFrames and value.hitFrames[1]),
                value.attackSerial,
                value.windupSeconds,
                value.recoverySeconds or value.durationSeconds,
                value.endFrame
            )
        elseif kind == "battle_hit" or kind == "damage_dealt" or kind == "player_attack_hit" then
            if PlayEffects.ShouldRender(seenVisualEvents, "enemy_hit", value) then
                currentEventLocked_ = true
                local amount = value.amountBig or value.damageBig or value.amount or value.damage or 0
                currentMonsterHp_ = value.targetHpBig or value.monsterHpBig
                    or value.targetHp or value.monsterHp or currentMonsterHp_
                currentMonsterMaxHp_ = value.targetMaxHpBig or value.monsterMaxHpBig
                    or value.targetMaxHp or value.monsterMaxHp or currentMonsterMaxHp_
                ScheduleAttackDamageText(
                    (value.critical and "暴击 " or "") .. context_.formatInt(amount),
                    value.eventType,
                    value.critical == true or value.lucky == true
                )
                TriggerCombatVisual(context_.formatInt(amount), value.eventType, value.critical == true or value.lucky == true)
            end
        elseif kind == "player_damaged" then
            if PlayEffects.ShouldRender(seenVisualEvents, "player_damage", value) then
                PlayEffects.AddPlayerFeedback("-" .. context_.formatInt(
                    value.amountBig or value.damageBig or value.amount or value.damage or 0), C().hp, "damage")
            end
        elseif kind == "player_healed" or kind == "life_steal" then
            if PlayEffects.ShouldRender(seenVisualEvents, "player_heal", value) then
                local source = value.source == "life_steal" and "lifesteal" or value.source
                local color = source == "floor_rest" and C().focus or (source == "revive" and C().focus or C().success)
                local prefix = source == "floor_rest" and "休整 +" or (source == "revive" and "复活 +" or "吸血 +")
                PlayEffects.AddPlayerFeedback(prefix .. context_.formatInt(value.amountBig or value.amount or 0), color, source)
            end
        elseif kind == "player_died" then
            PlayEffects.AddPlayerFeedback("角色倒下", C().hp, "death")
        elseif kind == "player_revived" then
            PlayEffects.AddPlayerFeedback("复活 · 返回本层第1场", C().focus, "revive")
        elseif kind == "floor_reset" then
            activeRouteId_ = nil
            roadEvents_ = {}
            pendingEncounterId_ = nil
            presentationX_ = 0
            ClearCombatPresentation(false)
            PlayEffects.AddPlayerFeedback("本层重置", C().focus, "floor_rest")
        elseif kind == "floor_advanced" then
            transitioningFloor_ = value.floor
            context_.loadingController.BeginFloorTransition(value.floor)
            activeRouteId_ = nil
            roadEvents_ = {}
            pendingEncounterId_ = nil
            presentationX_ = 0
            ClearCombatPresentation(false)
        elseif kind == "boss_enraged" then
            local enemyX, enemyY = CurrentEnemyScreenPosition()
            PlayEffects.AddEnemyDamage(
                "Boss 狂暴!",
                enemyX + context_.enemySize * 0.5 - 180,
                enemyY - 90,
                0,
                4
            )
        elseif kind == "battle_won" or kind == "monster_defeated" then
            if currentEventLocked_ then
                local enemyX, enemyY = CurrentEnemyScreenPosition()
                rewardOrigin_ = { x = enemyX, y = enemyY }
            end
            currentMonsterHp_ = 0
            currentMonsterMaxHp_ = 1
            combatSequenceIndex_ = nil
            combatHitFrame_ = nil
            currentAttackFrames_ = nil
            if currentEventLocked_ then AdvanceRoadEvent() end
        elseif kind == "battle_lost" then
            currentMonsterHp_ = value.monsterHpBig or value.monsterHp or currentMonsterMaxHp_
        elseif kind == "battle" then
            currentEventLocked_ = true
        elseif kind == "level_up" then
            local gained = tonumber(value.levelsGained) or 1
            PlayEffects.AddPlayerFeedback(
                "角色升级 Lv." .. tostring(value.level or game.level or 1)
                    .. (gained > 1 and ("  +" .. tostring(gained)) or ""),
                C().focus,
                "level_up"
            )
            context_.UI.Toast.Show(
                "角色升级至 Lv." .. tostring(value.level or game.level or 1),
                {duration = 2.5, variant = "success", position = "top"}
            )
        elseif kind == "battle_reward" then
            PlayEffects.SetLootDisplay(
                "金币+" .. context_.formatInt(value.gold or 0)
                    .. " 经验+" .. context_.formatInt(value.exp or 0),
                Assets().items.gold,
                "gold_green"
            )
        elseif kind == "currency_drop" and value.currency == "gold" then
            local total = math.max(0, tonumber(value.amount) or 0)
            local count = math.max(1, math.min(12, math.floor(tonumber(value.dropCount) or 1)))
            local baseAmount = math.floor(total / count)
            local remainder = total - baseAmount * count
            local enemyX, enemyY = CurrentRewardScreenPosition()
            local bursts = {}
            for index = 1, count do
                local amount = baseAmount + (index <= remainder and 1 or 0)
                local angle = ((index - 1) / count) * math.pi * 2
                local radius = 72 + ((index - 1) % 3) * 34
                bursts[index] = {
                    age = -(index - 1) * 0.07,
                    amount = amount,
                    startX = enemyX + context_.enemySize * 0.5 - context_.lootSize * 0.5,
                    startY = Clamp(enemyY + context_.enemySize * 0.58, 32, metrics_.height - context_.lootSize - 96),
                    scatterX = enemyX + context_.enemySize * 0.5 + math.cos(angle) * radius - context_.lootSize * 0.5,
                    scatterY = Clamp(enemyY + context_.enemySize * 0.58 + math.sin(angle) * 46, 32, metrics_.height - context_.lootSize - 96),
                    soundPlayed = false,
                }
            end
            PlayEffects.SetCurrencyBursts(bursts)
        elseif kind == "loot_dropped" or kind == "equipment_drop" then
            local itemKey = tostring(value.itemId or value.equipmentId or "")
            if itemKey == "" or not seenLootItems[itemKey] then
                if itemKey ~= "" then seenLootItems[itemKey] = true end
                if itemKey ~= "" and itemKey ~= lastLootSoundKey_ and context_.playFeedback then
                    lastLootSoundKey_ = itemKey
                    context_.playFeedback("lootDrop")
                end
                local icon = LootIcon(value)
                local rarity = value.rarity or "common"
                local rarityName = context_.rarityName and context_.rarityName(rarity) or rarity
                local text = tostring(value.name or rarityName .. " " .. tostring(value.slot or "装备"))
                local _, enemyY = CurrentRewardScreenPosition()
                local pickupStartY = Clamp(
                    enemyY + context_.enemySize * 0.45 - context_.lootSize * 0.5,
                    32,
                    metrics_.height - context_.lootSize - 96
                )
                TriggerPickupVisual(
                    icon, nil, pickupStartY, text, rarity, nil, itemKey
                )
            end
        elseif kind == "loot_settled" then
            PlayEffects.SettleLoot(
                value.itemId,
                value.outcome or value.destination
            )
        elseif kind == "chest_reward" then
            PlayEffects.SetLootDisplay(
                "宝箱+" .. context_.formatInt(value.gold or 0),
                Assets().items.chest
            )
        elseif kind == "story_gate" and context_.showStoryGate then
            pendingEncounterId_ = nil
            context_.showStoryGate(value)
        elseif kind == "event_pending" and context_.showPendingEvent then
            pendingEncounterId_ = nil
            context_.showPendingEvent(value)
        elseif kind == "equipment_upgrade_available" and context_.showEquipmentUpgrade then
            local ok, TutorialController = pcall(require, "client.TutorialController")
            if not (ok and TutorialController and TutorialController.IsActive and TutorialController.IsActive()) then
                context_.showEquipmentUpgrade(value)
            end
        elseif (kind == "aid_pending" or kind == "tower_aid_requested") and context_.showAidPrompt then
            context_.showAidPrompt(value)
        elseif kind == "equipment_reverted" or kind == "equip_undone" then
            context_.UI.Toast.Show("已撤回上一次自动换装", {duration = 2, variant = "info", position = "bottom"})
        end
    end
    context_.updateTopBar()
    EnsureRoadEvents()
    if game.page == "play" then PlayPresentation.Update(0) end
end

function PlayPresentation.HandleSnapshot()
    local game = Game()
    local monster = game.currentMonster

    if monster then
        AlignCurrentRoadEvent(
            NormalizedEventType(monster)
        )
        currentEventLocked_ = true
        currentMonsterHp_ = monster.hpBig or monster.hp or 0
        currentMonsterMaxHp_ =
            monster.maxHpBig
            or monster.maxHp
            or monster.hpBig
            or monster.hp
            or 1

        local phaseRemaining = math.max(
            0.001,
            tonumber(monster.phaseRemaining)
                or 0.001
        )
        local windupSeconds =
            monster.phase == "recovery"
            and 0.001
            or phaseRemaining
        local recoverySeconds =
            monster.phase == "recovery"
            and phaseRemaining
            or monster.recoverySeconds

        SetCombatSequence(
            monster.sequenceIndex,
            monster.hitFrame,
            monster.attackSerial,
            windupSeconds,
            recoverySeconds,
            monster.endFrame
        )

        if monster.phase == "recovery" then
            combatAnimationTime_ =
                combatWindupSeconds_
        end
    else
        currentEventLocked_ = false
        combatSequenceIndex_ = nil
        currentAttackFrames_ = nil
        currentMonsterHp_ = 0
        currentMonsterMaxHp_ = 1
    end

    sessionAutoStartAttempted_ = true
    local pendingStoryGate = game.pendingStoryGate or game.pendingStory
    if pendingStoryGate and context_.showStoryGate then context_.showStoryGate(pendingStoryGate) end
    if game.pendingEvent and context_.showPendingEvent then
        context_.showPendingEvent(game.pendingEvent)
    end
if game.pendingEquipDecision and context_.showEquipmentUpgrade then
        local ok, TutorialController = pcall(require, "client.TutorialController")
        if not (ok and TutorialController and TutorialController.IsActive and TutorialController.IsActive()) then
            context_.showEquipmentUpgrade(game.pendingEquipDecision)
        end
    end
    if game.aidPending and context_.showAidPrompt then
        context_.showAidPrompt({
            aidId = "snapshot:" .. tostring(game.floor or 1),
            floor = game.floor,
        })
    end
    if requestedAutoRun_ ~= nil and game.autoRun == requestedAutoRun_ then
        requestedAutoRun_ = nil
        pendingAutoRun_ = nil
    end
end

function PlayPresentation.SetAutoRun(enabled)
    return RequestAutoRunChange(enabled)
end

function PlayPresentation.CancelPendingAutoRun()
    requestedAutoRun_ = nil
    pendingAutoRun_ = nil
end

function PlayPresentation.ClearCombatPresentation(advanceLockedEvent)
    ClearCombatPresentation(advanceLockedEvent)
end

function PlayPresentation.Reset()
    ClearCombatPresentation(false)
    refs_ = {}
    roadEvents_ = {}
    activeRouteId_ = nil
    pendingEncounterId_ = nil
    transitioningFloor_ = nil
    presentationX_ = 0
    animationTime_ = 0
    rewardOrigin_ = nil
    PlayEffects.Reset()
    PlayHud.Reset()
    PlayWorldView.Reset()
    metrics_ = { width = 1080, height = 1400, enemyAnchorX = 820 }
    sessionAutoStartAttempted_ = false
    requestedAutoRun_ = nil
    pendingAutoRun_ = nil
end

function PlayPresentation.GetRequestedAutoRun()
    return requestedAutoRun_
end

function PlayPresentation.SetRequestedAutoRun(value)
    requestedAutoRun_ = value
end

function PlayPresentation.SetPendingAutoRun(value)
    pendingAutoRun_ = value
end

return PlayPresentation
