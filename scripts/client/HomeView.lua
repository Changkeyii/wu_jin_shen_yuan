local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DailyVipView = require("client.DailyVipView")
local LeaderboardController = require("client.LeaderboardController")
local MailController = require("client.MailController")
local QuestController = require("client.QuestController")

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

local function HomeActionButton(text, left, top, onClick, badge)
    local button = UI.Panel {
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

-- 邮件入口（首页左上区域最顶端）：信封图标 + 正下方「邮件」文字。
-- 单击打开邮件；长按 5 秒进 GM（仅管理员，服务端校验）。带未读红点。
local function MailEntry(left, top, game)
    local summary = (game and game.mailSummary) or {}
    local unread = math.max(0, math.floor(tonumber(summary.unread) or 0))
    -- 放大后的邮件入口：信封图标放大 + 「邮件」文字在图标正下方。
    -- 总高度控制在角色立绘上方，避免遮挡下方角色面板。
    local iconSize = 132
    local labelHeight = 44
    local width = iconSize
    local height = iconSize + labelHeight
    return UI.Panel {
        position = "absolute",
        left = left,
        top = top,
        width = width,
        height = height,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        onPointerDown = function() MailController.SetPressing(true) end,
        onPointerUp = function() MailController.SetPressing(false) end,
        onPointerCancel = function() MailController.SetPressing(false) end,
        onClick = function()
            MailController.SetPressing(false)
            MailController.Open()
        end,
        children = {
            -- 信封图标本体（透明背景，非方形卡片）
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                width = iconSize,
                height = iconSize,
                backgroundImage = ASSETS.ui.mailIcon,
                backgroundFit = "contain",
                pointerEvents = "none",
            },
            -- 正下方「邮件」文字
            Kit.Txt("邮件", 32, C.text, {
                position = "absolute",
                left = 0,
                top = iconSize - 4,
                width = width,
                height = labelHeight,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
            -- 未读红点（固定正圆，数字几何居中；超过 99 显示 99+）
            unread > 0 and UI.Panel {
                position = "absolute",
                right = 4,
                top = 6,
                width = 52,
                height = 52,
                alignItems = "center",
                justifyContent = "center",
                shape = "circle",
                overflow = "hidden",
                backgroundColor = C.error,
                borderWidth = 2,
                borderColor = { 0, 0, 0, 120 },
                children = {
                    Kit.CompactTxt(unread > 99 and "99+" or tostring(unread), 26, C.text, {
                        width = "100%",
                        height = 52,
                        textAlign = "center",
                        textStroke = { width = 1, color = "#000000" },
                        pointerEvents = "none",
                    }),
                },
            } or nil,
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
                + QuestController.CountClaimable(game, "achievement")),
            HomeActionButton("活动", 596, 378, function()
                ShowFeaturePreview("活动")
            end),
            HomeActionButton("排行榜", 596, 440, function()
                LeaderboardController.Open()
            end),
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

    -- 邮件入口固定在首页左上（ScrollView 之外），避免短屏滚动时被 ScrollView 的
    -- pan 手势取消长按状态（UI.CancelPointer 会中断按压）。
    return UI.Panel {
        width = "100%", height = "100%", position = "relative",
        children = {
            UI.ScrollView {
                width = "100%", height = "100%",
                scrollX = false, scrollY = true, showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%", flexShrink = 0,
                        alignItems = "center",
                        children = {
                            heroPanel,
                            statGrid,
                        },
                    },
                },
            },
            MailEntry(16, 10, game),
        },
    }
end

return HomeView
