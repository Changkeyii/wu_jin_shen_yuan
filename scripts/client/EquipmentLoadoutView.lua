local UI = require("urhox-libs/UI")
local ItemSort = require("shared.ItemSort")
local ItemSlotBase = require("client.ItemSlotBase")
local EquipmentItemSlot = require("client.EquipmentItemSlot")
local EquipmentQuickFilter = require("client.EquipmentQuickFilter")

local EquipmentLoadoutView = {}

-- Coordinates are relative to the 860 x 720 character equipment area.
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

function EquipmentLoadoutView.Build(context)
    local view = assert(context.view)
    local state = assert(context.state)
    local actions = assert(context.actions)
    local tips = assert(context.tips)
    local UI = UI
    local C = view.C
    local ASSETS = view.assets
    local SLOTS = view.slots
    local inventoryEmptyState = view.inventoryEmptyState
    local characterPortrait = view.characterPortrait
    local playerNickname = view.playerNickname
    local slotIcons = ASSETS.ui.equipmentSlotIcons
    local ui = view.clipboard
    local game = state.game
    local selectedInventoryId = state.getSelectedInventoryId()
    local selectedSlot = state.getSelectedSlot()
    local SetSelectedInventoryId = state.setSelectedInventoryId
    local SetSelectedSlot = state.setSelectedSlot
    local GetEquipmentScrollY = state.getEquipmentScrollY
    local SetEquipmentScrollY = state.setEquipmentScrollY
    local GetEquipmentPageScrollY = state.getEquipmentPageScrollY
    local SetEquipmentPageScrollY = state.setEquipmentPageScrollY
    local RequestPageRefresh = actions.requestPageRefresh
    local EquipItem = actions.equipItem
    local UnequipSlot = actions.unequipSlot
    local AutoEquipBest = actions.autoEquipBest
    local StrengthenSelected = actions.strengthenSelected
    local StarSelected = actions.starSelected
    local readOnly = state.readOnly
    local RarityColor = view.rarityColor
    local RarityName = view.rarityName
    local SlotName = view.slotName
    local ItemPowerText = view.itemPowerText
    local ItemImage = view.itemImage
    local IsEquipped = view.isEquipped
    local ShortenText = view.shortenText
    local CompactTxt = view.compactTxt
    local Txt = view.txt
    local ImageButton = view.imageButton
    local GetItemById = state.getItemById
    local ShowItemTips = tips.show
    local RegisterItemTipsTrigger = tips.registerTrigger
    local slotContext = {
        C = C,
        ASSETS = ASSETS,
        compactTxt = CompactTxt,
        shortenText = ShortenText,
        rarityColor = RarityColor,
        itemImage = ItemImage,
        itemLevelText = view.itemLevelText,
        isEquipped = IsEquipped,
        showItemTips = ShowItemTips,
        registerItemTipsTrigger = RegisterItemTipsTrigger,
    }
    local function ItemIcon(item, props, fallbackImage)
        return ItemSlotBase.Icon(slotContext, item, props, fallbackImage)
    end

    local function IsEquipCandidate(item)
        return item
            and item.equipmentId
            and item.category ~= "consumable"
            and item.category ~= "material"
            and EquipmentQuickFilter.Matches("equip", item)
    end

    local function CollectSlotCandidates(slotId)
        local list = {}
        for _, item in ipairs(game.inventory or {}) do
            if item.slot == slotId and IsEquipCandidate(item) then
                list[#list + 1] = item
            end
        end
        ItemSort.Sort(list)
        return list
    end

    local filtered = CollectSlotCandidates(selectedSlot)
    -- 序章穿戴/强化：优先切到已穿戴武器部位，保证强化按钮可用且高亮目标稳定。
    do
        local TutorialController = require("client.TutorialController")
        local tutorialStep = TutorialController.IsActive and TutorialController.IsActive()
            and TutorialController.GetStep and TutorialController.GetStep()
            or nil
        if tutorialStep == 2 or tutorialStep == 4 then
            local preferred = nil
            -- 强化教学：优先当前已穿戴武器。
            if tutorialStep == 4 then
                local equippedWeapon = game.equipped and game.equipped.weapon or nil
                if type(equippedWeapon) == "table" and equippedWeapon.id then
                    preferred = equippedWeapon
                elseif equippedWeapon then
                    preferred = GetItemById(equippedWeapon)
                end
            end
            if not preferred then
                for _, item in ipairs(game.inventory or {}) do
                    if IsEquipCandidate(item) and item.source == "tutorial_drop" and item.slot == "weapon" then
                        preferred = item
                        break
                    end
                end
            end
            if not preferred then
                for _, item in ipairs(game.inventory or {}) do
                    if IsEquipCandidate(item) and item.source == "tutorial_drop" then
                        preferred = item
                        break
                    end
                end
            end
            if not preferred then
                for _, item in ipairs(game.inventory or {}) do
                    if IsEquipCandidate(item) then
                        preferred = item
                        break
                    end
                end
            end
            local preferredSlot = (preferred and preferred.slot)
                or (tutorialStep == 4 and "weapon")
                or nil
            if preferredSlot and preferredSlot ~= selectedSlot then
                SetSelectedSlot(preferredSlot)
                selectedSlot = preferredSlot
                filtered = CollectSlotCandidates(selectedSlot)
            end
            if preferred then
                selectedInventoryId = preferred.id
                SetSelectedInventoryId(preferred.id)
            end
        end
    end

    local selectedCandidate = selectedInventoryId and GetItemById(selectedInventoryId) or nil
    if not selectedCandidate or selectedCandidate.slot ~= selectedSlot
        or not EquipmentQuickFilter.Matches("equip", selectedCandidate)
    then
        selectedCandidate = filtered[1]
        SetSelectedInventoryId(selectedCandidate and selectedCandidate.id or nil)
    end

    local draggingItem = nil
    local dragHint = nil

    local function StartDrag(item)
        if readOnly or not item then return end
        draggingItem = item
        if dragHint then dragHint:SetText("拖到 " .. SlotName(item.slot) .. " 槽位即可穿戴") end
    end

    local function DropOnSlot(slotId)
        if not draggingItem then return end
        local item = draggingItem
        draggingItem = nil
        if dragHint then dragHint:SetText("") end
        if item.slot ~= slotId then
            UI.Toast.Show("这件装备不能放入该部位", { duration = 2, variant = "warning", position = "bottom" })
            return
        end
        SetSelectedSlot(slotId)
        SetSelectedInventoryId(item.id)
        EquipItem(item)
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
        local endpoint = UI.Panel {
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
        endpoint:Animate {
            keyframes = {
                [0] = { opacity = 0.55, scale = 0.86 },
                [0.5] = { opacity = 1.0, scale = 1.08 },
                [1] = { opacity = 0.55, scale = 0.86 },
            },
            duration = 1.5 + animationIndex * 0.05,
            easing = "easeInOut",
            loop = true,
        }
        segments[#segments + 1] = endpoint

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

    local drawMode = false
    local editorSelectedIndex = nil
    local drawPreview = nil
    local drawModeLabel = nil
    local editorSlotLabel = nil
    local editorToolbar = nil
    local drawSurface = nil
    local connectorWidgets = {}
    local connectorLayer = nil
    local RefreshConnector = nil

    local function CreateSlot(slot, left, top, animationIndex)
        local item = game.equipped and game.equipped[slot.id]
        local active = selectedSlot == slot.id
        local longPressConsumed = false
        local slotWidget = UI.Panel {
            position = "absolute",
            left = left,
            top = top,
            width = 112,
            height = 112,
            clickable = true,
            backgroundImage = active and ASSETS.ui.equipSlotSelected or ASSETS.ui.equipSlot,
            backgroundFit = "contain",
            onPointerUp = function()
                if draggingItem then DropOnSlot(slot.id) end
            end,
            onClick = function(widget)
                if longPressConsumed then
                    longPressConsumed = false
                    return
                end
                if drawMode then
                    SetSelectedSlot(slot.id)
                    SetSelectedInventoryId(item and item.id or nil)
                    if editorSelectedIndex and editorSelectedIndex ~= animationIndex then
                        RefreshConnector(editorSelectedIndex)
                    end
                    editorSelectedIndex = animationIndex
                    local oldConnector = connectorWidgets[animationIndex]
                    if oldConnector and connectorLayer then
                        connectorLayer:RemoveChild(oldConnector)
                        connectorWidgets[animationIndex] = nil
                    end
                    if editorSlotLabel then editorSlotLabel:SetText("编辑：" .. slot.name) end
                    if dragHint then dragHint:SetText("原连线已隐藏，请在角色区域点击最终连接点") end
                    return
                end
                if active and item and ShowItemTips then
                    local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                        and widget:GetAbsoluteLayoutForHitTest()
                        or nil
                    ShowItemTips(item, bounds, { source = "equipment" })
                    return
                end
                SetSelectedSlot(slot.id)
                SetSelectedInventoryId(item and item.id or nil)
                SetEquipmentScrollY(0)
                RequestPageRefresh()
            end,
            onLongPress = item and function(_, widget)
                if drawMode or not ShowItemTips then return end
                longPressConsumed = true
                local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                    and widget:GetAbsoluteLayoutForHitTest()
                    or nil
                ShowItemTips(item, bounds, { source = "equipment" })
            end or nil,
            children = {
                UI.Panel {
                    position = "absolute",
                    left = 20,
                    top = 14,
                    width = 72,
                    height = 72,
                    children = { ItemIcon(item, { width = 72, height = 72, opacity = item and 1.0 or 0.66 }, slotIcons[slot.id]) },
                },
                CompactTxt(slot.name, 15, active and C.focus or C.textSecondary, {
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
            slotWidget:AddChild(UI.Panel {
                position = "absolute",
                right = 3,
                top = 3,
                width = 34,
                height = 24,
                clickable = not readOnly,
                backgroundImage = ASSETS.ui.buttonRed,
                backgroundFit = "contain",
                onClick = function() UnequipSlot(slot.id) end,
                children = {
                    CompactTxt("卸", 12, C.text, { width = "100%", height = 24, textAlign = "center", textStroke = { width = 1, color = "#000000" } }),
                },
            })
            slotWidget:AddChild(CompactTxt("+" .. tostring(item.enhance or 0), 13, C.gold, {
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
        if item and RegisterItemTipsTrigger then
            RegisterItemTipsTrigger(slotWidget, item)
        end
        slotWidget:Animate {
            keyframes = {
                [0] = { translateY = 0, opacity = 0.94 },
                [0.5] = { translateY = -2, opacity = 1.0 },
                [1] = { translateY = 0, opacity = 0.94 },
            },
            duration = 1.8 + animationIndex * 0.07,
            easing = "easeInOut",
            loop = true,
        }
        return slotWidget
    end

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
    connectorWidgets = {}
    local slotWidgets = {}
    local slotDropTargets = {}
    for index, slot in ipairs(SLOTS) do
        local layout = slotLayout[index]
        connectorWidgets[#connectorWidgets + 1] = CreateRoutedConnector(
            layout,
            selectedSlot == slot.id,
            index
        )
        local slotWidget = CreateSlot(slot, layout.x, layout.y, index)
        slotWidgets[#slotWidgets + 1] = slotWidget
        slotDropTargets[#slotDropTargets + 1] = {
            slotId = slot.id,
            widget = slotWidget,
        }
    end

    connectorLayer = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = 860,
        height = 720,
        pointerEvents = "none",
        children = connectorWidgets,
    }
    local drawPreviewLayer = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = 860,
        height = 720,
        pointerEvents = "none",
    }
    local function ClearDrawPreview()
        if drawPreview then
            drawPreviewLayer:RemoveChild(drawPreview)
            drawPreview = nil
        end
    end

    local function GetPointerPoint(event)
        local layout = drawSurface:GetAbsoluteLayoutForHitTest()
        return {
            x = math.floor(event.x - layout.x + 0.5),
            y = math.floor(event.y - layout.y + 72.5),
        }
    end

    local function ConnectorStartPoint(layout)
        return {
            x = layout.startSide == "right" and (layout.x + 112) or layout.x,
            y = layout.y + 56,
        }
    end

    local function BuildAutomaticRoute(layout, target)
        local start = ConnectorStartPoint(layout)
        local isLeft = layout.startSide == "right"
        local laneX
        if isLeft then
            laneX = layout.x < 100 and 270 or 282
            laneX = math.min(laneX, target.x - 20)
            laneX = math.max(start.x + 12, laneX)
        else
            laneX = layout.x > 650 and 590 or 578
            laneX = math.max(laneX, target.x + 20)
            laneX = math.min(start.x - 12, laneX)
        end
        return {
            { x = laneX, y = start.y },
            { x = laneX, y = target.y },
        }
    end

    local function UpdateDrawPreview(cursorPoint)
        ClearDrawPreview()
        if not editorSelectedIndex or not cursorPoint then return end
        local source = slotLayout[editorSelectedIndex]
        local target = {
            x = math.max(286, math.min(574, cursorPoint.x)),
            y = math.max(86, math.min(596, cursorPoint.y)),
        }
        local previewLayout = {
            x = source.x,
            y = source.y,
            startSide = source.startSide,
            anchorX = target.x,
            anchorY = target.y,
            route = BuildAutomaticRoute(source, target),
        }
        drawPreview = CreateRoutedConnector(previewLayout, true, editorSelectedIndex)
        drawPreviewLayer:AddChild(drawPreview)
    end

    RefreshConnector = function(index)
        local oldConnector = connectorWidgets[index]
        if oldConnector then connectorLayer:RemoveChild(oldConnector) end
        local layout = slotLayout[index]
        local newConnector = CreateRoutedConnector(layout, editorSelectedIndex == index, index)
        connectorWidgets[index] = newConnector
        connectorLayer:AddChild(newConnector)
    end

    local function SetAutomaticEndpoint(point)
        if not drawMode or not editorSelectedIndex then
            if dragHint then dragHint:SetText("请先点击一个装备部位") end
            return
        end
        local target = {
            x = math.max(286, math.min(574, point.x)),
            y = math.max(86, math.min(596, point.y)),
        }
        local layout = slotLayout[editorSelectedIndex]
        layout.anchorX = target.x
        layout.anchorY = target.y
        layout.route = BuildAutomaticRoute(layout, target)
        ClearDrawPreview()
        RefreshConnector(editorSelectedIndex)
        if dragHint then dragHint:SetText("终点已保存；可再次点击微调，或选择其他部位") end
        UI.Toast.Show("已更新 " .. SLOTS[editorSelectedIndex].name .. " 连线", { duration = 1.2, variant = "success", position = "bottom" })
    end

    local function CopyLineEditorSettings()
        local lines = {
            "-- equipment line editor settings",
            "EQUIPMENT_LAYOUT = {",
        }
        for index, slot in ipairs(SLOTS) do
            local layout = slotLayout[index]
            local routeParts = {}
            for _, point in ipairs(layout.route or {}) do
                routeParts[#routeParts + 1] = string.format("{ x = %d, y = %d }", point.x, point.y)
            end
            lines[#lines + 1] = string.format(
                "    -- %s (%s)\n    { slotX = %d, slotY = %d, startSide = %q, anchorX = %d, anchorY = %d, route = { %s } },",
                slot.name,
                slot.id,
                layout.x,
                layout.y,
                layout.startSide,
                layout.anchorX,
                layout.anchorY,
                table.concat(routeParts, ", ")
            )
        end
        lines[#lines + 1] = "}"
        ui.useSystemClipboard = true
        ui:SetClipboardText(table.concat(lines, "\n"))
        UI.Toast.Show("已复制全部12部位连线参数，直接粘贴发给我即可", { duration = 2.2, variant = "success", position = "bottom" })
    end

    local function ToggleDrawMode()
        drawMode = not drawMode
        editorSelectedIndex = nil
        ClearDrawPreview()
        if drawMode then
            if drawModeLabel then drawModeLabel:SetText("退出编辑") end
            if editorSlotLabel then editorSlotLabel:SetText("选择部位") end
            if editorToolbar then editorToolbar:SetVisible(true) end
            if dragHint then dragHint:SetText("先点部位槽，再点击角色上的最终连接点；路线会自动生成") end
        else
            if drawModeLabel then drawModeLabel:SetText("编辑连线") end
            if editorSlotLabel then editorSlotLabel:SetText("") end
            if editorToolbar then editorToolbar:SetVisible(false) end
            if dragHint then dragHint:SetText("") end
        end
    end

    local function DropAtPointer(event)
        if not draggingItem then return end
        local x = event and event.x
        local y = event and event.y
        if x ~= nil and y ~= nil then
            for _, target in ipairs(slotDropTargets) do
                local widget = target.widget
                local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                    and widget:GetAbsoluteLayoutForHitTest()
                    or nil
                if bounds
                    and x >= bounds.x
                    and x <= bounds.x + bounds.w
                    and y >= bounds.y
                    and y <= bounds.y + bounds.h
                then
                    DropOnSlot(target.slotId)
                    return
                end
            end
        end
        draggingItem = nil
        if dragHint then dragHint:SetText("") end
    end

    local function CreateEquipmentCard(item)
        local active = selectedCandidate and selectedCandidate.id == item.id
        local TutorialController = require("client.TutorialController")
        local tutorialEquipStep = TutorialController.IsActive
            and TutorialController.IsActive()
            and TutorialController.GetStep
            and TutorialController.GetStep() == 2
        local card = EquipmentItemSlot.Build(slotContext, item, {
            -- 构造时写入 id，避免后写 props.id 导致引导层找不到。
            id = "tutorialCandidate:" .. tostring(item.id),
            active = active,
            clickable = true,
            detailText = "战力 " .. ItemPowerText(item),
            -- 序章穿戴：候选本体自带蓝色描边，不依赖覆盖层几何。
            tutorialHighlight = tutorialEquipStep == true,
            itemTips = tutorialEquipStep ~= true,
            onPointerDown = function()
                if tutorialEquipStep then return end
                StartDrag(item)
            end,
            onPointerUp = function(event)
                if tutorialEquipStep then return end
                DropAtPointer(event)
            end,
            onClick = function(widget)
                if tutorialEquipStep then
                    -- 主路径推进：选中候选后立刻进入“快捷穿戴”子步骤。
                    if TutorialController.NotifyAction then
                        TutorialController.NotifyAction("equip_select")
                    end
                    SetSelectedInventoryId(item.id)
                    RequestPageRefresh()
                    return
                end
                if active and ShowItemTips then
                    draggingItem = nil
                    if dragHint then dragHint:SetText("") end
                    local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                        and widget:GetAbsoluteLayoutForHitTest()
                        or nil
                    ShowItemTips(item, bounds, { source = "equipment" })
                    return
                end
                SetSelectedInventoryId(item.id)
                RequestPageRefresh()
            end,
            onLongPress = function(_, widget)
                if tutorialEquipStep then return end
                draggingItem = nil
                if dragHint then dragHint:SetText("") end
                if not ShowItemTips then return end
                local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                    and widget:GetAbsoluteLayoutForHitTest()
                    or nil
                ShowItemTips(item, bounds, { source = "equipment" })
            end,
        })
        return card
    end

    local cardChildren = {}
    for _, item in ipairs(filtered) do
        cardChildren[#cardChildren + 1] = CreateEquipmentCard(item)
    end
    if #cardChildren == 0 then
        cardChildren[1] = UI.Panel {
            width = "100%",
            height = 380,
            alignItems = "center",
            justifyContent = "center",
            gap = 12,
            children = {
                UI.Panel { width = 180, height = 180, backgroundImage = inventoryEmptyState, backgroundFit = "contain" },
                Txt("当前部位暂无可穿戴装备", 25, C.textSecondary, { width = "100%", height = 38, textAlign = "center", textStroke = { width = 1, color = "#000000" } }),
            },
        }
    end

    local equipmentListScrollView = UI.ScrollView {
        position = "absolute",
        left = 18,
        top = 58,
        width = 824,
        height = 438,
        scrollY = true,
        showScrollbar = false,
        onScroll = function(_, _, scrollY)
            SetEquipmentScrollY(scrollY)
        end,
        children = {
            UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", justifyContent = "center", gap = 10, padding = 8, children = cardChildren },
        },
    }
    equipmentListScrollView.state.scrollY = math.max(0, GetEquipmentScrollY() or 0)

    local detailChildren = {}
    if selectedCandidate then
        local TutorialController = require("client.TutorialController")
        local tutorialEquipStep = TutorialController.IsActive
            and TutorialController.IsActive()
            and TutorialController.GetStep
            and TutorialController.GetStep() == 2
        -- 快捷穿戴：构造时写 id + 教学蓝框；点击主动推进，不依赖几何命中。
        local equipNowButton = UI.Panel {
            id = "tutorialEquipNow",
            width = 170,
            height = 50,
            clickable = not readOnly,
            opacity = readOnly and 0.45 or 1.0,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = ASSETS.ui.buttonBlue,
            backgroundFit = "sliced",
            backgroundSlice = { 8, 8, 8, 8 },
            borderWidth = tutorialEquipStep and 5 or 0,
            borderColor = tutorialEquipStep and C.focus or nil,
            borderRadius = 10,
            boxShadow = tutorialEquipStep and {
                color = {
                    (C.focus and C.focus[1]) or 111,
                    (C.focus and C.focus[2]) or 231,
                    (C.focus and C.focus[3]) or 255,
                    180,
                },
                offsetX = 0, offsetY = 0, blurRadius = 18,
            } or nil,
            onClick = function()
                if readOnly then return end
                if TutorialController.NotifyAction then
                    TutorialController.NotifyAction("equip_now")
                end
                EquipItem(selectedCandidate)
            end,
            children = {
                CompactTxt("快捷穿戴", 20, C.text, {
                    width = "100%",
                    height = 50,
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        }
        detailChildren = {
                UI.Panel { width = 64, height = 64, children = { ItemIcon(selectedCandidate, { width = 64, height = 64 }) }, flexShrink = 0 },
            UI.Panel {
                flexGrow = 1,
                flexBasis = 0,
                height = 64,
                justifyContent = "center",
                children = {
                    CompactTxt(ShortenText(selectedCandidate.name, 14), 21, RarityColor(selectedCandidate.rarity), { width = "100%", height = 28, textStroke = { width = 1, color = "#000000" } }),
                    CompactTxt(RarityName(selectedCandidate.rarity) .. " · " .. SlotName(selectedCandidate.slot), 17, C.textSecondary, { width = "100%", height = 24, textStroke = { width = 1, color = "#000000" } }),
                },
            },
            equipNowButton,
        }
    else
        detailChildren[1] = CompactTxt("点击装备卡选择装备", 20, C.textDim, { width = "100%", height = 30, textAlign = "center" })
    end

    local equippedForSelectedSlot = game.equipped and game.equipped[selectedSlot]
    local TutorialController = require("client.TutorialController")
    local tutorialStrengthenStep = TutorialController.IsActive
        and TutorialController.IsActive()
        and TutorialController.GetStep
        and TutorialController.GetStep() == 4
    -- 强化按钮：构造时写入 id + 教学蓝框；点击时主动推进引导，不依赖几何命中。
    local strengthenDisabled = readOnly or not equippedForSelectedSlot
    local strengthenButton = UI.Panel {
        id = "tutorialStrengthen",
        width = 190,
        height = 50,
        clickable = not strengthenDisabled,
        opacity = strengthenDisabled and 0.45 or 1.0,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = ASSETS.ui.buttonBlueWide,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        borderWidth = tutorialStrengthenStep and 5 or 0,
        borderColor = tutorialStrengthenStep and C.focus or nil,
        borderRadius = 10,
        boxShadow = tutorialStrengthenStep and {
            color = {
                (C.focus and C.focus[1]) or 111,
                (C.focus and C.focus[2]) or 231,
                (C.focus and C.focus[3]) or 255,
                180,
            },
            offsetX = 0, offsetY = 0, blurRadius = 18,
        } or nil,
        onClick = function()
            if strengthenDisabled then return end
            if TutorialController.NotifyAction then
                TutorialController.NotifyAction("strengthen_open")
            end
            if equippedForSelectedSlot then StrengthenSelected() end
        end,
        children = {
            CompactTxt("强化", 20, C.text, {
                width = "100%",
                height = 50,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
        },
    }
    local autoEquipButton = ImageButton(
        "一键穿戴",
        190,
        50,
        ASSETS.ui.buttonGreen or ASSETS.ui.buttonBlueWide,
        function()
            if readOnly then return end
            if AutoEquipBest then AutoEquipBest() end
        end,
        readOnly
    )
    local upgradeActionBar = UI.Panel {
        width = 900,
        height = 82,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "center",
        gap = 12,
        backgroundImage = ASSETS.ui.infoBarGold,
        backgroundFit = "sliced",
        backgroundSlice = { 10, 10, 10, 10 },
        children = {
            autoEquipButton,
            strengthenButton,
            ImageButton("升星", 170, 50, ASSETS.ui.buttonPurple, function()
                if equippedForSelectedSlot then StarSelected() end
            end, readOnly or not equippedForSelectedSlot),
            ImageButton("卸下", 170, 50, ASSETS.ui.buttonRed, function()
                if equippedForSelectedSlot then UnequipSlot(selectedSlot) end
            end, readOnly or not equippedForSelectedSlot),
        },
    }

    local topArea = UI.Panel {
        width = 860,
        height = 720,
        flexShrink = 0,
        position = "relative",
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        children = {
            Txt(playerNickname, 27, C.text, { position = "absolute", left = 280, top = 20, width = 300, height = 36, textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
            UI.Panel { position = "absolute", left = 292, top = 98, width = 276, height = 430, backgroundImage = characterPortrait, backgroundFit = "contain", pointerEvents = "none", opacity = 0.98 },
            UI.Panel { position = "absolute", left = 278, top = 84, width = 304, height = 458, borderWidth = 2, borderColor = { 50, 196, 255, 120 }, backgroundColor = { 12, 42, 82, 55 }, pointerEvents = "none" },
            CompactTxt("当前节点：" .. SlotName(selectedSlot), 19, C.focus, { position = "absolute", left = 280, top = 616, width = 300, height = 26, textAlign = "center", textStroke = { width = 1, color = "#000000" } }),
        },
    }
    dragHint = CompactTxt("", 17, C.focus, { position = "absolute", left = 180, top = 660, width = 500, height = 24, textAlign = "center", textStroke = { width = 1, color = "#000000" }, pointerEvents = "none" })
    drawSurface = UI.Panel {
        position = "absolute",
        left = 0,
        top = 72,
        width = 860,
        height = 574,
        pointerEvents = "box-only",
        cursor = "crosshair",
        backgroundColor = { 0, 0, 0, 0 },
        onPointerMove = function(event, widget)
            if drawMode and editorSelectedIndex then
                UpdateDrawPreview(GetPointerPoint(event))
            end
        end,
        onPointerUp = function(event)
            if drawMode then SetAutomaticEndpoint(GetPointerPoint(event)) end
        end,
    }
    local drawButton = UI.Panel {
        position = "absolute",
        left = 682,
        top = 18,
        width = 148,
        height = 42,
        clickable = true,
        cursor = "crosshair",
        backgroundImage = ASSETS.ui.buttonBlue,
        backgroundFit = "contain",
        onClick = ToggleDrawMode,
        children = {
            CompactTxt("编辑连线", 16, C.text, {
                width = "100%",
                height = 42,
                textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
            }),
        },
    }
    drawModeLabel = drawButton.children[1]
    editorSlotLabel = CompactTxt("", 16, C.focus, {
        position = "absolute",
        left = 18,
        top = 20,
        width = 150,
        height = 38,
        textAlign = "center",
        textStroke = { width = 1, color = "#000000" },
        pointerEvents = "none",
    })
    editorToolbar = UI.Panel {
        position = "absolute",
        left = 246,
        top = 16,
        width = 356,
        height = 46,
        visible = false,
        flexDirection = "row",
        justifyContent = "center",
        gap = 10,
        children = {
            ImageButton("重新选择", 150, 42, ASSETS.ui.buttonPurple, function()
                if not editorSelectedIndex then return end
                local oldConnector = connectorWidgets[editorSelectedIndex]
                if oldConnector then
                    connectorLayer:RemoveChild(oldConnector)
                    connectorWidgets[editorSelectedIndex] = nil
                end
                ClearDrawPreview()
                if dragHint then dragHint:SetText("原连线已隐藏，请点击新的最终连接点") end
            end, false),
            ImageButton("复制参数", 150, 42, ASSETS.ui.buttonBlue, CopyLineEditorSettings, false),
        },
    }
    topArea:AddChild(dragHint)
    topArea:AddChild(connectorLayer)
    for _, slotWidget in ipairs(slotWidgets) do topArea:AddChild(slotWidget) end

    local equipmentPageScrollView = UI.ScrollView {
        width = "100%",
        height = "100%",
        scrollY = true,
        showScrollbar = false,
        onScroll = function(_, _, scrollY)
            SetEquipmentPageScrollY(scrollY)
        end,
        children = {
            UI.Panel {
                width = "100%",
                padding = 24,
                gap = 18,
                alignItems = "center",
                children = {
                    topArea,
                    UI.Panel {
                        width = 900,
                        height = 86,
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 16,
                        paddingLeft = 20,
                        paddingRight = 20,
                        backgroundImage = ASSETS.ui.infoBarBlue,
                        backgroundFit = "sliced",
                        backgroundSlice = { 10, 10, 10, 10 },
                        children = detailChildren,
                    },
                    upgradeActionBar,
                    UI.Panel {
                        width = 860,
                        height = 520,
                        flexShrink = 0,
                        backgroundImage = ASSETS.ui.panelCompact,
                        backgroundFit = "sliced",
                        backgroundSlice = { 12, 12, 12, 12 },
                        children = {
                            Txt("可穿戴装备", 25, C.text, { position = "absolute", left = 22, top = 16, width = 260, height = 34, textStroke = { width = 2, color = "#000000" } }),
                            UI.Panel {
                                position = "absolute",
                                right = 22,
                                top = 10,
                                width = 150,
                                height = 48,
                                clickable = true,
                                backgroundImage = ASSETS.ui.inventoryActionGold,
                                backgroundFit = "contain",
                                onClick = function()
                                    EquipmentQuickFilter.Show("equip", { onApplied = RequestPageRefresh })
                                end,
                                children = {
                                    CompactTxt("快速筛选", 18, C.text, {
                                        width = "100%",
                                        height = 48,
                                        textAlign = "center",
                                        textStroke = { width = 1, color = "#000000" },
                                        pointerEvents = "none",
                                    }),
                                },
                            },
                            equipmentListScrollView,
                        },
                    },
                },
            },
        },
    }
    equipmentPageScrollView.state.scrollY = math.max(0, GetEquipmentPageScrollY() or 0)
    return equipmentPageScrollView
end

return EquipmentLoadoutView
