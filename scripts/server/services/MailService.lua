-- MailService.lua
-- 邮件服务：封装 MailEngine 与 profileService 的读写，提供玩家操作、业务发件与 GM 操作。
-- 所有发放结果以服务端为准，具备幂等保护。

local PlayerTransition = require("server.domain.PlayerTransition")
local MailEngine = require("server.domain.MailEngine")
local MailRules = require("shared.MailRules")
local TableUtils = require("server.domain.TableUtils")
local ServerConfig = require("server.ServerConfig")

---@class MailService
---@field profileService table<string, any>
---@field gateway table<string, any>?
---@field operationQueue table<string, any>?
---@field authorityUid integer
---@field decodeJson function?
---@field clock fun(): integer
---@field log function
---@field onDelta function
---@field instanceNonce string
---@field broadcasts table[]
---@field broadcastSeq integer
---@field broadcastWaiters function[]
---@field broadcastPolling table<integer, boolean>
---@field broadcastLoadedAt integer?
---@field expiryElapsed number
---@field sharedStore CloudMailStore?
---@field sharedDelivery SharedMailDelivery?
local MailService = {}
MailService.__index = MailService

-- 广播队列最大保留条数（超出后丢弃最旧批次）
local BROADCAST_KEY = "abyss_broadcast_mail_v1"

local function Result(ok, data, code, reason)
    return { ok = ok == true, data = data or {}, code = code or (ok and 0 or -1), reason = tostring(reason or "") }
end

---@return MailService
function MailService.New(options)
    options = options or {}
    assert(options.profileService, "MailService requires profileService")
    local self = setmetatable({
        profileService = options.profileService,
        log = options.log or print,
        clock = options.clock or os.time,
        expiryElapsed = 0,
        broadcasts = {},
        broadcastSeq = 0,
        gateway = options.gateway,
        operationQueue = options.operationQueue,
        authorityUid = options.authorityUid or ServerConfig.LEADERBOARD_AUTHORITY_UID,
        decodeJson = options.decodeJson or (_G.cjson and _G.cjson.decode),
        onDelta = options.onDelta or function() end,
        instanceNonce = options.instanceNonce or (tostring({}):gsub("[^%w]", "") .. tostring(math.random(1, 999999999))),
        broadcastWaiters = {},
        broadcastPolling = {},
        broadcastLoadedAt = nil,
    }, MailService)
    if options.sharedStore then
        local Shared = require("server.services.SharedMailDelivery")
        self.sharedStore = options.sharedStore
        self.sharedDelivery = Shared.New({ store = options.sharedStore, profileService = self.profileService,
            operationQueue = self.operationQueue, onDelta = self.onDelta, clock = self.clock, log = self.log })
    end
    return self
end

-- ============================================================================
-- 读取（直接读会话状态，不提交）
-- ============================================================================

function MailService:Summary(userId)
    local state = self.profileService:GetState(userId)
    if not state then return Result(false, {}, "PROFILE_NOT_LOADED", "玩家档案未加载") end
    return Result(true, MailEngine.Summary(state))
end

function MailService:List(userId, scope)
    local state = self.profileService:GetState(userId)
    if not state then return Result(false, {}, "PROFILE_NOT_LOADED", "玩家档案未加载") end
    local data = MailEngine.List(state, self.clock(), scope)
    if self.sharedDelivery then
        local status = self.sharedDelivery:Status(userId)
        data.deliveryPending = status.state ~= "synced"
        data.syncState, data.retryAt, data.syncError = status.state, status.retryAt, status.error
        data.deliveryProtocol = status.protocol
    end
    return Result(true, data)
end

function MailService:Detail(userId, mailId)
    local state = self.profileService:GetState(userId)
    if not state then return Result(false, {}, "PROFILE_NOT_LOADED", "玩家档案未加载") end
    MailEngine.Ensure(state)
    local mail = MailEngine.Find(state.mails, mailId)
    if not mail then return Result(false, {}, "MAIL_NOT_FOUND", "邮件不存在") end
    return Result(true, MailEngine.Detail(mail, self.clock()))
end

-- ============================================================================
-- 玩家操作（提交型）
-- ============================================================================

