-- Shared mail sources and per-player receipts. No process-local reward source.
-- Every read/modify/write uses a non-refreshing QuotaAdd revision in BatchCommit.
local Copy = require("server.domain.TableUtils").DeepCopy
local Rules = require("shared.MailRules")
local Config = require("server.ServerConfig")
---@class CloudMailStore
---@field gateway table
---@field clock fun(): integer
---@field authorityUid integer
---@field encode function?
---@field decode function?
---@field log function
---@field requests table
---@field unknown table
---@field publicWaiters function[]
---@field buckets table<integer, table>
---@field sequence integer
---@field nonce string
---@field budget table
---@field foreground boolean
---@field rateUntil integer?
---@field publicAt integer?
---@field publicResult table?
---@field foregroundUntil table
local Store = {}
Store.__index = Store
Store.VERSION = "shared-queue-v3"
Store.Keys = {
    MANIFEST = "mail_v3_directory", PUBLIC_GUARD = "mail_v3_directory_rev",
    PENDING = "mail_v3_pending", LEDGER = "mail_v3_ledger",
    AUDIT = "mail_v3_audit", PLAYER_GUARD = "mail_v3_player_rev",
    LEGACY_PUBLIC = "abyss_broadcast_mail_v1",
}
Store.Limits = { PUBLIC = 512, BUCKETS = 16, BUCKET = 32, PERSONAL = 300,
    AUDIT = 64, DOCUMENT_BYTES = 4096, MAIL_BYTES = 8192, SEQUENCE = 2147483647 }
local function Ok(data) return { ok = true, data = data or {} } end
local function Fail(code, reason, data)
    return { ok = false, code = code, reason = reason or tostring(code), data = data or {} }
end
Store.Ok, Store.Fail = Ok, Fail
function Store.Bucket(index) return string.format("mail_v3_public_%02d", index) end
function Store.Base36(n)
    if n == 0 then return "0" end
    local digits, value = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    while n > 0 do
        local d = n % 36; value = digits:sub(d + 1, d + 1) .. value; n = n // 36
    end
    return value
end
function Store.DecodeReceipts(value)
    if type(value) ~= "string" then return nil end
    local found, count = {}, 0
    if value == "" then return found end
    for item in (value .. ","):gmatch("([^,]*),") do
        local n = tonumber(item, 36)
        if not n or n < 1 or n > Store.Limits.SEQUENCE or Store.Base36(n) ~= item or found[n] then return nil end
        found[n] = true; count = count + 1
    end
    return count <= 512 and found or nil
