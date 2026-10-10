-- Model the shipped pre-mail consumer: unsupported GM actions receive a
-- rejection receipt, then their cloud message is marked read.
local Copy = require('server.domain.TableUtils').DeepCopy
local Repo = require('server.repositories.PlayerProfileRepository')
local Gateway = require('server.dao.ServerCloudGateway')
local Admin = require('server.services.AdminService')
local Profile = require('server.services.PlayerProfileService')
local Policy = require('server.core.AdminPolicy')
local Queue = require('server.core.OperationQueue')
local Factory = require('server.domain.StateFactory')
local Mail = require('server.domain.MailEngine')
local Large = require('shared.LargeNumber')
local now, actor, uid = 1791545000, 1001, 1162201458
local rows, serial, queries, commits = {}, 0, {}, 0
local stringValues, encoded = false, {}
local failDelete, failGet, failReceiptRead = false, false, false
local cloud = {message = {}}
function cloud.message:Send(sender, key, recipient, value, events)
    serial = serial + 1
    rows[#rows + 1] = {message_id = serial, sender = sender, recipient = recipient,
        key = key, value = Copy(value), read = false}
    events.ok(0, '')
end
function cloud.message:Get(userId, key, read, events)
    queries[#queries + 1] = {userId = userId, key = key, read = read}
    if failGet then failGet = false; events.error(-503, 'get unavailable'); return end
    if failReceiptRead and key == Repo.Keys.GM_RESULT and read then
        failReceiptRead = false; events.error(-503, 'read receipts unavailable'); return
    end
    local found = {}
    for _, row in ipairs(rows) do
        if row.recipient == userId and row.key == key and row.read == read then
            local result = Copy(row)
            if stringValues then
                local value = Copy(result.value)
                value.targetUid = tostring(value.targetUid)
                if value.actorUid then value.actorUid = tostring(value.actorUid) end
                local token = 'serialized:' .. result.message_id
                encoded[token] = value
                result.value, result.message_id = token, tostring(result.message_id)
            end
            found[#found + 1] = result
        end
    end
    events.ok(found)
end
function cloud.message:MarkRead(id, events)
    for _, row in ipairs(rows) do if row.message_id == id then row.read = true end end
    events.ok(0, '')
end
function cloud.message:Delete(id, events)
    if failDelete then failDelete = false; events.error(-503, 'delete unavailable'); return end
    for i, row in ipairs(rows) do if row.message_id == id then table.remove(rows, i); break end end
    events.ok(true, 0, '')
end
local gateway, saved = Gateway.New(cloud), {}
local function instance()
    local repo = {Keys = Repo.Keys}
    function repo:Commit(userId, _, state, _, cb)
        saved[userId] = Copy(state); commits = commits + 1; cb({ok = true, data = {}})
    end
    local profile = Profile.New{repository = repo, clock = function() return now end}
    local service = Admin.New{gateway = gateway, repository = repo, profileService = profile,
        operationQueue = Queue.New(), adminPolicy = Policy.New{adminUserIds = {actor}}, clock = function() return now end,
        decodeJson = function(token) return Copy(assert(encoded[token])) end}
    function service:_appendAudit(_, cb) cb({ok = true, data = {}}) end
    return service, profile
end
local function attach(profile)
    local state = Copy(saved[uid] or Factory.Create(now))
    profile.sessions[uid] = {state = state, persistedState = Copy(state), generation = 1,
        ready = true, connection = {}}
end
local function inbox(service)
    local response
    service:ProcessInbox(uid, function(r) response = r end)
    return assert(response)
end
local sender, senderProfile = instance()
local payload = {targetUid = tostring(uid), mailType = 'reward', title = '离线补偿', body = '跨实例投递',
    attachments = {{kind = 'currency', currency = 'gold', count = 50}}}
local accepted
sender:Execute(actor, 'send_mail', payload, function(r) accepted = r end)
assert(accepted and accepted.ok and not senderProfile:GetSession(uid))
assert(rows[1].key ~= Repo.Keys.GM_COMMAND,
    'personal mail must not be visible to old generic GM inbox consumers')
local newCommand = Copy(rows[1].value)
-- The legacy server can only query its original GM key.
cloud.message:Get(uid, Repo.Keys.GM_COMMAND, false, {ok = function(found) assert(#found == 0) end})
local receiver, profile = instance(); attach(profile)
assert(inbox(receiver).ok and #profile:GetState(uid).mails == 1)

-- An earlier release queued this command to GM_COMMAND. Its old receiver
-- rejected it before the fix and the administrator already read the receipt.
local rejected = Copy(newCommand); rejected.commandId = 'gm-legacy-rejected'
cloud.message:Send(actor, Repo.Keys.GM_COMMAND, uid, rejected, {ok = function() end})
local legacyId = serial
cloud.message:Send(uid, Repo.Keys.GM_RESULT, actor, {commandId = rejected.commandId,
    targetUid = uid, action = 'send_mail', ok = false, status = 'rejected',
    code = 'UNKNOWN_ADMIN_ACTION', appliedAt = now}, {ok = function() end})
cloud.message:MarkRead(legacyId, {ok = function() end})
cloud.message:MarkRead(serial, {ok = function() end})
receiver, profile = instance(); attach(profile)
failDelete = true
assert(inbox(receiver).ok and #profile:GetState(uid).mails == 2,
    'a proven old-instance rejection must be recovered, including read receipts')
local before = commits
receiver, profile = instance(); attach(profile)
assert(inbox(receiver).ok and #profile:GetState(uid).mails == 2 and commits == before,
    'cleanup retry after restart must not issue a second reward')
for _, row in ipairs(rows) do assert(row.message_id ~= legacyId, 'recovered legacy task must be removed') end

-- An acknowledged historical task with no rejection proof must not be
-- replayed: its mail may already have been claimed and deleted.
local unknown = Copy(newCommand); unknown.commandId = 'gm-history-no-proof'
cloud.message:Send(actor, Repo.Keys.GM_COMMAND, uid, unknown, {ok = function() end})
local unknownId = serial
cloud.message:MarkRead(unknownId, {ok = function() end})
receiver, profile = instance(); attach(profile)
assert(inbox(receiver).ok and #profile:GetState(uid).mails == 2 and commits == before)
local queryCount = #queries
assert(inbox(receiver).ok)
for i = queryCount + 1, #queries do
    assert(not (queries[i].key == Repo.Keys.GM_COMMAND and queries[i].read),
        'historical receipt recovery must not run every five-second poll')
end
-- A success receipt outweighs an earlier rejection even when the mail and
-- bounded idempotency entry no longer exist. Recovering it must only clean up.
cloud.message:Send(uid, Repo.Keys.GM_RESULT, actor, {commandId = unknown.commandId,
    targetUid = uid, action = 'send_mail', ok = true, status = 'applied'}, {ok = function() end})
cloud.message:MarkRead(serial, {ok = function() end})
cloud.message:Send(uid, Repo.Keys.GM_RESULT, actor, {commandId = unknown.commandId,
    targetUid = uid, action = 'send_mail', ok = false, status = 'rejected',
    code = 'UNKNOWN_ADMIN_ACTION'}, {ok = function() end})
receiver, profile = instance(); attach(profile)
failReceiptRead = true
assert(inbox(receiver).ok and commits == before and #profile:GetState(uid).mails == 2,
    'partial receipt reads cannot prove failure; success may be in the unavailable half')
assert(inbox(receiver).ok and commits == before and #profile:GetState(uid).mails == 2)
for _, row in ipairs(rows) do assert(row.message_id ~= unknownId) end
-- Unread legacy tasks remain compatible, and normal online delivery survives
-- a transient Get failure because accepted mail stays in the dedicated key.
sender:Execute(actor, 'send_mail', payload, function(r) assert(r.ok) end)
failGet = true
inbox(receiver)
assert(inbox(receiver).ok and #profile:GetState(uid).mails == 3)
local legacyUnread = Copy(newCommand); legacyUnread.commandId = 'gm-legacy-unread'
cloud.message:Send(actor, Repo.Keys.GM_COMMAND, uid, legacyUnread, {ok = function() end})
assert(inbox(receiver).ok and #profile:GetState(uid).mails == 4)
assert(Mail.Summary(profile:GetState(uid)).unread == 4)
-- Ordinary cross-instance GM actions still use their existing queue and must
-- not be dropped or migrated by the personal-mail compatibility reader.
local gold = Copy(profile:GetState(uid).gold)
sender:Execute(actor, 'grant_currency', {targetUid = tostring(uid), reason = 'GM回归', currency = 'gold', amount = 10},
    function(r) assert(r.ok) end)
assert(rows[#rows].key == Repo.Keys.GM_COMMAND)
assert(inbox(receiver).ok and Large.Compare(profile:GetState(uid).gold, Large.Add(gold, 10)) == 0)
-- Storage boundary may return a JSON value and string IDs; exercise the whole
-- delivery path with an injected codec, not a direct call to the parser.
stringValues = true
sender:Execute(actor, 'send_mail', payload, function(r) assert(r.ok) end)
assert(inbox(receiver).ok and #profile:GetState(uid).mails == 5)
assert(inbox(receiver).data.pending == 0, 'string message IDs must acknowledge successfully')
stringValues = false
local malformed = Copy(newCommand); malformed.commandId = 'gm-invalid-envelope'; malformed.targetUid = actor
cloud.message:Send(actor, Repo.Keys.PERSONAL_MAIL, uid, malformed, {ok = function() end})
assert(inbox(receiver).data.pending == 1)
assert(rows[#rows].read == false, 'invalid reward envelopes must stay available for diagnosis')
profile:DropSession(uid, 1)
receiver:Update(5)
assert(receiver.legacyMailSessions[uid] == nil, 'detached sessions must not be retained by migration cache')
print('personal_mail_mixed_versions: PASS')
