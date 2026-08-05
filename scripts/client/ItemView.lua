-- ItemView.lua
-- 物品相关视图辅助函数。
-- 从 GameView.lua 抽出：稀有度、槽位、物品属性格式化等与装备/道具显示相关的纯工具函数。

local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local ViewKit = require("client.ViewKit")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local BigNumber = require("shared.BigNumber")

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
    for _, item in ipairs(game.inventory or {}) do
        if tostring(item.id) == tostring(id) then return item end
    end
    return nil
end

local function IsEquipped(game, item)
    if not item then return false end
    for _, equipped in pairs(game.equipped or {}) do
        if equipped and tostring(equipped.id) == tostring(item.id) then return true end
    end
    return false
end

local function ItemImage(item)
    if not item then return ASSETS.items.chest end
    if item.category == "consumable" then return ASSETS.items.potion end
    if item.category == "material" then return ASSETS.items.crystal end
    local definition = item.equipmentId and EquipmentCatalog.Get(item.equipmentId)
    if definition and definition.icon then return definition.icon end
    return ASSETS.items.chest
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

return ItemView
