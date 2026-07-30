local UI = require("urhox-libs/UI")
local ItemSlotBase = require("client.ItemSlotBase")

local BackpackItemSlot = {}

function BackpackItemSlot.Build(context, item, options)
    options = options or {}
    local cardSize = options.width or 180
    local cardHeight = options.height or cardSize
    local slotSize = math.floor(cardSize * 0.81)
    local slotX = math.floor((cardSize - slotSize) * 0.5)
    local nameTop = math.min(cardHeight - 32, math.floor(cardSize * 0.82))
    local selected = options.selected == true
    local children = {
        UI.Panel {
            position = "absolute", left = slotX, top = 5,
            width = slotSize, height = slotSize,
            children = {
                ItemSlotBase.Build(context, item, {
                    size = slotSize,
                    selected = selected,
                    fallbackImage = options.fallbackImage,
                    showLevel = options.showLevel,
                    showEnhance = options.showEnhance,
                    showStars = options.showStars,
                    showEquipped = options.showEquipped,
                    opacity = options.opacity,
                }),
            },
        },
        context.compactTxt(context.shortenText(item.name or "未知装备", 8), 14, context.rarityColor(item.rarity), {
            position = "absolute", left = 8, top = nameTop,
            width = cardSize - 16, height = 28, textAlign = "center",
            textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
        }),
    }
    if options.amountText then
        children[#children + 1] = context.compactTxt(options.amountText, 16, context.C.text, {
            position = "absolute",
            left = slotX + 8,
            top = 5 + slotSize - 30,
            width = slotSize - 16,
            height = 26,
            textAlign = "right",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        })
    end
    local longPressConsumed = false
    local onLongPress = options.onLongPress
    if not onLongPress and context.showItemTips then
        onLongPress = function(_, widget)
            local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                and widget:GetAbsoluteLayoutForHitTest()
                or nil
            context.showItemTips(item, bounds)
        end
    end
    local function HandleLongPress(event, widget)
        longPressConsumed = true
        if onLongPress then onLongPress(event, widget) end
    end
    local function HandleClick(widget, event)
        if longPressConsumed then
            longPressConsumed = false
            return
        end
        if options.onClick then options.onClick(widget, event) end
    end
    local widget = UI.Panel {
        width = cardSize,
        height = cardHeight,
        clickable = options.clickable == true,
        position = "relative",
        overflow = "visible",
        backgroundImage = context.ASSETS.ui.inventoryItemCard,
        backgroundFit = "contain",
        onClick = HandleClick,
        onLongPress = onLongPress and HandleLongPress or nil,
        onLongPressStart = options.onLongPressStart,
        onLongPressEnd = options.onLongPressEnd,
        children = children,
    }
    if context.registerItemTipsTrigger and options.itemTips ~= false then
        context.registerItemTipsTrigger(widget, item)
    end
    return widget
end

return BackpackItemSlot
