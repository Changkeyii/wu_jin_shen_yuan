-- GridVirtualList.lua
-- 通用虚拟网格：把一维 items 按固定列数分组成“行”，交给 UI.VirtualList 池化渲染。
-- 每个池化行对象固定尺寸，bind 时只重建行内卡片子树，行本身复用。
-- 用于背包、装备候选、分解候选、邮件、排行榜、市场等可能展示大量格子的弹窗/页面。
--
-- 数据更新与表现解耦（重要）：
--   * 数据刷新请走 UpdateData，它只替换数据源并重绘当前显示区域，
--     滚动位置、玩家正在进行的滚动/查看操作完全不受影响；
--   * 不要在数据刷新时重建列表（重新 Build），重建必然丢失滚动位置、造成跳顶突变。

local UI = require("urhox-libs/UI")

local GridVirtualList = {}

local function BuildRows(items, columns)
    local rows = {}
    for first = 1, #items, columns do
        local rowItems = {}
        for index = first, math.min(first + columns - 1, #items) do
            rowItems[#rowItems + 1] = items[index]
        end
        rows[#rows + 1] = rowItems
    end
    return rows
end

-- 与 VirtualList:CalculateVisibleRange 相同的视口高度取值链，
-- 供滚动位置 clamp / 首屏恢复共用。
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

local function CreateRow(columns, cardWidth, cardHeight, cardGap)
    local rowWidth = columns * cardWidth + (columns - 1) * cardGap
    local row = UI.Panel {
        width = rowWidth,
        height = cardHeight,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "flex-start",
        gap = cardGap,
        alignSelf = "center",
        overflow = "visible",
    }
    row._boundItems = {}
    row._cards = {}
    return row
end

local function BindRow(row, rowItems, columns, createCard)
    row._boundItems = rowItems or {}
    for slotIndex = 1, columns do
        local oldCard = row._cards[slotIndex]
        if oldCard then
            row:RemoveChild(oldCard)
            oldCard:Destroy()
            row._cards[slotIndex] = nil
        end
        local card = createCard(row, slotIndex, row._boundItems[slotIndex])
        if card then
            row._cards[slotIndex] = card
            row:AddChild(card)
        end
    end
    -- 清理超出新列数的残留卡片（数据更新时列数变化不会留下脏卡）
    for slotIndex = columns + 1, #row._cards do
        local stale = row._cards[slotIndex]
        if stale then
            row:RemoveChild(stale)
            stale:Destroy()
            row._cards[slotIndex] = nil
        end
    end
end

--- 通用虚拟网格构建。
---@param opts table 见调用处注释：columns/cardWidth/cardHeight/cardGap/rowGap/data/viewportHeight/createCard/emptyState/widgetProps/getScrollY/setScrollY
function GridVirtualList.Build(opts)
    local columns = math.max(1, math.floor(opts.columns or 1))
    local cardWidth = opts.cardWidth or 180
    local cardHeight = opts.cardHeight or 180
    local cardGap = opts.cardGap or 0
    local rowGap = opts.rowGap or cardGap

    local items = opts.data or {}
    local rows = BuildRows(items, columns)
    if #rows == 0 and opts.emptyState then
        return opts.emptyState()
    end

    local function createCard(row, slotIndex, item)
        return opts.createCard(row, slotIndex, item)
    end

    local props = {}
    for key, value in pairs(opts.widgetProps or {}) do props[key] = value end
    props.data = rows
    props.itemHeight = cardHeight
    props.itemGap = rowGap
    props.viewportHeight = opts.viewportHeight or 500
    props.poolBuffer = opts.poolBuffer or 2
    props.showScrollbar = opts.showScrollbar ~= false
    props.bounces = opts.bounces == true
    props.createItem = function()
        return CreateRow(columns, cardWidth, cardHeight, cardGap)
    end
    props.bindItem = function(row, rowItems)
        BindRow(row, rowItems, columns, createCard)
    end

    local list = UI.VirtualList(props)

    local getScroll = opts.getScrollY
    local setScroll = opts.setScrollY
    if getScroll and setScroll then
        -- 首屏恢复：clamp 到新数据实际可滚范围，避免记忆位置越界导致空白/跳顶
        local viewportHeight = EffectiveViewportHeight(list)
        local maxScroll = math.max(0, #list.props.data * list.rowHeight_ - viewportHeight)
        local initialScroll = math.max(0, math.min(tonumber(getScroll()) or 0, maxScroll))
        list.scrollOffset_ = initialScroll
        list.visibleRange_ = { first = -1, last = -1 }
        list.scrollView_:SetScrollDirect(0, initialScroll)
        list:UpdateVisibleItems()
        local previousOnScroll = list.scrollView_.props.onScroll
        list.scrollView_.props.onScroll = function(scrollView, scrollX, scrollY)
            setScroll(scrollY)
            if previousOnScroll then previousOnScroll(scrollView, scrollX, scrollY) end
        end
    end

    return list
end

--- 数据更新：保留当前滚动位置，只刷新当前显示区域的数据显示。
--- 与重建（Build）不同，UpdateData 不创建新列表、不重置滚动位置：
---   1. 只替换数据源（props.data），不触碰任何表现状态；
---   2. 内容高度跟随数据量伸缩；
---   3. 滚动位置保持不动，仅当数据变短、当前停留超出新范围时才收敛；
---   4. 增量重算可见范围：放回离开视口的行、补绑进入视口的行；
---   5. 只重绘“数据刷新前就在可见区”的行（内容可能变化）。
--- 玩家正在查看的位置、滚动操作完全不受影响，数据与表现解耦。
---@param list VirtualList Build 返回的列表实例（空状态时传 nil 直接忽略）
---@param items table 新的数据数组
---@param opts table 至少需要 columns（与 Build 一致）
function GridVirtualList.UpdateData(list, items, opts)
    if not list or not list.scrollView_ or not list.contentContainer_ then return nil end
    opts = opts or {}
    local columns = math.max(1, math.floor(opts.columns or 1))
    local rows = BuildRows(items or {}, columns)

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

--- 兼容入口：等价于 UpdateData。
--- 旧实现会先“跳顶再拉回”（内部 list:SetData 会 SetScroll(0,0) + 全量释放），
--- 且无 clamp、非增量。数据刷新一律走 UpdateData。
function GridVirtualList.SetData(list, items, opts)
    return GridVirtualList.UpdateData(list, items, opts)
end

return GridVirtualList
