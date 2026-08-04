--- 市场系统共享配置与纯计算。
--- 客户端与服务端共用同一份实现，保证费用预览与实际结算完全一致。
---
--- 设计依据见 docs/market-system-design.md
local ItemTradeRules = require("shared.ItemTradeRules")
local LargeNumber = require("shared.LargeNumber")

local MarketCatalog = {}

--- 可上架品质：神器及以上。
MarketCatalog.LISTABLE_RARITIES = {
    artifact = true,
    legendary = true,
    epic = true,
    myth = true,
}

--- 底价版本用于挂单快照审计；升级公式时旧挂单仍可追溯。
MarketCatalog.MINIMUM_PRICE_VERSION = 1

--- 手续费：基准 8%，每 VIP 等级降低 0.7 个百分点，V10 为 1%。
MarketCatalog.FEE_RATE_SCALE = 1000
MarketCatalog.BASE_FEE_UNITS = 80
MarketCatalog.VIP_FEE_REDUCTION_UNITS = 7
MarketCatalog.BASE_FEE_RATE = MarketCatalog.BASE_FEE_UNITS
    / MarketCatalog.FEE_RATE_SCALE
MarketCatalog.VIP_FEE_REDUCTION_PER_LEVEL =
    MarketCatalog.VIP_FEE_REDUCTION_UNITS
    / MarketCatalog.FEE_RATE_SCALE
MarketCatalog.MAX_VIP_LEVEL = 10

--- 购买等级准入线。取自 docs/tower-balance-simulation.md 的难度偏移 D(f) 上限 +10。
--- 这是防止越级购买击穿纵向曲线的核心阀门，不是价格限制。
MarketCatalog.PURCHASE_LEVEL_HEADROOM = 10

--- 同时挂单数（数量上限，非价格上限），用于约束云账本体量。
MarketCatalog.BASE_LISTING_SLOTS = 8
MarketCatalog.VIP_LEVELS_PER_EXTRA_SLOT = 2

--- 挂单有效期 48 小时，到期退回卖家信箱。
MarketCatalog.LISTING_DURATION_SECONDS = 48 * 60 * 60

--- 信箱容量上限，防止无限堆积。
MarketCatalog.MAILBOX_CAP = 60

--- 低价扫货：价格 <= 标准值 * 10% 的挂单在扫货时点被系统回收。
--- 标准值 = NPC 回收价（黑市收购价），即理性价格地板的 100%。
--- 10% 远低于地板，正常交易永不触发，只截胡刻意低价送装备。
MarketCatalog.SWEEP_PRICE_NUMERATOR = 1
MarketCatalog.SWEEP_PRICE_DENOMINATOR = 10
MarketCatalog.SWEEP_PRICE_RATIO = MarketCatalog.SWEEP_PRICE_NUMERATOR
    / MarketCatalog.SWEEP_PRICE_DENOMINATOR

--- 每日扫货时点（当地小时），以及所用时区偏移。
MarketCatalog.SWEEP_HOURS = { 7, 20 }
MarketCatalog.SWEEP_TIMEZONE_OFFSET_SECONDS = 8 * 60 * 60

--- 价格技术上限由 LargeNumber 的 27 位容器决定，非玩法限制。
MarketCatalog.MAX_PRICE = LargeNumber.Max()

--- 浏览分桶：品质 x 部位。
MarketCatalog.SLOT_IDS = {
    "weapon", "shoulder", "coat", "pants", "belt", "shoes",
    "bracelet", "necklace", "ring", "support", "magicstone", "earring",
}

local function ClampInteger(value, minimum, maximum)
    local number = math.floor(tonumber(value) or 0)
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

---@param rarityId string|nil
---@return boolean
function MarketCatalog.IsListableRarity(rarityId)
    return MarketCatalog.LISTABLE_RARITIES[rarityId] == true
end

function MarketCatalog.IsListableItem(item)
    return type(item) == "table"
        and type(item.equipmentId) == "string"
        and MarketCatalog.IsListableRarity(item.rarity)
        and ItemTradeRules.IsTradeable(item)
end

--- 手续费率。VIP 越高越低，V10 为 1%。
---@param vipLevel number|nil
---@return number
function MarketCatalog.GetFeeUnits(vipLevel)
    local level = ClampInteger(vipLevel, 0, MarketCatalog.MAX_VIP_LEVEL)
    return math.max(0,
        MarketCatalog.BASE_FEE_UNITS
            - level * MarketCatalog.VIP_FEE_REDUCTION_UNITS)
