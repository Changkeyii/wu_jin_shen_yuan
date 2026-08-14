--- 市场领域层：玩家存档侧的纯状态迁移。
---
--- 职责边界：
---   本模块只负责"背包 <-> 挂单镜像 <-> 信箱领取"在**单个玩家存档内**的变化，
---   并附带该次变更需要一起提交的云账本操作（proposal.cloudOperations）。
---   跨玩家的结算、并发争抢、扫货由 server/services/MarketService.lua 负责。
---
--- 关键约束：绝不在这里读写其他玩家的存档。
local Catalog = require("server.domain.Catalog")
local GameEngine = require("server.domain.GameEngine")
local MarketCatalog = require("shared.MarketCatalog")
local ItemTradeRules = require("shared.ItemTradeRules")
local LargeNumber = require("shared.LargeNumber")
local TableUtils = require("server.domain.TableUtils")

local Internal = GameEngine.Internal
local stateCopy = Internal.stateCopy
local finalize = Internal.finalize
local noCommit = Internal.noCommit
local failure = Internal.failure
local event = Internal.event
local findItem = Internal.findItem
local equippedIdSet = Internal.equippedIdSet
local addCurrency = Internal.addCurrency
local hasCurrency = Internal.hasCurrency
local spendCurrency = Internal.spendCurrency

local MarketEngine = {}

--- 云账本所有者。所有挂单集中挂在这个保留 uid 下，按品质/部位分桶。
MarketEngine.LEDGER_UID = 1
MarketEngine.MAIL_KEY = "mk:mail"

---@param state table
---@param itemId string
---@return integer|nil
local function findListingIndex(state, itemId)
    for index, listing in ipairs(state.marketListings or {}) do
        if listing.itemId == itemId then return index end
    end
    return nil
end

--- 构造存入云账本的挂单记录。买家看到的就是这份数据。
---@param item table
---@param sellerUid number
---@param price table|number|string
---@param feeRate number
---@param now integer
---@return table
function MarketEngine.BuildListingRecord(item, sellerUid, price, feeRate, now)
    local normalizedPrice = MarketCatalog.NormalizePrice(price)
    local standardValue = Catalog.GetMarketStandardValue(item)
    local minimumPrice = MarketCatalog.GetMinimumListingPrice(
        standardValue,
        item.rarity
    )
    local feeUnits = math.max(0, math.min(
        MarketCatalog.FEE_RATE_SCALE,
        math.floor((tonumber(feeRate) or 0)
            * MarketCatalog.FEE_RATE_SCALE + 0.5)
    ))
    return {
        itemId = item.id,
        sellerUid = sellerUid,
        price = normalizedPrice,
        standardValue = standardValue,
        minimumPrice = minimumPrice,
        minimumPriceVersion = MarketCatalog.MINIMUM_PRICE_VERSION,
        tradeableChanceUnits = ItemTradeRules.GetTradeableChanceUnits(
            item.rarity
        ),
        feeRate = feeUnits / MarketCatalog.FEE_RATE_SCALE,
        feeUnits = feeUnits,
        rarity = item.rarity,
        slot = item.slot,
        level = math.max(1, math.floor(tonumber(item.level) or 1)),
        listedAt = now,
        expiresAt = now + MarketCatalog.LISTING_DURATION_SECONDS,
        item = TableUtils.DeepCopy(item),
    }
end

