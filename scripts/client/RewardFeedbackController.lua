local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local GameStateAdapter = require("client.GameStateAdapter")
local IdleRewardAccumulator = require("client.IdleRewardAccumulator")
local RewardDialogView = require("client.RewardDialogView")
local AudioController = require("client.AudioController")
local BigNumber = require("shared.BigNumber")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ItemView = require("client.ItemView")
local CommonPromptDialog = require("client.CommonPromptDialog")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local RewardFeedbackController = {}

local tracking_ = false
local actionPending_ = false
local summary_ = nil

local function ResetSummary()
    summary_ = IdleRewardAccumulator.New()
end

local function HasValue()
    return IdleRewardAccumulator.HasValue(summary_)
end

local function StartTracking()
    if tracking_ then return end
    tracking_ = true
    ResetSummary()
end

local function Accumulate(events)
    if not tracking_ then return end
    if not summary_ then ResetSummary() end
    IdleRewardAccumulator.Accumulate(assert(summary_), events, {
        getItemById = function(id)
            return ItemView.GetItemById(GameStateAdapter.GetViewState(), id)
        end,
        itemImage = ItemView.ItemImage,
    })
end

local function ShowLevelUpDialog(value)
    value = value or {}
    local previousLevel = math.max(1, tonumber(value.previousLevel) or ((tonumber(value.level) or 1) - 1))
    local level = math.max(previousLevel + 1, tonumber(value.level) or (previousLevel + 1))
    local levelsGained = math.max(1, tonumber(value.levelsGained) or (level - previousLevel))
    local currentExp = math.max(0, tonumber(value.exp) or 0)
    local nextExp = math.max(1, tonumber(value.nextExp) or 1)
    local expRatio = math.max(0, math.min(1, currentExp / nextExp))
    return CommonPromptDialog.Show {
        kind = "equipment",
        priority = 500,
        queueKey = "level_up:" .. tostring(previousLevel) .. ":" .. tostring(level),
        title = "等级提升",
        dialogHeight = 700,
        celebration = true,
        entranceDuration = 0.62,
        closeOnOverlay = false,
        showClose = false,
        confirmText = "继续冒险",
        onPresented = function()
            AudioController.PlayFeedback("levelUp")
        end,
        contentBuilder = function()
            local levelBadge = UI.Panel {
                width = 220,
                height = 220,
                flexShrink = 0,
                alignItems = "center",
                justifyContent = "center",
                backgroundColor = { 17, 36, 70, 245 },
                borderWidth = 4,
                borderColor = C.gold,
                borderRadius = 110,
                children = {
                    Kit.CompactTxt("LV", 24, C.textSecondary, {
                        position = "absolute",
                        left = 0,
                        top = 42,
                        width = 220,
                        height = 34,
                        textAlign = "center",
                        textStroke = { width = 1, color = "#000000" },
                        pointerEvents = "none",
                    }),
                    Kit.CompactTxt(tostring(level), 76, C.gold, {
                        width = 220,
                        height = 110,
                        textAlign = "center",
                        textStroke = { width = 3, color = "#000000" },
                        pointerEvents = "none",
                    }),
                },
            }
            levelBadge:Animate {
                keyframes = {
                    [0] = { opacity = 0, scale = 0.35, rotate = -10 },
                    [0.62] = { opacity = 1, scale = 1.16, rotate = 4 },
                    [1] = { opacity = 1, scale = 1.0, rotate = 0 },
                },
                duration = 0.72,
                easing = "easeOut",
            }
            return UI.Panel {
                width = "100%",
                flexShrink = 0,
                alignItems = "center",
                gap = 18,
                children = {
                    Kit.CompactTxt("Lv." .. tostring(previousLevel) .. "  →  Lv." .. tostring(level), 30, C.focus, {
                        width = "100%",
                        height = 48,
                        textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                        pointerEvents = "none",
                    }),
                    levelBadge,
                    Kit.CompactTxt(
                        levelsGained > 1 and ("连续提升 " .. tostring(levelsGained) .. " 级") or "角色属性已全面成长",
                        23,
                        C.text,
                        {
                            width = "100%",
                            height = 38,
                            textAlign = "center",
                            textStroke = { width = 1, color = "#000000" },
                            pointerEvents = "none",
                        }
                    ),
                    UI.Panel {
                        width = 520,
                        height = 28,
                        flexShrink = 0,
                        backgroundColor = { 5, 14, 29, 235 },
                        borderWidth = 2,
                        borderColor = C.border,
                        borderRadius = 14,
                        overflow = "hidden",
                        children = {
                            UI.Panel {
                                width = math.floor(516 * expRatio),
                                height = 24,
                                backgroundColor = C.focus,
                                borderRadius = 12,
                                pointerEvents = "none",
                            },
                        },
                    },
                    Kit.CompactTxt(
                        "当前经验 " .. Kit.FormatInt(currentExp) .. " / " .. Kit.FormatInt(nextExp),
                        18,
                        C.textSecondary,
                        { width = "100%", height = 30, textAlign = "center", pointerEvents = "none" }
                    ),
                },
            }
        end,
    }
