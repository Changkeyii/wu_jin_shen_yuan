-- LeaderboardView.lua
-- 排行榜弹窗：顶部页签（战力榜 / 伤害榜 / Boss榜）+ Top 100 列表。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DialogCoordinator = require("client.DialogCoordinator")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local LeaderboardView = {}

local TABS = {
    { id = "power", name = "战力榜", scoreLabel = "战力" },
    { id = "damage", name = "伤害榜", scoreLabel = "15秒伤害" },
    { id = "boss", name = "Boss榜", scoreLabel = "Boss伤害" },
    { id = "season", name = "赛季榜", coming = true, scoreLabel = "赛季" },
}

local BOARD_META = {
    power = { scoreLabel = "战力", empty = "暂无玩家上榜" },
    damage = { scoreLabel = "15秒伤害", empty = "暂无打桩成绩，去每日补给打桩即可上榜" },
    boss = { scoreLabel = "Boss伤害", empty = "暂无 Boss 成绩，去热门活动挑战深渊 Boss" },
}

-- 排名数字：用清晰文本替代 VIP 艺术字素材（艺术字难辨认）
local function RankText(rank)
    local color
    if rank == 1 then
        color = C.gold
    elseif rank == 2 then
        color = { 210, 228, 255, 255 }
    elseif rank == 3 then
        color = { 255, 184, 130, 255 }
    else
        color = C.textSecondary
    end
    return Kit.Txt(tostring(rank or 0), 30, color, {
        width = "100%",
        height = 44,
        textAlign = "center",
        textStroke = { width = 2, color = "#000000" },
        pointerEvents = "none",
    })
end

