local Power=require('server.services.LeaderboardService')
local Score=require('server.services.ScoreLeaderboardService')
local Big=require('shared.BigNumber')
local Codec=require('shared.LeaderboardCodec')
local Config=require('server.ServerConfig')
local function copy(value)
    if type(value)~='table' then return value end
    local out={};for k,v in pairs(value) do out[k]=copy(v) end;return out
end
local now,records,quotas=100,{},{}
local gateway={available=true,held={}}
local function row(uid)
    records[uid]=records[uid] or {scores={},iscores={}}
    return records[uid]
end
function gateway:IsAvailable() return self.available end
function gateway:BatchCommit(_,operations,done)
    operations=copy(operations)
    local function apply()
        if self.failWrite then done({ok=false});return end
        -- Evaluate all guards before applying ANY writes, like BatchCommit.
        for _,op in ipairs(operations) do
            if op.kind=='quota_add' then
                assert(not op.refreshType,'revision guard must never reset')
                if (quotas[op.key] or 0)+op.value>op.limit then
                    self.conflicts=(self.conflicts or 0)+1;done({ok=false});return
                end
            end
        end
        for _,op in ipairs(operations) do
            local data=row(op.userId)
            if op.kind=='quota_add' then quotas[op.key]=(quotas[op.key] or 0)+op.value
            elseif op.kind=='score_set' then data.scores[op.key]=copy(op.value)
            elseif op.kind=='score_set_int' then data.iscores[op.key]=op.value
            elseif op.kind=='score_delete' then data.scores[op.key]=nil
            elseif op.kind=='score_delete_int' then data.iscores[op.key]=nil
            else error(op.kind) end
        end
        done({ok=true})
    end
    if self.holdWrite then self.held[#self.held+1]=apply else apply() end
end
function gateway:RankGetList(key,_,count,asc,done)
    assert(asc==false)
    local list={}
    for uid,data in pairs(records) do
        if data.iscores[key]~=nil then list[#list+1]={userId=uid,iscore={[key]=data.iscores[key]}} end
    end
    table.sort(list,function(a,b)
        return a.iscore[key]>b.iscore[key] or (a.iscore[key]==b.iscore[key] and a.userId<b.userId)
    end)
    while #list>count do table.remove(list) end
    done({ok=true,data={rankList=copy(list)}})
end
function gateway:BatchGet(ids,keys,done)
    if self.failRead then done({ok=false});return end
    local data
    if type(ids)=='number' then data=copy(row(ids))
    else
        data={results={}}
        for _,uid in ipairs(ids) do
            local r=row(uid)
            data.results[#data.results+1]={userId=tostring(uid),score=copy(r.scores),iscore=copy(r.iscores)}
        end
    end
    if self.holdRead then self.delayedRead=function() done({ok=true,data=data}) end
    else done({ok=true,data=data}) end
end
local function options(board)
    board=board or 'power'
    return {gateway=gateway,clock=function() return now end,log=function() end,boardId=board,
        keyScore='lb_'..board,keyNick='lb_'..board..'_nick'}
end
local a,b=Power.New(options()),Power.New(options())
local emptyBlob=Codec.ToHex(Codec.Pack({},0))
-- Legacy clouds may already contain more than 100 rows from independent servers.
for uid=1,140 do
    local r=row(uid);r.iscores.lb_power=uid;r.scores.lb_nick='player'..uid;r.scores.lb_blob=emptyBlob
    r.scores.abyss_profile={gold=123}
end
row(139).scores.lb_nick=nil
local function top(service,uid)
    local result;service:GetTop(uid,function(r) result=r end)
    assert(result and result.ok,result and result.reason);return result.data
end
local function equalBoards()
    local x,y=top(a,140),top(b,139)
    assert(x.version==y.version and #x.list==#y.list and #x.list<=100)
    for i,v in ipairs(x.list) do
        local other=y.list[i]
        assert(v.userId==other.userId and v.rank==other.rank and v.nickname==other.nickname and Big.Compare(v.power,other.power)==0)
    end
    return x
end
local result=equalBoards()
assert(#result.list==100 and result.list[1].userId==140 and result.list[100].userId==41)
assert(result.list[2].nickname=='玩家 139','missing nickname never removes a player')
a:Update();now=now+30;a:Update()
for uid=1,140 do
    assert(row(uid).iscores.lb_power==nil and row(uid).scores.lb_blob==nil,'legacy rank keys retired')
    assert(row(uid).scores.abyss_profile.gold==123,'player profiles remain untouched')
end
local function detailCount()
    local count=0;for _,r in pairs(records) do if r.scores[a.store.keyDetail] then count=count+1 end end
    return count
end
assert(detailCount()==100)
a:Upsert(200,'new',200,{},0)
result=equalBoards()
assert(result.list[1].userId==200 and detailCount()==100 and not row(41).scores[a.store.keyDetail])
for uid=201,420 do a:Upsert(uid,'new'..uid,uid,{},0) end
assert(#equalBoards().list==100 and detailCount()==100 and #a.store.savedOrder<=128)
local version=top(a).version
a:Upsert(900,'too low',1,{},0)
assert(top(a).version==version and not row(900).scores[a.store.keyDetail],'nonqualifying candidates are not persisted')
local detail;b:GetDetail(420,function(r) detail=r end)
assert(detail.ok and detail.data.nickname=='new420' and Big.Compare(detail.data.power,420)==0)
b:GetDetail(41,function(r) detail=r end);assert(not detail.ok and detail.code=='NOT_ON_LEADERBOARD')
-- Two servers race from the same revision; winner commits, loser reloads/merges.
gateway.holdWrite=true
a:Upsert(501,'racerA',1000,{},0);b:Upsert(502,'racerB',1001,{},0)
assert(#gateway.held==2)
gateway.holdWrite=false
gateway.held[2]();gateway.held[1]();gateway.held={}
result=equalBoards()
assert(result.list[1].userId==502 and result.list[2].userId==501 and gateway.conflicts>=1)
assert(detailCount()==100)
-- A timed-out commit cannot overwrite a newer revision when it finally arrives.
gateway.holdWrite=true
a:Upsert(503,'late',1002,{},0)
now=now+11;a:Update()
gateway.holdWrite=false
b:Upsert(504,'winner',1003,{},0)
gateway.held[1]();gateway.held={}
now=now+5;a:Update()
result=equalBoards()
assert(result.list[1].userId==504 and result.list[2].userId==503)
gateway.failWrite=true
a:Upsert(505,'retry',1004,{},0);assert(a.store.pending[505])
gateway.failWrite=false;now=now+5;a:Update();assert(top(b).list[1].userId==505)
gateway.available=false
a:GetTop(1,function(r) result=r end);assert(not result.ok and not result.data)
gateway.available=true;gateway.failRead=true
a:GetTop(1,function(r) result=r end);assert(not result.ok)
gateway.failRead=false;gateway.holdRead=true
local calls=0
a:GetTop(1,function(r) calls=calls+1;assert(not r.ok) end)
now=now+11;a:Update();assert(calls==1)
gateway.holdRead=false;gateway.delayedRead();assert(calls==1)
a:Upsert(600,'huge',{mantissa=1.5,exponent=80},{},0)
assert(Big.Compare(top(b).list[1].power,{mantissa=1.5,exponent=80})==0,'large power does not overflow integer cloud ranks')
local da,db=Score.New(options('dmg')),Score.New(options('dmg'))
da:Upsert(1,'one',1000);db:Upsert(2,'two',2000)
local restart=Score.New(options('dmg'));restart:Upsert(1,'renamed',2)
assert(top(db).list[2].score==1000,'best score is checked against shared document')
local boss=Score.New(options('boss'));boss:Upsert(3,'three',3000)
assert(#top(boss).list==1 and #top(da).list==2)
local commands={}
require('server.commands.GameCommands').Register({Register=function(_,c) commands[c.name]=c end},
    {leaderboardService=b,damageLeaderboardService=db,bossLeaderboardService=boss})
commands['Leaderboard.GetTop'].handler({uid=2},{board='damage'},function(ok,data)
    assert(ok and data.board=='damage' and data.selfRank==1 and #data.list==2)
end)
commands['Leaderboard.GetDetail'].handler({uid=600},{userId='600'},function(ok,data) assert(ok and data.isSelf) end)
assert(commands['Leaderboard.GetTop'].async and commands['Leaderboard.GetDetail'].async)
assert(Config.IsAdmin(162878756))
print('leaderboard_authority: PASS (shared Top100, migration, atomic races, late commits, bounded details)')
