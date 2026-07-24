local PlayPresentation = {}
local CombatSequence = require("shared.CombatSequence")
local BigNumber = require("shared.BigNumber")

local context_ = nil
local refs_ = {}
local roadEvents_ = {}
local nextEventId_ = 1
local presentationX_ = 0
local animationTime_ = 0
local combatAnimationTime_ = 0
local combatSequenceStartTime_ = 0
local combatSequenceIndex_ = nil
local combatHitFrame_ = nil
local combatEndFrame_ = nil
local combatWindupSeconds_ = 0
local combatRecoverySeconds_ = 0
local combatAttackSerial_ = nil
local currentMonsterHp_ = 0
local currentMonsterMaxHp_ = 1
local currentEventLocked_ = false
local currentAttackFrames_ = nil
local pickupFx_ = nil
local currentPlayerImage_ = nil
local floatingText_ = nil
local enemyDamageBursts_ = {}
local playerFeedbackBursts_ = {}
local lastEventType_ = "monster"
local lastLootText_ = "等待掉落"
local lastLootIcon_ = nil
local requestedAutoRun_ = nil
local pendingAutoRun_ = nil
local sessionAutoStartAttempted_ = false

local DAMAGE_LABEL_COUNT = 5
local PLAYER_FEEDBACK_COUNT = 5
local metrics_ = { width = 1080, height = 1400, enemyAnchorX = 820 }
local Clamp

local function C()
    return context_.colors
end

local function MagnitudeRatio(value, maximum)
    if type(value) == "table" or type(maximum) == "table" then
        return Clamp(BigNumber.Ratio(value or 0, maximum or 1) or 0, 0, 1)
    end
    return Clamp((value or 0) / math.max(1, maximum or 1), 0, 1)
end

local function MagnitudeKey(value)
    if type(value) == "table" and (value.mantissa ~= nil or value.exponent ~= nil) then
        return BigNumber.ToScientificString(value, 12)
    end
    return tostring(value or "")
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

local function FrameAt(frames, fps, time)
    local player = context_.currentPlayer()
    if not frames or #frames == 0 then return player.icon end
    local index = math.floor((time or animationTime_) * (fps or 8)) % #frames + 1
    return frames[index]
end

local function AttackFrameAt(frames, sequenceTime)
    local player = context_.currentPlayer()
    if not frames or #frames == 0 then
        return player.icon
    end

    local hitFrame = Clamp(
        combatHitFrame_ or 1,
        1,
        #frames
    )
    local endFrame = Clamp(
        combatEndFrame_ or #frames,
        hitFrame,
        #frames
    )
    local windup = math.max(
        0.001,
        combatWindupSeconds_
    )
    local recovery = math.max(
        0.001,
        combatRecoverySeconds_
    )
    local frame

    if sequenceTime < windup then
        local progress = Clamp(
            sequenceTime / windup,
            0,
            1
        )
        frame = 1 + math.floor(
            progress * (hitFrame - 1)
        )
    else
        local progress = Clamp(
            (sequenceTime - windup)
                / recovery,
            0,
            1
        )
        frame = hitFrame + math.floor(
            progress
                * (endFrame - hitFrame)
        )
    end

    return frames[Clamp(frame, 1, endFrame)]
end

local function IsCombatEvent(eventType)
    return eventType == "monster" or eventType == "elite" or eventType == "boss"
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

local function EventIcon(eventType)
    local assets = Assets()
    if eventType == "chest" then return assets.items.chest end
    if eventType == "merchant" then return assets.items.gold end
    if eventType == "random" then return assets.items.crystal end
    return nil
end

local function DeterministicEventType(index)
    local room = ((index - 1) % 10) + 1
    if room <= 7 then return "monster" end
    if room <= 9 then return "elite" end
    return "boss"
end

local function MakeRoadEvent(index)
    local eventType = DeterministicEventType(index)
    local isEnemy = IsCombatEvent(eventType)
    local assets = Assets()
    return {
        id = index,
        x = 820 + (index - 1) * context_.eventSpacing,
        kind = isEnemy and "enemy" or "loot",
        eventType = eventType,
        image = isEnemy and EnemyImageForStep(index, eventType) or (EventIcon(eventType) or assets.items.crystal),
    }
end

