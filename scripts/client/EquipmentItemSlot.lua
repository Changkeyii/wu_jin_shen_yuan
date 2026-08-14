local UI = require("urhox-libs/UI")
local ItemSlotBase = require("client.ItemSlotBase")

local EquipmentItemSlot = {}

function EquipmentItemSlot.Build(context, item, options)
    options = options or {}
    local active = options.active == true
    local width = options.width or 180
    local height = options.height or 182
    local slotSize = options.slotSize or 128
    local slotLeft = math.floor((width - slotSize) * 0.5)
    local children = {
        UI.Panel {
            position = "absolute", left = slotLeft, top = 7,
            width = slotSize, height = slotSize,
            children = {
                ItemSlotBase.Build(context, item, {
                    size = slotSize,
                    selected = active,
                    fallbackImage = options.fallbackImage,
                    showLevel = options.showLevel,
                    showEnhance = options.showEnhance,
                    showStars = options.showStars,
                    showEquipped = options.showEquipped,
                }),
            },
        },
        context.compactTxt(context.shortenText(item.name or "未知装备", 8), 15, context.rarityColor(item.rarity), {
            position = "absolute", left = 8, top = 133,
            width = width - 16, height = 27, textAlign = "center",
            textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
        }),
    }
    local detailText = options.detailText
    if detailText then
        children[#children + 1] = context.compactTxt(detailText, 15, context.C.gold, {
            position = "absolute", left = 10, top = 158,
            width = width - 20, height = 19, textAlign = "center",
            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
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
    local tutorialHighlight = options.tutorialHighlight == true
    local widget = UI.Panel {
        -- 构造时写入 id，引导层按 instance.id 查找更稳。
        id = options.id,
        width = width,
        height = height,
        flexShrink = 0,
        clickable = options.clickable == true,
        position = "relative",
        backgroundImage = active and context.ASSETS.ui.inventoryItemCardSelected
            or context.ASSETS.ui.inventoryItemCard,
        backgroundFit = "contain",
        borderWidth = tutorialHighlight and 5 or (active and 3 or 1),
        borderColor = tutorialHighlight and (context.C.focus or { 111, 231, 255, 255 })
            or (active and context.C.focus or context.rarityColor(item.rarity)),
        boxShadow = tutorialHighlight and {
            color = {
                (context.C.focus and context.C.focus[1]) or 111,
                (context.C.focus and context.C.focus[2]) or 231,
                (context.C.focus and context.C.focus[3]) or 255,
                180,
            },
            offsetX = 0, offsetY = 0, blurRadius = 18,
        } or nil,
        onPointerDown = options.onPointerDown,
        onPointerUp = options.onPointerUp,
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

return EquipmentItemSlot