--- 上架。装备离开背包，写入云账本；两者在同一个 BatchCommit 内完成。
---@param inputState table
---@param payload { itemId: string, price: table|number|string, sellerUid: number }
---@param now integer
---@return table
function MarketEngine.List(inputState, payload, now)
    local itemId = payload.itemId
    local validPrice, priceReason, normalizedPrice = MarketCatalog.ValidatePrice(payload.price)
    if not validPrice or not normalizedPrice then
        return failure(inputState, now, "INVALID_PRICE", priceReason)
    end
    local price = normalizedPrice

    local item = findItem(inputState, itemId)
    if not item then
        return failure(inputState, now, "ITEM_NOT_FOUND", "装备不存在")
    end
    if not MarketCatalog.IsListableRarity(item.rarity) then
        return failure(inputState, now, "RARITY_NOT_LISTABLE", "仅神器及以上装备可以上架")
    end
    if type(item.equipmentId) ~= "string" or item.tradeable ~= true then
        return failure(inputState, now, "ITEM_NOT_TRADABLE", "该装备没有可交易资格")
    end

    local standardValue = Catalog.GetMarketStandardValue(item)
    local meetsMinimum, minimumPrice = MarketCatalog.MeetsMinimumListingPrice(
        price,
        standardValue,
        item.rarity
    )
    if not meetsMinimum then
        return failure(inputState, now, "PRICE_BELOW_MINIMUM", string.format(
            "该装备最低上架价为 %s 金币",
            LargeNumber.ToString(minimumPrice)
        ))
    end

    local equipped = equippedIdSet(inputState)
    if equipped[itemId] then
        return failure(inputState, now, "ITEM_NOT_TRADABLE", "已穿戴的装备无法上架")
    end
    if item.locked or item.aidLocked then
        return failure(inputState, now, "ITEM_NOT_TRADABLE", "已锁定或援助获得的装备无法上架")
    end

    local listings = inputState.marketListings or {}
    local slots = MarketCatalog.GetListingSlots(inputState.vipLevel)
    if #listings >= slots then
        return failure(inputState, now, "LISTING_SLOTS_FULL",
            string.format("挂单已满（%d/%d），提升 VIP 可增加格位", #listings, slots))
    end

    local working = stateCopy(inputState, now)
    local kept = {}
    local removed = nil
    for _, value in ipairs(working.inventory) do
        if value.id == itemId then removed = value else kept[#kept + 1] = value end
    end
    if not removed then
        return failure(inputState, now, "ITEM_NOT_FOUND", "装备不存在")
    end
    working.inventory = kept

    local feeRate = MarketCatalog.GetFeeRate(working.vipLevel)
    local record = MarketEngine.BuildListingRecord(removed, payload.sellerUid, price, feeRate, now)

    working.marketListings = working.marketListings or {}
    working.marketListings[#working.marketListings + 1] = {
        itemId = record.itemId,
        price = record.price,
        standardValue = record.standardValue,
        minimumPrice = record.minimumPrice,
        minimumPriceVersion = record.minimumPriceVersion,
        tradeableChanceUnits = record.tradeableChanceUnits,
        feeRate = record.feeRate,
        feeUnits = record.feeUnits,
        rarity = record.rarity,
        slot = record.slot,
        level = record.level,
        name = removed.name,
        listedAt = record.listedAt,
        expiresAt = record.expiresAt,
    }

    local proposal = finalize(inputState, working, now, "market_listed", {
        event("market_listed", {
            itemId = record.itemId,
            price = record.price,
            feeRate = record.feeRate,
            standardValue = record.standardValue,
            willBeSwept = MarketCatalog.WillBeSwept(record.price, record.standardValue),
        }),
    }, true, false)

    proposal.cloudOperations = {
        {
            kind = "list_add",
            userId = MarketEngine.LEDGER_UID,
            key = MarketCatalog.BucketKey(record.rarity, record.slot),
            value = record,
        },
    }
    proposal.market = { listingRecord = record }
    return proposal
end

--- 下架。需要先由 MarketService 从云账本取回记录并确认仍然存在。
---@param inputState table
---@param payload { itemId: string, record: table, cloudListId: integer }
---@param now integer
---@return table
function MarketEngine.Cancel(inputState, payload, now)
    local index = findListingIndex(inputState, payload.itemId)
    if not index then
        return failure(inputState, now, "LISTING_NOT_FOUND", "挂单不存在")
    end
    local record = payload.record
    if type(record) ~= "table" or type(record.item) ~= "table" then
        return failure(inputState, now, "LISTING_GONE", "挂单已被买走或已下架")
    end
    if #inputState.inventory >= Catalog.GetInventoryCapacity(inputState) then
        return failure(inputState, now, "INVENTORY_FULL", "背包已满，无法取回装备")
    end

    local working = stateCopy(inputState, now)
    table.remove(working.marketListings, index)
    working.inventory[#working.inventory + 1] = TableUtils.DeepCopy(record.item)

    local proposal = finalize(inputState, working, now, "market_cancelled", {
        event("market_cancelled", { itemId = payload.itemId, price = record.price }),
    }, true, false)

    proposal.cloudOperations = {
        { kind = "list_delete", listId = payload.cloudListId },
    }
    return proposal
end

--- 买家扣款。装备不直接进背包，而是走信箱，保证与卖家侧完全对称。
---@param inputState table
---@param payload { record: table, cloudListId: integer, buyerUid: number }
---@param now integer
---@return table
function MarketEngine.Purchase(inputState, payload, now)
    local record = payload.record
    if type(record) ~= "table" or type(record.item) ~= "table" then
        return failure(inputState, now, "LISTING_GONE", "挂单已被买走或已下架")
    end
    if not MarketCatalog.IsListableItem(record.item) then
        return failure(inputState, now, "LISTING_GONE", "挂单物品不再符合交易规则")
    end
    if record.sellerUid == payload.buyerUid then
        return failure(inputState, now, "SELF_PURCHASE", "不能购买自己的挂单")
    end

    local validPrice, priceReason, normalizedPrice = MarketCatalog.ValidatePrice(record.price)
    if not validPrice or not normalizedPrice then
        return failure(inputState, now, "INVALID_PRICE", priceReason or "挂单价格异常")
    end
    local price = normalizedPrice
    local standardValue = Catalog.GetMarketStandardValue(record.item)
    local meetsMinimum = MarketCatalog.MeetsMinimumListingPrice(
        price,
        standardValue,
        record.item.rarity
    )
    if not meetsMinimum then
        return failure(inputState, now, "PRICE_BELOW_MINIMUM",
            "挂单价格低于该装备的最低上架价")
    end

    if not MarketCatalog.CanPurchaseLevel(record.level, inputState.floor) then
        return failure(inputState, now, "LEVEL_GATE_BLOCKED", string.format(
            "当前层数仅可购买 %d 级以内的装备",
            MarketCatalog.GetPurchaseLevelCap(inputState.floor)))
    end
    if not hasCurrency(inputState, "gold", price) then
        return failure(inputState, now, "INSUFFICIENT_GOLD", "金币不足")
    end
    if #inputState.inventory >= Catalog.GetInventoryCapacity(inputState) then
        return failure(inputState, now, "INVENTORY_FULL", "背包已满，无法购买")
    end

    local working = stateCopy(inputState, now)
    if not spendCurrency(working, "gold", price) then
        return failure(inputState, now, "INSUFFICIENT_GOLD", "金币不足")
    end
    working.inventory[#working.inventory + 1] = TableUtils.DeepCopy(record.item)

    -- 手续费按卖家挂单时快照的费率结算，避免卖家 VIP 变动引发争议。
    local feeUnits = record.feeUnits
    if feeUnits == nil then
        feeUnits = math.floor(
            math.max(0, math.min(1,
                tonumber(record.feeRate) or MarketCatalog.BASE_FEE_RATE))
                * MarketCatalog.FEE_RATE_SCALE + 0.5
        )
    end
    local settlement = MarketCatalog.GetFeeBreakdownFromUnits(price, feeUnits)
    local fee = settlement.fee
    local proceeds = settlement.proceeds
    local sellerFeeRate = settlement.rate

    local proposal = finalize(inputState, working, now, "market_purchased", {
        event("market_purchased", {
            itemId = record.itemId,
            price = price,
            sellerUid = record.sellerUid,
        }),
    }, true, false)

    proposal.cloudOperations = {
        { kind = "list_delete", listId = payload.cloudListId },
        {
            kind = "list_add",
            userId = record.sellerUid,
            key = MarketEngine.MAIL_KEY,
            value = {
                kind = "sold",
                itemId = record.itemId,
                price = price,
                fee = fee,
                gold = proceeds,
                feeRate = sellerFeeRate,
                buyerUid = payload.buyerUid,
                at = now,
            },
        },
    }
    proposal.market = { settlement = { price = price, fee = fee, proceeds = proceeds } }
    return proposal
end

--- 领取信箱。金币入账、装备入包、并清理已成交的挂单镜像。
---@param inputState table
---@param payload { mails: table[] }
---@param now integer
---@return table
function MarketEngine.CollectMail(inputState, payload, now)
    local mails = payload.mails or {}
    if #mails == 0 then
        return noCommit(inputState, now, "market_mail_empty")
    end

    local working = stateCopy(inputState, now)
    local capacity = Catalog.GetInventoryCapacity(working) - #working.inventory
    local collected = {}
    local totalGold = LargeNumber.Zero()
    local items = 0
    local skipped = 0

    for _, mail in ipairs(mails) do
        local value = mail.value
        local canTake = true
        if type(value) ~= "table" then
            canTake = false
        elseif type(value.item) == "table" then
            -- 需要占用背包格位，容量不足则留在信箱里等下次。
            if capacity <= 0 then canTake = false end
        end

        if canTake and type(value) == "table" then
            local gold = MarketCatalog.NormalizePrice(value.gold)
            if not LargeNumber.IsZero(gold) then
                addCurrency(working, "gold", gold)
                totalGold = LargeNumber.Add(totalGold, gold)
            end
            if type(value.item) == "table" then
                working.inventory[#working.inventory + 1] = TableUtils.DeepCopy(value.item)
                capacity = capacity - 1
                items = items + 1
            end
            local index = findListingIndex(working, value.itemId)
            if index then table.remove(working.marketListings, index) end
            collected[#collected + 1] = mail.cloudListId
        else
            skipped = skipped + 1
        end
    end

    if #collected == 0 then
        return failure(inputState, now, "INVENTORY_FULL", "背包已满，无法领取信箱物品")
    end

    local proposal = finalize(inputState, working, now, "market_mail_collected", {
        event("market_mail_collected", {
            count = #collected,
            gold = totalGold,
            items = items,
            skipped = skipped,
        }),
    }, items > 0, false)

    local operations = {}
    for _, cloudListId in ipairs(collected) do
        operations[#operations + 1] = { kind = "list_delete", listId = cloudListId }
    end
    proposal.cloudOperations = operations
    proposal.market = { mailSummary = { count = #collected, gold = totalGold, items = items, skipped = skipped } }
    return proposal
end

return MarketEngine
