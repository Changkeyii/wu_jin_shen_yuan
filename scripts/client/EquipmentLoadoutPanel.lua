-- EquipmentLoadoutPanel.lua
-- 通用只读「12 部位装备展示」组件，复刻装备页上方展示（立绘 + 玩家名 + 12 部位 + 连线）。
-- 外部传入数据即可显示，供排行榜详情等模块复用。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local EquipmentIcon = require("client.EquipmentIcon")
local ItemView = require("client.ItemView")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS
local SLOTS = GameTheme.Slots
local slotIcons = ASSETS.ui.equipmentSlotIcons

-- 与装备页一致的 12 部位坐标 / 连线布局
local EQUIPMENT_LAYOUT = {
    { slotX = 146, slotY = 138, startSide = "right", anchorX = 390, anchorY = 314, route = { { x = 274, y = 194 }, { x = 274, y = 314 }, { x = 374, y = 314 } } },
    { slotX = 20, slotY = 82, startSide = "right", anchorX = 392, anchorY = 196, route = { { x = 142, y = 138 }, { x = 142, y = 196 }, { x = 376, y = 196 } } },
    { slotX = 20, slotY = 276, startSide = "right", anchorX = 402, anchorY = 254, route = { { x = 154, y = 332 }, { x = 154, y = 254 }, { x = 386, y = 254 } } },
    { slotX = 700, slotY = 526, startSide = "left", anchorX = 483, anchorY = 332, route = { { x = 590, y = 582 }, { x = 590, y = 332 } } },
    { slotX = 146, slotY = 332, startSide = "right", anchorX = 457, anchorY = 261, route = { { x = 282, y = 388 }, { x = 282, y = 261 } } },
    { slotX = 20, slotY = 526, startSide = "right", anchorX = 391, anchorY = 472, route = { { x = 270, y = 582 }, { x = 270, y = 472 } } },
    { slotX = 146, slotY = 470, startSide = "right", anchorX = 377, anchorY = 263, route = { { x = 282, y = 526 }, { x = 282, y = 263 } } },
    { slotX = 574, slotY = 138, startSide = "left", anchorX = 443, anchorY = 179, route = { { x = 562, y = 194 }, { x = 562, y = 179 } } },
    { slotX = 574, slotY = 332, startSide = "left", anchorX = 502, anchorY = 284, route = { { x = 562, y = 388 }, { x = 562, y = 284 } } },
    { slotX = 700, slotY = 276, startSide = "left", anchorX = 478, anchorY = 234, route = { { x = 590, y = 332 }, { x = 590, y = 234 } } },
    { slotX = 574, slotY = 470, startSide = "left", anchorX = 454, anchorY = 202, route = { { x = 562, y = 526 }, { x = 562, y = 202 } } },
    { slotX = 700, slotY = 82, startSide = "left", anchorX = 433, anchorY = 160, route = { { x = 590, y = 138 }, { x = 590, y = 160 } } },
}

local EquipmentLoadoutPanel = {}

local function ItemIcon(item, props, fallbackImage)
    props = props or {}
    local definition = item and item.equipmentId and EquipmentCatalog.Get(item.equipmentId) or nil
    if definition and definition.atlas and definition.atlasIndex ~= nil then
        props.atlas = definition.atlas
        props.atlasIndex = definition.atlasIndex
        props.atlasColumns = EquipmentCatalog.ATLAS_COLUMNS
        props.atlasCellSize = EquipmentCatalog.ATLAS_CELL_SIZE
        return EquipmentIcon(props)
    end
    props.backgroundImage = fallbackImage or ItemView.ItemImage(item)
    props.backgroundFit = "contain"
    return UI.Panel(props)
end

local function CreateFreeLineSegment(from, to, active)
    local dx = to.x - from.x
    local dy = to.y - from.y
    local length = math.sqrt(dx * dx + dy * dy)
    if length < 2 then return nil end
    return UI.Panel {
        position = "absolute",
        left = from.x,
        top = from.y - (active and 2 or 1.5),
        width = length,
        height = active and 4 or 3,
        backgroundColor = active and C.focus or { 55, 137, 214, 180 },
        opacity = active and 0.96 or 0.7,
        rotate = math.deg(math.atan(dy, dx)),
        transformOrigin = "top-left",
        pointerEvents = "none",
    }
end

