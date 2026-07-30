local UI = require("urhox-libs/UI")
local Input = require("urhox-libs/UI/Core/Input")
local PointerEvent = require("urhox-libs/UI/Core/PointerEvent")
local ItemSlotBase = require("client.ItemSlotBase")

local ItemTips = {}

local context_ = nil
local root_ = nil
local layer_ = nil
local panel_ = nil
local comparePanel_ = nil
local compareButton_ = nil
local currentItem_ = nil
local currentAnchor_ = nil
local currentOptions_ = nil
local compareExpanded_ = false
local pointerDownListener_ = nil
local triggers_ = setmetatable({}, { __mode = "k" })

local AFFIX_NAMES = {
    ["core.fury"] = "狂怒：提升攻击",
    ["core.guard"] = "坚守：提升防御",
    ["core.vitality"] = "活力：提升生命",
    ["core.swiftness"] = "迅捷：提升攻击速度",
    ["core.vampirism"] = "汲取：提升生命偷取",
    ["core.boss_hunter"] = "猎王：提升首领伤害",
}

local UNIQUE_EFFECT_NAMES = {
    ["myth.tower_soul_resonance"] = "塔魂共鸣：额外提升首领伤害",
}

local SOURCE_NAMES = {
    starter = "初始装备",
    monster_drop = "怪物掉落",
    elite_drop = "精英掉落",
    boss_drop = "首领掉落",
    chapter_boss_drop = "章节首领掉落",
    chest_drop = "宝箱掉落",
    tower_aid = "登塔援助",
    aid = "登塔援助",
    admin_grant = "管理发放",
    legacy = "历史装备",
    ["serverCloud.item"] = "云端发放",
}

local function RemoveLayer()
    if layer_ and root_ then
        root_:RemoveChild(layer_)
    end
    layer_ = nil
    panel_ = nil
    comparePanel_ = nil
    compareButton_ = nil
    currentItem_ = nil
    currentAnchor_ = nil
    currentOptions_ = nil
    compareExpanded_ = false
end

local function IsSelfOrDescendant(widget, ancestor)
    local current = widget
    while current do
        if current == ancestor then return true end
        current = current.parent
    end
    return false
end

local function FindTrigger(widget)
    local current = widget
    while current do
        if triggers_[current] then return current end
        current = current.parent
    end
    return nil
end

local function IsInteractive(widget)
    local current = widget
    while current do
        local props = current.props or {}
        if props.clickable == true
            or props.onClick
            or props.onPointerDown
            or props.onPointerUp
            or props.onLongPress
            or props.onLongPressStart
            or props.onTap
        then
            return true
        end
        current = current.parent
    end
    return false
end

local function HandleGlobalPointerDown(event)
    if not panel_ then return end
    local scale = UI.GetScale and UI.GetScale() or 1
    local x = (event.x or 0) / math.max(scale, 0.001)
    local y = (event.y or 0) / math.max(scale, 0.001)
    local hit = UI.FindWidgetAt(x, y)

    if hit and IsSelfOrDescendant(hit, panel_) then return end
    if hit and comparePanel_ and IsSelfOrDescendant(hit, comparePanel_) then return end
    if hit and compareButton_ and IsSelfOrDescendant(hit, compareButton_) then return end
    if FindTrigger(hit) then return end
    if IsInteractive(hit) then return end

    print("[ItemTips] hide after blank-area ray hit")
    RemoveLayer()
end

local function EnsureInputListener()
    if pointerDownListener_ then return end
    pointerDownListener_ = Input.On(
        PointerEvent.Types.PointerDown,
        HandleGlobalPointerDown,
        -1000
    )
end

local function AddRow(rows, label, value, color, options)
    if value == nil or value == "" then return end
    options = options or {}
    rows[#rows + 1] = {
        label = label,
        value = tostring(value),
        color = color,
        full = options.full == true,
        height = options.height or 38,
    }
end

