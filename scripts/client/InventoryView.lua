local EquipmentCatalog = require("shared.EquipmentCatalog")
local ItemPresentation = require("shared.ItemPresentation")
local EquipmentRecycleFilter = require("client.EquipmentRecycleFilter")
local EquipmentIcon = require("client.EquipmentIcon")
local BackpackItemSlot = require("client.BackpackItemSlot")
local EquipmentItemSlot = require("client.EquipmentItemSlot")

local InventoryView = {}

function InventoryView.EllipsizeName(text, maxChars)
    text = tostring(text or "")
    maxChars = math.max(1, math.floor(tonumber(maxChars) or 8))
    local count = 0
    local position = 1
    while position <= #text and count < maxChars do
        local byte = string.byte(text, position)
        local step = byte >= 240 and 4 or (byte >= 224 and 3 or (byte >= 192 and 2 or 1))
        position = position + step
        count = count + 1
    end
    if position <= #text then
        return string.sub(text, 1, position - 1) .. "…"
    end
    return text
end

function InventoryView.ItemLevelText(item)
    local level = item.level or item.dropLevel or item.floor or item.tier or 1
    return "Lv" .. tostring(level)
end

function InventoryView.SortByRarityAndPower(items)
    return require("shared.ItemSort").Sort(items)
end

-- 装备页手动布局参数：坐标均相对于 860 x 720 的角色装备区。
-- slotX / slotY 控制槽位；anchorX / anchorY 控制线终点；route 控制折线绕行点。
-- 调整时优先只改同一部位的这四组数值，不需要修改绘制逻辑。
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

local function CreateInventoryView(context)
    local UI = context.UI
    local C = context.C
    local ASSETS = context.ASSETS
    local SET_ORDER = context.SET_ORDER
    local SETS = context.SETS
    local SLOTS = context.SLOTS
    local CATEGORIES = context.CATEGORIES
    local inventoryEmptyState = context.inventoryEmptyState
    local characterPortrait = context.characterPortrait
    local playerNickname = context.playerNickname
    local slotIcons = ASSETS.ui.equipmentSlotIcons
    local ui = context.ui
    local game = context.game
    local selectedInventoryId = context.getSelectedInventoryId()
    local selectedSlot = context.getSelectedSlot()
    local selectedCategory = context.getSelectedCategory()
    local SetSelectedInventoryId = context.setSelectedInventoryId
    local SetSelectedSlot = context.setSelectedSlot
    local SetSelectedCategory = context.setSelectedCategory
    local GetInventoryTabScrollX = context.getInventoryTabScrollX
    local SetInventoryTabScrollX = context.setInventoryTabScrollX
    local GetEquipmentScrollY = context.getEquipmentScrollY
    local SetEquipmentScrollY = context.setEquipmentScrollY
    local GetEquipmentPageScrollY = context.getEquipmentPageScrollY
    local SetEquipmentPageScrollY = context.setEquipmentPageScrollY
    local RequestPageRefresh = context.requestPageRefresh
    local RequestDecomposePreview = context.requestDecomposePreview
    local EquipItem = context.equipItem
    local UnequipSlot = context.unequipSlot
    local DecomposeByFilter = context.decomposeByFilter
    local ShowDecomposeFilter = context.showDecomposeFilter
    local ShowDisposition = context.showDisposition
    local SetEquipmentLock = context.setEquipmentLock
    local AutoEquipBest = context.autoEquipBest
    local StrengthenSelected = context.strengthenSelected
    local StarSelected = context.starSelected
    local readOnly = context.readOnly
    local RarityColor = context.rarityColor
    local RarityName = context.rarityName
    local SlotName = context.slotName
    local ItemPower = context.itemPower
    local ItemPowerText = context.itemPowerText or function(item) return context.formatInt(ItemPower(item)) end
    local ItemImage = context.itemImage
    local IsEquipped = context.isEquipped
    local ShortenText = InventoryView.EllipsizeName
    local CompactTxt = context.compactTxt
    local Txt = context.txt
    local ImageProgress = context.imageProgress
    local ImageButton = context.imageButton
    local PixelPanel = context.pixelPanel
    local SectionTitle = context.sectionTitle
    local FormatInt = context.formatInt
    local GetItemById = context.getItemById
    local ShowItemTips = context.showItemTips
    local RegisterItemTipsTrigger = context.registerItemTipsTrigger

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
    props.backgroundImage = fallbackImage or ItemImage(item)
    props.backgroundFit = "contain"
    return UI.Panel(props)
