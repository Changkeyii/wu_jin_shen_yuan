-- MailEngine.lua
-- 邮件系统领域逻辑（服务端权威）。纯逻辑，输入 state，产出 PlayerTransition proposal。
-- 邮件不替代即时反馈，仅用于奖励延期领取 / 结果留痕。

local Catalog = require("server.domain.Catalog")
local RarityCatalog = require("shared.RarityCatalog")
local LargeNumber = require("shared.LargeNumber")
local PlayerTransition = require("server.domain.PlayerTransition")
local EquipmentEngine = require("server.domain.EquipmentEngine")
local InventoryState = require("server.domain.InventoryState")
local DomainMath = require("server.domain.DomainMath")
local TableUtils = require("server.domain.TableUtils")
local MailRules = require("shared.MailRules")
local WishPoolDefinitions = require("shared.WishPoolDefinitions")
local AbyssEngine = require("server.domain.AbyssEngine")

---@class MailEngine
local MailEngine = {}

-- ============================================================================
-- 基础
-- ============================================================================

function MailEngine.Ensure(state)
    if type(state.mails) ~= "table" then state.mails = {} end
    if type(state.mailCache) ~= "table" then state.mailCache = {} end
    state.mailSeq = math.max(1, math.floor(tonumber(state.mailSeq) or 1))
end

function MailEngine.MakeId(state, prefix)
    MailEngine.Ensure(state)
    local id = string.format("%s-%d-%d", prefix or "mail", os.time(), state.mailSeq)
    state.mailSeq = state.mailSeq + 1
    return id
end

function MailEngine.Find(list, mailId)
    for _, mail in ipairs(list or {}) do
        if mail.id == mailId then return mail end
    end
    return nil
end

function MailEngine.FindIndex(list, mailId)
    for index, mail in ipairs(list or {}) do
        if mail.id == mailId then return index, mail end
    end
    return nil, nil
end

function MailEngine.IsExpired(mail, now)
    if type(mail) ~= "table" then return false end
    return (mail.expireAt or 0) > 0 and now > (mail.expireAt or 0)
end

function MailEngine.HasAttachments(mail)
    return type(mail.attachments) == "table" and #mail.attachments > 0
end

function MailEngine.HasUnclaimed(mail)
    if not MailEngine.HasAttachments(mail) then return false end
    for _, attachment in ipairs(mail.attachments) do
        if (attachment.claimedCount or 0) < (attachment.count or 1) then return true end
    end
    return false
end

function MailEngine.AllClaimed(mail)
    if not MailEngine.HasAttachments(mail) then return true end
    return not MailEngine.HasUnclaimed(mail)
end

--- 附件状态：none / pending（未领取）/ partial（部分领取）/ claimed（已领取）
function MailEngine.AttachState(mail)
    if not MailEngine.HasAttachments(mail) then return "none" end
    local claimed = 0
    for _, attachment in ipairs(mail.attachments) do
        if (attachment.claimedCount or 0) >= (attachment.count or 1) then claimed = claimed + 1 end
    end
    if claimed == 0 then return "pending" end
    if claimed >= #mail.attachments then return "claimed" end
    return "partial"
end

-- ============================================================================
-- 排序（设计 §10）
-- ============================================================================

local function SortGroup(mail, now)
    if MailEngine.HasUnclaimed(mail) then
        return mail.read and 1 or 0
    end
    return mail.read and 3 or 2
end

local function SortMails(list, now)
    table.sort(list, function(a, b)
        local ga = SortGroup(a, now)
        local gb = SortGroup(b, now)
        if ga ~= gb then return ga < gb end
        if a.sentAt ~= b.sentAt then return a.sentAt > b.sentAt end
        return tostring(a.id) < tostring(b.id)
    end)
end

-- ============================================================================
-- 概览（红点数据）
-- ============================================================================

function MailEngine.Summary(state)
    MailEngine.Ensure(state)
    local unread = 0
    local unclaimed = 0
    for _, mail in ipairs(state.mails) do
        if not mail.read then unread = unread + 1 end
        if MailEngine.HasUnclaimed(mail) then unclaimed = unclaimed + 1 end
    end
    return { unread = unread, unclaimed = unclaimed }
end

-- ============================================================================
-- 列表 / 详情
-- ============================================================================

