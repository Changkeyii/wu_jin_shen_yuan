local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ItemView = require("client.ItemView")
local BackpackItemSlot = require("client.BackpackItemSlot")
local HorizontalArrowScroller = require("client.HorizontalArrowScroller")
local CommonPromptDialog = require("client.CommonPromptDialog")
local AudioController = require("client.AudioController")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local RewardDialogView = {}
local sequence_ = 0

function RewardDialogView.BuildItemCard(icon, name, amount, rarity, item)
    local displayItem = item or {
        name = name,
        rarity = rarity or "common",
        level = 1,
    }
    return BackpackItemSlot.Build({
        UI = UI,
        C = C,
        ASSETS = ASSETS,
        compactTxt = Kit.CompactTxt,
        shortenText = Kit.ShortenText,
        rarityColor = ItemView.RarityColor,
        itemImage = function() return icon end,
        itemLevelText = ItemView.ItemLevelText,
        isEquipped = function() return false end,
    }, displayItem, {
        width = 180,
        height = 180,
        selected = false,
        clickable = false,
        fallbackImage = icon,
        amountText = item == nil and amount or nil,
        showLevel = item ~= nil,
        showEquipped = false,
    })
end

function RewardDialogView.AddCard(cards, icon, name, amount, rarity, item)
    cards[#cards + 1] = RewardDialogView.BuildItemCard(icon, name, amount, rarity, item)
end

function RewardDialogView.BuildCardPanel(cards, pageLabel)
    return HorizontalArrowScroller.Build {
        width = 720,
        height = 600,
        rows = 3,
        columnsPerPage = 3,
        arrowWidth = 42,
        itemWidth = 180,
        itemHeight = 180,
        gapX = 8,
        gapY = 10,
        children = cards,
        text = Kit.CompactTxt,
        arrowColor = C.focus,
        arrowBorderColor = C.focus,
        arrowBackgroundColor = { 7, 19, 39, 225 },
        pageLabel = pageLabel,
    }
end

local function BuildContent(message, cards, detailLines)
    local pageLabel = Kit.CompactTxt("1 / 1", 17, C.textDim, {
        width = 92,
        height = 28,
        textAlign = "right",
        textStroke = { width = 1, color = "#000000" },
        pointerEvents = "none",
    })
    local details = {}
    for _, line in ipairs(detailLines or {}) do
        details[#details + 1] = Kit.CompactTxt(line, 18, C.textSecondary, {
            width = "100%",
            height = 26,
            textAlign = "center",
            textStroke = { width = 1, color = "#000000" },
            pointerEvents = "none",
        })
    end
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        alignItems = "center",
        gap = 14,
        children = {
            UI.Panel {
                width = 700,
                height = 44,
                flexShrink = 0,
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                paddingLeft = 14,
                paddingRight = 14,
                backgroundColor = { 7, 20, 42, 220 },
                borderWidth = 1,
                borderColor = C.border,
                borderRadius = 8,
                children = {
                    Kit.CompactTxt(message or "奖励已存入背包", 21, C.text, {
                        width = 560,
                        height = 44,
                        textAlign = "left",
                        textStroke = { width = 1, color = "#000000" },
                        pointerEvents = "none",
                    }),
                    pageLabel,
                },
            },
            RewardDialogView.BuildCardPanel(cards, pageLabel),
            UI.Panel {
                width = 700,
                flexShrink = 0,
                paddingTop = 8,
                gap = 4,
                borderTopWidth = 2,
                borderColor = C.border,
                children = details,
            },
        },
    }
end

function RewardDialogView.NextKey(prefix)
    sequence_ = sequence_ + 1
    return tostring(prefix or "reward") .. ":" .. tostring(sequence_)
end

function RewardDialogView.Show(options)
    options = options or {}
    local cards = options.cards or {}
    if #cards == 0 then return false end
    return CommonPromptDialog.Show {
        kind = "equipment",
        priority = options.priority or 320,
        queueKey = options.queueKey or RewardDialogView.NextKey("reward"),
        title = options.title or "获得奖励",
        celebration = true,
        entranceDuration = 0.52,
        onPresented = function()
            AudioController.PlayFeedback(options.sound or "reward")
        end,
        dialogHeight = 1160,
        closeOnOverlay = false,
        showClose = options.showClose == true,
        cancelText = options.cancelText,
        confirmText = options.confirmText or "确认收取",
        onConfirm = options.onConfirm,
        onCancel = options.onCancel,
        contentBuilder = function()
            return BuildContent(
                options.message or "奖励已存入背包",
                cards,
                options.lines or {}
            )
        end,
    }
end

return RewardDialogView
