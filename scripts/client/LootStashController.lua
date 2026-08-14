local UI = require("urhox-libs/UI")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local DialogCoordinator = require("client.DialogCoordinator")
local CommonPromptDialog = require("client.CommonPromptDialog")
local BackpackItemSlot = require("client.BackpackItemSlot")
local ItemSort = require("shared.ItemSort")
local GameTheme = require("client.Theme")
local RewardDialogView = require("client.RewardDialogView")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ItemView = require("client.ItemView")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local LootStashController = {}

local context_ = nil
local root_ = nil
local overlay_ = nil
local visible_ = false
local forced_ = false
local claimPending_ = false
local loginGuideShown_ = false
local onClosed_ = nil

local function RemoveOverlay()
    if overlay_ and root_ then root_:RemoveChild(overlay_) end
    overlay_ = nil
end

local function CurrentItems()
    local game = GameStateAdapter.GetViewState()
    local items = {}
    for _, itemId in ipairs(game.lootStash or {}) do
        local item = ItemView.GetItemById(game, itemId)
        if item then items[#items + 1] = item end
    end
    return ItemSort.Sort(items)
end

local function BuildRewardCards(itemIds)
    local currentGame = GameStateAdapter.GetViewState()
    local cards = {}
    for _, itemId in ipairs(itemIds) do
        local item = ItemView.GetItemById(currentGame, itemId)
        if item then
            RewardDialogView.AddCard(
                cards,
                ItemView.ItemImage(item),
                item.name or "装备",
                nil,
                item.rarity or "common",
                item
            )
        end
    end
    return cards
end

function LootStashController.Configure(context)
    context_ = assert(context)
end

function LootStashController.Close(force)
    if forced_ and force ~= true then return false end
    RemoveOverlay()
    visible_ = false
    forced_ = false
    local onClosed = onClosed_
    onClosed_ = nil
    if onClosed then onClosed() end
    return true
end

function LootStashController.Show(forced, onClosed)
    if not root_ or not context_ then return false end

    RemoveOverlay()
    visible_ = true
    forced_ = forced == true
    if onClosed ~= nil then onClosed_ = onClosed end

    local items = CurrentItems()
    local claimedItemIds = {}
    local cards = {}
    local slotContext = context_.buildInventoryContext()
    for _, item in ipairs(items) do
        claimedItemIds[#claimedItemIds + 1] = item.id
        cards[#cards + 1] = BackpackItemSlot.Build(slotContext, item, {
            width = 180,
            height = 180,
            clickable = true,
            onClick = function() context_.equipItem(item) end,
        })
    end

    local content
    if #cards == 0 then
        content = UI.Panel {
            width = 720,
            height = 560,
            flexShrink = 0,
            alignItems = "center",
            justifyContent = "center",
            children = {
                Kit.CompactTxt("暂存箱为空", 24, C.textSecondary, {
                    width = "100%",
                    height = 48,
                    textAlign = "center",
                }),
            },
        }
    else
        local pageLabel = Kit.CompactTxt("1 / 1", 17, C.textDim, {
            width = 92,
            height = 28,
            textAlign = "right",
        })
        content = RewardDialogView.BuildCardPanel(cards, pageLabel)
    end

    local dialogChildren = {
        Kit.Txt("在线挂机暂存箱", 32, C.text, {
            position = "absolute",
            left = 80,
            top = 30,
            width = 740,
            height = 54,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
        }),
        Kit.CompactTxt("在线挂机获得的装备已进入背包；点击格子可穿戴，或全部收取后关闭暂存箱", 18, C.textSecondary, {
            position = "absolute",
            left = 80,
            top = 88,
            width = 740,
            height = 34,
            textAlign = "center",
        }),
        UI.Panel {
            position = "absolute",
            left = 90,
            top = 140,
            width = 720,
            height = 620,
            children = { content },
        },
        UI.Panel {
            position = "absolute",
            left = 300,
            top = 790,
            width = 300,
            height = 72,
            children = {
                Kit.ImageButton("全部收取", 300, 72, ASSETS.ui.buttonGreen, function()
                    if claimPending_ then return end
                    if #claimedItemIds == 0 then
                        if context_ and context_.actionResult then
                            context_.actionResult({
                                ok = false,
                                code = "LOOT_STASH_EMPTY",
                                reason = "暂存箱为空或装备已不在背包",
                            })
                        end
                        LootStashController.Close(true)
                        return
                    end
                    claimPending_ = true
                    local rewardReservation = DialogCoordinator.ReserveNext()
                    ServerClient.ClaimLootStash(function(response)
                        claimPending_ = false
                        if not context_.actionResult(response, "暂存装备已全部收取") then
                            DialogCoordinator.ReleaseReservation(rewardReservation)
                            return
                        end
                        LootStashController.Close(true)
                        local rewardCards = BuildRewardCards(claimedItemIds)
                        local rewardOptions = RewardDialogView.BuildOptions {
                            title = "暂存箱收取成功",
                            message = "已收取 " .. tostring(#rewardCards) .. " 件在线挂机装备",
                            lines = { "装备已存入背包，可前往背包查看或穿戴。" },
                            confirmText = "确认收取",
                            cards = rewardCards,
                        }
                        local shown = rewardOptions
                            and DialogCoordinator.EnqueueReserved(rewardReservation, rewardOptions)
                            or false
                        if not shown then DialogCoordinator.ReleaseReservation(rewardReservation) end
                        ServerClient.RequestSnapshot()
                    end)
                end, false),
            },
        },
    }

    if not forced_ then
        dialogChildren[#dialogChildren + 1] = UI.Panel {
            position = "absolute",
            right = 22,
            top = 22,
            width = 64,
            height = 64,
            clickable = true,
            backgroundImage = "image/ui/dialog/close_button.png",
            backgroundFit = "contain",
            onClick = LootStashController.Close,
        }
    end

    overlay_ = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        zIndex = 2200,
        pointerEvents = "box-none",
        alignItems = "center",
        justifyContent = "center",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                right = 0,
                bottom = 0,
                clickable = true,
                backgroundImage = "image/ui/generated/screen_overlay_1080x1920.png",
                backgroundFit = "cover",
                onClick = LootStashController.Close,
            },
            UI.Panel {
                position = "relative",
                width = 900,
                height = 900,
                clickable = true,
                overflow = "hidden",
                backgroundImage = ASSETS.ui.panelLarge,
                backgroundFit = "sliced",
                backgroundSlice = { 14, 14, 14, 14 },
                children = dialogChildren,
            },
        },
    }
    root_:AddChild(overlay_)
    return true
