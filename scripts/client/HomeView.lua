local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DailyVipView = require("client.DailyVipView")
local LeaderboardController = require("client.LeaderboardController")
local MailController = require("client.MailController")
local QuestController = require("client.QuestController")
local ActivityController = require("client.ActivityController")
local StoryBrowserController = require("client.StoryBrowserController")

local C = GameTheme.Colors
local CONFIG = GameTheme.CONFIG
local ASSETS = ViewAssets.ASSETS

local HomeView = {}

local function FormalStatCard(label, value, color, icon, width, height)
    local cardW = width or 600
    local cardH = height or 400
    local iconSize = math.floor(cardH * 0.44)
    local textW = math.floor(cardW * 0.623)
    return UI.Panel {
        width = cardW,
        height = cardH,
        position = "relative",
        backgroundImage = ASSETS.ui.statCard,
        backgroundFit = "contain",
        children = {
            UI.Panel {
                position = "absolute",
                left = 52,
                top = math.floor((cardH - iconSize) * 0.52),
                width = iconSize,
                height = iconSize,
                backgroundImage = icon,
                backgroundFit = "contain",
            },
            Kit.Txt(label, 22, C.textSecondary, {
                position = "absolute", right = 66, top = 63, width = textW,
                textAlign = "right", textStroke = { width = 2, color = "#000000" },
            }),
            Kit.Txt(value, 28, color or C.text, {
                position = "absolute", right = 68, bottom = 66, width = textW,
                textAlign = "right", textStroke = { width = 2, color = "#000000" },
            }),
        },
    }
end

local function ShowRules(game)
    CommonPromptDialog.Show {
        kind = "rules",
        queueKey = "rules:tower-reward",
        title = "登塔说明",
        message = "在线战斗收益为100%；离线收益固定按20%结算且只折算一次。",
        lines = {
            "每层10场：7普通、2精英、1 Boss；每10层为章节 Boss。",
            "死亡后回到本层第1场，双方满血，已获得奖励保留。",
            "离线金币、经验、碎片及最终掉落概率均为在线效率的1/5。",
            "离线时间最多累计 12 小时；背包已满时，未结算时间会保留。",
            "当前累计离线：" .. Kit.FormatDuration(game.pendingOfflineSeconds),
        },
        confirmText = "知道了",
    }
end

local function ShowFeaturePreview(name)
    UI.Toast.Show(name .. "功能正在筹备中", {
        duration = 1.8,
        variant = "info",
        position = "bottom",
    })
end

local function HomeActionButton(text, left, top, onClick, badge, buttonId)
    local button = UI.Panel {
        id = buttonId,
        position = "absolute",
        left = left,
        top = top,
        width = 300,
        height = 44,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        onClick = onClick,
        children = {
            Kit.Txt(text, 23, C.text, {
                position = "absolute", left = -2, top = 15, width = "100%",
                textAlign = "center", textStroke = { width = 3, color = "#000000" },
                pointerEvents = "none",
            }),
        },
    }
    if badge and badge > 0 then
        button:AddChild(UI.Panel {
            position = "absolute", right = -6, top = -8, width = 44, height = 44,
            shape = "circle", overflow = "hidden",
            backgroundColor = C.error,
            borderWidth = 2, borderColor = { 0, 0, 0, 120 },
            alignItems = "center", justifyContent = "center",
            children = {
                Kit.CompactTxt(badge > 99 and "99+" or tostring(badge), 20, C.text, {
                    width = "100%", height = 44, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                }),
            },
        })
    end
    return button
end