end
function Store.EncodeReceipts(found)
    local order = {}; for n in pairs(found) do order[#order + 1] = n end
    table.sort(order)
    if #order > 512 then return nil end
    for i, n in ipairs(order) do order[i] = Store.Base36(n) end
    return table.concat(order, ",")
end
function Store.RowId(row)
    local id = math.tointeger(tonumber(row.list_id or row.listId or row.id))
    return id and id > 0 and id or nil
end
function Store.IsActive(source, now)
    return source.spec.expireAt == 0 or source.spec.expireAt > now
end
---@return CloudMailStore
function Store.New(options)
    options = options or {}
    return setmetatable({ gateway = assert(options.gateway), clock = options.clock or os.time,
        authorityUid = options.authorityUid or Config.LEADERBOARD_AUTHORITY_UID,
        encode = options.encodeJson or (_G.cjson and _G.cjson.encode),
        decode = options.decodeJson or (_G.cjson and _G.cjson.decode),
        log = options.log or print, requests = {}, unknown = {}, publicWaiters = {},
        buckets = {}, sequence = 0, nonce = options.instanceNonce or
            (tostring({}):gsub("[^%w]", "") .. tostring(math.random(1, 999999999))),
        budget = { at = 0, read = 0, write = 0, sharedRead = 0, legacyRead = 0 }, foreground = true,
        foregroundUntil = {},
    }, Store)
end
function Store:_decode(value)
    if type(value) == "string" and self.decode then
        local ok, decoded = pcall(self.decode, value); if ok then return decoded end
    end
    return value
end
function Store:CheckBytes(value, limit)
    if not self.encode then return false, "JSON_CODEC_UNAVAILABLE" end
    local ok, encoded = pcall(self.encode, value)
    return ok and type(encoded) == "string" and #encoded <= limit, ok and "MAIL_BYTES_LIMIT" or "INVALID_JSON"
end
function Store:ValidSource(value, broadcast)
    if type(value) ~= "table" or value.protocol ~= self.VERSION or type(value.id) ~= "string"
        or #value.id == 0 or #value.id > 128 or type(value.spec) ~= "table" then return false end
    local spec = value.spec
    if not Rules.TYPES[spec.type] or type(spec.title) ~= "string" or #spec.title > Rules.MAX_TITLE
        or type(spec.body) ~= "string" or #spec.body > Rules.MAX_BODY
        or type(spec.expireAt) ~= "number" or spec.expireAt % 1 ~= 0
        or spec.expireAt < (broadcast and 0 or 1)
        or type(spec.attachments) ~= "table" or #spec.attachments > Rules.MAX_ATTACHMENTS then return false end
    for _, a in ipairs(spec.attachments) do
        if type(a) ~= "table" or not Rules.ATTACH_KINDS[a.kind] or type(a.count) ~= "number"
            or a.count < 1 or a.count > 1000000000 or a.count % 1 ~= 0 then return false end
        if a.kind == "currency" and a.currency ~= "gold" and a.currency ~= "fragments" then return false end
        if a.kind == "equipment" and type(a.equipmentId) ~= "string" then return false end
        if a.kind == "item" and type(a.itemId) ~= "string" then return false end
    end
    if broadcast and (type(value.sequence) ~= "number" or value.sequence % 1 ~= 0
        or value.sequence < 1 or value.sequence > self.Limits.SEQUENCE
        or value.id ~= "broadcast-v3-" .. self.Base36(value.sequence)) then return false end
    if not broadcast and value.sequence ~= nil then return false end
    return self:CheckBytes(value, self.Limits.MAIL_BYTES)
end
function Store:_source(id, spec, sequence)
    spec = type(spec) == "table" and Copy(spec) or {}
    spec.type = spec.type or "notice"; spec.attachments = spec.attachments or {}
    spec.expireAt = spec.expireAt or Rules.DefaultExpireSeconds(spec.type, self.clock())
    spec.bizOrderId = id
    return { protocol = self.VERSION, id = id, sequence = sequence, spec = spec, createdAt = self.clock() }
end
function Store:_token()
    self.sequence = self.sequence + 1
    return "mq-" .. self.nonce .. "-" .. tostring(self.sequence)
end
-- Reserve 20 requests/minute for explicit mailbox/GM actions; background work
-- receives a retry time rather than entering an unbounded in-memory work queue.
function Store:Reserve(kind, foreground, legacy)
    local now = self.clock()
    if now >= self.budget.at + 60 then self.budget = { at = now, read = 0, write = 0, sharedRead = 0, legacyRead = 0 } end
    if self.rateUntil and now < self.rateUntil then return false, self.rateUntil end
    local limit = foreground == false and 40 or 60
    if self.budget[kind] >= limit then return false, self.budget.at + 60 end
    if kind == "read" and foreground == false then
        local group = legacy and "legacyRead" or "sharedRead"
        if self.budget[group] >= (legacy and 12 or 28) then return false, self.budget.at + 60 end
        self.budget[group] = self.budget[group] + 1
    end
    self.budget[kind] = self.budget[kind] + 1
    return true
end
function Store:Request(kind, foreground, invoke, callback, legacy)
    local allowed, retryAt = self:Reserve(kind, foreground, legacy)
    if not allowed then callback(Fail("MAIL_RATE_DEFERRED", "邮件同步已排队，稍后自动重试", { retryAt = retryAt })); return end
    local request = { deadline = self.clock() + 10, kind = kind }
    self.requests[request] = true
    request.finish = function(result)
        if not self.requests[request] then return end
        self.requests[request] = nil
        if result.code == -429 then self.rateUntil = self.clock() + 60 end
        callback(result)
    end
    local ok, err = pcall(invoke, request.finish)
    if not ok then request.finish(Fail("CLOUD_INVOCATION_ERROR", tostring(err))) end
end
function Store:Read(method, args, callback, foreground)
    self:Request("read", foreground, function(done)
        local call = {}; for i, v in ipairs(args) do call[i] = v end
        call[#call + 1] = done
        self.gateway[method](self.gateway, table.unpack(call))
    end, callback)
end
-- A proxy supplies deadlines to the old Message compatibility path as well.
function Store:LegacyGateway()
    local store = self
    return setmetatable({}, { __index = function(_, name)
        if name == "CommitOperation" then return store.gateway.CommitOperation end
        return function(_, ...)
            local args = { ... }; local done = table.remove(args)
            local read = name:find("Get") ~= nil
            local uid = tonumber(args[1])
            local foreground = uid and (store.foregroundUntil[uid] or 0) > store.clock()
            store:Request(read and "read" or "write", foreground, function(cb)
                args[#args + 1] = cb; store.gateway[name](store.gateway, table.unpack(args))
            end, done, true)
        end
    end })
end
function Store:_emptyManifest()
    local m = { protocol = self.VERSION, version = 0, sequence = 0, buckets = {}, migrated = false }
    for i = 1, 16 do m.buckets[i] = { version = 0, count = 0 } end
    return m
end
function Store:_manifest(value)
    if value == nil then return self:_emptyManifest() end
    value = self:_decode(value)
    if type(value) ~= "table" or value.protocol ~= self.VERSION or type(value.version) ~= "number"
        or value.version < 0 or value.version % 1 ~= 0 or value.version > self.Limits.SEQUENCE
        or type(value.sequence) ~= "number" or value.sequence < 0 or value.sequence % 1 ~= 0
        or value.sequence > self.Limits.SEQUENCE or type(value.buckets) ~= "table" or #value.buckets ~= 16 then return nil end
    for _, bucket in ipairs(value.buckets) do
        if type(bucket) ~= "table" or type(bucket.version) ~= "number" or bucket.version < 0
            or bucket.version % 1 ~= 0 or bucket.version > value.version
            or type(bucket.count) ~= "number" or bucket.count % 1 ~= 0
            or bucket.count < 0 or bucket.count > 32 then return nil end
    end
    if not self:CheckBytes(value, 4096) then return nil end
    return Copy(value)
end
function Store:_ledger(value)
    if value == nil then return { protocol = self.VERSION, version = 0, received = "" } end
    value = self:_decode(value)
    if type(value) ~= "table" or value.protocol ~= self.VERSION or type(value.version) ~= "number"
        or value.version < 0 or value.version % 1 ~= 0 or value.version > self.Limits.SEQUENCE
        or not self.DecodeReceipts(value.received) or not self:CheckBytes(value, 4096) then return nil end
    return Copy(value)
end
function Store:_commit(scope, uid, key, guard, before, after, extra, callback, foreground)
    if self.unknown[scope] then callback(Fail("WRITE_UNCONFIRMED", "邮件写入结果正在确认")); return end
    if before.version >= self.Limits.SEQUENCE then callback(Fail("MAIL_VERSION_LIMIT", "邮件云版本达到上限")); return end
    after.version = before.version + 1; after.lastWriteId = self:_token()
    if not self:CheckBytes(after, 4096) then callback(Fail("MAIL_BYTES_LIMIT", "邮件目录或账本超过4 KiB")); return end
    local operations = {
        { kind = "quota_add", userId = uid, key = guard, value = 1, limit = after.version },
        { kind = "score_set", userId = uid, key = key, value = after },
    }
    for _, op in ipairs(extra or {}) do operations[#operations + 1] = op end
    local attempt = { key = key, uid = uid, version = before.version, writeId = after.lastWriteId, retryAt = self.clock() + 15 }
    self:Request("write", foreground, function(done)
        self.gateway:BatchCommit("mail " .. scope, operations, function(result)
            attempt.actual = result; done(result)
        end)
    end, function(result)
        if result.code == "WRITE_UNCONFIRMED" then self.unknown[scope] = attempt end
        if result.ok then result.data.document = after end
        -- Never reuse an old manifest after a conflict or an uncertain commit.
        if scope == "public" then self.publicAt = nil end
        callback(result)
    end)
end
function Store:PlayerOperations(uid, before, after, extras)
    after.version = before.version + 1; after.lastWriteId = self:_token()
    if before.version >= self.Limits.SEQUENCE or not self:_ledger(after) then return nil end
    local ops = {
        { kind = "quota_add", userId = uid, key = self.Keys.PLAYER_GUARD, value = 1, limit = after.version },
        { kind = "score_set", userId = uid, key = self.Keys.LEDGER, value = after },
    }
    for _, op in ipairs(extras or {}) do ops[#ops + 1] = op end
    return ops
end
function Store:ReadPlayer(uid, callback, foreground)
    if self.unknown["player-" .. uid] then callback(Fail("WRITE_UNCONFIRMED", "邮件队列写入结果正在确认")); return end
    self:Read("ScoreGet", { uid, self.Keys.LEDGER }, function(result)
        if not result.ok then callback(result); return end
        local ledger = self:_ledger((result.data.scores or {})[self.Keys.LEDGER])
        if not ledger then callback(Fail("CORRUPT_MAIL_LEDGER", "邮件账本异常，源记录已保留")); return end
        self:Read("ListGet", { uid, self.Keys.PENDING }, function(pending)
            if not pending.ok then callback(pending); return end
            self:Read("ListGet", { uid, self.Keys.AUDIT }, function(audit)
                if not audit.ok then callback(audit); return end
                self:Read("ScoreGet", { uid, self.Keys.LEDGER }, function(check)
                    if not check.ok then callback(check); return end
                    local latest = self:_ledger((check.data.scores or {})[self.Keys.LEDGER])
                    if not latest or latest.version ~= ledger.version then
                        callback(Fail("MAIL_VERSION_CONFLICT", "邮件已由其他实例更新，请重试")); return
                    end
                    callback(Ok({ ledger = ledger, pending = pending.data.items or {}, audit = audit.data.items or {} }))
                end, foreground)
            end, foreground)
        end, foreground)
    end, foreground)
end
function Store:UnconfirmedCount(audit)
    local n = 0
    for _, row in ipairs(audit) do
        local value = self:_decode(row.value)
        if type(value) ~= "table" or value.handoffPending == true then n = n + 1 end
    end
    return n
end
function Store:QueuePersonal(uid, id, spec, callback)
    local source = self:_source(id, spec)
    if not self:ValidSource(source, false) then callback(Fail("INVALID_MAIL_SOURCE", "邮件格式或8 KiB字节上限校验失败", { mailId = id })); return end
    self:ReadPlayer(uid, function(loaded)
        if not loaded.ok then
            loaded.data.mailId, loaded.data.version = id, self.VERSION
            callback(loaded); return
        end
        local data = loaded.data
        for _, rows in ipairs({ data.pending, data.audit }) do
            for _, row in ipairs(rows) do
                local value = self:_decode(row.value)
                if type(value) == "table" and value.id == id then callback(Ok({ status = rows == data.audit and "applied" or "queued", mailId = id, action = "send_mail", version = self.VERSION })); return end
            end
        end
        if #data.pending + self:UnconfirmedCount(data.audit) >= 300 then
            callback(Fail("PERSONAL_MAIL_LIMIT", "个人待派发及未完成交接记录已达300条", { mailId = id })); return
        end
        local after = Copy(data.ledger)
        self:_commit("player-" .. uid, uid, self.Keys.LEDGER, self.Keys.PLAYER_GUARD, data.ledger, after,
            {{ kind = "list_add", userId = uid, key = self.Keys.PENDING, value = source }}, function(result)
                result.data = result.data or {}; result.data.mailId = id; result.data.commandId = id
                result.data.action = "send_mail"; result.data.version = self.VERSION
                if result.ok then result.data.status = "queued" end
                callback(result)
            end, true)
    end, true)
end
function Store:_readPublic(callback, foreground)
    self:Read("ScoreGet", { self.authorityUid, self.Keys.MANIFEST }, function(result)
        if not result.ok then callback(result); return end
        local manifest = self:_manifest((result.data.scores or {})[self.Keys.MANIFEST])
        if not manifest then callback(Fail("CORRUPT_MAIL_DIRECTORY", "公共邮件目录异常，源记录已保留")); return end
        local index = 1
        local function nextBucket()
            local i = index; index = index + 1
            if i > 16 then
                -- Validate a stable snapshot, including an initially absent directory.
                self:Read("ScoreGet", { self.authorityUid, self.Keys.MANIFEST }, function(check)
                    if not check.ok then callback(check); return end
                    local latest = self:_manifest((check.data.scores or {})[self.Keys.MANIFEST])
                    if not latest or latest.version ~= manifest.version then
                        callback(Fail("MAIL_VERSION_CONFLICT", "公共邮件目录已变化，请重试")); return
                    end
                    callback(Ok({ manifest = manifest }))
                end, foreground)
                return
            end
            local cached = self.buckets[i]
            if cached and cached.version == manifest.buckets[i].version then nextBucket(); return end
            if manifest.buckets[i].count == 0 then
                self.buckets[i] = { version = manifest.buckets[i].version, rows = {} }; nextBucket(); return
            end
            self:Read("ListGet", { self.authorityUid, self.Bucket(i) }, function(rows)
                if not rows.ok then callback(rows); return end
                if #(rows.data.items or {}) ~= manifest.buckets[i].count then
                    callback(Fail("MAIL_VERSION_CONFLICT", "公共邮件桶与目录不一致，请重试")); return
                end
                self.buckets[i] = { version = manifest.buckets[i].version, rows = rows.data.items or {} }
                nextBucket()
            end, foreground)
        end
        nextBucket()
    end, foreground)
end
function Store:_changePublic(before, entries, callback, foreground)
    local after, ops, changed = Copy(before), {}, {}
    for _, entry in ipairs(entries) do
        if entry.deleteBucket then
            local i = entry.deleteBucket
            ops[#ops + 1] = { kind = "list_delete", listId = entry.listId }
            after.buckets[i].count = after.buckets[i].count - 1; changed[i] = true
        else
            local i
            for b = 1, 16 do if after.buckets[b].count < 32 then i = b; break end end
            if not i then callback(Fail("BROADCAST_LIMIT", "有效全服邮件已达512封，请等待旧邮件到期")); return end
            if after.sequence >= self.Limits.SEQUENCE then callback(Fail("MAIL_SEQUENCE_LIMIT", "全服邮件序号达到上限")); return end
            after.sequence = after.sequence + 1
            local id = "broadcast-v3-" .. self.Base36(after.sequence)
            local source = self:_source(id, entry.spec, after.sequence)
            source.legacyBatchId = entry.legacyBatchId
            if not self:ValidSource(source, true) then callback(Fail("INVALID_MAIL_SOURCE", "邮件格式或8 KiB字节上限校验失败")); return end
            entry.mailId = id
            ops[#ops + 1] = { kind = "list_add", userId = self.authorityUid, key = self.Bucket(i), value = source }
            if entry.legacyListId then ops[#ops + 1] = { kind = "list_delete", listId = entry.legacyListId } end
            after.buckets[i].count = after.buckets[i].count + 1; changed[i] = true
        end
    end
    for i in pairs(changed) do after.buckets[i].version = after.buckets[i].version + 1 end
    self:_commit("public", self.authorityUid, self.Keys.MANIFEST, self.Keys.PUBLIC_GUARD,
        before, after, ops, callback, foreground)
end
function Store:ReadPublic(callback, foreground, force)
    if self.unknown.public then callback(Fail("WRITE_UNCONFIRMED", "公共邮件写入正在确认")); return end
    if not force and self.publicAt and self.clock() - self.publicAt < 60 then callback(self.publicResult); return end
    self.publicWaiters[#self.publicWaiters + 1] = callback
    if #self.publicWaiters > 1 then return end
    local function finish(result)
        if result.ok then self.publicAt = self.clock(); self.publicResult = result end
        local waiters = self.publicWaiters; self.publicWaiters = {}
        for _, done in ipairs(waiters) do
            local ok, err = pcall(done, result); if not ok then self.log("[Mail] public callback: " .. tostring(err)) end
        end
    end
    self:_readPublic(function(read)
        if not read.ok then finish(read); return end
        local manifest, valid, invalid, expired, seen, activeSequences = read.data.manifest, {}, 0, {}, {}, {}
        for i = 1, 16 do
            for _, row in ipairs(self.buckets[i].rows) do
                local source = self:_decode(row.value)
                if type(source) == "table" and type(source.sequence) == "number"
                    and source.sequence % 1 == 0 and source.sequence > 0 and source.sequence <= self.Limits.SEQUENCE
                    and not (type(source.spec) == "table" and type(source.spec.expireAt) == "number"
                        and source.spec.expireAt > 0 and source.spec.expireAt <= self.clock()) then
                    activeSequences[source.sequence] = true
                end
                if not self.RowId(row) or not self:ValidSource(source, true)
                    or source.sequence > manifest.sequence or seen[source.sequence] then
                    invalid = invalid + 1; self.log("[Mail] invalid public source bucket=" .. i .. " row=" .. tostring(self.RowId(row)))
                elseif not self.IsActive(source, self.clock()) then
                    if #expired < 8 then expired[#expired + 1] = { deleteBucket = i, listId = self.RowId(row) } end
                else
                    seen[source.sequence] = true; valid[#valid + 1] = Copy(source)
                end
            end
        end
        table.sort(valid, function(a, b) return a.sequence < b.sequence end)
        local function done()
            finish(Ok({ entries = valid, manifest = manifest, activeSequences = activeSequences,
                invalid = invalid, migrationPending = not manifest.migrated }))
        end
        if #expired > 0 then
            self:_changePublic(manifest, expired, function(clean)
                if clean.ok then manifest = clean.data.document end
                -- A failed cleanup does not hide unrelated valid rewards.
                if not clean.ok then self.log("[Mail] expiry maintenance: " .. tostring(clean.code)) end
                done()
            end, foreground)
        elseif not manifest.migrated then
            self:Read("ListGet", { self.authorityUid, self.Keys.LEGACY_PUBLIC }, function(legacy)
                if not legacy.ok then finish(legacy); return end
                local moves, leftover = {}, false
                local function validLegacy(old)
                    local seq = manifest.sequence + #moves + 1
                    local spec = Copy(old.spec)
                    if spec.expireAt == nil then spec.expireAt = 0 end
                    local candidate = self:_source("broadcast-v3-" .. self.Base36(seq), spec, seq)
                    candidate.legacyBatchId = old.batchId
                    return self:ValidSource(candidate, true)
                end
                for _, row in ipairs(legacy.data.items or {}) do
                    local old = self:_decode(row.value)
                    if type(old) ~= "table" or type(old.batchId) ~= "string" or type(old.spec) ~= "table" or not self.RowId(row) then
                        invalid = invalid + 1; leftover = true
                    elseif not validLegacy(old) then
                        invalid = invalid + 1; leftover = true
                    elseif #moves >= 8 then leftover = true
                    elseif (tonumber(old.spec.expireAt) or 0) > self.clock() then
                        moves[#moves + 1] = { spec = old.spec, legacyBatchId = old.batchId, legacyListId = self.RowId(row) }
                    elseif (tonumber(old.spec.expireAt) or 0) == 0 then
                        -- Zero/absent expiry was an indefinite public source in v1.
                        local spec = Copy(old.spec); spec.expireAt = 0
                        moves[#moves + 1] = { spec = spec, legacyBatchId = old.batchId, legacyListId = self.RowId(row) }
                    else
                        -- Expired old sources cannot produce rewards; preserve them for
                        -- the deployment audit rather than spending a key per tombstone.
                    end
                end
                if #moves > 0 then
                    self:_changePublic(manifest, moves, function(migrated)
                        if not migrated.ok then finish(migrated); return end
                        -- Reload changed buckets. If budget is exhausted, the durable
                        -- move remains valid and the next sync continues migration.
                        self:_readPublic(function(reloaded)
                            if not reloaded.ok then finish(reloaded); return end
                            manifest = reloaded.data.manifest; valid = {}
                            for i = 1, 16 do for _, row in ipairs(self.buckets[i].rows) do
                                local source = self:_decode(row.value)
                                if self:ValidSource(source, true) and self.IsActive(source, self.clock()) then
                                    valid[#valid + 1] = Copy(source); activeSequences[source.sequence] = true
                                end
                            end end
                            done()
                        end, foreground)
                    end, foreground)
                elseif not leftover then
                    local after = Copy(manifest); after.migrated = true
                    self:_commit("public", self.authorityUid, self.Keys.MANIFEST, self.Keys.PUBLIC_GUARD,
                        manifest, after, {}, function(saved)
                            if not saved.ok then finish(saved); return end
                            manifest = saved.data.document; done()
                        end, foreground)
                else done() end
            end, foreground)
        else done() end
    end, foreground)
end
function Store:QueueBroadcast(spec, callback)
    self:ReadPublic(function(loaded)
        if not loaded.ok then callback(loaded); return end
        if loaded.data.migrationPending then callback(Fail("MAIL_MIGRATION_PENDING", "旧邮件迁移中，请稍后发件")); return end
        local entry = { spec = spec }
        self:_changePublic(loaded.data.manifest, { entry }, function(result)
            result.data = result.data or {}; result.data.mailId = entry.mailId
            result.data.batchId = entry.mailId; result.data.version = self.VERSION
            if result.ok then result.data.status = "queued" end
            callback(result)
        end, true)
    end, true, true)
end
function Store:TrimAudit(rows, added)
    local completed = {}
    for _, row in ipairs(rows) do
        local value = self:_decode(row.value)
        if type(value) == "table" and value.handoffPending ~= true and self.RowId(row) then
            completed[#completed + 1] = { list_id = self.RowId(row), value = value }
        end
    end
    table.sort(completed, function(a, b) return (a.value.at or 0) < (b.value.at or 0) end)
    local ops = {}
    for i = 1, math.max(0, #completed + (added or 0) - 64) do
        ops[#ops + 1] = { kind = "list_delete", listId = self.RowId(completed[i]) }
    end
    return ops
end
function Store:Update()
    local now = self.clock(); local expired = {}
    for request in pairs(self.requests) do if now >= request.deadline then expired[#expired + 1] = request end end
    for _, request in ipairs(expired) do
        request.finish(Fail(request.kind == "write" and "WRITE_UNCONFIRMED" or "CLOUD_READ_TIMEOUT",
            request.kind == "write" and "邮件写入超时，结果待确认" or "邮件读取超时，请稍后重试"))
    end
    for scope, attempt in pairs(self.unknown) do
        if not attempt.reading and now >= attempt.retryAt then
            attempt.reading = true; attempt.retryAt = now + 5
            self:Read("ScoreGet", { attempt.uid, attempt.key }, function(result)
                attempt.reading = false
                if self.unknown[scope] ~= attempt or not result.ok then return end
                local value = self:_decode((result.data.scores or {})[attempt.key])
                if (type(value) == "table" and value.version > attempt.version)
                    or (attempt.actual and not attempt.actual.ok) then
                    self.unknown[scope] = nil
                    if scope == "public" then self.publicAt = nil end
                end
            end, true)
        end
    end
end
return Store
