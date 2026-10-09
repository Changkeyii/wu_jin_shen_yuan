local Video = require("client.RewardVideo")
local calls, last = 0, nil
local function result(value) calls = calls + 1; last = value end
_G.sdk = nil
assert(not Video.Play(result) and calls == 1 and not last.success)
_G.sdk = { ShowRewardVideoAd = function() return false end }
assert(not Video.Play(result) and calls == 2 and not Video.IsBusy())
_G.sdk = { ShowRewardVideoAd = function(_, cb) cb({ success = false }); return false end }
assert(not Video.Play(result) and calls == 3, "synchronous failure must finish once")
_G.sdk = { ShowRewardVideoAd = function() error("native sdk failure") end }
assert(not Video.Play(result) and calls == 4)
local callback
_G.sdk = { ShowRewardVideoAd = function(_, cb) callback = cb; return true end }
assert(Video.Play(result) and Video.IsBusy())
local rejected = 0
assert(not Video.Play(function(v) assert(not v.success); rejected = rejected + 1 end))
assert(rejected == 1 and Video.IsBusy())
callback({ success = true }); callback({ success = true })
assert(calls == 5 and last.success and not Video.IsBusy(), "duplicate SDK callback must finish once")
assert(Video.Play(result)) -- no game-defined cooldown
callback({ success = false, msg = "embed manual close" })
assert(calls == 6 and not last.success)
assert(Video.Play(result))
local stale = callback
Video.Update(180)
assert(calls == 7 and not last.success and not Video.IsBusy())
stale({ success = true })
assert(calls == 7, "late completion after timeout must not grant")
assert(Video.Play(result))
stale = callback
Video.Reset()
stale({ success = true })
assert(calls == 7 and not Video.IsBusy(), "old session callback must be ignored")
print("reward_video: PASS")
