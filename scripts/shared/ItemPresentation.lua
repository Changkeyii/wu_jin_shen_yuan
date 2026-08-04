local ItemPresentation = {}

local CATEGORY_NAMES = {
    weapon = "武器",
    armor = "防具",
    jewelry = "首饰",
    special = "特殊",
    consumable = "消耗品",
    material = "材料",
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

local TRADEABLE_PREFIX = "【可交易】"

function ItemPresentation.CategoryName(category)
    return CATEGORY_NAMES[category] or "道具"
end

function ItemPresentation.SourceName(source)
    return SOURCE_NAMES[source] or "其他途径"
end

function ItemPresentation.DisplayName(item, fallback)
    item = type(item) == "table" and item or {}
    local name = tostring(item.rawName or item.name or fallback or "未知道具")
    while name:sub(1, #TRADEABLE_PREFIX) == TRADEABLE_PREFIX do
        name = name:sub(#TRADEABLE_PREFIX + 1)
    end
    if item.tradeable == true then
        return TRADEABLE_PREFIX .. name
    end
    return name
end

return ItemPresentation
