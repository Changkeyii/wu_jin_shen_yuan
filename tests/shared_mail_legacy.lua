local Fixture=dofile("tests/helpers/mail_cloud_fixture.lua")
local Gateway=require("server.dao.ServerCloudGateway")
local Repo=require("server.repositories.PlayerProfileRepository")
local Profile=require("server.services.PlayerProfileService")
local Store=require("server.services.CloudMailStore")
local MailService=require("server.services.MailService")
local Admin=require("server.services.AdminService")
local Queue=require("server.core.OperationQueue")
local Transition=require("server.domain.PlayerTransition")
local env=Fixture.New()
local function instance()
    local gateway=Gateway.New(env.cloud)
    local repo=Repo.New{gateway=gateway,clock=function() return env.now end}
    local profile=Profile.New{repository=repo,clock=function() return env.now end}
    local store=Store.New{gateway=gateway,encodeJson=Fixture.Json,clock=function() return env.now end,log=function() end}
    local queue=Queue.New()
    local mail=MailService.New{profileService=profile,sharedStore=store,gateway=gateway,
        operationQueue=queue,clock=function() return env.now end,log=function() end}
    local admin=Admin.New{profileService=profile,repository=repo,gateway=store:LegacyGateway(),operationQueue=queue,
        adminPolicy={IsAdmin=function(_,uid) return uid==123 end,CanTarget=function() return true end},
        clock=function() return env.now end,auditOwnerUserId=123}
    admin.mailService=mail
    return {profile=profile,store=store,mail=mail,admin=admin}
end
local function attach(i,uid)
    local r; i.profile:Load(uid,function(result) r=result end); assert(r.ok,r.reason)
    i.profile:Attach(uid,{},1,r.data); i.profile:MarkReady(uid,1)
end
local spec={type="reward",title="旧版本",body="原有效期",expireAt=env.now+86400*10,
    attachments={{kind="currency",currency="gold",count=8}}}
