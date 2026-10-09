local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ItemView = require("client.ItemView")
local RewardDialogView = require("client.RewardDialogView")
local CommonPromptDialog = require("client.CommonPromptDialog")
local ItemSort = require("shared.ItemSort")
local BigNumber = require("shared.BigNumber")
local LargeNumber = require("shared.LargeNumber")
local RewardClaimController = require("client.RewardClaimController")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local OfflineClaimView = {}

local function BuildRewardCards(value)
    value = value or {}
    local cards = {
        RewardDialogView.DescribeCard(ASSETS.items.gold, "金币", "+" .. Kit.FormatInt(value.gold or 0), "epic"),
        RewardDialogView.DescribeCard(ASSETS.items.crystal, "经验", "+" .. Kit.FormatInt(value.exp or 0), "advanced"),
        RewardDialogView.DescribeCard(ASSETS.items.crystal, "碎片", "+" .. Kit.FormatInt(value.fragments or 0), "rare"),
    }
    local equipmentItems = ItemSort.Sort(value.equipmentItems or {})
    if not BigNumber.IsZero(value.abyssTickets or 0) then
        RewardDialogView.AddDescriptor(cards, require("shared.AbyssDefinitions").ICON,
            "深渊票", "+" .. Kit.FormatInt(value.abyssTickets), "epic")
    end
    for _, item in ipairs(equipmentItems) do
        cards[#cards + 1] = RewardDialogView.DescribeCard(
            ItemView.ItemImage(item), item.name or "装备", nil, item.rarity, item)
    end
    if (value.equipment or 0) > 0 and #(value.equipmentItems or {}) == 0 then
        cards[#cards + 1] = RewardDialogView.DescribeCard(
            ASSETS.items.chest, "装备", nil, "rare")
    end
    return cards
end

local function BuildTimeSummary(value, preview, currentFloor)
    value = value or {}
    local primaryLabel = preview and "累计离线" or "实际结算"
    local primaryValue = preview and value.seconds or value.processedSeconds
    local secondaryLabel = preview and "预计结算" or "当前楼层"
    local secondaryValue = preview and Kit.FormatDuration(value.processedSeconds or 0)
        or ("第" .. tostring(value.floor or currentFloor or 1) .. "层")
    local note
    if value.interrupted then
        note = "背包空间不足，未结算时间会继续保留"
    elseif (value.remainingSeconds or 0) > 0 then
        note = (preview and "领取后保留 " or "剩余离线 ") .. Kit.FormatDuration(value.remainingSeconds)
    else
        note = preview and "收益按在线效率的20%计算，装备结果已锁定"
            or "奖励已经服务器确认并同步到当前角色"
    end
    local function Stat(label, text, color, textAlign)
        return UI.Panel {
            width = 318, height = 64, flexShrink = 0,
            paddingLeft = 14, paddingRight = 14,
            justifyContent = "center", gap = 2,
            backgroundColor = { 7, 20, 42, 210 },
            borderWidth = 1, borderColor = C.border, borderRadius = 8,
            children = {
                Kit.CompactTxt(label, 15, C.textDim, {
                    width = "100%", height = 22, textAlign = textAlign,
                }),
                Kit.CompactTxt(text, 20, color, {
                    width = "100%", height = 28, textAlign = textAlign,
                    textStroke = { width = 1, color = "#000000" },
                }),
            },
        }
    end
    return UI.Panel {
        width = 700, flexShrink = 0, gap = 8,
        children = {
            UI.Panel {
                width = 700, height = 64, flexDirection = "row",
                justifyContent = "space-between",
                children = {
                    Stat(primaryLabel, Kit.FormatDuration(primaryValue or 0), C.gold, "left"),
                    Stat(secondaryLabel, secondaryValue, C.focus, "right"),
                },
            },
            Kit.CompactTxt(note, 16, C.textSecondary, {
                width = 700, height = 26, textAlign = "center",
                textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
            }),
        },
    }
end

