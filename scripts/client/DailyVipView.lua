local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local MarketCatalog = require("shared.MarketCatalog")
local ViewAssets = require("client.ViewAssets")
local ServerClock = require("client.ServerClock")
local Kit = require("client.ViewKit")

local DailyVipView = {}

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS
local MAX_VIP_LEVEL = MarketCatalog.MAX_VIP_LEVEL

-- 复用「筛选」弹窗的复选框素材，保持统一的选中态样式
local CHECKBOX_OFF = "image/ui/recycle_filter/checkbox_off.png"
local CHECKBOX_ON = "image/ui/recycle_filter/checkbox_on.png"

local function DayKey(now)
    return ServerClock.DayKey(now)
end

local function BenefitRows(vipLevel)
    local nextLevel = math.min(MAX_VIP_LEVEL, vipLevel + 1)
    return {
        string.format("战斗伤害加成  +%.1f%%", nextLevel * 0.5),
        string.format("市场手续费  %.1f%%", MarketCatalog.GetFeeRate(nextLevel) * 100),
        string.format("市场挂单槽位  %d 个", MarketCatalog.GetListingSlots(nextLevel)),
        string.format("出售强化金币返还  %d%%", math.min(55, 35 + nextLevel * 2)),
        string.format("分解投入返还  金币%d%% / 碎片%d%%",
            math.min(75, 45 + nextLevel * 3), math.min(80, 50 + nextLevel * 3)),
    }
end

local function ActionCard(options)
    local claimed = options.claimed == true
    local disabled = claimed or options.disabled == true
    return UI.Card {
        width = 704,
        height = 144,
        padding = 18,
        flexShrink = 0,
        backgroundColor = claimed and { 18, 52, 91, 220 } or { 24, 74, 145, 232 },
        borderColor = claimed and C.border or options.accent,
        children = {
            Kit.Txt(options.title, 20, claimed and C.textDim or C.text, {
                position = "absolute", left = 20, top = 18, width = 390, height = 30,
                textAlign = "left", textStroke = { width = 1, color = "#000000" },
            }),
            Kit.CompactTxt(options.description, 15, C.textSecondary, {
                position = "absolute", left = 20, top = 58, width = 390, height = 48,
                textAlign = "left", maxLines = 2,
            }),
            UI.Badge {
                position = "absolute", left = 20, bottom = 12,
                text = claimed and "已完成" or "每日一次",
                variant = claimed and "secondary" or "success",
            },
            UI.Panel {
                position = "absolute", right = 18, top = 40,
                width = 250, height = 64,
                children = {
                    Kit.ImageButton(
                        options.buttonText,
                        250,
                        64,
                        options.buttonImage,
                        options.onClick,
                        disabled
                    ),
                },
            },
        },
    }
end

local function BenefitPanel(vipLevel, atCap, benefitRows)
    local rows = {}
    for index, row in ipairs(benefitRows) do
        rows[#rows + 1] = UI.Panel {
            width = 330,
            height = 52,
            flexShrink = 0,
            paddingLeft = 14,
            paddingRight = 12,
            justifyContent = "center",
            backgroundColor = index % 2 == 0 and { 12, 36, 72, 220 } or { 8, 28, 64, 220 },
            borderWidth = 1,
            borderColor = C.border,
            borderRadius = 8,
            children = {
                Kit.CompactTxt(row, 15, C.textSecondary, {
                    width = "100%", height = 44, textAlign = "left", maxLines = 2,
                    textStroke = { width = 1, color = "#000000" },
                }),
            },
        }
    end
    return UI.Panel {
        width = 704,
        flexShrink = 0,
        gap = 10,
        children = {
            Kit.Txt(atCap and "当前满级权益" or ("升至 V" .. tostring(vipLevel + 1) .. " 后解锁"),
                20, C.gold, {
                    width = 704, height = 34, textAlign = "left",
                    textStroke = { width = 1, color = "#000000" },
                }),
            UI.Panel {
                width = 704,
                flexDirection = "row",
                flexWrap = "wrap",
                columnGap = 12,
                rowGap = 10,
                children = rows,
            },
        },
    }
end

