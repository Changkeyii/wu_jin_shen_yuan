local F = require("server.domain.StateFactory")
local E = require("server.domain.AdGiftEngine")
local T = require("server.domain.PlayerTransition")
local Catalog = require("server.domain.Catalog")
local Equipment = require("server.domain.EquipmentEngine")
local Rewards = require("server.domain.RewardEngine")
local Combat = require("server.domain.CombatEngine")
local Game = require("server.domain.GameEngine")
local Schema = require("shared.GameStateSchema")
local D = require("shared.AdGiftDefinitions")
local Large = require("shared.LargeNumber")
local Big = require("shared.BigNumber")
local now = 1791450000
local function fresh()
    local s = F.Create(now)
    s.tutorial = { completed = true, step = 6 }
    return s
end
local function validate(state, events)
    local snapshot = Schema.BuildSnapshot(state, { serverTime = now, playerNickname = "gift tests", itemPower = Catalog.GetItemPower })
    snapshot.logs, snapshot.recentDamage = {}, "ready"
    local ok, err = Schema.ValidateSnapshot(snapshot)
    assert(ok, err and (err.reason .. " " .. tostring(err.details and err.details.path)))
    local canonical, reason = Schema.CanonicalizeGameEvents(events or {})
    assert(canonical, reason)
    local saved = Schema.ToPersistedState(state)
    local savedOk, savedError = Schema.ValidateState(saved)
    assert(savedOk, savedError and savedError.reason)
    local loaded = T.Copy(saved, now)
    assert(loaded.rewardClaims.gifts.nextId == state.rewardClaims.gifts.nextId)
    assert(loaded.rewardClaims.gifts.lastClaim == state.rewardClaims.gifts.lastClaim)
end
local function claim(state, kind)
    local p = E.Prepare(state, kind, now)
    assert(p.ok, kind .. " unavailable")
    local q = p.state.rewardClaims.gifts.quote
    validate(p.state, p.delta.events)
    local r = E.Claim(p.state, q.id, now)
    assert(r.ok and r.state.rewardClaims.gifts.quote == nil)
    assert(Large.Compare(r.state.gold, Large.Add(p.state.gold, q.reward.gold)) == 0)
    assert(Large.Compare(r.state.fragments, Large.Add(p.state.fragments, q.reward.fragments)) == 0)
    local replay = E.Claim(r.state, q.id, now)
    assert(replay.ok and replay.commit.kind == "none", "callback/retry may not award twice")
    assert(Large.Compare(replay.state.gold, r.state.gold) == 0)
    validate(r.state, r.delta.events)
    return r.state
end

local tutorial = F.Create(now)
assert(next(E.List(tutorial)) == nil)
assert(not E.Prepare(tutorial, "forge", now).ok)
E.OnDecompose(tutorial, 100, {})
E.OnBossVictory(tutorial, Large.FromNumber(100), {})
E.OnOffline(tutorial, { gold = Large.FromNumber(100) }, {})
assert(next(tutorial.rewardClaims.gifts.offers) == nil, "tutorial must not advertise")

local state = fresh()
assert(not E.Prepare(state, "offline", now).ok)
assert(not E.Prepare(state, "invalid", now).ok)
assert(not E.Claim(state, "gift.999", now).ok)
-- More than any proposed daily quota, at identical timestamps: no cooldown or daily cap.
for _ = 1, 12 do state = claim(state, "forge") end

-- Frozen server quote survives a new offer arriving while the video is playing.
E.OnDecompose(state, 20, {})
local prepared = E.Prepare(state, "recycle", now)
local token = prepared.state.rewardClaims.gifts.quote.id
E.OnDecompose(prepared.state, 2000, {})
local after = E.Claim(prepared.state, token, now)
assert(Large.Compare(after.state.fragments, Large.Add(prepared.state.fragments, 10)) == 0)
state = after.state
assert(state.rewardClaims.gifts.offers.recycle.fragments == 1000)

-- Actual dismantle operation excludes the refund of invested upgrade fragments.
local recycle = fresh()
local armor = T.FindItem(recycle, recycle.equipped.shoulder)
recycle.equipped.shoulder = nil
armor.investedFragments = 10000
local base = Catalog.GetEquipmentBaseRecoveryValue(armor).fragments
local decomposed = Equipment.Decompose(recycle, Catalog.RARITIES[armor.rarity].rank, now, { armor.id })
assert(decomposed.ok)
assert(decomposed.state.rewardClaims.gifts.offers.recycle.fragments == math.floor(base / 2))
claim(decomposed.state, "recycle")

-- Actual offline claim adds the bonus opportunity only after the base reward is claimed.
local offline = fresh()
offline.pendingOfflineSeconds = 60
local ledger = { seconds = 60, gold = Large.FromNumber(1000), fragments = 20, exp = 0, items = {},
    reward = { seconds = 60, processedSeconds = 60, gold = Large.FromNumber(1000), fragments = 20, exp = 0, equipment = 0 } }
