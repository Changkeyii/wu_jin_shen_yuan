local Catalog = require("server.domain.Catalog")
local LargeNumber = require("shared.LargeNumber")

local EquipmentDisposition = {}

local VALID_MODES = {
    sell = true,
    decompose = true,
}

local function EquippedIds(state)
    local result = {}
    for _, itemId in pairs(state.equipped or {}) do
        result[tostring(itemId)] = true
    end
    return result
end

local function InventoryById(state)
    local result = {}
    for _, item in ipairs(state.inventory or {}) do
        result[tostring(item.id)] = item
    end
    return result
end

local function AddAmount(left, right)
    return LargeNumber.Add(left, right)
end

function EquipmentDisposition.Preview(state, mode, candidateIds)
    if type(state) ~= "table" then
        return { ok = false, code = "PROFILE_NOT_LOADED", reason = "profile is not loaded" }
    end
    if not VALID_MODES[mode] then
        return { ok = false, code = "INVALID_ARGUMENT", reason = "unsupported disposition mode" }
    end
    if type(candidateIds) ~= "table" or #candidateIds == 0 then
        return { ok = false, code = "INVALID_ARGUMENT", reason = "candidateIds must not be empty" }
    end

    local inventory = InventoryById(state)
    local equipped = EquippedIds(state)
    local seen = {}
    local quotes = {}
    local rejected = {}
    local totalGold = LargeNumber.Zero()
    local totalFragments = LargeNumber.Zero()

    for _, itemId in ipairs(candidateIds) do
        local key = tostring(itemId)
        local item = inventory[key]
        local rarity = item and Catalog.RARITIES[item.rarity] or nil
        local reason = nil
        if seen[key] then
            reason = "DUPLICATE_ITEM"
        elseif not item then
            reason = "ITEM_NOT_FOUND"
        elseif equipped[key] or item.locked or item.aidLocked then
            reason = "ITEM_PROTECTED"
        elseif not rarity or rarity.rank >= #Catalog.RARITY_ORDER then
            reason = "RARITY_PROTECTED"
        end
        seen[key] = true

        if reason then
            rejected[#rejected + 1] = { itemId = key, reason = reason }
        elseif mode == "sell" then
            local gold = Catalog.GetSellValue(item, state.vipLevel)
            quotes[#quotes + 1] = {
                itemId = key,
                gold = gold,
                fragments = LargeNumber.Zero(),
            }
            totalGold = AddAmount(totalGold, gold)
        else
            local refund = Catalog.GetDecomposeRefund(item, state.vipLevel)
            quotes[#quotes + 1] = {
                itemId = key,
                gold = refund.gold,
                fragments = refund.fragments,
                rate = refund.rate,
                investedGoldRate = refund.investedGoldRate,
                fragmentRate = refund.fragmentRate,
            }
            totalGold = AddAmount(totalGold, refund.gold)
            totalFragments = AddAmount(totalFragments, refund.fragments)
        end
    end

    print("[EquipmentDisposition] preview mode=" .. mode
        .. " requested=" .. tostring(#candidateIds)
        .. " quoted=" .. tostring(#quotes)
        .. " rejected=" .. tostring(#rejected)
        .. " gold=" .. LargeNumber.ToString(totalGold)
        .. " fragments=" .. LargeNumber.ToString(totalFragments))

    return {
        ok = true,
        data = {
            mode = mode,
            items = quotes,
            rejected = rejected,
            totalGold = totalGold,
            totalFragments = totalFragments,
            vipLevel = math.max(0, math.floor(tonumber(state.vipLevel) or 0)),
        },
    }
end

return EquipmentDisposition