function DailyVipView.BuildContent(game, options)
    options = options or {}
    local vipLevel = math.max(0, math.min(MAX_VIP_LEVEL, math.floor(tonumber(game.vipLevel) or 0)))
    local today = DayKey(ServerClock.Now())
    local dailyVip = type(game.dailyVip) == "table" and game.dailyVip or {}
    local atCap = vipLevel >= MAX_VIP_LEVEL
    local signInClaimed = atCap or dailyVip.signInDay == today
    local adClaimed = atCap or dailyVip.adDay == today
    local benefitRows = BenefitRows(vipLevel)
    ---@type Widget[]
    local children = {
        UI.Panel {
            width = 704,
            height = 112,
            flexShrink = 0,
            backgroundColor = { 8, 28, 64, 230 },
            borderWidth = 3,
            borderColor = C.focus,
            alignItems = "center",
            justifyContent = "center",
            children = {
                Kit.Txt("V" .. tostring(vipLevel), 40, C.gold, {
                    width = 180, textAlign = "center",
                    left = -252,
                    textStroke = { width = 3, color = "#000000" },
                }),
                Kit.CompactTxt(atCap and "已达到最高等级" or "今日最多可提升 2 级",
                    17, C.textSecondary, {
                        position = "absolute", right = 28, top = 42,
                        width = 400, textAlign = "center",
                    }),
            },
        },
        ActionCard {
            title = "每日签到",
            description = "直接领取，VIP 等级 +1",
            claimed = signInClaimed,
            disabled = options.requestPending == true,
            accent = C.success,
            buttonText = signInClaimed and (atCap and "已满级" or "今日已签到") or "领取 +1 VIP",
            buttonImage = ASSETS.ui.inventoryActionGold,
            onClick = options.onClaimSignIn,
        },
        ActionCard {
            title = "激励视频",
            description = "完整观看后领取，VIP 等级 +1",
            claimed = adClaimed,
            disabled = options.requestPending == true or options.adInFlight == true,
            accent = C.secondary,
            buttonText = adClaimed and (atCap and "已满级" or "奖励已领取")
                or (options.adInFlight and "广告播放中" or "看广告 +1 VIP"),
            buttonImage = ASSETS.ui.inventoryActionBlue,
            onClick = options.onWatchAd,
        },
        BenefitPanel(vipLevel, atCap, benefitRows),
    }
    if options.allowDoNotShowToday then
        local checked = options.doNotShowToday == true
        local checkImage = UI.Panel {
            width = 64,
            height = 64,
            flexShrink = 0,
            backgroundImage = checked and CHECKBOX_ON or CHECKBOX_OFF,
            backgroundFit = "contain",
            pointerEvents = "none",
        }
        children[#children + 1] = UI.Panel {
            width = 704,
            height = 64,
            flexShrink = 0,
            clickable = true,
            flexDirection = "row",
            alignItems = "center",
            gap = 12,
            paddingLeft = 8,
            onClick = function()
                checked = not checked
                checkImage:SetProp("backgroundImage", checked and CHECKBOX_ON or CHECKBOX_OFF)
                if options.onDoNotShowTodayChanged then options.onDoNotShowTodayChanged(checked) end
            end,
            children = {
                checkImage,
                Kit.CompactTxt("今日不再自动弹出（首页入口仍可打开）", 17, C.textSecondary, {
                    flexGrow = 1,
                    flexShrink = 1,
                    textAlign = "left",
                    textStroke = { width = 1, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        }
    end
    return UI.Panel {
        width = 704,
        flexShrink = 0,
        gap = 12,
        children = children,
    }
end

function DailyVipView.BuildRewardOptions(vipLevel, source, onClosed)
    local sourceText = source == "ad" and "激励视频奖励" or "每日签到奖励"
    return {
        kind = "reward",
        priority = 330,
        queueKey = "daily_vip_reward:" .. tostring(source) .. ":" .. tostring(vipLevel),
        title = "VIP 等级提升",
        message = sourceText .. "领取成功",
        lines = {
            "当前 VIP 等级：V" .. tostring(vipLevel),
            vipLevel >= MAX_VIP_LEVEL and "已达到最高 VIP 等级" or "明日可继续领取每日奖励",
        },
        contentBuilder = function()
            return UI.Panel {
                width = 660,
                height = 180,
                flexShrink = 0,
                alignItems = "center",
                justifyContent = "center",
                backgroundColor = { 8, 28, 64, 220 },
                borderWidth = 3,
                borderColor = C.gold,
                children = {
                    Kit.Txt("V" .. tostring(vipLevel), 56, C.gold, {
                        width = "100%", textAlign = "center",
                        textStroke = { width = 3, color = "#000000" },
                    }),
                },
            }
        end,
        celebration = true,
        confirmText = "确认",
        onConfirm = onClosed,
        onCancel = onClosed,
    }
end

function DailyVipView.ShowReward(vipLevel, source, onClosed)
    return require("client.CommonPromptDialog").Show(
        DailyVipView.BuildRewardOptions(vipLevel, source, onClosed)
    )
end

local function BuildDigitRow(vipLevel)
    local levelText = tostring(vipLevel)
    local children = {}
    for i = 1, #levelText do
        local digit = tonumber(string.sub(levelText, i, i)) or 0
        children[#children + 1] = UI.Panel {
            width = 74,
            height = 92,
            backgroundImage = ASSETS.ui.vipDigits[digit + 1],
            backgroundFit = "contain",
            pointerEvents = "none",
        }
    end
    -- 绝对定位在艺术字右侧，内容自适应宽度（1 位或 2 位数字都紧贴艺术字）
    return UI.Panel {
        position = "absolute",
        left = 170,
        top = 4,
        height = 96,
        flexDirection = "row",
        alignItems = "center",
        gap = 6,
        children = children,
    }
end

function DailyVipView.HomeEntry(context)
    local game = context.game
    local vipLevel = math.max(0, math.min(MAX_VIP_LEVEL, math.floor(tonumber(game.vipLevel) or 0)))
    local today = DayKey(ServerClock.Now())
    local dailyVip = type(game.dailyVip) == "table" and game.dailyVip or {}
    local hasClaim = vipLevel < MAX_VIP_LEVEL
        and (dailyVip.signInDay ~= today or dailyVip.adDay ~= today)
    local entry = UI.Panel {
        id = context.id or "tutorialFeatureVip",
        position = "absolute",
        left = context.left or 696,
        top = context.top or 16,
        width = 340,
        height = 112,
        zIndex = 20,
        clickable = true,
        onClick = context.onOpen,
        children = {
            UI.Panel {
                position = "absolute",
                left = 8,
                top = 6,
                width = 160,
                height = 100,
                backgroundImage = ASSETS.ui.vipArt,
                backgroundFit = "contain",
                pointerEvents = "none",
            },
            BuildDigitRow(vipLevel),
        },
    }
    if hasClaim then
        entry:AddChild(UI.Badge {
            position = "absolute", right = -8, top = -8,
            text = "可领", variant = "error",
        })
    end
    return entry
end

DailyVipView.DayKey = DayKey
DailyVipView.MAX_VIP_LEVEL = MAX_VIP_LEVEL

return DailyVipView
