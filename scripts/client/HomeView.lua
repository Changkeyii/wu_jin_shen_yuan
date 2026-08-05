local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local CommonPromptDialog = require("client.CommonPromptDialog")

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
        title = "挂机刷宝说明",
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

    return UI.Panel {
        width = "100%", height = "100%", position = "relative",
        children = {
            UI.Panel {
                position = "absolute", left = 16, top = 0,
                width = 1048, height = 620,
                backgroundImage = ASSETS.ui.heroPanel, backgroundFit = "contain",
            },
            UI.Panel {
                position = "absolute", left = 74, top = 148,
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
            Kit.Txt("挂机刷宝", 34, C.text, {
                position = "absolute", left = 612, top = 196,
                width = 270, textAlign = "center",
                textStroke = { width = 4, color = "#000000" },
            }),
            UI.Panel {
                position = "absolute", left = 890, top = 184,
                width = 64, height = 64, clickable = true,
                backgroundImage = "image/ui/dialog/help_button.png", backgroundFit = "contain",
                onClick = function() ShowRules(game) end,
            },
            Kit.MultiTxt("解放双手", 22, C.textSecondary, {
                position = "absolute", left = 612, top = 254,
                width = 270, height = 52, maxLines = 2, textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            }),
            UI.Panel {
                position = "absolute", left = 612, top = 316,
                width = 300, height = 168, pointerEvents = "box-none",
                children = {
                    UI.Panel {
                        position = "absolute", left = 0, top = 0, width = 300, height = 44,
                        clickable = true, alignItems = "center", justifyContent = "center",
                        onClick = context.onEnterPlay,
                        children = {
                            Kit.Txt("进入刷宝", 23, C.text, {
                                position = "absolute", left = -2, top = 15, width = "100%",
                                textAlign = "center", textStroke = { width = 3, color = "#000000" },
                                pointerEvents = "none",
                            }),
                        },
                    },
                    UI.Panel {
                        position = "absolute", left = 0, top = 62, width = 300, height = 44,
                        clickable = not game.readOnly, opacity = game.readOnly and 0.45 or 1.0,
                        alignItems = "center", justifyContent = "center",
                        onClick = function()
                            if game.readOnly then return end
                            local accepted = context.onToggleAutoRun and context.onToggleAutoRun(not game.autoRun)
                            if not accepted then
                                UI.Toast.Show("挂机状态正在同步，请稍候", {
                                    duration = 1.5, variant = "info", position = "bottom",
                                })
                            end
                        end,
                        children = {
                            Kit.Txt(game.autoRun and "暂停挂机" or "开始挂机", 23, C.text, {
                                position = "absolute", left = -2, top = 11, width = "100%",
                                textAlign = "center", textStroke = { width = 3, color = "#000000" },
                                pointerEvents = "none",
                            }),
                        },
                    },
                    UI.Panel {
                        position = "absolute", left = 0, top = 124, width = 300, height = 44,
                        clickable = not game.readOnly, opacity = game.readOnly and 0.45 or 1.0,
                        alignItems = "center", justifyContent = "center",
                        onClick = function()
                            if not game.readOnly and context.onCollectOffline then context.onCollectOffline() end
                        end,
                        children = {
                            Kit.Txt("领取离线", 23, C.text, {
                                position = "absolute", left = -4, top = 9, width = "100%",
                                textAlign = "center", textStroke = { width = 3, color = "#000000" },
                                pointerEvents = "none",
                            }),
                        },
                    },
                },
            },
            UI.Panel {
                position = "absolute", left = statGridX, top = 604,
                width = statGridW, height = statGridH,
                children = {
                    UI.Panel { position = "absolute", left = 0, top = 0, width = statCardW, height = statCardH, children = { FormalStatCard("攻击", Kit.FormatInt(stats.atkBig or stats.atk), C.primary, ASSETS.ui.statAtk, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = 0, width = statCardW, height = statCardH, children = { FormalStatCard("防御", Kit.FormatInt(stats.defBig or stats.def), C.textSecondary, ASSETS.ui.statDef, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = 0, top = statCardH + statRowGapY, width = statCardW, height = statCardH, children = { FormalStatCard("暴击", Kit.FormatPercent(stats.crit), C.gold, ASSETS.ui.statCrit, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = statCardH + statRowGapY, width = statCardW, height = statCardH, children = { FormalStatCard("攻速", string.format("%.1f", stats.atkSpeed), C.mp, ASSETS.ui.statSpeed, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = 0, top = (statCardH + statRowGapY) * 2, width = statCardW, height = statCardH, children = { FormalStatCard("生命", Kit.FormatInt(game.hpBig or game.hp) .. "/" .. Kit.FormatInt(game.playerMaxHp or stats.hpBig or stats.hp), C.hp, ASSETS.ui.statHp, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = (statCardH + statRowGapY) * 2, width = statCardW, height = statCardH, children = { FormalStatCard("战力", (game.displayedPower or stats.power) and Kit.FormatInt(game.displayedPower or stats.power) or "待评估", C.gold, ASSETS.ui.statPower, statCardW, statCardH) } },
                },
            },
        },
    }
end

return HomeView
