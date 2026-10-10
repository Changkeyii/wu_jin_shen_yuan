local Fixture = dofile("tests/helpers/mail_cloud_fixture.lua")
local Copy = require("server.domain.TableUtils").DeepCopy
local Equal = require("server.domain.TableUtils").DeepEqual
local Gateway = require("server.dao.ServerCloudGateway")
local Repo = require("server.repositories.PlayerProfileRepository")
local Profile = require("server.services.PlayerProfileService")
local Factory = require("server.domain.StateFactory")
local Rewards = require("server.domain.RewardEngine")
local Engine = require("server.domain.GameEngine")
local Schema = require("shared.GameStateSchema")
local Policy = require("shared.GameStatePolicy")
local Catalog = require("server.domain.Catalog")
local Rules = require("shared.TowerRules")
local Drops = require("shared.RewardPolicy")
local Progression = require("shared.GameProgression")
local Balance = require("shared.GameBalance")
local Large = require("shared.LargeNumber")
local Adapter = require("client.GameStateAdapter")
local env = Fixture.New()
local function instance()
    local repository = Repo.New { gateway = Gateway.New(env.cloud), clock = function() return env.now end }
    return Profile.New { repository = repository, clock = function() return env.now end }
end
local function attach(profile, uid, generation)
    local result
    profile:Load(uid, function(r) result = r end)
    assert(result and result.ok, result and result.reason)
    profile:Attach(uid, {}, generation or 1, result.data)
    profile:MarkReady(uid, generation or 1)
    return result
end
local function preview(profile, uid)
    local result; profile:PreviewOffline(uid, function(r) result = r end)
    return assert(result)
end
local function claim(profile, uid, token)
    local result; profile:ClaimOffline(uid, token, function(r) result = r end)
    return result
end
local function detach(profile, uid, generation)
    assert(profile:MarkDisconnected(uid, generation))
    local result; profile:TouchAndDetach(uid, generation, function(r) result = r end)
    return result
end

assert(Balance.OFFLINE_RATE == 0.10 and Drops.OFFLINE_RATE == Balance.OFFLINE_RATE
    and Catalog.OFFLINE_REWARD_RATE == Balance.OFFLINE_RATE and Rules.OFFLINE_REWARD_RATE == Balance.OFFLINE_RATE)
assert(Policy.OFFLINE_MAX_SECONDS == 86400 and require("server.ServerConfig").OFFLINE_MAX_SECONDS == 86400)

-- Real cloud load -> profile attach -> network snapshot -> client view. The
-- runtime-only proposal must survive WITHOUT a login write, and use the old CAS baseline.
local first = instance(); attach(first, 91001)
assert(detach(first, 91001, 1).ok)
local oldCloud = Copy(env.score(91001, Repo.Keys.PROFILE))
env:advance(3600)
local second = instance()
local commits = env.calls.Commit
local loaded = attach(second, 91001)
assert(env.calls.Commit == commits, "offline accrual must not add a blocking login cloud write")
assert(loaded.data.state.pendingOfflineSeconds == 3600 and loaded.data.offlineAccrualPending)
assert(loaded.data.persistedState.lastActiveAt == oldCloud.lastActiveAt)
assert(loaded.data.state.revision == loaded.data.persistedState.revision)
assert(Schema.ValidateState(second:GetState(91001)))
assert(Adapter.ApplySnapshot(Schema.BuildSnapshot(second:Snapshot(91001, false))))
assert(Adapter.GetViewState().pendingOfflineSeconds == 3600 and Adapter.GetViewState().offlineSeconds == 3600)
local same = Engine.AccrueOffline(second:GetState(91001), env.now)
assert(same.state.pendingOfflineSeconds == 3600, "same timestamp cannot accrue twice")
local quote = preview(second, 91001)
assert(quote.ok and quote.data.preview.seconds == 3600 and quote.data.preview.rewardRate == 0.10)
assert(Equal(quote.data, preview(second, 91001).data), "repeat preview must retain the frozen items and token")

