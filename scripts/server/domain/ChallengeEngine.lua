-- ChallengeEngine.lua
-- 深渊 Boss 限时挑战：扣票开场、服务端权威伤害、击杀走深渊结算、失败只给安慰奖。
-- 打桩个人最佳由 ActivityEngine 写入 challenges，本引擎只负责 Boss 会话。

local AbyssDefinitions = require("shared.AbyssDefinitions")
local ChallengeDefinitions = require("shared.ChallengeDefinitions")
local PlayerTransition = require("server.domain.PlayerTransition")
local CombatEngine = require("server.domain.CombatEngine")
local AbyssEngine = require("server.domain.AbyssEngine")
local Catalog = require("server.domain.Catalog")
local EquipmentEngine = require("server.domain.EquipmentEngine")
local DomainMath = require("server.domain.DomainMath")
local BigNumber = require("shared.BigNumber")
local TowerRules = require("shared.TowerRules")
local CombatSequence = require("shared.CombatSequence")

local ChallengeEngine = {}

local BOSS = ChallengeDefinitions.BOSS

local function ensureState(state)
    state.challenges = type(state.challenges) == "table"
        and state.challenges or ChallengeDefinitions.NewState()
    return state.challenges
end

local function activeSession(challenges)
    local session = type(challenges.bossSession) == "table" and challenges.bossSession or nil
    if not session or session.finished == true then return nil end
    return session
end

local function playerAtk(state)
    local stats = type(state.stats) == "table" and state.stats or {}
    local atk = DomainMath.StatMagnitude(stats, "atk")
    local number = BigNumber.ToNumber(atk)
    if type(number) == "number" and number == number and number > 0 then
        return math.max(1, math.floor(number))
    end
    return math.max(1, math.floor(tonumber(stats.atk) or 1))
end

function ChallengeEngine.ComputeBossHp(state, gradeId)
    local mul = ChallengeDefinitions.BossHpMul(gradeId)
    -- The existing scene plays full A/B/C animations. INTERVAL is a request
    -- throttle, not its attack speed; using it made the normal Boss unreachable.
    local expectedHits, elapsed, index = 0, 0, 1
    while elapsed < BOSS.DURATION do
        local sequence = CombatSequence.Get(index)
        ---@type number[]
        local hitFrames = sequence.hitFrames
        local windup = (hitFrames[1] - 1) / sequence.fps
        if elapsed + windup >= BOSS.DURATION then break end
        expectedHits = expectedHits + 1
        elapsed = elapsed + sequence.endFrame / sequence.fps + 0.15
        index = index % 3 + 1
    end
    local hp = math.floor(playerAtk(state) * 2.0 * expectedHits * mul)
    return ChallengeDefinitions.ClampScore(math.max(1000, hp))
end

local function recordBest(challenges, damage, now, gradeId, killed)
    challenges.lastBossDamage = ChallengeDefinitions.ClampScore(damage)
    challenges.lastBossAt = PlayerTransition.Now(now)
    challenges.lastBossGrade = AbyssDefinitions.IsKnownGrade(gradeId) and gradeId or "rift"
    challenges.lastBossKilled = killed == true
    if challenges.lastBossDamage > (challenges.bestBossDamage or 0) then
        challenges.bestBossDamage = challenges.lastBossDamage
        return true
    end
    return false
end

local function strikeDamage(working)
    local sequenceIndex = math.random(1, 3)
    local sequence = TowerRules.AttackSequence(sequenceIndex)
    local weights = sequence and sequence.weights or { 1.0 }
    local totalDamage = 0
    local lastCritical = false
    local lastLucky = false
    for _, weight in ipairs(weights) do
        local damage, critical, lucky = CombatEngine.PlayerHitDamage(working, {
            encounter = "boss",
            def = 0,
            defBig = BigNumber.Zero(),
        }, weight, nil)
        totalDamage = totalDamage + math.max(1, math.floor(BigNumber.ToNumber(damage) or 0))
        if critical then lastCritical = true end
        if lucky then lastLucky = true end
    end
    return ChallengeDefinitions.ClampScore(totalDamage), lastCritical, lastLucky
