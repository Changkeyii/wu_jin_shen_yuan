local UI = require("urhox-libs/UI")
local ItemSlotBase = require("client.ItemSlotBase")

local BackpackItemSlot = {}

function BackpackItemSlot.Build(context, item, options)
    options = options or {}
    local cardSize = options.width or 180
    local cardHeight = options.height or cardSize
    local slotSize = math.floor(cardSize * 0.81)
    local slotX = math.floor((cardSize - slotSize) * 0.5)
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
                }),
            },
        },
        context.compactTxt(context.shortenText(item.name or "未知装备", 8), 14, context.rarityColor(item.rarity), {
            position = "absolute", left = 8, top = 148,
            width = cardSize - 16, height = 28, textAlign = "center",
            textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
        }),
    }
    if options.amountText then
        children[#children + 1] = context.compactTxt(options.amountText, 16, context.C.text, {
            position = "absolute", right = 14, top = slotSize - 12,
            width = cardSize - 28, height = 26, textAlign = "right",
            textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
        })
    end
    return UI.Panel {
        width = cardSize,
        height = cardHeight,
        clickable = options.clickable == true,
        position = "relative",
        overflow = "visible",
        backgroundImage = context.ASSETS.ui.inventoryItemCard,
        backgroundFit = "contain",
        onClick = options.onClick,
        onPointerEnter = options.onPointerEnter,
        onPointerLeave = options.onPointerLeave,
        children = children,
    }
end

return BackpackItemSlot
