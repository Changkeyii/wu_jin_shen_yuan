local game = {page = 'home', tutorial = {completed = true}, autoRun = false}
local starts, clears = 0, 0
package.loaded['urhox-libs/UI'] = {}
package.loaded['client.Theme'] = {CONFIG = {}, Colors = {}}
package.loaded['client.GameStateAdapter'] = {
    GetViewState = function() return game end, SetPage = function(page) game.page = page end,
}
package.loaded['client.LoadingController'] = {EnsurePlayAssetsReady = function(callback) callback() end,
    EnsurePageAssetsReady = function(_, callback) if callback then callback() end end}
package.loaded['client.PlayPresentation'] = {
    SetAutoRun = function(enabled) assert(enabled); starts = starts + 1 end,
    ClearCombatPresentation = function() clears = clears + 1 end,
}
package.loaded['client.AudioController'] = {SetPage = function() end}
package.loaded['client.ItemTips'] = {Hide = function() end}
package.loaded['client.ItemView'] = {}
package.loaded['client.ViewAssets'] = {ASSETS = {}, LAYOUT = {}}
package.loaded['client.ViewKit'] = {}
local N = require('client.NavigationController')
N.Configure {refreshPage = function() end, isIdleRewardTracking = function() return false end}
assert(N.SwitchPage('play') and starts == 1)
N.SwitchPage('play'); N.OnReady(); assert(starts == 1, 'same page / later snapshots cannot restart a manual pause')
N.SwitchPage('home'); N.SwitchPage('play'); assert(starts == 2 and clears == 1)
N.SwitchPage('home'); game.autoRun = true; N.SwitchPage('play'); assert(starts == 2, 'already running does not resend')
N.SwitchPage('home'); game.autoRun = false; game.readOnly = true
N.SwitchPage('play'); assert(starts == 2)
game.readOnly = false; N.OnReady(); N.OnReady(); assert(starts == 3, 'deferred entry starts once after connection ready')
N.SwitchPage('home'); game.readOnly = true; N.SwitchPage('play'); N.SwitchPage('home')
game.readOnly = false; N.OnReady(); assert(starts == 3, 'leaving cancels deferred start')
game.tutorial.completed = false
N.SwitchPage('play', {tutorial = true}); assert(starts == 3, 'tutorial owns prologue start')
N.Reset()
game.page, game.tutorial.completed, game.readOnly, game.autoRun = 'home', true, false, false
local queued = {}
local Loader = package.loaded['client.LoadingController']
Loader.EnsurePlayAssetsReady = function(callback) queued[#queued + 1] = callback end
Loader.EnsurePageAssetsReady = function(_, callback) if callback then queued[#queued + 1] = callback end end
N.Configure {refreshPage = function() end, isIdleRewardTracking = function() return false end}
local before = starts
N.SwitchPage('play'); assert(game.page == 'home' and starts == before)
N.SwitchPage('home'); queued[1](); queued[2]()
assert(game.page == 'home' and starts == before, 'late page completion must not leave the requested homepage')
queued = {}
game.tutorial.completed = false
local guideStarted = false
N.SwitchPage('play', {tutorial = true, onReady = function() guideStarted = true end})
assert(not guideStarted and starts == before)
queued[1]()
assert(guideStarted and game.page == 'play' and starts == before, 'tutorial starts only after page readiness')
print('tower_entry: PASS')
