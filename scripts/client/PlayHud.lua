local PlayHud = {}

local ports_ = nil
local refs_ = {}

local CHAPTER_PROGRESS = {
    width = 760,
    height = 34,
    borderWidth = 4,
    contentLeft = 0,
    contentTop = 0,
    contentWidth = 752,
    contentHeight = 26,
    rootLeft = 160,
    rootTop = 294,
    trackTop = 16,
}

local function Colors()
    return ports_.colors
end

local function BuildChapterProgressBar()
    local UI = ports_.UI
    local trackChildren = {}
    local fillClip = UI.Panel {
        position = "absolute",
        left = CHAPTER_PROGRESS.contentLeft,
        top = CHAPTER_PROGRESS.contentTop,
        width = 0,
        height = CHAPTER_PROGRESS.contentHeight,
        overflow = "hidden",
        pointerEvents = "none",
    }
    fillClip:AddChild(UI.Panel {
        position = "absolute", left = 0, top = 0,
        width = CHAPTER_PROGRESS.contentWidth,
        height = CHAPTER_PROGRESS.contentHeight,
        backgroundColor = Colors().primary,
        borderRadius = 0,
        pointerEvents = "none",
    })
    fillClip:AddChild(UI.Panel {
        position = "absolute", left = 0, top = 0,
        width = CHAPTER_PROGRESS.contentWidth,
        height = 8,
        backgroundColor = { 120, 205, 255, 150 },
        borderRadius = 0,
        pointerEvents = "none",
    })
    fillClip:AddChild(UI.Panel {
        position = "absolute", left = 0,
        top = CHAPTER_PROGRESS.contentHeight - 6,
        width = CHAPTER_PROGRESS.contentWidth,
        height = 6,
        backgroundColor = { 13, 126, 230, 255 },
        borderRadius = 0,
        pointerEvents = "none",
    })
    trackChildren[#trackChildren + 1] = fillClip

    local chapterNodes = {}
    for index = 1, 10 do
        local danger = index == 10
        local nodeWidth = danger and 5 or 3
        local nodeCenter = CHAPTER_PROGRESS.contentLeft
            + math.floor(CHAPTER_PROGRESS.contentWidth * index / 10)
        local node = UI.Panel {
            position = "absolute",
            left = nodeCenter - math.floor(nodeWidth / 2),
            top = CHAPTER_PROGRESS.contentTop,
            width = nodeWidth,
            height = CHAPTER_PROGRESS.contentHeight,
            backgroundColor = danger and Colors().gold or { 10, 16, 32, 190 },
            borderRadius = 0,
            pointerEvents = "none",
        }
        chapterNodes[#chapterNodes + 1] = node
        trackChildren[#trackChildren + 1] = node
    end

    local chapterLabel = ports_.compactTxt("第1章", 20, Colors().gold, {
        position = "absolute", left = 2, top = -34,
        width = 240, height = 30,
        textStroke = { width = 2, color = "#000000" },
    })
    local progressLabel = ports_.compactTxt("第1层 · 第1关", 20, Colors().text, {
        position = "absolute", right = 2, top = -34,
        width = 400, height = 30, textAlign = "right",
        textStroke = { width = 2, color = "#000000" },
    })
    local root = UI.Panel {
        position = "absolute",
        left = CHAPTER_PROGRESS.rootLeft,
        top = CHAPTER_PROGRESS.rootTop,
        width = CHAPTER_PROGRESS.width,
        height = CHAPTER_PROGRESS.trackTop + CHAPTER_PROGRESS.height,
        pointerEvents = "box-none",
        children = {
            chapterLabel,
            progressLabel,
            UI.Panel {
                position = "absolute", left = 0, top = CHAPTER_PROGRESS.trackTop,
                width = CHAPTER_PROGRESS.width,
                height = CHAPTER_PROGRESS.height,
                backgroundColor = { 8, 24, 56, 255 },
                borderWidth = CHAPTER_PROGRESS.borderWidth,
                borderColor = Colors().border,
                borderRadius = 0,
                boxShadow = { { x = 6, y = 6, blur = 0, color = { 0, 0, 0, 64 } } },
                overflow = "hidden",
                pointerEvents = "none",
                children = trackChildren,
            },
        },
    }
    refs_.chapterProgressFill = fillClip
    refs_.chapterLabel = chapterLabel
    refs_.chapterProgressLabel = progressLabel
    refs_.chapterProgressNodes = chapterNodes
    return root
end

local function BuildHealthFrames(assets)
    local playerProgress
    playerProgress, refs_.hpFill = ports_.imageProgress(
        420, 30, 1, 1,
        assets.ui.progressTrackHp,
        assets.ui.progressFillHp
    )
    local enemyProgress
    enemyProgress, refs_.enemyHpFill = ports_.imageProgress(
        420, 30, 0, 1,
        assets.ui.progressTrackHp,
        assets.ui.progressFillHp
    )
    refs_.playerHpText = ports_.compactTxt("", 17, Colors().text, {
        position = "absolute", left = 52, top = 105,
        width = 400, height = 28, textAlign = "center",
        textStroke = {width = 2, color = "#000000"},
    })
    refs_.enemyHpText = ports_.compactTxt("", 17, Colors().text, {
        position = "absolute", left = 52, top = 105,
        width = 400, height = 28, textAlign = "center",
        textStroke = {width = 2, color = "#000000"},
    })
    refs_.playerName = ports_.compactTxt("赤焰枪刃", 21, Colors().text, {
        position = "absolute", left = 40, top = 27,
        width = 434, height = 34, textAlign = "center",
        textStroke = {width = 2, color = "#000000"},
    })
    refs_.enemyName = ports_.compactTxt("等待敌人", 21, Colors().text, {
        position = "absolute", left = 40, top = 27,
        width = 434, height = 34, textAlign = "center",
        textStroke = {width = 2, color = "#000000"},
    })
    local playerFrame = ports_.UI.Panel {
        position = "absolute", left = 20, top = 112,
        width = 520, height = 160,
        backgroundImage = assets.ui.playHpFrame,
        backgroundFit = "contain",
        children = {
            refs_.playerName,
            ports_.UI.Panel {
                position = "absolute", left = 52, top = 72,
                width = 420, height = 30,
                children = {playerProgress},
            },
            refs_.playerHpText,
        },
    }
    local enemyFrame = ports_.UI.Panel {
        position = "absolute", right = 20, top = 112,
        width = 520, height = 160,
        backgroundImage = assets.ui.playHpFrame,
        backgroundFit = "contain",
        children = {
            refs_.enemyName,
            ports_.UI.Panel {
                position = "absolute", left = 52, top = 72,
                width = 420, height = 30,
                children = {enemyProgress},
            },
            refs_.enemyHpText,
        },
    }
    return playerFrame, enemyFrame
end

function PlayHud.Configure(ports)
    ports_ = assert(ports)
end

function PlayHud.Build(options)
    options = options or {}
    local UI = ports_.UI
    local assets = ports_.assets
    refs_ = {}

    local stashButton = UI.Button {
        position = "absolute", right = 252, top = 18,
        width = 180, height = 72,
        disabled = options.readOnly,
        alignItems = "center", justifyContent = "center",
        padding = 0, borderWidth = 0, boxShadow = {},
        backgroundImage = assets.ui.playAutoRunButton,
        backgroundFit = "contain",
        onClick = function()
            if ports_.onOpenLootStash then ports_.onOpenLootStash() end
        end,
        children = {
            ports_.compactTxt("暂存箱 " .. tostring(options.stashCount or 0), 19, Colors().text, {
                width = "100%", height = 72, left = 6, top = -7,
                textAlign = "center",
                textStroke = {width = 2, color = "#000000"},
                pointerEvents = "none",
            }),
        },
    }
    local settingsButton = UI.Panel {
        position = "absolute", right = 42, top = 1379,
        width = 72, height = 72,
        clickable = not options.readOnly,
        opacity = options.readOnly and 0.45 or 1.0,
        backgroundImage = assets.ui.idleSettings,
        backgroundFit = "contain",
        onClick = function()
            if ports_.onOpenIdleSettings then ports_.onOpenIdleSettings() end
        end,
    }

    refs_.runButtonLabel = ports_.compactTxt("开始刷宝", 20, Colors().text, {
        width = "100%", left = 2, top = -7,
        textAlign = "center",
        textStroke = {width = 2, color = "#000000"},
        pointerEvents = "none",
    })
    refs_.runButton = UI.Button {
        position = "absolute", right = 26, top = 20,
        width = 230, height = 72,
        disabled = options.readOnly,
        alignItems = "center", justifyContent = "center",
        padding = 0, paddingHorizontal = 0, paddingVertical = 0,
        borderWidth = 0, boxShadow = {},
        backgroundImage = assets.ui.playAutoRunButton,
        backgroundFit = "contain",
        onClick = function()
            if ports_.onToggleAutoRun then ports_.onToggleAutoRun() end
        end,
        children = {refs_.runButtonLabel},
    }

    refs_.powerCurrent = ports_.compactTxt("当前战力 待评估", 19, Colors().gold, {
        position = "absolute", left = 22, top = 12,
        width = 282, height = 28,
        textStroke = {width = 1, color = "#000000"},
    })
    refs_.powerRecommended = ports_.compactTxt("推荐战力 待同步", 18, Colors().textSecondary, {
        position = "absolute", left = 310, top = 12,
        width = 298, height = 28, textAlign = "right",
        textStroke = {width = 1, color = "#000000"},
    })
    refs_.powerStatus = ports_.compactTxt("战力评估同步中", 17, Colors().focus, {
        position = "absolute", left = 22, top = 46,
        width = 586, height = 26, textAlign = "center",
        textStroke = {width = 1, color = "#000000"},
    })
    local powerCard = UI.Panel {
        position = "absolute", left = 26, top = 16,
        width = 630, height = 80,
        backgroundImage = assets.ui.panelCompact,
        backgroundFit = "sliced",
        backgroundSlice = {12,12,12,12},
        children = {refs_.powerCurrent, refs_.powerRecommended, refs_.powerStatus},
    }
    local rulesButton = UI.Panel {
        position = "absolute", left = 664, top = 24,
        width = 64, height = 64,
        clickable = true,
        backgroundImage = "image/ui/dialog/help_button.png",
        backgroundFit = "contain",
        onClick = function()
            if ports_.onShowTowerRules then ports_.onShowTowerRules() end
        end,
    }

    local lootText = options.lootText or "等待掉落"
    refs_.lootTrayIcon = UI.Panel {
        position = "absolute", left = 10, top = 8,
        width = 44, height = 44,
        backgroundImage = options.lootIcon or assets.items.chest,
        backgroundFit = "contain",
    }
    refs_.lootTrayLabel = ports_.compactTxt(lootText, 18, Colors().gold, {
        position = "absolute", left = 68, top = 10,
        width = 430, height = 42, textAlign = "left",
        textStroke = {width = 2, color = "#000000"},
        pointerEvents = "none",
    })
    local lootTray = UI.Panel {
        position = "absolute", left = 26, bottom = 20,
        width = 520, height = 76,
        backgroundImage = assets.ui.lootBarGold,
        backgroundFit = "contain",
        children = {refs_.lootTrayIcon, refs_.lootTrayLabel},
    }
    local playerFrame, enemyFrame = BuildHealthFrames(assets)

    return {
        powerCard,
        rulesButton,
        BuildChapterProgressBar(),
        playerFrame,
        enemyFrame,
        stashButton,
        settingsButton,
        refs_.runButton,
        lootTray,
    }
end

function PlayHud.Update(state)
    if not refs_.runButton then return end

    local floor = math.max(1, math.floor(tonumber(state.floor) or 1))
    local room = math.max(1, math.min(10, math.floor(tonumber(state.room) or 1)))
    local chapter = math.floor((floor - 1) / 10) + 1
    local chapterFloor = ((chapter - 1) * 10) + 1
    local chapterStep = (floor - chapterFloor) * 10 + (state.floorRouteStep or 0)
    local progress = math.max(0, math.min(1, chapterStep / 100))
    refs_.chapterProgressFill:SetStyle({
        width = CHAPTER_PROGRESS.contentWidth * progress,
    })
    refs_.chapterLabel:SetText(string.format("第%d章", chapter))
    refs_.chapterProgressLabel:SetText(string.format("第%d层 · 第%d关", floor, room))
    for index, node in ipairs(refs_.chapterProgressNodes or {}) do
        node:SetStyle({opacity = progress + 0.000001 >= index / 10 and 1.0 or 0.35})
    end

    refs_.lootTrayLabel:SetText(state.lootText or "等待掉落")
    local rarity = ports_.rarities
        and (ports_.rarities[state.lootRarity] or ports_.rarities.gold_green)
    refs_.lootTrayLabel:SetFontColor(rarity and rarity.color or Colors().gold)
    if state.lootIcon then refs_.lootTrayIcon:SetStyle({backgroundImage = state.lootIcon}) end

    ports_.setImageProgress(refs_.hpFill, 420, state.playerHp, state.playerMaxHp)
    ports_.setImageProgress(refs_.enemyHpFill, 420, state.enemyHp, state.enemyMaxHp)
    refs_.playerHpText:SetText(
        ports_.formatInt(state.playerHp) .. " / " .. ports_.formatInt(state.playerMaxHp)
            .. "  ·  " .. string.format("%.1f%%", (state.playerHpRatio or 0) * 100)
    )
    refs_.enemyHpText:SetText(
        ports_.formatInt(state.enemyHp) .. " / " .. ports_.formatInt(state.enemyMaxHp)
            .. "  ·  " .. string.format("%.1f%%", (state.enemyHpRatio or 0) * 100)
    )
    refs_.enemyName:SetText(state.enemyName or "等待敌人")

    refs_.powerCurrent:SetText(state.displayedPower ~= nil
        and ("当前战力 " .. ports_.formatInt(state.displayedPower))
        or "当前战力 待评估")
    refs_.powerRecommended:SetText(state.recommendedPower ~= nil
        and ("本层推荐 " .. ports_.formatInt(state.recommendedPower))
        or "本层推荐 待同步")
    local ratioText = state.powerRatio and string.format("%.1f%%", state.powerRatio * 100) or "--"
    local floorText = state.estimatedEasyFloor
        and (" · 预计轻松至" .. tostring(math.floor(state.estimatedEasyFloor)) .. "层")
        or ""
    refs_.powerStatus:SetText((state.difficultyLabel or "待评估") .. " · 战力比 " .. ratioText .. floorText)
    refs_.powerStatus:SetFontColor((state.powerRatio or 0) >= 0.92
        and Colors().success
        or ((state.powerRatio or 0) >= 0.88 and Colors().warning or Colors().hp))

    refs_.runButtonLabel:SetText(state.pendingAutoRun
        and "同步中"
        or (state.visualAutoRun and "刷宝中" or "开始刷宝"))
    local unavailable = state.readOnly or state.assetsLoading
    refs_.runButton:SetDisabled(unavailable or state.pendingAutoRun)
    refs_.runButton:SetStyle({
        opacity = unavailable and 0.45 or (state.pendingAutoRun and 0.72 or 1.0),
    })
end

function PlayHud.Reset()
    refs_ = {}
end

return PlayHud
