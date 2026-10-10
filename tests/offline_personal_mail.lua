local Copy = require('server.domain.TableUtils').DeepCopy
local Factory = require('server.domain.StateFactory')
local Profile = require('server.services.PlayerProfileService')
local Admin = require('server.services.AdminService')
local Policy = require('server.core.AdminPolicy')
local Queue = require('server.core.OperationQueue')
local Gateway = require('server.dao.ServerCloudGateway')
local Mail = require('server.domain.MailEngine')
local Rules = require('shared.MailRules')
local Large = require('shared.LargeNumber')
local Protocol = require('shared.NetworkProtocol')
local now, actor, uid = 1791545000, 1001, 2002
local messages, nextId, stored, failSend, failMark, failCommit = {}, 0, {}, nil, false, false
local cloud = {message = {}}
function cloud.message:Send(sender, key, recipient, value, events)
    if failSend == key then failSend = nil; events.error(-503, 'injected message error'); return end
    nextId = nextId + 1
    messages[#messages + 1] = {message_id = nextId, sender = sender, key = key, recipient = recipient,
        value = Copy(value), read = false}
    events.ok(0, '')
end
function cloud.message:Get(userId, key, read, events)
    local result = {}
    for _, m in ipairs(messages) do
        if m.recipient == userId and m.key == key and m.read == read then result[#result + 1] = Copy(m) end
    end
    events.ok(result)
end
function cloud.message:MarkRead(id, events)
    if failMark then failMark = false; events.error(-503, 'injected mark error'); return end
    for _, m in ipairs(messages) do if m.message_id == id then m.read = true end end
    events.ok(0, '')
end
local keys = {GM_COMMAND = 'gm-command', PERSONAL_MAIL = 'personal-mail', PLAYER_ENTITLEMENT = 'player-entitlement', GM_RESULT = 'gm-result', ADMIN_AUDIT = 'gm-audit'}
local gateway = Gateway.New(cloud)
local audit, deltas, receipts = {}, 0, {}
local function NewInstance(nonce)
    local repository = {Keys = keys}
    function repository:Commit(userId, before, after, _, cb)
        if failCommit then failCommit = false; cb({ok = false, code = -503, reason = 'injected save error'}); return end
        if stored[userId] then assert(before.revision == stored[userId].revision, 'stale write') end
        stored[userId] = Copy(after); cb({ok = true, data = {}})
    end
    local profile = Profile.New{repository = repository, clock = function() return now end}
    local service = Admin.New{
        gateway = gateway, repository = repository, profileService = profile, operationQueue = Queue.New(),
        adminPolicy = Policy.New{adminUserIds = {actor}}, clock = function() return now end,
        instanceNonce = nonce, onDelta = function() deltas = deltas + 1 end,
        onAdminResult = function(_, result) receipts[#receipts + 1] = result end,
    }
    function service:_appendAudit(record, cb)
        audit[#audit + 1] = Copy(record); cb({ok = true, data = {}})
    end
    return service, profile
end
local function Attach(profile, ready)
    local state = Copy(stored[uid] or Factory.Create(now))
    profile.sessions[uid] = {state = state, persistedState = Copy(state), generation = 1,
        ready = ready == true, connection = {}}
end
local function Inbox(service)
    local response
    service:ProcessInbox(uid, function(r) response = r end)
    return assert(response)
end
local function Send(service, payload, sender)
    local response
    service:Execute(sender or actor, 'send_mail', payload, function(r) response = r end)
    return assert(response)
end
local function UnreadCommands()
    local count = 0
    for _, m in ipairs(messages) do if m.recipient == uid and m.key == keys.PERSONAL_MAIL and not m.read then count = count + 1 end end
    return count
end
local payload = {targetUid = tostring(uid), mailType = 'reward', title = '奖励补发', body = '离线也能收到',
    expireDays = 30, batchId = 'gm_mail', attachments = {
        {kind = 'currency', currency = 'gold', count = 321},
        {kind = 'currency', currency = 'fragments', count = 12},
        {kind = 'item', itemId = 'wish_ticket', count = 2},
        {kind = 'equipment', slot = 'weapon', rarity = 'rare', level = 1, count = 1},
    }}
local sender, senderProfile = NewInstance('sender')
-- Actual registered personal-mail handler must no longer require a local target.
local defs = {}
require('server.commands.AdminCommands').Register({Register = function(_, d) defs[d.name] = d end}, sender, {})
assert(defs['Admin.SendMail'].auth == 'admin')
assert(Protocol.ValidatePayload(payload, defs['Admin.SendMail'].schema))
local accepted
defs['Admin.SendMail'].handler({uid = actor}, payload, function(ok, r) assert(ok); accepted = r end)
assert(accepted.ok and accepted.data.status == 'queued' and accepted.data.action == 'send_mail')
assert(UnreadCommands() == 1 and not senderProfile:GetSession(uid), 'offline send must persist without loading/writing target profile')
local originalCommand = Copy(messages[1].value)
payload.title = 'mutated draft'; payload.attachments[1].count = 999
assert(originalCommand.payload.spec.title == '奖励补发' and originalCommand.payload.spec.attachments[1].count == 321)

-- A separate instance, after a restart, performs delivery before the login snapshot.
now = now + 3600
local receiver, profile = NewInstance('receiver')
Attach(profile, false)
local delivered = Inbox(receiver)
assert(delivered.ok and delivered.data.applied == 1 and UnreadCommands() == 0)
local state = profile:GetState(uid)
local snapshot = profile:Snapshot(uid, false)
assert(#snapshot.mails == 1 and Mail.Summary(state).unread == 1 and deltas == 1)
local mail = state.mails[1]
assert(mail.title == '奖励补发' and #mail.attachments == 4 and mail.attachments[1].count == 321)
assert(mail.expireAt == originalCommand.createdAt + 30 * 86400)
assert(mail.bizOrderId == 'gm-mail:' .. accepted.data.commandId)
local diagnostic
receiver:InspectMailDelivery(actor, uid, {_loadBroadcasts=function(_,cb)
    cb({ok=true,data={entries={{batchId='pending-broadcast'}}}})
end}, function(r) diagnostic=r end)
assert(diagnostic.ok and diagnostic.data.delivery.mailboxCount==1
    and diagnostic.data.delivery.personalPending==0 and diagnostic.data.delivery.broadcastPending==1)
receiver:InspectMailDelivery(9999, uid, {}, function(r) assert(not r.ok and r.code=='FORBIDDEN') end)
local beforeGold = Copy(state.gold)
local claimed = Mail.Claim(state, mail.id, now)
assert(claimed.ok and Large.Compare(claimed.state.gold, Large.Add(beforeGold, 321)) == 0)
local duplicateClaim = Mail.Claim(claimed.state, mail.id, now)
assert(Large.Compare(duplicateClaim.state.gold, claimed.state.gold) == 0)

-- Replayed cloud messages, including after a receipt/ack failure, never create two mails.
messages[1].read = false; failSend = keys.GM_RESULT
assert(Inbox(receiver).data.pending == 1 and UnreadCommands() == 1)
assert(#profile:GetState(uid).mails == 1)
failMark = true
assert(Inbox(receiver).data.pending == 1 and UnreadCommands() == 1)
assert(Inbox(receiver).ok and #profile:GetState(uid).mails == 1 and UnreadCommands() == 0)
assert(deltas == 1, 'idempotent replay must not create another revision/delta')
sender:ProcessResults(actor, function(r) assert(r.ok) end)
assert(#receipts >= 1 and receipts[#receipts].action == 'send_mail')

-- Local online target receives immediately, but persistence still happens first.
payload.title = 'online'; profile.sessions[uid].ready = true
local online = Send(receiver, payload)
assert(online.ok and online.data.status == 'queued' and UnreadCommands() == 0)
assert(#profile:GetState(uid).mails == 2)
local notify = receiver.onDelta
receiver.onDelta = function() error('injected notification failure') end
assert(Send(receiver, payload).ok and #profile:GetState(uid).mails == 3 and UnreadCommands() == 0)
receiver.onDelta = notify

-- Storage failure keeps the task unread and must not prevent entering the game.
profile.sessions[uid].ready = false
assert(Send(sender, payload).ok); failCommit = true
local saveRetry = Inbox(receiver)
assert(saveRetry.ok and saveRetry.data.pending == 1 and UnreadCommands() == 1)
assert(#profile:GetState(uid).mails == 3)
assert(Inbox(receiver).ok and #profile:GetState(uid).mails == 4)

-- Filled mailbox/cache: preserve rewards, continue login, retry after freeing space.
local full = profile:GetState(uid)
local seed = Copy(full.mails[1]); seed.favorite = true
while #full.mails < Rules.CAPACITY do local m = Copy(seed); m.id = 'full-' .. #full.mails; full.mails[#full.mails + 1] = m end
while #full.mailCache < Rules.CACHE_CAPACITY do local m = Copy(seed); m.id = 'cache-' .. #full.mailCache; full.mailCache[#full.mailCache + 1] = m end
profile.sessions[uid].persistedState = Copy(full); stored[uid] = Copy(full)
assert(Send(sender, payload).ok)
local capacity = Inbox(receiver)
assert(capacity.ok and capacity.data.pending == 1 and UnreadCommands() == 1)
table.remove(full.mailCache); stored[uid] = Copy(full); profile.sessions[uid].persistedState = Copy(full)
assert(Inbox(receiver).ok and UnreadCommands() == 0)
assert(#profile:GetState(uid).mailCache == Rules.CACHE_CAPACITY)

-- Unauthorized/malformed requests never write a durable reward command.
local count = #messages
assert(not Send(sender, payload, 9999).ok and #messages == count)
local invalid = Copy(payload); invalid.attachments[1].count = -1
assert(not Send(sender, invalid).ok and #messages == count)
failSend = keys.PERSONAL_MAIL
assert(not Send(sender, payload).ok and #messages == count)
local auditAppend = sender._appendAudit
sender._appendAudit = function(_, _, cb) cb({ok = false, code = -503, reason = 'audit unavailable'}) end
local auditFailed = Send(sender, payload)
assert(auditFailed.ok and auditFailed.data.auditWarning and UnreadCommands() == 1,
    'a saved mail must remain accepted when optional audit storage fails')
sender._appendAudit = auditAppend
print('offline_personal_mail: PASS')
