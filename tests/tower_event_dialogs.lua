local D = require('client.DialogCoordinator')
local game, requests, snapshots, errors = {}, {}, {}, 0
package.loaded['client.GameStateAdapter'] = { GetViewState = function() return game end }
package.loaded['client.CommonPromptDialog'] = {Show = function(options) return D.Enqueue(options) end}
package.loaded['client.ServerClient'] = {
    ResolveEvent = function(id, action, callback) requests[#requests + 1] = {id = id, action = action, callback = callback} end,
    RequestSnapshot = function(callback) snapshots[#snapshots + 1] = callback end,
}
D.Configure {present = function() end, dismiss = function() end}
local C = require('client.GameplayDialogsController')
C.Configure {actionResult = function() errors = errors + 1 end}
local function start(kind, action)
    game.pendingEvent = {eventId = 'ev.' .. tostring(#requests + 1), eventType = kind, expiresAt = os.time() + 60, actions = {action, 'skip'}}
    C.SyncPendingEvent(game.pendingEvent)
    assert(D.GetState().active.queueKey == 'event:' .. game.pendingEvent.eventId)
end
for _, spec in ipairs({{'chest', 'open'}, {'merchant', 'buy'}, {'randomEvent', 'accept'}}) do
    for _, skip in ipairs({false, true}) do
        start(spec[1], spec[2])
        if skip then D.CancelActive() else D.ConfirmActive() end
        assert(requests[#requests].action == (skip and 'skip' or spec[2]))
        local before = #requests
        C.ShowPendingEvent(game.pendingEvent)
        assert(#requests == before and D.GetState().active.showConfirm == false)
        game.pendingEvent = nil
        C.SyncPendingEvent(nil)
        requests[#requests].callback({ok = true})
        assert(not D.GetState().active and D.GetState().queued == 0, 'authoritative resolution closes without sending a second decision')
        assert(#requests == before)
    end
end
start('randomEvent', 'accept'); D.ConfirmActive()
requests[#requests].callback({ok = false, reason = 'timeout'})
assert(errors == 1 and D.GetState().active.confirmText == '接受', 'failure restores retry/skip choices')
D.CancelActive()
requests[#requests].callback({ok = true})
assert(#snapshots == 1 and D.GetState().active.showConfirm == false, 'lost delta must trigger state sync')
snapshots[1]({ok = false})
assert(errors == 2 and D.GetState().active.cancelText == '跳过', 'snapshot timeout releases busy state')
local before = #requests
game.pendingEvent = nil; C.SyncPendingEvent(nil)
assert(#requests == before and not D.GetState().active, 'server timeout silently removes obsolete dialog')
start('randomEvent', 'accept'); D.ConfirmActive()
local old = requests[#requests].callback
C.Reset(); old({ok = false})
assert(not D.GetState().active and errors == 2, 'emergency reset ignores stale callbacks')
print('tower_event_dialogs: PASS')
