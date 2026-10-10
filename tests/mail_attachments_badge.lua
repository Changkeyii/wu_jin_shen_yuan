-- Exercise the real composer and cached homepage with UI/network boundaries mocked.
local root, lastToast
local function widget(props)
    local w = {props = props or {}, children = {}}
    function w:AddChild(c) self.children[#self.children + 1] = c; c.parent = self end
    function w:Hide() self.props.visible = false end
    function w:Show() self.props.visible = true end
    function w:SetText(text) self.props.text = text end
    function w:SetChecked(value) self.props.checked = value end
    function w:SetStyle(style) for k,v in pairs(style) do self.props[k] = v end end
    function w:GetValue() return self.props.value end
    for _, c in ipairs(w.props.children or {}) do w:AddChild(c) end
    return w
end
local function find(w, key, value)
    if w.props[key] == value then return w end
    for _, c in ipairs(w.children) do local f = find(c,key,value); if f then return f end end
end
local UI = {Panel=widget, Label=widget, TextField=widget, Dropdown=widget,
    Button=widget, Checkbox=widget, ScrollView=widget, Alert=widget,
    Toast={Show=function(text) lastToast=text end},
    FindById=function(id) return root and find(root,'id',id) end}
package.loaded['urhox-libs/UI'] = UI
local requests, pending = {}, nil
local function send(kind, payload, callback)
    requests[#requests + 1] = {kind=kind, payload=payload}
    pending = callback
end
package.loaded['client.ServerClient'] = {
    AdminSendMail=function(p,c) send('personal',p,c) end,
    AdminSendBroadcastMail=function(p,c) send('broadcast',p,c) end,
}
local Admin = require('client.AdminPanel')
local readOnly = false
local refresh
refresh = function() root = Admin.Build(UI,{onChanged=refresh,readOnly=readOnly}) end
local function click(text) assert(find(root,'text',text),text).props.onClick() end
local function set(field, value) field.props.value=value; field.props.onChange(field,value) end
local function input(label,value) set(assert(find(root,'text',label),label).parent.children[2],value) end
local function section(title) return assert(find(root,'text',title),title).parent end
local function addCurrency(currency, amount)
    local sec=section('添加货币附件')
    local row=sec.children[2]
    set(row.children[1].children[2],currency)
    input('数量',tostring(amount))
    find(sec,'text','加入邮件附件').props.onClick()
end
refresh()
-- Mail tab exposes the very same currency/equipment/item controls as the player tab.
find(root,'text','邮件管理').parent.props.onClick()
assert(section('添加装备附件') and section('添加道具附件（多选）'))
addCurrency('gold',1000); addCurrency('fragments',200)
find(section('添加装备附件'),'text','加入邮件附件').props.onClick()
local itemSection=section('添加道具附件（多选）')
local itemScroll=itemSection.children[4]
assert(itemScroll.props.height==420)
local rows=itemScroll.children[1].children
assert(#rows>6,'all item rows must survive table construction, not just the first')
for i=1,3 do
    assert(rows[i].children[1].props.label and rows[i].children[1].props.height >= 80)
    assert(rows[i].children[1].props.flexGrow == 1 and #rows[i].children == 2,
        'the name and selection share a large native checkbox, separate from the count field')
    rows[i].children[1].props.onChange(rows[i].children[1],true)
    set(rows[i].children[2],tostring(i+1))
end
click('选中道具加入附件')
assert(find(root,'text','待发送附件（6/6）') and #requests==0,'adding only edits the draft')
addCurrency('gold',1)
assert(find(root,'text','待发送附件（6/6）') and lastToast:find('最多'))
click('发送个人邮件'); assert(#requests==0,'personal recipient is required')
click('发送全服邮件'); click('发送全服邮件')
assert(#requests==1 and requests[1].kind=='broadcast','broadcast needs no target and deduplicates pending clicks')
local broadcast=requests[1].payload
assert(#broadcast.attachments==6 and not broadcast.targetUid)
assert(broadcast.attachments[1].currency=='gold' and broadcast.attachments[2].currency=='fragments')
assert(broadcast.attachments[3].kind=='equipment')
local ids={}; for _,a in ipairs(broadcast.attachments) do if a.itemId then ids[a.itemId]=true end end
assert(ids.wish_ticket and ids.abyss_ticket)
pending({ok=false,reason='timeout'})
assert(find(root,'text','待发送附件（6/6）'),'failure retains the reviewed draft')
input('个人邮件目标玩家编号（全服发送无需填写）','162878756')
click('发送个人邮件')
assert(#requests==2 and requests[2].payload.targetUid=='162878756')
local TableUtils=require('server.domain.TableUtils')
assert(TableUtils.DeepEqual(broadcast.attachments,requests[2].payload.attachments),'both targets use identical attachments')
assert(broadcast.title==requests[2].payload.title and broadcast.expireDays==requests[2].payload.expireDays)
pending({ok=true,data={action='send_mail',status='queued',mailId='gm-mail:stable-id'}})
assert(find(root,'text','待发送附件（0/6）') and lastToast:find('待派发队列') and lastToast:find('gm%-mail:stable%-id'))
Admin.HandleResult({ok=true,action='send_mail',status='applied'},refresh)
assert(lastToast=='个人邮件已投递')
readOnly=true; refresh(); click('发送全服邮件'); assert(#requests==2)
readOnly=false; refresh()
addCurrency('gold',1.5); assert(find(root,'text','待发送附件（0/6）'))
click('发送全服邮件'); assert(#requests[3].payload.attachments==0,'text-only notices remain supported')
pending({ok=true})
-- Server handlers keep the same attachment schema and administrator authorization.
local defs={}
require('server.commands.AdminCommands').Register({Register=function(_,d) defs[d.name]=d end},{})
assert(defs['Admin.SendMail'].auth=='admin' and defs['Admin.SendBroadcastMail'].auth=='admin')
assert(defs['Admin.SendMail'].schema.fields.attachments==defs['Admin.SendBroadcastMail'].schema.fields.attachments)
-- Actual claiming changes the authoritative count; duplicate claims never issue currency twice.
local Engine=require('server.domain.MailEngine')
local state=require('server.domain.StateFactory').Create(1791520000)
local mail=Engine.Create(state,{type='reward',title='test',body='test',attachments=broadcast.attachments},1791520000)
local extra=Engine.Create(state,{type='reward',title='extra',body='extra',attachments={{kind='currency',currency='gold',count=1}}},1791520000)
assert(Engine.Summary(state).unread==2)
local proposal=Engine.Claim(state,mail.id,1791520001)
assert(proposal.ok and Engine.AllClaimed(Engine.Find(proposal.state.mails,mail.id)))
assert(Engine.Summary(proposal.state).unread==1)
local repeatClaim=Engine.Claim(proposal.state,mail.id,1791520002)
assert(TableUtils.DeepEqual(proposal.state.gold,repeatClaim.state.gold))
local all=Engine.ClaimAll(proposal.state,1791520003)
assert(all.ok and Engine.Summary(all.state).unread==0)
local function text(value,_,_,props) props=props or {}; props.text=value; return widget(props) end
package.loaded['client.Theme']={Colors=setmetatable({},{__index=function() return {255,255,255,255} end}),CONFIG={DesignW=1080,Title='test'}}
package.loaded['client.ViewKit']={Txt=text,CompactTxt=text,MultiTxt=text,FormatInt=tostring,FormatPercent=tostring}
for _,name in ipairs({'CommonPromptDialog','LeaderboardController','MailController','StoryBrowserController','CampaignView'}) do
    package.loaded['client.'..name]={}
end
package.loaded['client.DailyVipView']={HomeEntry=function() return widget() end}
package.loaded['client.QuestController']={CountClaimable=function() return 0 end}
package.loaded['client.ActivityController']={HasRedDot=function() return false end}
local Home=require('client.HomeView')
local game={stats={atk=1,def=1,crit=0,atkSpeed=1,hp=10},hp=10,mailSummary=Engine.Summary(state)}
local home=Home.Build({game=game})
local badge=assert(find(home:GetRoot(),'id','homeMailBadge'))
assert(badge.children[1].props.text=='2')
game.mailSummary=Engine.Summary(proposal.state); home:Update(game)
assert(badge.children[1].props.text=='1' and badge.props.visible~=false)
game.mailSummary=Engine.Summary(all.state); home:Update(game)
assert(badge.props.visible==false and find(home:GetRoot(),'id','homeMailBadge')==badge,'claim hides badge without rebuilding homepage')
game.mailSummary={unread=101}; home:Update(game)
assert(badge.props.visible==true and badge.children[1].props.text=='99+')
game.mailSummary={unread=0}; home:Update(game)
home:Destroy()
home=Home.Build({game=game}); badge=assert(find(home:GetRoot(),'id','homeMailBadge'))
assert(badge.props.visible==false)
game.mailSummary={unread=1}; home:Update(game); assert(badge.props.visible==true)
print('mail_attachments_badge: PASS (shared composer, all rows, 6 attachments, authorization, retry, claims, cached badge)')