end

local function EventKey(value, index)
    return table.concat({
        tostring(value.kind or value.type or "event"),
        tostring(value.itemId or value.equipmentId or ""),
        tostring(value.floor or ""),
        tostring(value.position or ""),
        tostring(index or ""),
    }, ":")
end

local function ShowDeltaFeedback(payload)
    local events = (payload and payload.events) or {}
    local hasOfflineReward = false
    for _, value in ipairs(events) do
        local kind = value.kind or value.type
        if kind == "offline_collected" then
            hasOfflineReward = true
        elseif kind == "level_up" then
            ShowLevelUpDialog(value)
        end
    end
    if hasOfflineReward then return end

    local game = GameStateAdapter.GetViewState()
    local equipmentById = {}
    local cards = {}
    local title = "获得奖励"
    local message = "奖励已存入背包"
    local queueParts = {}
    local gold = BigNumber.FromNumber(0) ---@type table
    local exp = BigNumber.FromNumber(0) ---@type table
    local fragments = BigNumber.FromNumber(0) ---@type table
    local hasReward = false

    for index, value in ipairs(events) do
        local kind = value.kind or value.type
        queueParts[#queueParts + 1] = EventKey(value, index)
        if tracking_ and IdleRewardAccumulator.IsRewardEvent(kind) then
            -- 在线挂机奖励按会话累计，切页或退出挂机时统一展示。
        elseif kind == "equipment_drop" or kind == "equipment_granted" or kind == "tower_aid_equipment" then
            local itemId = tostring(value.itemId or value.equipmentId or index)
            if not equipmentById[itemId] then
                equipmentById[itemId] = true
                local item = ItemView.GetItemById(game, value.itemId) or value
                RewardDialogView.AddCard(
                    cards,
                    ItemView.ItemImage(item),
                    value.name or item.name or "装备",
                    nil,
                    value.rarity or item.rarity,
                    item
                )
                hasReward = true
            end
        elseif kind == "battle_reward" then
            gold = BigNumber.Add(gold, value.gold or 0)
            exp = BigNumber.Add(exp, value.exp or 0)
            title = "战斗胜利"
            message = "战斗奖励结算完成"
            hasReward = true
        elseif kind == "chest_reward" then
            gold = BigNumber.Add(gold, value.gold or 0)
            fragments = BigNumber.Add(fragments, value.fragments or 0)
            title = "宝箱奖励"
            message = "宝箱奖励已收取"
            hasReward = true
        elseif kind == "merchant_trade" then
            fragments = BigNumber.Add(fragments, value.fragments or 0)
            title = "交易奖励"
            message = "商人交易完成"
            hasReward = true
        elseif kind == "wish_pool" then
            gold = BigNumber.Add(gold, value.gold or 0)
            title = "许愿奖励"
            message = "许愿池已回应"
            hasReward = true
        elseif kind == "abyss_echo" then
            fragments = BigNumber.Add(fragments, value.fragments or 0)
            title = "深渊回响"
            message = "深渊碎片已收取"
            hasReward = true
        elseif kind == "aid_granted" or kind == "tower_aid_claimed" then
            title = "塔灵援助"
            message = "援助奖励已发放"
            if value.gold or value.fragments then
                gold = BigNumber.Add(gold, value.gold or 0)
                fragments = BigNumber.Add(fragments, value.fragments or 0)
                hasReward = true
            end
        elseif kind == "quest_claimed" then
            local reward = value.reward or {}
            if reward.gold then gold = BigNumber.Add(gold, reward.gold) end
            if reward.fragments then fragments = BigNumber.Add(fragments, reward.fragments) end
            if reward.exp then exp = BigNumber.Add(exp, reward.exp) end
            title = "任务奖励"
            message = "任务奖励已发放"
            hasReward = true
        elseif kind == "battle_lost" then
            UI.Toast.Show("挑战失败，已返回本层第1场重新整备", { duration = 2.8, variant = "error", position = "top" })
        elseif kind == "inventory_full" then
            UI.Toast.Show("背包已满，请清理装备或调整自动处理规则", { duration = 2.8, variant = "warning", position = "bottom" })
        elseif kind == "inventory_drop_skipped" then
            UI.Toast.Show("背包已满，本次装备掉落未能收取", { duration = 2.8, variant = "warning", position = "bottom" })
        elseif kind == "merchant_skipped" then
            UI.Toast.Show("金币不足，未能完成商人交易", { duration = 2.4, variant = "warning", position = "bottom" })
        elseif kind == "story_skipped" then
            UI.Toast.Show("剧情已跳过", { duration = 1.8, variant = "info", position = "bottom" })
        end
    end

    if not BigNumber.IsZero(gold) then
        RewardDialogView.AddCard(cards, ASSETS.items.gold, "金币", "+" .. Kit.FormatInt(gold), "epic")
    end
    if not BigNumber.IsZero(exp) then
        RewardDialogView.AddCard(cards, ASSETS.items.crystal, "经验", "+" .. Kit.FormatInt(exp), "advanced")
    end
    if not BigNumber.IsZero(fragments) then
        RewardDialogView.AddCard(cards, ASSETS.items.crystal, "碎片", "+" .. Kit.FormatInt(fragments), "rare")
    end
    if not hasReward or #cards == 0 then return end

    RewardDialogView.Show {
        queueKey = "delta_reward:" .. table.concat(queueParts, "|"),
        title = title,
        message = message,
        lines = { "奖励结算由服务器确认，物品已同步到当前角色。" },
        cards = cards,
    }
end

function RewardFeedbackController.SyncSnapshot()
    local game = GameStateAdapter.GetViewState()
    if game.autoRun then
        StartTracking()
    elseif tracking_ and not actionPending_ and not HasValue() then
        tracking_ = false
        ResetSummary()
    end
end

function RewardFeedbackController.AccumulateDelta(payload)
    local game = GameStateAdapter.GetViewState()
    if game.autoRun then StartTracking() end
    Accumulate(payload and payload.events)
end

function RewardFeedbackController.PresentDelta(payload)
    ShowDeltaFeedback(payload)
end

function RewardFeedbackController.ShowIdleSummary(onConfirm)
    if not HasValue() then
        if onConfirm then onConfirm() end
        return false
    end
    if actionPending_ then return true end

    local summary = assert(summary_)
    ResetSummary()
    local cards = {}
    if not BigNumber.IsZero(summary.gold) then
        RewardDialogView.AddCard(cards, ASSETS.items.gold, "金币", "+" .. Kit.FormatInt(summary.gold), "epic")
    end
    if not BigNumber.IsZero(summary.exp) then
        RewardDialogView.AddCard(cards, ASSETS.items.crystal, "经验", "+" .. Kit.FormatInt(summary.exp), "advanced")
    end
    if not BigNumber.IsZero(summary.fragments) then
        RewardDialogView.AddCard(cards, ASSETS.items.crystal, "碎片", "+" .. Kit.FormatInt(summary.fragments), "rare")
    end
    for _, value in ipairs(summary.equipmentItems) do
        RewardDialogView.AddCard(cards, value.icon, value.name, nil, value.rarity, value.item)
    end

    actionPending_ = true
    local shown = RewardDialogView.Show {
        priority = 450,
        queueKey = RewardDialogView.NextKey("idle_reward"),
        title = "获得挂机奖励",
        message = "本次挂机收益已汇总",
        lines = {
            "完成战斗 " .. tostring(summary.battles or 0) .. " 场，奖励已同步到当前角色。",
        },
        confirmText = "确认并离开",
        cancelText = "继续登塔",
        showClose = true,
        cards = cards,
        onConfirm = function()
            actionPending_ = false
            if onConfirm then onConfirm() end
        end,
        onCancel = function()
            IdleRewardAccumulator.Merge(assert(summary_), summary)
            actionPending_ = false
        end,
    }
    if not shown then
        IdleRewardAccumulator.Merge(assert(summary_), summary)
        actionPending_ = false
    end
    return shown
end

function RewardFeedbackController.IsTracking()
    return tracking_
end

function RewardFeedbackController.Reset()
    tracking_ = false
    actionPending_ = false
    ResetSummary()
end

ResetSummary()

return RewardFeedbackController