function MailEngine.List(state, now, scope)
    MailEngine.Ensure(state)
    local all = {}
    for _, mail in ipairs(state.mails) do
        if mail.deleted ~= true and (scope ~= "favorite" or mail.favorite) then
            all[#all + 1] = mail
        end
    end
    SortMails(all, now)
    local items = {}
    for _, mail in ipairs(all) do
        items[#items + 1] = MailEngine.ListItem(mail, now)
    end
    local summary = MailEngine.Summary(state)
    return {
        items = items,
        unread = summary.unread,
        unclaimed = summary.unclaimed,
        total = #items,
    }
end

function MailEngine.ListItem(mail, now)
    local unclaimed = MailEngine.HasUnclaimed(mail)
    return {
        mailId = mail.id,
        type = mail.type or "notice",
        title = mail.title or "",
        sender = mail.sender or MailRules.SENDER_DEFAULT,
        sentAt = mail.sentAt or 0,
        expireAt = mail.expireAt or 0,
        read = mail.read == true,
        favorite = mail.favorite == true,
        attachState = MailEngine.AttachState(mail),
        hasUnclaimed = unclaimed,
        expired = MailEngine.IsExpired(mail, now),
    }
end

function MailEngine.Detail(mail, now)
    if not mail then return nil end
    local detail = MailEngine.ListItem(mail, now)
    detail.body = mail.body or ""
    detail.attachments = {}
    for _, attachment in ipairs(mail.attachments or {}) do
        detail.attachments[#detail.attachments + 1] = {
            id = attachment.id,
            kind = attachment.kind,
            currency = attachment.currency,
            equipmentId = attachment.equipmentId,
            itemId = attachment.itemId,
            name = attachment.name,
            slot = attachment.slot,
            rarity = attachment.rarity,
            level = attachment.level,
            count = attachment.count or 1,
            claimedCount = attachment.claimedCount or 0,
            failReason = attachment.failReason,
        }
    end
    detail.expireAt = mail.expireAt or 0
    detail.effectiveAt = mail.effectiveAt or mail.sentAt or 0
    detail.overduePolicy = mail.overduePolicy or "Discard"
    return detail
end

-- ============================================================================
-- 创建（含幂等、容量、缓存队列）
-- ============================================================================

--- 生成一封新邮件（原地写入 state）。
--- spec: { type, title, sender, body, expireAt, effectiveAt, favorite, capacity,
---        bizOrderId, batchId, reason, overduePolicy, attachments = [{kind,currency,count,equipmentId,name,level,rarity}] }
---@return table 创建的邮件（已存在则返回已存在的）
function MailEngine.Create(state, spec, now)
    MailEngine.Ensure(state)
    now = math.max(0, TableUtils.ToInteger(now, os.time()))
    spec = type(spec) == "table" and spec or {}

    -- 幂等：同一业务订单号只投递一次
    if spec.bizOrderId then
        for _, mail in ipairs(state.mails) do
            if mail.bizOrderId == spec.bizOrderId then return mail end
        end
        for _, mail in ipairs(state.mailCache) do
            if mail.bizOrderId == spec.bizOrderId then return mail end
        end
    end

    local mailType = MailRules.NormalizeType(spec.type)
    local capacity = spec.capacity ~= false and spec.type ~= "special"
    local expireAt = TableUtils.ToInteger(spec.expireAt, 0)
    if expireAt <= 0 then
        expireAt = MailRules.DefaultExpireSeconds(mailType, now)
    end
    local attachments = {}
    for index, attachment in ipairs(spec.attachments or {}) do
        if index > MailRules.MAX_ATTACHMENTS then break end
        local kind = attachment.kind
        if MailRules.ATTACH_KINDS[kind] then
            attachments[#attachments + 1] = {
                id = string.format("att-%d-%d", index, state.mailSeq),
                kind = kind,
                currency = attachment.currency,
                equipmentId = attachment.equipmentId,
                itemId = attachment.itemId,
                slot = attachment.slot,
                rarity = attachment.rarity,
                level = attachment.level,
                name = attachment.name,
                count = math.max(1, TableUtils.ToInteger(attachment.count, 1)),
                claimedCount = 0,
                failReason = nil,
            }
        end
    end

    local mail = {
        id = MailEngine.MakeId(state, "mail"),
        type = mailType,
        title = string.sub(tostring(spec.title or "系统邮件"), 1, MailRules.MAX_TITLE),
        sender = string.sub(tostring(spec.sender or MailRules.SENDER_DEFAULT), 1, 32),
        body = string.sub(tostring(spec.body or ""), 1, MailRules.MAX_BODY),
        sentAt = now,
        effectiveAt = math.max(0, TableUtils.ToInteger(spec.effectiveAt, now)),
        expireAt = expireAt,
        read = false,
        favorite = spec.favorite == true,
        capacity = capacity,
        allowUnfavorite = spec.allowUnfavorite ~= false,
        bizOrderId = spec.bizOrderId,
        batchId = spec.batchId,
        reason = string.sub(tostring(spec.reason or ""), 1, 128),
        overduePolicy = MailRules.NormalizePolicy(spec.overduePolicy),
        attachments = attachments,
        deleted = false,
    }

    -- 系统特殊邮件不受普通容量限制
    if not capacity then
        state.mails[#state.mails + 1] = mail
        return mail
    end

    -- 容量不足：尝试删除最早可删除邮件
    if #state.mails >= MailRules.CAPACITY then
        MailEngine.TryAutoDelete(state, now)
    end
    if #state.mails < MailRules.CAPACITY then
        state.mails[#state.mails + 1] = mail
    elseif #state.mailCache < MailRules.CACHE_CAPACITY then
        state.mailCache[#state.mailCache + 1] = mail
    else
        -- 缓存也满：丢弃缓存中最旧可删除邮件
        MailEngine.DropOldestCache(state, now)
        if #state.mailCache < MailRules.CACHE_CAPACITY then
            state.mailCache[#state.mailCache + 1] = mail
        else
            return nil
        end
    end
    return mail
end

function MailEngine.TryAutoDelete(state, now)
    -- 找到最早的可删除邮件（无未领附件、非收藏、已过期或已读），物理移除腾出容量
    local candidates = {}
    for index, mail in ipairs(state.mails) do
        if MailEngine.CanDelete(mail, now) then
            candidates[#candidates + 1] = { index = index, mail = mail }
        end
    end
    if #candidates == 0 then return false end
    table.sort(candidates, function(a, b)
        if a.mail.sentAt ~= b.mail.sentAt then return a.mail.sentAt < b.mail.sentAt end
        return a.mail.id < b.mail.id
    end)
    table.remove(state.mails, candidates[1].index)
    return true
end

function MailEngine.DropOldestCache(state, now)
    local candidates = {}
    for index, mail in ipairs(state.mailCache) do
        if MailEngine.CanDelete(mail, now) then
            candidates[#candidates + 1] = { index = index, mail = mail }
        end
    end
    if #candidates == 0 then
        -- Keep unclaimed/favorite rewards. The sender must retain and retry the
        -- new delivery instead of replacing an existing player's reward.
        return
    end
    table.sort(candidates, function(a, b) return a.mail.sentAt < b.mail.sentAt end)
    table.remove(state.mailCache, candidates[1].index)
end

-- ============================================================================
-- 删除规则
-- ============================================================================

function MailEngine.CanDelete(mail, now)
    if not mail or mail.deleted == true then return false end
    if mail.favorite and mail.allowUnfavorite ~= false then
        -- 收藏邮件需先取消收藏（业务侧处理确认），此处按不可直接删除返回
        return false
    end
    if MailEngine.HasUnclaimed(mail) then return false end
    if not mail.read and not MailEngine.IsExpired(mail, now) then return false end
    return true
end

function MailEngine.Delete(state, mailId, now)
    local index, mail = MailEngine.FindIndex(state.mails, mailId)
    if not mail then return false, "MAIL_NOT_FOUND" end
    if MailEngine.HasUnclaimed(mail) then return false, "MAIL_HAS_UNCLAIMED" end
    if mail.favorite then return false, "MAIL_FAVORITED" end
    table.remove(state.mails, index)
    return true
end

function MailEngine.UnfavoriteAndDelete(state, mailId, now)
    local index, mail = MailEngine.FindIndex(state.mails, mailId)
    if not mail then return false, "MAIL_NOT_FOUND" end
    if MailEngine.HasUnclaimed(mail) then return false, "MAIL_HAS_UNCLAIMED" end
    table.remove(state.mails, index)
    return true
end

--- 一键删除已读（非收藏、无未领附件）
function MailEngine.DeleteRead(state, now)
    local deleted = 0
    for index = #state.mails, 1, -1 do
        local mail = state.mails[index]
        if mail.read and not mail.favorite and not MailEngine.HasUnclaimed(mail) then
            table.remove(state.mails, index)
            deleted = deleted + 1
        end
    end
    return deleted
end

-- ============================================================================
-- 收藏
-- ============================================================================

function MailEngine.Favorite(state, mailId)
    local mail = MailEngine.Find(state.mails, mailId)
    if not mail or mail.deleted == true then return false, "MAIL_NOT_FOUND" end
    if mail.favorite then return true end
    mail.favorite = true
    return true
end

function MailEngine.Unfavorite(state, mailId)
    local mail = MailEngine.Find(state.mails, mailId)
    if not mail or mail.deleted == true then return false, "MAIL_NOT_FOUND" end
    if not mail.favorite then return true end
    if mail.allowUnfavorite == false then return false, "MAIL_LOCKED_FAVORITE" end
    mail.favorite = false
    return true
end

-- ============================================================================
-- 阅读（设计 §7.1）
-- ============================================================================

function MailEngine.MarkRead(state, mailId, now)
    local mail = MailEngine.Find(state.mails, mailId)
    if not mail or mail.deleted == true then return false, "MAIL_NOT_FOUND" end
    if mail.read then return false end
    mail.read = true
    return true
end

-- ============================================================================
-- 附件发放（服务端权威）
-- ============================================================================

local function uuidPart()
    local value = math.random(0, 65535)
    return string.format("%04x", value)
end

function MailEngine._NewItemId(state)
    local used = {}
    for _, item in ipairs(state.inventory or {}) do used[item.id] = true end
    for _, item in ipairs(state.overflowLoot or {}) do used[item.id] = true end
    local itemId
    repeat
        itemId = string.format("%s%s-%s-4%03x-%04x-%s%s%s",
            uuidPart(), uuidPart(), uuidPart(), math.random(0, 4095),
            0x8000 + math.random(0, 16383),
            uuidPart(), uuidPart(), uuidPart())
    until not used[itemId]
    state.nextItemId = (state.nextItemId or 1) + 1
    return itemId
end

local function createEquipmentItem(state, spec, now)
    local definition = Catalog.GetEquipmentDefinition(spec.equipmentId)
    -- GM 按部位发放：未指定具体装备时，从该部位随机挑选一件
    if not definition and spec.slot then
        local candidates = {}
        for _, entry in ipairs(Catalog.EQUIPMENT_DEFINITIONS or {}) do
            if entry.slot == spec.slot then candidates[#candidates + 1] = entry end
        end
        if #candidates > 0 then
            definition = candidates[math.random(1, #candidates)]
        end
    end
    if not definition then return nil end
    local level = Catalog.Clamp(TableUtils.ToInteger(spec.level, state.floor or 1), 1, 1000000)
    local enhance = Catalog.Clamp(TableUtils.ToInteger(spec.enhance, 0), 0, 1000)
    local star = Catalog.Clamp(TableUtils.ToInteger(spec.star, 0), 0, Catalog.MAX_STAR)
    local rarity = RarityCatalog.NormalizeId(spec.rarity or definition.rarity)
    local actual = Catalog.CreateItemStats(definition, level, rarity, tonumber(spec.roll) or 1, enhance, star)
    local atkBig = DomainMath.Magnitude(spec.atkBig, spec.atk, actual.atkBig)
    local defBig = DomainMath.Magnitude(spec.defBig, spec.def, actual.defBig)
    local hpBig = DomainMath.Magnitude(spec.hpBig, spec.hp, actual.hpBig)
    return {
        id = MailEngine._NewItemId(state),
        equipmentId = definition.id,
        name = definition.name,
        slot = definition.slot,
        category = definition.category,
        level = level,
        enhance = enhance,
        star = star,
        rarity = rarity,
        setEnabled = actual.setEnabled == true,
        setId = actual.setId,
        statVersion = 5,
        roll = actual.roll,
        budget = actual.budget,
        budgetBig = actual.budgetBig,
        atk = DomainMath.ProjectedMagnitude(atkBig),
        def = DomainMath.ProjectedMagnitude(defBig),
        hp = DomainMath.ProjectedMagnitude(hpBig),
        atkBig = atkBig,
        defBig = defBig,
        hpBig = hpBig,
        crit = tonumber(spec.crit) or actual.crit,
        critDmg = tonumber(spec.critDmg) or actual.critDmg,
        atkSpeed = tonumber(spec.atkSpeed) or actual.atkSpeed,
        lifeSteal = tonumber(spec.lifeSteal) or actual.lifeSteal,
        damageReduction = tonumber(spec.damageReduction) or actual.damageReduction,
        bossDamage = tonumber(spec.bossDamage) or actual.bossDamage,
        coreAffixes = {},
        locked = spec.locked == true,
        acquiredAt = PlayerTransition.Now(now),
        source = "mail_claim",
        investedGold = LargeNumber.Zero(),
        investedFragments = 0,
    }
end

--- 尝试发放单个附件，成功返回 true 并累加 claimedCount。
function MailEngine.GrantAttachment(working, attachment, events, now)
    if attachment.kind == "currency" then
        if attachment.currency ~= "gold" and attachment.currency ~= "fragments" then
            attachment.failReason = "REWARD_INVALID"
            return false
        end
        PlayerTransition.AddCurrency(working, attachment.currency, attachment.count or 1)
        attachment.claimedCount = attachment.count or 1
        attachment.failReason = nil
        return true
    end
    if attachment.kind == "item" then
        local itemId = tostring(attachment.itemId or "")
        if type(working.wishPool) ~= "table" then working.wishPool = {} end
        if itemId == "wish_ticket" then
            working.wishPool.tickets = (working.wishPool.tickets or 0) + (attachment.count or 1)
            attachment.claimedCount = attachment.count or 1
            attachment.failReason = nil
            return true
        end
        if itemId == "abyss_ticket" then
            AbyssEngine.GrantTickets(
                working,
                attachment.count or 1
            )
            attachment.claimedCount = attachment.count or 1
            attachment.failReason = nil
            return true
        end
        if itemId:match("^jar%.") then
            local jar = WishPoolDefinitions.ResolveJar(itemId)
            if jar then
                if type(working.wishPool.jars) ~= "table" then working.wishPool.jars = {} end
                working.wishPool.jars[itemId] = (working.wishPool.jars[itemId] or 0) + (attachment.count or 1)
                attachment.claimedCount = attachment.count or 1
                attachment.failReason = nil
                return true
            end
        end
        attachment.failReason = "REWARD_INVALID"
        return false
    end
    if attachment.kind == "equipment" then
        local item = createEquipmentItem(working, attachment, now)
        if not item then
            attachment.failReason = "REWARD_INVALID"
            return false
        end
        local grantEvents = {}
        InventoryState.RecordCollection(working, item)
        local hasRoom, handled = EquipmentEngine.MakeRoomForDrop(working, item, grantEvents, false)
        if hasRoom then
            item.power = Catalog.GetItemPower(item)
            working.inventory[#working.inventory + 1] = item
        elseif not handled then
            attachment.failReason = "INVENTORY_FULL"
            return false
        end
        for _, event in ipairs(grantEvents) do events[#events + 1] = event end
        attachment.claimedCount = attachment.count or 1
        attachment.failReason = nil
        return true
    end
    attachment.failReason = "REWARD_INVALID"
    return false
end

-- ============================================================================
-- 领取（单封 / 一键）
-- ============================================================================

function MailEngine.Claim(inputState, mailId, now)
    local working = PlayerTransition.Copy(inputState, now)
    MailEngine.Ensure(working)
    local mail = MailEngine.Find(working.mails, mailId)
    if not mail or mail.deleted == true then
        return PlayerTransition.Failure(inputState, now, "MAIL_NOT_FOUND", "邮件不存在")
    end
    if MailEngine.IsExpired(mail, now) then
        return PlayerTransition.Failure(inputState, now, "MAIL_EXPIRED", "邮件已过期")
    end
    if not MailEngine.HasUnclaimed(mail) then
        return PlayerTransition.NoCommit(inputState, now, "mail_already_claimed")
    end
    local events = {}
    local grantedAny = false
    local failedAny = false
    for _, attachment in ipairs(mail.attachments) do
        if (attachment.claimedCount or 0) < (attachment.count or 1) then
            if MailEngine.GrantAttachment(working, attachment, events, now) then
                grantedAny = true
            else
                failedAny = true
            end
        end
    end
    if MailEngine.AllClaimed(mail) then
        mail.read = true
    end
    events[#events + 1] = PlayerTransition.Event(
        failedAny and "mail_partially_claimed" or "mail_claimed",
        { mailId = mail.id, fullyClaimed = MailEngine.AllClaimed(mail) }
    )
    return PlayerTransition.Finalize(inputState, working, now, "mail_claim", events, false, false)
end

function MailEngine.ClaimAll(inputState, now)
    local working = PlayerTransition.Copy(inputState, now)
    MailEngine.Ensure(working)
    local events = {}
    local claimed = 0
    local failed = 0
    for _, mail in ipairs(working.mails) do
        if mail.deleted ~= true and not MailEngine.IsExpired(mail, now) and MailEngine.HasUnclaimed(mail) then
            local grantedAny = false
            local failedAny = false
            for _, attachment in ipairs(mail.attachments) do
                if (attachment.claimedCount or 0) < (attachment.count or 1) then
                    if MailEngine.GrantAttachment(working, attachment, events, now) then
                        grantedAny = true
                    else
                        failedAny = true
                    end
                end
            end
            if grantedAny then
                claimed = claimed + 1
                if MailEngine.AllClaimed(mail) then mail.read = true end
                events[#events + 1] = PlayerTransition.Event(
                    failedAny and "mail_partially_claimed" or "mail_claimed",
                    { mailId = mail.id, fullyClaimed = MailEngine.AllClaimed(mail) }
                )
            elseif failedAny then
                failed = failed + 1
            end
        end
    end
    if claimed == 0 and failed == 0 then
        return PlayerTransition.NoCommit(inputState, now, "mail_nothing_to_claim")
    end
    return PlayerTransition.Finalize(inputState, working, now, "mail_claim_all", events, false, false)
end

-- ============================================================================
-- 过期处理与自动清理（设计 §8）
-- ============================================================================

function MailEngine.ProcessExpiry(state, now)
    MailEngine.Ensure(state)
    now = math.max(0, TableUtils.ToInteger(now, os.time()))
    local events = {}
    local removed = 0
    local changed = false

    local function process(list, capacity)
        local survivors = {}
        for _, mail in ipairs(list) do
            if mail.deleted == true then
                removed = removed + 1
            elseif MailEngine.IsExpired(mail, now) then
                local overdue = mail.overduePolicy or "Discard"
                if overdue == "AutoSettle" and MailEngine.HasUnclaimed(mail) then
                    for _, attachment in ipairs(mail.attachments) do
                        if (attachment.claimedCount or 0) < (attachment.count or 1) then
                            MailEngine.GrantAttachment(state, attachment, events, now)
                        end
                    end
                    if MailEngine.AllClaimed(mail) then mail.read = true end
                elseif overdue == "Reissue" and MailEngine.HasUnclaimed(mail) then
                    local unclaimed = {}
                    for _, attachment in ipairs(mail.attachments) do
                        if (attachment.claimedCount or 0) < (attachment.count or 1) then
                            unclaimed[#unclaimed + 1] = attachment
                        end
                    end
                    if #unclaimed > 0 then
                        local resend = MailEngine.Create(state, {
                            type = mail.type,
                            title = mail.title,
                            sender = mail.sender,
                            body = "（补发）" .. tostring(mail.body),
                            favorite = mail.favorite,
                            bizOrderId = "reissue:" .. tostring(mail.bizOrderId or mail.id),
                            overduePolicy = "Discard",
                            attachments = unclaimed,
                        }, now)
                        if resend then
                            events[#events + 1] = PlayerTransition.Event("mail_reissued", { mailId = mail.id, newMailId = resend.id })
                        end
                    end
                end
                -- 过期后保留期内保留，供查看；到期自动删除
                local retention = MailRules.RetentionSeconds(now)
                if mail.favorite then retention = retention + MailRules.FAVORITE_RETENTION_DAYS * 24 * 3600 end
                if now > (mail.expireAt or 0) + retention then
                    removed = removed + 1
                else
                    survivors[#survivors + 1] = mail
                end
            else
                survivors[#survivors + 1] = mail
            end
        end
        return survivors
    end

    state.mails = process(state.mails, MailRules.CAPACITY)
    state.mailCache = process(state.mailCache, MailRules.CACHE_CAPACITY)
    if removed > 0 then
        MailEngine.TryReplenish(state)
        changed = true
    end
    if #events > 0 then changed = true end
    return events, changed
end

-- ============================================================================
-- 缓存补位
-- ============================================================================

function MailEngine.TryReplenish(state)
    MailEngine.Ensure(state)
    while #state.mails < MailRules.CAPACITY and #state.mailCache > 0 do
        table.sort(state.mailCache, function(a, b)
            local pa = MailRules.REFILL_PRIORITY[a.type or "notice"] or 9
            local pb = MailRules.REFILL_PRIORITY[b.type or "notice"] or 9
            if pa ~= pb then return pa < pb end
            if a.sentAt ~= b.sentAt then return a.sentAt < b.sentAt end
            return a.id < b.id
        end)
        local candidate = state.mailCache[1]
        table.remove(state.mailCache, 1)
        state.mails[#state.mails + 1] = candidate
    end
end

return MailEngine
