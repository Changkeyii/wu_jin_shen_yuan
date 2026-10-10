local F = require("server.domain.StateFactory")
local E = require("server.domain.AdGiftEngine")
local T = require("server.domain.PlayerTransition")
local C = require("server.domain.CombatEngine")
local Catalog = require("server.domain.Catalog")
local Large = require("shared.LargeNumber")
local Big = require("shared.BigNumber")
local Schema = require("shared.GameStateSchema")
local now = 1791450000
local function fresh()
    local s = F.Create(now); s.tutorial = { completed = true, step = 6 }; return s
end
local function same(a,b) assert(Large.Compare(a,b) == 0) end
local s = fresh()
local weapon = T.FindItem(s, s.equipped.weapon)
for _, enhance in ipairs({ 0, 20, 100, 999 }) do
    weapon.enhance = enhance
    local cost = Catalog.GetStrengthenCost(weapon, enhance)
    local q = E.List(s, now).forge
    local expected = Large.MultiplyRatio(cost.gold, 1, 2)
    local cap = Large.MultiplyScalar(Catalog.GetBattleGold(s.floor, "normal"), 15)
    same(q.gold, Large.Compare(expected, cap) > 0 and cap or expected)
    assert(q.fragments == math.max(5, math.min(80, math.floor(cost.fragments / 2))))
end
weapon.enhance = 0
s.gold, s.fragments = Large.FromNumber(100000000), Large.FromNumber(100000000)
local p = E.Prepare(s, "forge", now)
assert(p.ok and p.state.rewardClaims.gifts.quote.benefit:find("足够强化1次", 1, true))
local saved = Schema.ToPersistedState(p.state)
assert(Schema.ValidateState(saved))
assert(T.Copy(saved, now).rewardClaims.gifts.quote.benefit == p.state.rewardClaims.gifts.quote.benefit)
s.gold, s.fragments = Large.Zero(), Large.Zero()
weapon.enhance = 100
p = E.Prepare(s, "forge", now)
assert(p.ok and p.state.rewardClaims.gifts.quote.benefit:find("后续", 1, true), "max-enhanced gear must offer materials without promising another upgrade")

s = fresh()
E.OnBossVictory(s, Large.FromNumber(101), {})
same(s.rewardClaims.gifts.offers.boss.gold, 101)
E.OnOffline(s, { gold = Large.FromNumber(1001), fragments = 21 }, {})
same(s.rewardClaims.gifts.offers.offline.gold, 500)
assert(s.rewardClaims.gifts.offers.offline.fragments == 10)
E.OnDecompose(s, 3, {})
assert(s.rewardClaims.gifts.offers.recycle.fragments == 1)
for n = 2, 400 do
    s.floor, s.maxFloor, s.revision = n, n, n
    E.OnBossVictory(s, 100, {})
    if n % 10 == 0 then
        local gift = s.rewardClaims.gifts.offers.journey
        assert(gift.fragments == math.min(200, 30 + (n / 10 - 1) * 5))
        same(gift.gold, Large.MultiplyScalar(Catalog.GetBattleGold(n, "boss"), 5))
        s.rewardClaims.gifts.offers.journey = nil
    end
end

-- An already frozen pre-update quote pays exactly its original amount.
s = fresh()
s.rewardClaims.gifts.quote = { id = "gift.1", kind = "offline", reward = { gold = Large.FromNumber(25), fragments = 5, jars = 0, boosts = 0 } }
s.rewardClaims.gifts.nextId = 2
local before = s.gold
p = E.Prepare(s, "offline", now)
same(p.state.rewardClaims.gifts.quote.reward.gold, 25)
local claimed = E.Claim(p.state, "gift.1", now)
same(claimed.state.gold, Large.Add(before, 25))
assert(E.Claim(claimed.state, "gift.1", now).commit.kind == "none")