end

function LootStashController.AttachRoot(root)
    local reopen = visible_
    local forced = forced_
    local onClosed = onClosed_
    root_ = root
    overlay_ = nil
    if reopen then LootStashController.Show(forced, onClosed) end
end

function LootStashController.IsOpen()
    return visible_
end

function LootStashController.RefreshIfOpen()
    if not visible_ then return false end
    return LootStashController.Show(forced_, onClosed_)
end

function LootStashController.ShowLoginGuide(options)
    options = options or {}
    local game = GameStateAdapter.GetViewState()
    local count = #(game.lootStash or {})
    if count == 0 then return false end

    loginGuideShown_ = true
    local shown = CommonPromptDialog.Show {
        kind = "confirm",
        priority = options.priority or 1000,
        queueKey = options.queueKey or "loot_stash_login_guide",
        title = "在线挂机暂存箱待收取",
        message = "上次在线挂机还有 " .. tostring(count) .. " 件装备留在暂存箱中。",
        lines = {
            "请先前往暂存箱确认并全部收取。",
            "离线期间不会继续推进在线挂机，也不会向该暂存箱新增装备。",
        },
        closeOnOverlay = false,
        showClose = false,
        confirmText = "前往收取",
        onPresented = options.onPresented,
        onConfirm = function()
            LootStashController.Show(true, options.onClosed)
        end,
    }
    if not shown then loginGuideShown_ = false end
    return shown
end

function LootStashController.MaybeShowLoginGuide()
    if not context_ or context_.isOfflineLoginFlowPending() then return false end
    if loginGuideShown_ then return false end
    return LootStashController.ShowLoginGuide()
end

function LootStashController.ResetConnection()
    loginGuideShown_ = false
    claimPending_ = false
    onClosed_ = nil
    DialogCoordinator.CancelByKey("loot_stash_login_guide")
    LootStashController.Close(true)
end

function LootStashController.Reset()
    LootStashController.ResetConnection()
    root_ = nil
    context_ = nil
end

return LootStashController