local function BuildPreviewContent(value, currentFloor)
    local cards = BuildRewardCards(value)
    local pageLabel = Kit.CompactTxt("1 / 1", 17, C.textDim, {
        width = 92, height = 28, textAlign = "right",
        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
    })
    return UI.Panel {
        width = "100%", flexShrink = 0, alignItems = "center", gap = 12,
        children = {
            UI.Panel {
                width = 700, height = 42, flexShrink = 0,
                flexDirection = "row", alignItems = "center", justifyContent = "space-between",
                paddingLeft = 14, paddingRight = 14,
                backgroundColor = { 7, 20, 42, 220 },
                borderWidth = 1, borderColor = C.border, borderRadius = 8,
                children = {
                    Kit.CompactTxt("预计奖励", 21, C.text, {
                        width = 500, height = 42, textAlign = "left",
                        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                    }),
                    pageLabel,
                },
            },
            RewardDialogView.BuildCardPanel(cards, pageLabel),
            UI.Panel { width = 700, height = 28, flexShrink = 0, pointerEvents = "none" },
            BuildTimeSummary(value, true, currentFloor),
        },
    }
end

function OfflineClaimView.ShowLoading(dialogKey)
    return CommonPromptDialog.Show {
        kind = "confirm",
        priority = 460,
        queueKey = dialogKey,
        title = "离线收益",
        message = "正在计算离线收益，请稍候……",
        lines = { "服务器正在锁定本次预计奖励，完成后会显示确认领取内容。" },
        closeOnOverlay = false,
        showClose = false,
        showConfirm = false,
    }
end

function OfflineClaimView.ShowPreview(quoteToken, value, currentFloor, onClaim, onCancel, forceClaim)
    local dialogKey = "offline_preview:" .. tostring(quoteToken)
    return CommonPromptDialog.Show {
        kind = "confirm",
        priority = 460,
        queueKey = dialogKey,
        title = "离线收益预览",
        dialogHeight = 1100,
        titleTop = -7,
        closeTop = 17,
        closeRight = 22,
        buttonTop = 1017,
        buttonGap = 120,
        cancelText = "稍后领取",
        showClose = true,
        confirmText = "确认领取",
        closeOnOverlay = false,
        contentBuilder = function()
            return BuildPreviewContent(value or {}, currentFloor)
        end,
        onConfirm = onClaim,
        onCancel = onCancel,
    }, dialogKey
end

function OfflineClaimView.BuildRewardOptions(value, currentFloor, onCompleted)
    value = value or {}
    local events = RewardClaimController.TakeOfflineEvents()
    local base = {}; for key, amount in pairs(value) do base[key] = amount end
    local function AddResources(target, reward)
        for _, key in ipairs({ "gold", "exp", "fragments", "abyssTickets" }) do
            local left, right = target[key] or 0, reward[key] or 0
            if LargeNumber.IsLargeNumber(left) then left = LargeNumber.ToBigNumber(left) end
            if LargeNumber.IsLargeNumber(right) then right = LargeNumber.ToBigNumber(right) end
            target[key] = BigNumber.Add(left, right)
        end
    end
    for _, event in ipairs(events) do
        if (event.kind or event.type) == "level_milestone_reward" then AddResources(base, event.reward or {}) end
    end
    local lines = {
        "本次实际结算：" .. Kit.FormatDuration(value.processedSeconds or 0),
        "离线期间仅重复挑战第" .. tostring(value.floor or currentFloor or 1) .. "层，不会自动突破楼层。",
        "奖励已经过服务器确认并同步到当前角色。",
    }
    if value.interrupted then
        lines[#lines + 1] = "背包已满，尚未结算的离线时间已保留。"
    elseif (value.remainingSeconds or 0) > 0 then
        lines[#lines + 1] = "剩余离线时间：" .. Kit.FormatDuration(value.remainingSeconds)
    end
    return RewardClaimController.ShowReward({
        priority = 450,
        queueKey = RewardDialogView.NextKey("offline_reward"),
        title = "获得离线奖励",
        message = "离线收益已领取",
        lines = lines,
        confirmText = "确认收取",
        buildCards = function(extra)
            local total = {}; for key, amount in pairs(base) do total[key] = amount end
            AddResources(total, extra or {})
            return BuildRewardCards(total)
        end,
        onConfirm = onCompleted,
        onCancel = onCompleted,
    }, events, true)
end

function OfflineClaimView.ShowReward(value, currentFloor, onCompleted)
    local options = OfflineClaimView.BuildRewardOptions(value, currentFloor, onCompleted)
    local shown = options and CommonPromptDialog.Show(options) or false
    if not shown and onCompleted then onCompleted() end
    return shown
end

return OfflineClaimView