local function EnsureRoadEvents()
    while #roadEvents_ < context_.eventViewCount do
        roadEvents_[#roadEvents_ + 1] = MakeRoadEvent(nextEventId_)
        nextEventId_ = nextEventId_ + 1
    end
end

local function AlignCurrentRoadEvent(
    eventType
)
    EnsureRoadEvents()
    local current = roadEvents_[1]
    if not current then
        return
    end

    local isEnemy =
        IsCombatEvent(eventType)
    current.kind = isEnemy
        and "enemy"
        or "loot"
    current.eventType = eventType
    current.image = isEnemy
        and EnemyImageForStep(
            current.id,
            eventType
        )
        or (
            EventIcon(eventType)
            or Assets().items.crystal
        )
    current.x = presentationX_ + metrics_.enemyAnchorX - context_.enemySize * 0.5
end

local function AdvanceRoadEvent()
    table.remove(roadEvents_, 1)
    roadEvents_[#roadEvents_ + 1] = MakeRoadEvent(nextEventId_)
    nextEventId_ = nextEventId_ + 1
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
    combatAttackSerial_ = nil
    currentMonsterHp_ = 0
    currentMonsterMaxHp_ = 1
    enemyDamageBursts_ = {}
    playerFeedbackBursts_ = {}
    floatingText_ = nil
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
                ActionResult(response, "挂机已开始")
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
            ActionResult(response, "挂机已暂停")
            context_.serverClient.RequestSnapshot()
        end)
    end
    return true
end

local function TriggerPickupVisual(image, startX, startY, text, rarity, outcome)
    local assets = Assets()
    pickupFx_ = {
        age = 0,
        duration = 1.35,
        image = image or assets.items.crystal,
        startX = startX or (metrics_.enemyAnchorX - context_.lootSize * 0.5),
        startY = startY or (context_.roadY - context_.lootSize),
        endX = 58,
        endY = metrics_.height - 50,
        text = text or "获得道具",
        rarity = rarity or "common",
        outcome = outcome,
    }
    lastLootText_ = pickupFx_.text
    lastLootIcon_ = pickupFx_.image
end

local function AddPlayerFeedback(text, color, source)
    if #playerFeedbackBursts_ >= PLAYER_FEEDBACK_COUNT then
        table.remove(playerFeedbackBursts_, 1)
    end
    playerFeedbackBursts_[#playerFeedbackBursts_ + 1] = {
        age = 0,
        text = text,
        color = color,
        source = source,
        lane = (#playerFeedbackBursts_ % PLAYER_FEEDBACK_COUNT),
    }
end

local function AddEnemyDamageBurst(text, baseX, baseY, delay, variant)
    if #enemyDamageBursts_ >= DAMAGE_LABEL_COUNT then
        table.remove(enemyDamageBursts_, 1)
    end
    enemyDamageBursts_[#enemyDamageBursts_ + 1] = {
        age = -(delay or 0),
        text = text or "命中",
        baseX = baseX or (context_.playerScreenX + 360),
        baseY = baseY or (context_.roadY - context_.enemySize - 72),
        variant = variant or 1,
    }
end

local function ScheduleAttackDamageText(
    text,
    eventType,
    isBurst
)
    local enemyX = metrics_.enemyAnchorX - 180
    local enemyY =
        context_.roadY
        - context_.enemySize
        - 72

    AddEnemyDamageBurst(
        text or "命中",
        enemyX,
        enemyY,
        0,
        isBurst and 3 or 1
    )
    lastEventType_ =
        eventType or lastEventType_
end

local function TriggerCombatVisual(
    text,
    eventType,
    isBurst
)
    lastEventType_ =
        eventType or lastEventType_
    floatingText_ = {
        age = 0.0,
        text = isBurst
            and (text or "暴击")
            or "命中",
    }
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
    currentAttackFrames_ = job.attackFrameSets
        and job.attackFrameSets[resolvedIndex]
        or job.attackFrames
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
    combatAttackSerial_ = attackSerial
    combatAnimationTime_ = 0
    combatSequenceStartTime_ = 0
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
    currentPlayerImage_ = nil
    refs_.bgTiles[1] = context_.UI.Panel {position = "absolute", left = 0, top = context_.bgTileTop, width = context_.bgTileW, height = context_.bgTileH, backgroundImage = assets.bg, backgroundFit = "cover"}
    refs_.bgTiles[2] = context_.UI.Panel {position = "absolute", left = context_.bgTileW, top = context_.bgTileTop, width = context_.bgTileW, height = context_.bgTileH, backgroundImage = assets.bgMirror, backgroundFit = "cover"}
    refs_.bgTiles[3] = context_.UI.Panel {position = "absolute", left = context_.bgTileW * 2, top = context_.bgTileTop, width = context_.bgTileW, height = context_.bgTileH, backgroundImage = assets.bg, backgroundFit = "cover"}
    refs_.playerShadow = context_.UI.Panel {position = "absolute", left = context_.playerScreenX + 168, top = context_.roadY - 12, width = 118, height = 14, backgroundImage = assets.ui.characterShadow, backgroundFit = "contain"}
    refs_.player = context_.UI.Panel {position = "absolute", left = context_.playerScreenX, top = context_.platformPlayerY, width = context_.runW, height = context_.runH, backgroundImage = context_.currentPlayer().sprite or context_.currentPlayer().icon, backgroundFit = "contain"}

    for index = 1, context_.eventViewCount do
        refs_.objects[index] = context_.UI.Panel {position = "absolute", left = 0, top = 0, width = context_.enemySize, height = context_.enemySize, backgroundImage = assets.enemies.slime, backgroundFit = "contain", visible = true}
    end
    refs_.lootBeam = context_.UI.Panel {
        position = "absolute", left = 0, top = 0, width = 112, height = 300,
        visible = false, pointerEvents = "none",
        backgroundGradient = { type = "linear", direction = "to-top", from = {255,255,255,230}, to = {255,255,255,0} },
        borderLeftWidth = 3, borderRightWidth = 3,
    }
    refs_.pickup = context_.UI.Panel {position = "absolute", left = 0, top = 0, width = context_.lootSize, height = context_.lootSize, backgroundImage = assets.items.crystal, backgroundFit = "contain", visible = false}
    refs_.pickupSpark = context_.UI.Panel {position = "absolute", left = 0, top = 0, width = 82, height = 82, backgroundImage = assets.ui.pickupSpark, backgroundFit = "contain", visible = false}
    refs_.floatLabel = context_.txt("", 30, C().gold, {position = "absolute", left = 0, top = 0, width = 360, textAlign = "center", visible = false, textStroke = {width = 2, color = "#000000"}})
    refs_.enemyDamageLabels = {}
    for index = 1, DAMAGE_LABEL_COUNT do
        refs_.enemyDamageLabels[index] = context_.txt("", 34, C().hp, {position = "absolute", left = 0, top = 0, width = 360, textAlign = "center", visible = false, textStroke = {width = 3, color = "#000000"}})
    end
    refs_.playerFeedbackLabels = {}
    for index = 1, PLAYER_FEEDBACK_COUNT do
        refs_.playerFeedbackLabels[index] = context_.txt("", 32, C().hp, {
            position = "absolute", left = 0, top = 0, width = 360,
            textAlign = "center", visible = false,
            textStroke = {width = 3, color = "#000000"},
        })
    end
    refs_.event = context_.compactTxt("向右移动", 20, C().primary, {width = "100%"})
    refs_.progress = context_.compactTxt("第1层", 20, C().focus, {})
    refs_.lootLabel = context_.compactTxt(lastLootText_, 18, C().gold, {width = "100%"})
    local hpProgress
    hpProgress, refs_.hpFill = context_.imageProgress(
        420, 30, game.hpBig or game.hp or 1,
        game.playerMaxHp or game.stats.hpBig or game.stats.hp or 1,
        assets.ui.progressTrackHp, assets.ui.progressFillHp)
    refs_.hpBar = hpProgress
    local enemyHpProgress
    enemyHpProgress, refs_.enemyHpFill = context_.imageProgress(420, 30, currentMonsterHp_, currentMonsterMaxHp_, assets.ui.progressTrackHp, assets.ui.progressFillHp)
    refs_.enemyHpBar = enemyHpProgress
    refs_.runButtonLabel = context_.compactTxt(game.autoRun and "刷宝中" or "开始刷宝", 20, C().text, {
        width = "100%",
        textAlign = "center",
        textStroke = {width = 2, color = "#000000"},
        pointerEvents = "none",
    })

    local sceneChildren = {refs_.bgTiles[1], refs_.bgTiles[2], refs_.bgTiles[3]}
    for index = 1, #refs_.objects do sceneChildren[#sceneChildren + 1] = refs_.objects[index] end
    sceneChildren[#sceneChildren + 1] = refs_.playerShadow
    sceneChildren[#sceneChildren + 1] = refs_.player
    sceneChildren[#sceneChildren + 1] = refs_.lootBeam
    sceneChildren[#sceneChildren + 1] = refs_.pickup
    sceneChildren[#sceneChildren + 1] = refs_.pickupSpark
    sceneChildren[#sceneChildren + 1] = refs_.floatLabel
    for index = 1, #refs_.enemyDamageLabels do sceneChildren[#sceneChildren + 1] = refs_.enemyDamageLabels[index] end
    for index = 1, #refs_.playerFeedbackLabels do sceneChildren[#sceneChildren + 1] = refs_.playerFeedbackLabels[index] end

    local settingsButton = context_.UI.Panel {
        position = "absolute",
        right = 272,
        top = 20,
        width = 72,
        height = 72,
        clickable = not game.readOnly,
        opacity = game.readOnly and 0.45 or 1.0,
        backgroundImage = assets.ui.idleSettings,
        backgroundFit = "contain",
        onClick = function()
            if not Game().readOnly and context_.openIdleSettings then
                context_.openIdleSettings()
            end
        end,
    }

    -- RunButton boundary contract:
    -- assetRect=264x94, visualOuterRect=(4,4,256,86), contentRect=(50,22,164,50).
    -- The full design-space target (x=824,y=42,w=230,h=72) remains interactive;
    -- contain preserves the formal purple/cyan frame without stretching.
    local runButtonDisabled = game.readOnly
        or context_.loadingController.IsPlayAssetLoading()
        or pendingAutoRun_
    local runButton = context_.UI.Button {
        position = "absolute", right = 26, top = 20, width = 230, height = 72,
        disabled = runButtonDisabled,
        alignItems = "center", justifyContent = "center",
        padding = 0, paddingHorizontal = 0, paddingVertical = 0,
        borderWidth = 0, boxShadow = {},
        backgroundImage = assets.ui.playAutoRunButton, backgroundFit = "contain",
        onClick = function()
            local currentGame = Game()
            if not currentGame.readOnly and not context_.loadingController.IsPlayAssetLoading() and not pendingAutoRun_ then
                local currentAutoRun = currentGame.autoRun
                if requestedAutoRun_ ~= nil then currentAutoRun = requestedAutoRun_ end
                SetAutoRun(not currentAutoRun)
            end
        end,
        children = {refs_.runButtonLabel},
    }
    refs_.runButton = runButton

    local root = context_.UI.Panel {width = "100%", height = "100%", position = "relative", overflow = "hidden", backgroundImage = assets.bg, backgroundFit = "cover", children = sceneChildren}
    refs_.root = root
    refs_.event:SetStyle({visible = false})
    refs_.progress:SetStyle({position = "absolute", left = 0, top = 19, width = 150, textAlign = "center"})
    local floorBadge = context_.UI.Panel {position = "absolute", left = 465, top = 286, width = 150, height = 60, backgroundImage = assets.ui.floorBadge, backgroundFit = "contain", children = {refs_.progress}}
    refs_.floatLabel:SetStyle({visible = false})
    refs_.lootLabel:SetStyle({visible = false})
    refs_.playerHpText = context_.compactTxt("", 17, C().text, {position = "absolute", left = 52, top = 105, width = 400, height = 28, textAlign = "center", textStroke = {width = 2, color = "#000000"}})
    refs_.enemyHpText = context_.compactTxt("", 17, C().text, {position = "absolute", left = 52, top = 105, width = 400, height = 28, textAlign = "center", textStroke = {width = 2, color = "#000000"}})
    refs_.playerName = context_.compactTxt("赤焰枪刃", 21, C().text, {position = "absolute", left = 40, top = 27, width = 434, height = 34, textAlign = "center", textStroke = {width = 2, color = "#000000"}})
    refs_.enemyName = context_.compactTxt("等待敌人", 21, C().text, {position = "absolute", left = 40, top = 27, width = 434, height = 34, textAlign = "center", textStroke = {width = 2, color = "#000000"}})
    local hpFrame = context_.UI.Panel {position = "absolute", left = 20, top = 112, width = 520, height = 160, backgroundImage = assets.ui.playHpFrame, backgroundFit = "contain", children = {
        refs_.playerName,
        context_.UI.Panel {position = "absolute", left = 52, top = 72, width = 420, height = 30, children = {refs_.hpBar}},
        refs_.playerHpText,
    }}
    local enemyHpFrame = context_.UI.Panel {position = "absolute", right = 20, top = 112, width = 520, height = 160, backgroundImage = assets.ui.playHpFrame, backgroundFit = "contain", children = {
        refs_.enemyName,
        context_.UI.Panel {position = "absolute", left = 52, top = 72, width = 420, height = 30, children = {refs_.enemyHpBar}},
        refs_.enemyHpText,
    }}
    refs_.enemyHpFrame = enemyHpFrame
    refs_.powerCurrent = context_.compactTxt("当前战力 待评估", 19, C().gold, {position = "absolute", left = 22, top = 12, width = 282, height = 28, textStroke = {width = 1, color = "#000000"}})
    refs_.powerRecommended = context_.compactTxt("推荐战力 待同步", 18, C().textSecondary, {position = "absolute", left = 310, top = 12, width = 298, height = 28, textAlign = "right", textStroke = {width = 1, color = "#000000"}})
    refs_.powerStatus = context_.compactTxt("战力评估同步中", 17, C().focus, {position = "absolute", left = 22, top = 46, width = 586, height = 26, textAlign = "center", textStroke = {width = 1, color = "#000000"}})
    local powerCard = context_.UI.Panel {
        position = "absolute", left = 26, top = 16, width = 630, height = 80,
        backgroundImage = assets.ui.panelCompact, backgroundFit = "sliced", backgroundSlice = {12,12,12,12},
        children = {refs_.powerCurrent, refs_.powerRecommended, refs_.powerStatus},
    }
    local rulesButton = context_.UI.Panel {
        position = "absolute", left = 664, top = 24, width = 64, height = 64,
        clickable = true, backgroundImage = "image/ui/dialog/help_button.png", backgroundFit = "contain",
        onClick = function() if context_.showTowerRules then context_.showTowerRules() end end,
    }
    refs_.lootTrayIcon = context_.UI.Panel {position = "absolute", left = 10, top = 8, width = 44, height = 44, backgroundImage = lastLootIcon_ or assets.items.chest, backgroundFit = "contain"}
    refs_.lootTrayLabel = context_.compactTxt(lastLootText_, 18, C().gold, {position = "absolute", left = 68, top = 18, width = 410, textStroke = {width = 2, color = "#000000"}})
    local lootTray = context_.UI.Panel {position = "absolute", left = 26, bottom = 20, width = 520, height = 60, backgroundImage = assets.ui.lootBarGold, backgroundFit = "contain", children = {refs_.lootTrayIcon, refs_.lootTrayLabel}}
    root:AddChild(powerCard)
    root:AddChild(rulesButton)
    root:AddChild(floorBadge)
    root:AddChild(hpFrame)
    root:AddChild(enemyHpFrame)
    root:AddChild(settingsButton)
    root:AddChild(runButton)
    root:AddChild(lootTray)
    PlayPresentation.Update(0)
    return root
end

local function Update(dt)
    if not refs_.player then return end
    local assets = Assets()
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
    if requestedAutoRun_ ~= nil and game.autoRun == requestedAutoRun_ then requestedAutoRun_ = nil; pendingAutoRun_ = nil end
    local visualAutoRun = game.autoRun
    if requestedAutoRun_ ~= nil then visualAutoRun = requestedAutoRun_ end
    local current = roadEvents_[1]
    local currentDistance = current and (current.x - presentationX_ - context_.playerScreenX) or 9999
    local shouldStopForEvent = currentEventLocked_ and current and current.kind == "enemy"
    local speed = (visualAutoRun and not shouldStopForEvent) and context_.presentationSpeed or 0
    presentationX_ = presentationX_ + speed * dt
    currentDistance = current and (current.x - presentationX_ - context_.playerScreenX) or 9999
    local inTriggerRange = current and currentDistance <= context_.eventTriggerDistance
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

    local bgShift = -(presentationX_ % (context_.bgTileW * 2))
    refs_.bgTiles[1]:SetStyle({left = bgShift, top = 0, height = metrics_.height})
    refs_.bgTiles[2]:SetStyle({left = bgShift + context_.bgTileW, top = 0, height = metrics_.height})
    refs_.bgTiles[3]:SetStyle({left = bgShift + context_.bgTileW * 2, top = 0, height = metrics_.height})
    local currentEvent = roadEvents_[1]
    local distance = currentEvent and (currentEvent.x - presentationX_ - context_.playerScreenX) or 9999
    local isAttacking =
        currentEventLocked_
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
    local movementFrames = visualAutoRun
        and job.run
        or job.idle
    local activeParams = isAttacking
        and context_.getAttackParams(
            currentAttackFrames_ or attackFrames,
            context_.currentPlayer()
        )
        or context_.getRunParams()
    local activeFps = isAttacking and (CombatSequence.Get(combatSequenceIndex_ or 1) or {}).fps or (visualAutoRun and activeParams.fps or 8)
    local sequenceTime = math.max(0, combatAnimationTime_ - combatSequenceStartTime_)
    local playerImage = isAttacking
        and AttackFrameAt(
            currentAttackFrames_ or attackFrames,
            sequenceTime
        )
        or FrameAt(movementFrames, activeFps)
    local walkBob = (visualAutoRun and not isAttacking) and math.sin(animationTime_ * 6.0) * 3 or math.sin(animationTime_ * 2.0) * 2
    local walkLean = (visualAutoRun and not isAttacking) and math.sin(animationTime_ * 6.0) * 4 or 0
    local attackPulse = isAttacking and math.max(0, math.sin(combatAnimationTime_ * 11.0)) or 0
    local actionLeft = context_.playerScreenX - (context_.runW - context_.playerSize) * 0.42
    local actionTop = context_.roadY - context_.runH + 20
    local useActionBox = isAttacking or not isPicking
    local targetLeft = useActionBox and (actionLeft + activeParams.x) or context_.playerScreenX
    local targetTop = useActionBox and (actionTop + activeParams.y) or context_.platformPlayerY
    local targetW = useActionBox and activeParams.w or context_.playerSize
    local targetH = useActionBox and activeParams.h or context_.playerSize
    local targetScale = useActionBox and activeParams.scale or 1.0
    local playerStyle = {left = targetLeft + walkLean + attackPulse * 3, top = targetTop + walkBob - attackPulse * 2, width = targetW, height = targetH, scale = targetScale + (isAttacking and attackPulse * 0.04 or 0)}
    if playerImage ~= currentPlayerImage_ then playerStyle.backgroundImage = playerImage; currentPlayerImage_ = playerImage end
    refs_.player:SetStyle(playerStyle)
    refs_.playerShadow:SetStyle({left = context_.playerScreenX + 42 + walkLean + attackPulse * 3, top = context_.roadY - 8})
    for index, node in ipairs(refs_.objects) do
        local event = roadEvents_[index]
        if event then
            local x = event.x - presentationX_
            local size = event.kind == "enemy" and context_.enemySize or context_.lootSize
            if index == 1 and currentEventLocked_ and event.kind == "enemy" then
                x = metrics_.enemyAnchorX - size * 0.5
            end
            local top = event.kind == "enemy" and (context_.roadY - context_.enemySize + EnemyFootOffset(event.eventType)) or (context_.roadY - context_.lootSize + context_.lootFootOffset)
            local active = index == 1 and (isAttacking or isPicking)
            local pulse = active and math.sin(animationTime_ * 18) * 5 or 0
            node:SetStyle({visible = x > -180 and x < 1180, left = x, top = top + pulse, width = size, height = size, backgroundImage = event.image, opacity = (index == 1 and isAttacking) and 0.86 or 1.0, scale = active and 1.05 or 1.0})
        else
            node:SetStyle({visible = false})
        end
    end
    if refs_.event then
        local eventType = currentEvent and currentEvent.eventType or "monster"
        local actionText = isAttacking and "正在攻击" or (isPicking and "正在拾取" or "向右移动")
        refs_.event:SetText(actionText .. " / " .. ((context_.eventInfo[eventType] and context_.eventInfo[eventType].name) or "前方道路"))
        refs_.event:SetFontColor((context_.eventInfo[eventType] and context_.eventInfo[eventType].color) or C().primary)
    end
    if refs_.progress then refs_.progress:SetText("第" .. tostring(game.floor or 1) .. "层 · " .. tostring(game.room or 1) .. "/10") end
    if refs_.lootLabel then refs_.lootLabel:SetText(lastLootText_) end
    if refs_.lootTrayLabel then refs_.lootTrayLabel:SetText(lastLootText_) end
    if refs_.lootTrayIcon and lastLootIcon_ then refs_.lootTrayIcon:SetStyle({backgroundImage = lastLootIcon_}) end
    local playerMaxHp = game.playerMaxHp
        or (game.stats and (game.stats.hpBig or game.stats.hp)) or 1
    local playerHp = game.hpBig or game.hp or 0
    if refs_.hpFill then context_.setImageProgress(refs_.hpFill, 420, playerHp, playerMaxHp) end
    if refs_.enemyHpFill then
        context_.setImageProgress(refs_.enemyHpFill, 420, currentMonsterHp_, currentMonsterMaxHp_)
    end
    if refs_.playerHpText then
        local ratio = MagnitudeRatio(playerHp, playerMaxHp)
        refs_.playerHpText:SetText(context_.formatInt(playerHp) .. " / " .. context_.formatInt(playerMaxHp) .. "  ·  " .. string.format("%.1f%%", ratio * 100))
    end
    if refs_.enemyHpText then
        local hasMonster = game.currentMonster ~= nil or currentEventLocked_
        local displayMaxHp = hasMonster and currentMonsterMaxHp_ or 0
        local displayHp = hasMonster and currentMonsterHp_ or 0
        local ratio = MagnitudeRatio(displayHp, displayMaxHp)
        refs_.enemyHpText:SetText(context_.formatInt(displayHp) .. " / " .. context_.formatInt(displayMaxHp) .. "  ·  " .. string.format("%.1f%%", ratio * 100))
    end
    if refs_.enemyName then
        local monster = game.currentMonster
        refs_.enemyName:SetText((monster and (monster.name or monster.encounterKind or monster.eventType)) or "等待敌人")
    end
    local displayedPower = game.displayedPower or (game.stats and game.stats.power)
    if refs_.powerCurrent then refs_.powerCurrent:SetText(displayedPower ~= nil and ("当前战力 " .. context_.formatInt(displayedPower)) or "当前战力 待评估") end
    if refs_.powerRecommended then refs_.powerRecommended:SetText(game.recommendedPower ~= nil and ("本层推荐 " .. context_.formatInt(game.recommendedPower)) or "本层推荐 待同步") end
    if refs_.powerStatus then
        local ratioText = game.powerRatio and string.format("%.1f%%", game.powerRatio * 100) or "--"
        local floorText = game.estimatedEasyFloor and (" · 预计轻松至" .. tostring(math.floor(game.estimatedEasyFloor)) .. "层") or ""
        refs_.powerStatus:SetText((game.difficultyLabel or "待评估") .. " · 战力比 " .. ratioText .. floorText)
        refs_.powerStatus:SetFontColor((game.powerRatio or 0) >= 0.92 and C().success or ((game.powerRatio or 0) >= 0.88 and C().warning or C().hp))
    end
    if refs_.runButtonLabel then refs_.runButtonLabel:SetText(pendingAutoRun_ and "同步中" or (visualAutoRun and "刷宝中" or "开始刷宝")) end
    local runButtonUnavailable = game.readOnly or context_.loadingController.IsPlayAssetLoading()
    refs_.runButton:SetDisabled(runButtonUnavailable or pendingAutoRun_)
    refs_.runButton:SetStyle({opacity = runButtonUnavailable and 0.45 or (pendingAutoRun_ and 0.72 or 1.0)})

    if pickupFx_ then
        pickupFx_.age = pickupFx_.age + dt
        local rarityInfo = context_.rarities and (context_.rarities[pickupFx_.rarity] or context_.rarities.common) or nil
        local beamColor = rarityInfo and (rarityInfo.beam or rarityInfo.color) or {220, 235, 255, 240}
        if rarityInfo and rarityInfo.dynamic then
            local phase = pickupFx_.age * 5.5
            beamColor = {
                math.floor(128 + 127 * math.sin(phase)),
                math.floor(128 + 127 * math.sin(phase + 2.094)),
                math.floor(128 + 127 * math.sin(phase + 4.188)),
                250,
            }
        end
        local beamEnd = 0.45
        local hoverEnd = 0.75
        local temporaryBox = pickupFx_.outcome == "temporary_box" or pickupFx_.outcome == "temporary_loot"
        local endX = temporaryBox and 62 or 58
        local endY = temporaryBox and (metrics_.height - 56) or (metrics_.height - 50)
        pickupFx_.endX, pickupFx_.endY = endX, endY
        if pickupFx_.age <= hoverEnd then
            local hover = math.sin(pickupFx_.age * 15) * 5
            refs_.pickup:SetStyle({
                visible = true, left = pickupFx_.startX, top = pickupFx_.startY + hover,
                width = context_.lootSize, height = context_.lootSize,
                backgroundImage = pickupFx_.image, opacity = 1, scale = 1.0 + math.sin(pickupFx_.age * 10) * 0.06,
            })
            local beamOpacity = pickupFx_.age <= beamEnd and (0.72 + math.sin(pickupFx_.age * 22) * 0.18)
                or Clamp(1 - (pickupFx_.age - beamEnd) / (hoverEnd - beamEnd), 0, 1)
            refs_.lootBeam:SetStyle({
                visible = beamOpacity > 0,
                left = pickupFx_.startX + context_.lootSize * 0.5 - 56,
                top = context_.roadY - 300,
                opacity = beamOpacity,
                scale = 0.96 + math.sin(pickupFx_.age * 18) * 0.05,
                borderLeftColor = beamColor,
                borderRightColor = beamColor,
                backgroundGradient = { type = "linear", direction = "to-top", from = beamColor, to = {beamColor[1], beamColor[2], beamColor[3], 0} },
            })
            refs_.pickupSpark:SetStyle({visible = false})
        else
            local t = Clamp((pickupFx_.age - hoverEnd) / math.max(0.01, pickupFx_.duration - hoverEnd), 0, 1)
            local ease = 1 - (1 - t) * (1 - t)
            local x = pickupFx_.startX + (endX - pickupFx_.startX) * ease
            local y = pickupFx_.startY + (endY - pickupFx_.startY) * ease - math.sin(t * math.pi) * 76
            local size = context_.lootSize * (1.0 - 0.62 * ease)
            refs_.lootBeam:SetStyle({visible = false})
            refs_.pickup:SetStyle({visible = t < 1, left = x, top = y, width = size, height = size, backgroundImage = pickupFx_.image, opacity = 1.0 - t * 0.12, scale = 1.0 + math.sin(t * math.pi) * 0.22})
            refs_.pickupSpark:SetStyle({visible = t > 0.72 and t < 1 and endY < metrics_.height, left = endX - 10, top = endY - 10, opacity = (1 - t) * 2.0, scale = 0.7 + t * 0.8})
            if t >= 1 then pickupFx_ = nil end
        end
    else
        refs_.lootBeam:SetStyle({visible = false})
        refs_.pickup:SetStyle({visible = false})
        refs_.pickupSpark:SetStyle({visible = false})
    end
    for index = #enemyDamageBursts_, 1, -1 do
        local burst = enemyDamageBursts_[index]
        burst.age = burst.age + dt
        if burst.age >= 1.05 then table.remove(enemyDamageBursts_, index) end
    end
    for index, label in ipairs(refs_.enemyDamageLabels) do
        local burst = enemyDamageBursts_[index]
        if burst and burst.age >= 0 then
            local age = burst.age
            label:SetText(burst.text)
            label:SetStyle({visible = age < 0.95, left = burst.baseX + math.sin(age * 22.0 + (burst.variant or 1)) * 7, top = burst.baseY - age * (78 + (burst.variant or 1) * 4), fontColor = {255, 83, 93, math.floor(255 * math.max(0, 1 - age / 0.95))}, scale = 1.0 + math.max(0, 1 - age * 4.0) * 0.42})
        else
            label:SetStyle({visible = false})
        end
    end
    for index = #playerFeedbackBursts_, 1, -1 do
        local burst = playerFeedbackBursts_[index]
        burst.age = burst.age + dt
        if burst.age >= 1.25 then table.remove(playerFeedbackBursts_, index) end
    end
    for index, label in ipairs(refs_.playerFeedbackLabels or {}) do
        local burst = playerFeedbackBursts_[index]
        if burst then
            local age = burst.age
            local color = burst.color or C().hp
            label:SetText(burst.text)
            label:SetStyle({
                visible = age < 1.15,
                left = metrics_.playerAnchorX - 180 + (burst.lane or 0) * 8,
                top = context_.platformPlayerY - 42 - age * 82 - (burst.lane or 0) * 13,
                fontColor = {color[1], color[2], color[3], math.floor(255 * math.max(0, 1 - age / 1.15))},
                scale = burst.source == "revive" and (1.18 + math.sin(age * 9) * 0.08) or (1.0 + math.max(0, 1 - age * 5) * 0.25),
            })
        else
            label:SetStyle({visible = false})
        end
    end
    if floatingText_ then
        floatingText_.age = floatingText_.age + dt
        refs_.floatLabel:SetText(floatingText_.text)
        refs_.floatLabel:SetStyle({visible = floatingText_.age < 1.0, left = context_.playerScreenX + 120, top = context_.platformPlayerY - 52 - floatingText_.age * 70, fontColor = {255, 217, 61, math.floor(255 * math.max(0, 1 - floatingText_.age / 1.0))}})
        if floatingText_.age >= 1.0 then floatingText_ = nil end
    else
        refs_.floatLabel:SetStyle({visible = false})
    end
end

function PlayPresentation.Configure(context)
    context_ = context
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

local function VisualEventKey(group, value)
    if value.eventId ~= nil then
        return group .. ":event:" .. tostring(value.eventId)
    end
    local serial = value.attackSerial or value.sequenceSerial or value.monsterAttackSerial
    local hitIndex = value.hitIndex or value.sequenceHitIndex
    local amount = value.amountBig or value.damageBig or value.amount or value.damage
    local remainingHp = value.targetHpBig or value.monsterHpBig or value.hpBig
        or value.playerHpBig or value.targetHp or value.monsterHp or value.hp or value.playerHp
    if serial == nil and hitIndex == nil and amount == nil and remainingHp == nil then
        return nil
    end
    return table.concat({
        group,
        tostring(serial or ""),
        tostring(hitIndex or ""),
        MagnitudeKey(amount),
        MagnitudeKey(remainingHp),
        tostring(value.source or ""),
    }, ":")
end

local function ShouldRenderVisual(seen, group, value)
    local key = VisualEventKey(group, value)
    if key == nil then return true end
    if seen[key] then return false end
    seen[key] = true
    return true
end

function PlayPresentation.HandleDelta(payload)
    local game = Game()
    local seenVisualEvents = {}
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
            local sequenceIndex = value.sequenceIndex or tonumber(value.sequenceId)
                or ({A = 1, B = 2, C = 3})[value.sequenceId]
            SetCombatSequence(
                sequenceIndex,
                value.hitFrame or (value.hitFrames and value.hitFrames[1]),
                value.attackSerial,
                value.windupSeconds,
                value.recoverySeconds or value.durationSeconds,
                value.endFrame
            )
        elseif kind == "battle_hit" or kind == "damage_dealt" or kind == "player_attack_hit" then
            if ShouldRenderVisual(seenVisualEvents, "enemy_hit", value) then
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
            if ShouldRenderVisual(seenVisualEvents, "player_damage", value) then
                AddPlayerFeedback("-" .. context_.formatInt(
                    value.amountBig or value.damageBig or value.amount or value.damage or 0), C().hp, "damage")
            end
        elseif kind == "player_healed" or kind == "life_steal" then
            if ShouldRenderVisual(seenVisualEvents, "player_heal", value) then
                local source = value.source == "life_steal" and "lifesteal" or value.source
                local color = source == "floor_rest" and C().focus or (source == "revive" and C().focus or C().success)
                local prefix = source == "floor_rest" and "休整 +" or (source == "revive" and "复活 +" or "吸血 +")
                AddPlayerFeedback(prefix .. context_.formatInt(value.amountBig or value.amount or 0), color, source)
            end
        elseif kind == "player_died" then
            AddPlayerFeedback("角色倒下", C().hp, "death")
        elseif kind == "player_revived" then
            AddPlayerFeedback("复活 · 返回本层第1场", C().focus, "revive")
        elseif kind == "floor_reset" then
            ClearCombatPresentation(false)
            AddPlayerFeedback("本层重置", C().focus, "floor_rest")
        elseif kind == "boss_enraged" then
            AddEnemyDamageBurst("Boss 狂暴!", metrics_.enemyAnchorX - 180, context_.roadY - context_.enemySize - 90, 0, 4)
        elseif kind == "battle_won" or kind == "monster_defeated" then
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
        elseif kind == "battle_reward" then
            lastLootText_ = "金币+" .. context_.formatInt(value.gold or 0) .. " 经验+" .. context_.formatInt(value.exp or 0)
            lastLootIcon_ = Assets().items.gold
        elseif kind == "loot_dropped" or kind == "equipment_drop" then
            local icon = LootIcon(value)
            local rarity = value.rarity or "common"
            local rarityName = context_.rarityName and context_.rarityName(rarity) or rarity
            local text = tostring(value.name or rarityName .. " " .. tostring(value.slot or "装备"))
            TriggerPickupVisual(icon, metrics_.enemyAnchorX - context_.lootSize * 0.5, context_.roadY - context_.lootSize, text, rarity)
        elseif kind == "loot_settled" then
            if pickupFx_ then pickupFx_.outcome = value.outcome or value.destination end
            if value.outcome == "temporary_box" or value.outcome == "temporary_loot" then
                lastLootText_ = "已进入临时战利品箱"
            end
        elseif kind == "chest_reward" then
            lastLootText_ = "宝箱+" .. context_.formatInt(value.gold or 0)
            lastLootIcon_ = Assets().items.chest
        elseif kind == "story_gate" and context_.showStoryGate then
            context_.showStoryGate(value)
        elseif kind == "equipment_upgrade_available" and context_.showEquipmentUpgrade then
            context_.showEquipmentUpgrade(value)
        elseif (kind == "aid_pending" or kind == "tower_aid_requested") and context_.showAidPrompt then
            context_.showAidPrompt(value)
        elseif kind == "equipment_reverted" or kind == "equip_undone" then
            context_.UI.Toast.Show("已撤回上一次自动换装", {duration = 2, variant = "info", position = "bottom"})
        end
    end
    context_.updateTopBar()
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
    if game.pendingEquipDecision and context_.showEquipmentUpgrade then
        context_.showEquipmentUpgrade(game.pendingEquipDecision)
    end
    if requestedAutoRun_ ~= nil and game.autoRun == requestedAutoRun_ then
        requestedAutoRun_ = nil
        pendingAutoRun_ = nil
    end
end

function PlayPresentation.SetAutoRun(enabled)
    return SetAutoRun(enabled)
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
    nextEventId_ = 1
    presentationX_ = 0
    animationTime_ = 0
    pickupFx_ = nil
    playerFeedbackBursts_ = {}
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