local collected = Rewards.ClaimOfflineReward(offline, ledger, now)
assert(collected.ok)
assert(collected.state.rewardClaims.gifts.offers.offline.fragments == 10)
assert(Large.Compare(collected.state.rewardClaims.gifts.offers.offline.gold, 500) == 0)
assert(not Rewards.ClaimOfflineReward(collected.state, ledger, now).ok)
claim(collected.state, "offline")

-- Real boss settlement must update only the new state and send gifts in the delta.
local boss = fresh()
boss.position, boss.autoRun = 10, true
Combat.BeginBattle(boss, "boss", function() return 0.5 end, {})
boss.currentMonster.hpBig, boss.currentMonster.hp = Big.Zero(), 0
boss.currentMonster.phase, boss.currentMonster.phaseRemaining = "recovery", 0
local won = Game.AdvanceCombatTick(boss, function() return 0.99 end, now, 0.1)
assert(won.ok and won.state.rewardClaims.gifts.offers.boss)
assert(not boss.rewardClaims.gifts.offers.boss, "combat may not mutate the input gift state")
assert(won.delta.changed.rewardClaims, "gift update must be replicated")
claim(won.state, "boss")

local lost = fresh()
for attempt = 1, 2 do
    lost.position, lost.autoRun = 10, true
    Combat.BeginBattle(lost, "boss", function() return 0.99 end, {})
    lost.hp, lost.hpBig = 1, Big.FromNumber(1)
    lost.currentMonster.atkBig = Big.FromNumber(1000000000)
    lost.currentMonster.phaseRemaining, lost.currentMonster.nextMonsterAttackSeconds = 1, 0
    local died = Game.AdvanceCombatTick(lost, function() return 0.99 end, now, 0.1)
    assert(died.ok and died.state.rewardClaims.gifts.losses == attempt)
    assert(lost.rewardClaims.gifts.losses == attempt - 1, "death must not mutate input gift state")
    lost = died.state
end
assert(lost.rewardClaims.gifts.offers.retry)
validate(lost)

local progress = fresh()
for n = 1, 30 do
    progress.floor, progress.revision = n, n
    E.OnBossVictory(progress, Large.FromNumber(100), {})
    if n == 4 then assert(not progress.rewardClaims.gifts.offers.journey) end
    if n == 10 then assert(progress.rewardClaims.gifts.offers.journey.fragments == 30) end
    if n == 20 then assert(progress.rewardClaims.gifts.offers.journey.fragments == 65) end
end
assert(progress.rewardClaims.gifts.offers.journey.jars == 0)
local jarsBefore = progress.wishPool.jars["jar.random"] or 0
progress = claim(progress, "journey")
assert((progress.wishPool.jars["jar.random"] or 0) == jarsBefore)

local retry = fresh()
E.OnLoss(retry, { encounter = "boss" }, {})
assert(not retry.rewardClaims.gifts.offers.retry)
retry.floor = 2
E.OnLoss(retry, { encounter = "boss" }, {})
assert(not retry.rewardClaims.gifts.offers.retry, "different bosses must not count as consecutive failures")
E.OnLoss(retry, { encounter = "boss" }, {})
retry = claim(retry, "retry")
assert(not E.Prepare(retry, "retry", now).ok, "event bonus cannot be claimed twice")
assert(retry.rewardClaims.gifts.boostCharges == 1)
retry.position = 10
Combat.BeginBattle(retry, "boss", function() return 0.99 end, {}, { offline = true })
assert(retry.rewardClaims.gifts.boostCharges == 1 and not retry.rewardClaims.gifts.boostActive,
    "offline simulation must not consume the next online boss boost")
retry.position = 1
Combat.BeginBattle(retry, "monster", function() return 0.99 end, {})
assert(retry.rewardClaims.gifts.boostCharges == 1 and not retry.rewardClaims.gifts.boostActive)
retry.position = 10
Combat.BeginBattle(retry, "boss", function() return 0.99 end, {})
assert(retry.rewardClaims.gifts.boostCharges == 0 and retry.rewardClaims.gifts.boostActive)
local target = retry.currentMonster
local boosted = Combat.PlayerHitDamage(retry, target, 1, function() return 0.99 end)
retry.rewardClaims.gifts.boostActive = false
local normal = Combat.PlayerHitDamage(retry, target, 1, function() return 0.99 end)
assert(Big.Compare(boosted, normal) > 0, "queued boost must change actual combat damage")
E.OnLoss(retry, target, {})
assert(not retry.rewardClaims.gifts.boostActive and retry.rewardClaims.gifts.boostCharges == 0)

local old = fresh()
old.rewardClaims.gifts = nil
local migrated = T.Copy(old, now)
assert(migrated.rewardClaims.gifts.nextId == 1)
validate(migrated)
for _, kind in ipairs(D.ORDER) do assert(D.KINDS[kind]) end
print("ad_gifts: PASS")
