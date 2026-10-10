local Store = require("server.services.CloudMailStore")
local Mail = require("server.domain.MailEngine")
local Transition = require("server.domain.PlayerTransition")
local Copy = require("server.domain.TableUtils").DeepCopy
---@class SharedMailDelivery
---@field store CloudMailStore
---@field profile table
---@field queue table?
---@field onDelta function
---@field clock fun(): integer
---@field log function
---@field syncing table
---@field status table
---@field failures table
---@field retryElapsed number
local Delivery = {}
Delivery.__index = Delivery
---@type integer[]
local RETRY = { 5, 15, 30, 60 }
---@return SharedMailDelivery
function Delivery.New(options)
    return setmetatable({ store = assert(options.store), profile = assert(options.profileService),
        queue = options.operationQueue, onDelta = options.onDelta or function() end,
        clock = options.clock or os.time, log = options.log or print,
        syncing = {}, status = {}, failures = {}, retryElapsed = 0 }, Delivery)
end
function Delivery:Status(uid)
    return self.status[uid] or { state = "pending", retryAt = 0, protocol = Store.VERSION }
end
local function Proof(state, source)
    if source.legacyBatchId and (state.receivedBroadcasts or {})[source.legacyBatchId] then return true end
    for _, rows in ipairs({ state.mails or {}, state.mailCache or {} }) do for _, m in ipairs(rows) do
        if m.bizOrderId == source.id or (source.legacyBatchId and
            m.bizOrderId == "broadcast:" .. source.legacyBatchId) then return true end
    end end
    return false
end
function Delivery:_publish(uid, result)
    if result.ok and result.data.committed and result.data.delta then
        local ok, err = pcall(self.onDelta, uid, result.data.delta)
        if not ok then self.log("[Mail] notification: " .. tostring(err)) end
    end
