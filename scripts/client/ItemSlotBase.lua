local UI = require("urhox-libs/UI")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local EquipmentIcon = require("client.EquipmentIcon")

local ItemSlotBase = {}

function ItemSlotBase.Frame(assets, item, selected)
    if selected then return assets.ui.inventorySlotSelected end
    if not item then return assets.ui.inventorySlotEmpty end
    local rarity = item.rarity
    if rarity == "myth" then return assets.ui.inventorySlotMyth end
    if rarity == "epic" or rarity == "legendary" or rarity == "legend" then
        return assets.ui.inventorySlotLegend
    end
    if rarity == "artifact" or rarity == "rare" or rarity == "purple" then
        return assets.ui.inventorySlotEpic
    end
    if rarity == "advanced" or rarity == "blue" then return assets.ui.inventorySlotRare end
    return assets.ui.inventorySlotCommon
end

function ItemSlotBase.Icon(context, item, props, fallbackImage)
    props = props or {}
    local definition = item and item.equipmentId and EquipmentCatalog.Get(item.equipmentId) or nil
    if definition and definition.atlas and definition.atlasIndex ~= nil then
        props.atlas = definition.atlas
        props.atlasIndex = definition.atlasIndex
        props.atlasColumns = EquipmentCatalog.ATLAS_COLUMNS
        props.atlasCellSize = EquipmentCatalog.ATLAS_CELL_SIZE
        return EquipmentIcon(props)
    end
    props.backgroundImage = fallbackImage or context.itemImage(item)
    props.backgroundFit = "contain"
    return UI.Panel(props)
end

function ItemSlotBase.Build(context, item, options)
    options = options or {}
    local size = options.size or 144
    local selected = options.selected == true
    local scale = size / 144
    local function S(value) return math.floor(value * scale + 0.5) end
    local children = {
        UI.Panel {
            position = "absolute", left = 0, top = 0,
            width = size, height = size,
            backgroundImage = ItemSlotBase.Frame(context.ASSETS, item, false),
            backgroundFit = "contain",
            pointerEvents = "none",
        },
    }
    if item then
        children[#children + 1] = ItemSlotBase.Icon(context, item, {
            position = "absolute", left = S(29), top = S(29),
            width = S(86), height = S(86),
            opacity = options.opacity or 1.0,
            pointerEvents = "none",
        }, options.fallbackImage)
        if options.showLevel ~= false then
            local itemLevelText = context.itemLevelText or function(value)
                return "Lv" .. tostring(value.level or value.dropLevel or value.floor or value.tier or 1)
            end
            children[#children + 1] = context.compactTxt(itemLevelText(item), 13, context.C.text, {
                position = "absolute", left = S(42), top = S(6),
                width = S(96), height = S(32), textAlign = "right",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            })
        end
        local enhance = options.showEnhance == false and 0 or (item.enhance or 0)
        if enhance > 0 then
            children[#children + 1] = context.compactTxt("+" .. tostring(enhance), 17, context.C.gold, {
                position = "absolute", left = S(10), top = S(106),
                width = S(42), height = S(24), textAlign = "left",
                textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
            })
        end
        local star = options.showStars == false and 0 or math.max(0, math.min(5, item.star or 0))
        if star > 0 then
            children[#children + 1] = context.compactTxt(string.rep("★", star), 13, context.C.gold, {
                position = "absolute", left = S(58), top = S(106),
                width = S(72), height = S(24), textAlign = "right",
                textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
            })
        end
        if options.showEquipped ~= false and context.isEquipped and context.isEquipped(item) then
            children[#children + 1] = context.compactTxt("E", 15, context.C.success, {
                position = "absolute", left = S(12), top = S(12),
                width = S(24), height = S(24), textAlign = "center",
                textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
            })
        end
        local rarity = item.rarity
        if rarity == "artifact" or rarity == "legendary" or rarity == "legend"
            or rarity == "epic" or rarity == "myth"
        then
            children[#children + 1] = UI.Panel {
                position = "absolute", left = S(8), top = S(8),
                width = S(128), height = S(128),
                backgroundImage = context.ASSETS.ui.selectionFrame,
                backgroundFit = "contain",
                imageTint = context.rarityColor(rarity),
                opacity = 0.20,
                pointerEvents = "none",
            }
        end
    end
    if selected then
        children[#children + 1] = UI.Panel {
            position = "absolute", left = 0, top = 0,
            width = size, height = size,
            backgroundImage = context.ASSETS.ui.selectionFrame,
            backgroundFit = "contain",
            pointerEvents = "none",
        }
    end
    return UI.Panel {
        width = size, height = size, flexShrink = 0,
        position = "relative", overflow = "visible", children = children,
    }
end

return ItemSlotBase
