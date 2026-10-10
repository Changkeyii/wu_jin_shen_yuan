local Adventure = require("server.domain.AdventureEngine")
local Factory = require("server.domain.StateFactory")
local FloorRoute = require("shared.FloorRoute")
local StoryCatalog = require("shared.StoryCatalog")

local now = 1791446850
local function startFirstBattle(state)
    local start = Adventure.SetAutoRun(state, true, now)
    assert(start.ok, "tutorial auto-run rejected")
    assert(start.state.pendingStoryGate == nil, "hidden legacy prologue still blocks tutorial")
    assert(start.state.storyProgress.introCompleted, "tutorial must acknowledge prologue")
    assert(not start.state.tutorial.completed, "must not skip gameplay tutorial")
    local completed = false
    for _, event in ipairs(start.delta.events or {}) do
        assert(event.kind ~= "story_gate", "tutorial must not enqueue blocked legacy dialog")
        if event.kind == "story_completed" then completed = true end
    end
    assert(completed, "client needs story_completed to clear its gate and re-arm encounters")
    local first = FloorRoute.GetEncounter(1, 1)
    local battle = Adventure.EnterEncounter(start.state, {
        routeId = FloorRoute.RouteId(1), encounterId = first.encounterId, room = 1,
    }, nil, now + 1)
    assert(battle.ok, battle.error and battle.error.reason)
    assert(battle.state.currentMonster, "first enemy must start authoritative combat")
    assert(battle.state.position == 1)
    return start.state
end

local fresh = Factory.Create(now)
fresh.storyProgress.introCompleted = false
startFirstBattle(fresh)
assert(not fresh.storyProgress.introCompleted, "must not mutate input state")

-- Reproduce persisted saves from the broken flow, including already-on auto-run.
for _, completed in ipairs({ false, true }) do
    local stuck = Factory.Create(now)
    stuck.autoRun = true
    stuck.storyProgress.introCompleted = completed
    stuck.pendingStoryGate = {
        storyId = StoryCatalog.PROLOGUE.id, chapter = 0, floor = 1,
        phase = "prologue", title = StoryCatalog.PROLOGUE.title,
        lines = StoryCatalog.PROLOGUE.lines, lineIndex = 1,
    }
    stuck.pauseReason = "story_gate"
    local repaired = startFirstBattle(stuck)
    assert(repaired.pauseReason ~= "story_gate")
    assert(Adventure.SetAutoRun(repaired, true, now + 2).commit.kind == "none",
        "repeated auto-run must be idempotent")
end

local normal = Factory.Create(now)
normal.tutorial.completed = true
normal.storyProgress.introCompleted = false
local legacy = Adventure.SetAutoRun(normal, true, now)
assert(legacy.ok and not legacy.state.pendingStoryGate,
    "completed tutorial must never fall back to the old prologue flow")

local chapterState = Factory.Create(now)
chapterState.pendingStoryGate = StoryCatalog.GetGate(1, "opening")
chapterState.pendingStoryGate.lineIndex = 1
local chapter = Adventure.SetAutoRun(chapterState, true, now)
assert(chapter.ok and not chapter.state.pendingStoryGate,
    "obsolete chapter gates must not block free-select progression")
print("tutorial_prologue_battle: PASS")