local function Percent(value)
    return string.format("%.1f%%", (tonumber(value) or 0) * 100)
end

local function BuildRows(item, compactForCompare)
    local C = context_.C
    local rows = {}
    AddRow(rows, "等级", context_.formatInt(item.level or 1), C.textSecondary)
    AddRow(rows, "强化", "+" .. tostring(item.enhance or 0), C.gold)
    AddRow(rows, "星级", tostring(item.star or 0) .. " 星", C.gold)
    local setText = item.setEnabled == false
        and "未激活"
        or (item.setName or (item.setId and tostring(item.setId)) or "散件")
    AddRow(rows, "套装", setText, item.setEnabled == false and C.textDim or C.textSecondary)
    AddRow(rows, "数量", context_.formatInt(item.quantity or 1), C.textSecondary)

    if not compactForCompare then
        if item.atkBig or (item.atk or 0) > 0 then
            AddRow(rows, "攻击", context_.formatInt(item.atkBig or item.atk), C.primary)
        end
        if item.defBig or (item.def or 0) > 0 then
            AddRow(rows, "防御", context_.formatInt(item.defBig or item.def), C.textSecondary)
        end
        if item.hpBig or (item.hp or 0) > 0 then
            AddRow(rows, "生命", context_.formatInt(item.hpBig or item.hp), C.hp)
        end
        if (item.crit or 0) > 0 then AddRow(rows, "暴击率", Percent(item.crit), C.gold) end
        if (item.critDmg or 0) > 0 then AddRow(rows, "暴击伤害", Percent(item.critDmg), C.gold) end
        if (item.atkSpeed or 0) > 0 then AddRow(rows, "攻击速度", Percent(item.atkSpeed), C.mp) end
        if (item.lifeSteal or 0) > 0 then AddRow(rows, "生命偷取", Percent(item.lifeSteal), C.success) end
        if (item.damageReduction or 0) > 0 then AddRow(rows, "伤害减免", Percent(item.damageReduction), C.success) end
        if (item.bossDamage or 0) > 0 then AddRow(rows, "首领伤害", Percent(item.bossDamage), C.error) end
    end

    local state = {}
    if context_.isEquipped(item) then state[#state + 1] = "已穿戴" end
    if item.locked then state[#state + 1] = "已锁定" end
    if item.aidLocked then
        state[#state + 1] = item.aidFloor
            and ("援助占用 · 第 " .. context_.formatInt(item.aidFloor) .. " 层")
            or "援助占用"
    end
    AddRow(rows, "状态", #state > 0 and table.concat(state, " · ") or "可用", #state > 0 and C.gold or C.success)
    AddRow(rows, "来源", SOURCE_NAMES[item.source] or "其他途径", C.textSecondary)
    local decomposeRefund = type(item.decomposeRefund) == "table"
        and item.decomposeRefund
        or nil
    AddRow(
        rows,
        "分解返还",
        decomposeRefund
            and ("金币 " .. context_.formatInt(decomposeRefund.gold or 0)
                .. " / 碎片 " .. context_.formatInt(decomposeRefund.fragments or 0)
                .. "（" .. tostring(math.floor((decomposeRefund.rate or 0) * 100)) .. "%）")
            or "正在获取真实返还…",
        C.textSecondary,
        { full = true }
    )
    return rows
end

local function BuildRow(row, width)
    local C = context_.C
    return UI.Panel {
        width = width,
        height = row.height,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "center",
        paddingLeft = 16,
        paddingRight = 16,
        borderBottomWidth = 1,
        borderBottomColor = C.border,
        children = {
            context_.compactTxt(row.label, 16, C.textDim, {
                width = 108,
                height = 28,
                flexShrink = 0,
                textAlign = "left",
            }),
            row.full
                and context_.multiTxt(row.value, 17, row.color or C.textSecondary, {
                    flexGrow = 1,
                    flexBasis = 0,
                    height = row.height - 8,
                    textAlign = "right",
                    textStroke = { width = 1, color = "#000000" },
                })
                or context_.compactTxt(row.value, 18, row.color or C.textSecondary, {
                    flexGrow = 1,
                    flexBasis = 0,
                    height = row.height - 8,
                    textAlign = "right",
                    textStroke = { width = 1, color = "#000000" },
                }),
        },
    }
end

local function CompareValues(left, right)
    if context_.compareMagnitude then
        return context_.compareMagnitude(left or 0, right or 0)
    end
    left = tonumber(left) or 0
    right = tonumber(right) or 0
    if left == right then return 0 end
    return left > right and 1 or -1
end

local function BuildCompareRows(candidate, equipped)
    local rows = {
        { "战力", context_.itemPower(candidate), context_.itemPower(equipped), false },
        { "攻击", candidate.atkBig or candidate.atk or 0, equipped.atkBig or equipped.atk or 0, false },
        { "防御", candidate.defBig or candidate.def or 0, equipped.defBig or equipped.def or 0, false },
        { "生命", candidate.hpBig or candidate.hp or 0, equipped.hpBig or equipped.hp or 0, false },
        { "暴击", candidate.crit or 0, equipped.crit or 0, true },
        { "暴伤", candidate.critDmg or 0, equipped.critDmg or 0, true },
        { "攻速", candidate.atkSpeed or 0, equipped.atkSpeed or 0, true },
        { "吸血", candidate.lifeSteal or 0, equipped.lifeSteal or 0, true },
        { "减伤", candidate.damageReduction or 0, equipped.damageReduction or 0, true },
        { "首领伤害", candidate.bossDamage or 0, equipped.bossDamage or 0, true },
    }
    return rows
end

local function BuildComparePanel(candidate, equipped, width, height, left, top)
    local C = context_.C
    local compareRows = {}
    for _, row in ipairs(BuildCompareRows(candidate, equipped)) do
        local order = CompareValues(row[2], row[3])
        local candidateText = row[4] and Percent(row[2]) or context_.formatInt(row[2])
        local equippedText = row[4] and Percent(row[3]) or context_.formatInt(row[3])
        local candidateColor = order > 0 and C.success or (order < 0 and C.error or C.textSecondary)
        compareRows[#compareRows + 1] = UI.Panel {
            width = width - 28,
            height = 42,
            flexShrink = 0,
            flexDirection = "row",
            alignItems = "center",
            paddingLeft = 14,
            paddingRight = 14,
            borderBottomWidth = 1,
            borderBottomColor = C.border,
            children = {
                context_.compactTxt(row[1], 15, C.textDim, {
                    width = 74,
                    height = 28,
                    flexShrink = 0,
                    textAlign = "left",
                }),
                context_.compactTxt(equippedText, 16, C.textSecondary, {
                    width = 88,
                    height = 28,
                    textAlign = "right",
                }),
                context_.compactTxt("→", 16, candidateColor, {
                    width = 28,
                    height = 28,
                    textAlign = "center",
                }),
                context_.compactTxt(candidateText, 16, candidateColor, {
                    flexGrow = 1,
                    flexBasis = 0,
                    height = 28,
                    textAlign = "right",
                    textStroke = { width = 1, color = "#000000" },
                }),
            },
        }
    end

    local slotContext = {
        C = C,
        ASSETS = context_.ASSETS,
        itemImage = context_.itemImage,
        itemLevelText = context_.itemLevelText,
        compactTxt = context_.compactTxt,
        rarityColor = context_.rarityColor,
        isEquipped = context_.isEquipped,
    }
    return UI.Panel {
        id = "itemTipsComparePanel",
        position = "absolute",
        left = left,
        top = top,
        width = width,
        height = height,
        overflow = "hidden",
        backgroundImage = context_.ASSETS.ui.itemTipsCompareFrame,
        backgroundFit = "contain",
        boxShadow = {
            color = { 0, 0, 0, 165 },
            offsetX = 0,
            offsetY = 10,
            blurRadius = 22,
        },
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                width = width,
                height = 7,
                pointerEvents = "none",
            },
            UI.Panel {
                position = "absolute",
                left = 14,
                top = 24,
                width = 108,
                height = 108,
                children = {
                    ItemSlotBase.Build(slotContext, equipped, {
                        size = 104,
                        showEquipped = true,
                    }),
                },
            },
            context_.compactTxt("当前已装备", 17, C.textDim, {
                position = "absolute",
                left = 136,
                top = 26,
                width = width - 154,
                height = 26,
                textAlign = "left",
            }),
            context_.compactTxt(context_.shortenText(equipped.name or "未知装备", 12), 21,
                context_.rarityColor(equipped.rarity), {
                    position = "absolute",
                    left = 136,
                    top = 58,
                    width = width - 154,
                    height = 32,
                    textAlign = "left",
                    textStroke = { width = 1, color = "#000000" },
                }),
            context_.compactTxt("当前 → 候选", 16, C.textSecondary, {
                position = "absolute",
                left = 136,
                top = 98,
                width = width - 154,
                height = 26,
                textAlign = "left",
            }),
            UI.ScrollView {
                position = "absolute",
                left = 14,
                top = 150,
                width = width - 28,
                height = height - 168,
                scrollX = false,
                scrollY = true,
                showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%",
                        gap = 5,
                        paddingBottom = 10,
                        children = compareRows,
                    },
                },
            },
        },
    }
