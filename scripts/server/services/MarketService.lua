--- 市场服务层：云账本读写、跨分片并发控制、结算与低价扫货。
---
--- 为什么这些逻辑必须在这里而不是领域层：
---   常驻世界存在多个服务端分片，交易行账本只能放 serverCloud。
---   由此产生两条铁律：
---     1. 绝不跨分片写他人存档 —— 卖家收益走"信箱"，等卖家自己上线领取。
---     2. 云读写各 300 次/分钟且全局共享 —— 浏览必须走分片内缓存，不能每次查云。
---
--- 并发原语：serverCloud 没有 CAS，Add 回调也不返回新值。
---   可用的确定性原语是 list:Add 同步返回全局唯一 id。
---   因此用"票据锁"：各方写入票据后回读，最小 id 获胜。
---   这是共享状态的确定性函数，所有分片读到同一答案，无需协调。
local ItemSort = require("shared.ItemSort")
local MarketCatalog = require("shared.MarketCatalog")
local LargeNumber = require("shared.LargeNumber")
local MarketEngine = require("server.domain.MarketEngine")
local ServerCloudGateway = require("server.dao.ServerCloudGateway")

local MarketService = {}
MarketService.__index = MarketService

--- 分片内缓存有效期。浏览容忍这个量级的陈旧，下单时会二次校验。
MarketService.BUCKET_CACHE_SECONDS = 30
--- 扫货/过期检查间隔。
MarketService.SWEEP_CHECK_SECONDS = 60
--- 单次云事务内的结算条目上限，避免超出 BatchCommit 操作数限制。
MarketService.SETTLE_CHUNK = 40

local function Result(ok, data, code, reason)
    return { ok = ok, data = data or {}, code = code, reason = reason }
end

---@param options { gateway: table, profileService: table, clock: function|nil, log: function|nil }
---@return table
function MarketService.New(options)
    local instance = {
        gateway = options.gateway,
        profileService = options.profileService,
        clock = options.clock or os.time,
        log = options.log or function() end,
        buckets = {},
        lastSweepCheckAt = 0,
        lastSweptEpoch = nil,
        sweeping = false,
    }
    return setmetatable(instance, MarketService)
end

-- 云账本读取 -----------------------------------------------------------------

---@param rows table[]|nil
---@return table[]
local function NormalizeRows(rows)
    local listings = {}
    for _, row in ipairs(rows or {}) do
        local value = row.value
        local cloudListId = row.list_id or row.listId or row.id
        if type(value) == "table" and type(value.itemId) == "string" and cloudListId then
            listings[#listings + 1] = {
                cloudListId = math.floor(tonumber(cloudListId) or 0),
                record = value,
            }
        end
    end
    return listings
end

--- 读取单个分桶，命中缓存则不产生云读。
function MarketService:ReadBucket(bucketKey, onComplete, forceRefresh)
    local now = self.clock()
    local cached = self.buckets[bucketKey]
    if not forceRefresh and cached
        and (now - cached.fetchedAt) < MarketService.BUCKET_CACHE_SECONDS then
        onComplete(Result(true, { listings = cached.listings, cached = true }))
        return
    end

    self.gateway:ListGet(MarketEngine.LEDGER_UID, bucketKey, function(result)
        if not result.ok then
            -- 云不可用时退回旧缓存，浏览体验优于直接报错。
            if cached then
                onComplete(Result(true, { listings = cached.listings, cached = true, stale = true }))
                return
            end
            onComplete(Result(false, {}, "CLOUD_ERROR", result.reason))
            return
        end
        local listings = NormalizeRows(result.data.items)
        self.buckets[bucketKey] = { listings = listings, fetchedAt = now }
        onComplete(Result(true, { listings = listings, cached = false }))
    end)
end

function MarketService:InvalidateBucket(bucketKey)
    self.buckets[bucketKey] = nil
end

