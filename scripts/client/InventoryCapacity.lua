-- InventoryCapacity.lua
-- 客户端背包容量：基础 300 + 广告解锁加成（最多 +700 = 1000）。

local GameStatePolicy = require("shared.GameStatePolicy")

local InventoryCapacity = {}

local BASE = GameStatePolicy.INVENTORY_CAP or 300
local PER_AD = GameStatePolicy.INVENTORY_EXPAND_PER_AD or 50
local MAX_BONUS = GameStatePolicy.INVENTORY_EXPAND_MAX_BONUS or 700
local AD_PER_DAY = GameStatePolicy.INVENTORY_EXPAND_AD_PER_DAY or 5

function InventoryCapacity.Base()
    return BASE
end

function InventoryCapacity.PerAd()
    return PER_AD
end

function InventoryCapacity.MaxBonus()
    return MAX_BONUS
end

function InventoryCapacity.AdPerDay()
    return AD_PER_DAY
end

function InventoryCapacity.Bonus(game)
    game = game or {}
    return math.max(0, math.min(MAX_BONUS, math.floor(tonumber(game.inventoryBonusSlots) or 0)))
end

function InventoryCapacity.Capacity(game)
    if game and tonumber(game.inventoryCapacity) and tonumber(game.inventoryCapacity) > 0 then
        -- 服务端快照优先；同时用 bonus 兜底纠正。
        local serverCap = math.floor(tonumber(game.inventoryCapacity))
        local localCap = BASE + InventoryCapacity.Bonus(game)
        return math.max(serverCap, localCap)
    end
    return BASE + InventoryCapacity.Bonus(game)
end

function InventoryCapacity.Used(game)
    game = game or {}
    if tonumber(game.equipmentInventoryCount) then
        return math.max(0, math.floor(tonumber(game.equipmentInventoryCount)))
    end
    return type(game.inventory) == "table" and #game.inventory or 0
end

function InventoryCapacity.Free(game)
    return math.max(0, InventoryCapacity.Capacity(game) - InventoryCapacity.Used(game))
end

function InventoryCapacity.IsFull(game)
    return InventoryCapacity.Free(game) <= 0
end

function InventoryCapacity.CanExpand(game)
    return InventoryCapacity.Bonus(game) < MAX_BONUS
end

function InventoryCapacity.TodayAdRemaining(game)
    game = game or {}
    local expand = type(game.inventoryExpand) == "table" and game.inventoryExpand or {}
    local used = math.max(0, math.floor(tonumber(expand.adUsed) or 0))
    -- 跨日重置展示：若 dayKey 不是今天，则剩余按满额显示。
    local dayKey = math.floor(tonumber(expand.adDayKey) or 0)
    local today = dayKey
    local ok, ServerClock = pcall(require, "client.ServerClock")
    if ok and ServerClock and ServerClock.DayKey then
        today = ServerClock.DayKey()
    end
    if dayKey ~= today then
        used = 0
    end
    return math.max(0, AD_PER_DAY - used), used
end

function InventoryCapacity.SummaryText(game)
    return string.format("装备 %d / %d", InventoryCapacity.Used(game), InventoryCapacity.Capacity(game))
end

return InventoryCapacity