-- 左侧入口栏单项：图标 + 底部文字，底板由整条入口栏统一提供。
local function SideEntryItem(options)
    local iconSize = options.iconSize or 56
    local labelHeight = options.labelHeight or 28
    local width = options.width or 80
    local height = options.height or 96
    return UI.Panel {
        id = options.id,
        width = width,
        height = height,
        flexShrink = 0,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        onPointerDown = options.onPointerDown,
        onPointerUp = options.onPointerUp,
        onPointerCancel = options.onPointerCancel,
        onClick = options.onClick,
        children = {
            UI.Panel {
                position = "absolute",
                left = math.floor((width - iconSize) * 0.5),
                top = 0,
                width = iconSize,
                height = iconSize,
                backgroundImage = options.icon,
                backgroundFit = "contain",
                pointerEvents = "none",
            },
            Kit.Txt(options.label or "", options.labelSize or 18, options.labelColor or C.text, {
                position = "absolute",
                left = 0,
                top = iconSize + 2,
                width = width,
                height = labelHeight,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
            options.badge,
        },
    }
end

-- 剧情入口：放在邮件下方的左侧入口栏中。
local function StoryEntry()
    return SideEntryItem {
        id = "tutorialFeatureStory",
        icon = ASSETS.ui.storyMemoryIcon,
        label = "剧情",
        labelColor = C.gold,
        onClick = function()
            StoryBrowserController.Show()
        end,
    }
end

-- 邮件入口：左侧入口栏第一项。单击打开邮件；长按 5 秒进 GM（仅管理员，服务端校验）。
local function MailEntry(game)
    local summary = (game and game.mailSummary) or {}
    local unread = math.max(0, math.floor(tonumber(summary.unread) or 0))
    return SideEntryItem {
        id = "tutorialFeatureMail",
        icon = ASSETS.ui.mailIcon,
        label = "邮件",
        onPointerDown = function() MailController.SetPressing(true) end,
        onPointerUp = function() MailController.SetPressing(false) end,
        onPointerCancel = function() MailController.SetPressing(false) end,
        onClick = function()
            MailController.SetPressing(false)
            MailController.Open()
        end,
        badge = unread > 0 and UI.Panel {
            -- 未读红点（固定正圆，数字几何居中；超过 99 显示 99+）
            position = "absolute",
            right = -2,
            top = 2,
            width = 36,
            height = 36,
            alignItems = "center",
            justifyContent = "center",
            shape = "circle",
            overflow = "visible",
            backgroundColor = C.error,
            borderWidth = 2,
            borderColor = { 0, 0, 0, 120 },
            children = {
                Kit.CompactTxt(unread > 99 and "99+" or tostring(unread), 18, C.text, {
                    width = "100%",
                    height = 36,
                    textAlign = "center",
                    textStroke = { width = 1, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        } or nil,
    }
end

local function GameplayEntry(title, subtitle, accent, onClick, entryId)
    return UI.Panel {
        id = entryId,
        width = 480,
        height = 128,
        flexShrink = 0,
        position = "relative",
        clickable = true,
        backgroundColor = { 10, 31, 72, 242 },
        borderWidth = { 3, 5, 7, 3 },
        borderColor = { 10, 16, 32, 255 },
        boxShadow = { { x = 6, y = 6, blur = 0, color = { 0, 0, 0, 64 } } },
        onClick = onClick,
        children = {
            UI.Panel {
                position = "absolute", left = 12, top = 12, bottom = 12, width = 8,
                backgroundColor = accent, pointerEvents = "none",
            },
            Kit.Txt(title, 27, C.text, {
                position = "absolute", left = 42, top = 20, width = 400, height = 42,
                textAlign = "left", textStroke = { width = 3, color = "#000000" },
            }),
            Kit.CompactTxt(subtitle, 16, C.textSecondary, {
                position = "absolute", left = 42, top = 70, width = 400, height = 30,
                textAlign = "left", textStroke = { width = 1, color = "#000000" },
            }),
        },
    }
end

function HomeView.Build(context)
    context = context or {}
    local game = assert(context.game)
    local stats = game.stats
    local statCardW = 480
    local statCardH = 220
    local statGapX = 12
    local statRowGapY = 10
    local statGridW = statCardW * 2 + statGapX
    local statGridH = statCardH * 3 + statRowGapY * 2
    local statGridX = math.floor((CONFIG.DesignW - statGridW) * 0.5)

    -- 背景板容器：玩家信息、标题、VIP 徽标、三个按钮全部作为其子项，
    -- 保证这些内容绘制在背景板图片之上，不会被遮挡。
    local heroPanel = UI.Panel {
        width = 1048, height = 620, flexShrink = 0, position = "relative",
        backgroundImage = ASSETS.ui.heroPanel, backgroundFit = "contain",
        children = {
            UI.Panel {
                position = "absolute", left = 58, top = 148,
                width = 360, height = 310,
                alignItems = "center", justifyContent = "center",
                children = {
                    Kit.Txt("赤焰枪刃", 28, C.gold, {
                        position = "absolute", left = 72, top = 7, width = "100%", textAlign = "center",
                        textStroke = { width = 3, color = "#000000" },
                    }),
                    UI.Panel {
                        position = "absolute", left = 59, top = 67,
                        width = 360, height = 280,
                        backgroundImage = ViewAssets.CurrentPlayer().icon, backgroundFit = "contain",
                    },
                },
            },
            DailyVipView.HomeEntry {
                game = game,
                left = 696,
                top = 16,
                id = "tutorialFeatureVip",
                onOpen = context.onOpenDailyVip,
            },
            Kit.Txt("登塔", 34, C.text, {
                position = "absolute", left = 596, top = 196,
                width = 270, textAlign = "center",
                textStroke = { width = 4, color = "#000000" },
            }),
            UI.Panel {
                position = "absolute", left = 874, top = 184,
                width = 64, height = 64, clickable = true,
                backgroundImage = "image/ui/dialog/help_button.png", backgroundFit = "contain",
                onClick = function() ShowRules(game) end,
            },
            Kit.MultiTxt("解放双手", 22, C.textSecondary, {
                position = "absolute", left = 596, top = 254,
                width = 270, height = 52, maxLines = 2, textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            }),
            HomeActionButton("任务", 596, 316, function()
                QuestController.Open()
            end, QuestController.CountClaimable(game, "newbie")
                + QuestController.CountClaimable(game, "daily")
                + QuestController.CountClaimable(game, "achievement"), "tutorialFeatureQuest"),
            HomeActionButton("活动", 596, 378, function()
                ActivityController.Open()
            end, ActivityController.HasRedDot(game) and 1 or nil, "tutorialFeatureActivity"),
            HomeActionButton("排行榜", 596, 440, function()
                LeaderboardController.Open()
            end, nil, "tutorialFeatureLeaderboard"),
        },
    }

    -- 中间区域可能比设计高度矮（如 iPad 短屏）：首页内容放进垂直滚动容器，
    -- 短屏时可滚动查看完整内容，避免超出屏幕被裁剪。
    local statGrid = UI.Panel {
        width = statGridW, height = statGridH, flexShrink = 0,
        marginTop = -16, position = "relative",
        children = {
            UI.Panel { position = "absolute", left = 0, top = 0, width = statCardW, height = statCardH, children = { FormalStatCard("攻击", Kit.FormatInt(stats.atkBig or stats.atk), C.primary, ASSETS.ui.statAtk, statCardW, statCardH) } },
            UI.Panel { position = "absolute", left = statCardW + statGapX, top = 0, width = statCardW, height = statCardH, children = { FormalStatCard("防御", Kit.FormatInt(stats.defBig or stats.def), C.textSecondary, ASSETS.ui.statDef, statCardW, statCardH) } },
            UI.Panel { position = "absolute", left = 0, top = statCardH + statRowGapY, width = statCardW, height = statCardH, children = { FormalStatCard("暴击", Kit.FormatPercent(stats.crit), C.gold, ASSETS.ui.statCrit, statCardW, statCardH) } },
            UI.Panel { position = "absolute", left = statCardW + statGapX, top = statCardH + statRowGapY, width = statCardW, height = statCardH, children = { FormalStatCard("攻速", string.format("%.1f", stats.atkSpeed), C.mp, ASSETS.ui.statSpeed, statCardW, statCardH) } },
            UI.Panel { position = "absolute", left = 0, top = (statCardH + statRowGapY) * 2, width = statCardW, height = statCardH, children = { FormalStatCard("生命", Kit.FormatInt(game.hpBig or game.hp) .. "/" .. Kit.FormatInt(game.playerMaxHp or stats.hpBig or stats.hp), C.hp, ASSETS.ui.statHp, statCardW, statCardH) } },
            UI.Panel { position = "absolute", left = statCardW + statGapX, top = (statCardH + statRowGapY) * 2, width = statCardW, height = statCardH, children = { FormalStatCard("战力", (game.displayedPower or stats.power) and Kit.FormatInt(game.displayedPower or stats.power) or "待评估", C.gold, ASSETS.ui.statPower, statCardW, statCardH) } },
        },
    }

    local gameplayEntries = UI.Panel {
        width = statGridW,
        height = 156,
        flexShrink = 0,
        marginTop = 6,
        flexDirection = "row",
        justifyContent = "space-between",
        children = {
            GameplayEntry("许愿池", "许愿券抽取 · 十连8券", C.focus, function()
                require("client.NavigationController").SwitchPage("wish")
            end, "tutorialFeatureWish"),
            GameplayEntry("深渊远征", "4人数据团本 · 即将开放", C.mp, function()
                ShowFeaturePreview("深渊远征")
            end, "tutorialFeatureExpedition"),
        },
    }

    -- 左侧入口栏是覆盖层：不参与中间首页板布局，首页板始终居中。
    -- 外框位置/高度以 Inspector 视觉对齐结果为准，内部入口按高度自适应。
    local sideEntries = {
        MailEntry(game),
        StoryEntry(),
    }
    local sideEntryBarW = 88
    local sideEntryBarH = 506
    local sideEntryBarTop = 58
    local sideEntryPadY = 8
    local sideEntryGap = 4
    local innerH = math.max(1, sideEntryBarH - sideEntryPadY * 2 - math.max(0, #sideEntries - 1) * sideEntryGap)
    local sideEntryItemH = math.max(96, math.floor(innerH / math.max(1, #sideEntries)))
    for _, entry in ipairs(sideEntries) do
        if entry then
            entry.props = entry.props or {}
            entry.props.height = sideEntryItemH
        end
    end
    local sideEntryBar = UI.Panel {
        position = "absolute",
        left = 0,
        top = sideEntryBarTop,
        width = sideEntryBarW,
        height = sideEntryBarH,
        backgroundColor = { 6, 16, 38, 150 },
        borderWidth = 2,
        borderColor = { 80, 190, 255, 140 },
        borderRadius = 22,
        boxShadow = {
            color = { 50, 170, 255, 80 },
            offsetX = 0, offsetY = 0, blurRadius = 12,
        },
        overflow = "visible",
        children = {
            UI.ScrollView {
                width = "100%",
                height = "100%",
                scrollX = false,
                scrollY = true,
                showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%",
                        flexShrink = 0,
                        paddingTop = sideEntryPadY,
                        paddingBottom = sideEntryPadY,
                        alignItems = "center",
                        gap = sideEntryGap,
                        children = sideEntries,
                    },
                },
            },
        },
    }

    return UI.Panel {
        width = "100%", height = "100%", position = "relative",
        children = {
            UI.ScrollView {
                width = "100%", height = "100%",
                scrollX = false, scrollY = true, showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%",
                        flexShrink = 0,
                        alignItems = "center",
                        children = {
                            heroPanel,
                            statGrid,
                            gameplayEntries,
                        },
                    },
                },
            },
            sideEntryBar,
        },
    }
end

return HomeView
