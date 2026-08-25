-- ItemView.lua
-- 物品相关视图辅助函数。
-- 从 GameView.lua 抽出：稀有度、槽位、物品属性格式化等与装备/道具显示相关的纯工具函数。

local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local ViewKit = require("client.ViewKit")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local BigNumber = require("shared.BigNumber")

local SET_TIERS = { 3, 6, 9, 12 }

local RARITIES = GameTheme.Rarities
local SLOTS = GameTheme.Slots
local ASSETS = ViewAssets.ASSETS

local ItemView = {}

local function RarityColor(rarity)
    return (RARITIES[rarity] and RARITIES[rarity].color) or GameTheme.Colors.textSecondary
end

local function RarityName(rarity)
    return (RARITIES[rarity] and RARITIES[rarity].name) or "未知"
end

local function SlotById(id)
    for _, slot in ipairs(SLOTS) do
        if slot.id == id then return slot end
    end
    return nil
end

local function SlotName(id)
    local slot = SlotById(id)
    return slot and slot.name or id
end

local function ItemLevelText(item)
    return "Lv" .. tostring(item and (item.level or 1) or 1)
end

local function ItemPower(item)
    if not item then return 0 end
    -- Equipment comparison is server-authoritative in V5. These are aliases
    -- for evaluated values emitted by PowerEvaluator, never a local formula.
    if item.power ~= nil then return item.power end
    if item.displayedPower ~= nil then return item.displayedPower end
    if item.evaluatedPower ~= nil then return item.evaluatedPower end
    if item.powerContribution ~= nil then return item.powerContribution end
    if item.category == "material" or item.category == "consumable" then return item.quantity or 1 end
    return 0
end

local function ItemPowerText(item)
    if not item then return "待评估" end
    if item.power == nil and item.displayedPower == nil and item.evaluatedPower == nil and item.powerContribution == nil
        and item.category ~= "material" and item.category ~= "consumable" then
        return "待评估"
    end
    return ViewKit.FormatInt(ItemPower(item))
end

-- GetItemById 和 IsEquipped 需要实时访问 game，不能在模块加载时捕获
local function GetItemById(game, id)
    if id == nil then return nil end
    local indexed = game and game.itemById
    if type(indexed) == "table" then
        local item = indexed[tostring(id)]
        if item ~= nil then return item end
    end
    for _, item in ipairs((game and game.inventory) or {}) do
        if tostring(item.id) == tostring(id) then return item end
    end
    return nil
end

local function IsEquipped(game, item)
    if not item then return false end
    local indexed = game and game.equippedSlotByItemId
    if type(indexed) == "table" and indexed[tostring(item.id)] ~= nil then return true end
    if item.isEquipped ~= nil then return item.isEquipped == true end
    for _, equipped in pairs((game and game.equipped) or {}) do
        if equipped and tostring(equipped.id) == tostring(item.id) then return true end
    end
    return false
end

local function ItemImage(item)
    if not item then return ASSETS.items.chest end
    if item.category == "consumable" then return item.icon or ASSETS.items.potion end
    if item.category == "material" then return item.icon or ASSETS.items.crystal end
    if item.category == "wishjar" then return item.icon or ASSETS.items.chest end
    local definition = item.equipmentId and EquipmentCatalog.Get(item.equipmentId)
    if definition and definition.icon then return definition.icon end
    return ASSETS.items.chest
end

local function CompareItemPower(left, right)
    return BigNumber.Compare(ItemPower(left), ItemPower(right))
end

local function reachesSetTier(count)
    for _, tier in ipairs(SET_TIERS) do
        if count + 1 == tier then return true end
    end
    return false
end

-- 与服务端一键穿戴一致：12 部位各自找背包里战力最高的未锁装备。
-- 另外：套装差 1 件就能激活（3/6/9/12 或防具/首饰/特殊 3 件）时，缺的那件部位也提示。
-- 当前部位已锁 / 教学锁则跳过，不提示替换。
function ItemView.BetterUnequippedSlots(game)
    game = type(game) == "table" and game or {}
    local flags = game.uiFlags
    if type(flags) == "table" and type(flags.betterUnequippedSlots) == "table" then
        return flags.betterUnequippedSlots
    end
    local equipped = type(game.equipped) == "table" and game.equipped or {}
    local better = {}
    local equippedCountBySet = {}
    local equippedRegionBySet = {}
    local equippedSetBySlot = {}

    for slotId, current in pairs(equipped) do
        if current and current.setEnabled == true and current.setId then
            local setId = current.setId
            equippedCountBySet[setId] = (equippedCountBySet[setId] or 0) + 1
            equippedSetBySlot[slotId] = setId
            local region = EquipmentCatalog.REGION_BY_SLOT[slotId] or current.region
            if region then
                equippedRegionBySet[setId] = equippedRegionBySet[setId] or {}
                equippedRegionBySet[setId][region] = (equippedRegionBySet[setId][region] or 0) + 1
            end
        end
    end

    for _, item in ipairs(game.inventory or {}) do
        if item
            and item.slot
            and item.equipmentId
            and not item.aidLocked
            and not IsEquipped(game, item)
        then
            local current = equipped[item.slot]
            local locked = current and (current.locked or current.aidLocked)
            if not locked then
                if not current or CompareItemPower(item, current) > 0 then
                    better[item.slot] = true
                elseif item.setEnabled == true and item.setId
                    and equippedSetBySlot[item.slot] ~= item.setId
                then
                    local setId = item.setId
                    local count = equippedCountBySet[setId] or 0
                    local region = EquipmentCatalog.REGION_BY_SLOT[item.slot] or item.region
                    local regionCount = 0
                    if region and equippedRegionBySet[setId] then
                        regionCount = equippedRegionBySet[setId][region] or 0
                    end
                    local completesRegion = region ~= nil
                        and region ~= "weapon"
                        and regionCount + 1 == 3
                    if reachesSetTier(count) or completesRegion then
                        better[item.slot] = true
                    end
                end
            end
        end
    end
    return better
end

function ItemView.HasBetterUnequipped(game)
    game = type(game) == "table" and game or {}
    local flags = game.uiFlags
    if type(flags) == "table" and flags.hasBetterUnequipped ~= nil then
        return flags.hasBetterUnequipped == true
    end
    return next(ItemView.BetterUnequippedSlots(game)) ~= nil
end

ItemView.RarityColor = RarityColor
ItemView.RarityName = RarityName
ItemView.SlotById = SlotById
ItemView.SlotName = SlotName
ItemView.ItemLevelText = ItemLevelText
ItemView.ItemPower = ItemPower
ItemView.ItemPowerText = ItemPowerText
ItemView.GetItemById = GetItemById
ItemView.IsEquipped = IsEquipped
ItemView.ItemImage = ItemImage
ItemView.CompareItemPower = CompareItemPower

return ItemView
