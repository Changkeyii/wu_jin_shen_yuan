local EquipmentCatalog = require("shared.EquipmentCatalog")
local ItemPresentation = require("shared.ItemPresentation")
local EquipmentRecycleFilter = require("client.EquipmentRecycleFilter")
local EquipmentQuickFilter = require("client.EquipmentQuickFilter")
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
        -- 快速筛选只作用于装备（消耗品/材料等道具始终完整展示）
        if item.category == selectedCategory
            and (not item.equipmentId or EquipmentQuickFilter.Matches("bag", item))
        then
            list[#list + 1] = item
        end
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
        if not selectedItem or selectedItem.category ~= selectedCategory
            or (selectedItem.equipmentId and not EquipmentQuickFilter.Matches("bag", selectedItem))
        then
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
                CreateInventoryActionButton("快速筛选", ASSETS.ui.inventoryActionGold, function()
                    EquipmentQuickFilter.Show("bag", { onApplied = RequestPageRefresh })
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

    return CreateInventoryPage
end

function InventoryView.BuildInventoryPage(context)
    local buildInventoryPage = CreateInventoryView(context)
    return buildInventoryPage()
end


return InventoryView
