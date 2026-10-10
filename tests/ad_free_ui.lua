local root, toast
local function widget(props)
    local w={props=props or {},children={}}
    function w:AddChild(c) self.children[#self.children+1]=c; c.parent=self end
    for _,c in ipairs(w.props.children or {}) do w:AddChild(c) end
    return w
end
local function find(w,text)
    if w.props.text==text then return w end
    for _,c in ipairs(w.children) do local result=find(c,text); if result then return result end end
end
local UI={Panel=widget,Label=widget,TextField=widget,Dropdown=widget,Button=widget,Checkbox=widget,
    ScrollView=widget,Alert=widget,Toast={Show=function(text) toast=text end}}
package.loaded['urhox-libs/UI']=UI
local requests={}
package.loaded['client.ServerClient']={AdminSetAdFree=function(uid,enabled,reason,cb)
    requests[#requests+1]={uid=uid,enabled=enabled,reason=reason}
    cb({ok=true,data={action='set_ad_free',status='queued'}})
end}
local Panel=require('client.AdminPanel')
local readOnly=false
local refresh
refresh=function() root=Panel.Build(UI,{readOnly=readOnly,onChanged=refresh}) end
local function click(text) assert(find(root,text),text).props.onClick() end
local function input(label,value)
    local field=assert(find(root,label)).parent.children[2]; field.props.onChange(field,value)
end
refresh(); click('发放免广告卡'); assert(#requests==0 and toast:find('编号'))
input('目标玩家编号','2002'); click('发放免广告卡'); assert(#requests==0 and toast:find('原因'))
input('身份修改原因','运营发放'); click('发放免广告卡')
assert(#requests==1 and requests[1].uid=='2002' and requests[1].enabled==true and requests[1].reason=='运营发放')
assert(toast:find('上线或同步'))
click('收回免广告卡'); assert(#requests==2 and requests[2].enabled==false)
readOnly=true; refresh(); click('发放免广告卡'); click('收回免广告卡'); assert(#requests==2)
Panel.HandleResult({ok=true,action='set_ad_free',status='applied'},refresh)
assert(toast=='免广告身份已更新')
print('ad_free_ui: PASS')
