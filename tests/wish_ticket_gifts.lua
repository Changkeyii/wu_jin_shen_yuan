local F = require("server.domain.StateFactory")
local E = require("server.domain.AdGiftEngine")
local T = require("server.domain.PlayerTransition")
local Schema = require("shared.GameStateSchema")
local Catalog = require("server.domain.Catalog")
local D = require("shared.AdGiftDefinitions")
local Wish = require("shared.WishPoolDefinitions")
local now = 1791450000
local function fresh()
    local state = F.Create(now)
    state.tutorial = { completed = true, step = 6 }
    return state
end
local function validate(state, events)
    local saved = Schema.ToPersistedState(state)
    local ok, err = Schema.ValidateState(saved)
    assert(ok, err and err.reason)
    local snapshot = Schema.BuildSnapshot(state, { serverTime = now, playerNickname = "wish gifts", itemPower = Catalog.GetItemPower })
    snapshot.logs, snapshot.recentDamage = {}, "ready"
    ok, err = Schema.ValidateSnapshot(snapshot)
    assert(ok, err and err.reason)
    assert(Schema.CanonicalizeGameEvents(events or {}))
    return T.Copy(saved, now)
end
local function collect(state, kind, at, expected)
    local prepared = E.Prepare(state, kind, at)
    assert(prepared.ok)
    state = validate(prepared.state)
    local quote = state.rewardClaims.gifts.quote
    assert(quote.reward.tickets == expected)
    local repeated = E.Prepare(state, kind, at)
    assert(repeated.ok and repeated.state.rewardClaims.gifts.quote.id == quote.id)
    local result = E.Claim(state, quote.id, at)
    assert(result.ok)
    assert(result.state.wishPool.tickets == state.wishPool.tickets + expected)
    assert(#result.state.rewardClaims.pending == #state.rewardClaims.pending, "tickets never generate a fivefold offer")
    assert(#result.delta.events == 1 and result.delta.events[1].kind == "ad_gift_claimed")
    local replay = E.Claim(result.state, quote.id, at)
    assert(replay.ok and replay.commit.kind == "none" and replay.state.wishPool.tickets == result.state.wishPool.tickets)
    return validate(result.state, result.delta.events)
end

assert(not E.Prepare(F.Create(now), "wishSupply", now).ok)
local state = fresh()
local initial = state.wishPool.tickets
for n = 1, 4 do
    assert(E.List(state, now).wishSupply.tickets == n)
    state = collect(state, "wishSupply", now, n)
end
assert(state.wishPool.tickets == initial + 10)
assert(not E.List(state, now).wishSupply)
assert(not E.Prepare(state, "wishSupply", now).ok)
assert(state.rewardClaims.gifts.wishUsed == 4)
local midnight = (Wish.DayKey(now) + 1) * 86400 - 8 * 3600
assert(not E.List(state, midnight - 1).wishSupply)
assert(E.List(state, midnight).wishSupply.tickets == 1)
state = collect(state, "wishSupply", midnight, 1)

-- Closing a quote and selecting a different gift consumes neither tickets nor daily quota.
state = E.Prepare(state, "wishSupply", midnight).state
assert(state.rewardClaims.gifts.quote.reward.tickets == 2)
state = E.Prepare(state, "forge", midnight).state
assert(not state.rewardClaims.gifts.offers.wishSupply)
state = collect(state, "wishSupply", midnight, 2)

-- A frozen prior-day quote remains redeemable after reconnect/midnight, charged to its original day.
local frozen = E.Prepare(state, "wishSupply", midnight).state
local token = frozen.rewardClaims.gifts.quote.id
local nextDay = midnight + 86400
local result = E.Claim(validate(frozen), token, nextDay)
assert(result.ok and result.state.wishPool.tickets == frozen.wishPool.tickets + 3)
assert(result.state.rewardClaims.gifts.wishDay == Wish.DayKey(midnight))
assert(E.List(result.state, nextDay).wishSupply.tickets == 1)
local reopened = E.Prepare(frozen, "wishSupply", nextDay)
assert(reopened.ok and reopened.state.rewardClaims.gifts.quote.reward.tickets == 1)
assert(reopened.state.rewardClaims.gifts.quote.day == Wish.DayKey(nextDay))
assert(reopened.state.rewardClaims.gifts.quote.id ~= token, "unwatched quotes refresh on the new day")

local lucky = fresh()
for floor = 1, 9 do lucky.floor = floor; E.OnBossVictory(lucky, 100, {}) end
assert(not E.List(lucky, now).lucky)
lucky.floor = 10; E.OnBossVictory(lucky, 100, {})
assert(E.List(lucky, now).lucky.tickets == 2)
for _ = 1, 5 do E.OnBossVictory(lucky, 100, {}) end
assert(lucky.rewardClaims.gifts.offers.lucky.tickets == 2)
lucky = E.Prepare(lucky, "lucky", now).state
local luckyToken = lucky.rewardClaims.gifts.quote.id
for floor = 11, 30 do lucky.floor, lucky.maxFloor = floor, floor; E.OnBossVictory(lucky, 100, {}) end
assert(lucky.rewardClaims.gifts.offers.lucky.tickets == 4)
local claimed = E.Claim(validate(lucky), luckyToken, now)
assert(claimed.ok and claimed.state.wishPool.tickets == lucky.wishPool.tickets + 2)
lucky = collect(claimed.state, "lucky", now, 2)
-- Switching quotes restores only the reserved two tickets, preserving other opportunities.
lucky = E.Prepare(lucky, "lucky", now).state
lucky = E.Prepare(lucky, "forge", now).state
assert(lucky.rewardClaims.gifts.offers.lucky.tickets == 2)
lucky = collect(lucky, "lucky", now, 2)
assert(not E.Prepare(lucky, "lucky", now).ok)
lucky.floor = 10; E.OnBossVictory(lucky, 100, {})
assert(not E.List(lucky, now).lucky)

local old = fresh()
old.maxFloor, old.floor = 121, 121
old.rewardClaims.gifts.version = 2
old.rewardClaims.gifts.luckyHighest = nil
old.rewardClaims.gifts.offers.boss = D.Reward { gold = 100 }
old.rewardClaims.gifts.quote = { id = "gift.1", kind = "boss", reward = D.Reward { gold = 50 } }
old.rewardClaims.gifts.nextId = 2
old = T.Copy(old, now)
assert(old.rewardClaims.gifts.luckyHighest == 120)
assert(old.rewardClaims.gifts.offers.boss and old.rewardClaims.gifts.quote, "v2 pending and frozen rewards both survive")
old.floor = 120; E.OnBossVictory(old, 100, {})
assert(not old.rewardClaims.gifts.offers.lucky, "no retroactive milestone farming")
old.floor, old.maxFloor = 130, 130; E.OnBossVictory(old, 100, {})
assert(old.rewardClaims.gifts.offers.lucky.tickets == 2)
validate(old)
print("wish_ticket_gifts: PASS (daily tiers/reset, frozen quotes, persistence, 10-floor milestones, migration, idempotence)")