local function incoming(state)
    local events = {}
    state.currentMonster.nextMonsterAttackSeconds = 0
    state.currentMonster.phaseRemaining = 1
    state.hpBig, state.hp = Big.FromNumber(10000000), 10000000
    C.AdvanceActiveCombat(state, function() return 0.99 end, now, 0, events, {}, {
        handlePlayerDeath = function() error("unexpected death") end,
    })
    for _, event in ipairs(events) do if event.kind == "player_damaged" then return event.amountBig end end
    error("missing damage event")
end
s = fresh(); s.position = 10
s.rewardClaims.gifts.boostCharges = 1
C.BeginBattle(s, "boss", function() return 0.99 end, {})
assert(s.rewardClaims.gifts.boostActive and s.rewardClaims.gifts.boostCharges == 0)
s.currentMonster.atkBig = Big.FromNumber(10000)
s.stats.def, s.stats.defBig = 0, Big.Zero()
s.stats.damageReduction = 0.5
local boosted = T.Copy(s, now)
-- Restore fixed combat fixture values after normalization derives equipment stats.
boosted.stats = s.stats
local reduced = incoming(boosted)
s.rewardClaims.gifts.boostActive = false
local normal = incoming(s)
assert(Big.Compare(reduced, Big.FromNumber(4250)) == 0)
assert(Big.Compare(normal, Big.FromNumber(5000)) == 0, "15% reduction multiplies existing reduction")
s.rewardClaims.gifts.boostActive = true
s.currentMonster.abyssSource = "random"
assert(Big.Compare(incoming(s), normal) == 0, "tower boost never leaks into abyss")
s.currentMonster.abyssSource = nil
s.currentMonster.encounter = "normal"
assert(Big.Compare(incoming(s), normal) == 0, "no reduction against ordinary monsters")
s.currentMonster.encounter = "boss"
s.stats.atk, s.stats.atkBig = 10000, Big.FromNumber(10000)
s.stats.damageBonus, s.stats.bossDamage, s.stats.trueDamageRate, s.stats.crit = 0, 0, 0, 0
s.currentMonster.def, s.currentMonster.defBig = 0, Big.Zero()
local hit = C.PlayerHitDamage(s, s.currentMonster, 1, function() return 0.99 end)
assert(Big.Compare(hit, Big.FromNumber(13000)) == 0)
E.OnLoss(s, s.currentMonster, {})
assert(not s.rewardClaims.gifts.boostActive)
s.rewardClaims.gifts.boostActive = true
E.OnBossVictory(s, 100, {})
assert(not s.rewardClaims.gifts.boostActive)
local dialog
package.loaded["urhox-libs/UI"] = {}
package.loaded["client.CommonPromptDialog"] = {}
package.loaded["client.ViewKit"] = { FormatInt = tostring }
package.loaded["client.ViewAssets"] = { ASSETS = { items = { gold = "gold", crystal = "fragment" } } }
package.loaded["client.Theme"] = {}
package.loaded["client.RewardDialogView"] = {
    AddCard = function(cards, _, title, count) cards[#cards + 1] = { title = title, count = count } end,
    Show = function(options) dialog = options; return true end,
}
local View = require("client.AdGiftView")
View.Reward(p.state.rewardClaims.gifts.quote)
assert(dialog.lines[1]:find("更新前", 1, true), "legacy quote never promises the new percentage")
local prepared = E.Prepare(fresh(), "forge", now)
View.Reward(prepared.state.rewardClaims.gifts.quote)
assert(dialog.lines[1]:find("50%", 1, true) and dialog.lines[2] == prepared.state.rewardClaims.gifts.quote.benefit)
View.Reward({ kind = "retry", reward = require("shared.AdGiftDefinitions").Reward { boosts = 1 } })
assert(dialog.lines[1]:find("攻击+30%", 1, true) and dialog.lines[1]:find("降低15%", 1, true))
assert(dialog.cards[1].title == "首领攻防助力")
print("ad_gift_value: PASS (six rewards, caps, growing milestones, frozen quotes, exact attack/reduction, scope/expiry)")