local function CreateRoutedConnector(layout, active, animationIndex)
    local startOnRight = layout.startSide == "right"
    local startX
    if startOnRight then
        startX = layout.x + 112
    elseif layout.startSide == "left" then
        startX = layout.x
    else
        startX = layout.x < 430 and (layout.x + 112) or layout.x
    end
    local startY = layout.y + 56
    local anchorX = layout.anchorX
    local anchorY = layout.anchorY
    local points = {
        { x = startX, y = startY },
    }
    for _, point in ipairs(layout.route or {}) do
        points[#points + 1] = point
    end
    points[#points + 1] = { x = anchorX, y = anchorY }

    local segments = {}
    for index = 1, #points - 1 do
        local segment = CreateFreeLineSegment(points[index], points[index + 1], active)
        if segment then segments[#segments + 1] = segment end
    end
    local dotSize = active and 12 or 9
    segments[#segments + 1] = UI.Panel {
        position = "absolute",
        left = anchorX - dotSize * 0.5,
        top = anchorY - dotSize * 0.5,
        width = dotSize,
        height = dotSize,
        shape = "circle",
        backgroundColor = active and C.focus or { 76, 158, 230, 210 },
        borderWidth = 2,
        borderColor = { 8, 24, 54, 255 },
        pointerEvents = "none",
    }

    return UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = 860,
        height = 720,
        pointerEvents = "none",
        children = segments,
    }
end

local function CreateSlot(options, slot, layout, index)
    local item = options.equipped and options.equipped[slot.id]
    local active = options.activeSlot == slot.id
    local widget = UI.Panel {
        position = "absolute",
        left = layout.x,
        top = layout.y,
        width = 112,
        height = 112,
        clickable = item ~= nil,
        backgroundImage = active and ASSETS.ui.equipSlotSelected or ASSETS.ui.equipSlot,
        backgroundFit = "contain",
        onClick = function(widget)
            if item and options.onSlotClick then options.onSlotClick(item, slot, widget) end
        end,
        children = {
            UI.Panel {
                position = "absolute",
                left = 20,
                top = 14,
                width = 72,
                height = 72,
                children = {
                    ItemIcon(item, {
                        width = 72,
                        height = 72,
                        opacity = item and 1.0 or 0.66,
                    }, slotIcons[slot.id]),
                },
            },
            Kit.CompactTxt(slot.name, 15, active and C.focus or C.textSecondary, {
                position = "absolute",
                left = 5,
                top = 84,
                width = 102,
                height = 21,
                textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
                pointerEvents = "none",
            }),
        },
    }
    if item then
        widget:AddChild(Kit.CompactTxt("+" .. tostring(item.enhance or 0), 13, C.gold, {
            position = "absolute",
            left = 7,
            top = 7,
            width = 34,
            height = 20,
            textAlign = "left",
            textStroke = { width = 1, color = "#000000" },
            pointerEvents = "none",
        }))
    end
    return widget
end

--- 构建只读装备展示面板
---@param options table
---@return table UI.Panel
function EquipmentLoadoutPanel.Build(options)
    options = options or {}
    -- 与装备页一致：将 slotX/slotY 映射为布局用的 x/y
    local slotLayout = {}
    for index, layout in ipairs(EQUIPMENT_LAYOUT) do
        slotLayout[index] = {
            x = layout.slotX,
            y = layout.slotY,
            startSide = layout.startSide,
            anchorX = layout.anchorX,
            anchorY = layout.anchorY,
            route = layout.route,
        }
    end
    local children = {
        Kit.Txt(tostring(options.nickname or ""), 27, C.text, {
            position = "absolute", left = 280, top = 20, width = 300, height = 36,
            textAlign = "center", textStroke = { width = 2, color = "#000000" },
        }),
        UI.Panel {
            position = "absolute", left = 292, top = 98, width = 276, height = 430,
            backgroundImage = options.portrait or ASSETS.player.icon,
            backgroundFit = "contain",
            pointerEvents = "none",
            opacity = 0.98,
        },
        UI.Panel {
            position = "absolute", left = 278, top = 84, width = 304, height = 458,
            borderWidth = 2, borderColor = { 50, 196, 255, 120 },
            backgroundColor = { 12, 42, 82, 55 },
            pointerEvents = "none",
        },
        Kit.CompactTxt("点击装备查看详情", 19, C.focus, {
            position = "absolute", left = 280, top = 616, width = 300, height = 26,
            textAlign = "center", textStroke = { width = 1, color = "#000000" },
            pointerEvents = "none",
        }),
    }

    for index, slot in ipairs(SLOTS) do
        local layout = slotLayout[index]
        children[#children + 1] = CreateRoutedConnector(layout, options.activeSlot == slot.id, index)
    end
    for index, slot in ipairs(SLOTS) do
        local layout = slotLayout[index]
        children[#children + 1] = CreateSlot(options, slot, layout, index)
    end

    return UI.Panel {
        width = 860,
        height = 720,
        flexShrink = 0,
        position = "relative",
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        children = children,
    }
end

return EquipmentLoadoutPanel
