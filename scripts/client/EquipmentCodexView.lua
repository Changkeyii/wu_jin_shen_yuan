local UI = require("urhox-libs/UI")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local ItemSlotBase = require("client.ItemSlotBase")
local GridVirtualList = require("client.UI.GridVirtualList")

local EquipmentCodexView = {}

local CODEX_ASSETS = {
    background = "image/ui/codex/codex_background.png",
    titleBanner = "image/ui/codex/codex_title_banner.png",
    cardUnlocked = "image/ui/codex/codex_card_unlocked.png",
    cardLocked = "image/ui/codex/codex_card_locked.png",
    filterOn = "image/ui/codex/codex_filter_on.png",
    filterOff = "image/ui/codex/codex_filter_off.png",
    lockBadge = "image/ui/codex/codex_lock_badge.png",
}

local selectedSet_ = "all"

local SETS = {
    { id = "all", name = "全部" },
    { id = "nightmare", name = "噩梦" },
    { id = "lucky", name = "幸运" },
    { id = "voyage", name = "远征" },
    { id = "abyss", name = "深渊" },
    { id = "prophecy", name = "预言" },
}

local function CollectionCount(collection)
    local count = 0
    for _, definition in ipairs(EquipmentCatalog.GetAll()) do
        if collection[definition.id] then count = count + 1 end
    end
    return count
end

local function BestItem(definition, record)
    if not record then return nil end
    return {
        equipmentId = definition.id,
        name = definition.name,
        slot = definition.slot,
        category = definition.category,
        setId = definition.setId,
        rarity = record.rarity or definition.rarity,
        level = record.level or 1,
        enhance = record.enhance or 0,
        star = record.star or 0,
        power = record.powerBig,
    }
end

local CARD_WIDTH = 465
local CARD_HEIGHT = 330

local function ShortenName(value, maxChars)
    local text = tostring(value or "")
    local count = 0
    local position = 1
    while position <= #text do
        local byte = string.byte(text, position)
        local step = 1
        if byte >= 240 then step = 4
        elseif byte >= 224 then step = 3
        elseif byte >= 192 then step = 2 end
        if count >= maxChars then
            return string.sub(text, 1, position - 1) .. "..."
        end
        count = count + 1
        position = position + step
    end
    return text
end

local function BuildCard(context, definition, record)
    local unlocked = type(record) == "table"
    local item = BestItem(definition, record) or {
        equipmentId = definition.id,
        rarity = definition.rarity,
        level = 1,
        enhance = 0,
        star = 0,
    }
    local rarityColor = unlocked and context.rarityColor(item.rarity) or context.C.textDim
    local children = {
        ItemSlotBase.Icon(context, item, {
            position = "absolute",
            left = 27,
            top = 68,
            width = 130,
            height = 130,
            opacity = unlocked and 1.0 or 0.08,
            imageTint = unlocked and nil or { 14, 20, 34, 255 },
            pointerEvents = "none",
        }, definition.icon),
        context.compactTxt(
            ShortenName(definition.name, 9),
            22,
            unlocked and rarityColor or context.C.textDim,
            {
                position = "absolute", left = 180, top = 74,
                width = 252, height = 40, textAlign = "left",
                whiteSpace = "nowrap",
                textStroke = { width = 1, color = "#000000" },
                pointerEvents = "none",
            }
        ),
    }
    if unlocked then
        children[#children + 1] = context.compactTxt(
            EquipmentCatalog.SLOT_NAMES[definition.slot] or definition.slot,
            14,
            rarityColor,
            {
                position = "absolute", left = 180, top = 116,
                width = 252, height = 25, textAlign = "left",
                pointerEvents = "none",
            }
        )
        children[#children + 1] = context.compactTxt("评分", 17, context.C.textSecondary, {
            position = "absolute", left = 180, top = 160,
            width = 70, height = 38, textAlign = "left",
            pointerEvents = "none",
        })
        children[#children + 1] = context.compactTxt(context.formatInt(record.powerBig), 24, context.C.gold, {
            position = "absolute", left = 252, top = 160,
            width = 180, height = 38, textAlign = "right",
            whiteSpace = "nowrap",
            textStroke = { width = 1, color = "#000000" },
            pointerEvents = "none",
        })
        children[#children + 1] = context.compactTxt(
            "Lv." .. tostring(item.level)
                .. "    强化 +" .. tostring(item.enhance)
                .. "    " .. tostring(item.star) .. " 星",
            16,
            context.C.textSecondary,
            {
                position = "absolute", left = 34, top = 258,
                width = 397, height = 40, textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
                pointerEvents = "none",
            }
        )
    else
        children[#children + 1] = context.compactTxt("？？？？", 26, context.C.textDim, {
            position = "absolute", left = 180, top = 146,
            width = 252, height = 48, textAlign = "center",
            letterSpacing = 4,
            textStroke = { width = 1, color = "#000000" },
            pointerEvents = "none",
        })
        children[#children + 1] = UI.Panel {
            position = "absolute", left = 39, top = 71,
            width = 128, height = 128,
            backgroundImage = CODEX_ASSETS.lockBadge,
            backgroundFit = "contain",
            pointerEvents = "none",
        }
    end
    return UI.Panel {
        width = CARD_WIDTH,
        height = CARD_HEIGHT,
        flexShrink = 0,
        position = "relative",
        overflow = "hidden",
        backgroundImage = unlocked and CODEX_ASSETS.cardUnlocked or CODEX_ASSETS.cardLocked,
        backgroundFit = "contain",
        children = children,
    }