end

local function PositionPanel(anchor, width, height, hintHeight)
    local viewportWidth, viewportHeight = UI.GetViewportSize()
    local margin = 28
    local gap = 18
    local reservedBottom = (hintHeight or 0) + 18
    local maxLeft = viewportWidth - width - margin
    local maxTop = viewportHeight - height - reservedBottom - margin
    local left = math.floor((viewportWidth - width) * 0.5)
    local top = math.max(margin, math.min(maxTop, math.floor(viewportHeight * 0.10)))
    local alignment = "center"

    if anchor then
        local rightLeft = anchor.x + anchor.w + gap
        local leftLeft = anchor.x - width - gap
        local fitsRight = rightLeft <= maxLeft
        local fitsLeft = leftLeft >= margin

        if fitsRight or not fitsLeft then
            left = rightLeft
            alignment = "right-top"
        else
            left = leftLeft
            alignment = "left-top"
        end

        top = anchor.y
        if top > maxTop then
            top = anchor.y + anchor.h - height
            alignment = alignment == "right-top" and "right-bottom" or "left-bottom"
        end
    end

    left = math.max(margin, math.min(maxLeft, left))
    top = math.max(margin, math.min(maxTop, top))
    return math.floor(left), math.floor(top), alignment
end

function ItemTips.Configure(context)
    context_ = context
    EnsureInputListener()
