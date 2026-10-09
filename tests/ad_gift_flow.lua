local Engine = require("server.domain.AdGiftEngine")
local Factory = require("server.domain.StateFactory")
local Large = require("shared.LargeNumber")
local now = 1791450000
local state = Factory.Create(now)
state.page = "home"
package.loaded["client.LoadingController"] = { IsActive = function() return false end }
package.loaded["client.CampaignView"] = { IsOpen = function() return false end }
package.loaded["client.IdleSettingsView"] = { IsOpen = function() return false end }
package.loaded["client.OfflineClaimController"] = { IsLoginFlowPending = function() return false end }
state.tutorial = { completed = true, step = 6 }
local dialog, sdkCallback
local plays, claims, prepares = 0, 0, 0
local loseResponse = false
package.loaded["urhox-libs/UI"] = { Toast = { Show = function() end } }
package.loaded["client.GameStateAdapter"] = { GetViewState = function() return state end }
package.loaded["client.DialogCoordinator"] = {
    HasKey = function(key) return dialog ~= nil and (key == "ad_gift_dialog" or key == "ad_gift_menu") end,
    GetState = function() return { active = dialog, queued = 0 } end,
}
package.loaded["client.AdGiftView"] = {
    Reward = function(quote, options) dialog = { quote = quote, options = options }; return true end,
    Menu = function(offers, select) dialog = { offers = offers, select = select }; return true end,
}
package.loaded["client.ServerClient"] = {
    ListAdGifts = function(cb) cb({ ok = true, data = { offers = Engine.List(state) } }) end,
    PrepareAdGift = function(kind, cb)
        prepares = prepares + 1
        local p = Engine.Prepare(state, kind, now)
        if not p.ok then cb({ ok = false }); return end
        state = p.state
        cb({ ok = true, data = { quote = state.rewardClaims.gifts.quote } })
    end,
    ClaimAdGift = function(token, cb)
        claims = claims + 1
        local p = Engine.Claim(state, token, now)
        if p.ok then state = p.state end
        if loseResponse then loseResponse = false; cb({ ok = false, reason = "timeout" }); return end
        cb({ ok = p.ok, data = { lastClaim = state.rewardClaims.gifts.lastClaim } })
    end,
}
_G.sdk = { ShowRewardVideoAd = function(_, cb) plays = plays + 1; sdkCallback = cb; return true end }
local Controller = require("client.AdGiftController")
local function click()
    local options = assert(dialog).options
    dialog = nil
    if options.onConfirm then options.onConfirm() end
end
local function cancel()
    local options = assert(dialog).options
    dialog = nil
    if options and options.onCancel then options.onCancel() end
end
Controller.Show("forge")
local before = state.gold
cancel()
assert(plays == 0 and claims == 0 and Large.Compare(before, state.gold) == 0)
Controller.Show("forge")
click()
assert(plays == 1 and claims == 0)
sdkCallback({ success = false, msg = "embed manual close" })
assert(claims == 0 and Large.Compare(before, state.gold) == 0)
cancel()
Controller.Show("forge")
local reward = dialog.quote.reward.gold
click()
local oldCallback = sdkCallback
sdkCallback({ success = true })
oldCallback({ success = true })
assert(claims == 1 and Large.Compare(state.gold, Large.Add(before, reward)) == 0)
assert(dialog.options.confirmText == "完成")
cancel()
dialog = nil
Controller.Show("forge")
assert(dialog.options.confirmText == nil, "continue must show a new optional video offer")
loseResponse = true
click()
sdkCallback({ success = true })
local afterCommitted = state.gold
assert(dialog.options.confirmText == "重试领取")
local playsBeforeRetry = plays
click()
assert(plays == playsBeforeRetry and claims == 3, "retry settlement must not replay an ad")
assert(Large.Compare(state.gold, afterCommitted) == 0, "lost response replay must not duplicate rewards")
cancel()

dialog = nil
state.page = "home"
-- Each event is prompted once; no frame-by-frame loop after closing.
Engine.OnDecompose(state, 20, {})
Controller.HandleDelta({ events = { { kind = "ad_gift_available", giftKind = "recycle" } } })
Controller.Update()
assert(dialog.quote.kind == "recycle")
local preparesBefore = prepares
cancel()
for _ = 1, 10 do Controller.Update() end
assert(not dialog and prepares == preparesBefore)
Controller.Open()
assert(dialog.offers.forge and dialog.offers.recycle)
dialog = nil
state.tutorial.completed = false
Controller.HandleDelta({ events = { { kind = "ad_gift_available", giftKind = "forge" } } })
Controller.Update()
assert(not dialog and not Controller.Open())
Controller.Reset()
state.tutorial.completed = true
dialog = nil
Controller.Show("forge"); click()
local recoveryCallback, beforeRecoveryClaims = sdkCallback, claims
Controller.Recover()
require("client.RewardVideo").Cancel()
recoveryCallback({ success = true })
assert(not dialog and claims == beforeRecoveryClaims, "recovery invalidates callbacks before canceling SDK wait")
Controller.Show("forge"); click()
loseResponse = true
sdkCallback({ success = true })
local recoveryBalance, recoveryPlays = state.gold, plays
Controller.Recover(); dialog = nil
Controller.Open()
assert(dialog.options.confirmText == "重试领取", "confirmed advertisement survives emergency recovery")
click()
assert(plays == recoveryPlays and Large.Compare(state.gold, recoveryBalance) == 0)
Controller.Reset()
dialog = nil
local ticketStart = state.wishPool.tickets
Controller.Show("wishSupply"); click()
sdkCallback({ success = false, msg = "embed manual close" })
assert(state.wishPool.tickets == ticketStart and state.rewardClaims.gifts.wishUsed == 0)
cancel()
Controller.Show("wishSupply"); click()
loseResponse = true
local ticketCallback = sdkCallback
sdkCallback({ success = true }); ticketCallback({ success = true })
assert(state.wishPool.tickets == ticketStart + 1 and state.rewardClaims.gifts.wishUsed == 1)
assert(dialog.options.confirmText == "重试领取")
local beforeTicketRetry = plays
click()
assert(plays == beforeTicketRetry and state.wishPool.tickets == ticketStart + 1)
dialog = nil
state.floor, state.maxFloor = 10, 10
Engine.OnBossVictory(state, 100, {})
Controller.Show("lucky"); click(); sdkCallback({ success = true })
assert(state.wishPool.tickets == ticketStart + 3)
assert(state.rewardClaims.gifts.wishUsed == 1, "lucky has its own opportunity balance")
Controller.Reset()
print("ad_gift_flow: PASS")
