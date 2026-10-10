local F = require('server.domain.StateFactory')
local T = require('server.domain.PlayerTransition')
local E = require('server.domain.AdGiftEngine')
local R = require('server.domain.RewardClaimEngine')
local Rewards = require('server.domain.RewardEngine')
local Large = require('shared.LargeNumber')
local D = require('shared.AdGiftDefinitions')
local Config = require('server.ServerConfig')
local Limiter = require('server.core.RateLimiter')
local now = 1791450000
local function fresh()
    local s=F.Create(now); s.tutorial.completed=true; return s
end
local clock=0
local limiter=Limiter.New { clock=function() return clock end }
assert(Config.RATES.DailyClaim.refillRate==1 and Config.RATES.DailyClaim.burst==10)
assert(Config.RATES.Equipment.refillRate==20 and Config.RATES.Equipment.burst==40)
assert(Config.RATES.AdminMutation.refillRate==0.2 and Config.RATES.AdminMutation.burst==2)
for i=1,10 do assert(limiter:Check('user','claim',Config.RATES.DailyClaim)) end
assert(not limiter:Check('user','claim',Config.RATES.DailyClaim))
assert(limiter:Check('user','equipment',Config.RATES.Equipment), 'separate commands never share a click lock')
clock=1; assert(limiter:Check('user','claim',Config.RATES.DailyClaim))
local s=fresh()
for _,source in ipairs({'signin','task','level_milestone','abyss_settlement'}) do
    assert(not R.CreateAdOffer(s,{source=source,sourceKey='test:1',baseReward={gold=100}},now))
end
for _,floor in ipairs({10,49,51,100}) do
    local offer=R.CreateAdOffer(s,{source='floor_milestone',sourceKey='floor:'..floor,baseReward={gold=100,exp=500,fragments=20,abyssTickets=30}},now)
    assert((offer~=nil)==(floor%50==0))
    if offer then assert(offer.extraReward.exp==0 and offer.extraReward.abyssTickets==0) end
end
local offer=R.CreateAdOffer(s,{source='campaign',sourceKey='campaign:first:main:c01:c',baseReward={gold=100,exp=500,fragments=20}},now)
local paid=R.ClaimAdExtra(s,offer.id,now)
local saved=require('shared.GameStateSchema').ToPersistedState(paid.state)
local retry=R.ClaimAdExtra(T.Copy(saved,now),offer.id,now)
assert(retry.ok and Large.Compare(paid.state.gold,retry.state.gold)==0, 'receipt survives normalization/save reload')
assert(#retry.delta.events==1)
-- Old pending entitlements remain redeemable, including their original resource mix.
local legacy=fresh()
legacy.rewardClaims.pending={{id='rc.900.1',source='signin',sourceKey='old:signin',createdAt=now,expiresAt=0,
    baseReward={gold=Large.FromNumber(2),exp=0,fragments=1,abyssTickets=2},
    extraReward={gold=Large.FromNumber(8),exp=0,fragments=4,abyssTickets=8},meta={}}}
assert(R.ClaimAdExtra(legacy,'rc.900.1',now).ok)
-- Aggregate separate event rewards, freeze one quote, never consume future events.
s=fresh(); E.OnDecompose(s,40,{}); E.OnDecompose(s,40,{})
assert(s.rewardClaims.gifts.offers.recycle.fragments==20, 'same event id is deduplicated')
s.revision=s.revision+1; E.OnDecompose(s,80,{})
assert(s.rewardClaims.gifts.offers.recycle.fragments==60)
local p=E.Prepare(s,'recycle',now); local quote=p.state.rewardClaims.gifts.quote
E.OnDecompose(p.state,100,{})
local result=E.Claim(p.state,quote.id,now)
assert(result.state.rewardClaims.gifts.offers.recycle.fragments==50)
local nextGift=E.Prepare(result.state,'recycle',now)
assert(nextGift.state.rewardClaims.gifts.quote.reward.fragments==50)
result=E.Claim(nextGift.state,nextGift.state.rewardClaims.gifts.quote.id,now)
assert(not E.Prepare(result.state,'recycle',now).ok)
assert(Large.Compare(E.Claim(result.state,quote.id,now).state.fragments,result.state.fragments)==0)
local old=D.Normalize({offers={boss={gold=50},journey={jars=1}},quote={id='gift.2',kind='boss',reward={gold=50}}})
assert(old.version==D.VERSION and not old.offers.boss and old.offers.journey.jars==1)
for _,seconds in ipairs({899,900,13*3600}) do
    s=fresh(); s.lastActiveAt=now-seconds
    local accrued=Rewards.AccrueOffline(s,now)
    assert(accrued.state.pendingOfflineSeconds==(seconds<900 and 0 or math.min(seconds,24*3600)))
    local ledger=Rewards.FreezeOfflineReward(accrued.state,now,function() return 0.99 end)
    assert((ledger~=nil)==(seconds>=900))
    if ledger then
        local claim=Rewards.ClaimOfflineReward(accrued.state,ledger,now)
        assert(claim.ok and not Rewards.ClaimOfflineReward(claim.state,ledger,now).ok)
    end
end
-- Recovery uses the serialized authoritative mutation, preserving earned resources and pending rewards.
s=fresh(); s.autoRun=true; s.pendingOfflineSeconds=900
local session={state=s,campaignTrial={id='pending'}}
local registered, snapshot={},false
require('server.commands.GameCommands').Register({Register=function(_,def) registered[def.name]=def end},{
    profileService={GetSession=function() return session end, Apply=function(_,uid,op,mutator,cb)
        local result=mutator(session.state,now); session.state=result.state
        cb({ok=result.ok,data={state=result.state,delta=result.delta}})
    end},sendSnapshot=function() snapshot=true; return session.state end})
local complete
registered['Game.RecoverToHome'].handler({uid=1},{},function(ok) complete=ok end)
assert(complete and snapshot and not session.state.autoRun and not session.campaignTrial)
assert(session.state.pendingOfflineSeconds==900 and Large.Compare(session.state.gold,s.gold)==0)
assert(#session.state.inventory==#s.inventory and session.state.tutorial.completed)
print('stability_economy: PASS')
