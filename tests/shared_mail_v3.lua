local Fixture = dofile("tests/helpers/mail_cloud_fixture.lua")
local Copy = require("server.domain.TableUtils").DeepCopy
local Gateway = require("server.dao.ServerCloudGateway")
local Repo = require("server.repositories.PlayerProfileRepository")
local Profile = require("server.services.PlayerProfileService")
local Store = require("server.services.CloudMailStore")
local MailService = require("server.services.MailService")
local Mail = require("server.domain.MailEngine")
local Transition = require("server.domain.PlayerTransition")
local Queue = require("server.core.OperationQueue")
local Schema = require("shared.GameStateSchema")
local env = Fixture.New()
local function instance()
    local gateway=Gateway.New(env.cloud)
    local repo=Repo.New{gateway=gateway,clock=function() return env.now end}
    local profile=Profile.New{repository=repo,clock=function() return env.now end}
    local store=Store.New{gateway=gateway,encodeJson=Fixture.Json,clock=function() return env.now end,log=function() end}
    local service=MailService.New{profileService=profile,sharedStore=store,gateway=gateway,
        clock=function() return env.now end,operationQueue=Queue.New(),log=function() end}
    return { profile=profile,store=store,repo=repo,service=service }
end
local function attach(i,uid,generation)
    local result; i.profile:Load(uid,function(r) result=r end)
    assert(result and result.ok,result and result.reason)
    i.profile:Attach(uid,{},generation or 1,result.data); i.profile:MarkReady(uid,generation or 1)
end
local function sync(i,uid)
    local result; i.service:DeliverBroadcasts(uid,function(r) result=r end); return assert(result)
end
local function send(i,uid,id)
    local result; i.store:QueuePersonal(uid,id,{type="reward",title="离线补偿",body="跨实例",
        expireAt=env.now+86400*365,attachments={{kind="currency",currency="gold",count=10}}},function(r) result=r end)
    return assert(result)
