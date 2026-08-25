local UI = require("urhox-libs/UI")
local ItemSort = require("shared.ItemSort")
local RarityCatalog = require("shared.RarityCatalog")
local ServerClient = require("client.ServerClient")
local BackpackItemSlot = require("client.BackpackItemSlot")
local GridVirtualList = require("client.UI.GridVirtualList")
local EquipmentRecycleFilter = require("client.EquipmentRecycleFilter")
local EquipmentDispositionDialog = require("client.EquipmentDispositionDialog")

local BlackMarketView = {}

local RULES = "黑市按装备标准回收价收购可交易装备。锁定、穿戴中的装备不能出售；神话装备不在黑市出售范围内。批量出售由服务器校验并结算。\n\n交易行挂单价格不设上下限；价格不高于标准值10%的挂单，会在每日07:00与20:00（UTC+8）由系统低价扫货。"

-- 黑市背包网格（虚拟列表）：
-- 正文容器宽 940（body），滚动内容左右各 10 padding → 可用宽 920。
-- 卡片 180×180 + gap 14，一行可放 4 张：4*180 + 3*14 = 762 ≤ 920；不足一行取整为 4 列。
local MARKET_CARD_WIDTH = 180
local MARKET_CARD_HEIGHT = 180
local MARKET_CARD_GAP = 14
local MARKET_GRID_CONTENT_WIDTH = 940 - 20
local MARKET_GRID_COLUMNS = math.floor((MARKET_GRID_CONTENT_WIDTH + MARKET_CARD_GAP) / (MARKET_CARD_WIDTH + MARKET_CARD_GAP))

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
    local slotContext = EquipmentContext(context)
    -- 黑市背包虚拟网格：行池化复用，替代全量 cards + flexWrap ScrollView。
    -- 页面无滚动状态变量，无需接入 getScrollY/setScrollY。
    local inventoryGrid = GridVirtualList.Build {
        columns = MARKET_GRID_COLUMNS,
        cardWidth = MARKET_CARD_WIDTH,
        cardHeight = MARKET_CARD_HEIGHT,
        cardGap = MARKET_CARD_GAP,
        rowGap = MARKET_CARD_GAP,
        -- 视口高度（设计分辨率 1080×1920）：
        -- 页面中部 1440 - 市场外框上下 226 - body 上下 160 - 网格区上下 154 = 900。
        viewportHeight = 900,
        widgetProps = {
            width = "100%",
            height = "100%",
        },
        showScrollbar = true,
        data = visibleItems,
        createCard = function(row, slotIndex, item)
            if not item then return nil end
            return BackpackItemSlot.Build(slotContext, item, {
                width = MARKET_CARD_WIDTH,
                height = MARKET_CARD_HEIGHT,
                clickable = true,
                showLockButton = true,
                onClick = function(widget)
                    -- 行会被池化复用：点击时从当前绑定读取 item，禁止闭包捕获 bind 参数。
                    local currentItem = row._boundItems[slotIndex]
                    if not currentItem then return end
                    local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                        and widget:GetAbsoluteLayoutForHitTest()
                        or nil
                    context.showItemTips(currentItem, bounds, { source = "black-market" })
                end,
                onLongPress = function()
                    local currentItem = row._boundItems[slotIndex]
                    if not currentItem then return end
                    context.setEquipmentLock(currentItem)
                end,
            })
        end,
        emptyState = function()
            -- 空状态面板放在原 ScrollView 位置，保持原布局/文案原样返回。
            return UI.Panel {
                width = "100%",
                height = "100%",
                children = {
                    UI.Panel {
                        width = "100%", flexShrink = 0,
                        flexDirection = "row", flexWrap = "wrap",
                        justifyContent = "center", alignItems = "flex-start",
                        gap = 14,
                        paddingLeft = 10, paddingRight = 10,
                        paddingTop = 12, paddingBottom = 42,
                        children = {
                            UI.Panel {
                                width = "100%", height = 260, flexShrink = 0,
                                justifyContent = "center", alignItems = "center",
                                children = {
                                    context.compactTxt("当前没有可出售装备", 24, context.C.textSecondary, {
                                        width = "100%", height = 48, textAlign = "center",
                                        textStroke = { width = 1, color = "#000000" },
                                    }),
                                },
                            },
                        },
                    },
                },
            }
        end,
    }

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
                children = { inventoryGrid },
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
