local Big = require('shared.BigNumber')
local Large = require('shared.LargeNumber')
local Factory = require('server.domain.StateFactory')
local Engine = require('server.domain.RewardClaimEngine')
local StateSchema = require('shared.GameStateSchema')
local EventSchema = require('shared.GameEventSchema')
local state = Factory.Create(os.time())
local offer1 = Engine.CreateAdOffer(state, { source = 'campaign', sourceKey = 'campaign:first:main:c01:c', baseReward = { gold = Large.FromNumber(100) } })
local offer2 = Engine.CreateAdOffer(state, { source = 'floor_milestone', sourceKey = 'floor:50', baseReward = { fragments = 20 } })
local before = Large.Normalize(state.gold)
assert(not Engine.ClaimAdExtras(state, { offer1.id, 'missing' }).ok)
assert(not Engine.ClaimAdExtras(state, { offer1.id, offer1.id }).ok)
assert(#state.rewardClaims.pending == 2 and Large.Compare(state.gold, before) == 0)
local result = Engine.ClaimAdExtras(state, { offer1.id, offer2.id })
assert(result.ok and #result.state.rewardClaims.pending == 0)
assert(Large.Compare(result.state.gold, Large.Add(before, 400)) == 0, 'only extra 4x is paid')
local replay = Engine.ClaimAdExtras(result.state, { offer1.id, offer2.id }); assert(replay.ok and Large.Compare(replay.state.gold, result.state.gold) == 0, 'receipt retries cannot pay twice')
local valid, reason = StateSchema.ValidateState(result.state); assert(valid, reason)
local receipts = {}
for _, event in ipairs(result.delta.events) do
    event.type = event.kind
    local ok, why = EventSchema.Validate(event); assert(ok, why)
    if event.kind == 'reward_ad_extra_claimed' then receipts[#receipts + 1] = event end
end
assert(#receipts == 2 and Large.Compare(receipts[1].totalReward.gold, 500) == 0)

-- Actual feedback, reward view, coordinator and ad wrapper; only UI/SDK/network ports are fakes.
package.loaded['urhox-libs/UI'] = { Toast = { Show = function() end }, Panel = function(p) return p end }
package.loaded['client.Theme'] = { Colors = {}, CONFIG = {} }
package.loaded['client.ViewAssets'] = { ASSETS = { items = { gold = 'gold', crystal = 'crystal' } } }
package.loaded['client.ViewKit'] = { FormatInt = function(value)
    if Large.IsLargeNumber(value) then value = Large.ToBigNumber(value) end
    return tostring(math.floor(Big.ToNumber(value) + 0.5))
end }
package.loaded['client.ItemView'] = { GetItemById = function() end, ItemImage = function() return 'equipment' end }
local builtCards = {}
package.loaded['client.BackpackItemSlot'] = { Build = function(_, item, options)
    builtCards[item.name] = options.amountText
    return { item = item, options = options }
end }
package.loaded['client.HorizontalArrowScroller'] = {}
package.loaded['client.AudioController'] = {}
package.loaded['client.GameStateAdapter'] = { GetViewState = function() return { autoRun = true, rewardClaims = state.rewardClaims } end }
package.loaded['client.AdGiftController'] = { HandleDelta = function() end, Reset = function() end }
local returned = 0
package.loaded['client.CampaignView'] = { GetRewardReturnHandler = function() return function() returned = returned + 1 end end }
local pending, requests, adCallback, ads = nil, 0, nil, 0
package.loaded['client.ServerClient'] = { ClaimRewardAdExtras = function(ids, callback)
    requests = requests + 1; assert(#ids == 2); pending = callback
end }
_G.sdk = { ShowRewardVideoAd = function(_, callback) ads = ads + 1; adCallback = callback; return true end }
local Coordinator = require('client.DialogCoordinator')
Coordinator.Configure { present = function() end, dismiss = function() end }
package.loaded['client.CommonPromptDialog'] = { Show = function(options) return Coordinator.Enqueue(options) end }
local Claim = require('client.RewardClaimController')
local Feedback = require('client.RewardFeedbackController')
local function Payload(revision)
    return { revision = revision, events = {
        { kind = 'campaign_stage_completed', stageId = 'main:c01:b', firstClear = true, reward = { gold = 50 } },
        { kind = 'activity_signed', reward = { gold = Large.FromNumber(100) } },
        { kind = 'level_milestone_reward', reward = { fragments = 20 } },
        { kind = 'reward_offer_pending', rewardId = offer1.id, source = 'signin', baseReward = offer1.baseReward },
        { kind = 'reward_offer_pending', rewardId = offer2.id, source = 'level_milestone', baseReward = offer2.baseReward },
    } }
end
local function Reset()
    Feedback.Reset(); Coordinator.Clear(false); require('client.RewardVideo').Reset()
    returned, requests, ads, pending = 0, 0, 0, nil
    Feedback.SyncSnapshot()
end
local function Present()
    local payload = Payload(1)
    Feedback.AccumulateDelta(payload); Feedback.PresentDelta(payload)
    local dialog = Coordinator.GetState()
    assert(dialog.active and dialog.queued == 0 and dialog.active.zIndex == 3700)
    assert(dialog.active.confirmText == '看广告 · 五倍' and dialog.active.cancelText == '领取并返回章节')
    assert(not Feedback.ShowIdleSummary(), 'same rewards cannot also enter idle summary')
    return payload
end
Reset()
local original = Present()
Coordinator.CancelActive()
assert(returned == 1 and ads == 0 and requests == 0 and not Coordinator.GetState().active)
Feedback.SyncSnapshot(); Feedback.PresentDelta(original)
assert(not Coordinator.GetState().active, 'declining must not resurrect a separate reward or ad dialog')

Reset(); Present(); Coordinator.ConfirmActive()
assert(ads == 1 and requests == 0 and not Coordinator.GetState().active)
adCallback({ success = true }); adCallback({ success = true })
assert(requests == 1)
-- Server delta arrives first; its result belongs to the originating dialog.
Feedback.PresentDelta(result.delta)
assert(not Coordinator.GetState().active and Coordinator.GetState().queued == 0)
pending({ ok = true, data = { rewards = receipts } })
local final = assert(Coordinator.GetState().active)
assert(final.title == '五倍奖励结算' and final.zIndex == 3700 and not final.cancelText)
assert(Coordinator.GetState().queued == 0 and returned == 0)
assert(builtCards['金币'] == '+550' and builtCards['碎片'] == '+100', '5x eligible reward plus unchanged chapter reward')
Coordinator.ConfirmActive()
assert(returned == 1)
Feedback.PresentDelta(result.delta)
assert(not Coordinator.GetState().active, 'late duplicate receipt must not show another reward')

Reset(); Present(); Coordinator.ConfirmActive()
adCallback({ success = false, msg = 'embed manual close' })
assert(requests == 0 and Coordinator.GetState().active.confirmText == '看广告 · 五倍')
Coordinator.CancelActive(); assert(returned == 1)

Reset(); Present(); Coordinator.ConfirmActive(); adCallback({ success = true })
pending({ ok = false, reason = 'network timeout' })
assert(Coordinator.GetState().active.confirmText == '重试领取五倍')
Coordinator.ConfirmActive()
assert(ads == 1 and requests == 2, 'settlement retry must not replay the ad')
-- Response arrives before delta; still exactly one result.
pending({ ok = true, data = { rewards = receipts } })
Feedback.PresentDelta(result.delta)
assert(Coordinator.GetState().queued == 0)
Coordinator.ConfirmActive(); assert(returned == 1)

Reset(); Present(); Coordinator.ConfirmActive()
Claim.Update(181)
assert(Coordinator.GetState().active, 'ad timeout must restore an actionable reward popup')
Coordinator.CancelActive(); assert(returned == 1 and requests == 0)

-- Every existing online offer source uses the same one-dialog path.
for _, source in ipairs({ 'signin', 'task', 'level_milestone', 'floor_milestone', 'abyss_settlement', 'campaign' }) do
    Reset()
    local payload = { revision = 12, events = {
        { kind = 'activity_signed', reward = { gold = Large.FromNumber(100) } },
        { kind = 'reward_offer_pending', rewardId = offer1.id, source = source, baseReward = offer1.baseReward },
    } }
    Feedback.PresentDelta(payload)
    assert(Coordinator.GetState().active.confirmText == '看广告 · 五倍' and Coordinator.GetState().queued == 0)
    Coordinator.CancelActive(); Feedback.SyncSnapshot()
    assert(not Coordinator.GetState().active)
end

-- Offline rewards already own a reserved result dialog. Merge concurrent level
-- rewards into that dialog instead of opening an independent ad prompt.
Reset()
package.loaded['shared.ItemSort'] = { Sort = function(items) return items end }
local offline = require('client.OfflineClaimView')
local offlineEvents = { events = {
    { kind = 'offline_collected', gold = 50 },
    { kind = 'level_milestone_reward', reward = { fragments = 20 } },
    { kind = 'reward_offer_pending', rewardId = offer2.id, source = 'level_milestone', baseReward = offer2.baseReward },
} }
Feedback.PresentDelta(offlineEvents)
assert(not Coordinator.GetState().active)
package.loaded['client.ViewKit'].FormatDuration = function() return '1h' end
local realDescribe = require('client.RewardDialogView').DescribeCard
require('client.RewardDialogView').DescribeCard = function(icon, name, amount, rarity, item)
    builtCards[name] = amount
    return realDescribe(icon, name, amount, rarity, item)
end
local reservation = Coordinator.ReserveNext()
local options = offline.BuildRewardOptions({ gold = Large.FromNumber(50), exp = 1, fragments = 2 }, 1, function() returned = returned + 1 end)
assert(builtCards['碎片'] == '+22')
assert(Coordinator.EnqueueReserved(reservation, options))
assert(Coordinator.GetState().active.confirmText == '看广告 · 五倍' and Coordinator.GetState().queued == 0)
Coordinator.CancelActive(); assert(returned == 1)
print('reward_dialog_flow: PASS')