end
local function retry(i,uid) env:advance(61); i.store:Update(); i.profile:Update(); return sync(i,uid) end
local function stored(uid) return env.score(uid,"abyss_profile") end
local gm=instance()
assert(send(gm,2002,"personal-A").ok)
local first,second=instance(),instance()
attach(first,2002); attach(second,2002)
assert(sync(first,2002).ok and #first.profile:GetState(2002).mails==1)
assert(#env.rows(2002,Store.Keys.PENDING)==0 and #env.rows(2002,Store.Keys.AUDIT)==1)
assert(stored(2002).storageVersion==2 and Schema.ValidateState(first.profile:GetState(2002)))
-- The old instance's disconnect cannot overwrite mail or receipts.
env:advance(10)
local stale; second.profile:TouchAndDetach(2002,1,function(r) stale=r end)
assert(not stale.ok and stale.code=="PROFILE_CONFLICT")
assert(#stored(2002).mails==1)
local public
gm.service:SendBroadcast({type="reward",title="全服",body="新玩家也收到",expireAt=env.now+86400*365,
    attachments={{kind="currency",currency="gold",count=5}}},function(r) public=r end)
assert(public.ok and public.data.mailId:match("broadcast%-v3%-"))
assert(retry(first,2002).data.delivered==1)
local new=instance(); attach(new,3003); assert(sync(new,3003).data.delivered==1)
assert(env.score(3003,Store.Keys.LEDGER).received~="")
local mailId=new.profile:GetState(3003).mails[1].id
local claimed; new.service:Claim(3003,mailId,function(r) claimed=r end); assert(claimed.ok)
new.service:Delete(3003,mailId,function(r) assert(r.ok) end)
local restarted=instance(); attach(restarted,3003)
assert(sync(restarted,3003).data.delivered==0 and #restarted.profile:GetState(3003).mails==0)
-- Atomic rollback even when source deletion fails AFTER profile staging.
for _,failure in ipairs({"failProfile","failDelete"}) do
    env:advance(61); assert(send(gm,4004,"rollback-"..failure).ok)
    local receiver=instance(); attach(receiver,4004); local before=Copy(stored(4004))
    env[failure]=true
    assert(not sync(receiver,4004).ok)
    assert(require("server.domain.TableUtils").DeepEqual(before,stored(4004)))
    assert(#env.rows(4004,Store.Keys.PENDING)>0)
    assert(retry(receiver,4004).ok)
end
-- Concurrent deliveries share neither process state nor fake repository checks.
env:advance(61); assert(send(gm,5005,"race").ok)
local a,b=instance(),instance(); attach(a,5005); attach(b,5005)
-- Warm the public cache BEFORE pausing writes.
a.store:ReadPublic(function(r) assert(r.ok) end,true)
b.store:ReadPublic(function(r) assert(r.ok) end,true)
env.pause=true; local ra,rb
a.service:DeliverBroadcasts(5005,function(r) ra=r end)
b.service:DeliverBroadcasts(5005,function(r) rb=r end)
assert(#env.pending==2); env:flush()
assert(ra.ok and not rb.ok and #stored(5005).mails==2)
assert(#env.rows(5005,Store.Keys.PENDING)==0 and #env.rows(5005,Store.Keys.AUDIT)==1)
-- Success with missing callback freezes all player writes until readback proves it.
env:advance(61); assert(send(gm,6006,"lost").ok)
local lost=instance(); attach(lost,6006)
lost.store:ReadPublic(function(r) assert(r.ok) end,true)
env.dropCommit=true; local lostResult, calls= nil,0
lost.service:DeliverBroadcasts(6006,function(r) lostResult=r; calls=calls+1 end)
assert(lostResult==nil)
env:advance(10); lost.profile:Update()
assert(lostResult.code=="WRITE_UNCONFIRMED" and lost.profile:GetSession(6006).writeBlocked)
local blocked; lost.profile:Apply(6006,"blocked",function(state,now) return Transition.Finalize(state,Transition.Copy(state,now),now,"blocked",{},false,false) end,function(r) blocked=r end)
assert(not blocked.ok and blocked.code=="WRITE_UNCONFIRMED")
env:advance(5); lost.profile:Update()
assert(not lost.profile:GetSession(6006).writeBlocked and #lost.profile:GetState(6006).mails==2)
for _,callback in ipairs(env.lost) do callback() end; env.lost={}
assert(calls==1 and retry(lost,6006).data.delivered==0)
-- A truly delayed write cannot be classified as failed just by reading old data.
env:advance(61); assert(send(gm,7007,"delayed").ok)
local delayed=instance(); attach(delayed,7007)
delayed.store:ReadPublic(function(r) assert(r.ok) end,true)
env.pause=true; local delayedResult
delayed.service:DeliverBroadcasts(7007,function(r) delayedResult=r end)
env:advance(15); delayed.profile:Update(); assert(delayedResult.code=="WRITE_UNCONFIRMED")
delayed.profile:Update(); assert(delayed.profile:GetSession(7007).writeBlocked)
env:flush(); env:advance(5); delayed.profile:Update()
assert(not delayed.profile:GetSession(7007).writeBlocked and #stored(7007).mails==2)
-- Fast reconnect during a disconnect checkpoint: late old callback cannot detach it.
env:advance(61); local reconnect=instance(); attach(reconnect,8008)
env:advance(10)
env.pause=true; local checkpoint
reconnect.profile:MarkDisconnected(8008,1)
reconnect.profile:TouchAndDetach(8008,1,function(r) checkpoint=r end)
local session=reconnect.profile:GetSession(8008); session.generation=2; session.connection={}; session.ready=true
env:flush()
assert(checkpoint.code=="STALE_SESSION" and reconnect.profile:GetSession(8008)==session and session.generation==2)
-- Lost public and personal queue callback: stable ID is queryable, no blind replay.
env:advance(61); local uncertain=instance(); env.dropCommit=true
local queued
uncertain.store:QueuePersonal(9009,"accepted-unknown",{type="notice",title="notice",body="body",expireAt=env.now+86400,attachments={}},function(r) queued=r end)
env:advance(10); uncertain.store:Update()
assert(queued.code=="WRITE_UNCONFIRMED" and queued.data.mailId=="accepted-unknown")
env:advance(5); uncertain.store:Update(); assert(not uncertain.store.unknown["player-9009"])
local status; uncertain.service.sharedDelivery:Inspect(9009,"accepted-unknown",function(r) status=r end)
assert(status.ok and status.data.delivery.stage=="pending" and status.data.delivery.version==Store.VERSION)
-- Read timeout releases public coalescing and per-player syncing flags.
env:advance(61); local timeout=instance(); attach(timeout,10010)
env.dropRead="Get:"..Store.Keys.MANIFEST; local timed
timeout.service:DeliverBroadcasts(10010,function(r) timed=r end)
env:advance(10); timeout.store:Update()
assert(timed.code=="CLOUD_READ_TIMEOUT" and not timeout.service.sharedDelivery.syncing[10010] and #timeout.store.publicWaiters==0)
assert(retry(timeout,10010).ok)
for _,callback in ipairs(env.lost) do callback() end; env.lost={}
-- Bad personal source retained while the valid source is delivered.
env:advance(61); assert(send(gm,11011,"valid-next-to-bad").ok)
env:addRow(11011,Store.Keys.PENDING,{id="broken"})
local bad=instance(); attach(bad,11011)
local badResult=sync(bad,11011)
assert(badResult.ok and badResult.data.invalid==1 and #stored(11011).mails==2 and #env.rows(11011,Store.Keys.PENDING)==1)
-- An absent/trimmed audit never implies undelivered.
bad.service.sharedDelivery:Inspect(11011,"nonexistent-history",function(r) assert(r.data.delivery.stage=="unknown") end)
-- Full mailbox: sources and receipts stay untouched, then resume after space is available.
env:advance(61); assert(send(gm,12012,"mailbox-full").ok)
local full=instance(); attach(full,12012)
local state=full.profile:GetState(12012)
for n=1,300 do assert(Mail.Create(state,{type="notice",title="filler",body="filler",bizOrderId="filler-"..n},env.now)) end
local saved; full.profile:Apply(12012,"save full mailbox",function(before,now)
    return Transition.Finalize(before,Transition.Copy(before,now),now,"full",{},false,false)
end,function(r) saved=r end); assert(saved.ok)
local pending=sync(full,12012)
assert(pending.ok and pending.data.pending>0 and #env.rows(12012,Store.Keys.PENDING)==1)
assert(not env.score(12012,Store.Keys.LEDGER).received:find("1"))
full.service:Delete(12012,state.mails[1].id,function(r) assert(r.ok) end)
assert(retry(full,12012).data.delivered==1 and #env.rows(12012,Store.Keys.PENDING)==0)
-- A public source expiring during the 60s directory cache is never newly delivered.
env:advance(61); local exp=instance(); attach(exp,13013)
local short
gm.service:SendBroadcast({type="notice",title="short",body="short",expireAt=env.now+2,attachments={}},function(r) short=r end)
assert(short.ok)
exp.store:ReadPublic(function(r) assert(r.ok) end,true)
env:advance(3); local expiredResult=sync(exp,13013)
assert(expiredResult.ok and expiredResult.data.delivered==1,"only the still-active old broadcast is delivered")
assert(#exp.profile:GetState(13013).mails==1)
-- Per-instance total request accounting includes non-mail profile operations.
local totals=exp.store.gateway:RequestTotals()
assert(totals.read>0 and totals.write>0 and totals.platformScopeVerified==false)
print("shared_mail_v3: PASS (real cloud gateway/repository, cross-instance guards, rollback, reconnect, callback loss, bad records)")
