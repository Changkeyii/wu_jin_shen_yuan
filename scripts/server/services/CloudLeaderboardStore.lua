-- One shared, bounded Top100 document per board. A non-refreshing quota counter
-- is its revision: atomic QuotaAdd(1, expected+1) + ScoreSet rejects stale writers.
local BigNumber = require("shared.BigNumber")
local Config = require("server.ServerConfig")
---@class CloudLeaderboardStore
---@field gateway table
---@field clock fun(): number
---@field log fun(message: string)
---@field authorityUserId integer
---@field keyDocument string
---@field keyRevision string
---@field keyDetail string?
---@field legacyScore string
---@field legacyNick string
---@field legacyBlob string?
---@field onlyIncrease boolean?
---@field pending table
---@field saved table
---@field savedOrder table
---@field requests table
---@field writing table?
---@field cleaning boolean?
---@field retryAt number
---@field cleanupAt number
local Store = {}
Store.__index = Store
local LIMIT, TIMEOUT, RETRY_SECONDS = 100, 10, 5
local function Failure(reason)
    return {ok=false,code="LEADERBOARD_UNAVAILABLE",reason=reason or "排行榜加载失败，请稍后重试"}
end
local function Success(data) return {ok=true,data=data or {}} end
local function Same(a,b)
    return a and b and BigNumber.Compare(a.score,b.score)==0 and a.nickname==b.nickname and a.blobHex==b.blobHex
end
local function Sort(rows)
    table.sort(rows,function(a,b)
        local c=BigNumber.Compare(a.score,b.score)
        return c>0 or (c==0 and a.userId<b.userId)
    end)
    while #rows>LIMIT do table.remove(rows) end
end
local function CopyRow(row)
    return {userId=row.userId,nickname=row.nickname,score=row.score,detailVersion=row.detailVersion}
end
---@return CloudLeaderboardStore
function Store.New(options)
    local id=assert(options.boardId)
    local instance = {
        gateway=options.gateway,clock=options.clock or os.time,log=options.log or print,
        authorityUserId=Config.LEADERBOARD_AUTHORITY_UID,
        keyDocument="lb_top100_v1_"..id,keyRevision="lb_top100_v1_"..id.."_revision",
        keyDetail=options.keyBlob and ("lb_top100_v1_"..id.."_detail") or nil,
        legacyScore=options.keyScore,legacyNick=options.keyNick,legacyBlob=options.keyBlob,
        onlyIncrease=options.onlyIncrease,pending={},saved={},savedOrder={},requests={},retryAt=0,cleanupAt=0,
    }
    return setmetatable(instance,Store)
end
function Store:_request(callback)
    local request={deadline=self.clock()+TIMEOUT}
    self.requests[request]=true
    local function finish(result)
        if not self.requests[request] then return end
        self.requests[request]=nil;callback(result)
    end
    request.finish=finish
    return finish,function() return self.requests[request]==true end
