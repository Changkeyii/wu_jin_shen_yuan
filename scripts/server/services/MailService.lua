-- MailService.lua
-- 邮件服务：封装 MailEngine 与 profileService 的读写，提供玩家操作、业务发件与 GM 操作。
-- 所有发放结果以服务端为准，具备幂等保护。

local PlayerTransition = require("server.domain.PlayerTransition")
local MailEngine = require("server.domain.MailEngine")
local MailRules = require("shared.MailRules")
local TableUtils = require("server.domain.TableUtils")

local MailService = {}
MailService.__index = MailService

-- 广播队列最大保留条数（超出后丢弃最旧批次）
local BROADCAST_QUEUE_LIMIT = 200

local function Result(ok, data, code, reason)
    return { ok = ok == true, data = data or {}, code = code or (ok and 0 or -1), reason = tostring(reason or "") }
end

function MailService.New(options)
    options = options or {}
    assert(options.profileService, "MailService requires profileService")
    return setmetatable({
        profileService = options.profileService,
        log = options.log or print,
        clock = options.clock or os.time,
        expiryElapsed = 0,
        broadcasts = {},
        broadcastSeq = 0,
    }, MailService)
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
    return Result(true, MailEngine.List(state, self.clock(), scope))
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

--- 阅读标记（玩家手动/自动标记已读）
function MailService:MarkRead(userId, mailId, onComplete)
    self.profileService:Apply(userId, "mail read", function(state, now)
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
    self.profileService:Apply(userId, "mail claim", function(state, now)
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
                            name = attachment.name, count = attachment.count,
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
    self.profileService:Apply(userId, "mail claim all", function(state, now)
        local proposal = MailEngine.ClaimAll(state, now)
        if proposal.ok and proposal.state and type(resultSink) == "table" then
            MailEngine.Ensure(proposal.state)
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
                end
            end
            resultSink.claimedCount = claimedCount
        end
        return proposal
    end, onComplete)
end

--- 收藏 / 取消收藏
function MailService:Favorite(userId, mailId, onComplete)
    self.profileService:Apply(userId, "mail favorite", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local ok, code = MailEngine.Favorite(working, mailId)
        if not ok then return PlayerTransition.Failure(state, now, code, MailRules.CLAIM_ERRORS[code] or code) end
        return PlayerTransition.Finalize(state, working, now, "mail_favorite", {}, false, false)
    end, onComplete)
end

function MailService:Unfavorite(userId, mailId, onComplete)
    self.profileService:Apply(userId, "mail unfavorite", function(state, now)
        local working = PlayerTransition.Copy(state, now)
        MailEngine.Ensure(working)
        local ok, code = MailEngine.Unfavorite(working, mailId)
        if not ok then return PlayerTransition.Failure(state, now, code, MailRules.CLAIM_ERRORS[code] or code) end
        return PlayerTransition.Finalize(state, working, now, "mail_unfavorite", {}, false, false)
    end, onComplete)
end

--- 删除（普通）
function MailService:Delete(userId, mailId, onComplete)
    self.profileService:Apply(userId, "mail delete", function(state, now)
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
    self.profileService:Apply(userId, "mail unfavorite delete", function(state, now)
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
    self.profileService:Apply(userId, "mail delete read", function(state, now)
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
    self.profileService:Apply(userId, "mail send", function(state, now)
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
function MailService:DeliverBroadcasts(userId, onComplete)
    if #self.broadcasts == 0 then
        if onComplete then onComplete(Result(true, { delivered = 0 })) end
        return
    end
    local queue = {}
    for i = 1, #self.broadcasts do queue[i] = self.broadcasts[i] end
    local index = 1
    local delivered = 0
    local function next()
        if index > #queue then
            if onComplete then onComplete(Result(true, { delivered = delivered })) end
            return
        end
        local entry = queue[index]
        index = index + 1
        self.profileService:Apply(userId, "mail broadcast", function(state, now)
            local working = PlayerTransition.Copy(state, now)
            MailEngine.Ensure(working)
            if type(working.receivedBroadcasts) ~= "table" then working.receivedBroadcasts = {} end
            if working.receivedBroadcasts[entry.batchId] then
                return PlayerTransition.NoCommit(state, now, "mail_broadcast_delivered")
            end
            local mail = MailEngine.Create(working, TableUtils.DeepCopy(entry.spec), now)
            if not mail then
                return PlayerTransition.Failure(state, now, "MAIL_CAPACITY_FULL", "邮箱已满，全服邮件将在之后自动重试")
            end
            working.receivedBroadcasts[entry.batchId] = true
            return PlayerTransition.Finalize(state, working, now, "mail_broadcast", {}, false, false)
        end, function(result)
            if result.ok then delivered = delivered + 1 end
            next()
        end)
    end
    next()
end

--- 创建一封全服邮件批次并立即投递给当前在线玩家；离线玩家登录时自动补发。
--- spec 与 SendMail 一致（title/body/mailType/sender/favorite/expireAt/attachments 等）。
function MailService:SendBroadcast(spec, onComplete, resultSink)
    spec = type(spec) == "table" and spec or {}
    self.broadcastSeq = (self.broadcastSeq or 0) + 1
    local batchId = string.format("broadcast-%d-%d", self.clock(), self.broadcastSeq)
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
    self.broadcasts[#self.broadcasts + 1] = entry

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
end

-- ============================================================================
-- GM 操作
-- ============================================================================

function MailService:ForceExpire(userId, mailId, onComplete)
    self.profileService:Apply(userId, "mail force expire", function(state, now)
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
    self.profileService:Apply(userId, "mail clean test", function(state, now)
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
    self.expiryElapsed = self.expiryElapsed + (timeStep or 0)
    if self.expiryElapsed < 30 then return end
    self.expiryElapsed = 0
    -- 广播队列只保留最近 BROADCAST_QUEUE_LIMIT 条
    if #self.broadcasts > BROADCAST_QUEUE_LIMIT then
        local keep = {}
        for i = #self.broadcasts - BROADCAST_QUEUE_LIMIT + 1, #self.broadcasts do
            keep[#keep + 1] = self.broadcasts[i]
        end
        self.broadcasts = keep
    end
    for _, userId in ipairs(self.profileService:OnlineUserIds()) do
        self.profileService:Apply(userId, "mail expiry", function(state, now)
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
            end
        end)
    end
end

return MailService
