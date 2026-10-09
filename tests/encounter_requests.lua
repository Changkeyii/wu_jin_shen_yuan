local Controller = require("client.EncounterRequestController")
local route = { routeId = "floor-1" }
local encounter = { encounterId = "floor-1-room-1", room = 1 }
local game = { autoRun = true }
local requests, snapshots, toasts = 0, 0, 0
local callbacks = {}
local context = {
    serverClient = {
        EnterEncounter = function(routeId, encounterId, room, callback)
            assert(routeId == route.routeId and encounterId == encounter.encounterId and room == 1)
            requests = requests + 1
            callbacks[#callbacks + 1] = callback
        end,
        RequestSnapshot = function() snapshots = snapshots + 1 end,
    },
    actionResult = function() toasts = toasts + 1 end,
}
local controller = Controller.New()
local function frames(count)
    for _ = 1, count do
        controller:Update(1 / 60)
        controller:Try(game, route, encounter, context)
    end
end

-- At the first enemy, pending prologue must send no commands at any frame rate.
for _, field in ipairs({ "pendingStoryGate", "pendingStory", "pendingEvent", "aidPending", "readOnly", "currentMonster" }) do
    game[field] = true
    frames(600)
    assert(requests == 0, field .. " must block encounters")
    game[field] = nil
end
game.autoRun = false
frames(600)
assert(requests == 0, "must wait for authoritative auto-run")
game.autoRun = true
frames(600)
assert(requests == 1, "one request while awaiting response")
callbacks[1]({ ok = true })
frames(600)
assert(requests == 1, "success must await battle state")

-- A gate rejected before its state arrived must not request a snapshot every frame.
controller:Reset()
frames(1)
callbacks[2]({ ok = false, code = "STORY_GATE_PENDING" })
frames(3600)
assert(requests == 2 and snapshots == 1 and toasts == 1, "business rejection loop")
controller:Reset() -- story_completed/story_skipped re-arms the encounter.
frames(1)
assert(requests == 3, "must resume after completing/skipping the story")

-- Rate limiting respects server retryAfter and has a bounded retry budget.
callbacks[3]({ ok = false, code = "RATE_LIMITED", details = { retryAfter = 10 } })
frames(540)
assert(requests == 3, "retried before server deadline")
frames(120)
assert(requests == 4, "must retry after deadline")
callbacks[4]({ ok = false, code = "SERVER_BUSY" })
frames(180)
assert(requests == 4, "must back off before second retry")
frames(120)
assert(requests == 5)
callbacks[5]({ ok = false, code = "RATE_LIMITED" })
frames(3600)
assert(requests == 5 and snapshots == 2 and toasts == 2, "unbounded retry/toast loop")

-- Delayed callbacks from a previous route/connection must not touch the new one.
controller:Reset()
frames(1)
controller:Reset()
frames(1)
callbacks[6]({ ok = false, code = "RATE_LIMITED" })
frames(600)
assert(requests == 7 and snapshots == 2 and toasts == 2, "stale callback changed new request")
callbacks[7]({ ok = true })
print("encounter_requests: PASS")
