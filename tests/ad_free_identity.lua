local Copy = require('server.domain.TableUtils').DeepCopy
local Factory = require('server.domain.StateFactory')
local Normalizer = require('server.domain.StateNormalizer')
local Schema = require('shared.GameStateSchema')
local Protocol = require('shared.NetworkProtocol')
local Repo = require('server.repositories.PlayerProfileRepository')
local Gateway = require('server.dao.ServerCloudGateway')
local Profile = require('server.services.PlayerProfileService')
local Admin = require('server.services.AdminService')
local Queue = require('server.core.OperationQueue')
local Policy = require('server.core.AdminPolicy')
local Adapter = require('client.GameStateAdapter')
local now, actor, uid = os.time(), 1001, 2002
local rows, nextId, stored, deltas, commits = {}, 0, {}, {}, 0
local failSave, reverse = false, false
local cloud = {message = {}}
function cloud.message:Send(sender, key, recipient, value, events)
    nextId = nextId + 1
    rows[#rows + 1] = {sender = sender, key = key, recipient = recipient, value = Copy(value), message_id = nextId, read = false}
    events.ok(0, '')
end
function cloud.message:Get(userId, key, read, events)
    local found = {}
    for _, row in ipairs(rows) do
        if row.recipient == userId and row.key == key and row.read == read then found[#found + 1] = Copy(row) end
    end
    if reverse then table.sort(found, function(a,b) return a.message_id > b.message_id end) end
    events.ok(found)
end
function cloud.message:MarkRead(id, events)
    for _, row in ipairs(rows) do if row.message_id == id then row.read = true end end
    events.ok(0, '')
end
function cloud.message:Delete(id, events) events.ok(true, 0, '') end
local gateway = Gateway.New(cloud)
local function instance()
    local repo = {Keys = Repo.Keys}
    function repo:Commit(userId, _, state, _, cb)
        if failSave then failSave = false; cb({ok = false, code = 'SAVE_FAILED', reason = 'save failed'}); return end
        stored[userId], commits = Copy(state), commits + 1
        cb({ok = true, data = {}})
    end
    local profile = Profile.New{repository = repo, clock = function() return now end}
    local admin = Admin.New{gateway = gateway, repository = repo, profileService = profile,
        operationQueue = Queue.New(), adminPolicy = Policy.New{adminUserIds = {actor}}, clock = function() return now end,
        onDelta = function(_, delta) deltas[#deltas + 1] = delta end}
    function admin:_appendAudit(_, cb) cb({ok = true, data = {}}) end
    return admin, profile
end
local function attach(profile)
    local state = Normalizer.Normalize(Copy(stored[uid] or Factory.Create(now)), now)
    state.tutorial.completed = true
    profile.sessions[uid] = {state = state, persistedState = Copy(state), generation = 1, ready = true, connection = {}}
end
local function inbox(admin)
    local response; admin:ProcessInbox(uid, function(r) response = r end); return assert(response)
end
local function set(admin, enabled, sender)
    local response
    admin:Execute(sender or actor, 'set_ad_free', {targetUid = tostring(uid), reason = '身份回归', enabled = enabled},
        function(r) response = r end)
    return assert(response)
end
local sender, senderProfile = instance()
local defs = {}
require('server.commands.AdminCommands').Register({Register = function(_, d) defs[d.name] = d end}, sender, {})
assert(defs['Admin.SetAdFree'].auth == 'admin')
assert(not Protocol.ValidatePayload({targetUid = tostring(uid), enabled = 'true', reason = 'x'}, defs['Admin.SetAdFree'].schema))
assert(Factory.Create(now).adFree == false and Normalizer.Normalize({adFree = 'true'}, now).adFree == false)
assert(not set(sender, true, 999).ok and #rows == 0)
assert(not set(sender, 1).ok and #rows == 0)
assert(set(sender, true).ok and not senderProfile:GetSession(uid) and commits == 0)
assert(rows[1].key == Repo.Keys.PLAYER_ENTITLEMENT and rows[1].key ~= Repo.Keys.GM_COMMAND,
    'old GM consumers must not acknowledge new identity actions')
local receiver, profile = instance(); attach(profile)
assert(inbox(receiver).ok and profile:GetState(uid).adFree == true)
local grantDelta = deltas[#deltas]
assert(grantDelta.changes.adFree == true and Schema.ValidateState(Schema.ToPersistedState(profile:GetState(uid))))
local snapshot = Schema.BuildSnapshot(profile:GetState(uid), {serverTime = now, playerNickname = 'Identity test'})
snapshot.logs, snapshot.recentDamage = {}, 'ready'
assert(snapshot.adFree == true and Schema.ValidateSnapshot(snapshot))
Adapter.ApplySnapshot(snapshot); Adapter.SetConnectionState('ready')
assert(Adapter.GetViewState().adFree == true)
receiver, profile = instance(); attach(profile)
assert(profile:GetState(uid).adFree == true, 'identity survives restart/storage normalization')
local before = commits
rows[1].read = false
assert(inbox(receiver).ok and commits == before, 'replayed grant must not write/grant again')
-- Current authoritative holder can revoke immediately and pushes an explicit false.
assert(set(receiver, false).ok and profile:GetState(uid).adFree == false)
assert(deltas[#deltas].changes.adFree == false)
Adapter.ApplyDelta(deltas[#deltas]); assert(Adapter.GetViewState().adFree == false)
local verifyDefs = {}
require('server.commands.RewardClaimCommands').Register({Register = function(_, d) verifyDefs[d.name] = d end},
    {profileService = profile, sendDelta = function() end})
local ok = verifyDefs['Reward.VerifyAdFree'].handler({uid = uid})
assert(not ok, 'ordinary/revoked players cannot verify ad-free access')
assert(not Protocol.ValidatePayload({targetUid = tostring(actor)}, verifyDefs['Reward.VerifyAdFree'].schema),
    'player cannot ask to verify another identity')
-- Grant then revoke offline: newest setting wins even if storage returns newest first.
assert(set(sender, true).ok and set(sender, false).ok)
reverse, failSave = true, true
local failed = inbox(receiver)
assert(failed.ok and failed.data.pending == 2 and not profile:GetState(uid).adFree,
    'failed older setting must retain both tasks rather than apply newer then revert it later')
assert(inbox(receiver).ok and not profile:GetState(uid).adFree)
reverse = false
assert(set(receiver, true).ok)
ok = verifyDefs['Reward.VerifyAdFree'].handler({uid = uid}); assert(ok)

-- Real RewardVideo + real gift controller. Only cloud, UI and transport ports
-- are replaced; VerifyAdFree routes through the actual server command above.
local display, dialog, plays, verifies, claims = Copy(profile:GetState(uid)), nil, 0, 0, 0
display.readOnly = false
local verifyCallback
local transport = {}
function transport.VerifyAdFree(cb)
    verifies = verifies + 1
    verifyCallback = function()
        local _, response = verifyDefs['Reward.VerifyAdFree'].handler({uid = uid}); cb(response)
    end
    return 'verify'
end
local function invoke(name, payload, cb)
    verifyDefs[name].handler({uid = uid}, payload, function(_, response)
        display = Copy(profile:GetState(uid)); display.readOnly = false; cb(response)
    end)
end
function transport.PrepareAdGift(kind, cb) invoke('Reward.PrepareGift', {giftKind = kind}, cb) end
function transport.ClaimAdGift(token, cb) claims = claims + 1; invoke('Reward.ClaimGift', {token = token}, cb) end
package.loaded['client.GameStateAdapter'] = {GetViewState = function() return display end}
package.loaded['client.ServerClient'] = transport
package.loaded['urhox-libs/UI'] = {Toast = {Show = function() end}}
package.loaded['client.AdGiftView'] = {Reward = function(quote, options) dialog = {quote = quote, options = options}; return true end}
package.loaded['client.DialogCoordinator'] = {HasKey = function() return dialog ~= nil end}
local Video = require('client.RewardVideo')
local Controller = require('client.AdGiftController')
local baseTickets = profile:GetState(uid).wishPool.tickets
_G.sdk = nil
assert(Video.IsAvailable() and Video.ActionText('看广告', '免广告') == '免广告')
local verifyTransport = transport.VerifyAdFree
transport.VerifyAdFree = function() error('injected transport failure') end
local failure
assert(not Video.Play(function(r) failure=r end) and failure and not failure.success and not Video.IsBusy())
transport.VerifyAdFree = verifyTransport
assert(Controller.Show('wishSupply'))
local choice = dialog; dialog = nil; choice.options.onConfirm()
assert(Video.IsBusy() and verifies == 1 and claims == 0, 'wait for server verification before issuing any claim')
verifyCallback()
assert(not Video.IsBusy() and claims == 1 and profile:GetState(uid).wishPool.tickets == baseTickets + 1)
verifyCallback(); assert(claims == 1, 'duplicate verification cannot claim twice')
invoke('Reward.ClaimGift', {token = choice.quote.id}, function(r) assert(r.ok) end)
assert(profile:GetState(uid).wishPool.tickets == baseTickets + 1, 'same gift token remains idempotent')
for _ = 2, 4 do
    dialog = nil; assert(Controller.Show('wishSupply'))
    choice = dialog; dialog = nil; choice.options.onConfirm(); verifyCallback()
end
assert(profile:GetState(uid).wishPool.tickets == baseTickets + 10 and profile:GetState(uid).rewardClaims.gifts.wishUsed == 4)
dialog = nil; Controller.Show('wishSupply'); assert(dialog == nil, 'free identity must still enforce four daily supply claims')
-- A forged/stale local identity never authorizes the exemption.
assert(set(receiver, false).ok)
display.adFree = true
local result
assert(Video.Play(function(r) result = r end)); verifyCallback()
assert(result and not result.success and claims == 4)
display.adFree = false
local nativeCallback
_G.sdk = {ShowRewardVideoAd = function(_, cb) plays = plays + 1; nativeCallback = cb; return true end}
assert(Video.Play(function(r) result = r end) and plays == 1)
nativeCallback({success = true}); assert(result.success and not result.adFree)
-- Revocation also persists across restart.
receiver, profile = instance(); attach(profile); assert(not profile:GetState(uid).adFree)

-- Existing domain rules apply identically for exempt players across each reward category.
local s = Factory.Create(now); s.adFree = true; s.tutorial.completed = true
local Rewards = require('server.domain.RewardEngine')
local p = Rewards.ClaimDailyAdVip(s, now); assert(p.ok and p.state.vipLevel == 1)
assert(not Rewards.ClaimDailyAdVip(p.state, now).ok)
for _ = 1, 5 do p = Rewards.ExpandInventoryByAd(s, now); assert(p.ok); s = p.state end
assert(not Rewards.ExpandInventoryByAd(s, now).ok)
local Activity = require('server.domain.ActivityEngine')
local strikeId
for _, def in pairs(require('shared.ActivityDefinitions').ALL) do if def.type == 'strike' then strikeId = def.id; break end end
p = Activity.UnlockExtraStrike(s, assert(strikeId), now); assert(p.ok)
assert(not Activity.UnlockExtraStrike(p.state, strikeId, now).ok)
local Extras = require('server.domain.RewardClaimEngine')
for _ = 1, 3 do p = Extras.ClaimExclusiveAdGift(s, 'daily', now); assert(p.ok); s = p.state end
assert(not Extras.ClaimExclusiveAdGift(s, 'daily', now).ok)
print('ad_free_identity: PASS')
