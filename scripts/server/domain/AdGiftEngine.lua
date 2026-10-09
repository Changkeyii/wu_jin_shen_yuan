local D = require("shared.AdGiftDefinitions")
local LargeNumber = require("shared.LargeNumber")
local Catalog = require("server.domain.Catalog")
local T = require("server.domain.PlayerTransition")
local TableUtils = require("server.domain.TableUtils")
local Wish = require("shared.WishPoolDefinitions")
local E = {}

local function active(state)
    return state.tutorial and state.tutorial.completed == true
end
local function gifts(state)
    local old = state.rewardClaims.gifts
    if not old or old.version ~= D.VERSION then
        state.rewardClaims.gifts = D.Normalize(old, math.max(0, (state.maxFloor or state.floor or 1) - 1))
        state.rewardClaims.gifts.highestFloor = math.max(0, (state.maxFloor or state.floor or 1) - 1)
    end
    return state.rewardClaims.gifts
end
local function merge(a, b)
    a, b = D.Reward(a), D.Reward(b)
    return D.Reward { gold = LargeNumber.Add(a.gold, b.gold), fragments = a.fragments + b.fragments,
        jars = a.jars + b.jars, boosts = math.min(1, a.boosts + b.boosts), tickets = a.tickets + b.tickets }
end
local function offer(state, kind, reward, events, eventId)
    if not active(state) then return end
    local g = gifts(state)
    eventId = tostring(eventId or (tostring(state.revision or 0) .. ":" .. tostring(#events)))
    if g.lastEvents[kind] == eventId then return end
    g.lastEvents[kind] = eventId
    g.offers[kind] = merge(g.offers[kind], reward)
    events[#events + 1] = T.Event("ad_gift_available", { giftKind = kind })
end

function E.OnDecompose(state, baseFragments, events)
    if baseFragments >= 2 then
        offer(state, "recycle", { fragments = math.floor(baseFragments / 2) }, events)
    end
end
function E.OnOffline(state, reward, events)
    local bonus = D.Reward { gold = LargeNumber.MultiplyRatio(reward.gold, 1, 2),
        fragments = math.floor((reward.fragments or 0) / 2) }
    if not LargeNumber.IsZero(bonus.gold) or bonus.fragments > 0 then offer(state, "offline", bonus, events) end
end
function E.OnBossVictory(state, gold, events)
    if not active(state) then return end
    local g = gifts(state)
    g.boostActive = false
    g.losses, g.lossFloor = 0, 0
    offer(state, "boss", { gold = gold }, events)
    local floor = math.max(1, state.floor or 1)
    if floor > g.luckyHighest then
        g.luckyHighest = floor
        if floor % D.LUCKY_INTERVAL == 0 then
            offer(state, "lucky", { tickets = D.LUCKY_TICKETS }, events, "lucky:" .. tostring(floor))
        end
    end
    if floor > g.highestFloor then
        g.highestFloor = floor
        g.floors = g.floors + 1
        if g.floors % 10 == 0 then
            offer(state, "journey", { gold = LargeNumber.MultiplyScalar(Catalog.GetBattleGold(floor, "boss"), 5),
                fragments = D.JourneyFragments(floor) }, events, "journey:" .. tostring(g.floors))
        end
    end
end
function E.OnLoss(state, monster, events)
    if not active(state) then return end
    local g = gifts(state)
    g.boostActive = false
    if monster.abyssSource or (monster.encounter ~= "boss" and monster.encounter ~= "chapterBoss") then
        g.losses, g.lossFloor = 0, 0
        return
    end
    g.losses = g.lossFloor == state.floor and g.losses + 1 or 1
    g.lossFloor = state.floor
    if g.losses >= 2 and g.boostCharges == 0 and not g.offers.retry
        and not (g.quote and g.quote.kind == "retry") then
        offer(state, "retry", { boosts = 1 }, events)
    end
end
function E.BeginBattle(state, monster, context)
    local g = gifts(state)
    g.boostActive = false
    if context and context.offline then return end
    if active(state) and not monster.abyssSource and g.boostCharges > 0
        and (monster.encounter == "boss" or monster.encounter == "chapterBoss") then
        g.boostCharges = g.boostCharges - 1
        g.boostActive = true
        g.losses = 0
    end
end

function E.List(state, now)
    if not active(state) then return {} end
    local available = TableUtils.DeepCopy(gifts(state).offers)
    local g = gifts(state)
    local used = g.wishDay == Wish.DayKey(now or os.time()) and g.wishUsed or 0
    if used < D.WISH_DAILY_LIMIT then available.wishSupply = D.Reward { tickets = used + 1 } end
    if available.lucky then
        available.lucky = available.lucky.tickets >= D.LUCKY_TICKETS and D.Reward { tickets = D.LUCKY_TICKETS } or nil
    end
    local weapon = T.FindItem(state, state.equipped.weapon)
    local cost = Catalog.GetStrengthenCost(weapon or { slot = "weapon", rarity = "common", level = 1 }, weapon and weapon.enhance or 0)
    -- 固定一份当前阶段材料，不根据余额补差；预览和领取冻结为同一份奖励。
    local gold = LargeNumber.MultiplyRatio(cost.gold, 1, 2)
    local cap = LargeNumber.MultiplyScalar(Catalog.GetBattleGold(state.floor, "normal"), 15)
    if LargeNumber.Compare(gold, cap) > 0 then gold = cap end
    available.forge = D.Reward { gold = gold, fragments = math.max(5, math.min(80, math.floor(cost.fragments / 2))) }
    if gifts(state).boostCharges > 0 then available.retry = nil end
    if g.quote and (g.quote.kind ~= "wishSupply" or g.quote.day == Wish.DayKey(now or os.time())) then
        available[g.quote.kind] = D.Reward(g.quote.reward)
    end
    return available
end
function E.Prepare(inputState, kind, now)
    local working = T.Copy(inputState, now)
    local g = gifts(working)
    if g.quote and g.quote.kind == kind and (kind ~= "wishSupply" or g.quote.day == Wish.DayKey(now)) then
        return T.NoCommit(inputState, now, "ad_gift_prepared")
    end
    -- A new kind releases an unconsumed quote back into the bounded per-kind balance.
    if g.quote then
        if g.quote.kind ~= "forge" and g.quote.kind ~= "wishSupply" then
            g.offers[g.quote.kind] = merge(g.offers[g.quote.kind], g.quote.reward)
        end
        g.quote = nil
    end
    local day = Wish.DayKey(now)
    if g.wishDay ~= day then g.wishDay, g.wishUsed = day, 0 end
    local available = E.List(working, now)
    if not D.KINDS[kind] or not available[kind] then
        return T.Failure(inputState, now, "AD_GIFT_LOCKED",
            kind == "wishSupply" and active(working) and "今日许愿补给已领完，明日零点刷新" or "尚未满足礼包条件")
    end
    g.quote = { id = "gift." .. tostring(g.nextId), kind = kind, reward = D.Reward(available[kind]) }
    g.quote.ruleVersion = D.REWARD_RULE_VERSION
    if kind == "forge" then
        local weapon = T.FindItem(working, working.equipped.weapon)
        if weapon and (weapon.enhance or 0) < Catalog.MAX_ENHANCE then
            local cost = Catalog.GetStrengthenCost(weapon, weapon.enhance or 0)
            local enough = LargeNumber.Compare(LargeNumber.Add(working.gold, g.quote.reward.gold), cost.gold) >= 0
                and LargeNumber.Compare(LargeNumber.Add(working.fragments, g.quote.reward.fragments), cost.fragments) >= 0
            g.quote.benefit = enough and "按打开时的武器和余额计算：领取后材料足够强化1次。"
                or "补充当前武器强化所需的金币与碎片；本次领取后仍需积累材料。"
        else
            g.quote.benefit = "金币和碎片存入背包，可用于后续装备强化、升星。"
        end
    end
    if kind == "wishSupply" then g.quote.day = day end
    g.nextId = g.nextId + 1
    if kind == "lucky" then
        g.offers.lucky.tickets = g.offers.lucky.tickets - D.LUCKY_TICKETS
        if g.offers.lucky.tickets == 0 then g.offers.lucky = nil end
    elseif kind ~= "forge" and kind ~= "wishSupply" then g.offers[kind] = nil end
    return T.Finalize(inputState, working, now, "ad_gift_prepared", {}, false, false)
end
function E.Claim(inputState, token, now)
    local working = T.Copy(inputState, now)
    local g = gifts(working)
    local tokenId = tonumber(tostring(token):match("^gift%.(%d+)$")) or math.huge
    local claimedId = tonumber(g.lastClaim:match("^gift%.(%d+)$")) or 0
    if tokenId <= claimedId then return T.NoCommit(inputState, now, "ad_gift_already_claimed") end
    local quote = g.quote
    if not active(working) or not quote or quote.id ~= token then
        return T.Failure(inputState, now, "AD_GIFT_QUOTE_INVALID", "礼包已变更，请重新打开")
    end
    local reward = quote.reward
    -- Keep a completed video redeemable across midnight without charging tomorrow's quota.
    if quote.kind == "wishSupply" then
        if quote.day ~= g.wishDay or g.wishUsed >= D.WISH_DAILY_LIMIT or reward.tickets ~= g.wishUsed + 1 then
            return T.Failure(inputState, now, "AD_GIFT_QUOTE_INVALID", "补给记录已变更，请重新打开")
        end
        g.wishUsed = g.wishUsed + 1
    end
    T.AddCurrency(working, "gold", reward.gold)
    T.AddCurrency(working, "fragments", reward.fragments)
    working.wishPool.jars["jar.random"] = (working.wishPool.jars["jar.random"] or 0) + reward.jars
    working.wishPool.tickets = working.wishPool.tickets + (reward.tickets or 0)
    g.boostCharges = math.min(1, g.boostCharges + reward.boosts)
    g.lastClaim, g.quote = token, nil
    return T.Finalize(inputState, working, now, "ad_gift_claimed", {
        T.Event("ad_gift_claimed", { giftKind = quote.kind, token = token, reward = reward }),
    }, false, false)
end
return E