function MailService:_apply(userId, name, mutator, callback)
    if self.sharedStore and name ~= "mail expiry" then self.sharedStore.foregroundUntil[userId] = self.clock() + 10 end
    self.profileService:Apply(userId, name, function(state, now)
        local proposal = mutator(state, now)
        if self.sharedStore and proposal.ok and proposal.commit and proposal.commit.kind ~= "none" then
            local allowed = self.sharedStore:Reserve("write", name ~= "mail expiry")
            if not allowed then return PlayerTransition.Failure(state, now, "MAIL_RATE_DEFERRED", "邮件操作繁忙，请稍后重试") end
        end
        return proposal
    end, callback)
end

--- 阅读标记（玩家手动/自动标记已读）
function MailService:MarkRead(userId, mailId, onComplete)
    self:_apply(userId, "mail read", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local mail = MailEngine.Find(working.mails, mailId)
        if not mail then
            return PlayerTransition.Failure(state, now, "MAIL_NOT_FOUND", "邮件不存在")
        end
        if mail.read then
            return PlayerTransition.NoCommit(state, now, "mail_already_read")
        end
        mail.read = true
        return PlayerTransition.Finalize(state, working, now, "mail_read", {}, false, false)
    end, onComplete)
end

--- 单封领取
function MailService:Claim(userId, mailId, onComplete, resultSink)
    self:_apply(userId, "mail claim", function(state, now)
        local proposal = MailEngine.Claim(state, mailId, now)
        if proposal.ok and proposal.state and type(resultSink) == "table" then
            MailEngine.Ensure(proposal.state)
            local mail = MailEngine.Find(proposal.state.mails, mailId)
            if mail then
                resultSink.claimed = {}
                resultSink.failed = {}
                for _, attachment in ipairs(mail.attachments) do
                    if (attachment.claimedCount or 0) >= (attachment.count or 1) then
                        resultSink.claimed[#resultSink.claimed + 1] = {
                            id = attachment.id, kind = attachment.kind,
                            currency = attachment.currency, equipmentId = attachment.equipmentId,
                            itemId = attachment.itemId, name = attachment.name, count = attachment.count,
                            slot = attachment.slot, rarity = attachment.rarity, level = attachment.level,
                        }
                    elseif attachment.failReason then
                        resultSink.failed[#resultSink.failed + 1] = {
                            id = attachment.id, kind = attachment.kind, reason = attachment.failReason,
                        }
                    end
                end
            end
        end
        return proposal
    end, onComplete)
end

--- 一键领取
function MailService:ClaimAll(userId, onComplete, resultSink)
    self:_apply(userId, "mail claim all", function(state, now)
        ---@type table
        local proposal = MailEngine.ClaimAll(state, now)
        if proposal.ok and proposal.state and type(resultSink) == "table" then
            MailEngine.Ensure(proposal.state)
            resultSink.claimed = {}
            resultSink.failed = {}
            local claimedCount = 0
            for _, mail in ipairs(proposal.state.mails) do
                if MailEngine.HasUnclaimed(mail) then
                    for _, attachment in ipairs(mail.attachments) do
                        if attachment.failReason then
                            resultSink.failed[#resultSink.failed + 1] = {
                                mailId = mail.id, title = mail.title, reason = attachment.failReason,
                            }
                        end
                    end
                elseif MailEngine.HasAttachments(mail) then
                    claimedCount = claimedCount + 1
                    for _, attachment in ipairs(mail.attachments) do
                        if (attachment.claimedCount or 0) >= (attachment.count or 1) then
                            resultSink.claimed[#resultSink.claimed + 1] = {
                                id = attachment.id, kind = attachment.kind,
                                currency = attachment.currency, equipmentId = attachment.equipmentId,
                                itemId = attachment.itemId, name = attachment.name, count = attachment.count,
                                slot = attachment.slot, rarity = attachment.rarity, level = attachment.level,
                            }
                        end
                    end
                end
            end
            resultSink.claimedCount = claimedCount
        end
        return proposal
    end, onComplete)
end

--- 收藏 / 取消收藏
function MailService:Favorite(userId, mailId, onComplete)
    self:_apply(userId, "mail favorite", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local ok, code = MailEngine.Favorite(working, mailId)
        if not ok then return PlayerTransition.Failure(state, now, code, MailRules.CLAIM_ERRORS[code] or code) end
        return PlayerTransition.Finalize(state, working, now, "mail_favorite", {}, false, false)
    end, onComplete)
