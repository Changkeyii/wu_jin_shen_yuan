local game = { page = 'home', isAdmin = true }
local opened, hidden, lastToast = 0, 0, nil
package.loaded['urhox-libs/UI'] = { Toast = { Show = function(message) lastToast = message end } }
package.loaded['client.GameStateAdapter'] = { GetViewState = function() return game end }
package.loaded['client.MailView'] = { Hide = function() hidden = hidden + 1 end }
package.loaded['client.NavigationController'] = { SwitchPage = function(page)
    assert(page == 'admin'); opened = opened + 1; game.page = page
end }
local M = require('client.MailController')
local function taps(n)
    for _ = 1, n do M.OnHomeTitleClick(); M.Update(0.1) end
end
local function reset(admin)
    M.Reset(); game.page = 'home'; game.isAdmin = admin
    opened, hidden, lastToast = 0, 0, nil
end
taps(7); assert(opened == 0)
taps(1); assert(opened == 1 and hidden == 1 and game.page == 'admin')
taps(8); assert(opened == 1, 'other pages cannot trigger the entry')
reset(true)
taps(7); M.Update(2.1); taps(1); assert(opened == 0, 'long gaps reset the sequence')
taps(7); assert(opened == 1)
reset(true)
taps(7); game.page = 'bag'; M.Update(0); game.page = 'home'; taps(1)
assert(opened == 0, 'leaving home clears partial sequences')
reset(false)
taps(8); assert(opened == 0 and hidden == 0 and lastToast == '无管理员权限')
reset(true)
taps(7); game.isAdmin = false; taps(1)
assert(opened == 0, 'authorization is checked at activation, not the first tap')
reset(true)
taps(7); M.Reset(); taps(1); assert(opened == 0, 'recovery clears partial sequences')
reset(true)
M.SetPressing(true); M.Update(5)
assert(opened == 1 and M.WasLongPressed(), 'existing long-press entry still works')
local AdminPolicy = require('server.core.AdminPolicy')
local policy = AdminPolicy.New({ adminUserIds = {1379670410, 162525390, 162878756} })
assert(policy:Authorize(1379670410, 'admin') and policy:Authorize(162525390, 'admin'))
assert(policy:Authorize(162878756, 'admin'))
assert(not policy:Authorize(123, 'admin'))
print('gm_title_entry: PASS')
