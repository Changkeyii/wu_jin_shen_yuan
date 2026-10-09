local Factory = require('server.domain.StateFactory')
local Engine = require('server.domain.CampaignEngine')
local Catalog = require('shared.CampaignCatalog')
local Large = require('shared.LargeNumber')
local Schema = require('shared.GameEventSchema')
local now = os.time()
local state = Factory.Create(now)
state.tutorial.completed = true
local _, opening = Engine.PrepareTrial(state, 'main:c01:a', function() return 0.5 end)
state = Engine.SettleTrial(state, 'main:c01:a', opening, now).state
local function Clear(id)
    local beforeGold, beforeInventory = state.gold, #state.inventory
    local result = Engine.SettleTrial(state, id, { won = true, stars = 3, elapsed = 10 }, now)
    assert(result.ok)
    local event, equipment = nil, {}
    for _, value in ipairs(result.delta.events) do
        local wire = require('server.domain.TableUtils').DeepCopy(value)
        wire.type = wire.kind or wire.type
        local valid, reason = Schema.Validate(wire); assert(valid, reason)
        assert(value.kind ~= 'battle_reward', 'chapter must not pay tower combat reward')
        if value.kind == 'campaign_stage_completed' then event = value end
        if value.kind == 'equipment_drop' or value.kind == 'equipment_granted' then equipment[value.itemId] = true end
    end
    assert(event and event.firstClear and event.reward.gold == Catalog.GetStage(id).gold)
    assert(Large.Compare(result.state.gold, Large.Add(beforeGold, event.reward.gold)) == 0)
    assert(#result.state.inventory == beforeInventory + 1, 'one equipment grant per battle stage')
    local count = 0; for _ in pairs(equipment) do count = count + 1 end; assert(count == 1)
    state = result.state
    local repeated = Engine.SettleTrial(state, id, { won = true, stars = 3, elapsed = 10 }, now)
    assert(Large.Compare(repeated.state.gold, state.gold) == 0 and #repeated.state.inventory == #state.inventory)
    for _, value in ipairs(repeated.delta.events) do
        if value.kind == 'campaign_stage_completed' then assert(not value.firstClear and value.reward == nil) end
    end
    return result.delta, event
end
Clear('main:c01:b')
local chapterDelta, chapterEvent = Clear('main:c01:c')
assert(chapterEvent.chapterCompleted)

-- Real feedback reducer with only UI/transport boundaries stubbed.
local shown, accumulated = {}, 0
local returnedStage
package.loaded['client.CampaignView'] = { GetRewardReturnHandler = function(id)
    return function() returnedStage = id end
end }
package.loaded['urhox-libs/UI'] = { Toast = { Show = function() end } }
package.loaded['client.Theme'] = { Colors = {} }
package.loaded['client.UI.UILayout'] = { Z = { reward = 3700 } }
package.loaded['client.GameStateAdapter'] = { GetViewState = function() return { autoRun = true } end }
package.loaded['client.IdleRewardAccumulator'] = {
    New = function() return {} end, HasValue = function() return false end,
    IsRewardEvent = function() return true end,
    Accumulate = function() accumulated = accumulated + 1 end,
}
package.loaded['client.RewardDialogView'] = {
    AddCard = function(cards, icon, name, amount) cards[#cards + 1] = { name = name, amount = amount } end,
    Show = function(options) shown[#shown + 1] = options; return true end,
}
package.loaded['client.AudioController'] = {}
package.loaded['client.ViewAssets'] = { ASSETS = { items = { gold = 'gold', crystal = 'crystal' } } }
package.loaded['client.ViewKit'] = { FormatInt = function(v) return tostring(require('shared.BigNumber').ToNumber(v)) end }
package.loaded['client.ItemView'] = { GetItemById = function() end, ItemImage = function() return 'equipment' end }
package.loaded['client.CommonPromptDialog'] = { Show = function(options) assert(options.zIndex == 3700) end }
package.loaded['client.RewardClaimController'] = { ShowPending = function() end, HandleDelta = function() end,
    ShowReward = function(options)
        options.cards = options.buildCards({})
        return package.loaded['client.RewardDialogView'].Show(options)
    end }
package.loaded['client.AdGiftController'] = { HandleDelta = function() end }
local Feedback = require('client.RewardFeedbackController')
Feedback.SyncSnapshot()
Feedback.AccumulateDelta(chapterDelta)
Feedback.PresentDelta(chapterDelta)
assert(accumulated == 0, 'chapter equipment must not also appear in idle summary')
assert(#shown == 1 and #shown[1].cards == 4, 'one common popup containing one equipment and three resources')
assert(shown[1].title == '章节通关奖励' and shown[1].zIndex == 3700)
assert(shown[1].confirmText == '领取并返回章节')
shown[1].onConfirm()
assert(returnedStage == 'main:c01:c')
Feedback.PresentDelta({ events = { { kind = 'campaign_stage_completed', stageId = 'main:c01:c', firstClear = false } } })
assert(#shown == 1, 'replay without reward must not show a second reward popup')

-- Pause both newly scheduled and already queued tower ticks; resume without catchup.
local ticks, jobs, applied = 0, {}, 0
package.loaded['server.domain.GameEngine'] = { AdvanceCombatTick = function()
    ticks = ticks + 1; return { ok = true, data = { delta = { events = {} } } }
end }
local session = { generation = 1, state = { autoRun = true, currentMonster = { hp = 100 } } }
local profile = {}
function profile:GetSession() return session end
function profile:GetState() return session.state end
function profile:IsOnline() return true end
function profile:OnlineUserIds() return { 'test' } end
function profile:ApplyRuntime(_, _, mutate, callback)
    applied = applied + 1
    local result = mutate(session.state, now)
    callback(result.data and result or { ok = true, data = { delta = result.delta } })
end
local runtime = require('server.services.IdleRuntimeService').New {
    profileService = profile, operationQueue = { Enqueue = function(_, _, job) jobs[#jobs + 1] = job end },
}
runtime:_enqueueTick('test', 0.1)
session.campaignTrial = { expiresAt = now + 900 }
jobs[1](function() end)
assert(ticks == 0 and applied == 0, 'queued tower tick must recheck chapter activity')
runtime:Update(120)
assert(#jobs == 1 and runtime.elapsed.test == 0)
session.campaignTrial.expiresAt = now - 1
runtime:Update(1)
assert(#jobs == 2, 'expired chapter must not permanently pause tower')
jobs[2](function() end)
assert(ticks == 1)
-- Simulate a trial starting between the outer check and persistence mutator.
function profile:ApplyRuntime(_, _, mutate, callback)
    session.campaignTrial = { expiresAt = now + 900 }
    local result = mutate(session.state, now)
    assert(result.commit.kind == 'none')
    callback({ ok = true, data = { delta = result.delta } })
end
session.campaignTrial = nil
runtime:_enqueueTick('test', 0.1)
jobs[3](function() end)
assert(ticks == 1, 'mutator must recheck chapter activity')
print('campaign_rewards: PASS')
