-- Real presentation modules; native widgets mocked for deterministic work counts.
-- This measures Lua/UI submissions, not phone GPU time or battery consumption.
local all, animations, created = {}, {}, 0
local styles, hiddenGeometry, unchanged, layoutFields = 0, 0, 0, 0
local geometry = {left=true, top=true, width=true, height=true, right=true, bottom=true}
local function same(a,b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function Widget(props)
    local w = {props=props or {}, children={}}
    created=created+1; all[#all+1]=w
    function w:RemoveChild(c)
        for i,v in ipairs(self.children) do if v==c then table.remove(self.children,i);c.parent=nil;break end end
    end
    function w:InsertChild(c,i)
        if c.parent then c.parent:RemoveChild(c) end
        table.insert(self.children,i,c); c.parent=self
    end
    function w:AddChild(c) self:InsertChild(c,#self.children+1) end
    function w:SetStyle(s)
        assert(not self.destroyed, 'style submitted to destroyed widget')
        styles=styles+1; local different, geom = false,false
        for k,v in pairs(s) do
            if not same(self.props[k],v) then different=true end
            if geometry[k] then geom=true;layoutFields=layoutFields+1 end
        end
        if not different then unchanged=unchanged+1 end
        if geom and (s.visible==false or (s.visible==nil and self.props.visible==false)) then
            hiddenGeometry=hiddenGeometry+1
        end
        for k,v in pairs(s) do self.props[k]=v end
        self.lastStyle=s
    end
    function w:SetText(v) self.props.text=v end
    function w:SetFontColor(v) self.props.fontColor=v end
    function w:SetDisabled(v) self.props.disabled=v end
    function w:Hide() self:SetStyle({visible=false}) end
    function w:GetLayout() return {x=0,y=0,w=1080,h=1440} end
    function w:Animate(config) animations[self]={config=config,age=0} end
    function w:Destroy()
        if self.destroyed then return end
        for i=#self.children,1,-1 do self.children[i]:Destroy() end
        animations[self]=nil
        if self.parent then self.parent:RemoveChild(self) end
        self.destroyed=true
    end
    for _,c in ipairs(w.props.children or {}) do w:AddChild(c) end
    return w
end
local function Tick(dt)
    local completed={}
    for w,a in pairs(animations) do
        a.age=a.age+dt
        if a.age >= a.config.duration+(a.config.delay or 0) then completed[#completed+1]={w,a} end
    end
    for _,v in ipairs(completed) do
        local w,a=v[1],v[2]
        if animations[w]==a then
            animations[w]=nil
            if a.config.onComplete then a.config.onComplete() end
        end
    end
end
local UI={Panel=Widget,Button=Widget,Label=Widget,Toast={Show=function() end}}
package.loaded['urhox-libs/UI']=UI
package.loaded['client.Theme']={Colors=setmetatable({}, {__index=function() return {255,255,255,255} end})}
package.loaded['client.PerformanceController']={IsPowerSaving=function() return false end}
local Assets=require('client.ViewAssets')
local Kit=require('client.ViewKit')
local L=Assets.LAYOUT
local game
local context={UI=UI,assets=Assets.ASSETS,colors=require('client.Theme').Colors,
    getGame=function() return game end, currentPlayer=Assets.CurrentPlayer,
    compactTxt=Kit.CompactTxt,txt=Kit.Txt,formatInt=Kit.FormatInt,
    imageProgress=Kit.ImageProgress,setImageProgress=Kit.SetImageProgress,
    getRunParams=function() return {fps=16,w=L.RUN_W,h=L.RUN_H,x=0,y=0,scale=1} end,
    getAttackParams=function() return {fps=16,w=L.RUN_W,h=L.RUN_H,x=0,y=0,scale=1} end,
    loadingController={IsPlayAssetLoading=function() return false end,
        BeginFloorTransition=function() end,CompleteFloorTransition=function() end},
    updateTopBar=function() end,presentationOnly=true,
    serverClient={EnterEncounter=function() error('unexpected encounter request') end},
    runW=L.RUN_W,runH=L.RUN_H,playerSize=L.PLAYER_SIZE,playerScreenX=L.PLAYER_SCREEN_X,
    bgTileW=L.BG_TILE_W,bgTileTop=L.BG_TILE_TOP,bgTileH=L.BG_TILE_H,roadY=L.ROAD_Y,
    lootSize=L.LOOT_SIZE,lootFootOffset=L.LOOT_FOOT_OFFSET,platformPlayerY=L.PLATFORM_PLAYER_Y,
    enemySize=L.ENEMY_SIZE,eventTriggerDistance=L.EVENT_TRIGGER_DISTANCE,eventViewCount=L.EVENT_VIEW_COUNT,
    presentationSpeed=L.PRESENTATION_SPEED}
local route=require('shared.FloorRoute').Build(9)
local function Scene(room)
    game={floor=9,position=room,room=math.max(1,room),page='play',autoRun=true,
        floorRoute=route,stats={hp=100,power=100},hp=100}
    if room>0 then game.currentMonster={id='monster',hp=100,maxHp=100,sequenceIndex=1,phaseRemaining=100} end
    local scene=require('client.PlayPresentation').New()
    scene.Configure(context)
    local root=scene.BuildPage()
    if room>0 then scene.HandleDelta({events={{kind='attack_started',sequenceIndex=1,windupSeconds=100}}}) end
    return scene,root
end
for _,room in ipairs({0,1,9}) do
    local scene,root=Scene(room)
    scene.Update(1/60)
    styles,hiddenGeometry,unchanged,layoutFields=0,0,0,0
    local before=created
    for _=1,300 do Tick(1/60);scene.Update(1/60) end
    print(string.format('render_budget room=%d default60 styles/s=%.1f hidden/s=%.1f unchanged/s=%.1f layoutFields/s=%.1f newNodes=%d',
        room,styles/5,hiddenGeometry/5,unchanged/5,layoutFields/5,created-before))
    if not TOWER_RENDER_BASELINE then
        assert(hiddenGeometry==0,'hidden world/effect geometry still submitted every frame')
        assert(unchanged==0,'unchanged progress/style invalidates native layout')
        assert(styles/5<520,'default-mode rendering work budget exceeded')
        assert(created==before,'normal battle should allocate no widgets')
        assert(root.props.backgroundImage==nil,'root duplicates the three full-coverage background tiles')
        assert(root.children[1].props.height==1440 and root.children[1].props.top==0)
    end
    scene.Reset();root:Destroy()
end
if TOWER_RENDER_BASELINE then return end

-- Diff-only updates preserve nested style values and avoid redundant Yoga writes.
local Changed=require('client.UI.ChangedOnly')
local w=Widget({width=10,boxShadow={{blur=8,color={1,2,3,255}}}})
local before=styles
Changed.Style(w,{width=10,boxShadow={{blur=8,color={1,2,3,255}}}})
assert(styles==before)
Changed.Style(w,{width=10,opacity=0.5,boxShadow={{blur=8,color={1,2,3,255}}}})
assert(w.lastStyle.width==nil and w.lastStyle.boxShadow==nil and w.props.opacity==0.5)
Changed.Style(w,{boxShadow=false});assert(w.props.boxShadow==false);w:Destroy()

-- Lazy abyss pillars appear behind the correct enemy and stop moving when hidden.
local World=require('client.PlayWorldView').New()
World.Configure({UI=UI,assets=Assets.ASSETS,currentPlayer=Assets.CurrentPlayer,
    bgTileTop=0,bgTileW=1080,bgTileH=1440,runW=100,runH=100,playerSize=100,
    enemySize=100,lootSize=50,lootFootOffset=0,eventViewCount=2,enemyFootOffset=function() return 0 end})
before=created
local nodes=World.Build({playerScreenX=100,roadY=800,platformPlayerY=700})
assert(created-before==7,'normal scene preallocates unused abyss widgets')
local root=Widget({children=nodes})
local enemy=nodes[4]
local frame={metrics={height=1440},presentationX=0,roadEvents={{kind='enemy',x=600,image='enemy'}},
    activeParams={x=0,y=0,w=100,h=100,scale=1},animationTime=0,combatAnimationTime=0,
    playerScreenX=100,roadY=800,platformPlayerY=700,visualAutoRun=false}
World.Update(frame);before=created
frame.roadEvents[1].abyssGradeId='rift';World.Update(frame)
assert(created-before==5,'only the encountered grade is materialized')
local pillar=root.children[4]
assert(root.children[5]==enemy and pillar.props.visible==true)
before=created
frame.presentationX=1000;World.Update(frame)
styles,hiddenGeometry=0,0
for i=1,60 do frame.animationTime=i/60;World.Update(frame) end
assert(pillar.props.visible==false and hiddenGeometry==0 and created==before)
frame.presentationX=0;frame.roadEvents[1].abyssGradeId='mutated';World.Update(frame)
assert(pillar.props.visible==false and created==before+5)
frame.roadEvents[1].abyssGradeId='rift';World.Update(frame)
assert(pillar.props.visible==true)
World.Reset();root:Destroy()

-- Glow restores both absent/custom shadows; old completions cannot clear new glow.
local scene,sceneRoot=Scene(1)
-- The world player is the last node in the world prefix (3 tiles + 8 enemies + shadow).
local player=sceneRoot.children[3+L.EVENT_VIEW_COUNT+2]
local function Finisher(serial)
    scene.HandleDelta({events={{kind='attack_started',sequenceIndex=4,attackSerial=serial,windupSeconds=100}}})
end
Finisher(1)
local old=animations[player].config.onComplete
Finisher(2);local latest=animations[player].config.onComplete
old();assert(player.props.boxShadow~=false,'old completion cleared a newer finisher')
latest();assert(player.props.boxShadow==false,'absent original shadow must be explicitly disabled')
local custom={{blur=4,color={1,2,3,255}}};player.props.boxShadow=custom
Finisher(3);animations[player].config.onComplete();assert(player.props.boxShadow==custom)
Finisher(4);old=animations[player].config.onComplete
scene.ClearCombatPresentation(false);assert(player.props.boxShadow==custom)
old();assert(player.props.boxShadow==custom)

-- Over 100 finishers, the trail pool is bounded and reused; native nodes do not grow.
local function Ghosts()
    local n=0
    for _,node in ipairs(sceneRoot.children) do if node.props.borderRadius==36 then n=n+1 end end
    return n
end
local poolSize
for serial=5,104 do
    Finisher(serial)
    for _=1,120 do Tick(1/60);scene.Update(1/60) end
    local n=Ghosts();assert(n>0 and n<=6,'finisher trail pool exceeds its bound')
    poolSize=poolSize or n;assert(n==poolSize,'finisher trail allocates more nodes on later attacks')
end
scene.ClearCombatPresentation(false)
Tick(2)
for _,node in ipairs(sceneRoot.children) do
    if node.props.borderRadius==36 then assert(node.props.visible==false,'completed pooled ghost remains visible') end
end
Finisher(105);old=animations[player].config.onComplete
local newRoot=scene.BuildPage();sceneRoot:Destroy();old()
scene.Reset();newRoot:Destroy()
for _,node in ipairs(all) do assert(node.destroyed,'widget leaked after scene teardown') end
print('tower_render_budget: PASS (default 60 FPS, hidden/offscreen culling, lazy pillars, 100 finishers, glow lifecycle)')