local function TabRow(activeBoard, onSelectTab)
    local children = {}
    for _, tab in ipairs(TABS) do
        local active = tab.id == activeBoard
        children[#children + 1] = UI.Panel {
            width = 188,
            height = 64,
            flexShrink = 0,
            clickable = true,
            backgroundImage = active and ASSETS.ui.marketTabOn or ASSETS.ui.marketTabOff,
            backgroundFit = "sliced",
            backgroundSlice = { 10, 10, 10, 10 },
            opacity = tab.coming and 0.7 or 1.0,
            onClick = function()
                if tab.coming then
                    UI.Toast.Show(tab.name .. "敬请期待", { duration = 1.5, variant = "info", position = "bottom" })
                    return
                end
                if onSelectTab then onSelectTab(tab.id) end
            end,
            children = {
                Kit.Txt(tab.name, 23, active and C.text or C.textDim, {
                    width = "100%", height = 64, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    end
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        flexDirection = "row",
        justifyContent = "center",
        alignItems = "center",
        gap = 16,
        children = children,
    }
end

local function BuildRow(entry, selfRank, onSelectPlayer)
    local rank = entry.rank or 0
    local isSelf = rank == selfRank
    return UI.Panel {
        width = 820,
        height = 64,
        flexShrink = 0,
        clickable = true,
        flexDirection = "row",
        alignItems = "center",
        gap = 22,
        paddingLeft = 22,
        paddingRight = 22,
        borderWidth = 2,
        borderColor = isSelf and C.focus or (rank <= 3 and { 120, 190, 255, 160 } or C.border),
        borderRadius = 10,
        backgroundColor = isSelf and { 20, 56, 108, 220 } or { 10, 26, 52, 210 },
        -- 整行可点击（所有子项 pointerEvents=none，点击穿透到整行）
        onClick = function()
            if onSelectPlayer then onSelectPlayer(entry.userId) end
        end,
        children = {
            UI.Panel {
                width = 92,
                height = 44,
                flexShrink = 0,
                alignItems = "center",
                justifyContent = "center",
                pointerEvents = "none",
                children = { RankText(rank) },
            },
            UI.Panel {
                flexGrow = 1,
                flexBasis = 0,
                height = 44,
                justifyContent = "center",
                pointerEvents = "none",
                children = {
                    Kit.CompactTxt(entry.nickname or "玩家", 24, isSelf and C.focus or C.text, {
                        width = "100%", height = 44, textAlign = "left",
                        textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                    }),
                },
            },
            Kit.Txt(Kit.FormatInt(entry.score or entry.power or 0), 26, C.gold, {
                width = 170, height = 40, textAlign = "right",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            }),
            UI.Panel {
                width = 150,
                height = 57,
                left = 2,
                top = 7,
                flexShrink = 0,
                clickable = true,
                alignItems = "center",
                justifyContent = "center",
                backgroundImage = ASSETS.ui.buttonBlue,
                backgroundFit = "sliced",
                backgroundSlice = { 8, 8, 8, 8 },
                onClick = function()
                    if onSelectPlayer then onSelectPlayer(entry.userId) end
                end,
                children = {
                    Kit.CompactTxt("查看详情", 20, C.text, {
                        width = "100%",
                        height = 50,
                        minHeight = 38,
                        left = -2,
                        top = -5,
                        textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                        pointerEvents = "none",
                    }),
                },
            },
        },
    }
end

function LeaderboardView.Show(list, selfRank, total, onSelectPlayer, options)
    options = type(options) == "table" and options or {}
    local board = options.board == "damage" and "damage"
        or (options.board == "boss" and "boss" or "power")
    local meta = BOARD_META[board] or BOARD_META.power
    list = type(list) == "table" and list or {}
    local rows = {}
    for _, entry in ipairs(list) do
        rows[#rows + 1] = BuildRow(entry, selfRank, onSelectPlayer)
    end
    if #rows == 0 then
        rows[#rows + 1] = UI.Panel {
            width = 820,
            height = 200,
            alignItems = "center",
            justifyContent = "center",
            children = {
                Kit.Txt(meta.empty, 24, C.textSecondary, {
                    width = "100%", height = 80, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                }),
            },
        }
    end

    local selfLine = selfRank and selfRank > 0
        and ("我的排名：第 " .. tostring(selfRank) .. " 名")
        or "我尚未进入前 100 名"
    local header = UI.Panel {
        width = 820,
        height = 44,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "center",
        gap = 22,
        paddingLeft = 22,
        paddingRight = 22,
        children = {
            Kit.Txt("排名", 20, C.textDim, { width = 92, height = 40, textAlign = "center", pointerEvents = "none" }),
            Kit.Txt("玩家", 20, C.textDim, { flexGrow = 1, flexBasis = 0, height = 40, textAlign = "left", pointerEvents = "none" }),
            Kit.Txt(meta.scoreLabel, 20, C.textDim, { width = 170, height = 40, textAlign = "right", pointerEvents = "none" }),
            Kit.Txt("操作", 20, C.textDim, { width = 150, height = 40, textAlign = "center", pointerEvents = "none" }),
        },
    }

    DialogCoordinator.CancelByKey("leaderboard")
    return CommonPromptDialog.Show {
        kind = "confirm",
        queueKey = "leaderboard",
        title = "排行榜",
        dialogWidth = 980,
        dialogHeight = 1220,
        bodyTop = 108,
        bodyHeight = 1000,
        buttonTop = 1142,
        closeOnOverlay = true,
        confirmText = "关闭",
        showClose = true,
        contentBuilder = function()
            return UI.Panel {
                width = "100%",
                flexShrink = 0,
                gap = 12,
                alignItems = "center",
                children = {
                    TabRow(board, options.onSelectTab),
                    header,
                    UI.ScrollView {
                        width = 860,
                        height = 780,
                        scrollX = false,
                        scrollY = true,
                        showScrollbar = false,
                        children = {
                            UI.Panel {
                                width = "100%",
                                flexDirection = "row",
                                flexWrap = "wrap",
                                justifyContent = "center",
                                gap = 8,
                                paddingTop = 4,
                                paddingBottom = 12,
                                children = rows,
                            },
                        },
                    },
                    Kit.Txt(selfLine, 20, C.textSecondary, {
                        width = "100%", height = 32, textAlign = "center",
                        textStroke = { width = 1, color = "#000000" },
                    }),
                },
            }
        end,
    }
end

return LeaderboardView