end

local function FilterDefinitions()
    local result = {}
    for _, definition in ipairs(EquipmentCatalog.GetAll()) do
        if selectedSet_ == "all" or definition.setId == selectedSet_ then
            result[#result + 1] = definition
        end
    end
    return result
end

function EquipmentCodexView.Build(context)
    local collection = context.game.equipmentCollection or {}
    local allDefinitions = EquipmentCatalog.GetAll()
    local unlockedCount = CollectionCount(collection)
    local definitions = FilterDefinitions()
    -- 虚拟网格：一维 definitions 按 2 列分组为行，行对象池化复用，卡片子树按需重建。
    local codexList = GridVirtualList.Build {
        columns = 2,
        cardWidth = CARD_WIDTH,
        cardHeight = CARD_HEIGHT,
        cardGap = 16,   -- 原行内卡片间距 gap
        rowGap = 16,    -- 原容器行间距 gap
        -- 原 ScrollView 为 absolute(left=58 top=298 width=976 bottom=24)；
        -- 设计高度 1920 - 顶栏310 - 底栏170 = 1440，滚动区 ≈ 1440 - 298 - 24 = 1118。
        -- 仅用于 Yoga 布局完成前的池预创建，实际视口以布局计算为准。
        viewportHeight = 1118,
        bounces = true, -- 与原生 ScrollView 默认 bounces=true 一致
        data = definitions,
        createCard = function(row, slotIndex)
            local definition = row._boundItems[slotIndex]
            if not definition then return nil end
            return BuildCard(context, definition, collection[definition.id])
        end,
    }

    local filterButtons = {}
    for _, set in ipairs(SETS) do
        local active = selectedSet_ == set.id
        filterButtons[#filterButtons + 1] = UI.Panel {
            width = 150,
            height = 62,
            flexShrink = 0,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = active and CODEX_ASSETS.filterOn or CODEX_ASSETS.filterOff,
            backgroundFit = "contain",
            onClick = function()
                if selectedSet_ == set.id then return end
                selectedSet_ = set.id
                context.onRefresh()
            end,
            children = {
                context.compactTxt(set.name, 20, active and context.C.text or context.C.textSecondary, {
                    width = 150, height = 62, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        }
    end

    return UI.Panel {
        width = "100%",
        height = "100%",
        position = "relative",
        overflow = "hidden",
        backgroundImage = CODEX_ASSETS.background,
        backgroundFit = "cover",
        children = {
            UI.Panel {
                position = "absolute", left = 44, top = 18,
                width = 992, height = 190,
                backgroundImage = CODEX_ASSETS.titleBanner,
                backgroundFit = "contain",
                children = {
                    context.txt("装备图鉴", 34, context.C.text, {
                        position = "absolute", left = 252, top = 45,
                        width = 488, height = 52, textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                        pointerEvents = "none",
                    }),
                    context.compactTxt(
                        "已收集 " .. tostring(unlockedCount) .. " / " .. tostring(#allDefinitions)
                            .. "    ·    永久记录历史最高评分",
                        17,
                        context.C.gold,
                        {
                            position = "absolute", left = 252, top = 101,
                            width = 488, height = 32, textAlign = "center",
                            textStroke = { width = 1, color = "#000000" },
                            pointerEvents = "none",
                        }
                    ),
                },
            },
            UI.Panel {
                position = "absolute", left = 64, top = 216,
                width = 952, height = 62,
                flexDirection = "row",
                justifyContent = "space-between",
                children = filterButtons,
            },
            codexList,
        },
    }
end

return EquipmentCodexView