-- A rejected transaction retains both seconds and frozen results, then persists once.
local before = Copy(second:GetState(91001))
env.failProfile = true
assert(not claim(second, 91001, quote.data.quoteToken).ok)
assert(Equal(before, second:GetState(91001)))
assert(Equal(quote.data, preview(second, 91001).data))
local paid = claim(second, 91001, quote.data.quoteToken)
assert(paid.ok and second:GetState(91001).pendingOfflineSeconds == 0)
local paidState = Copy(second:GetState(91001))
assert(claim(second, 91001, quote.data.quoteToken).ok)
assert(Equal(paidState, second:GetState(91001)), "duplicate claim cannot mint currency/items")
local restarted = instance(); attach(restarted, 91001)
assert(restarted:GetState(91001).pendingOfflineSeconds == 0)
assert(not preview(restarted, 91001).ok)
env:advance(900)
assert(detach(restarted, 91001, 1).ok)
assert(not detach(second, 91001, 1).ok, "stale instance cannot overwrite newer delivery/save")

-- Threshold, cap and carrying an unclaimed interval through a checkpoint/restart.
for _, seconds in ipairs({ 0, 899, 900, 13 * 3600, 86400, 172800 }) do
    local p = instance(); local uid = 92000 + seconds
    attach(p, uid); assert(detach(p, uid, 1).ok); env:advance(seconds)
    p = instance(); attach(p, uid)
    local expected = seconds < 900 and 0 or math.min(86400, seconds)
    assert(p:GetState(uid).pendingOfflineSeconds == expected)
    assert((preview(p, uid).ok) == (expected >= 900))
    assert(detach(p, uid, 1).ok)
    env:advance(900)
    local nextInstance = instance(); attach(nextInstance, uid)
    assert(nextInstance:GetState(uid).pendingOfflineSeconds == math.min(86400, expected + 900))
end

-- Retained sessions can resume while a checkpoint is still in flight. Its old
-- callback must not drop the new generation or erase the offline interval.
local resume = instance(); attach(resume, 93001)
env:advance(60); env.pause = true
assert(resume:MarkDisconnected(93001, 1))
local checkpoint; resume:TouchAndDetach(93001, 1, function(r) checkpoint = r end)
env:advance(1800)
local session = resume:Resume(93001, {}, 2)
assert(session.writing and session.generation == 2)
env:flush()
assert(checkpoint.code == "STALE_SESSION" and resume:GetSession(93001) == session)
assert(session.state.pendingOfflineSeconds == 1800 and session.offlineLedger)
assert(resume:MarkReady(93001, 2))
env:advance(1800)
resume:Resume(93001, {}, 3)
assert(session.state.pendingOfflineSeconds == 1800, "online connection replacement is not offline time")
assert(not resume:MarkDisconnected(93001, 2), "old disconnect cannot clear the new connection")

