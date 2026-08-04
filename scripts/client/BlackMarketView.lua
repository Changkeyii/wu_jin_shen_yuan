local UI = require("urhox-libs/UI")
local ItemSort = require("shared.ItemSort")
local RarityCatalog = require("shared.RarityCatalog")
local ServerClient = require("client.ServerClient")
local BackpackItemSlot = require("client.BackpackItemSlot")
local EquipmentRecycleFilter = require("client.EquipmentRecycleFilter")
local EquipmentDispositionDialog = require("client.EquipmentDispositionDialog")

local BlackMarketView = {}

local RULES = "黑市按装备标准回收价收购可交易装备。锁定、穿戴中的装备不能出售；神话装备不在黑市出售范围内。批量出售由服务器校验并结算。\n\n交易行挂单价格不设上下限；价格不高于标准值10%的挂单，会在每日07:00与20:00（UTC+8）由系统低价扫货。"

local function ImageButton(context, label, onClick, disabled)
    return UI.Panel {
        width = 260,
        height = 58,
        flexShrink = 0,
        clickable = not disabled,
        opacity = disabled and 0.42 or 1.0,
        backgroundImage = context.ASSETS.ui.inventoryActionBlue,
        backgroundFit = "contain",
        onClick = disabled and nil or onClick,
        children = {
            context.txt(label, 19, disabled and context.C.textDim or context.C.text, {
                width = "100%", height = 58, textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
        },
    }
end

local function RulesButton(context)
    return UI.Panel {
        width = 64,
        height = 64,
        flexShrink = 0,
        clickable = true,
        backgroundImage = "image/ui/dialog/help_button.png",
        backgroundFit = "contain",
        onClick = function()
            context.showPrompt {
                kind = "rules",
                queueKey = "rules:black-market",
                title = "黑市规则",
                message = RULES,
                confirmText = "知道了",
            }
        end,
    }
end

local function EquipmentContext(context)
    return {
        ASSETS = context.ASSETS,
        C = context.C,
        compactTxt = context.compactTxt,
        itemImage = context.itemImage,
        itemLevelText = context.itemLevelText,
        isEquipped = context.isEquipped,
        rarityColor = context.rarityColor,
        shortenText = context.shortenText,
        showItemTips = context.showItemTips,
        registerItemTipsTrigger = context.registerItemTipsTrigger,
        setEquipmentLock = context.setEquipmentLock,
    }
end

local function Toast(context, title, message)
    context.showPrompt { title = title, message = message, confirmText = "知道了" }
end

local function CollectVisibleItems(context)
    local equipped = {}
    for _, itemId in pairs(context.game.equippedSlots or {}) do equipped[itemId] = true end
    local result = {}
    for _, item in ipairs(context.game.inventory or {}) do
        local rarity = RarityCatalog.Get(item.rarity)
        if item.equipmentId and type(item.id) == "string" and #item.id == 36
            and rarity and rarity.rank <= 6
            and not equipped[item.id] and not item.aidLocked
        then
            result[#result + 1] = item
        end
    end
    return ItemSort.Sort(result)
end

local function OneClickSell(context, visibleItems)
    local candidates = EquipmentRecycleFilter.FilterItems("sell", visibleItems, function(item)
        return not item.locked
    end)
    if #candidates == 0 then
        Toast(context, "黑市", "当前没有符合出售筛选的装备")
        return
    end

    EquipmentDispositionDialog.Show(context.dispositionContext, {
        mode = "sell",
        items = candidates,
    })
end

function BlackMarketView.Build(context)
    local visibleItems = CollectVisibleItems(context)
    local cards = {}
    local slotContext = EquipmentContext(context)
    for _, item in ipairs(visibleItems) do
        cards[#cards + 1] = BackpackItemSlot.Build(slotContext, item, {
            width = 180,
            height = 180,
            clickable = true,
            showLockButton = true,
            onClick = function(widget)
                local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                    and widget:GetAbsoluteLayoutForHitTest()
                    or nil
                context.showItemTips(item, bounds, { source = "black-market" })
            end,
            onLongPress = function()
                context.setEquipmentLock(item)
            end,
        })
    end
    if #cards == 0 then
        cards[1] = UI.Panel {
            width = "100%", height = 260, flexShrink = 0,
            justifyContent = "center", alignItems = "center",
            children = {
                context.compactTxt("当前没有可出售装备", 24, context.C.textSecondary, {
                    width = "100%", height = 48, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" },
                }),
            },
        }
    end

    return UI.Panel {
        width = "100%", height = "100%", position = "relative", overflow = "hidden",
        children = {
            context.txt("深渊黑市", 27, context.C.gold, {
                position = "absolute", left = 28, top = 2,
                width = 260, height = 48, textAlign = "left",
                textStroke = { width = 2, color = "#000000" },
            }),
            context.compactTxt("可处理 " .. tostring(#visibleItems) .. " 件装备", 18,
                context.C.textSecondary, {
                    position = "absolute", left = 300, top = 10,
                    width = 300, height = 34, textAlign = "left",
                }),
            UI.Panel {
                position = "absolute", right = 16, top = 0,
                width = 64, height = 64,
                children = { RulesButton(context) },
            },
            UI.Panel {
                position = "absolute", left = 0, top = 62, right = 0, bottom = 92,
                overflow = "hidden",
                children = {
                    UI.ScrollView {
                        width = "100%", height = "100%",
                        scrollX = false, scrollY = true, showScrollbar = true,
                        children = {
                            UI.Panel {
                                width = "100%", flexShrink = 0,
                                flexDirection = "row", flexWrap = "wrap",
                                justifyContent = "center", alignItems = "flex-start",
                                gap = 14,
                                paddingLeft = 10, paddingRight = 10,
                                paddingTop = 12, paddingBottom = 42,
                                children = cards,
                            },
                        },
                    },
                },
            },
            UI.Panel {
                position = "absolute", left = 170, bottom = 12,
                width = 600, height = 64,
                flexDirection = "row", gap = 24,
                justifyContent = "center", alignItems = "center",
                children = {
                    ImageButton(context, "一键出售", function()
                        OneClickSell(context, visibleItems)
                    end, context.game.readOnly),
                    ImageButton(context, "出售筛选", function()
                        EquipmentRecycleFilter.Show("sell", { onSaved = context.onRefresh })
                    end, false),
                },
            },
        },
    }
end

return BlackMarketView
