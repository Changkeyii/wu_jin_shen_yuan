local Copy = require('server.domain.TableUtils').DeepCopy
local Factory = require('server.domain.StateFactory')
local Normalizer = require('server.domain.StateNormalizer')
local Schema = require('shared.GameStateSchema')
local Profile = require('server.services.PlayerProfileService')
local MailService = require('server.services.MailService')
local Mail = require('server.domain.MailEngine')
local Queue = require('server.core.OperationQueue')
local now, rows, stored, writes = 1791600000, {}, {}, 0
local failRead, failWrite, failSave, paused, fetched = false, false, false, false, 0
local readCallback
local gateway = {}
function gateway:ListAdd(owner, key, value, cb)
    if failWrite then failWrite = false; cb({ok=false,code='CLOUD_WRITE_FAILED'}); return end
    rows[#rows+1] = {owner=owner,key=key,value=Copy(value),list_id=#rows+1}
    cb({ok=true,data={listId=#rows}})
end
function gateway:ListDelete(id,cb)
    for i,row in ipairs(rows) do if row.list_id==id then table.remove(rows,i); break end end
    cb({ok=true,data={}})
end
function gateway:ListGet(owner, key, cb)
    fetched = fetched + 1
    local function finish()
        if failRead then failRead = false; cb({ok=false,data={},code='CLOUD_READ_FAILED'}); return end
        local result = {}
        for _, row in ipairs(rows) do if row.owner==owner and row.key==key then result[#result+1]=Copy(row) end end
        cb({ok=true,data={items=result}})
    end
    if paused then readCallback=finish else finish() end
end
local function instance(nonce)
    local repository = {}
    function repository:Commit(uid, _, after, _, cb)
        if failSave then failSave=false; cb({ok=false,code='SAVE_FAILED'}); return end
        stored[uid] = Normalizer.ToPersisted(after); writes = writes + 1
        assert(Schema.ValidateState(stored[uid]))
        cb({ok=true,data={}})
    end
    local profile = Profile.New{repository=repository,clock=function() return now end}
    local notices = 0
    local service = MailService.New{profileService=profile,gateway=gateway,operationQueue=Queue.New(),
        instanceNonce=nonce,clock=function() return now end,onDelta=function() notices=notices+1 end}
    return service, profile, function() return notices end
end
local function attach(profile, uid)
    local state = Normalizer.Normalize(Copy(stored[uid] or Factory.Create(now)), now)
    profile.sessions[uid]={state=state,persistedState=Copy(state),generation=1,ready=true,connection={}}
end
local function deliver(service, uid)
    local result; service:DeliverBroadcasts(uid,function(r) result=r end); return assert(result)
end
local spec={type='reward',title='全服补偿',body='离线与新玩家领取',expireAt=now+86400,
    attachments={{kind='currency',currency='gold',count=50}}}
local sender, senderProfile = instance('sender')
local response
sender:SendBroadcast(spec,function(r) response=r end)
assert(response.ok and #rows==1 and #senderProfile:OnlineUserIds()==0)
assert(rows[1].value.spec.expireAt==now+86400)
local firstBatch=rows[1].value.batchId
-- A new instance with no sender memory serves an offline player and a brand-new player.
local receiver, profile, notices = instance('receiver')
attach(profile,2002); attach(profile,3003)
assert(deliver(receiver,2002).data.delivered==1 and #profile:GetState(2002).mails==1)
assert(deliver(receiver,3003).data.delivered==1 and #profile:GetState(3003).mails==1 and notices()==2)
assert(profile:GetState(2002).receivedBroadcasts[firstBatch])
local before=writes
assert(deliver(receiver,2002).data.delivered==0 and writes==before)
receiver:DeliverBroadcasts(2002,function() error('injected UI/snapshot callback failure') end)
assert(not receiver.operationQueue:IsBusy(2002) and not receiver.broadcastPolling[2002],
    'a notification callback failure cannot strand the player operation queue')
-- Even after claiming/deleting mail and restarting, the persisted receipt must prevent reissuing.
local state=profile:GetState(2002)
local proposal=Mail.Claim(state,state.mails[1].id,now); assert(proposal.ok)
assert(Mail.Delete(proposal.state,proposal.state.mails[1].id,now))
stored[2002]=Normalizer.ToPersisted(proposal.state)
receiver,profile=instance('restarted'); attach(profile,2002)
assert(deliver(receiver,2002).data.delivered==0 and #profile:GetState(2002).mails==0 and writes==before)
-- Same-second sends from separate/restarted instances cannot share a batch id.
local other=instance('other')
other:SendBroadcast(spec,function(r) assert(r.ok) end)
assert(rows[2].value.batchId~=firstBatch)
now=now+5; failSave=true
assert(deliver(receiver,2002).data.pending==1 and #profile:GetState(2002).mails==0)
assert(deliver(receiver,2002).data.delivered==1 and #profile:GetState(2002).mails==1)
now=now+5; failRead=true
assert(not deliver(receiver,2002).ok)
assert(deliver(receiver,2002).ok)
failWrite=true
other:SendBroadcast(spec,function(r) assert(not r.ok) end); assert(#rows==2,'no success without durable storage')
-- Concurrent joins share a single in-flight cloud read, then commit independently.
now=now+5; receiver,profile=instance('parallel'); attach(profile,4004); attach(profile,5005)
paused=true; local completions=0; local beforeFetch=fetched
for _,uid in ipairs({4004,5005}) do receiver:DeliverBroadcasts(uid,function(r) assert(r.ok); completions=completions+1 end) end
assert(fetched==beforeFetch+1 and completions==0)
paused=false; readCallback(); assert(completions==2)
-- Opening the actual player mailbox synchronizes broadcasts before listing.
receiver,profile=instance('mail-list'); attach(profile,6006)
local defs={}
require('server.commands.MailCommands').Register({Register=function(_,d) defs[d.name]=d end},
    {mailService=receiver,profileService=profile,adminService={ProcessInbox=function(_,_,cb) cb({ok=true,data={pending=1}}) end}})
defs['Mail.List'].handler({uid=6006},{scope='all'},function(ok,r)
    assert(ok and #r.data.items==2 and r.data.deliveryPending); response=r
end)
assert(response.data.total==2)
-- Expired cloud batches never reward a new account that joins after expiry.
now=1791600000+86401; receiver,profile=instance('expired'); attach(profile,7007)
assert(deliver(receiver,7007).data.delivered==0 and #profile:GetState(7007).mails==0)
assert(#rows==0,'expired cloud batches must not accumulate forever')
print('offline_broadcast_mail: PASS')
