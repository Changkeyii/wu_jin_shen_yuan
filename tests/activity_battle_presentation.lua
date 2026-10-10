-- Use the actual view, controller, adapter and domains, with native widgets and
-- transport replaced. The cached page must transition from cards into combat.
local now = 1791455000
local damageTexts = 0
local function Widget(props)
    local w = {props = props or {}, children = {}, writes = 0}
    function w:AddChild(c) self.children[#self.children + 1] = c end
    function w:SetStyle(p) self.writes = self.writes + 1; for k,v in pairs(p) do self.props[k] = v end end
    function w:SetText(t)
        if tonumber(t) or tostring(t):match('^暴击 %d') then damageTexts = damageTexts + 1 end
        self:SetStyle{text = t}
    end
    function w:Destroy() self.destroyed = true end
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
package.loaded['client.RewardVideo'] = {WATCHDOG_SECONDS = 60}
package.loaded['client.RewardClaimController'] = {}
local confirmation
package.loaded['client.CommonPromptDialog'] = {Show = function(p) confirmation = p end}
local preload
package.loaded['client.LoadingController'] = {EnsurePlayAssetsReady = function(cb) preload = cb end}
local function Text(t, _, _, p) p = p or {}; p.text = t; return Widget(p) end
package.loaded['client.ViewKit'] = {
    Txt = Text, CompactTxt = Text, RewardCell = Widget, BackButton = function(p) p.text = '返回'; return Widget(p) end,
    FormatInt = tostring, FormatDuration = tostring,
    ImageButton = function(t, w, h, image, cb, disabled)
        return Widget{text = t, width = w, height = h, onClick = cb, disabled = disabled}
    end,
}
local Factory = require('server.domain.StateFactory')
local Activity = require('server.domain.ActivityEngine')
local Boss = require('server.domain.ChallengeEngine')
local state, adapter, deltaListener
local calls, failures, deferred, late = {}, {}, {}, nil
local function Apply(p)
    if not p.ok then return {ok = false, reason = p.error.reason} end
    state = p.state
    assert(adapter.ApplyDelta(p.delta))
    if deltaListener then deltaListener(p.delta) end
    return {ok = true}
end
package.loaded['client.ServerClient'] = {
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
            elseif cmd == 'Activity.BeginAbyssBoss' then p = Boss.BeginBoss(state, payload.gradeId, now)
            elseif cmd == 'Activity.StrikeAbyssBoss' then p = Boss.StrikeBoss(state, now)
            elseif cmd == 'Activity.FinishAbyssBoss' then p = Boss.FinishBoss(state, now)
            else error(cmd) end
            cb(Apply(p))
        end
        if deferred[cmd] then late = Deliver else Deliver() end
    end,
}
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
    adapter.ApplySnapshot(state); adapter.SetPage('activity')
    page = View.BuildPage(); refreshPending = false; calls = {}; failures = {}; deferred = {}; late = nil; damageTexts = 0
end
local function Step(seconds)
    for _ = 1, math.floor(seconds * 40) do now = now + 0.025; View.Update(0.025); Refresh() end
end
local function Ready()
    assert(preload); local cb = preload; preload = nil; cb(); Refresh()
end
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
    assert(not calls['Activity.BeginStrike'], 'preload must finish before consuming daily attempt')
    Ready()
    assert(View.IsStriking() and page ~= list and list:GetRoot().destroyed)
    local scene = page
    assert(TextIs(scene:GetRoot(), '剩余 15 秒'))
    Step(3)
    assert(calls['Activity.Strike'] and state.activities[id].session.damage > 0)
    assert(page == scene, 'hit delta must preserve the battle scene')
    assert(TextIs(scene:GetRoot(), '剩余 12 秒'))
    -- Rebuilding a page during recovery must preserve the authoritative deadline.
    page:Destroy(); page = View.BuildPage()
    assert(TextIs(page:GetRoot(), '剩余 12 秒'))
    if index == 1 then failures['Activity.FinishStrike'] = true end
    Step(15)
    assert(not View.IsStriking() and not state.activities[id].session)
    assert(state.activities[id].strikeCount == 1 and state.challenges.lastStrikeDamage > 0)
    assert(calls['Activity.FinishStrike'] == (index == 1 and 2 or 1))
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
assert(state.challenges.lastBossKilled and calls['Activity.StrikeAbyssBoss'] >= 6)

-- Exit waits for an in-flight hit, then retries settlement without losing the scene.
New(); Click('每日补给'); Click('进入'); Ready()
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
View.Reset(); Ready(); assert(not calls['Activity.BeginStrike'])
deferred['Activity.BeginStrike'] = true
Click('进入'); Ready(); assert(late)
View.Reset(); Controller.Recover()
late(); assert(not View.IsStriking(), 'late response must not revive a reset scene')
now = now + 10; adapter.ApplySnapshot(state)
page = View.BuildPage(); assert(View.IsStriking() and TextIs(page:GetRoot(), '剩余 5 秒'))
Step(6); assert(not View.IsStriking())
print('activity_battle_presentation: PASS')
