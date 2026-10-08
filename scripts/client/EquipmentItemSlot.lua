local UI = require("urhox-libs/UI")
local ItemSlotBase = require("client.ItemSlotBase")

local EquipmentItemSlot = {}

local function SlotOptions(options)
    return {
        size = options.slotSize or 128,
        selected = options.active == true,
        fallbackImage = options.fallbackImage,
        showLevel = options.showLevel,
        showEnhance = options.showEnhance,
        showStars = options.showStars,
        showEquipped = options.showEquipped,
    }
end

local function CardStyle(context, item, options)
    local active = options.active == true
    local tutorialHighlight = options.tutorialHighlight == true
    return {
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
    }
end

function EquipmentItemSlot.Build(context, item, options)
    options = options or {}
    local width = options.width or 180
    local height = options.height or 182
    local slotSize = options.slotSize or 128
    local slotLeft = math.floor((width - slotSize) * 0.5)
    local slotHost = UI.Panel {
        position = "absolute", left = slotLeft, top = 7,
        width = slotSize, height = slotSize,
        children = {
            ItemSlotBase.Build(context, item, SlotOptions(options)),
        },
    }
    local nameLabel = context.compactTxt(context.shortenText(item.name or "未知装备", 8), 15, context.rarityColor(item.rarity), {
        position = "absolute", left = 8, top = 133,
        width = width - 16, height = 27, textAlign = "center",
        textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
    })
    local children = { slotHost, nameLabel }
    local detailLabel = nil
    local detailText = options.detailText
    if detailText then
        detailLabel = context.compactTxt(detailText, 15, context.C.gold, {
            position = "absolute", left = 10, top = 158,
            width = width - 20, height = 19, textAlign = "center",
            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
        })
        children[#children + 1] = detailLabel
    end
    local boundHolder = { item = item }
    local longPressConsumed = false
    local onLongPress = options.onLongPress
    if not onLongPress and context.showItemTips then
        onLongPress = function(_, host)
            local bound = host and host._boundItem or boundHolder.item
            local bounds = host and host.GetAbsoluteLayoutForHitTest
                and host:GetAbsoluteLayoutForHitTest()
                or nil
            context.showItemTips(bound, bounds)
        end
    end
    local function HandleLongPress(event, host)
        longPressConsumed = true
        if onLongPress then onLongPress(event, host) end
    end
    local function HandleClick(host, event)
        if longPressConsumed then
            longPressConsumed = false
            return
        end
        local click = host._slotOptions and host._slotOptions.onClick
        if click then click(host, event) end
    end
    local style = CardStyle(context, item, options)
    local widget = UI.Panel {
        id = options.id,
        width = width,
        height = height,
        flexShrink = 0,
        clickable = options.clickable == true,
        position = "relative",
        backgroundImage = style.backgroundImage,
        backgroundFit = style.backgroundFit,
        borderWidth = style.borderWidth,
        borderColor = style.borderColor,
        boxShadow = style.boxShadow,
        onPointerDown = options.onPointerDown,
        onPointerUp = options.onPointerUp,
        onClick = HandleClick,
        onLongPress = onLongPress and HandleLongPress or nil,
        onLongPressStart = options.onLongPressStart,
        onLongPressEnd = options.onLongPressEnd,
        children = children,
    }
    widget._slotContext = context
    widget._slotOptions = options
    widget._boundItem = item
    widget._boundHolder = boundHolder
    widget._slotHost = slotHost
    widget._nameLabel = nameLabel
    widget._detailLabel = detailLabel
    widget._width = width

    function widget:Rebind(nextItem, nextOptions)
        if not nextItem then return self end
        local ctx = self._slotContext
        local merged = {}
        for key, value in pairs(self._slotOptions or {}) do merged[key] = value end
        if nextOptions then
            for key, value in pairs(nextOptions) do merged[key] = value end
        end
        self._boundItem = nextItem
        self._slotOptions = merged
        if self._boundHolder then self._boundHolder.item = nextItem end
        if merged.id then self.props.id = merged.id end
        if self._slotHost then
            self._slotHost:ClearChildren()
            local inner = ItemSlotBase.Build(ctx, nextItem, SlotOptions(merged))
            if inner then self._slotHost:AddChild(inner) end
        end
        if self._nameLabel and self._nameLabel.SetText then
            self._nameLabel:SetText(ctx.shortenText(nextItem.name or "未知装备", 8))
            self._nameLabel:SetStyle({ fontColor = ctx.rarityColor(nextItem.rarity) })
        end
        local nextDetail = merged.detailText
        if nextDetail then
            if self._detailLabel and self._detailLabel.SetText then
                self._detailLabel:SetText(nextDetail)
                self._detailLabel:SetStyle({ visible = true })
            else
                self._detailLabel = ctx.compactTxt(nextDetail, 15, ctx.C.gold, {
                    position = "absolute", left = 10, top = 158,
                    width = (self._width or 180) - 20, height = 19, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                })
                self:AddChild(self._detailLabel)
            end
        elseif self._detailLabel then
            self:RemoveChild(self._detailLabel)
            if self._detailLabel.Destroy then self._detailLabel:Destroy() end
            self._detailLabel = nil
        end
        self:SetStyle(CardStyle(ctx, nextItem, merged))
        if ctx.registerItemTipsTrigger and merged.itemTips ~= false then
            ctx.registerItemTipsTrigger(self, nextItem)
        end
        return self
    end
    if context.registerItemTipsTrigger and options.itemTips ~= false then
        context.registerItemTipsTrigger(widget, item)
    end
    return widget
end

return EquipmentItemSlot