end

function MailService:Unfavorite(userId, mailId, onComplete)
    self:_apply(userId, "mail unfavorite", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local ok, code = MailEngine.Unfavorite(working, mailId)
        if not ok then return PlayerTransition.Failure(state, now, code, MailRules.CLAIM_ERRORS[code] or code) end
        return PlayerTransition.Finalize(state, working, now, "mail_unfavorite", {}, false, false)
    end, onComplete)
end

--- 删除（普通）
function MailService:Delete(userId, mailId, onComplete)
    self:_apply(userId, "mail delete", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local ok, code = MailEngine.Delete(working, mailId, now)
        if not ok then
            return PlayerTransition.Failure(state, now, code, MailRules.CLAIM_ERRORS[code] or code)
        end
        MailEngine.TryReplenish(working)
        return PlayerTransition.Finalize(state, working, now, "mail_delete", {}, false, false)
    end, onComplete)
end

--- 收藏邮件确认后删除（取消收藏 + 删除）
function MailService:UnfavoriteAndDelete(userId, mailId, onComplete)
    self:_apply(userId, "mail unfavorite delete", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local ok, code = MailEngine.UnfavoriteAndDelete(working, mailId, now)
        if not ok then
            return PlayerTransition.Failure(state, now, code, MailRules.CLAIM_ERRORS[code] or code)
        end
        MailEngine.TryReplenish(working)
        return PlayerTransition.Finalize(state, working, now, "mail_delete", {}, false, false)
    end, onComplete)
end

--- 一键删除已读
function MailService:DeleteRead(userId, onComplete, resultSink)
    self:_apply(userId, "mail delete read", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local deleted = MailEngine.DeleteRead(working, now)
        if deleted == 0 then
            return PlayerTransition.NoCommit(state, now, "mail_nothing_to_delete")
        end
        if type(resultSink) == "table" then resultSink.deletedCount = deleted end
        MailEngine.TryReplenish(working)
        return PlayerTransition.Finalize(state, working, now, "mail_delete_read", {}, false, false)
    end, onComplete)
end

-- ============================================================================
-- 业务发件（幂等）
-- ============================================================================

--- 业务系统统一投递。spec: { type, title, body, sender?, expireAt?, effectiveAt?,
---   favorite?, bizOrderId?, batchId?, reason?, overduePolicy?,
---   attachments = [{ kind, currency/count | equipmentId/count }] }
function MailService:SendMail(userId, spec, onComplete, resultSink)
    self:_apply(userId, "mail send", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local mail = MailEngine.Create(working, spec, now)
        if not mail then
            return PlayerTransition.Failure(state, now, "MAIL_CAPACITY_FULL", "邮箱已满")
        end
        if type(resultSink) == "table" then
            resultSink.mailId = mail.id
            resultSink.created = true
        end
        return PlayerTransition.Finalize(state, working, now, "mail_sent", {}, false, false)
    end, onComplete)
end

--- 是否已存在相同业务订单号的邮件
function MailService:HasBizOrder(userId, bizOrderId)
    local state = self.profileService:GetState(userId)
    if not state then return false end
    MailEngine.Ensure(state)
    for _, mail in ipairs(state.mails) do
        if mail.bizOrderId == bizOrderId then return true end
    end
    for _, mail in ipairs(state.mailCache) do
        if mail.bizOrderId == bizOrderId then return true end
    end
    return false
end

-- ============================================================================
-- 全服邮件（广播队列 + 在线投递 + 离线登录补发）
-- ============================================================================