end

function MarketCatalog.GetFeeRate(vipLevel)
    return MarketCatalog.GetFeeUnits(vipLevel)
        / MarketCatalog.FEE_RATE_SCALE
end

--- 手续费拆分。费用从成交价中扣除，买家只付标价。
--- 手续费金币直接销毁，不进入任何账户。
---@param price table|number|string
---@param feeUnits number|nil
---@return { rate: number, feeUnits: integer, fee: table, proceeds: table }
function MarketCatalog.GetFeeBreakdownFromUnits(price, feeUnits)
    local amount = MarketCatalog.NormalizePrice(price)
    feeUnits = ClampInteger(
        feeUnits,
        0,
        MarketCatalog.FEE_RATE_SCALE
    )
    local normalizedFeeUnits = feeUnits or 0
    local fee = LargeNumber.MultiplyRatio(
        amount,
        normalizedFeeUnits,
        MarketCatalog.FEE_RATE_SCALE
    )
    local proceeds = LargeNumber.Subtract(amount, fee)
    return {
        rate = normalizedFeeUnits / MarketCatalog.FEE_RATE_SCALE,
        feeUnits = normalizedFeeUnits,
        fee = fee,
        proceeds = proceeds,
    }
end

function MarketCatalog.GetFeeBreakdown(price, vipLevel)
    return MarketCatalog.GetFeeBreakdownFromUnits(
        price,
        MarketCatalog.GetFeeUnits(vipLevel)
    )
end

--- 同时挂单上限。
---@param vipLevel number|nil
---@return integer
function MarketCatalog.GetListingSlots(vipLevel)
    local level = ClampInteger(vipLevel, 0, MarketCatalog.MAX_VIP_LEVEL)
    return MarketCatalog.BASE_LISTING_SLOTS
        + math.floor(level / MarketCatalog.VIP_LEVELS_PER_EXTRA_SLOT)
end

function MarketCatalog.NormalizePrice(value)
    if LargeNumber.IsLargeNumber(value) then
        return LargeNumber.Normalize(value)
    end
    if type(value) == "string" then
        return LargeNumber.FromString(value) or LargeNumber.Zero()
    end
    return LargeNumber.FromNumber(value)
end

function MarketCatalog.PriceEquals(left, right)
    return LargeNumber.Compare(
        MarketCatalog.NormalizePrice(left),
        MarketCatalog.NormalizePrice(right)
    ) == 0
end

--- 交易底价 = ceil(装备黑市基础价值 / 该品质可交易概率)。
--- 概率以整数万分比保存，保证服务端边界判断精确且不受浮点误差影响。
---@param standardValue table|number|string
---@param rarityId string|nil
---@return table
function MarketCatalog.GetMinimumListingPrice(standardValue, rarityId)
    local chanceUnits = ItemTradeRules.GetTradeableChanceUnits(rarityId)
    if chanceUnits <= 0 then return LargeNumber.Max() end
    return LargeNumber.MultiplyRatioCeil(
        MarketCatalog.NormalizePrice(standardValue),
        ItemTradeRules.TRADEABLE_CHANCE_SCALE,
        chanceUnits
    )
end

---@param price table|number|string
---@param standardValue table|number|string
---@param rarityId string|nil
---@return boolean, table
function MarketCatalog.MeetsMinimumListingPrice(price, standardValue, rarityId)
    local minimumPrice = MarketCatalog.GetMinimumListingPrice(
        standardValue,
        rarityId
    )
    return LargeNumber.Compare(
        MarketCatalog.NormalizePrice(price),
        minimumPrice
    ) >= 0, minimumPrice
end

function MarketCatalog.GetSweepThreshold(standardValue)
    return LargeNumber.MultiplyRatio(
        MarketCatalog.NormalizePrice(standardValue),
        MarketCatalog.SWEEP_PRICE_NUMERATOR,
        MarketCatalog.SWEEP_PRICE_DENOMINATOR
    )
end

--- 该价格是否会被系统低价扫货回收。
---@param price table|number|string
---@param standardValue table|number|string
---@return boolean
function MarketCatalog.WillBeSwept(price, standardValue)
    return LargeNumber.Compare(
        MarketCatalog.NormalizePrice(price),
        MarketCatalog.GetSweepThreshold(standardValue)
    ) <= 0
end

