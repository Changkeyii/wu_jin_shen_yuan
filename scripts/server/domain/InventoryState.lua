local Catalog = require("server.domain.Catalog")
local BigNumber = require("shared.BigNumber")
local GameStateSchema = require("shared.GameStateSchema")

local InventoryState = {}

function InventoryState.RecordCollection(state, item)
    if not item or not item.equipmentId then return end
    state.equipmentCollection = state.equipmentCollection or {}
    local powerBig = BigNumber.Normalize(Catalog.GetItemPower(item))
    local record = state.equipmentCollection[item.equipmentId]
    if not record or BigNumber.Compare(powerBig, record.powerBig) > 0 then
        state.equipmentCollection[item.equipmentId] = {
            powerBig = powerBig,
            level = item.level,
            enhance = item.enhance,
            star = item.star,
            rarity = item.rarity,
        }
    end
end

function InventoryState.UpdateCollection(state)
    for _, item in ipairs(state.inventory or {}) do InventoryState.RecordCollection(state, item) end
    for _, item in ipairs(state.overflowLoot or {}) do InventoryState.RecordCollection(state, item) end
end

function InventoryState.RemoveFromLootStash(state, itemId)
    local kept = {}
    for _, value in ipairs(state.lootStash or {}) do
        if tostring(value) ~= tostring(itemId) then kept[#kept + 1] = value end
    end
    state.lootStash = kept
end

function InventoryState.AddToLootStash(state, itemId)
    if itemId == nil then return end
    state.lootStash = state.lootStash or {}
    InventoryState.RemoveFromLootStash(state, itemId)
    state.lootStash[#state.lootStash + 1] = itemId
    while #state.lootStash > GameStateSchema.LOOT_STASH_CAP do
        table.remove(state.lootStash, 1)
    end
end

function InventoryState.PruneLootStash(state)
    local existing = {}
    for _, item in ipairs(state.inventory or {}) do existing[tostring(item.id)] = true end
    local kept = {}
    for _, itemId in ipairs(state.lootStash or {}) do
        if existing[tostring(itemId)] then kept[#kept + 1] = itemId end
    end
    state.lootStash = kept
end

return InventoryState