end

local function FilteredInventory()
    local list = {}
    for _, item in ipairs(game.inventory or {}) do
        if item.category == selectedCategory then list[#list + 1] = item end
    end
    InventoryView.SortByRarityAndPower(list)
    return list
end

local function InventorySlotFrame(item, selected)
    if selected then return ASSETS.ui.inventorySlotSelected end
    if not item then return ASSETS.ui.inventorySlotEmpty end
    if item.rarity == "myth" then return ASSETS.ui.inventorySlotMyth end
    if item.rarity == "epic" or item.rarity == "legendary" or item.rarity == "legend" then return ASSETS.ui.inventorySlotLegend end
    if item.rarity == "artifact" or item.rarity == "rare" or item.rarity == "purple" then return ASSETS.ui.inventorySlotEpic end
    if item.rarity == "advanced" or item.rarity == "blue" then return ASSETS.ui.inventorySlotRare end
    return ASSETS.ui.inventorySlotCommon
end

local ItemLevelText = InventoryView.ItemLevelText

local function ItemEnhanceText(item)
    local enhance = item.enhance or 0
    return enhance > 0 and ("+" .. tostring(enhance)) or ""
end

local function ItemStarText(item)
    local star = math.max(0, math.min(5, item.star or 0))
    if star <= 0 then return "" end
    return string.rep("★", star)
end

local function InventoryImageBox(item, selected, size)
    size = size or 144
    local rarityColor = item and RarityColor(item.rarity) or C.border
    local scale = size / 144
    local function S(v) return math.floor(v * scale + 0.5) end
    local children = {
        UI.Panel {
            position = "absolute",
            left = 0,
            top = 0,
            width = size,
            height = size,
            backgroundImage = InventorySlotFrame(item, false),
            backgroundFit = "contain",
        }
    }
    if item then
        children[#children + 1] = ItemIcon(item, {
            position = "absolute",
            left = S(29),
            top = S(29),
            width = S(86),
            height = S(86),
        })
        children[#children + 1] = UI.Panel {
            position = "absolute",
            left = S(42),
            top = S(6),
            width = S(96),
            height = S(32),
            children = { CompactTxt(ItemLevelText(item), 13, C.text, { width = "100%", height = S(32), textAlign = "right", textStroke = { width = 2, color = "#000000" }, pointerEvents = "none" }) }
        }
        local enhanceText = ItemEnhanceText(item)
        if enhanceText ~= "" then
            children[#children + 1] = UI.Panel {
                position = "absolute",
                left = S(10),
                top = S(106),
                width = S(42),
                height = S(24),
                children = { CompactTxt(enhanceText, 17, C.gold, { width = "100%", height = S(24), textAlign = "left", textStroke = { width = 1, color = "#000000" } }) }
            }
        end
        local starText = ItemStarText(item)
        if starText ~= "" then
            children[#children + 1] = UI.Panel {
                position = "absolute",
                left = S(58),
                top = S(106),
                width = S(72),
                height = S(24),
                children = { CompactTxt(starText, 13, C.gold, { width = "100%", height = S(24), textAlign = "right", textStroke = { width = 1, color = "#000000" } }) }
            }
        end
        if IsEquipped(item) then
            children[#children + 1] = UI.Panel {
                position = "absolute",
                left = S(12),
                top = S(12),
                width = S(24),
                height = S(24),
                children = { CompactTxt("E", 15, C.success, { width = S(24), height = S(24), textAlign = "center", textStroke = { width = 1, color = "#000000" } }) }
            }
        end
        if item.rarity == "artifact" or item.rarity == "legendary" or item.rarity == "legend" or item.rarity == "epic" or item.rarity == "myth" then
            children[#children + 1] = UI.Panel {
                position = "absolute",
                left = S(8),
                top = S(8),
                width = S(128),
                height = S(128),
                backgroundImage = ASSETS.ui.selectionFrame,
                backgroundFit = "contain",
                imageTint = rarityColor,
                opacity = 0.20,
            }
        end
    end
    if selected then
        children[#children + 1] = UI.Panel {
            position = "absolute",
            left = 0,
            top = 0,
            width = size,
            height = size,
            backgroundImage = ASSETS.ui.selectionFrame,
            backgroundFit = "contain",
            pointerEvents = "none",
        }
    end
    return UI.Panel {
        width = size,
        height = size,
        flexShrink = 0,
        position = "relative",
        overflow = "visible",
        children = children,
    }