end

function ItemTips.AttachRoot(root)
    RemoveLayer()
    root_ = root
end

function ItemTips.RegisterTrigger(widget, item)
    if widget and item then triggers_[widget] = item end
    return widget
end

function ItemTips.Show(item, anchor, options, expanded)
    if not item or not root_ or not context_ then return false end
    options = options or {}
    if item.id
        and type(item.decomposeRefund) ~= "table"
        and options.refundRequestPending ~= true
        and context_.requestDecomposePreview
    then
        options.refundRequestPending = true
        context_.requestDecomposePreview(item.id, function(response)
            options.refundRequestPending = false
            if response and response.ok and type(response.data) == "table" then
                item.decomposeRefund = {
                    gold = response.data.gold or 0,
                    fragments = response.data.fragments or 0,
                    rate = response.data.rate or 0,
                    vipLevel = response.data.vipLevel or 0,
                }
                if currentItem_ == item then
                    ItemTips.Show(item, anchor, options, expanded)
                end
            end
        end)
    end
    local requestedExpanded = expanded == true
    RemoveLayer()

    local compareItem = options.compareItem
    local canCompare = options.allowCompare == true
        and compareItem ~= nil
        and tostring(compareItem.id) ~= tostring(item.id)
    requestedExpanded = requestedExpanded and canCompare

    local C = context_.C
    local viewportWidth, viewportHeight = UI.GetViewportSize()
    local hintHeight = 34
    local compareWidth = requestedExpanded and 400 or 0
    local compareGap = requestedExpanded and 94 or 0
    local panelWidth = math.min(requestedExpanded and 530 or 650, viewportWidth - 56)
    local footprintWidth = panelWidth + (canCompare and 88 or 0) + compareWidth + compareGap
    footprintWidth = math.min(footprintWidth, viewportWidth - 56)
    local panelHeight = math.min(920, viewportHeight - hintHeight - 92)
    local footprintLeft, top, alignment = PositionPanel(anchor, footprintWidth, panelHeight, hintHeight)
    local opensRight = alignment:find("left", 1, true) == nil
    local left = footprintLeft
    local rowWidth = panelWidth - 83
    local rows = {}
    rows[#rows + 1] = UI.Panel {
        width = "100%",
        height = 46,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "center",
        marginTop = 4,
        marginBottom = 4,
        children = {
            UI.Panel {
                width = 5,
                height = 24,
                flexShrink = 0,
                marginRight = 10,
                cornerRadius = 2,
                backgroundColor = { 80, 173, 225, 235 },
            },
            context_.compactTxt("基础信息", 21, C.primary, {
                flexGrow = 1,
                flexBasis = 0,
                height = 34,
                textAlign = "left",
                textStroke = { width = 1, color = "#000000" },
            }),
        },
    }
    for _, row in ipairs(BuildRows(item, requestedExpanded)) do
        rows[#rows + 1] = BuildRow(row, rowWidth)
    end
    local affixNames = {}
    for _, affix in ipairs(type(item.coreAffixes) == "table" and item.coreAffixes or {}) do
        affixNames[#affixNames + 1] = AFFIX_NAMES[affix] or tostring(affix)
    end
    local uniqueEffectText = item.uniqueEffect
        and (UNIQUE_EFFECT_NAMES[item.uniqueEffect] or item.uniqueEffect)
        or nil
    local affixHeight = 174
    local descriptionHeight = 96
    local detailTop = 206
    local detailBottom = panelHeight - descriptionHeight - affixHeight - 62
    local detailHeight = math.max(140, detailBottom - detailTop - 26)
    local affixTop = detailBottom + 14
    local descriptionTop = affixTop + affixHeight + 10

    local affixChildren = {}
    if #affixNames == 0 and not uniqueEffectText then
        affixChildren[#affixChildren + 1] = context_.compactTxt("暂无核心词条", 17, C.textDim, {
            width = "100%",
            height = 28,
            textAlign = "left",
        })
    else
        for _, affixName in ipairs(affixNames) do
            affixChildren[#affixChildren + 1] = context_.compactTxt("◆ " .. affixName, 17, C.secondary, {
                width = "100%",
                height = 28,
                textAlign = "left",
                textStroke = { width = 1, color = "#000000" },
            })
        end
        if uniqueEffectText then
            affixChildren[#affixChildren + 1] = context_.compactTxt("◆ " .. uniqueEffectText, 17, C.gold, {
                width = "100%",
                height = 28,
                textAlign = "left",
                textStroke = { width = 1, color = "#000000" },
            })
        end
    end

    local slotContext = {
        C = C,
        ASSETS = context_.ASSETS,
        itemImage = context_.itemImage,
        itemLevelText = context_.itemLevelText,
        compactTxt = context_.compactTxt,
        rarityColor = context_.rarityColor,
        isEquipped = context_.isEquipped,
    }
    panel_ = UI.Panel {
        id = "itemTipsPanel",
        position = "absolute",
        left = left,
        top = top,
        width = panelWidth,
        height = panelHeight,
        zIndex = 3600,
        overflow = "hidden",
        backgroundImage = requestedExpanded
            and context_.ASSETS.ui.itemTipsMainFrameCompare
            or context_.ASSETS.ui.itemTipsMainFrame,
        backgroundFit = "contain",
        boxShadow = {
            color = { 0, 0, 0, 185 },
            offsetX = 0,
            offsetY = 12,
            blurRadius = 26,
        },
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                width = panelWidth,
                height = 7,
                pointerEvents = "none",
            },
            UI.Panel {
                position = "absolute",
                left = 1,
                top = 7,
                width = panelWidth - 2,
                height = 178,
                pointerEvents = "none",
            },
            UI.Panel {
                position = "absolute",
                left = 51,
                top = 48,
                width = 146,
                height = 143,
                children = {
                    ItemSlotBase.Build(slotContext, item, {
                        size = 142,
                        showEquipped = true,
                    }),
                },
            },
            context_.compactTxt(context_.shortenText(item.name or "未知道具", 18), 28,
                context_.rarityColor(item.rarity), {
                    position = "absolute",
                    left = 199,
                    top = 56,
                    width = panelWidth - 244,
                    height = 40,
                    textAlign = "left",
                    textStroke = { width = 2, color = "#000000" },
                }),
            context_.compactTxt(
                context_.rarityName(item.rarity)
                    .. " · " .. (item.slot and context_.slotName(item.slot) or (item.category or "道具")),
                19,
                context_.rarityColor(item.rarity),
                {
                    position = "absolute",
                    left = 204,
                    top = 107,
                    width = panelWidth - 244,
                    height = 28,
                    textAlign = "left",
                    textStroke = { width = 1, color = "#000000" },
                }
            ),
            context_.compactTxt("战力 " .. context_.itemPowerText(item), 22, C.gold, {
                position = "absolute",
                left = 204,
                top = 142,
                width = panelWidth - 244,
                height = 32,
                textAlign = "left",
                textStroke = { width = 2, color = "#000000" },
            }),
            UI.Panel {
                position = "absolute",
                right = 14,
                top = 17,
                width = 48,
                height = 48,
                clickable = true,
                backgroundImage = context_.ASSETS.ui.itemTipsCloseButton,
                backgroundFit = "contain",
                onClick = function() ItemTips.Hide("close-button") end,
                children = {
                    context_.compactTxt("×", 28, C.text, {
                        width = "100%",
                        height = 48,
                        textAlign = "center",
                        pointerEvents = "none",
                    }),
                },
            },
            UI.ScrollView {
                position = "absolute",
                left = 49,
                top = detailTop,
                width = panelWidth - 83,
                height = detailHeight,
                scrollX = false,
                scrollY = true,
                showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%",
                        height = 402,
                        top = -6,
                        paddingBottom = 8,
                        children = rows,
                    },
                },
            },
            UI.Panel {
                position = "absolute",
                left = 51,
                top = affixTop,
                width = panelWidth - 87,
                height = affixHeight,
                paddingTop = 4,
                paddingLeft = 12,
                paddingRight = 12,
                borderTopWidth = 1,
                borderTopColor = { 80, 173, 225, 180 },
                children = {
                    context_.compactTxt("核心词条", 18, C.primary, {
                        width = "100%",
                        height = 28,
                        left = -4,
                        top = -29,
                        textAlign = "left",
                        textStroke = { width = 1, color = "#000000" },
                    }),
                    UI.Panel {
                        width = "100%",
                        height = 99,
                        left = -4,
                        top = -7,
                        children = affixChildren,
                    },
                },
            },
            UI.Panel {
                position = "absolute",
                left = 51,
                top = descriptionTop,
                width = panelWidth - 87,
                height = descriptionHeight,
                paddingTop = 4,
                paddingLeft = 12,
                paddingRight = 12,
                borderTopWidth = 1,
                borderTopColor = { 80, 173, 225, 180 },
                children = {
                    context_.compactTxt("装备介绍", 18, C.primary, {
                        width = "100%",
                        height = 28,
                        top = -37,
                        textAlign = "left",
                        textStroke = { width = 1, color = "#000000" },
                    }),
                    context_.multiTxt(item.description or "暂无介绍", 17, C.textSecondary, {
                        width = "100%",
                        height = descriptionHeight - 34,
                        left = -2,
                        top = -22,
                        textAlign = "left",
                    }),
                },
            },
        },
    }
    local cornerConnector = nil
    if anchor then
        local connectorLeft = opensRight and (left - 18) or (left + footprintWidth)
        local connectorTop = alignment:find("bottom", 1, true)
            and (top + panelHeight - 4)
            or (top + 1)
        cornerConnector = UI.Panel {
            position = "absolute",
            left = connectorLeft,
            top = connectorTop,
            width = 18,
            height = 3,
            backgroundColor = context_.rarityColor(item.rarity),
            pointerEvents = "none",
        }
    end

    if canCompare then
        compareButton_ = UI.Panel {
            id = "itemTipsCompareButton",
            position = "absolute",
            left = left + panelWidth + 14,
            top = top + 24,
            width = 66,
            height = 74,
            clickable = true,
            backgroundImage = context_.ASSETS.ui.itemTipsCompareButton,
            backgroundFit = "contain",
            onClick = function()
                ItemTips.Show(item, anchor, options, not requestedExpanded)
            end,
            children = {
                context_.compactTxt(requestedExpanded and "收起" or "对比", 18, C.text, {
                    width = "100%",
                    height = 74,
                    textAlign = "center",
                    textStroke = { width = 1, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        }
    end

    if requestedExpanded and compareItem then
        comparePanel_ = BuildComparePanel(
            item,
            compareItem,
            compareWidth,
            panelHeight,
            left + footprintWidth - compareWidth,
            top
        )
    end

    local outsideHint = context_.compactTxt(
        "再次点击其他道具可直接切换 · 点击空白区域关闭",
        16,
        C.textDim,
        {
            position = "absolute",
            left = footprintLeft,
            top = top + panelHeight + 10,
            width = footprintWidth,
            height = hintHeight,
            textAlign = "center",
            pointerEvents = "none",
            textStroke = { width = 1, color = "#000000" },
        }
    )
    local layerChildren = { panel_, outsideHint }
    if cornerConnector then layerChildren[#layerChildren + 1] = cornerConnector end
    if compareButton_ then layerChildren[#layerChildren + 1] = compareButton_ end
    if comparePanel_ then layerChildren[#layerChildren + 1] = comparePanel_ end
    layer_ = UI.Panel {
        id = "itemTipsLayer",
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        zIndex = 3500,
        pointerEvents = "box-none",
        children = layerChildren,
    }
    currentItem_ = item
    currentAnchor_ = anchor
    currentOptions_ = options
    compareExpanded_ = requestedExpanded
    root_:AddChild(layer_)
    panel_:Animate {
        keyframes = {
            [0] = { opacity = 0, scale = 0.92, translateY = 16 },
            [1] = { opacity = 1, scale = 1.0, translateY = 0 },
        },
        duration = 0.18,
        easing = "easeOut",
    }
    print("[ItemTips] show item=" .. tostring(item.id or item.name))
    return true
end

function ItemTips.Hide(reason)
    if panel_ then
        print("[ItemTips] hide reason=" .. tostring(reason or "unknown"))
    end
    RemoveLayer()
end

function ItemTips.IsVisible()
    return panel_ ~= nil
end

function ItemTips.GetCurrentItem()
    return currentItem_
end

function ItemTips.Stop()
    RemoveLayer()
    if pointerDownListener_ then
        Input.Off(PointerEvent.Types.PointerDown, pointerDownListener_)
        pointerDownListener_ = nil
    end
    triggers_ = setmetatable({}, { __mode = "k" })
    root_ = nil
    context_ = nil
end

return ItemTips