--- 浏览。rarity/slot 为 nil 时遍历对应维度的全部分桶。
function MarketService:Browse(query, onComplete)
    local now = self.clock()
    local rarities = {}
    if query.rarity and MarketCatalog.IsListableRarity(query.rarity) then
        rarities[1] = query.rarity
    else
        for rarityId in pairs(MarketCatalog.LISTABLE_RARITIES) do rarities[#rarities + 1] = rarityId end
        table.sort(rarities)
    end
    local slots = {}
    if query.slot then
        slots[1] = query.slot
    else
        for _, slotId in ipairs(MarketCatalog.SLOT_IDS) do slots[#slots + 1] = slotId end
    end

    local keys = {}
    for _, rarityId in ipairs(rarities) do
        for _, slotId in ipairs(slots) do
            keys[#keys + 1] = MarketCatalog.BucketKey(rarityId, slotId)
        end
    end

    local pending = #keys
    if pending == 0 then
        onComplete(Result(true, { listings = {} }))
        return
    end

    local collected = {}
    local levelCap = query.buyerFloor
        and MarketCatalog.GetPurchaseLevelCap(query.buyerFloor)
        or nil

    local function finish()
        for _, entry in ipairs(collected) do
            entry.affordableLevel = levelCap == nil or entry.level <= levelCap
        end
        table.sort(collected, function(left, right)
            local compared = ItemSort.Compare(left.item, right.item)
            if compared ~= 0 then return compared < 0 end
            compared = LargeNumber.Compare(left.price, right.price)
            if compared ~= 0 then return compared < 0 end
            return left.itemId < right.itemId
        end)
        local limit = math.min(#collected, math.max(1, math.floor(tonumber(query.limit) or 60)))
        local page = {}
        for index = 1, limit do page[index] = collected[index] end
        onComplete(Result(true, {
            listings = page,
            total = #collected,
            levelCap = levelCap,
            serverTime = now,
            nextSweepAt = MarketCatalog.NextSweepAt(now),
        }))
    end

    for _, bucketKey in ipairs(keys) do
        self:ReadBucket(bucketKey, function(result)
            if result.ok then
                for _, entry in ipairs(result.data.listings) do
                    local record = entry.record
                    if (tonumber(record.expiresAt) or 0) > now
                        and record.sellerUid ~= query.viewerUid
                        and MarketCatalog.IsListableItem(record.item)
                    then
                        collected[#collected + 1] = {
                            itemId = record.itemId,
                            sellerUid = record.sellerUid,
                            price = MarketCatalog.NormalizePrice(record.price),
                            standardValue = MarketCatalog.NormalizePrice(record.standardValue),
                            rarity = record.rarity,
                            slot = record.slot,
                            level = math.floor(tonumber(record.level) or 1),
                            expiresAt = math.floor(tonumber(record.expiresAt) or 0),
                            item = record.item,
                        }
                    end
                end
            end
            pending = pending - 1
            if pending == 0 then finish() end
        end)
    end
end

--- 在指定分桶中定位一条挂单，强制穿透缓存，用于成交前的权威校验。
function MarketService:FindListing(rarity, slot, itemId, onComplete)
    local bucketKey = MarketCatalog.BucketKey(rarity, slot)
    self:ReadBucket(bucketKey, function(result)
        if not result.ok then
            onComplete(Result(false, {}, result.code, result.reason))
            return
        end
        for _, entry in ipairs(result.data.listings) do
            if entry.record.itemId == itemId then
                onComplete(Result(true, {
                    record = entry.record,
                    cloudListId = entry.cloudListId,
                    bucketKey = bucketKey,
                }))
                return
            end
        end
        onComplete(Result(false, {}, "LISTING_GONE", "挂单已被买走或已下架"))
    end, true)
end

-- 票据锁 ---------------------------------------------------------------------

--- 抢占一次性资源。写入票据后回读，最小 id 获胜。
---@param lockKey string
---@param onComplete fun(result: table)
function MarketService:AcquireTicket(lockKey, onComplete)
    local now = self.clock()
    self.gateway:ListAdd(MarketEngine.LEDGER_UID, lockKey, { at = now }, function(addResult)
        if not addResult.ok then
            onComplete(Result(false, {}, "CLOUD_ERROR", addResult.reason))
            return
        end
        local myTicketId = math.floor(tonumber(addResult.data.listId) or 0)
        if myTicketId <= 0 then
            onComplete(Result(false, {}, "CLOUD_ERROR", "票据未返回有效 id"))
            return
        end
        self.gateway:ListGet(MarketEngine.LEDGER_UID, lockKey, function(getResult)
            if not getResult.ok then
                self.gateway:ListDelete(myTicketId, function() end)
                onComplete(Result(false, {}, "CLOUD_ERROR", getResult.reason))
                return
            end
            local winner = nil
            local ticketIds = {}
            for _, row in ipairs(getResult.data.items or {}) do
                local ticketId = math.floor(tonumber(row.list_id or row.listId or row.id) or 0)
                if ticketId > 0 then
                    ticketIds[#ticketIds + 1] = ticketId
                    if winner == nil or ticketId < winner then winner = ticketId end
                end
            end
            if winner ~= myTicketId then
                self.gateway:ListDelete(myTicketId, function() end)
                onComplete(Result(false, {}, "LISTING_CONTESTED", "已有其他玩家抢先"))
                return
            end
            onComplete(Result(true, { ticketId = myTicketId, ticketIds = ticketIds }))
        end)
    end)
end

--- 释放票据。争抢结束后清理，避免键无限增长。
function MarketService:ReleaseTickets(ticketIds)
    for _, ticketId in ipairs(ticketIds or {}) do
        self.gateway:ListDelete(ticketId, function() end)
    end
end

-- 玩家操作 -------------------------------------------------------------------

--- 上架。
function MarketService:List(uid, payload, onComplete)
    self.profileService:Apply(uid, "market list", function(state, now)
        return MarketEngine.List(state, {
            itemId = payload.itemId,
            price = payload.price,
            sellerUid = uid,
        }, now)
    end, function(result)
        if result.ok and result.data.market and result.data.market.listingRecord then
            local record = result.data.market.listingRecord
            self:InvalidateBucket(MarketCatalog.BucketKey(record.rarity, record.slot))
        end
        onComplete(result)
    end)
end

--- 下架。先从云账本取回权威记录，再走存档变更。
function MarketService:Cancel(uid, payload, onComplete)
    local state = self.profileService:GetState(uid)
    if not state then
        onComplete(Result(false, {}, "PROFILE_NOT_LOADED", "存档尚未加载"))
        return
    end
    local mirror = nil
    for _, listing in ipairs(state.marketListings or {}) do
        if listing.itemId == payload.itemId then mirror = listing break end
    end
    if not mirror then
        onComplete(Result(false, {}, "LISTING_NOT_FOUND", "挂单不存在"))
        return
    end

    self:FindListing(mirror.rarity, mirror.slot, payload.itemId, function(found)
        if not found.ok then
            onComplete(Result(false, {}, found.code, found.reason))
            return
        end
        if found.data.record.sellerUid ~= uid then
            onComplete(Result(false, {}, "FORBIDDEN", "不是你的挂单"))
            return
        end
        self.profileService:Apply(uid, "market cancel", function(currentState, now)
            return MarketEngine.Cancel(currentState, {
                itemId = payload.itemId,
                record = found.data.record,
                cloudListId = found.data.cloudListId,
            }, now)
        end, function(result)
            self:InvalidateBucket(found.data.bucketKey)
            onComplete(result)
        end)
    end)
end

--- 购买。票据锁 -> 权威校验 -> 单事务结算。
function MarketService:Buy(uid, payload, onComplete)
    local lockKey = "mkbid:" .. tostring(payload.itemId)
    self:AcquireTicket(lockKey, function(ticket)
        if not ticket.ok then
            onComplete(Result(false, {}, ticket.code, ticket.reason))
            return
        end
        local ticketIds = ticket.data.ticketIds

        local function release(result)
            self:ReleaseTickets(ticketIds)
            onComplete(result)
        end

        self:FindListing(payload.rarity, payload.slot, payload.itemId, function(found)
            if not found.ok then
                release(Result(false, {}, found.code, found.reason))
                return
            end
            local record = found.data.record
            if (tonumber(record.expiresAt) or 0) <= self.clock() then
                release(Result(false, {}, "LISTING_GONE", "挂单已过期"))
                return
            end
            if payload.expectedPrice
                and not MarketCatalog.PriceEquals(payload.expectedPrice, record.price)
            then
                release(Result(false, {}, "LISTING_GONE", "价格已变化，请刷新"))
                return
            end

            self.profileService:Apply(uid, "market buy", function(state, now)
                return MarketEngine.Purchase(state, {
                    record = record,
                    cloudListId = found.data.cloudListId,
                    buyerUid = uid,
                }, now)
            end, function(result)
                self:InvalidateBucket(found.data.bucketKey)
                if result.ok then
                    self.log(string.format(
                        "[Market] trade item=%s seller=%s buyer=%s price=%s fee=%s",
                        tostring(record.itemId), tostring(record.sellerUid), tostring(uid),
                        LargeNumber.ToString(MarketCatalog.NormalizePrice(record.price)),
                        LargeNumber.ToString(
                            result.data.market and result.data.market.settlement
                                and result.data.market.settlement.fee
                                or LargeNumber.Zero()
                        )))
                end
                release(result)
            end)
        end)
    end)
end

--- 读取信箱。
function MarketService:Mailbox(uid, onComplete)
    self.gateway:ListGet(uid, MarketEngine.MAIL_KEY, function(result)
        if not result.ok then
            onComplete(Result(false, {}, "CLOUD_ERROR", result.reason))
            return
        end
        local mails = {}
        for _, row in ipairs(result.data.items or {}) do
            local cloudListId = math.floor(tonumber(row.list_id or row.listId or row.id) or 0)
            if type(row.value) == "table" and cloudListId > 0 then
                mails[#mails + 1] = { cloudListId = cloudListId, value = row.value }
            end
        end
        table.sort(mails, function(left, right) return left.cloudListId < right.cloudListId end)
        onComplete(Result(true, { mails = mails, count = #mails }))
    end)
end

--- 领取信箱。
function MarketService:Collect(uid, onComplete)
    self:Mailbox(uid, function(mailResult)
        if not mailResult.ok then
            onComplete(Result(false, {}, mailResult.code, mailResult.reason))
            return
        end
        local mails = mailResult.data.mails
        if #mails == 0 then
            onComplete(Result(true, {
                collected = 0,
                gold = LargeNumber.Zero(),
                items = 0,
            }))
            return
        end
        self.profileService:Apply(uid, "market collect mail", function(state, now)
            return MarketEngine.CollectMail(state, { mails = mails }, now)
        end, onComplete)
    end)
end

-- 低价扫货与过期清扫 ---------------------------------------------------------

--- 把一批挂单结算掉：删除账本条目，并把结果投递到卖家信箱。
--- 全程只写云，不触碰任何玩家存档，因此卖家离线或在别的分片都安全。
function MarketService:_settleBatch(entries, description, onComplete)
    if #entries == 0 then
        onComplete(Result(true, { settled = 0 }))
        return
    end
    local operation = ServerCloudGateway.CommitOperation
    local settled = 0
    local index = 1

    local function step()
        if index > #entries then
            onComplete(Result(true, { settled = settled }))
            return
        end
        local operations = {}
        local chunkCount = 0
        while index <= #entries and chunkCount < MarketService.SETTLE_CHUNK do
            local entry = entries[index]
            operations[#operations + 1] = {
                kind = operation.LIST_DELETE,
                listId = entry.cloudListId,
            }
            operations[#operations + 1] = {
                kind = operation.LIST_ADD,
                userId = entry.record.sellerUid,
                key = MarketEngine.MAIL_KEY,
                value = entry.mail,
            }
            index = index + 1
            chunkCount = chunkCount + 1
        end
        self.gateway:BatchCommit(description, operations, function(result)
            if result.ok then settled = settled + chunkCount end
            step()
        end)
    end
    step()
end

--- 执行一次扫货 + 过期清扫。调用前必须已经拿到该纪元的票据。
function MarketService:_runSweep(epochId, onComplete)
    local now = self.clock()
    local bucketKeys = MarketCatalog.AllBucketKeys()
    local pending = #bucketKeys
    local swept = {}
    local expired = {}

    local function finish()
        self:_settleBatch(swept, "market low price sweep", function()
            self:_settleBatch(expired, "market listing expiry", function()
                for _, bucketKey in ipairs(bucketKeys) do self:InvalidateBucket(bucketKey) end
                self.log(string.format(
                    "[Market] sweep epoch=%s swept=%d expired=%d", epochId, #swept, #expired))
                onComplete(Result(true, { epochId = epochId, swept = #swept, expired = #expired }))
            end)
        end)
    end

    for _, bucketKey in ipairs(bucketKeys) do
        self:ReadBucket(bucketKey, function(result)
            if result.ok then
                for _, entry in ipairs(result.data.listings) do
                    local record = entry.record
                    local price = MarketCatalog.NormalizePrice(record.price)
                    local standardValue = MarketCatalog.NormalizePrice(record.standardValue)
                    local feeUnits = record.feeUnits
                    if feeUnits == nil then
                        feeUnits = math.floor(
                            math.max(0, math.min(1,
                                tonumber(record.feeRate)
                                    or MarketCatalog.BASE_FEE_RATE))
                                * MarketCatalog.FEE_RATE_SCALE + 0.5
                        )
                    end
                    if (tonumber(record.expiresAt) or 0) <= now then
                        -- 过期：原样退回卖家信箱，不收手续费。
                        expired[#expired + 1] = {
                            cloudListId = entry.cloudListId,
                            record = record,
                            mail = {
                                kind = "returned",
                                itemId = record.itemId,
                                item = record.item,
                                price = price,
                                at = now,
                            },
                        }
                    elseif MarketCatalog.WillBeSwept(price, standardValue) then
                        -- 低价扫货：卖家照常拿到自己的标价（扣手续费），装备被系统销毁。
                        local settlement = MarketCatalog.GetFeeBreakdownFromUnits(
                            price,
                            feeUnits
                        )
                        swept[#swept + 1] = {
                            cloudListId = entry.cloudListId,
                            record = record,
                            mail = {
                                kind = "swept",
                                itemId = record.itemId,
                                price = price,
                                fee = settlement.fee,
                                gold = settlement.proceeds,
                                feeRate = settlement.rate,
                                feeUnits = settlement.feeUnits,
                                at = now,
                            },
                        }
                    end
                end
            end
            pending = pending - 1
            if pending == 0 then finish() end
        end, true)
    end
end

--- 每帧调用。内部自行按间隔节流，跨越扫货时点才真正执行。
function MarketService:Tick()
    local now = self.clock()
    if self.sweeping then return end
    if (now - self.lastSweepCheckAt) < MarketService.SWEEP_CHECK_SECONDS then return end
    self.lastSweepCheckAt = now

    local epochId = MarketCatalog.SweepEpochAt(now)
    if not epochId or epochId == self.lastSweptEpoch then return end

    self.sweeping = true
    -- 票据锁保证多分片下同一纪元只扫一次；错过时点的分片下次检查会补扫。
    self:AcquireTicket("mksweep:" .. epochId, function(ticket)
        if not ticket.ok then
            -- 输掉票据说明别的分片已在处理这个纪元，本分片直接标记跳过。
            self.lastSweptEpoch = epochId
            self.sweeping = false
            return
        end
        self:_runSweep(epochId, function()
            self.lastSweptEpoch = epochId
            self.sweeping = false
        end)
    end)
end

return MarketService
