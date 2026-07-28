local UI = require("urhox-libs/UI")

local HorizontalArrowScroller = {}

function HorizontalArrowScroller.Build(options)
    options = options or {}
    local width = options.width or 720
    local height = options.height or 400
    local arrowWidth = options.arrowWidth or 42
    local viewportWidth = width - arrowWidth * 2
    local rowCount = math.max(1, options.rows or 2)
    local gapX = options.gapX or 12
    local gapY = options.gapY or 10
    local itemWidth = options.itemWidth or 164
    local itemHeight = options.itemHeight or 188
    local children = options.children or {}
    local padding = options.padding or 6
    local columnsPerPage = math.max(1, options.columnsPerPage
        or math.floor((viewportWidth - padding * 2 + gapX) / (itemWidth + gapX)))
    local itemsPerPage = columnsPerPage * rowCount
    local totalPages = math.max(1, math.ceil(#children / itemsPerPage))
    local pageWidth = viewportWidth
    local contentWidth = pageWidth * totalPages
    local contentChildren = {}
    for index, child in ipairs(children) do
        local zeroIndex = index - 1
        local page = math.floor(zeroIndex / itemsPerPage)
        local withinPage = zeroIndex % itemsPerPage
        local row = math.floor(withinPage / columnsPerPage)
        local column = withinPage % columnsPerPage
        local pageItemCount = math.min(itemsPerPage, #children - page * itemsPerPage)
        local rowItemCount = math.min(columnsPerPage, pageItemCount - row * columnsPerPage)
        local rowWidth = rowItemCount * itemWidth + math.max(0, rowItemCount - 1) * gapX
        local rowInset = math.max(padding, math.floor((pageWidth - rowWidth) * 0.5))
        contentChildren[#contentChildren + 1] = UI.Panel {
            position = "absolute",
            left = page * pageWidth + rowInset + column * (itemWidth + gapX),
            top = padding + row * (itemHeight + gapY),
            width = itemWidth,
            height = itemHeight,
            children = { child },
        }
    end
    local currentPage = 1
    local pageLabel = options.pageLabel
    local leftArrow
    local rightArrow
    local scrollView
    local function UpdatePage(page)
        currentPage = math.max(1, math.min(totalPages, page))
        if pageLabel then pageLabel:SetText(string.format("%d / %d", currentPage, totalPages)) end
        if leftArrow then leftArrow:SetVisible(totalPages > 1 and currentPage > 1) end
        if rightArrow then rightArrow:SetVisible(totalPages > 1 and currentPage < totalPages) end
        if options.onPageChange then options.onPageChange(currentPage, totalPages) end
    end
    scrollView = UI.ScrollView {
        position = "absolute", left = arrowWidth, top = 0,
        width = viewportWidth, height = height,
        scrollX = true, scrollY = false,
        showScrollbar = false, bounces = false,
        onScroll = function(_, scrollX)
            UpdatePage(math.floor((scrollX + pageWidth * 0.5) / pageWidth) + 1)
        end,
        children = {
            UI.Panel {
                width = contentWidth,
                height = height,
                position = "relative",
                children = contentChildren,
            },
        },
    }
    local function Arrow(symbol, left, direction)
        return UI.Panel {
            position = "absolute", left = left, top = math.floor((height - 72) * 0.5),
            width = arrowWidth, height = 72,
            clickable = true,
            alignItems = "center", justifyContent = "center",
            borderWidth = 2,
            borderColor = options.arrowBorderColor or options.arrowColor,
            borderRadius = 10,
            backgroundColor = options.arrowBackgroundColor or { 8, 24, 48, 210 },
            onClick = function()
                local target = math.max(1, math.min(totalPages, currentPage + direction))
                scrollView:SetScrollDirect((target - 1) * pageWidth, 0)
                UpdatePage(target)
            end,
            children = {
                options.text(symbol, 28, options.arrowColor, {
                    width = arrowWidth, height = 72, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    end
    leftArrow = Arrow("‹", 0, -1)
    rightArrow = Arrow("›", width - arrowWidth, 1)
    local result = UI.Panel {
        width = width,
        height = height,
        flexShrink = 0,
        position = "relative",
        overflow = "hidden",
        children = { scrollView, leftArrow, rightArrow },
    }
    UpdatePage(1)
    return result
end

return HorizontalArrowScroller