end

local function CreateItemIconCard(item, width, height)
    local selected = selectedInventoryId == item.id
    return BackpackItemSlot.Build(context, item, {
        width = width or 180,
        height = height or width or 180,
        selected = selected,
        clickable = true,
        showLockButton = true,
        onClick = function(widget)
            if selected and ShowItemTips then
                local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                    and widget:GetAbsoluteLayoutForHitTest()
                    or nil
                ShowItemTips(item, bounds, { source = "inventory" })
                return
            end
            SetSelectedInventoryId(item.id)
            RequestPageRefresh()
        end,
    })
end

local function CreateInventoryTabs()
    local tabWidth = 218
    local tabGap = 12
    local tabPadding = 6
    local viewportWidth = 790
    local arrowWidth = 64
    local arrowStep = tabWidth + tabGap
    local tabChildren = {}
    for _, cat in ipairs(CATEGORIES) do
        local active = selectedCategory == cat.id
        tabChildren[#tabChildren + 1] = UI.Panel {
            width = tabWidth,
            height = 72,
            flexShrink = 0,
            clickable = true,
            backgroundImage = active and ASSETS.ui.inventoryTabOn or ASSETS.ui.inventoryTabOff,
            backgroundFit = "sliced",
            backgroundSlice = { 12, 18, 12, 18 },
            borderWidth = active and 3 or 1,
            borderColor = active and C.focus or C.border,
            opacity = active and 1.0 or 0.78,
            onClick = function()
                SetSelectedCategory(cat.id)
                SetSelectedInventoryId(nil)
                RequestPageRefresh()
            end,
            children = {
                Txt(cat.name, active and 23 or 20, active and C.text or C.textDim, {
                    width = "100%",
                    height = 72,
                    textAlign = "center",
                    textStroke = { width = active and 2 or 1, color = "#000000" },
                }),
            },
        }
    end
    local tabContentWidth = #CATEGORIES * tabWidth
        + math.max(0, #CATEGORIES - 1) * tabGap
        + tabPadding * 2
    local maxScrollX = math.max(0, tabContentWidth - viewportWidth)
    local initialScrollX = math.max(0, math.min(GetInventoryTabScrollX(), maxScrollX))
    local scrollView = UI.ScrollView {
        position = "absolute",
        left = 70,
        top = 0,
        width = viewportWidth,
        height = 84,
        scrollX = true,
        scrollY = false,
        showScrollbar = false,
        bounces = false,
        children = {
            UI.Panel {
                width = tabContentWidth,
                height = 84,
                flexDirection = "row",
                gap = tabGap,
                paddingLeft = tabPadding,
                paddingRight = tabPadding,
                alignItems = "center",
                children = tabChildren,
            },
        },
    }

    local function ArrowButton(symbol, left, onClick)
        return UI.Panel {
            position = "absolute",
            left = left,
            top = 10,
            width = arrowWidth,
            height = 64,
            flexShrink = 0,
            clickable = true,
            backgroundImage = ASSETS.ui.inventoryTabOff,
            backgroundFit = "sliced",
            backgroundSlice = { 12, 18, 12, 18 },
            borderWidth = 2,
            borderColor = C.border,
            onClick = onClick,
            children = {
                Txt(symbol, 30, C.text, {
                    width = "100%",
                    height = 64,
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        }
    end

    local leftArrow = ArrowButton("◀", 0, function()
        scrollView:ScrollBy(-arrowStep, 0)
    end)
    local rightArrow = ArrowButton("▶", 866, function()
        scrollView:ScrollBy(arrowStep, 0)
    end)

    local function UpdateArrowVisibility(scrollX)
        leftArrow:SetVisible(scrollX > 1)
        rightArrow:SetVisible(scrollX < maxScrollX - 1)
    end
    scrollView.props.onScroll = function(_, scrollX)
        SetInventoryTabScrollX(scrollX)
        UpdateArrowVisibility(scrollX)
    end
    scrollView:SetScrollDirect(initialScrollX, 0)
    UpdateArrowVisibility(initialScrollX)

    return UI.Panel {
        position = "relative",
        width = 930,
        height = 84,
        children = { scrollView, leftArrow, rightArrow },
    }
end

local function CreateSelectedItemDetail()
    local item = GetItemById(selectedInventoryId)
    if not item then
        return UI.Panel {
            width = 940,
            height = 470,
            flexShrink = 0,
            backgroundImage = ASSETS.ui.inventoryDetail,
            backgroundFit = "contain",
            children = {
                Txt("装备详情", 28, C.text, { position = "absolute", left = 54, top = 38, width = 220, height = 44, textStroke = { width = 2, color = "#000000" } }),
                Txt("点选 1:1 装备格查看完整信息", 22, C.textSecondary, { position = "absolute", left = 54, top = 86, width = 480, height = 36 }),
                Txt("格子内仅保留部位、品质、等级、强化、星级、状态等核心视觉维度", 20, C.textDim, { position = "absolute", left = 54, top = 126, width = 650, height = 36 }),
                UI.Panel { position = "absolute", left = 740, top = 132, width = 128, height = 128, backgroundImage = ASSETS.items.chest, backgroundFit = "contain", opacity = 0.55 },
            }
        }
    end
    local slotText = item.slot and SlotName(item.slot) or ItemPresentation.CategoryName(item.category)
    local setText = item.setId and (SETS[item.setId].short .. "套") or "散件"
    local decomposeRefund = type(item.decomposeRefund) == "table" and item.decomposeRefund or nil
    if item.id
        and not decomposeRefund
        and item.refundRequestPending ~= true
        and RequestDecomposePreview
    then
        item.refundRequestPending = true
        RequestDecomposePreview(item.id, function(response)
            item.refundRequestPending = false
            if response and response.ok and type(response.data) == "table" then
                item.decomposeRefund = {
                    gold = response.data.gold or 0,
                    fragments = response.data.fragments or 0,
                    rate = response.data.rate or 0,
                    vipLevel = response.data.vipLevel or 0,
                }
                RequestPageRefresh()
            end
        end)
    end
    local refundText = decomposeRefund
        and ("金币 " .. FormatInt(decomposeRefund.gold or 0)
            .. " / 碎片 " .. FormatInt(decomposeRefund.fragments or 0)
            .. "（" .. tostring(math.floor((decomposeRefund.rate or 0) * 100)) .. "%）")
        or "正在获取真实返还…"
    local detailRows = {
        { "名称", item.name or "未知装备", RarityColor(item.rarity) },
        { "品质", RarityName(item.rarity), RarityColor(item.rarity) },
        { "部位", slotText, C.textSecondary },
        { "套装", setText, C.textSecondary },
        { "等级", ItemLevelText(item), C.textSecondary },
        { "强化", ItemEnhanceText(item) ~= "" and ItemEnhanceText(item) or "+0", C.gold },
        { "星级", ItemStarText(item) ~= "" and ItemStarText(item) or "无", C.gold },
        { "战力", ItemPowerText(item), C.gold },
        { "数量", FormatInt(item.quantity or 1), C.textSecondary },
        { "状态", item.isEquipped and "已穿戴" or "未穿戴", item.isEquipped and C.success or C.textDim },
        { "保护", item.locked and "已锁定" or "未锁定", item.locked and C.gold or C.textDim },
        { "交易", item.tradeable == true and "可交易" or "不可交易", item.tradeable == true and C.success or C.textDim },
        { "来源", ItemPresentation.SourceName(item.source), C.textSecondary },
        { "获取", item.acquiredAt and item.acquiredAt > 0 and os.date("%Y-%m-%d %H:%M", item.acquiredAt) or "旧存档", C.textSecondary },
        { "分解返还", refundText, C.textSecondary },
    }
    local rows = {}
    for _, row in ipairs(detailRows) do
        rows[#rows + 1] = UI.Panel {
            width = "100%",
            height = 38,
            flexDirection = "row",
            alignItems = "center",
            paddingLeft = 12,
            paddingRight = 12,
            backgroundImage = ASSETS.ui.detailRow,
            backgroundFit = "contain",
            children = {
                UI.Panel {
                    width = 96,
                    height = 30,
                    flexShrink = 0,
                    justifyContent = "center",
                    children = { CompactTxt(row[1], 18, C.textDim, { width = "100%", height = 30, textAlign = "left" }) },
                },
                UI.Panel {
                    flexGrow = 1,
                    flexBasis = 0,
                    height = 30,
                    justifyContent = "center",
                    children = { CompactTxt(
                    row[1] == "名称" and ShortenText(row[2], 20) or row[2],
                    18,
                    row[3],
                    {
                        width = "100%",
                        height = 30,
                        textAlign = "right",
                        textStroke = { width = 1, color = "#000000" },
                    }
                ) },
                },
            }
        }
    end
    return UI.Panel {
        width = 940,
        height = 470,
        flexShrink = 0,
        backgroundImage = ASSETS.ui.inventoryDetail,
        backgroundFit = "contain",
        children = {
            UI.Panel {
                position = "absolute",
                left = 42,
                top = 66,
                width = 160,
                height = 160,
                alignItems = "center",
                justifyContent = "center",
                children = { InventoryImageBox(item, false, 152) }
            },
            UI.Panel {
                position = "absolute",
                left = 210,
                top = 40,
                width = 520,
                height = 36,
                justifyContent = "center",
                children = { CompactTxt(ShortenText(item.name or "未知装备", 12), 24, RarityColor(item.rarity), { width = "100%", height = 36, textAlign = "left", textStroke = { width = 2, color = "#000000" } }) },
            },
            UI.Panel {
                position = "absolute",
                left = 210,
                top = 78,
                width = 520,
                height = 30,
                justifyContent = "center",
                children = { CompactTxt(RarityName(item.rarity) .. " / " .. slotText .. " / " .. setText, 19, RarityColor(item.rarity), { width = "100%", height = 30, textAlign = "left", textStroke = { width = 1, color = "#000000" } }) },
            },
            UI.ScrollView {
                position = "absolute",
                left = 210,
                top = 116,
                width = 520,
                height = 260,
                scrollY = true,
                showScrollbar = false,
                children = {
                    UI.Panel { width = "100%", gap = 6, paddingLeft = 0, paddingRight = 8, children = rows }
                }
            },
            UI.Panel {
                position = "absolute",
                left = 748,
                top = 124,
                width = 150,
                height = 46,
                alignItems = "center",
                children = { item.slot and ImageButton("穿戴", 150, 46, ASSETS.ui.buttonBlue, function() EquipItem(item) end, readOnly) or ImageButton("", 150, 46, ASSETS.ui.buttonBlue, nil, true) }
            },
            UI.Panel {
                position = "absolute",
                left = 748,
                top = 182,
                width = 150,
                height = 46,
                alignItems = "center",
                children = { ImageButton(item.locked and "解锁" or "锁定", 150, 46, item.locked and ASSETS.ui.buttonBlue or ASSETS.ui.inventoryActionGold, function()
                    if not readOnly then SetEquipmentLock(item) end
                end, readOnly) }
            },
        }
    }
end

local function CreateInventoryActionButton(text, image, onClick)
    return UI.Panel {
        width = 260,
        height = 58,
        flexShrink = 0,
        clickable = not readOnly,
        opacity = readOnly and 0.45 or 1.0,
        backgroundImage = image,
        backgroundFit = "contain",
        onClick = function()
            if not readOnly and onClick then onClick() end
        end,
        children = {
            Txt(text, 20, C.text, {
                width = "100%",
                height = 58,
                textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
            }),
        },
    }
end

local function CreateInventoryPage()
    local items = FilteredInventory()
    local firstItem = items[1]
    local selectedItem = selectedInventoryId and GetItemById(selectedInventoryId) or nil

    if firstItem then
        if not selectedItem or selectedItem.category ~= selectedCategory then
            selectedInventoryId = firstItem.id
            SetSelectedInventoryId(firstItem.id)
        end
    else
        selectedInventoryId = nil
        SetSelectedInventoryId(nil)
    end

    local pageChildren = {
        UI.Panel {
            width = "100%",
            height = 196,
            flexShrink = 0,
            backgroundImage = ASSETS.ui.inventoryTitle,
            backgroundFit = "contain",
            children = {
                Txt("深渊背包", 32, C.text, { position = "absolute", left = 94, top = 28, width = 300, height = 48, textAlign = "center", textStroke = { width = 3, color = "#000000" } }),
                Txt(string.format("装备 %d / %d", game.equipmentInventoryCount or 0, game.inventoryCapacity or 300), 20, C.textSecondary, { position = "absolute", left = 450, top = 34, width = 370, height = 34, textAlign = "center", textStroke = { width = 1, color = "#000000" } }),
                UI.Panel { position = "absolute", left = 28, top = 86, width = 930, height = 122, alignItems = "center", children = { CreateInventoryTabs() } },
            },
        },
        UI.Panel {
            width = "100%",
            height = 76,
            flexShrink = 0,
            flexDirection = "row",
            justifyContent = "center",
            alignItems = "center",
            gap = 18,
            overflow = "hidden",
            children = {
                CreateInventoryActionButton("一键分解", ASSETS.ui.inventoryActionBlue, function()
                    local filter = EquipmentRecycleFilter.Get("decompose")
                    local candidates = {}
                    for _, item in ipairs(game.inventory or {}) do
                        if item.equipmentId and filter[item.rarity] == true
                            and not item.locked and not item.aidLocked and not IsEquipped(item) then
                            candidates[#candidates + 1] = item
                        end
                    end
                    if #candidates > 0 then
                        ShowDisposition("decompose", candidates)
                    else
                        DecomposeByFilter()
                    end
                end),
                CreateInventoryActionButton("分解筛选", ASSETS.ui.inventoryActionBlue, function()
                    ShowDecomposeFilter(RequestPageRefresh)
                end),
            },
        },
    }

    if #items == 0 then
        pageChildren[#pageChildren + 1] = UI.Panel {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
            minHeight = 520,
            flexShrink = 1,
            alignItems = "center",
            justifyContent = "center",
            gap = 18,
            children = {
                UI.Panel {
                    width = 256,
                    height = 256,
                    flexShrink = 0,
                    backgroundImage = inventoryEmptyState,
                    backgroundFit = "contain",
                },
                Txt("当前分类暂无装备", 28, C.textSecondary, {
                    width = "100%",
                    height = 42,
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                }),
                CompactTxt("切换上方页签查看其他装备", 20, C.textDim, {
                    width = "100%",
                    height = 32,
                    textAlign = "center",
                    textStroke = { width = 1, color = "#000000" },
                }),
            },
        }
    else
        local cards = {}
        for _, item in ipairs(items) do
            cards[#cards + 1] = CreateItemIconCard(item)
        end

        pageChildren[#pageChildren + 1] = UI.Panel {
            width = "100%",
            height = 500,
            flexShrink = 0,
            children = { CreateSelectedItemDetail() },
        }
        pageChildren[#pageChildren + 1] = UI.Panel {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
            minHeight = 240,
            flexShrink = 1,
            overflow = "hidden",
            children = {
                UI.ScrollView {
                    width = "100%",
                    height = "100%",
                    flexGrow = 1,
                    flexBasis = 0,
                    scrollY = true,
                    showScrollbar = false,
                    children = {
                        UI.Panel {
                            width = "100%",
                            flexDirection = "row",
                            flexWrap = "wrap",
                            justifyContent = "center",
                            gap = 14,
                            paddingLeft = 12,
                            paddingRight = 12,
                            paddingTop = 12,
                            paddingBottom = 42,
                            children = cards,
                        },
                    },
                },
            },
        }
    end

    return UI.Panel {
        width = "100%",
        height = "100%",
        paddingLeft = 24,
        paddingRight = 24,
        paddingTop = 18,
        paddingBottom = 22,
        gap = 14,
        children = pageChildren,
    }
end

local function CreateEquipSlot(slot)
    local item = game.equipped and game.equipped[slot.id]
    local selected = selectedSlot == slot.id
    local color = item and RarityColor(item.rarity) or C.border
    return UI.Panel {
        width = 214,
        height = 212,
        clickable = true,
        padding = 10,
        backgroundImage = selected and ASSETS.ui.equipSlotSelected or ASSETS.ui.equipSlot,
        backgroundFit = "contain",
        onClick = function()
            SetSelectedSlot(slot.id)
            RequestPageRefresh()
        end,
        children = {
            UI.Panel {
                width = "100%",
                height = 98,
                backgroundImage = InventorySlotFrame(item, false),
                backgroundFit = "contain",
                alignItems = "center",
                justifyContent = "center",
                children = {
                    ItemIcon(item, { width = 86, height = 86, opacity = item and 1 or 0.42 }),
                }
            },
            Txt(slot.name, 26, selected and C.primary or C.textSecondary, { width = "100%", height = 34, textAlign = "center", textStroke = { width = 1, color = "#000000" } }),
            Txt(item and ("+" .. tostring(item.enhance or 0) .. " / " .. tostring(item.star or 0) .. "★") or "空槽", 25, item and C.gold or C.textDim, { width = "100%", height = 34, textAlign = "center", textStroke = { width = 1, color = "#000000" } }),
        }
    }
end

local function CreateSetOverview()
    local serverProgress = game.setProgress or (game.stats and game.stats.setProgress) or {}

    local children = {
        SectionTitle("套装图鉴", "同套装累计激活 3 / 6 / 9 / 12；防具、首饰、特殊装备各自满 3 件激活区域效果"),
    }
    for _, setId in ipairs(SET_ORDER) do
        local set = SETS[setId]
        local progressData = serverProgress[setId] or {}
        local count = progressData.count or 0
        local regions = progressData.regions or {}
        local activeTiers = progressData.activeTiers or {}
        local tierText = table.concat({
            activeTiers["3"] and "3激活" or "3未激活",
            activeTiers["6"] and "6激活" or "6未激活",
            activeTiers["9"] and "9激活" or "9未激活",
            activeTiers["12"] and "12激活" or "12未激活",
        }, " · ")
        local regionText = string.format("防具%d/3  首饰%d/3  特殊%d/3", regions.armor or 0, regions.jewelry or 0, regions.special or 0)
        local progress = ImageProgress(720, 22, count, 12, ASSETS.ui.progressTrackSet, ASSETS.ui.progressFillSet)
        local progressLabel = CompactTxt(
            string.format("%d / 12", count),
            18,
            count >= 12 and C.success or C.textSecondary,
            { width = 720, height = 22, textAlign = "right", textStroke = { width = 1, color = "#000000" } }
        )

        children[#children + 1] = UI.Panel {
            width = "100%",
            height = 118,
            flexShrink = 0,
            position = "relative",
            overflow = "hidden",
            backgroundImage = ASSETS.ui.infoBarBlue,
            backgroundFit = "sliced",
            backgroundSlice = { 10, 10, 10, 10 },
            children = {
                UI.Panel {
                    position = "absolute",
                    left = 16,
                    top = 14,
                    width = 54,
                    height = 54,
                    backgroundImage = ASSETS.items.crystal,
                    backgroundFit = "contain",
                    imageTint = set.color,
                },
                UI.Panel {
                    position = "absolute",
                    left = 84,
                    top = 12,
                    width = 560,
                    height = 54,
                    justifyContent = "center",
                    gap = 2,
                    children = {
                        CompactTxt(ShortenText(set.name, 16), 22, set.color, {
                            width = "100%",
                            height = 28,
                            textAlign = "left",
                            textStroke = { width = 1, color = "#000000" },
                        }),
                        CompactTxt(tierText .. "  |  " .. regionText, 16, C.textSecondary, {
                            width = "100%",
                            height = 24,
                            textAlign = "left",
                            textStroke = { width = 1, color = "#000000" },
                        }),
                    },
                },
                UI.Panel {
                    position = "absolute",
                    right = 18,
                    top = 16,
                    width = 94,
                    height = 46,
                    justifyContent = "center",
                    children = {
                        CompactTxt(count >= 12 and "已完成" or (tostring(count) .. "/12"), 20, count >= 12 and C.success or C.text, {
                            width = "100%",
                            height = 26,
                            textAlign = "right",
                            textStroke = { width = 1, color = "#000000" },
                        }),
                    },
                },
                UI.Panel {
                    position = "absolute",
                    left = 84,
                    top = 76,
                    width = 720,
                    height = 22,
                    overflow = "hidden",
                    children = { progress },
                },
                UI.Panel {
                    position = "absolute",
                    left = 84,
                    top = 76,
                    width = 720,
                    height = 22,
                    pointerEvents = "none",
                    children = { progressLabel },
                },
            },
        }
    end

    return PixelPanel {
        width = "100%",
        gap = 12,
        children = children,
    }
end

local function CreateEquipmentPage()
    local filtered = {}
    for _, item in ipairs(game.inventory or {}) do
        if item.slot == selectedSlot and item.category ~= "consumable" and item.category ~= "material" then
            filtered[#filtered + 1] = item
        end
    end
    InventoryView.SortByRarityAndPower(filtered)

    local selectedCandidate = selectedInventoryId and GetItemById(selectedInventoryId) or nil
    if not selectedCandidate or selectedCandidate.slot ~= selectedSlot then
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
        return EquipmentItemSlot.Build(context, item, {
            active = active,
            clickable = true,
            detailText = "战力 " .. ItemPowerText(item),
            onPointerDown = function() StartDrag(item) end,
            onPointerUp = function(event) DropAtPointer(event) end,
            onClick = function(widget)
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
                draggingItem = nil
                if dragHint then dragHint:SetText("") end
                if not ShowItemTips then return end
                local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                    and widget:GetAbsoluteLayoutForHitTest()
                    or nil
                ShowItemTips(item, bounds, { source = "equipment" })
            end,
        })
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
            ImageButton("快捷穿戴", 170, 50, ASSETS.ui.buttonBlue, function() EquipItem(selectedCandidate) end, readOnly),
        }
    else
        detailChildren[1] = CompactTxt("点击装备卡选择装备", 20, C.textDim, { width = "100%", height = 30, textAlign = "center" })
    end

    local equippedForSelectedSlot = game.equipped and game.equipped[selectedSlot]
    local upgradeActionBar = UI.Panel {
        width = 900,
        height = 82,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "center",
        gap = 18,
        backgroundImage = ASSETS.ui.infoBarGold,
        backgroundFit = "sliced",
        backgroundSlice = { 10, 10, 10, 10 },
        opacity = equippedForSelectedSlot and 1.0 or 0.55,
        children = {
            ImageButton("强化", 190, 50, ASSETS.ui.buttonBlueWide, function()
                if equippedForSelectedSlot then StrengthenSelected() end
            end, readOnly or not equippedForSelectedSlot),
            ImageButton("升星", 190, 50, ASSETS.ui.buttonPurple, function()
                if equippedForSelectedSlot then StarSelected() end
            end, readOnly or not equippedForSelectedSlot),
            ImageButton("卸下", 190, 50, ASSETS.ui.buttonRed, function()
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
    return CreateInventoryPage, CreateEquipmentPage
end

function InventoryView.BuildInventoryPage(context)
    local buildInventoryPage = CreateInventoryView(context)
    return buildInventoryPage()
end

function InventoryView.BuildEquipmentPage(context)
    local _, buildEquipmentPage = CreateInventoryView(context)
    return buildEquipmentPage()
end

return InventoryView