--- 价格合法性。只校验技术边界，不设玩法上下限。
---@param price any
---@return boolean, string|nil, table|nil
function MarketCatalog.ValidatePrice(price)
    local amount
    local reason
    if LargeNumber.IsLargeNumber(price) then
        amount = LargeNumber.Normalize(price)
        if price.high ~= amount.high
            or price.mid ~= amount.mid
            or price.low ~= amount.low
        then
            return false, "价格结构无效"
        end
    elseif type(price) == "string" then
        amount, reason = LargeNumber.FromString(price)
    elseif type(price) == "number" then
        if price ~= math.floor(price) or price < 0
            or price > LargeNumber.MAX_SAFE_INTEGER
        then
            return false, "价格必须是可精确表示的整数"
        end
        amount = LargeNumber.FromNumber(price)
    else
        return false, "价格必须是整数"
    end
    if not amount then return false, reason or "价格无效" end
    if LargeNumber.IsZero(amount) then return false, "价格必须大于 0" end
    return true, nil, amount
end

--- 购买准入：买家层数决定可购买的装备等级上限。
---@param itemLevel number
---@param buyerFloor number
---@return boolean
function MarketCatalog.CanPurchaseLevel(itemLevel, buyerFloor)
    local level = math.max(1, math.floor(tonumber(itemLevel) or 1))
    local floor = math.max(1, math.floor(tonumber(buyerFloor) or 1))
    return level <= floor + MarketCatalog.PURCHASE_LEVEL_HEADROOM
end

---@param buyerFloor number
---@return integer
function MarketCatalog.GetPurchaseLevelCap(buyerFloor)
    local floor = math.max(1, math.floor(tonumber(buyerFloor) or 1))
    return floor + MarketCatalog.PURCHASE_LEVEL_HEADROOM
end

--- 分桶键。浏览时只读取命中的桶，避免全量拉取。
---@param rarityId string
---@param slotId string
---@return string
function MarketCatalog.BucketKey(rarityId, slotId)
    return string.format("mk:%s:%s", tostring(rarityId), tostring(slotId))
end

--- 枚举全部分桶，用于扫货与过期清扫。
---@return string[]
function MarketCatalog.AllBucketKeys()
    local keys = {}
    for rarityId in pairs(MarketCatalog.LISTABLE_RARITIES) do
        for _, slotId in ipairs(MarketCatalog.SLOT_IDS) do
            keys[#keys + 1] = MarketCatalog.BucketKey(rarityId, slotId)
        end
    end
    table.sort(keys)
    return keys
end

--- 扫货纪元 ID。同一时点在所有分片得到同一字符串，用于跨分片幂等。
--- 返回 nil 表示该时刻尚未到达当日首个扫货点。
---@param timestamp number
---@return string|nil
function MarketCatalog.SweepEpochAt(timestamp)
    local seconds = math.floor(tonumber(timestamp) or 0)
    local localSeconds = seconds + MarketCatalog.SWEEP_TIMEZONE_OFFSET_SECONDS
    local dayIndex = math.floor(localSeconds / 86400)
    local secondOfDay = localSeconds - dayIndex * 86400
    local hour = math.floor(secondOfDay / 3600)

    local matchedIndex = nil
    for index, sweepHour in ipairs(MarketCatalog.SWEEP_HOURS) do
        if hour >= sweepHour then matchedIndex = index end
    end
    if not matchedIndex then
        -- 当日首个扫货点之前，归属前一日的最后一个纪元。
        dayIndex = dayIndex - 1
        matchedIndex = #MarketCatalog.SWEEP_HOURS
    end
    return string.format("%d-%d", dayIndex, MarketCatalog.SWEEP_HOURS[matchedIndex])
end

--- 下一个扫货时点的 Unix 时间戳，用于 UI 倒计时。
---@param timestamp number
---@return integer
function MarketCatalog.NextSweepAt(timestamp)
    local seconds = math.floor(tonumber(timestamp) or 0)
    local offset = MarketCatalog.SWEEP_TIMEZONE_OFFSET_SECONDS
    local localSeconds = seconds + offset
    local dayIndex = math.floor(localSeconds / 86400)
    local secondOfDay = localSeconds - dayIndex * 86400

    for _, sweepHour in ipairs(MarketCatalog.SWEEP_HOURS) do
        local target = sweepHour * 3600
        if target > secondOfDay then
            return dayIndex * 86400 + target - offset
        end
    end
    return (dayIndex + 1) * 86400 + MarketCatalog.SWEEP_HOURS[1] * 3600 - offset
end

return MarketCatalog
