local BackpackItemSlot = require("client.BackpackItemSlot")

local InventoryGridView = {}

local COLUMN_COUNT = 5
local CARD_SIZE = 180
local CARD_GAP = 14
local ROW_HEIGHT = 180
local ROW_PITCH = 194
local ROW_WIDTH = COLUMN_COUNT * CARD_SIZE + (COLUMN_COUNT - 1) * CARD_GAP

local function BuildRows(items)
    local rows = {}
    for first = 1, #items, COLUMN_COUNT do
        local rowItems = {}
        for index = first, math.min(first + COLUMN_COUNT - 1, #items) do
            rowItems[#rowItems + 1] = items[index]
        end
        rows[#rows + 1] = rowItems
    end
    return rows
end

-- 与 VirtualList:CalculateVisibleRange 相同的视口高度取值链
local function EffectiveViewportHeight(list)
    local props = list.props
    local layout = list:GetLayout()
    if layout.h > 0 then return layout.h end
    if type(props.height) == "number" then return props.height end
    if props.viewportHeight and type(props.viewportHeight) == "number" then
        return props.viewportHeight
    end
    return 400
end

local function BuildCard(context, row, slotIndex, item)
    if not item then return nil end
    return BackpackItemSlot.Build(context, item, {
        width = CARD_SIZE,
        height = CARD_SIZE,
        selected = context.getSelectedInventoryId() == item.id,
        clickable = true,
        showLockButton = item.equipmentId ~= nil,
        amountText = ((item.quantity or 1) > 1 or item.category == "wishjar")
            and ("x" .. tostring(item.quantity or 1)) or nil,
        onClick = function(widget)
            -- Read through the row binding on click. A recycled row must never
            -- retain the item table from an earlier bind.
            local currentItem = row._boundItems[slotIndex]
            if not currentItem then return end
            local selectedId = context.getSelectedInventoryId()
            if selectedId == currentItem.id and context.showItemTips then
                local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                    and widget:GetAbsoluteLayoutForHitTest()
                    or nil
                context.showItemTips(currentItem, bounds, { source = "inventory" })
                return
            end
            context.setSelectedInventoryId(currentItem.id)
            context.requestPageRefresh()
        end,
    })
end

local function CreateRow(context)
    local UI = context.UI
    local row = UI.Panel {
        width = ROW_WIDTH,
        height = ROW_HEIGHT,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "flex-start",
        gap = CARD_GAP,
        alignSelf = "center",
        overflow = "visible",
    }
    row._boundItems = {}
    row._context = context
    row._cards = {}
    -- Keep a fixed five-slot row object; bind reuses cards via Rebind.
    for slotIndex = 1, COLUMN_COUNT do
        row._cards[slotIndex] = nil
    end
    return row
end

local function BindRow(row, rowItems)
    row._boundItems = rowItems or {}
    for slotIndex = 1, COLUMN_COUNT do
        local oldCard = row._cards[slotIndex]
        local item = row._boundItems[slotIndex]
        if oldCard and item and oldCard.Rebind then
            local rebound = oldCard:Rebind(item, {
                selected = row._context.getSelectedInventoryId() == item.id,
                showLockButton = item.equipmentId ~= nil,
                amountText = ((item.quantity or 1) > 1 or item.category == "wishjar")
                    and ("x" .. tostring(item.quantity or 1)) or nil,
            })
            row._cards[slotIndex] = rebound or oldCard
        elseif oldCard and not item then
            row:RemoveChild(oldCard)
            oldCard:Destroy()
            row._cards[slotIndex] = nil
        elseif item then
            if oldCard then
                row:RemoveChild(oldCard)
                oldCard:Destroy()
                row._cards[slotIndex] = nil
            end
            local card = BuildCard(row._context, row, slotIndex, item)
            if card then
                row._cards[slotIndex] = card
                row:AddChild(card)
            end
        end
    end
end

function InventoryGridView.Build(context, items)
    local UI = context.UI
    local rows = BuildRows(items or {})
    local initialScrollY = math.max(0, tonumber(context.getInventoryGridScrollY()) or 0)
    local virtualList = UI.VirtualList {
        width = "100%",
        height = "100%",
        flexGrow = 1,
        flexBasis = 0,
        viewportHeight = 500,
        data = rows,
        itemHeight = ROW_HEIGHT,
        itemGap = ROW_PITCH - ROW_HEIGHT,
        poolBuffer = 2,
        showScrollbar = false,
        bounces = false,
        createItem = function() return CreateRow(context) end,
        bindItem = BindRow,
    }

    -- VirtualList exposes the underlying ScrollView for the actual scroll state.
    -- Restore after construction because the initial pool may be created before
    -- Yoga has calculated the final viewport layout.
    virtualList.scrollOffset_ = initialScrollY
    virtualList.scrollView_:SetScrollDirect(0, initialScrollY)
    virtualList:UpdateVisibleItems()
    local previousOnScroll = virtualList.scrollView_.props.onScroll
    virtualList.scrollView_.props.onScroll = function(scrollView, scrollX, scrollY)
        context.setInventoryGridScrollY(scrollY)
        if previousOnScroll then previousOnScroll(scrollView, scrollX, scrollY) end
    end

    return virtualList
end

--- 数据更新：保留当前滚动位置，只刷新当前显示区域的数据显示。
--- 与 Build（重建）不同，UpdateData 不创建新列表、不重置滚动位置，
--- 数据变化只重绘可见行，玩家正在查看的位置与滚动操作完全不受影响。
---@param list VirtualList Build 返回的列表实例
---@param items table 新的数据数组
function InventoryGridView.UpdateData(list, items)
    if not list or not list.scrollView_ or not list.contentContainer_ then return nil end
    local rows = BuildRows(items or {})

    -- 更新前已在显示区域的行：数据刷新后只需重绑这些行（新进入的行由 UpdateVisibleItems 绑定）
    local oldVisible = {}
    for idx in pairs(list.pool_.inUse) do oldVisible[idx] = true end

    -- 1. 替换数据源（数据更新与表现解耦：此处不触碰滚动/布局状态）
    local listProps = list.props
    listProps.data = rows

    -- 2. 内容高度跟随数据量变化
    local totalHeight = #rows * list.rowHeight_
    list.contentContainer_:SetStyle({ height = totalHeight })

    -- 3. 滚动位置保持不动；只有数据变短、当前停留超出新范围时才收敛
    local viewportHeight = EffectiveViewportHeight(list)
    local maxScroll = math.max(0, totalHeight - viewportHeight)
    local currentScroll = list.scrollOffset_ or 0
    if currentScroll > maxScroll then currentScroll = maxScroll elseif currentScroll < 0 then currentScroll = 0 end
    list.scrollOffset_ = currentScroll
    list.scrollView_:SetScrollDirect(0, currentScroll)

    -- 4. 重算可见范围（增量）：放回离开视口的行、补绑进入视口的行
    list.visibleRange_ = { first = -1, last = -1 }
    list:UpdateVisibleItems()

    -- 5. 只刷新当前显示区域：重绑“数据刷新前就可见”的行（内容可能变化）
    for idx, widget in pairs(list.pool_.inUse) do
        if oldVisible[idx] and listProps.data[idx] then
            listProps.bindItem(widget, listProps.data[idx], idx)
        end
    end

    return list
end

function InventoryGridView.GetMetrics()
    return {
        columns = COLUMN_COUNT,
        cardSize = CARD_SIZE,
        gap = CARD_GAP,
        rowHeight = ROW_PITCH,
    }
end

return InventoryGridView
