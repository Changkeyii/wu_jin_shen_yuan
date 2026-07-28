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
    return UI.Panel {
        width = width,
        height = height,
        flexShrink = 0,
        clickable = options.clickable == true,
        position = "relative",
        backgroundImage = active and context.ASSETS.ui.inventoryItemCardSelected
            or context.ASSETS.ui.inventoryItemCard,
        backgroundFit = "contain",
        borderWidth = active and 3 or 1,
        borderColor = active and context.C.focus or context.rarityColor(item.rarity),
        onPointerDown = options.onPointerDown,
        onPointerUp = options.onPointerUp,
        onClick = options.onClick,
        onPointerEnter = options.onPointerEnter,
        onPointerLeave = options.onPointerLeave,
        children = children,
    }
end

return EquipmentItemSlot
