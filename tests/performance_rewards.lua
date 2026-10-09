local A = require('client.IdleRewardAccumulator')
local summary=A.New()
for i=1,100000 do
    A.Accumulate(summary,{{kind='equipment_drop',itemId='item.'..i,name='装备',rarity='common'},
        {kind='battle_reward',gold=1,exp=1}})
end
assert(summary.equipmentCount==100000 and #summary.equipmentItems==100)
local count=0; for _ in pairs(summary.equipmentById) do count=count+1 end
assert(count==100)
local nextSummary=A.New(); A.Merge(nextSummary,summary)
assert(#nextSummary.equipmentItems==100 and nextSummary.equipmentCount==100000)
local live, animations, created = 0, {}, 0
local function widget(p)
    p=p or {}; local w={props=p,children={},parent=nil}; live=live+1; created=created+1
    function w:AddChild(child)
        assert(not child.destroyed,'cannot reuse a destroyed widget')
        if child.parent then child.parent:RemoveChild(child) end
        self.children[#self.children+1]=child; child.parent=self
    end
    function w:RemoveChild(child)
        for i,c in ipairs(self.children) do if c==child then table.remove(self.children,i);child.parent=nil;break end end
    end
    function w:Destroy()
        if self.destroyed then return end
        for i=#self.children,1,-1 do self.children[i]:Destroy() end
        animations[self]=nil
        if self.parent then self.parent:RemoveChild(self) end
        self.destroyed=true;live=live-1
    end
    function w:SetStyle(s) self.styles=(self.styles or 0)+1;for k,v in pairs(s) do self.props[k]=v end end
    function w:SetText(s) self.texts=(self.texts or 0)+1;self.props.text=s end
    function w:Animate(options) animations[self]=options end
    for _,c in ipairs(p.children or {}) do w:AddChild(c) end
    return w
end
local UI={Panel=widget,ScrollView=widget,Button=widget,Label=widget}
package.loaded['urhox-libs/UI']=UI
package.loaded['client.Theme']={Colors={},CONFIG={}}
package.loaded['client.ViewAssets']={ASSETS={items={}}}
package.loaded['client.ViewKit']={CompactTxt=function(text,_,_,p) p=p or {};p.text=text;return widget(p) end}
package.loaded['client.ItemView']={}
package.loaded['client.BackpackItemSlot']={Build=function() return widget() end}
package.loaded['client.HorizontalArrowScroller']={}
package.loaded['client.AudioController']={PlayFeedback=function() end}
local Changed=require('client.UI.ChangedOnly')
local test=widget()
for i=1,10000 do Changed.Style(test,{opacity=1,width=42});Changed.Text(test,'same') end
assert(test.styles==1 and test.texts==1);test:Destroy()
local V=require('client.RewardDialogView')
local cards={}
for i=1,10000 do cards[i]=V.DescribeCard('icon','item '..i,'1','rare') end
local label=widget()
local before=live
local panel=V.BuildCardPanel(cards,label)
assert(live-before<=13,'only one small page of cards is materialized')
for i=1,100 do panel.children[3].props.onClick();assert(live-before<=13) end
panel:Destroy();label:Destroy();assert(live==0)
local C=require('client.CommonPromptDialog')
local D=require('client.DialogCoordinator')
local root=widget()
local function txt(text,_,_,p) p=p or {};p.text=text;return widget(p) end
C.Configure({txt=txt,multiTxt=txt}); C.AttachRoot(root)
local Access = require('client.UI.DialogSettingsAccess')
local settingsOpened = 0
Access.Configure(function() settingsOpened = settingsOpened + 1 end)
for i=1,200 do
    assert(C.Show({queueKey='reward.'..i,celebration=true,title='礼包',message='奖励',onConfirm=function() end}))
    local controls = {}
    Access.AllowInTree(root, function(control) controls[#controls+1] = control end)
    assert(#controls == 1 and controls[1].parent ~= root, 'settings must belong to the dialog')
    controls[1].props.onClick()
    assert(settingsOpened == i)
    assert(next(animations),'reward has active animations')
    D.ConfirmActive()
    assert(controls[1].destroyed, 'dialog settings must be destroyed with the dialog')
    assert(not next(animations) and live==1,'closing must cancel looping celebration and free native nodes')
end
local first = Access.Wrap(widget({width=900,height=800}))
local second = Access.Wrap(widget({width=996,height=800,zIndex=2100}))
assert(second.children[2].props.zIndex > second.children[1].props.zIndex,
    'side settings must remain above a wide frame where their bounds overlap')
root:AddChild(first);root:AddChild(second)
local allowed={}
Access.AllowInTree(root,function(control) allowed[#allowed+1]=control end)
assert(#allowed==2, 'tutorial must allow settings for all stacked dialogs')
first:Destroy();second:Destroy();assert(live==1)
local retained=widget();retained.retainOnDialogRebuild=true
local foreground=widget()
assert(C.Show({queueKey='rebuild',content=retained,foregroundContent=foreground,celebration=true}))
C.DetachForRebuild();assert(not retained.destroyed and not foreground.destroyed)
local newRoot=widget();root:Destroy();C.AttachRoot(newRoot)
assert(not retained.destroyed and D.GetState().active)
D.CancelActive();assert(retained.destroyed and foreground.destroyed and not next(animations))
C.Reset();newRoot:Destroy();assert(live==0)
print('performance_rewards: PASS (100000 drops, 100 pages, 200 animated dialog lifecycles)')
