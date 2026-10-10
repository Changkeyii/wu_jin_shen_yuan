-- Exercise the production ServerClient snapshot path and count catalog lookups.
local Protocol=require('shared.NetworkProtocol')
local Schema=require('shared.GameStateSchema')
local Tables=require('shared.TableUtils')
local Catalog=require('shared.EquipmentCatalog')
local Adapter=require('client.GameStateAdapter')
local Client=require('client.ServerClient')
local callbacks,encoded,serial={},{},0
LOCAL=0
function VariantMap() return {} end
function Variant(v) return {GetString=function() return v end} end
function Scene() return {CreateComponent=function() end,Dispose=function() end} end
function SubscribeToEvent(name,callback) callbacks[name]=callback end
function UnsubscribeFromEvent(name) callbacks[name]=nil end
cjson={encode=function(v) serial=serial+1;encoded[tostring(serial)]=v;return tostring(serial) end,
    decode=function(k) return encoded[k] end}
local transport={SendRemoteEvent=function() end}
network={GetServerConnection=function() return transport end,RegisterRemoteEvent=function() end}
local function Receive(snapshot,events)
    local json=cjson.encode({snapshot=snapshot,events=events or {}})
    callbacks[Protocol.EVENTS.SNAPSHOT](nil,{[Protocol.FIELDS.PAYLOAD_JSON]={GetString=function() return json end}})
end
assert(Client.Start())
Client.On('error',function(r) error(tostring(r.reason)..' '..tostring(r.code)) end)
local factory=require('server.domain.StateFactory')
local state=factory.Create(1791455000)
state.tutorial.completed=true;state.storyProgress.introCompleted=true
state.wishPool.tickets=0;state.wishPool.jars={};state.abyss.tickets=0
local original=state.inventory[1]
local calls=0
local get=Catalog.Get
Catalog.Get=function(...) calls=calls+1;return get(...) end
local revision=state.revision
for _,size in ipairs({12,180,300}) do
    while #state.inventory<size do
        local item=Tables.DeepCopy(original);item.id=string.format('00000000-0000-4000-8000-%012d',#state.inventory)
        state.inventory[#state.inventory+1]=item
    end
    local elapsed,total=0,0
    for _=1,5 do
        revision=revision+1;state.revision=revision
        local snapshot=Schema.BuildSnapshot(state,{serverTime=1791455000,playerNickname='Snapshot budget'})
        snapshot.logs={};snapshot.recentDamage='Waiting'
        calls=0;local start=os.clock()
        Receive(snapshot)
        elapsed=elapsed+os.clock()-start;total=total+calls
        assert(Adapter.GetViewState().revision==revision)
        assert(#Adapter.GetViewState().inventory==size+1,'equipment plus projected potion slot')
        if not TOWER_RENDER_BASELINE then assert(calls==size*2,'snapshot projects inventory more than once') end
    end
    print(string.format('snapshot_budget items=%d catalogCalls=%.0f luaCpuMs=%.2f',size,total/5,elapsed/5*1000))
end
if TOWER_RENDER_BASELINE then return end
local view=Adapter.GetViewState()
local inventory,itemById,equipped=view.inventory,view.itemById,view.equipped
calls=0
Adapter.ApplySnapshotEvents({})
assert(Adapter.GetViewState()==view,'empty events should not rebuild the view')
Adapter.SetConnectionState('ready')
assert(Adapter.GetViewState()==view,'repeated ready state should not rebuild the view')
Adapter.SetConnectionState('disconnected')
assert(Adapter.GetViewState().readOnly and Adapter.GetViewState().inventory==inventory)
Adapter.SetConnectionState('ready')
assert(not Adapter.GetViewState().readOnly and Adapter.GetViewState().equipped==equipped)
Adapter.ApplySnapshotEvents({{kind='tutorial_completed'},{kind='battle_started',monsterId='budget',monsterHp=30},
    {kind='battle_hit',monsterHp=20,amount=10}})
view=Adapter.GetViewState()
assert(view.currentMonster.hp==20 and view.tutorial.completed)
assert(view.inventory==inventory and view.itemById==itemById and calls==0,
    'connection/combat/gate events must reuse the projected inventory')
Adapter.ApplySnapshotEvents({{kind='battle_won'}})
assert(not Adapter.GetViewState().currentMonster)
-- Genuine inventory and ticket changes still invalidate the projection.
Adapter.ApplyDelta({revision=revision+1,changes={wishPool={tickets=7},abyss={tickets=9}},events={}})
view=Adapter.GetViewState()
assert(view.inventory~=inventory and view.itemById.wish_ticket.quantity==7 and view.itemById.abyss_ticket.quantity==9)
local replacement=Tables.DeepCopy(state.inventory[1]);replacement.id='new-drop'
Adapter.ApplyDelta({revision=revision+2,changes={inventory={replacement},equippedSlots={}},events={}})
view=Adapter.GetViewState()
assert(#view.inventory==4 and view.itemById['new-drop'] and not view.itemById[state.inventory[1].id])
Client.Stop()
Catalog.Get=get
print('tower_snapshot_budget: PASS (single projection, connection/events reuse, real inventory/ticket invalidation)')
