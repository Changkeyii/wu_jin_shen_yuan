local ItemTipData = {}

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

function ItemTipData.Percent(value)
    return string.format("%.1f%%", (tonumber(value) or 0) * 100)
end

function ItemTipData.BuildRows(item, compactForCompare, ports)
    local C = ports.colors
    local formatInt = ports.formatInt
    local rows = {}
    AddRow(rows, "等级", formatInt(item.level or 1), C.textSecondary)
    AddRow(rows, "强化", "+" .. tostring(item.enhance or 0), C.gold)
    AddRow(rows, "星级", tostring(item.star or 0) .. " 星", C.gold)
    local setText = item.setEnabled == false
        and "未激活"
        or (item.setName or (item.setId and tostring(item.setId)) or "散件")
    AddRow(rows, "套装", setText, item.setEnabled == false and C.textDim or C.textSecondary)
    AddRow(rows, "数量", formatInt(item.quantity or 1), C.textSecondary)

    if not compactForCompare then
        if item.atkBig or (item.atk or 0) > 0 then
            AddRow(rows, "攻击", formatInt(item.atkBig or item.atk), C.primary)
        end
        if item.defBig or (item.def or 0) > 0 then
            AddRow(rows, "防御", formatInt(item.defBig or item.def), C.textSecondary)
        end
        if item.hpBig or (item.hp or 0) > 0 then
            AddRow(rows, "生命", formatInt(item.hpBig or item.hp), C.hp)
        end
        if (item.crit or 0) > 0 then AddRow(rows, "暴击率", ItemTipData.Percent(item.crit), C.gold) end
        if (item.critDmg or 0) > 0 then AddRow(rows, "暴击伤害", ItemTipData.Percent(item.critDmg), C.gold) end
        if (item.atkSpeed or 0) > 0 then AddRow(rows, "攻击速度", ItemTipData.Percent(item.atkSpeed), C.mp) end
        if (item.lifeSteal or 0) > 0 then AddRow(rows, "生命偷取", ItemTipData.Percent(item.lifeSteal), C.success) end
        if (item.damageReduction or 0) > 0 then AddRow(rows, "伤害减免", ItemTipData.Percent(item.damageReduction), C.success) end
        if (item.bossDamage or 0) > 0 then AddRow(rows, "首领伤害", ItemTipData.Percent(item.bossDamage), C.error) end
    end

    local state = {}
    if ports.isEquipped(item) then state[#state + 1] = "已穿戴" end
    if item.locked then state[#state + 1] = "已锁定" end
    if item.aidLocked then
        state[#state + 1] = item.aidFloor
            and ("援助占用 · 第 " .. formatInt(item.aidFloor) .. " 层")
            or "援助占用"
    end
    AddRow(rows, "状态", #state > 0 and table.concat(state, " · ") or "可用", #state > 0 and C.gold or C.success)
    AddRow(
        rows,
        "交易",
        item.tradeable == true and "可交易" or "不可交易",
        item.tradeable == true and C.success or C.textDim
    )
    AddRow(rows, "来源", SOURCE_NAMES[item.source] or "其他途径", C.textSecondary)
    local refund = ports.decomposeRefund
    AddRow(
        rows,
        "分解返还",
        refund
            and ("金币 " .. formatInt(refund.gold or 0)
                .. " / 碎片 " .. formatInt(refund.fragments or 0)
                .. "（" .. tostring(math.floor((refund.rate or 0) * 100)) .. "%）")
            or "正在获取真实返还…",
        C.textSecondary,
        { full = true }
    )
    return rows
end

function ItemTipData.BuildCompareRows(candidate, equipped, itemPower)
    return {
        { "战力", itemPower(candidate), itemPower(equipped), false },
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
end

function ItemTipData.CompareValues(left, right, compareMagnitude)
    if compareMagnitude then return compareMagnitude(left or 0, right or 0) end
    left = tonumber(left) or 0
    right = tonumber(right) or 0
    if left == right then return 0 end
    return left > right and 1 or -1
end

function ItemTipData.AffixName(affix)
    return AFFIX_NAMES[affix] or tostring(affix)
end

function ItemTipData.UniqueEffectName(effect)
    return UNIQUE_EFFECT_NAMES[effect] or tostring(effect)
end

return ItemTipData