--- 给单个玩家补发所有尚未送达的全服邮件（幂等：receivedBroadcasts 标记 + bizOrderId 双保险）。
--- 在线投递与离线登录补发共用此函数；已送达的批次自动跳过。
function MailService:_loadBroadcasts(onComplete)
    if self.sharedStore then self.sharedStore:ReadPublic(onComplete, true); return end
    if not self.gateway then onComplete(Result(false, {}, "MAIL_CLOUD_UNAVAILABLE", "邮件云存储不可用")); return end
    if self.broadcastLoadedAt and self.clock() - self.broadcastLoadedAt < 5 then
        onComplete(Result(true, { entries = self.broadcasts })); return
    end
    self.broadcastWaiters[#self.broadcastWaiters + 1] = onComplete
    if #self.broadcastWaiters > 1 then return end
    self.gateway:ListGet(self.authorityUid, BROADCAST_KEY, function(result)
        local entries, expired, now = {}, {}, self.clock()
        if result.ok then
            for _, row in ipairs(result.data.items or {}) do
                local entry = row.value
                if type(entry) == "string" and self.decodeJson then
                    local ok, decoded = pcall(self.decodeJson, entry)
                    if ok then entry = decoded end
                end
                if type(entry) ~= "table" or type(entry.batchId) ~= "string"
                    or #entry.batchId < 1 or #entry.batchId > 128 or type(entry.spec) ~= "table" then
                    result = Result(false, {}, "INVALID_BROADCAST", "全服邮件记录无法解析，稍后重试")
                    break
                end
                if (tonumber(entry.spec.expireAt) or 0) == 0 or (tonumber(entry.spec.expireAt) or 0) > now then
                    entries[#entries + 1] = TableUtils.DeepCopy(entry)
                elseif #expired < 8 and math.tointeger(tonumber(row.list_id or row.listId)) then
                    expired[#expired + 1] = math.tointeger(tonumber(row.list_id or row.listId))
                end
            end
            if result.ok then
                table.sort(entries, function(a, b)
                    if a.createdAt == b.createdAt then return a.batchId < b.batchId end
                    return (tonumber(a.createdAt) or 0) < (tonumber(b.createdAt) or 0)
                end)
                self.broadcasts, self.broadcastLoadedAt = entries, now
                result = Result(true, { entries = entries })
            end
        end
        local waiters = self.broadcastWaiters
        self.broadcastWaiters = {}
        for _, callback in ipairs(waiters) do callback(result) end
        if result.ok then
            for _, id in ipairs(expired) do
                self.gateway:ListDelete(id, function(deleted)
                    if not deleted.ok then self.log("[Mail] expired broadcast cleanup failed id=" .. tostring(id)) end
                end)
            end
        end
    end)
end

function MailService:_deliverBroadcastEntries(userId, queue, onComplete)
    local index = 1
    local delivered, pending = 0, 0
    local function next()
        if index > #queue then
            onComplete(Result(true, { delivered = delivered, pending = pending }))
            return
        end
        local entry = queue[index]
        index = index + 1
        self:_apply(userId, "mail broadcast", function(state, now)
            local working = PlayerTransition.Copy(state, now)
            MailEngine.Ensure(working)
            if type(working.receivedBroadcasts) ~= "table" then working.receivedBroadcasts = {} end
            if working.receivedBroadcasts[entry.batchId] then
                return PlayerTransition.NoCommit(state, now, "mail_broadcast_delivered")
            end
            if (entry.spec.expireAt or 0) > 0 and entry.spec.expireAt <= now then
                return PlayerTransition.NoCommit(state, now, "mail_broadcast_expired")
            end
            local mail = MailEngine.Create(working, TableUtils.DeepCopy(entry.spec), now)
            if not mail then
                return PlayerTransition.Failure(state, now, "MAIL_CAPACITY_FULL", "邮箱已满，全服邮件将在之后自动重试")
            end
            -- Keep receipts for all active batches, including claimed/deleted
            -- mails. Expired batches can no longer be delivered and need no flag.
            local receipts = {}
            for _, active in ipairs(queue) do
                if working.receivedBroadcasts[active.batchId] then receipts[active.batchId] = true end
            end
            receipts[entry.batchId] = true
            working.receivedBroadcasts = receipts
            return PlayerTransition.Finalize(state, working, now, "mail_broadcast", {}, false, false)
        end, function(result)
            if result.ok and result.data.committed then
                delivered = delivered + 1
                if result.data.delta then
                    local ok, err = pcall(self.onDelta, userId, result.data.delta)
                    if not ok then self.log("[Mail] notification failed: " .. tostring(err)) end
                end
            elseif not result.ok then
                pending = pending + 1
                self.log("[Mail] broadcast pending uid=" .. tostring(userId) .. " batch=" .. entry.batchId
                    .. " code=" .. tostring(result.code))
            end
            next()
        end)
    end
    next()
end

function MailService:DeliverBroadcasts(userId, onComplete)
    if self.sharedDelivery then self.sharedDelivery:Sync(userId, onComplete, true); return end
    onComplete = onComplete or function() end
    if self.broadcastPolling[userId] then onComplete(Result(true, { status = "busy", pending = 1 })); return end
    local session = self.profileService:GetSession(userId)
    if not session then onComplete(Result(false, {}, "PROFILE_NOT_LOADED", "玩家档案未加载")); return end
    self.broadcastPolling[userId] = true
    self:_loadBroadcasts(function(result)
        local finished = false
        local function finish(response)
            if finished then return end
            finished = true
            self.broadcastPolling[userId] = nil
            local ok, err = pcall(onComplete, response)
            if not ok then self.log("[Mail] delivery callback failed: " .. tostring(err)) end
        end
        if not result.ok then finish(result); return end
        local function run(done)
            if self.profileService:GetSession(userId) ~= session then
                finish(Result(false, {}, "STALE_SESSION", "玩家连接已变化")); done(); return
            end
            self:_deliverBroadcastEntries(userId, result.data.entries, function(response)
                finish(response); done()
            end)
        end
        if self.operationQueue then self.operationQueue:Enqueue(userId, {
            run = run,
            onComplete = function(ok, errorResult)
                if not ok then finish(Result(false, {}, "MAIL_DELIVERY_FAILED", errorResult and errorResult.reason)) end
            end,
        })
        else run(function() end) end
    end)
end

--- 创建一封全服邮件批次并立即投递给当前在线玩家；离线玩家登录时自动补发。
--- spec 与 SendMail 一致（title/body/mailType/sender/favorite/expireAt/attachments 等）。
function MailService:SendBroadcast(spec, onComplete, resultSink)
    if self.sharedStore then
        self.sharedStore:QueueBroadcast(spec, function(result)
            if type(resultSink) == "table" then for key, value in pairs(result.data or {}) do resultSink[key] = value end end
            if onComplete then onComplete(result) end
            if result.ok then for _, uid in ipairs(self.profileService:OnlineUserIds()) do
                self.sharedDelivery:Sync(uid, function() end, false)
            end end
        end)
        return
    end
    spec = type(spec) == "table" and spec or {}
    self.broadcastSeq = (self.broadcastSeq or 0) + 1
    local batchId = string.format("broadcast-%d-%s-%d", self.clock(), self.instanceNonce, self.broadcastSeq)
    local bizOrderId = "broadcast:" .. batchId
    local entry = {
        batchId = batchId,
        bizOrderId = bizOrderId,
        spec = TableUtils.DeepCopy(spec),
        createdAt = self.clock(),
    }
    entry.spec.batchId = batchId
    entry.spec.bizOrderId = bizOrderId
    entry.spec.reason = entry.spec.reason or "全服邮件"
    entry.spec.expireAt = entry.spec.expireAt or MailRules.DefaultExpireSeconds(entry.spec.type, entry.createdAt)
    if not self.gateway then
        if onComplete then onComplete(Result(false, {}, "MAIL_CLOUD_UNAVAILABLE", "邮件云存储不可用")) end
        return
    end
    -- Acceptance requires a durable project-wide batch, never an in-memory append.
    self:_loadBroadcasts(function(loaded)
        if not loaded.ok then if onComplete then onComplete(loaded) end; return end
        if #loaded.data.entries >= 512 then
            if onComplete then onComplete(Result(false, {}, "BROADCAST_LIMIT", "有效全服邮件批次已达上限，请等待旧批次到期")) end
            return
        end
        self.gateway:ListAdd(self.authorityUid, BROADCAST_KEY, entry, function(saved)
            if not saved.ok then if onComplete then onComplete(saved) end; return end
            self.broadcastLoadedAt = nil
            self.log("[Mail] broadcast saved batch=" .. batchId)

            local online = self.profileService:OnlineUserIds()
            if type(resultSink) == "table" then
                resultSink.batchId = batchId
                resultSink.totalOnline = #online
                resultSink.delivered = 0
            end
            if #online == 0 then
                if onComplete then onComplete(Result(true, { batchId = batchId, delivered = 0 })) end
                return
            end

            -- 在线玩家逐个补发（DeliverBroadcasts 幂等，已收到的批次自动跳过）
            local index = 1
            local delivered = 0
            local deliveredUsers = {}
            local function next()
                if index > #online then
                    if type(resultSink) == "table" then
                        resultSink.delivered = delivered
                        resultSink.deliveredUsers = deliveredUsers
                    end
                    if onComplete then
                        onComplete(Result(true, {
                            batchId = batchId,
                            delivered = delivered,
                            deliveredUsers = deliveredUsers,
                        }))
                    end
                    return
                end
                local userId = online[index]
                index = index + 1
                self:DeliverBroadcasts(userId, function(result)
                    if result and result.ok and result.data and (result.data.delivered or 0) > 0 then
                        delivered = delivered + (result.data.delivered or 0)
                        deliveredUsers[#deliveredUsers + 1] = userId
                    end
                    next()
                end)
            end
            next()
        end)
    end)
end

-- ============================================================================
-- GM 操作
-- ============================================================================

function MailService:ForceExpire(userId, mailId, onComplete)
    self:_apply(userId, "mail force expire", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local mail = MailEngine.Find(working.mails, mailId)
        if not mail then
            return PlayerTransition.Failure(state, now, "MAIL_NOT_FOUND", "邮件不存在")
        end
        mail.expireAt = now
        return PlayerTransition.Finalize(state, working, now, "mail_force_expire", {}, false, false)
    end, onComplete)
end

function MailService:CleanTest(userId, onComplete, resultSink)
    self:_apply(userId, "mail clean test", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local removed = 0
        local function purge(list)
            local survivors = {}
            for _, mail in ipairs(list) do
                if (mail.batchId or ""):find("gm_test") or (mail.reason or ""):find("GM测试") then
                    removed = removed + 1
                else
                    survivors[#survivors + 1] = mail
                end
            end
            return survivors
        end
        working.mails = purge(working.mails)
        working.mailCache = purge(working.mailCache)
        if removed == 0 then
            return PlayerTransition.NoCommit(state, now, "mail_nothing_to_clean")
        end
        if type(resultSink) == "table" then resultSink.removed = removed end
        MailEngine.TryReplenish(working)
        return PlayerTransition.Finalize(state, working, now, "mail_clean_test", {}, false, false)
    end, onComplete)
end

-- ============================================================================
-- 周期性过期清理
-- ============================================================================

function MailService:Update(timeStep)
    if self.sharedStore then self.sharedStore:Update() end
    if self.sharedDelivery then self.sharedDelivery:Update(timeStep) end
    self.expiryElapsed = self.expiryElapsed + (timeStep or 0)
    if self.expiryElapsed < 30 then return end
    self.expiryElapsed = 0
    local online = self.sharedDelivery and self.sharedDelivery:OnlineInSyncOrder() or self.profileService:OnlineUserIds()
    for _, userId in ipairs(online) do
        local function receive(result)
            if not result.ok then self.log("[Mail] broadcast sync failed uid=" .. tostring(userId) .. " code=" .. tostring(result.code)) end
        end
        if self.sharedDelivery then self.sharedDelivery:Sync(userId, receive, false)
        else self:DeliverBroadcasts(userId, receive) end
        local function expire(done)
            self:_apply(userId, "mail expiry", function(state, now)
                local working = PlayerTransition.Copy(state, now)
                MailEngine.Ensure(working)
                local _, changed = MailEngine.ProcessExpiry(working, now)
                if not changed then
                    return PlayerTransition.NoCommit(state, now, "mail_expiry_noop")
                end
                return PlayerTransition.Finalize(state, working, now, "mail_expiry", {}, false, false)
            end, function(result)
                if not result.ok then
                    self.log("[Mail] expiry failed uid=" .. tostring(userId) .. " code=" .. tostring(result.code))
                elseif result.data.committed and result.data.delta then
                    pcall(self.onDelta, userId, result.data.delta)
                end
                done()
            end)
        end
        if self.operationQueue then self.operationQueue:Enqueue(userId, expire)
        else expire(function() end) end
    end
end

return MailService
