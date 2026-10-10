local sent, dialogs, notices, view = {}, {}, {}, { readOnly = false }
package.loaded["urhox-libs/UI"] = { Toast = { Show = function(message) notices[#notices + 1] = message end } }
package.loaded["client.GameStateAdapter"] = { GetViewState = function() return view end }
package.loaded["client.CommonPromptDialog"] = { Show = function(options) dialogs[#dialogs + 1] = options end }
package.loaded["client.ServerClient"] = {
    RecycleWishJar = function(id, count, callback)
        sent[#sent + 1] = { id = id, count = count, callback = callback }
        return "request:" .. #sent
    end,
}
local Controller = require("client.WishPoolController")
local jarId = "jar.random.lv40"
assert(Controller.RecycleJar(jarId, 2) and #sent == 0)
Controller.ResetConnection()
dialogs[#dialogs].onConfirm()
assert(#sent == 0, "a dialog from the disconnected session must not send a new request")
assert(Controller.RecycleJar(jarId, 2))
view.readOnly = true
dialogs[#dialogs].onConfirm()
assert(#sent == 0, "confirm must recheck connection readiness")
view.readOnly = false
assert(Controller.RecycleJar(jarId, 2))
dialogs[#dialogs].onConfirm()
assert(#sent == 1 and sent[1].count == 2 and Controller.IsBusy())
assert(not Controller.RecycleJar(jarId, 1))
Controller.ResetConnection()
assert(Controller.RecycleJar(jarId, 1))
dialogs[#dialogs].onConfirm()
assert(#sent == 2 and Controller.IsBusy())
sent[1].callback({ ok = true })
assert(Controller.IsBusy(), "late callback must not clear the reconnected session's request")
sent[2].callback({ ok = false, reason = "stock changed" })
assert(not Controller.IsBusy())
assert(not Controller.RecycleJar("jar.random.lv6", 1))
print("wish_jar_controller: PASS (confirmation, reconnect, late callback and request isolation)")
