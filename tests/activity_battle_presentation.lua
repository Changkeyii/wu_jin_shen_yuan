-- Use the actual view, controller, adapter and domains, with native widgets and
-- transport replaced. The cached page must transition from cards into combat.
local now = 1791455000
local damageTexts = 0
local function Widget(props)
    local w = {props = props or {}, children = {}, writes = 0, state = {scrollY = 0, scrollX = 0}}
    function w:AddChild(c) self.children[#self.children + 1] = c; c.parent = self end
    function w:InsertChild(c, i) table.insert(self.children, i, c); c.parent = self end
    function w:RemoveChild(c)
        for i, child in ipairs(self.children) do
            if child == c then table.remove(self.children, i); c.parent = nil; return end
        end
    end
    function w:SetScrollDirect(x, y) self.state.scrollX, self.state.scrollY = x, y end
    function w:SetStyle(p) self.writes = self.writes + 1; for k,v in pairs(p) do self.props[k] = v end end
    function w:SetText(t)
        if tonumber(t) or tostring(t):match('^暴击 %d') then damageTexts = damageTexts + 1 end
        self:SetStyle{text = t}
    end
    function w:Destroy() self.destroyed = true end
    function w:SetVisible(v) self.props.visible = v end
    for _, c in ipairs(w.props.children or {}) do w:AddChild(c) end
    return w
end
local UI = {Panel = Widget, Card = Widget, Badge = Widget, ScrollView = Widget, Toast = {Show = function() end}}
package.loaded['urhox-libs/UI'] = UI
package.loaded['client.Theme'] = {Colors = setmetatable({}, {__index = function() return {255,255,255,255} end})}
package.loaded['client.UI.UILayout'] = {ContentHeight = function() return 1200 end}
package.loaded['client.ServerClock'] = {Now = function() return math.floor(now + 0.0001) end,
    DayKey = function(t) return math.floor((t + 28800) / 86400) end}
package.loaded['client.AbyssPresentation'] = {BuildPillar = function() return Widget{} end}
package.loaded['client.RewardVideo'] = {WATCHDOG_SECONDS = 60, ActionText = function(label) return label end}
package.loaded['client.RewardClaimController'] = {}
local confirmation
package.loaded['client.CommonPromptDialog'] = {Show = function(p) confirmation = p end}
local preload
package.loaded['client.LoadingController'] = {EnsurePlayAssetsReady = function(cb) preload = cb end}
local function Text(t, _, _, p) p = p or {}; p.text = t; return Widget(p) end
package.loaded['client.ViewKit'] = {
    Txt = Text, CompactTxt = Text, MultiTxt = Text, RewardCell = Widget, BackButton = function(p) p.text = '返回'; return Widget(p) end,
    ActionButton = function(p) return Widget(p) end,
    FormatInt = tostring, FormatDuration = tostring,
    ImageButton = function(t, w, h, image, cb, disabled)
        return Widget{text = t, width = w, height = h, onClick = cb, disabled = disabled}
    end,
}
local Factory = require('server.domain.StateFactory')
local Activity = require('server.domain.ActivityEngine')
local Boss = require('server.domain.ChallengeEngine')
local trialCommand, trialSession
local state, adapter, deltaListener
local calls, failures, deferred, late = {}, {}, {}, nil
local function Apply(p)
    if not p.ok then return {ok = false, reason = p.error.reason} end
    state = p.state
    assert(adapter.ApplyDelta(p.delta))
    if deltaListener then deltaListener(p.delta) end
    return {ok = true}
end
local server = {
    On = function(kind, cb) if kind == 'delta' then deltaListener = cb end end,
    RequestSnapshot = function() assert(adapter.ApplySnapshot(state)) end,
    Send = function(cmd, payload, cb)
        calls[cmd] = (calls[cmd] or 0) + 1
        local function Deliver()
            if failures[cmd] then failures[cmd] = nil; cb({ok = false, reason = 'injected temporary failure'}); return end
            local p
            if cmd == 'Activity.BeginStrike' then p = Activity.BeginStrike(state, payload.activityId, now)
            elseif cmd == 'Activity.Strike' then p = Activity.Strike(state, payload.activityId, now)
            elseif cmd == 'Activity.FinishStrike' then p = Activity.FinishStrike(state, payload.activityId, now)
            elseif cmd == 'Activity.BeginAbyssBoss' then p = Boss.BeginBoss(state, payload.gradeId, now, payload.setId)
            elseif cmd == 'Activity.StrikeAbyssBoss' then p = Boss.StrikeBoss(state, now)
            elseif cmd == 'Activity.FinishAbyssBoss' then p = Boss.FinishBoss(state, now)
            else error(cmd) end
            cb(Apply(p))
        end
        if deferred[cmd] then late = Deliver else Deliver() end
    end,
}
function server.CampaignTrial(stageId, action, trialId, pageNo, cb)
    local key = 'trial:' .. action
    calls[key] = (calls[key] or 0) + 1
    local function Deliver()
        if failures[key] then failures[key] = nil; cb({ok = false, reason = 'temporary failure'}); return end
        trialSession.state = state
        trialCommand.handler({uid = 'p'}, {stageId = stageId, action = action, trialId = trialId, page = pageNo},
            function(_, response) cb(response) end)
    end
    if deferred[key] then late = Deliver else Deliver() end
end
package.loaded['client.ServerClient'] = server
local services = {profileService = {}, sendDelta = function(_, delta)
    assert(adapter.ApplyDelta(delta)); if deltaListener then deltaListener(delta) end
end}
function services.profileService:GetSession() return trialSession end
function services.profileService:Apply(_, _, mutate, cb)
    local proposal = mutate(state, math.floor(now + 0.0001))
    if not proposal.ok then cb({ok = false, code = proposal.error.code, reason = proposal.error.reason}); return end
    state, trialSession.state = proposal.state, proposal.state
    cb({ok = true, data = {state = state, delta = proposal.delta}})
end
require('server.commands.CampaignTrialCommands').Register({Register = function(_, d) trialCommand = d end}, services)
local playedFrames = 0
package.loaded['client.PlayPresentation'] = {CreateIsolated = function() return {
    BuildPage = function() return Widget{} end, Update = function() end,
    HandleDelta = function() playedFrames = playedFrames + 1 end,
    ClearCombatPresentation = function() end, Reset = function() end,
} end}
adapter = require('client.GameStateAdapter')
local Controller = require('client.ActivityController')
local View = require('client.ActivityView')
local page, refreshPending
Controller.Configure{requestPageRefresh = function() refreshPending = true end}
local function Refresh()
    if refreshPending then
        refreshPending = false
        if not page or not page:Update() then
            if page then page:Destroy() end
            page = View.BuildPage()
        end
    end
end
local function Find(w, predicate)
    if predicate(w) then return w end
    for _, c in ipairs(w.children) do local found = Find(c, predicate); if found then return found end end
end
local function TextIs(w, t) return Find(w, function(c) return c.props.text == t end) end
local function Click(t)
    local w = assert(Find(page:GetRoot(), function(c)
        return c.props.onClick and (c.props.text == t or TextIs(c, t))
    end), 'missing action: ' .. t)
    assert(not w.props.disabled); w.props.onClick(); Refresh()
end
local function New()
    View.Reset(); Controller.Recover(); adapter.Reset()
    state = Factory.Create(math.floor(now)); state.level = 40; state.abyss.tickets = 100000
    local catalog = require('server.domain.Catalog')
    for _, item in ipairs(state.inventory) do
        item.level = 40
        local def = require('shared.EquipmentCatalog').Get(item.equipmentId)
        for key, value in pairs(catalog.CreateItemStats(def, 40, item.rarity, 1, 0, 0)) do item[key] = value end
    end
    state = require('server.domain.StateNormalizer').Normalize(state, math.floor(now))
    require('server.domain.PlayerTransition').RefreshDerived(state)
    trialSession = {state = state, generation = 1}
    adapter.ApplySnapshot(state); adapter.SetPage('activity')
    page = View.BuildPage(); refreshPending = false; calls = {}; failures = {}; deferred = {}; late = nil; damageTexts = 0
end
local function Step(seconds)
    for _ = 1, math.floor(seconds * 40) do now = now + 0.025; View.Update(0.025); Refresh() end
end
local function Ready()
    assert(preload); local cb = preload; preload = nil; cb(); Refresh()
end

-- Clicking selections, failed responses and unrelated deltas keep the same
-- viewport and cards. Enter must use the newly selected tier/set/grade.
New()
state.level = 100
require('server.domain.PlayerTransition').RefreshDerived(state)
adapter.ApplySnapshot(state)
Click('每日补给')
local listPage, listRoot = page, page:GetRoot()
local viewport = listRoot.children[1].children[3]
local content = viewport.children[1]
local goldCard, fragmentCard = content.children[1], content.children[3]
viewport:SetScrollDirect(0, 380)
Click('困难 · Lv.50')
assert(page == listPage and page:GetRoot() == listRoot and viewport.state.scrollY == 380)
assert(content.children[1] == goldCard and content.children[3] == fragmentCard)
failures['Activity.UnlockExtraStrike'] = true
Controller.UnlockExtraStrike('act_daily_gold', function(r) assert(not r.ok) end); Refresh()
assert(page == listPage and content.children[1] == goldCard)
state.gold = require('shared.LargeNumber').Add(state.gold, 1)
adapter.ApplySnapshot(state); Controller.Refresh(); Refresh()
assert(content.children[1] == goldCard and viewport.state.scrollY == 380)
Click('进入'); Ready()
assert(state.activities.act_daily_exp.session.dungeonStageId == 'dungeon:tickets:2')
View.Reset(); page:Destroy()

New(); state.level = 100; require('server.domain.PlayerTransition').RefreshDerived(state)
adapter.ApplySnapshot(state); Click('热门活动')
local hotPage, hotRoot = page, page:GetRoot()
local hotScroll = hotRoot.children[1].children[3]
local abyssCard = hotScroll.children[1].children[5]
hotScroll:SetScrollDirect(0, 650)
Click('幸运'); Click('灾厄深渊')
assert(page == hotPage and hotScroll.state.scrollY == 650)
assert(hotScroll.children[1].children[5] == abyssCard)
Click('每日补给'); Click('热门活动')
assert(page == hotPage and hotScroll.state.scrollY == 650)
Click('挑战 Boss'); Ready()
assert(state.challenges.bossSession.gradeId == 'calamity' and state.challenges.bossSession.setId == 'lucky')
New(); Click('热门活动'); Click('裂隙深渊'); Click('噩梦')

for index, id in ipairs(require('shared.ActivityDefinitions').StrikeIds) do
    New(); Click('每日补给')
    local entries = {}
    local function Collect(w)
        if w.props.text == '进入' then entries[#entries + 1] = w end
        for _, c in ipairs(w.children) do Collect(c) end
    end
    Collect(page:GetRoot()); assert(#entries == 3)
    local list = page
    entries[index].props.onClick()
    assert(not calls['trial:prepare'], 'preload must finish before consuming daily attempt')
    Ready()
    assert(View.IsStriking() and page ~= list and list:GetRoot().destroyed)
    local scene = page
    assert(calls['trial:frames'] and state.activities[id].session.dungeonStageId)
    if index == 1 then failures['trial:finish'] = true end
    Step(95)
    if index == 1 then Click('重试结算') end
    assert(page == scene, 'battle and reward deltas must preserve the common scene')
    assert(not state.activities[id].session and state.activities[id].strikeCount == 1)
    assert(calls['trial:finish'] == (index == 1 and 2 or 1) and playedFrames > 0)
    Click('返回副本')
    assert(not View.IsStriking() and scene:GetRoot().destroyed)
end

New(); Click('热门活动'); Click('挑战 Boss'); Ready()
assert(View.IsStriking(), 'boss must participate in the GameView refresh guard')
local bossScene = page
Step(3)
assert(calls['Activity.StrikeAbyssBoss'] and state.challenges.bossSession.damage > 0)
assert(page == bossScene)
assert(damageTexts > 0, 'Boss hit must display authoritative damage text')
-- Rift must be reachable with the full existing A/B/C animation cadence.
Step(18)
assert(not View.IsStriking() and not state.challenges.bossSession and state.challenges.bossKills == 1)
assert(state.challenges.lastBossKilled and calls['Activity.StrikeAbyssBoss'] >= 3)

-- Exit waits for an in-flight hit, then retries settlement without losing the scene.
local function LegacyScene()
    New(); Apply(Activity.BeginStrike(state, 'act_daily_gold', now))
    page:Destroy(); page = View.BuildPage()
end
LegacyScene()
deferred['Activity.Strike'] = true
Step(1)
assert(late)
Click('返回'); assert(confirmation); confirmation.onConfirm()
Step(1); assert(not calls['Activity.FinishStrike'] and View.IsStriking())
local deliver = late; late = nil; deferred['Activity.Strike'] = nil; deliver()
failures['Activity.FinishStrike'] = true
Step(0.1); assert(View.IsStriking())
Step(3); assert(not View.IsStriking() and calls['Activity.FinishStrike'] == 2)

-- Logout/recovery invalidates a late preparation callback; a new server session
-- is restored with its original deadline on the next authenticated page build.
New(); Click('每日补给'); Click('进入')
View.Reset(); Ready(); assert(not calls['trial:prepare'])
page:Destroy(); page = View.BuildPage()
deferred['trial:prepare'] = true
Click('进入'); Ready(); assert(late)
View.Reset(); Controller.Recover()
late(); assert(not View.IsStriking(), 'late response must not revive a reset scene')
assert(calls['trial:abort'] == 1 and not state.activities.act_daily_gold.session)
-- A legacy timed challenge remains recoverable with its original deadline.
LegacyScene(); now = state.activities.act_daily_gold.session.startedAt + 10; adapter.ApplySnapshot(state)
View.Update(0)
page:Destroy(); page = View.BuildPage()
assert(View.IsStriking() and TextIs(page:GetRoot(), '剩余 5 秒'))
Step(6); assert(not View.IsStriking())
print('activity_battle_presentation: PASS')
