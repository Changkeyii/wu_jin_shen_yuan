local UI = require("urhox-libs/UI")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local BackpackItemSlot = require("client.BackpackItemSlot")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ItemView = require("client.ItemView")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local EquipmentUpgradePromptController = {}

local context_ = nil
local root_ = nil
local overlay_ = nil
local pendingValue_ = nil
local pendingDecisionId_ = nil

local function RemoveOverlay()
    if overlay_ and root_ then root_:RemoveChild(overlay_) end
    overlay_ = nil
end

function EquipmentUpgradePromptController.Configure(context)
    context_ = assert(context)
end

function EquipmentUpgradePromptController.Close()
    RemoveOverlay()
    pendingValue_ = nil
    pendingDecisionId_ = nil
end

function EquipmentUpgradePromptController.Show(value)
    value = value or {}
    local decisionId = value.decisionId or value.itemId
    if not root_ or not context_ or decisionId == nil then return false end
    if overlay_ and tostring(decisionId) == tostring(pendingDecisionId_) then return false end

    RemoveOverlay()
    pendingValue_ = value
    pendingDecisionId_ = decisionId

    local game = GameStateAdapter.GetViewState()
    local item = ItemView.GetItemById(game, value.itemId) or value
    local current = game.equipped and game.equipped[item.slot] or nil
    local slotContext = context_.buildInventoryContext()
    local itemId = value.itemId

    local children = {
        Kit.CompactTxt("发现更强装备", 22, C.gold, {
            position = "absolute",
            left = 18,
            top = 10,
            width = 444,
            height = 34,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
        }),
        Kit.CompactTxt("当前", 16, C.textSecondary, {
            position = "absolute",
            left = 24,
            top = 52,
            width = 180,
            height = 26,
            textAlign = "center",
        }),
        Kit.CompactTxt("新装备", 16, C.focus, {
            position = "absolute",
            left = 276,
            top = 52,
            width = 180,
            height = 26,
            textAlign = "center",
        }),
        UI.Panel {
            position = "absolute",
            left = 24,
            top = 78,
            width = 180,
            height = 180,
            children = {
                BackpackItemSlot.Build(slotContext, current or {
                    name = "未装备",
                    rarity = "common",
                    level = 1,
                }, {
                    width = 180,
                    height = 180,
                    clickable = false,
                    showEquipped = false,
                }),
            },
        },
        UI.Panel {
            position = "absolute",
            left = 276,
            top = 78,
            width = 180,
            height = 180,
            children = {
                BackpackItemSlot.Build(slotContext, item, {
                    width = 180,
                    height = 180,
                    clickable = false,
                    showEquipped = false,
                }),
            },
        },
        Kit.CompactTxt("战力提升 " .. Kit.FormatInt(value.displayedPowerDeltaBig or value.displayedPowerDelta or 0), 18, C.success, {
            position = "absolute",
            left = 20,
            top = 270,
            width = 440,
            height = 30,
            textAlign = "center",
            textStroke = { width = 1, color = "#000000" },
        }),
        UI.Panel {
            position = "absolute",
            left = 24,
            top = 312,
            width = 200,
            height = 58,
            children = {
                Kit.ImageButton("保留原装", 200, 58, ASSETS.ui.buttonBlueWide, function()
                    EquipmentUpgradePromptController.Close()
                    ServerClient.DecideEquip("keep", itemId, context_.actionResult)
                end, false),
            },
        },
        UI.Panel {
            position = "absolute",
            right = 24,
            top = 312,
            width = 200,
            height = 58,
            children = {
                Kit.ImageButton("立即装备", 200, 58, ASSETS.ui.buttonGreen, function()
                    EquipmentUpgradePromptController.Close()
                    ServerClient.DecideEquip("equip", itemId, function(response)
                        context_.actionResult(response, response and response.ok and "装备已穿戴" or nil)
                        context_.refreshLootStash()
                    end)
                end, false),
            },
        },
    }

    overlay_ = UI.Panel {
        position = "absolute",
        right = 24,
        top = 340,
        width = 480,
        height = 398,
        zIndex = 1800,
        clickable = true,
        overflow = "hidden",
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 14, 14, 14, 14 },
        boxShadow = { { x = 0, y = 6, blur = 16, color = { 0, 0, 0, 150 } } },
        children = children,
    }
    root_:AddChild(overlay_)
    return true
end

function EquipmentUpgradePromptController.AttachRoot(root)
    local pendingValue = pendingValue_
    root_ = root
    overlay_ = nil
    pendingDecisionId_ = nil
    if pendingValue then EquipmentUpgradePromptController.Show(pendingValue) end
end

function EquipmentUpgradePromptController.Reset()
    RemoveOverlay()
    context_ = nil
    root_ = nil
    pendingValue_ = nil
    pendingDecisionId_ = nil
end

return EquipmentUpgradePromptController