end

function ChallengeEngine.BeginBoss(inputState, gradeId, now)
    now = PlayerTransition.Now(now)
    local current = inputState.challenges and activeSession(inputState.challenges)
    if current then
        if current.gradeId == gradeId then
            return PlayerTransition.NoCommit(inputState, now, "abyss_boss_resumed", {})
        end
        return PlayerTransition.Failure(inputState, now, "BOSS_ALREADY_STARTED", "请先结束当前深渊挑战")
    end
    local grade = AbyssDefinitions.Get(gradeId)
    if not grade then
        return PlayerTransition.Failure(inputState, now, "INVALID_ABYSS_GRADE", "未知深渊档位")
    end
    if not AbyssDefinitions.IsUnlocked(gradeId, inputState.level) then
        return PlayerTransition.Failure(
            inputState,
            now,
            "ABYSS_GRADE_LOCKED",
            string.format("该深渊需达到 Lv.%d", grade.minLevel)
        )
    end
    if #inputState.inventory >= Catalog.GetInventoryCapacity(inputState)
        and not EquipmentEngine.HasAutoDispositionPolicy(inputState)
    then
        return PlayerTransition.Failure(
            inputState,
            now,
            "INVENTORY_FULL",
            "背包已满，请先分解、出售或点击容量后的 +50 扩容"
        )
    end

    local ticketCost = AbyssDefinitions.TicketCost(inputState.level, gradeId)
    local currentTickets = inputState.abyss and inputState.abyss.tickets
        or AbyssDefinitions.STARTER_TICKETS
    if currentTickets < ticketCost then
        return PlayerTransition.Failure(
            inputState,
            now,
            "ABYSS_TICKET_INSUFFICIENT",
            string.format("深渊票不足，需要 %d 张", ticketCost)
        )
    end

    local working = PlayerTransition.Copy(inputState, now)
    local challenges = ensureState(working)
    local abyss = working.abyss
    if type(abyss) ~= "table" then
        working.abyss = AbyssDefinitions.NewState()
        abyss = working.abyss
    end
    if abyss.tickets < ticketCost then
        return PlayerTransition.Failure(
            inputState,
            now,
            "ABYSS_TICKET_INSUFFICIENT",
            string.format("深渊票不足，需要 %d 张", ticketCost)
        )
    end
    abyss.tickets = abyss.tickets - ticketCost

    local maxHp = ChallengeEngine.ComputeBossHp(working, gradeId)
    local runId = AbyssEngine.MakeRunId(working, "boss", now)
    challenges.bossSession = {
        runId = runId,
        gradeId = gradeId,
        ticketCost = ticketCost,
        startedAt = now,
        lastHitAt = 0,
        damage = 0,
        hp = maxHp,
        maxHp = maxHp,
        finished = false,
    }
    challenges.bossRuns = (challenges.bossRuns or 0) + 1

    local events = {
        PlayerTransition.Event("abyss_boss_begin", {
            runId = runId,
            gradeId = gradeId,
            ticketCost = ticketCost,
            maxHp = maxHp,
            remaining = BOSS.DURATION,
        }),
    }
    print(string.format(
        "[Challenge] begin boss grade=%s cost=%d hp=%d tickets=%d",
        gradeId,
        ticketCost,
        maxHp,
        abyss.tickets
    ))
    return PlayerTransition.Finalize(inputState, working, now, "abyss_boss_begin", events, false, false)
end

