local game={page='home',connectionState='ready',tutorial={completed=true},pendingOfflineSeconds=900,floor=1}
local D=require('client.DialogCoordinator')
D.Configure({present=function() end,dismiss=function() end})
package.loaded['urhox-libs/UI']={Toast={Show=function() end}}
package.loaded['client.GameStateAdapter']={GetViewState=function() return game end}
package.loaded['client.CommonPromptDialog']={Show=function(opts) return D.Enqueue(opts) end}
package.loaded['client.LoadingController']={IsActive=function() return false end}
local previewCallback,claimCallback,previews,claims=nil,nil,0,0
package.loaded['client.ServerClient']={
    PreviewOffline=function(cb) previews=previews+1;previewCallback=cb end,
    CollectOffline=function(_,cb) claims=claims+1;claimCallback=cb end,
    RequestSnapshot=function() end}
package.loaded['client.OfflineClaimView']={
    ShowLoading=function(key) return D.Enqueue({queueKey=key}) end,
    ShowPreview=function(token,preview,floor,claim,cancel)
        local key='preview:'..token
        return D.Enqueue({queueKey=key,onConfirm=claim,onCancel=cancel}),key
    end,
    BuildRewardOptions=function(reward,floor,complete) return {queueKey='offline:reward',onConfirm=complete} end}
local C=require('client.OfflineClaimController')
C.Configure({showActionResult=function(r) return r and r.ok end})
C.Update(1);assert(D.GetState().active.queueKey=='offline_login_guide')
D.ConfirmActive();assert(previews==1)
C.Collect();assert(previews==1,'in-flight preview prevents duplicate requests')
previewCallback({ok=false,reason='network timeout'})
assert(not D.GetState().active and not C.IsLoginFlowPending())
C.Update(4);assert(not D.GetState().active)
C.Update(1);assert(D.GetState().active)
D.ConfirmActive();previewCallback({ok=true,data={quoteToken='q1',preview={gold=1}}})
D.CancelActive();assert(not C.IsLoginFlowPending())
C.Update(60);assert(not D.GetState().active,'intentional dismissal does not immediately re-prompt')
C.Collect();previewCallback({ok=true,data={quoteToken='q1',preview={gold=1}}})
D.ConfirmActive();assert(claims==1 and D.GetState().reservations==1)
claimCallback({ok=false,reason='timeout'});assert(D.GetState().reservations==0)
C.Reset();D.Clear(false)
D.SetBlocked(true);C.Update(1);assert(not D.GetState().active)
D.SetBlocked(false);C.Update(1);assert(D.GetState().active,'rejected guide remains eligible')
D.CancelActive();C.Reset();D.Clear(false)
game.pendingOfflineSeconds=899;C.Update(1);assert(not D.GetState().active)
game.pendingOfflineSeconds=900;C.Update(1);assert(D.GetState().active)
D.ConfirmActive();local old=previewCallback
C.Reset();D.Clear(false);old({ok=true,data={quoteToken='stale',preview={}}})
assert(not D.GetState().active,'stale callback cannot recreate overlay after recovery')
print('offline_recovery: PASS')
