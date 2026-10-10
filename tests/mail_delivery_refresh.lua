-- Exercise the actual mailbox across delayed delivery and closing/reopening.
local function widget(props)
    local w={props=props or {},children={}}
    function w:AddChild(c) self.children[#self.children+1]=c; c.parent=self end
    function w:RemoveChild(c) for i,v in ipairs(self.children) do if v==c then table.remove(self.children,i); return end end end
    for _,c in ipairs(w.props.children or {}) do w:AddChild(c) end
    return w
end
local function find(w,text)
    if w.props.text==text then return w end
    for _,c in ipairs(w.children) do local f=find(c,text); if f then return f end end
end
local UI={Panel=widget,Label=widget,Button=widget,ScrollView=widget,Toast={Show=function() end}}
package.loaded['urhox-libs/UI']=UI
local function text(value,_,_,props) props=props or {}; props.text=value; return widget(props) end
package.loaded['client.Theme']={Colors=setmetatable({},{__index=function() return {255,255,255,255} end})}
package.loaded['client.ViewAssets']={ASSETS={ui={}}}
package.loaded['client.ViewKit']={Txt=text,CompactTxt=text,MultiTxt=text,FormatInt=tostring}
package.loaded['client.UI.DialogSettingsAccess']={Attach=function() end}
local summary={total=0,unread=0,unclaimed=0}
package.loaded['client.GameStateAdapter']={GetViewState=function() return {mailSummary=summary} end}
local requests,callbacks=0,{}
package.loaded['client.ServerClient']={MailList=function(_,cb) requests=requests+1; callbacks[requests]=cb end}
local dataUpdates=0
package.loaded['client.UI.GridVirtualList']={Build=function(options)
    local w=widget(options.widgetProps)
    w.scrollView_=widget()
    if #options.data==0 then w:AddChild(options.emptyState()) else w:AddChild(widget{text='delivered'}) end
    return w
end,UpdateData=function(_,data) dataUpdates=dataUpdates+1; assert(#data==1) end}
local View=require('client.MailView')
local root=widget(); View.AttachRoot(root)
View.Show(); callbacks[1]({ok=true,data={items={},deliveryPending=true}})
assert(find(root,'邮件正在同步，将自动重试'))
View.Update(5); assert(requests==2)
View.Update(10); assert(requests==2,'an in-flight refresh cannot issue duplicate requests')
summary={total=1,unread=1,unclaimed=1}
callbacks[2]({ok=true,data={items={{mailId='mail-1'}},deliveryPending=false}})
assert(find(root,'delivered'))
View.Update(20); assert(requests==2,'unchanged visible mailbox must not continuously query cloud')
summary={total=2,unread=2,unclaimed=1}
View.Update(5); assert(requests==3)
View.Hide(); callbacks[3]({ok=true,data={items={},deliveryPending=true}})
View.Update(20); assert(requests==3 and #root.children==0,'closing drops late callbacks and stops retries')
View.Show(); View.Reset(); callbacks[4]({ok=true,data={items={}}})
assert(#root.children==0,'old-session list callback cannot reopen the mailbox')
print('mail_delivery_refresh: PASS')