function ChallengeEngine.StrikeBoss(inputState, now)
    now = PlayerTransition.Now(now)
    local working = PlayerTransition.Copy(inputState, now)
    local challenges = ensureState(working)
    local session = activeSession(challenges)
    if not session then
        return PlayerTransition.Failure(inputState, now, "BOSS_NOT_STARTED", "深渊 Boss 尚未开始")
    end
    local elapsed = now - (session.startedAt or now)
    if elapsed >= BOSS.DURATION then
        return ChallengeEngine.FinishBoss(inputState, now)
    end
    if (now - (session.lastHitAt or 0)) < BOSS.INTERVAL then
        return PlayerTransition.NoCommit(inputState, now, "boss_too_fast", {})
    end
    session.lastHitAt = now
    local hitDamage, critical, lucky = strikeDamage(working)
    session.damage = ChallengeDefinitions.ClampScore((session.damage or 0) + hitDamage)
    session.hp = math.max(0, (session.hp or 0) - hitDamage)
    local events = {
        PlayerTransition.Event("abyss_boss_hit", {
            runId = session.runId,
            gradeId = session.gradeId,
            damage = hitDamage,
            critical = critical,
            lucky = lucky,
            total = session.damage,
            hp = session.hp,
            maxHp = session.maxHp,
        }),
    }
    if session.hp <= 0 then
        return ChallengeEngine.FinishBoss(working, now, inputState, events)
    end
    return PlayerTransition.Finalize(inputState, working, now, "abyss_boss_hit", events, false, false)
end

function ChallengeEngine.FinishBoss(inputState, now, previousState, pendingEvents)
    now = PlayerTransition.Now(now)
    local previous = previousState or inputState
    local working = PlayerTransition.Copy(inputState, now)
    local challenges = ensureState(working)
    local session = activeSession(challenges)
    if not session then
        return PlayerTransition.NoCommit(inputState, now, "boss_not_active", {})
    end

    local damage = ChallengeDefinitions.ClampScore(session.damage)
    local killed = (session.hp or 0) <= 0 or damage >= (session.maxHp or 0)
    local events = pendingEvents or {}
    local inventoryChanged = false

    if killed then
        local settled, code, reason, changed = AbyssEngine.SettleWorking(
            working,
            "boss",
            session.gradeId,
            session.ticketCost or 0,
            session.runId,
            nil,
            now,
            events
        )
        if not settled then
            return PlayerTransition.Failure(previous, now, code, reason)
        end
        inventoryChanged = changed == true
        challenges = ensureState(working)
        challenges.bossKills = (challenges.bossKills or 0) + 1
    else
        local grade = AbyssDefinitions.Get(session.gradeId)
        local fragments = math.max(1, math.floor((grade and grade.fragments or 0) * BOSS.FAIL_FRAGMENT_RATE))
        PlayerTransition.AddCurrency(working, "fragments", fragments)
        local abyss = working.abyss
        if type(abyss) == "table" then
            abyss.dryStreak = math.min(
                AbyssDefinitions.HARD_PITY_ATTEMPT - 1,
                (abyss.dryStreak or 0) + 1
            )
        end
        events[#events + 1] = PlayerTransition.Event("abyss_boss_failed", {
            runId = session.runId,
            gradeId = session.gradeId,
            ticketCost = session.ticketCost or 0,
            damage = damage,
            maxHp = session.maxHp or 0,
            fragments = fragments,
        })
    end

    challenges = ensureState(working)
    local ranked = recordBest(challenges, damage, now, session.gradeId, killed)
    challenges.bossSession = nil
    events[#events + 1] = PlayerTransition.Event("abyss_boss_finished", {
        runId = session.runId,
        gradeId = session.gradeId,
        ticketCost = session.ticketCost or 0,
        damage = damage,
        maxHp = session.maxHp or 0,
        killed = killed,
        ranked = ranked,
        bestDamage = challenges.bestBossDamage or 0,
    })
    print(string.format(
        "[Challenge] finish boss grade=%s killed=%s damage=%d best=%d",
        tostring(session.gradeId),
        tostring(killed),
        damage,
        challenges.bestBossDamage or 0
    ))
    return PlayerTransition.Finalize(
        previous,
        working,
        now,
        killed and "abyss_completed" or "abyss_boss_finished",
        events,
        inventoryChanged,
        false
    )
end

return ChallengeEngine