local gm=instance()
env:addRow(gm.store.authorityUid,Store.Keys.LEGACY_PUBLIC,{batchId="old-A",createdAt=env.now,spec=spec})
env:addRow(gm.store.authorityUid,Store.Keys.LEGACY_PUBLIC,{batchId="old-B",createdAt=env.now,spec=spec})
local old=instance(); attach(old,42)
old.profile:Apply(42,"old receipt",function(state,now)
    local w=Transition.Copy(state,now); w.receivedBroadcasts["old-A"]=true
    return Transition.Finalize(state,w,now,"legacy",{},false,false)
end,function(r) assert(r.ok) end)
local delivered; old.mail:DeliverBroadcasts(42,function(r) delivered=r end)
assert(delivered.ok and delivered.data.delivered==1 and #old.profile:GetState(42).mails==1)
local rows=env.rows(gm.store.authorityUid,Store.Bucket(1))
assert(#rows==2 and #env.rows(gm.store.authorityUid,Store.Keys.LEGACY_PUBLIC)==0)
assert(rows[1].value.legacyBatchId=="old-A" and rows[1].value.spec.expireAt==spec.expireAt)
assert(env.score(42,Store.Keys.LEDGER).received=="1,2")
env:advance(61)
local restart=instance(); attach(restart,42)
restart.mail:DeliverBroadcasts(42,function(r) assert(r.ok and r.data.delivered==0) end)
-- GM sending uses the new shared List even if target is offline; no MessageSend.
local payload={targetUid="51",title="GM",body="queued",mailType="reward",attachments=spec.attachments}
local accepted; gm.admin:Execute(123,"send_mail",payload,function(r) accepted=r end)
assert(accepted.ok and accepted.data.mailId:match("gm%-mail:") and #env.rows(51,Store.Keys.PENDING)==1)
assert(next(env.db.messages)==nil)
local receiver=instance(); attach(receiver,51)
receiver.mail:DeliverBroadcasts(51,function(r) assert(r.ok and r.data.delivered==3) end)
-- Old personal tasks: proof is committed BEFORE source deletion. Failed delete
-- survives restart, mailbox deletion, and >64 completed audit records.
env:advance(61); receiver.store.foregroundUntil[51]=env.now+10
local command={commandId="old-personal",actorUid=123,targetUid=51,action="send_mail",payload={spec=spec},createdAt=env.now}
env.db.messages[500]={uid=51,key=Repo.Keys.PERSONAL_MAIL,value=command,read=false}
env.failAck=true
local pending; receiver.admin:ProcessInbox(51,function(r) pending=r end)
assert(pending.ok and pending.data.pending==1 and env.db.messages[500])
local audits=env.rows(51,Store.Keys.AUDIT)
assert(#audits==2 and audits[2].value.handoffPending and audits[2].value.commandId=="old-personal")
local count=#receiver.profile:GetState(51).mails
local mailboxId=receiver.profile:GetState(51).mails[count].id
receiver.mail:Claim(51,mailboxId,function(r) assert(r.ok) end)
receiver.mail:Delete(51,mailboxId,function(r) assert(r.ok) end)
env:advance(61); local again=instance(); attach(again,51)
again.store.foregroundUntil[51]=env.now+10
again.admin:ProcessInbox(51,function(r) assert(r.ok) end)
assert(#again.profile:GetState(51).mails==count-1,"unconfirmed proof survives claimed/deleted mail")
env.failAck=false; env:advance(61); again.store.foregroundUntil[51]=env.now+10
again.admin:ProcessInbox(51,function(r) assert(r.ok) end)
assert(env.db.messages[500]==nil)
audits=env.rows(51,Store.Keys.AUDIT)
assert(audits[2].value.handoffPending==false and audits[2].value.stage=="delivered")
-- Historical read tasks without a proven result must remain untouched.
env:advance(61); again.store.foregroundUntil[51]=env.now+10
env.db.messages[600]={uid=51,key=Repo.Keys.GM_COMMAND,value={commandId="no-evidence",actorUid=123,targetUid=51,action="send_mail",payload={spec=spec}},read=true}
local ambiguous=instance(); attach(ambiguous,51); ambiguous.store.foregroundUntil[51]=env.now+10
ambiguous.admin:ProcessInbox(51,function(r) assert(r.ok) end)
assert(env.db.messages[600] and #ambiguous.profile:GetState(51).mails==count-1)
-- Proven old success becomes a ledger audit without recreating deleted mail;
-- dedicated PERSONAL_MAIL read history follows the same compatibility rule.
env:advance(61); ambiguous.store.foregroundUntil[51]=env.now+10
env.db.messages[601]={uid=51,key=Repo.Keys.PERSONAL_MAIL,value={commandId="proven-success",actorUid=123,targetUid=51,action="send_mail",payload={spec=spec}},read=true}
env.db.messages[602]={uid=123,key=Repo.Keys.GM_RESULT,value={commandId="proven-success",targetUid=51,action="send_mail",ok=true,status="applied"},read=false}
ambiguous.admin.legacyMailSessions[51]=nil
ambiguous.admin:ProcessInbox(51,function(r) assert(r.ok) end)
assert(env.db.messages[601]==nil and #ambiguous.profile:GetState(51).mails==count-1)
-- A malformed old reward does not poison migration of another valid record.
-- Indefinite old public sources retain their original zero expiry.
env=Fixture.New(); local mixed=instance(); attach(mixed,80)
local good={type="notice",title="forever",body="forever",expireAt=0,attachments={}}
env:addRow(mixed.store.authorityUid,Store.Keys.LEGACY_PUBLIC,{batchId="bad-old",spec={type="reward",title="bad",body="bad",attachments={{kind="currency",count=-1}}}})
env:addRow(mixed.store.authorityUid,Store.Keys.LEGACY_PUBLIC,{batchId="forever-old",createdAt=env.now,spec=good})
mixed.mail:DeliverBroadcasts(80,function(r) assert(r.ok and r.data.delivered==1 and r.data.pending==1) end)
assert(#env.rows(mixed.store.authorityUid,Store.Keys.LEGACY_PUBLIC)==1)
assert(env.rows(mixed.store.authorityUid,Store.Bucket(1))[1].value.spec.expireAt==0)
print("shared_mail_legacy: PASS (public aliases/expiry, stable GM ID, old personal handoff, failed acknowledgement, deleted mails, proven-only history)")
