local function Widget(props)
    local w = { props = props or {}, children = {}, writes = 0 }
    function w:AddChild(c)
        if c.parent then c.parent:RemoveChild(c) end
        self.children[#self.children + 1] = c; c.parent = self
    end
    function w:RemoveChild(c) for i,v in ipairs(self.children) do if v == c then table.remove(self.children,i); c.parent=nil; break end end end
    function w:SetStyle(p) self.writes=self.writes+1; for k,v in pairs(p) do self.props[k]=v end end
    function w:SetVisible(v) self:SetStyle({visible=v}) end
    function w:SetText(v) self:SetStyle({text=v}) end
    function w:SetFontColor(v) self:SetStyle({fontColor=v}) end
    function w:SetDisabled(v) self:SetStyle({disabled=v}) end
    function w:GetLayout() return { x=0,y=0,w=1080,h=1440 } end
    function w:Animate(p) self.animation=p end
    function w:Destroy() self.destroyed=true end
    for _, c in ipairs(w.props.children or {}) do w:AddChild(c) end
    return w
end
local function Writes(w) local n=w.writes; for _,c in ipairs(w.children) do n=n+Writes(c) end; return n end
local UI={Panel=Widget,Button=Widget,Toast={Show=function() end}}
package.loaded['urhox-libs/UI']=UI
package.loaded['urhox-libs/UI/Core/ImageCache']={}
package.loaded['client.AbyssPresentation']={BuildPillar=function() return Widget({}) end}
local Assets=require('client.ViewAssets')
local L=Assets.LAYOUT
local colors=setmetatable({}, {__index=function() return {255,255,255,255} end})
local function Text(text,_,_,props) props=props or {};props.text=text; return Widget(props) end
local Kit={Txt=Text,CompactTxt=Text,ActionButton=Widget}
package.loaded['client.ViewKit']=Kit
package.loaded['client.Theme']={Colors=colors}
local Big=require('shared.BigNumber')
local tower={floor=1,position=0,room=1,stats={hp=100,power=100},hp=100,autoRun=false,page='play'}
package.loaded['client.GameStateAdapter']={GetViewState=function() return tower end}
local context={UI=UI,colors=colors,assets=Assets.ASSETS,getGame=function() return tower end,
    compactTxt=Text,txt=Text,formatInt=function() return '100' end,
    currentPlayer=Assets.CurrentPlayer,updateTopBar=function() end,
    imageProgress=function() return Widget({}),Widget({}) end,setImageProgress=function(w,_,v) w:SetStyle({value=v}) end,
    loadingController={IsPlayAssetLoading=function() return false end},
    getRunParams=function() return {fps=8,w=L.RUN_W,h=L.RUN_H,x=0,y=0} end,
    getAttackParams=function() return {fps=24,w=L.RUN_W,h=L.RUN_H,x=0,y=0} end,
    serverClient={EnterEncounter=function() error('trial issued tower encounter') end},
    runW=L.RUN_W,runH=L.RUN_H,playerSize=L.PLAYER_SIZE,playerScreenX=L.PLAYER_SCREEN_X,
    bgTileW=L.BG_TILE_W,bgTileTop=L.BG_TILE_TOP,bgTileH=L.BG_TILE_H,roadY=L.ROAD_Y,
    lootSize=L.LOOT_SIZE,lootFootOffset=L.LOOT_FOOT_OFFSET,platformPlayerY=L.PLATFORM_PLAYER_Y,
    enemySize=L.ENEMY_SIZE,eventTriggerDistance=L.EVENT_TRIGGER_DISTANCE,eventViewCount=L.EVENT_VIEW_COUNT,
    presentationSpeed=L.PRESENTATION_SPEED}
local Presentation=require('client.PlayPresentation')
Presentation.Configure(context)
local towerRoot=Presentation.BuildPage()
local factory=require('server.domain.StateFactory')
local engine=require('server.domain.CampaignEngine')
local state=factory.Create(1791455000)
local _, opening=engine.PrepareTrial(state,'main:c01:a',function() return 0.5 end)
state=engine.SettleTrial(state,'main:c01:a',opening,1791455000).state
local report=assert(engine.PrepareTrial(state,'main:c01:b',function() return 0.5 end))
local sends,settles,aborts=0,0,0
local deferredPrepare
local function Server(stage,action,id,page,cb)
    sends=sends+1
    if action=='prepare' then
        if deferredPrepare then deferredPrepare=cb; return end
        cb({ok=true,data={trialId='trial:1',duration=report.duration,limit=report.limit,waves=report.waves,playerMaxHp=report.playerMaxHp,pages=1}})
    elseif action=='frames' then cb({ok=true,data={trialId=id,frames=report.frames}})
    elseif action=='finish' then settles=settles+1; cb({ok=true,data={won=true,stars=3}})
    elseif action=='abort' then aborts=aborts+1;cb({ok=true,data={}})
    else error(action) end
end
package.loaded['client.ServerClient']={CampaignTrial=Server}
package.loaded['client.LoadingController']={EnsurePlayAssetsReady=function(cb) cb() end}
local View=require('client.CampaignBattleView')
local stage=require('shared.CampaignCatalog').GetStage('main:c01:b')
local trial=View.Create(stage,function() end,function() end)
assert(trial.ready and trial.scene and trial.scene ~= Presentation)
local towerBefore=Writes(towerRoot)
local imageChanged=false
for _=1,2000 do
    trial:Update(0.025)
    if trial.settled then break end
end
assert(trial.settled and settles==1 and sends==3)
assert(Writes(towerRoot)==towerBefore,'trial animation must not mutate cached tower widgets')
local trialBefore=Writes(trial.root)
Presentation.Update(0.1)
assert(Writes(trial.root)==trialBefore,'tower animation must not mutate trial widgets')
trial:Destroy(); assert(aborts==0)
local cancelled=View.Create(stage,function() end,function() end)
cancelled:Destroy(); assert(aborts==1)
for _=1,100 do cancelled:Update(1) end
assert(settles==1,'closed view must stop advancing')
deferredPrepare=true
local delayed=View.Create(stage,function() end,function() end)
delayed:Destroy()
deferredPrepare({ok=true,data={trialId='trial:late'}})
assert(aborts==2,'late preparation must release its exact trial')
print('campaign_presentation: PASS')
