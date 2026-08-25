-- QuestView.lua
-- 任务系统全屏独立页面：新手 / 每日 / 成就 三 Tab，任务卡片 + 领取 + 一键领取。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local GameStateAdapter = require("client.GameStateAdapter")
local ServerClock = require("client.ServerClock")
local QuestDefinitions = require("shared.QuestDefinitions")
local LargeNumber = require("shared.LargeNumber")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local QuestController = require("client.QuestController")
local GridVirtualList = require("client.UI.GridVirtualList")

local QuestView = {}

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

-- 与活动界面一致的机械蓝面背景板
local SURFACE = { 33, 69, 138, 235 }
local SURFACE_CAN = { 20, 62, 36, 235 }

local TAB_NAMES = { newbie = "新手", daily = "每日", achievement = "成就" }

local function NextDayCountdown()
    local now = ServerClock.Now()
    local dayKey = ServerClock.DayKey(now)
    local nextDayStart = (dayKey + 1) * 86400 - 8 * 3600
    local seconds = math.max(0, nextDayStart - now)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours <= 0 then return string.format("%d分钟后刷新", math.max(1, minutes)) end
    return string.format("%d小时%d分后刷新", hours, minutes)
end

local function RewardText(reward)
    reward = type(reward) == "table" and reward or {}
    local parts = {}
    if reward.gold and not LargeNumber.IsZero(reward.gold) then
        parts[#parts + 1] = "金币 " .. Kit.FormatInt(reward.gold)
    end
    if (reward.fragments or 0) > 0 then
        parts[#parts + 1] = "碎片 " .. tostring(reward.fragments)
    end
    if (reward.exp or 0) > 0 then
        parts[#parts + 1] = "经验 " .. tostring(reward.exp)
    end
    return #parts > 0 and table.concat(parts, "   ") or "奖励待定"
end

local function ProgressRatio(quest)
    local target = math.max(1, quest.target or 1)
    return math.max(0, math.min(1, (quest.cur or 0) / target))
end

local function QuestCard(quest)
    local claimed = quest.state == "claimed"
    local claimable = quest.state == "claimable"
    local inProgress = not claimed and not claimable
    local ratio = ProgressRatio(quest)
    local trackWidth = 480
    local fillWidth = math.max(0, math.floor(trackWidth * ratio))

    local button
    if claimed then
        button = UI.Panel {
            position = "absolute", right = 24, top = 26, width = 168, height = 64,
            backgroundImage = ASSETS.ui.buttonBlueWide, backgroundFit = "contain",
            opacity = 0.72,
            children = {
                Kit.Txt("已完成", 20, C.textDim, {
                    width = "100%", height = 64, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    elseif claimable then
        button = UI.Panel {
            position = "absolute", right = 24, top = 26, width = 168, height = 64,
            clickable = true,
            backgroundImage = ASSETS.ui.inventoryActionGold, backgroundFit = "contain",
            onClick = function() QuestController.Claim(quest.id) end,
            children = {
                Kit.Txt("领取", 22, C.text, {
                    width = "100%", height = 64, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    else
        button = UI.Panel {
            position = "absolute", right = 24, top = 26, width = 168, height = 64,
            backgroundImage = ASSETS.ui.buttonBlueWide, backgroundFit = "contain",
            opacity = 0.55,
            children = {
                Kit.Txt("进行中", 20, C.textSecondary, {
                    width = "100%", height = 64, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    end

    return UI.Panel {
        width = "100%",
        height = 168,
        flexShrink = 0,
        position = "relative",
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        backgroundColor = claimable and SURFACE_CAN or SURFACE,
        borderWidth = claimable and 3 or 2,
        borderColor = claimable and C.gold or C.border,
        borderRadius = 14,
        paddingLeft = 24,
        paddingRight = 20,
        children = {
            Kit.Txt(quest.title, 24, claimable and C.gold or C.text, {
                position = "absolute", left = 24, top = 16, width = 620, height = 36,
                textAlign = "left", textStroke = { width = 2, color = "#000000" },
            }),
            Kit.CompactTxt(quest.desc, 17, C.textSecondary, {
                position = "absolute", left = 24, top = 56, width = 620, height = 28,
                textAlign = "left",
            }),
            -- 进度条
            UI.Panel {
                position = "absolute", left = 24, top = 92,
                width = trackWidth, height = 18,
                backgroundColor = { 8, 20, 40, 255 },
                borderWidth = 2,
                borderColor = C.border,
                overflow = "hidden",
                children = {
                    UI.Panel {
                        position = "absolute", left = 0, top = 0,
                        width = fillWidth, height = 14,
                        backgroundColor = claimable and C.gold or C.focus,
                        pointerEvents = "none",
                    },
                },
            },
            Kit.CompactTxt(string.format("%d / %d", quest.cur or 0, quest.target or 0),
                18, claimable and C.gold or C.text, {
                    position = "absolute", left = 24, top = 116, width = 260, height = 26,
                    textAlign = "left", textStroke = { width = 1, color = "#000000" },
                }),
            Kit.CompactTxt(RewardText(quest.reward), 17, C.textSecondary, {
                position = "absolute", left = 500, top = 116, width = 380, height = 26,
                textAlign = "right",
            }),
            button,
        },
    }
end

local function BuildTabs(tab)
    local tabChildren = {}
    for _, questType in ipairs(QuestDefinitions.ORDER) do
        local active = tab == questType
        local currentQuestType = questType
        tabChildren[#tabChildren + 1] = UI.Panel {
            width = 200,
            height = 64,
            flexShrink = 0,
            clickable = true,
            backgroundImage = active and ASSETS.ui.inventoryTabOn or ASSETS.ui.inventoryTabOff,
            backgroundFit = "sliced",
            backgroundSlice = { 12, 18, 12, 18 },
            borderWidth = active and 2 or 1,
            borderColor = active and C.focus or C.border,
            onClick = function() QuestController.SetTab(currentQuestType) end,
            children = {
                Kit.Txt(TAB_NAMES[questType], active and 24 or 20, active and C.text or C.textDim, {
                    width = "100%", height = 64, textAlign = "center",
                    textStroke = { width = active and 2 or 1, color = "#000000" },
                }),
            },
        }
    end
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        flexDirection = "row",
        justifyContent = "center",
        gap = 16,
        children = tabChildren,
    }
end

function QuestView.BuildPage()
    local game = GameStateAdapter.GetViewState()
    local view = game.questsView or QuestDefinitions.BuildView(game, ServerClock.DayKey(ServerClock.Now()))
    local tab = QuestController.GetTab()
    local list = view[tab] or {}
    local claimableCount = QuestController.CountClaimable(game, tab)

    -- 虚拟列表：一维 list 按单列渲染，任务卡片池化复用。
    local questList = GridVirtualList.Build {
        columns = 1,
        cardWidth = 1000, -- 全屏内容宽 = 设计宽 1080 - 左右 padding(40*2)
        cardHeight = 168,
        cardGap = 14,     -- 原卡片间距 gap
        -- 原 ScrollView 为 flexGrow=1，高度由布局决定；此值仅用于布局完成前的池预创建估算。
        viewportHeight = 800,
        bounces = true,       -- 与原生 ScrollView 默认 bounces=true 一致
        showScrollbar = false,
        data = list,
        emptyState = function()
            return UI.Panel {
                width = "100%",
                flexShrink = 0,
                height = 200,
                alignItems = "center",
                justifyContent = "center",
                children = {
                    Kit.CompactTxt("暂无任务", 22, C.textSecondary, { width = "100%", textAlign = "center" }),
                },
            }
        end,
        createCard = function(row, slotIndex)
            local quest = row._boundItems[slotIndex]
            if not quest then return nil end
            return QuestCard(quest)
        end,
    }

    local dailyHeader = nil
    if tab == "daily" then
        dailyHeader = UI.Panel {
            width = "100%", flexShrink = 0, height = 44,
            flexDirection = "row",
            alignItems = "center",
            justifyContent = "center",
            gap = 12,
            children = {
                Kit.CompactTxt(view.dailyActive and "今日任务" or "每日任务已刷新", 18,
                    view.dailyActive and C.success or C.warning, {
                        textAlign = "center",
                    }),
                Kit.CompactTxt(NextDayCountdown(), 18, C.textDim, { textAlign = "center" }),
            },
        }
    end

    return UI.Panel {
        width = "100%",
        height = "100%",
        flexShrink = 0,
        paddingLeft = 40,
        paddingRight = 40,
        paddingTop = 16,
        paddingBottom = 24,
        gap = 14,
        children = {
            -- 顶部栏
            UI.Panel {
                width = "100%", flexShrink = 0, height = 72,
                position = "relative",
                children = {
                    Kit.Txt("任务", 32, C.text, {
                        position = "absolute", left = 0, top = 8, width = 1000, height = 56,
                        textAlign = "center", textStroke = { width = 3, color = "#000000" },
                    }),
                    Kit.BackButton {
                        onClick = function() require("client.NavigationController").SwitchPage("home") end,
                    },
                    UI.Panel {
                        position = "absolute", right = 0, top = 0, width = 280, height = 72,
                        clickable = claimableCount > 0,
                        opacity = claimableCount > 0 and 1.0 or 0.45,
                        -- 用大尺寸金色按钮素材，避免文字超出按钮背景。
                        backgroundImage = ASSETS.ui.playAutoRunButton, backgroundFit = "contain",
                        onClick = function()
                            if claimableCount > 0 then QuestController.ClaimAll() end
                        end,
                        children = {
                            Kit.Txt("一键领取" .. (claimableCount > 0 and ("(" .. tostring(claimableCount) .. ")") or ""),
                                22, C.text, {
                                    width = "100%", height = 72, textAlign = "center",
                                    textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                                }),
                        },
                    },
                },
            },
            BuildTabs(tab),
            dailyHeader or UI.Panel { width = "100%", flexShrink = 0, height = 0 },
            questList,
        },
    }
end

return QuestView