end
function Store:_commit(expected,document,operations,onComplete)
    document.version=expected+1
    local changes={
        {kind="quota_add",userId=self.authorityUserId,key=self.keyRevision,value=1,limit=document.version},
        {kind="score_set",userId=self.authorityUserId,key=self.keyDocument,value=document},
    }
    for _,op in ipairs(operations or {}) do changes[#changes+1]=op end
    self.gateway:BatchCommit("global Top100 "..self.keyDocument,changes,onComplete)
end

-- A single guarded initializer migrates legacy cloud Top100, including offline
-- players. Losing initializers reload the winner's document.
function Store:_read(onComplete,active,attempt)
    attempt=attempt or 0
    self.gateway:BatchGet(self.authorityUserId,{self.keyDocument},function(result)
        if not active() then return end
        if not result.ok then onComplete(Failure());return end
        local document=(result.data.scores or {})[self.keyDocument]
        if document~=nil then
            if type(document)~="table" or type(document.rows)~="table" or #document.rows>LIMIT
                or type(document.version)~="number" or document.version<1 then
                onComplete(Failure("排行榜数据校验失败"));return
            end
            onComplete(Success(document));return
        end
        self.gateway:RankGetList(self.legacyScore,1,LIMIT,false,function(rankResult)
            if not active() then return end
            if not rankResult.ok then onComplete(Failure());return end
            local ids,rows,seen={},{},{}
            for _,row in ipairs(rankResult.data.rankList or {}) do
                local uid=tonumber(row.userId or row.player)
                local score=(row.iscore or row.iscores or {})[self.legacyScore]
                if not uid or score==nil or seen[uid] then onComplete(Failure());return end
                seen[uid]=true;ids[#ids+1]=uid
                rows[#rows+1]={userId=uid,score=score,nickname="玩家 "..tostring(uid)}
            end
            local function Initialize(metadata)
                if not active() then return end
                if not metadata.ok then onComplete(Failure());return end
                local values={}
                for _,row in ipairs((metadata.data or {}).results or {}) do
                    local uid=tonumber(row.userId or row.player)
                    if uid then values[uid]=row.score or row.scores or {} end
                end
                local writes={}
                for _,row in ipairs(rows) do
                    local data=values[row.userId] or {}
                    if type(data[self.legacyNick])=="string" and data[self.legacyNick]~="" then row.nickname=data[self.legacyNick] end
                    if self.keyDetail then
                        row.detailVersion=1
                        writes[#writes+1]={kind="score_set",userId=row.userId,key=self.keyDetail,
                            value={version=1,blobHex=data[self.legacyBlob] or ""}}
                    end
                end
                Sort(rows)
                self:_commit(0,{rows=rows},writes,function(committed)
                    if not active() then return end
                    if committed.ok then onComplete(Success({version=1,rows=rows}))
                    elseif attempt<2 then self:_read(onComplete,active,attempt+1)
                    else onComplete(Failure()) end
                end)
            end
            if #ids==0 then Initialize(Success({results={}}));return end
            local keys={self.legacyNick}
            if self.legacyBlob then keys[#keys+1]=self.legacyBlob end
            self.gateway:BatchGet(ids,keys,Initialize)
        end)
    end)
end
function Store:Upsert(userId,nickname,score,blobHex)
    userId=tonumber(userId)
    if not userId then return end
    local previous=self.pending[userId] or self.saved[userId]
    if self.onlyIncrease and previous and BigNumber.Compare(score,previous.score)<0 then score=previous.score end
    local value={userId=userId,nickname=tostring(nickname or ""),score=score,blobHex=blobHex}
    if Same(previous,value) and (self.pending[userId] or self.clock()<(previous.checkedAt or 0)+60) then return end
    self.pending[userId]=value;self:Flush()
end
function Store:Flush()
    if self.writing or self.clock()<self.retryAt then return end
    if not self.gateway or not self.gateway:IsAvailable() then return end
    local uid,value=next(self.pending)
    if not uid then return end
    self.writing=value
    local finish,active=self:_request(function(result)
        self.writing=nil
        if result.ok then
            value.checkedAt=self.clock()
            if not self.saved[uid] then self.savedOrder[#self.savedOrder+1]=uid end
            self.saved[uid]=value
            if #self.savedOrder>128 then self.saved[table.remove(self.savedOrder,1)]=nil end
            if self.pending[uid]==value then self.pending[uid]=nil end
            self:Flush()
        else
            self.retryAt=self.clock()+RETRY_SECONDS
            self.log("[Leaderboard] update deferred "..self.keyDocument.." uid="..tostring(uid))
        end
    end)
    local function Apply(attempt)
        self:_read(function(result)
            if not active() then return end
            if not result.ok then finish(result);return end
            local before=result.data
            local rows,existing={},nil
            for _,row in ipairs(before.rows) do
                if row.userId==uid then existing=row else rows[#rows+1]=CopyRow(row) end
            end
            local score=value.score
            if self.onlyIncrease and existing and BigNumber.Compare(score,existing.score)<0 then score=existing.score end
            local candidate={userId=uid,nickname=value.nickname,score=score,detailVersion=self.keyDetail and before.version+1 or nil}
            rows[#rows+1]=candidate;Sort(rows)
            local retained={}
            for _,row in ipairs(rows) do retained[row.userId]=true end
            if not existing and not retained[uid] then finish(Success());return end
            local writes={}
            if self.keyDetail and retained[uid] then
                writes[#writes+1]={kind="score_set",userId=uid,key=self.keyDetail,
                    value={version=candidate.detailVersion,blobHex=value.blobHex or ""}}
            end
            if self.keyDetail then
                for _,row in ipairs(before.rows) do
                    if not retained[row.userId] then writes[#writes+1]={kind="score_delete",userId=row.userId,key=self.keyDetail} end
                end
            end
            self:_commit(before.version,{rows=rows},writes,function(committed)
                if not active() then return end
                if committed.ok then finish(Success())
                elseif attempt<2 then Apply(attempt+1)
                else finish(Failure()) end
            end)
        end,active)
    end
    Apply(0)
end
function Store:GetTop(userId,onComplete)
    if not self.gateway or not self.gateway:IsAvailable() then onComplete(Failure());return end
    local finish,active=self:_request(onComplete)
    self:_read(function(result)
        if not result.ok then finish(result);return end
        local rows,selfRank={},0
        for index,row in ipairs(result.data.rows) do
            rows[#rows+1]={rank=index,userId=row.userId,nickname=row.nickname,power=row.score,score=row.score}
            if row.userId==tonumber(userId) then selfRank=index end
        end
        finish(Success({list=rows,selfRank=selfRank,total=#rows,version=result.data.version}))
    end,active)
end
function Store:GetDetail(userId,onComplete)
    if not self.gateway or not self.gateway:IsAvailable() then onComplete(Failure());return end
    local finish,active=self:_request(onComplete)
    local function Read(attempt)
        self:_read(function(result)
            if not result.ok then finish(result);return end
            local entry
            for _,row in ipairs(result.data.rows) do if row.userId==tonumber(userId) then entry=row;break end end
            if not entry then finish({ok=false,code="NOT_ON_LEADERBOARD",reason="该玩家已离开前 100 名"});return end
            self.gateway:BatchGet(entry.userId,{self.keyDetail},function(details)
                if not active() then return end
                if not details.ok then finish(Failure());return end
                local data=(details.data.scores or {})[self.keyDetail]
                if not data or data.version~=entry.detailVersion then
                    if attempt<1 then Read(attempt+1) else finish(Failure("榜单正在更新，请重试")) end
                    return
                end
                finish(Success({userId=entry.userId,nickname=entry.nickname,power=entry.score,blobHex=data.blobHex}))
            end)
        end,active)
    end
    Read(0)
end

-- New records use different keys. After initialization retire legacy per-user
-- rank keys in batches of at most 100, without touching profiles or new details.
function Store:_cleanupLegacy()
    if self.cleaning or self.clock()<self.cleanupAt or not self.gateway or not self.gateway:IsAvailable() then return end
    self.cleaning=true
    local finish,active=self:_request(function() self.cleaning=false;self.cleanupAt=self.clock()+30 end)
    self.gateway:BatchGet(self.authorityUserId,{self.keyDocument},function(result)
        if not active() then return end
        if not result.ok or not (result.data.scores or {})[self.keyDocument] then finish(Failure());return end
        self.gateway:RankGetList(self.legacyScore,1,LIMIT,false,function(ranks)
            if not active() then return end
            if not ranks.ok then finish(Failure());return end
            local operations={}
            for _,row in ipairs(ranks.data.rankList or {}) do
                local uid=tonumber(row.userId or row.player)
                if uid then
                    operations[#operations+1]={kind="score_delete_int",userId=uid,key=self.legacyScore}
                    operations[#operations+1]={kind="score_delete",userId=uid,key=self.legacyNick}
                    if self.legacyBlob then operations[#operations+1]={kind="score_delete",userId=uid,key=self.legacyBlob} end
                end
            end
            if #operations==0 then finish(Success());return end
            self.gateway:BatchCommit("retire legacy leaderboard keys",operations,finish)
        end)
    end)
end
function Store:Update()
    local expired={}
    for request in pairs(self.requests) do if self.clock()>=request.deadline then expired[#expired+1]=request end end
    for _,request in ipairs(expired) do request.finish(Failure("排行榜请求超时，请重试")) end
    self:Flush();self:_cleanupLegacy()
end
function Store:Reset()
    self.requests,self.pending,self.saved,self.savedOrder={},{},{},{}
    self.writing,self.cleaning,self.retryAt,self.cleanupAt=nil,nil,0,0
end
return Store