end
function Delivery:_deliver(uid, public, data, callback, foreground)
    local ledger, audit = Copy(data.ledger), data.audit
    local received = Store.DecodeReceipts(ledger.received)
    local active, sources, seen, invalid, auditProof = {}, {}, {}, public.invalid or 0, {}
    for _, row in ipairs(audit) do
        local value = self.store:_decode(row.value)
        if type(value) == "table" and type(value.id) == "string" then auditProof[value.id] = true end
    end
    for _, source in ipairs(public.entries or {}) do
        if Store.IsActive(source, self.clock()) then active[source.sequence] = true end
    end
    for seq in pairs(public.activeSequences or {}) do active[seq] = true end
    for _, source in ipairs(public.entries or {}) do
        if not Store.IsActive(source, self.clock()) then active[source.sequence] = nil end
    end
    -- Only remove receipts for sources confirmed absent in a stable public view.
    for seq in pairs(received or {}) do if not active[seq] then received[seq] = nil end end
    for _, row in ipairs(data.pending) do
        local source = self.store:_decode(row.value)
        if not Store.RowId(row) or not self.store:ValidSource(source, false) or seen[source.id] then
            invalid = invalid + 1
            self.log("[Mail] invalid personal source uid=" .. uid .. " row=" .. tostring(Store.RowId(row)))
        else
            source = Copy(source); source.sourceListId = Store.RowId(row)
            seen[source.id] = true; sources[#sources + 1] = source
        end
    end
    for _, source in ipairs(public.entries or {}) do
        if not received[source.sequence] and Store.IsActive(source, self.clock()) then sources[#sources + 1] = source end
    end
    local delivered, pending, changed = 0, 0, false
    local extras, newAudits = {}, 0
    local state = self.profile:GetState(uid)
    if not state then callback(Store.Fail("PROFILE_NOT_LOADED", "玩家存档尚未加载")); return end
    self.profile:Apply(uid, "shared mail delivery", function(before, now)
        local working = Transition.Copy(before, now)
        for _, source in ipairs(sources) do
            if delivered >= 32 then pending = pending + 1
            else
                local already = Proof(working, source) or auditProof[source.id] == true
                local mail
                if not already then mail = Mail.Create(working, Copy(source.spec), now) end
                if already or mail then
                    if not already then delivered = delivered + 1 end
                    changed = true
                    if source.sequence then received[source.sequence] = true end
                    if source.legacyBatchId then
                        working.receivedBroadcasts = working.receivedBroadcasts or {}
                        working.receivedBroadcasts[source.legacyBatchId] = true
                    end
                    if source.sourceListId then
                        extras[#extras + 1] = { kind = "list_delete", listId = source.sourceListId }
                        if not auditProof[source.id] then
                            newAudits = newAudits + 1; auditProof[source.id] = true
                            extras[#extras + 1] = { kind = "list_add", userId = uid, key = Store.Keys.AUDIT,
                                value = { protocol = Store.VERSION, id = source.id, stage = "delivered", at = now,
                                    mailboxId = mail and mail.id or nil, handoffPending = false } }
                        end
                    end
                else pending = pending + 1 end
            end
        end
        ledger.received = Store.EncodeReceipts(received)
        changed = changed or ledger.received ~= data.ledger.received
        if not changed then return Transition.NoCommit(before, now, "mail_sync_noop") end
        local allowed, retryAt = self.store:Reserve("write", foreground)
        if not allowed then
            return Transition.Failure(before, now, "MAIL_RATE_DEFERRED", "邮件同步等待预算（" .. tostring(retryAt) .. "）")
        end
        for _, op in ipairs(self.store:TrimAudit(audit, newAudits)) do extras[#extras + 1] = op end
        local operations = self.store:PlayerOperations(uid, data.ledger, ledger, extras)
        if not operations then return Transition.Failure(before, now, "MAIL_BYTES_LIMIT", "邮件账本超过4 KiB或版本上限") end
        local proposal = Transition.Finalize(before, working, now, "mail_delivery", {}, false, false)
        proposal.cloudOperations = operations
        return proposal
    end, function(result)
        self:_publish(uid, result)
        if not result.ok then callback(result); return end
        callback(Store.Ok({ delivered = delivered, pending = pending + invalid,
            invalid = invalid, migrationPending = public.migrationPending,
            status = pending + invalid > 0 and "pending" or "synced" }))
    end)
end
function Delivery:_ack(uid, row, callback)
    self.store:ReadPlayer(uid, function(loaded)
        if not loaded.ok then callback(loaded); return end
        local current
        for _, candidate in ipairs(loaded.data.audit) do
            if Store.RowId(candidate) == Store.RowId(row) then current = self.store:_decode(candidate.value); break end
        end
        if not current or current.handoffPending ~= true then callback(Store.Ok()); return end
        current = Copy(current); current.handoffPending = false; current.stage = "delivered"; current.at = self.clock()
        local ops = self.store:TrimAudit(loaded.data.audit, 1)
        ops[#ops + 1] = { kind = "list_modify", listId = Store.RowId(row), value = current }
        self.store:_commit("player-" .. uid, uid, Store.Keys.LEDGER, Store.Keys.PLAYER_GUARD,
            loaded.data.ledger, Copy(loaded.data.ledger), ops, callback, true)
    end, true)
end
function Delivery:_handoffs(uid, data, callback, foreground)
    local index, pending = 1, 0
    local function nextRow()
        local row = data.audit[index]; index = index + 1
        if not row then callback(Store.Ok({ pending = pending })); return end
        local value = self.store:_decode(row.value)
        if type(value) ~= "table" or not value.handoffPending then nextRow(); return end
        self.store:Request("write", foreground, function(done)
            self.store.gateway:MessageDelete(value.messageId, done)
        end, function(deleted)
            if not deleted.ok then
                if not value.messageKey then pending = pending + 1; nextRow(); return end
                -- The delete may have succeeded while its callback was lost.
                -- Only a successful read of BOTH filters proves source absence.
                self.store:Read("MessageGet", { uid, value.messageKey, false }, function(unread)
                    if not unread.ok then pending = pending + 1; nextRow(); return end
                    self.store:Read("MessageGet", { uid, value.messageKey, true }, function(read)
                        if not read.ok then pending = pending + 1; nextRow(); return end
                        local present = false
                        for _, rows in ipairs({ unread.data.messages or {}, read.data.messages or {} }) do
                            for _, m in ipairs(rows) do
                                if tonumber(m.message_id or m.messageId) == value.messageId then present = true end
                            end
                        end
                        if present then pending = pending + 1; nextRow(); return end
                        self:_ack(uid, row, function(acked)
                            if not acked.ok then pending = pending + 1 end
                            nextRow()
                        end)
                    end, foreground)
                end, foreground)
                return
            end
            self:_ack(uid, row, function(acked)
                if not acked.ok then pending = pending + 1 end
                nextRow()
            end)
        end)
    end
    nextRow()
end
function Delivery:Sync(uid, callback, foreground)
    callback = callback or function() end
    local originalCallback = callback
    callback = function(result)
        local ok, err = pcall(originalCallback, result)
        if not ok then self.log("[Mail] sync callback: " .. tostring(err)) end
    end
    local session = self.profile:GetSession(uid)
    if not session then callback(Store.Fail("PROFILE_NOT_LOADED", "玩家存档尚未加载")); return end
    local generation = session.generation
    if foreground ~= false then self.store.foregroundUntil[uid] = self.clock() + 10 end
    if self.syncing[uid] then callback(Store.Ok({ status = "busy", pending = 1 })); return end
    local status = self:Status(uid)
    if self.clock() < (status.retryAt or 0) then
        callback(Store.Fail(status.error or "MAIL_RETRY_PENDING", "邮件同步等待重试", { retryAt = status.retryAt })); return
    end
    local token = {}; self.syncing[uid] = token
    local function finish(result)
        if self.syncing[uid] ~= token then return end
        self.syncing[uid] = nil
        if self.profile:GetSession(uid) ~= session or session.generation ~= generation then
            callback(Store.Fail("STALE_SESSION", "玩家连接已变化")); return
        end
        local pending = not result.ok or (result.data.pending or 0) > 0 or result.data.migrationPending
        local attempt = pending and ((self.failures[uid] or 0) + 1) or 0
        self.failures[uid] = attempt
        self.status[uid] = { state = result.code == "WRITE_UNCONFIRMED" and "confirming"
                or (pending and "pending" or "synced"), protocol = Store.VERSION,
            error = result.ok and nil or result.code, reason = result.reason,
            lastCloudSyncAt = token.lastCloudSyncAt or status.lastCloudSyncAt or 0,
            retryAt = pending and math.max(result.data.retryAt or 0,
                self.clock() + RETRY[math.min(4, attempt)]) or 0, invalid = result.data.invalid or 0 }
        callback(result)
    end
    self.store:ReadPublic(function(public)
        if self.syncing[uid] ~= token then return end
        if not public.ok then finish(public); return end
        self.store:ReadPlayer(uid, function(player)
            if self.syncing[uid] ~= token then return end
            if not player.ok then finish(player); return end
            token.lastCloudSyncAt = self.clock()
            local function run(done)
                if self.profile:GetSession(uid) ~= session or session.generation ~= generation then
                    finish(Store.Fail("STALE_SESSION", "玩家连接已变化")); done(); return
                end
                -- This reservation includes the profile transaction (which uses the
                -- repository's own 10-second write confirmation protocol).
                self:_deliver(uid, public.data, player.data, function(result)
                    if not result.ok then finish(result); done(); return end
                    finish(result); done()
                    -- Source Message deletion is separate from BatchCommit. Its
                    -- proof is durable and cannot be trimmed until acknowledgement.
                    self:_handoffs(uid, player.data, function() end, foreground)
                end, foreground)
            end
            if self.queue then self.queue:Enqueue(uid, { run = run, onComplete = function(ok, err)
                if not ok then finish(Store.Fail("MAIL_DELIVERY_FAILED", err and err.reason)) end
            end }) else run(function() end) end
        end, foreground)
    end, foreground)
end

function Delivery:OnlineInSyncOrder()
    local ids = self.profile:OnlineUserIds()
    table.sort(ids, function(a, b)
        local av, bv = self:Status(a).lastCloudSyncAt or 0, self:Status(b).lastCloudSyncAt or 0
        return av < bv or (av == bv and a < b)
    end)
    return ids
end
function Delivery:Update(timeStep)
    self.retryElapsed = self.retryElapsed + (timeStep or 0)
    if self.retryElapsed < 1 then return end
    self.retryElapsed = 0
    for _, uid in ipairs(self:OnlineInSyncOrder()) do
        local status = self:Status(uid)
        if status.state ~= "synced" and status.retryAt > 0 and self.clock() >= status.retryAt then
            self:Sync(uid, function() end, false)
        end
    end
    for uid in pairs(self.status) do
        if not self.profile:GetSession(uid) and not self.syncing[uid] then
            self.status[uid], self.failures[uid], self.store.foregroundUntil[uid] = nil, nil, nil
        end
    end
end
-- Called from AdminService while already holding the player's operation queue.
function Delivery:DeliverLegacy(command, callback)
    local uid, id = command.targetUid, "gm-mail:" .. command.commandId
    self.store:ReadPlayer(uid, function(loaded)
        if not loaded.ok then callback(loaded); return end
        local proof
        for _, row in ipairs(loaded.data.audit) do
            local value = self.store:_decode(row.value)
            if type(value) == "table" and value.id == id then proof = row; break end
        end
        if proof then callback(Store.Ok({ alreadyApplied = true, status = "alreadyApplied", handoff = proof })); return end
        if #loaded.data.pending + self.store:UnconfirmedCount(loaded.data.audit) >= 300 then
            callback(Store.Fail("PERSONAL_MAIL_LIMIT", "旧邮件交接等待空间，源任务已保留")); return
        end
        local source = self.store:_source(id, command.payload.spec)
        if not self.store:ValidSource(source, false) then callback(Store.Fail("INVALID_MAIL_SOURCE", "旧邮件格式异常，源任务已保留")); return end
        local allowed, retryAt = self.store:Reserve("write", true)
        if not allowed then callback(Store.Fail("MAIL_RATE_DEFERRED", "旧邮件交接等待预算", { retryAt = retryAt })); return end
        self.profile:Apply(uid, "legacy mail handoff", function(state, now)
            local working, already = Transition.Copy(state, now), command.legacyComplete == true
            for _, commandId in ipairs(state.appliedGmCommandIds or {}) do if commandId == command.commandId then already = true end end
            already = already or Proof(state, source)
            local mail
            if not already then mail = Mail.Create(working, source.spec, now) end
            if not already and not mail then return Transition.Failure(state, now, "MAIL_CAPACITY_FULL", "邮箱已满，旧任务保留重试") end
            local evidence = { protocol = Store.VERSION, id = id, commandId = command.commandId,
                messageId = command.messageId, messageKey = command.messageKey,
                stage = "handoff_pending", handoffPending = true, at = now,
                mailboxId = mail and mail.id or nil }
            local ops = self.store:PlayerOperations(uid, loaded.data.ledger, Copy(loaded.data.ledger),
                {{ kind = "list_add", userId = uid, key = Store.Keys.AUDIT, value = evidence, resultKey = "mailHandoff" }})
            if not ops then return Transition.Failure(state, now, "MAIL_BYTES_LIMIT", "邮件账本超过上限") end
            local proposal = Transition.Finalize(state, working, now, "mail_legacy_handoff", {}, false, false)
            proposal.cloudOperations = ops
            return proposal
        end, callback)
    end, true)
end
function Delivery:Inspect(uid, mailId, callback)
    local function failed(result)
        result.data = result.data or {}
        result.data.delivery = { version = Store.VERSION, targetUid = uid, mailId = mailId,
            stage = result.code == "WRITE_UNCONFIRMED" and "confirming" or "sync_failed",
            error = result.code, retryAt = result.data.retryAt or self:Status(uid).retryAt }
        callback(result)
    end
    self.store:ReadPublic(function(public)
        if not public.ok then failed(public); return end
        self.store:ReadPlayer(uid, function(player)
            if not player.ok then failed(player); return end
            local stage, errorCode = "unknown", nil
            local received = Store.DecodeReceipts(player.data.ledger.received)
            local waiting = 0
            for _, source in ipairs(public.data.entries) do
                if not received[source.sequence] then waiting = waiting + 1 end
                if source.id == mailId then stage = received[source.sequence] and "delivered" or "pending" end
            end
            for _, row in ipairs(player.data.pending) do
                local source = self.store:_decode(row.value)
                if type(source) == "table" and source.id == mailId then stage = "pending" end
            end
            for _, row in ipairs(player.data.audit) do
                local value = self.store:_decode(row.value)
                if type(value) == "table" and value.id == mailId then stage = value.stage; errorCode = value.error end
            end
            local status = self:Status(uid)
            local label = ({ pending = "待派发", delivered = "已保存到个人邮箱", handoff_pending = "已送达，旧任务交接中", unknown = "无法确认（记录不存在或审计已清理）" })[stage]
            local totals = self.store.gateway.RequestTotals and self.store.gateway:RequestTotals() or nil
            local totalText = totals and string.format("｜实例云请求 读%d/写%d（本分钟）", totals.read, totals.write) or ""
            callback(Store.Ok({ status = string.format("UID %s｜个人待派发 %d｜全服待派发 %d｜%s｜协议 %s%s",
                uid, #player.data.pending, waiting, mailId and label or status.state, Store.VERSION, totalText),
                delivery = { version = Store.VERSION, targetUid = uid, mailId = mailId, stage = stage,
                    error = errorCode or status.error, personalPending = #player.data.pending,
                    broadcastPending = waiting, invalid = public.data.invalid, retryAt = status.retryAt,
                    cloudRequestTotals = totals } }))
        end, true)
    end, true)
end
return Delivery
