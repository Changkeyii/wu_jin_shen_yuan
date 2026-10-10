local Fixture = dofile("tests/helpers/mail_cloud_fixture.lua")
local Store = require("server.services.CloudMailStore")
local Gateway = require("server.dao.ServerCloudGateway")
local env=Fixture.New()
local function instance()
    return Store.New{gateway=Gateway.New(env.cloud),encodeJson=Fixture.Json,
        clock=function() return env.now end,log=function() end}
end
local store=instance()
local spec={type="notice",title="limits",body="limits",expireAt=env.now+86400*365,attachments={}}
local m=store:_emptyManifest(); m.migrated=true
local entries={}; for i=1,512 do entries[i]={spec=spec} end
local full
store:_changePublic(m,entries,function(r) full=r end,true)
assert(full.ok and full.data.document.sequence==512)
for i=1,16 do assert(#env.rows(store.authorityUid,Store.Bucket(i))==32) end
local before=require("server.domain.TableUtils").DeepCopy(env.db)
local rejected
store:QueueBroadcast(spec,function(r) rejected=r end)
assert(rejected.code=="BROADCAST_LIMIT" and require("server.domain.TableUtils").DeepEqual(before,env.db))
-- Exactly 300 total queued + unresolved handoffs, including admission races.
local a,b=instance(),instance()
for i=1,299 do env:addRow(42,Store.Keys.PENDING,a:_source("cap-"..i,spec)) end
env.pause=true; local ra,rb
a:QueuePersonal(42,"last-A",spec,function(r) ra=r end)
b:QueuePersonal(42,"last-B",spec,function(r) rb=r end)
assert(#env.pending==2); env:flush()
assert(ra.ok and not rb.ok and #env.rows(42,Store.Keys.PENDING)==300)
a:QueuePersonal(42,"too-many",spec,function(r) assert(r.code=="PERSONAL_MAIL_LIMIT") end)
env:addRow(43,Store.Keys.AUDIT,{id="unconfirmed",handoffPending=true,at=env.now,protocol=Store.VERSION})
for i=1,299 do env:addRow(43,Store.Keys.PENDING,a:_source("legacy-cap-"..i,spec)) end
a:QueuePersonal(43,"too-many-handoffs",spec,function(r) assert(r.code=="PERSONAL_MAIL_LIMIT") end)
-- Audit trimming cannot remove an unconfirmed handoff or an invalid record.
local audit={}
for i=1,64 do audit[#audit+1]={list_id=i,value={id="done"..i,at=i,handoffPending=false}} end
audit[#audit+1]={list_id=1000,value={id="pending",at=0,handoffPending=true}}
audit[#audit+1]={list_id=1001,value="broken"}
local trim=store:TrimAudit(audit,32)
assert(#trim==32)
for _,op in ipairs(trim) do assert(op.listId<1000) end
-- UTF-8 and escaped control characters measured as ACTUAL JSON bytes.
local source=a:_source("oversize",spec)
source.spec.extra=string.rep("中文\n",2000)
assert(#Fixture.Json(source)>8192 and not a:ValidSource(source,false))
source.spec.extra=nil; source.spec.extra=string.rep("a",8192-#Fixture.Json(source)-11)
assert(#Fixture.Json(source)==8192 and a:ValidSource(source,false))
source.spec.extra=source.spec.extra.."a"
assert(#Fixture.Json(source)==8193 and not a:ValidSource(source,false))
local receipt={}
for i=0,511 do receipt[Store.Limits.SEQUENCE-i]=true end
local ledger={protocol=Store.VERSION,version=Store.Limits.SEQUENCE,received=Store.EncodeReceipts(receipt),lastWriteId=string.rep("w",64)}
assert(Store.DecodeReceipts(ledger.received))
local bytes=#Fixture.Json(ledger); assert(bytes<4096)
receipt[Store.Limits.SEQUENCE-512]=true; assert(Store.EncodeReceipts(receipt)==nil)
assert(Store.DecodeReceipts("1,,2")==nil and Store.DecodeReceipts("01")==nil and Store.DecodeReceipts("1,1")==nil)
local doc=store:_emptyManifest(); doc.extra=string.rep("字",2000)
assert(not store:_manifest(doc))
-- Public read cache is shared for 60s; only changed buckets are fetched.
local cached=instance(); cached:ReadPublic(function(r) assert(r.ok and #r.data.entries==512) end,true)
local calls=env.calls["Get:"..Store.Keys.MANIFEST]
cached:ReadPublic(function(r) assert(r.ok) end,true)
assert(env.calls["Get:"..Store.Keys.MANIFEST]==calls)
local gets=env.calls["ListGet:"..Store.Bucket(1)]
env:advance(61); cached:ReadPublic(function(r) assert(r.ok) end,true)
assert(env.calls["ListGet:"..Store.Bucket(1)]==gets,"unchanged buckets are not fetched again")
-- Coalesced readers, lost/late callbacks and a budget reserved for foreground.
env:advance(61); local coalesced=instance(); local replies=0
env.dropRead="Get:"..Store.Keys.MANIFEST
coalesced:ReadPublic(function(r) assert(not r.ok); replies=replies+1 end,true)
coalesced:ReadPublic(function(r) assert(not r.ok); replies=replies+1 end,true)
assert(#coalesced.publicWaiters==2)
env:advance(10); coalesced:Update(); assert(replies==2)
for _,fn in ipairs(env.lost) do fn() end; assert(replies==2)
local budget=instance()
for _=1,28 do assert(budget:Reserve("read",false)) end
assert(not budget:Reserve("read",false))
for _=1,12 do assert(budget:Reserve("read",false,true)) end
assert(not budget:Reserve("read",false,true))
for _=1,20 do assert(budget:Reserve("read",true)) end
assert(not budget:Reserve("read",true))
env:advance(61); assert(budget:Reserve("read",false))
env.rateRead="Get:"..Store.Keys.LEDGER
local rate
budget:ReadPlayer(42,function(r) rate=r end,true)
assert(rate.code==-429)
budget:ReadPlayer(42,function(r) assert(r.code=="MAIL_RATE_DEFERRED" and r.data.retryAt==env.now+60) end,true)
-- Expired public receipts are pruned even while the bounded cleaner is still
-- draining old buckets; replacing expired sources cannot overflow a 512-ID ledger.
env:advance(86400*366)
local expired=instance(); local cleaned
expired:ReadPublic(function(r) cleaned=r end,true)
assert(cleaned.ok and #cleaned.data.entries==0 and next(cleaned.data.activeSequences)==nil)
local replacement={type="notice",title="replacement",body="replacement",expireAt=env.now+86400,attachments={}}
expired:QueueBroadcast(replacement,function(r) assert(r.ok) end)
local Repo=require("server.repositories.PlayerProfileRepository")
local Profile=require("server.services.PlayerProfileService")
local MailService=require("server.services.MailService")
local profile=Profile.New{repository=Repo.New{gateway=Gateway.New(env.cloud),clock=function() return env.now end},clock=function() return env.now end}
local loaded; profile:Load(90,function(r) loaded=r end); assert(loaded.ok)
profile:Attach(90,{},1,loaded.data)
local oldReceipts={}; for n=1,512 do oldReceipts[n]=true end
env.db.scores[env.field(90,Store.Keys.LEDGER)]={protocol=Store.VERSION,version=0,received=Store.EncodeReceipts(oldReceipts)}
local service=MailService.New{profileService=profile,sharedStore=instance(),clock=function() return env.now end}
service:DeliverBroadcasts(90,function(r) assert(r.ok and r.data.delivered==1) end)
local newReceipts=Store.DecodeReceipts(env.score(90,Store.Keys.LEDGER).received)
assert(newReceipts and newReceipts[513] and not newReceipts[1])
print("shared_mail_limits: PASS (512 broadcasts, 300 pending/handoffs, atomic admission, 64 audits, 8 KiB boundary, ledger bytes="..bytes..", cache/coalescing/budgets)")
