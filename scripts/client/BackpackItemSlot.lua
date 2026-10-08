local UI = require("urhox-libs/UI")
local ItemSlotBase = require("client.ItemSlotBase")

local BackpackItemSlot = {}

local LOCK_BADGE = "image/ui/inventory/equipment_lock_badge.png"

local function SlotOptions(options)
    return {
        size = options.slotSize,
        selected = options.selected == true,
        fallbackImage = options.fallbackImage,
        showLevel = options.showLevel,
        showEnhance = options.showEnhance,
        showStars = options.showStars,
        showEquipped = options.showEquipped,
        showLock = not options.showLockButton,
        opacity = options.opacity,
    }
end

local function AmountText(item, options)
    if options.amountText then return options.amountText end
    if (item.quantity or 1) > 1 or item.category == "wishjar" then
        return "x" .. tostring(item.quantity or 1)
    end
    return nil
end

function BackpackItemSlot.Build(context, item, options)
    options = options or {}
    local cardSize = options.width or 180
    local cardHeight = options.height or cardSize
    local slotSize = math.floor(cardSize * 0.81)
    local slotX = math.floor((cardSize - slotSize) * 0.5)
    local nameTop = math.min(cardHeight - 32, math.floor(cardSize * 0.82))
    options.slotSize = slotSize
    local slotHost = UI.Panel {
        position = "absolute", left = slotX, top = 5,
        width = slotSize, height = slotSize,
        children = {
            ItemSlotBase.Build(context, item, SlotOptions(options)),
        },
    }
    local nameLabel = context.compactTxt(context.shortenText(item.name or "未知装备", 8), 14, context.rarityColor(item.rarity), {
        position = "absolute", left = 8, top = nameTop,
        width = cardSize - 16, height = 28, textAlign = "center",
        textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
    })
    local children = { slotHost, nameLabel }
    local lockBadge = nil
    local boundHolder = { item = item }
    if options.showLockButton and context.setEquipmentLock and item.locked then
        lockBadge = UI.Panel {
            position = "absolute",
            left = slotX + math.floor((slotSize - 58) * 0.5),
            top = 5 + math.floor((slotSize - 58) * 0.5),
            width = 58,
            height = 58,
            clickable = true,
            backgroundImage = LOCK_BADGE,
            backgroundFit = "contain",
            onClick = function(_, event)
                if event and event.StopPropagation then event:StopPropagation() end
                context.setEquipmentLock(boundHolder.item)
            end,
        }
        children[#children + 1] = lockBadge
    end
    local amountLabel = nil
    local amountText = AmountText(item, options)
    if amountText then
        amountLabel = context.compactTxt(amountText, 16, context.C.text, {
            position = "absolute",
            left = slotX + 8,
            top = 5 + slotSize - 30,
            width = slotSize - 16,
            height = 26,
            textAlign = "right",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        })
        children[#children + 1] = amountLabel
    end
    local longPressConsumed = false
    local onLongPress = options.onLongPress
    if not onLongPress and context.showItemTips then
        onLongPress = function(_, host)
            local bound = host and host._boundItem or item
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
    widget._slotContext = context
    widget._slotOptions = options
    widget._boundItem = item
    widget._boundHolder = boundHolder
    widget._slotHost = slotHost
    widget._nameLabel = nameLabel
    widget._lockBadge = lockBadge
    widget._amountLabel = amountLabel
    widget._slotX = slotX
    widget._slotSize = slotSize
    widget._nameTop = nameTop
    widget._cardSize = cardSize

    function widget:Rebind(nextItem, nextOptions)
        if not nextItem then return self end
        local ctx = self._slotContext
        local merged = {}
        for key, value in pairs(self._slotOptions or {}) do merged[key] = value end
        if nextOptions then
            for key, value in pairs(nextOptions) do merged[key] = value end
        end
        merged.slotSize = self._slotSize
        self._boundItem = nextItem
        self._slotOptions = merged
        if self._boundHolder then self._boundHolder.item = nextItem end
        if self._slotHost then
            self._slotHost:ClearChildren()
            local inner = ItemSlotBase.Build(ctx, nextItem, SlotOptions(merged))
            if inner then self._slotHost:AddChild(inner) end
        end
        if self._nameLabel and self._nameLabel.SetText then
            self._nameLabel:SetText(ctx.shortenText(nextItem.name or "未知装备", 8))
            self._nameLabel:SetStyle({ fontColor = ctx.rarityColor(nextItem.rarity) })
        end
        local wantLock = merged.showLockButton and ctx.setEquipmentLock and nextItem.locked
        if wantLock and not self._lockBadge then
            self._lockBadge = UI.Panel {
                position = "absolute",
                left = self._slotX + math.floor((self._slotSize - 58) * 0.5),
                top = 5 + math.floor((self._slotSize - 58) * 0.5),
                width = 58,
                height = 58,
                clickable = true,
                backgroundImage = LOCK_BADGE,
                backgroundFit = "contain",
                onClick = function(_, event)
                    if event and event.StopPropagation then event:StopPropagation() end
                    ctx.setEquipmentLock(self._boundItem)
                end,
            }
            self:AddChild(self._lockBadge)
        elseif wantLock and self._lockBadge then
            self._lockBadge:SetStyle({ visible = true })
        elseif self._lockBadge then
            self:RemoveChild(self._lockBadge)
            if self._lockBadge.Destroy then self._lockBadge:Destroy() end
            self._lockBadge = nil
        end
        local amount = AmountText(nextItem, merged)
        if amount then
            if self._amountLabel and self._amountLabel.SetText then
                self._amountLabel:SetText(amount)
                self._amountLabel:SetStyle({ visible = true })
            else
                self._amountLabel = ctx.compactTxt(amount, 16, ctx.C.text, {
                    position = "absolute",
                    left = self._slotX + 8,
                    top = 5 + self._slotSize - 30,
                    width = self._slotSize - 16,
                    height = 26,
                    textAlign = "right",
                    textStroke = { width = 2, color = "#000000" },
                    pointerEvents = "none",
                })
                self:AddChild(self._amountLabel)
            end
        elseif self._amountLabel then
            self:RemoveChild(self._amountLabel)
            if self._amountLabel.Destroy then self._amountLabel:Destroy() end
            self._amountLabel = nil
        end
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

return BackpackItemSlot