-- Lost successful callbacks are reconciled from cloud, never blindly replayed.
local uncertain = instance(); attach(uncertain, 94001)
assert(detach(uncertain, 94001, 1).ok); env:advance(900)
uncertain = instance(); attach(uncertain, 94001)
local q = preview(uncertain, 94001)
env.dropCommit = true
local response; uncertain:ClaimOffline(94001, q.data.quoteToken, function(r) response = r end)
env:advance(10); uncertain:Update()
assert(response.code == "WRITE_UNCONFIRMED" and uncertain:GetSession(94001).writeBlocked)
env:advance(5); uncertain:Update()
assert(not uncertain:GetSession(94001).writeBlocked and uncertain:GetState(94001).pendingOfflineSeconds == 0)
local reconciled = Copy(uncertain:GetState(94001))
env.lost[#env.lost]()
assert(Equal(reconciled, uncertain:GetState(94001)), "late callback must not replace reconciled state")

-- A lost FAILED callback must keep runtime accrual that was never in cloud.
local rollback = instance(); attach(rollback, 95001)
assert(detach(rollback, 95001, 1).ok); env:advance(900)
rollback = instance(); attach(rollback, 95001)
q = preview(rollback, 95001)
env.failProfile, env.dropCommit = true, true
rollback:ClaimOffline(95001, q.data.quoteToken, function(r) response = r end)
env:advance(10); rollback:Update()
assert(response.code == "WRITE_UNCONFIRMED")
env.lost[#env.lost]() -- provide definitive transaction failure evidence
env:advance(5); rollback:Update()
assert(not rollback:GetSession(95001).writeBlocked and rollback:GetState(95001).pendingOfflineSeconds == 900)
assert(Equal(q.data, preview(rollback, 95001).data))
assert(claim(rollback, 95001, q.data.quoteToken).ok)

-- Experience is scaled ONCE, including crossing level 100 and sub-point XP.
for _, level in ipairs({ 1, 20, 99, 100 }) do
    local a = Factory.Create(env.now); a.level = level; a.exp = level == 99 and Progression.NextExp(level) - 1 or 0
    local b = Copy(a)
    local xa = Progression.TrainingExp(a, 86400, true)
    local xb = Progression.TrainingExp(b, 8640, false)
    Progression.AddExperience(a, xa, env.now); Progression.AddExperience(b, xb, env.now)
    assert(a.level == b.level and a.exp == b.exp and a.growth.masteryExp == b.growth.masteryExp)
    assert(Equal(a.fragments, b.fragments) and math.abs(a.growth.trainingFraction - b.growth.trainingFraction) < 1e-7)
end
for _, kind in ipairs({ "normal", "elite", "boss", "chapterBoss" }) do
    assert(math.abs(Drops.DropChance(kind, true) - Drops.DropChance(kind, false) * 0.10) < 1e-12)
end
local batch = Factory.Create(env.now); batch.level = 50; batch.floor = 50; batch.maxFloor = 50
batch.pendingOfflineSeconds = 900
local ledger = assert(Rewards.FreezeOfflineReward(batch, env.now, function() return 0.99 end))
local expectedGold = Large.Zero()
local counts = { normal = 0, elite = 0, chapterBoss = 0 }
for i = 1, 75 do
    local room = (i - 1) % 10 + 1
    if not Rules.GetEncounter(room, 50).isInteractive then
        local kind = room <= 7 and "normal" or (room <= 9 and "elite" or "chapterBoss")
        counts[kind] = counts[kind] + 1
        expectedGold = Large.Add(expectedGold, Large.MultiplyScalar(Catalog.GetBattleGold(50, kind), 0.10))
    end
end
assert(Large.Compare(ledger.gold, expectedGold) == 0, "batch gold uses the 10% factor once")
assert(ledger.rewardPity.mythMisses < counts.chapterBoss, "offline pity cannot advance at full online speed")

-- Full bags keep time. A partially full bag consumes only a bounded prefix;
-- space lost after preview cannot discard frozen equipment or consume time.
local function fill(state, count, target)
    target = target or state.inventory
    while #target < count do
        local item = Copy(state.inventory[1])
        item.id = string.format("00000000-0000-4000-8000-%012x",
            (target == state.inventory and 10000 or 20000) + #target)
        target[#target + 1] = item
    end
end
local full = Factory.Create(env.now); full.pendingOfflineSeconds = 86400
fill(full, Catalog.GetInventoryCapacity(full))
local missing, code = Rewards.FreezeOfflineReward(full, env.now, function() return 0.5 end)
assert(not missing and code == "INVENTORY_FULL" and full.pendingOfflineSeconds == 86400)
table.remove(full.inventory)
local partial = assert(Rewards.FreezeOfflineReward(full, env.now, function() return 0.5 end))
assert(partial.reward.interrupted and partial.seconds < 86400 and #partial.items == 1)
local partlyPaid = Rewards.ClaimOfflineReward(full, partial, env.now)
assert(partlyPaid.ok and partlyPaid.state.pendingOfflineSeconds == 86400 - partial.seconds)
assert(partlyPaid.state.pendingOfflineSeconds > 0 and partlyPaid.delta.events[1])
assert(Schema.ValidateState(partlyPaid.state))

local space = Factory.Create(env.now); space.pendingOfflineSeconds = 86400
local locked = assert(Rewards.FreezeOfflineReward(space, env.now, function() return 0.99 end))
assert(#locked.items > Policy.TEMPORARY_LOOT_CAP)
fill(space, Catalog.GetInventoryCapacity(space)); fill(space, Policy.TEMPORARY_LOOT_CAP, space.overflowLoot)
local refused = Rewards.ClaimOfflineReward(space, locked, env.now)
assert(not refused.ok and refused.error.code == "INVENTORY_FULL" and space.pendingOfflineSeconds == 86400)
space.inventory, space.overflowLoot, space.equipped = {}, {}, {}
local recovered = Rewards.ClaimOfflineReward(space, locked, env.now)
assert(recovered.ok and #recovered.state.inventory == #locked.items and recovered.state.pendingOfflineSeconds == 0)
assert(Schema.ValidateState(recovered.state))
print("offline_delivery: PASS")
