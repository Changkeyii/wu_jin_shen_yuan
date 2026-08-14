local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local CombatSequence = require("shared.CombatSequence")
local BigNumber = require("shared.BigNumber")
local TowerRules = require("shared.TowerRules")
local PlayerTransition = require("server.domain.PlayerTransition")
local DomainMath = require("server.domain.DomainMath")

local CombatEngine = {}

local function encounterFor(room, floor, explicitType)
    room = Catalog.Clamp(TableUtils.ToInteger(room, 1), 1, 10)
    floor = math.max(1, TableUtils.ToInteger(floor, 1))
    local encounter = TowerRules.GetEncounter(room, floor) or {}
    local kind = encounter.kind or encounter.eventType
    if explicitType == "monster" or explicitType == "normal" then kind = "normal" end
    if explicitType == "elite" then kind = "elite" end
    if explicitType == "chapterBoss" then kind = "chapterBoss" end
    if explicitType == "boss" then kind = floor % 10 == 0 and "chapterBoss" or "boss" end
    if kind ~= "elite" and kind ~= "boss" and kind ~= "chapterBoss" then kind = "normal" end
    return {
        room = room,
        floor = floor,
        kind = kind,
        eventType = kind == "normal" and "monster" or (kind == "chapterBoss" and "boss" or kind),
        isBoss = kind == "boss" or kind == "chapterBoss",
        isChapterBoss = kind == "chapterBoss",
    }
end

function CombatEngine.GetMonster(state, eventType, room)
    local encounter = encounterFor(room or state.position or 1, state.floor, eventType)
    local stats = TowerRules.MonsterStats(state.floor, encounter.kind)
        or TowerRules.MonsterStats(state.floor, encounter.eventType)
        or {}
    local hpBig = DomainMath.Magnitude(stats.hpBig or stats.maxHpBig, stats.hp or stats.maxHp, 1)
    local atkBig = DomainMath.Magnitude(stats.attackBig or stats.atkBig, stats.attack or stats.atk, 0)
    local defBig = DomainMath.Magnitude(stats.defenseBig or stats.defBig, stats.defense or stats.def, 0)
    local names = {
        normal = "回廊怪物",
        elite = "深渊精英",
        boss = "第" .. state.floor .. "层守层者",
        chapterBoss = "第" .. state.floor .. "层万灵领主",
    }
    return {
        name = names[encounter.kind],
        hp = DomainMath.ProjectedMagnitude(hpBig),
        atk = DomainMath.ProjectedMagnitude(atkBig),
        def = DomainMath.ProjectedMagnitude(defBig),
        hpBig = hpBig,
        atkBig = atkBig,
        defBig = defBig,
        encounter = encounter,
    }
end

local function defendedDamage(attack, defense, growth)
    local ok, value = pcall(TowerRules.DamageAfterDefense, attack, defense, growth)
    if ok then
        if BigNumber.IsBigNumber(value) then return BigNumber.Normalize(value) end
        if type(value) == "number" and value == value and value >= 0 then
            return BigNumber.FromNumber(value)
        end
    end
    local defenseRatio = BigNumber.Ratio(defense, growth) or math.huge
    local multiplier = 100 / (100 + defenseRatio)
    return BigNumber.MultiplyScalar(attack, multiplier)
end

local function damageToMonster(state, monster, weight, rng)
    local stats = state.stats
    local attack = BigNumber.MultiplyScalar(DomainMath.StatMagnitude(stats, "atk"), weight)
    local critical = DomainMath.RandomFloat(rng) < (stats.crit or 0)
    local lucky = false
    if critical then attack = BigNumber.MultiplyScalar(attack, stats.critDmg or 1.5) end
    if (stats.luckyChance or 0) > 0 and DomainMath.RandomFloat(rng) < stats.luckyChance then
        attack = BigNumber.MultiplyScalar(attack, stats.luckyMultiplier or 1)
        lucky = true
    end
    if monster.encounter == "boss" or monster.encounter == "chapterBoss" then
        attack = BigNumber.MultiplyScalar(attack, 1 + (stats.bossDamage or 0))
    end
    attack = BigNumber.MultiplyScalar(attack, 1 + (stats.damageBonus or 0))
    attack = BigNumber.Add(attack, BigNumber.MultiplyScalar(
        DomainMath.StatMagnitude(stats, "hp"), (stats.trueDamageRate or 0) * weight))
    return DomainMath.FloorDamage(defendedDamage(
        attack,
        DomainMath.Magnitude(monster.defBig, monster.def, 0),
        TowerRules.DifficultyGrowth(state.floor))), critical, lucky
end

local function damageToPlayer(state, monster)
    local attack = BigNumber.MultiplyScalar(
        DomainMath.Magnitude(monster.atkBig, monster.atk, 0),
        monster.enraged and Catalog.BOSS_ENRAGE_DAMAGE_MULTIPLIER or 1)
    local damage = defendedDamage(
        attack, DomainMath.StatMagnitude(state.stats, "def"), TowerRules.DifficultyGrowth(state.floor))
    damage = BigNumber.MultiplyScalar(
        damage, 1 - Catalog.Clamp(state.stats.damageReduction or 0, 0, 0.70))
    return DomainMath.FloorDamage(damage)
end

local function attackDefinition(index, attackSpeed)
    local visual = CombatSequence.Get(index) or CombatSequence.Get(1)
    local rules = TowerRules.AttackSequence(index)
        or TowerRules.AttackSequence(visual.id)
        or {}
    local hitFrames = rules.hitFrames or visual.hitFrames
    local weights = rules.weights or {}
    if #weights == 0 and type(rules.hits) == "table" then
        for hitIndex, hit in ipairs(rules.hits) do
            weights[hitIndex] = hit.weight
        end
    end
    if #weights == 0 then weights = { 0.30, 0.40, 0.50, 0.80 } end
    local fps = tonumber(rules.fps) or visual.fps
    local endFrame = tonumber(rules.endFrame) or visual.endFrame
    local baseDuration = math.max(0.01, tonumber(rules.duration) or (endFrame / fps))
    local duration = math.max(0.8, baseDuration / Catalog.Clamp(tonumber(attackSpeed) or 1, 0.5, 3.0))
    local hitTimes = {}
    for hitIndex, frame in ipairs(hitFrames) do
        hitTimes[hitIndex] = Catalog.Clamp((frame - 1) / math.max(1, endFrame - 1) * duration, 0.01, duration)
    end
    return {
        sequenceIndex = index,
        sequenceId = rules.id or visual.id,
        fps = fps,
        hitFrames = hitFrames,
        weights = weights,
        hitTimes = hitTimes,
        endFrame = endFrame,
        duration = duration,
    }
end

local function randomAttack(state, monster, rng)
    local count = CombatSequence.Count()
    -- 连招链：A → B → C → 终结技(D) → 循环，按已完成攻击数取序列
    local index = (monster.attackSerial or 0) % count + 1
    local attack = attackDefinition(index, state.stats.atkSpeed)
    monster.phase = "windup"
    monster.phaseRemaining = attack.hitTimes[1]
    monster.sequenceIndex = attack.sequenceIndex
    monster.sequenceId = attack.sequenceId
    monster.fps = attack.fps
    monster.hitIndex = 1
    monster.hitFrame = attack.hitFrames[1]
    monster.endFrame = attack.endFrame
    monster.recoverySeconds = math.max(CombatSequence.MIN_PHASE_SECONDS,
        attack.duration - attack.hitTimes[#attack.hitTimes])
    monster.lastSequenceIndex = attack.sequenceIndex
    return attack
end

local function attackStartedEvent(monster, attack)
    return PlayerTransition.Event("attack_started", {
        monsterId = monster.id,
        eventType = monster.eventType,
        encounterKind = monster.encounter,
        attackSerial = monster.attackSerial,
        sequenceIndex = attack.sequenceIndex,
        sequenceId = attack.sequenceId,
        fps = attack.fps,
        hitFrames = TableUtils.DeepCopy(attack.hitFrames),
        hitWeights = TableUtils.DeepCopy(attack.weights),
        endFrame = attack.endFrame,
        durationSeconds = attack.duration,
    })
end

function CombatEngine.BeginBattle(state, eventType, rng, events)
    local generated = CombatEngine.GetMonster(state, eventType, state.position)
    local encounter = generated.encounter
    local monster = {
        id = string.format("floor:%d:room:%d", state.floor, encounter.room),
        eventType = encounter.eventType,
        encounter = encounter.kind,
        room = encounter.room,
        name = generated.name,
        hp = generated.hp,
        maxHp = generated.hp,
        atk = generated.atk,
        def = generated.def,
        hpBig = BigNumber.Clone(generated.hpBig),
        maxHpBig = BigNumber.Clone(generated.hpBig),
        atkBig = BigNumber.Clone(generated.atkBig),
        defBig = BigNumber.Clone(generated.defBig),
        isChapterBoss = encounter.isChapterBoss,
        phase = "windup",
        phaseRemaining = 0,
        attackSerial = 1,
        hitIndex = 1,
        lastSequenceIndex = 0,
        elapsedSeconds = 0,
        enraged = false,
        nextMonsterAttackSeconds = Catalog.ENEMY_ATTACK_SECONDS,
    }
    state.currentMonster = monster
    state.currentEvent = encounter.eventType
    local attack = randomAttack(state, monster, rng)
    local battleStarted = {
        monsterId = monster.id,
        eventType = monster.eventType,
        encounterKind = encounter.kind,
        room = encounter.room,
        floor = encounter.floor,
        name = monster.name,
        isChapterBoss = encounter.isChapterBoss,
    }
    DomainMath.AddMagnitudeFields(battleStarted, "monsterHp", "monsterHpBig", monster.hpBig)
    DomainMath.AddMagnitudeFields(battleStarted, "monsterMaxHp", "monsterMaxHpBig", monster.maxHpBig)
    events[#events + 1] = PlayerTransition.Event("battle_started", battleStarted)
    local spawned = {
        monsterId = monster.id,
        floor = state.floor,
        room = monster.room,
        kind = monster.encounter,
        encounterKind = monster.encounter,
        name = monster.name,
        isChapterBoss = monster.isChapterBoss,
    }
    DomainMath.AddMagnitudeFields(spawned, "hp", "hpBig", monster.hpBig)
    DomainMath.AddMagnitudeFields(spawned, "maxHp", "maxHpBig", monster.maxHpBig)
    events[#events + 1] = PlayerTransition.Event("monster_spawned", spawned)
    events[#events + 1] = attackStartedEvent(monster, attack)
end

local function resolvePlayerHit(state, monster, rng, events)
    local attack = attackDefinition(monster.sequenceIndex or 1, state.stats.atkSpeed)
    local hitIndex = Catalog.Clamp(TableUtils.ToInteger(monster.hitIndex, 1), 1, #attack.weights)
    local hitFrame = attack.hitFrames[hitIndex]
    local weight = attack.weights[hitIndex]
    local oldHp = DomainMath.Magnitude(monster.hpBig, monster.hp, 0)
    local damage, critical, lucky = damageToMonster(state, monster, weight, rng)
    local effectiveDamage = BigNumber.Min(oldHp, damage)
    DomainMath.SetMonsterMagnitude(monster, "hp", BigNumber.Subtract(oldHp, damage))
    local payload = {
        monsterId = monster.id,
        eventType = monster.eventType,
        encounterKind = monster.encounter,
        attackSerial = monster.attackSerial,
        sequenceIndex = monster.sequenceIndex,
        sequenceId = monster.sequenceId,
        hitIndex = hitIndex,
        hitFrame = hitFrame,
        weight = weight,
        critical = critical,
        lucky = lucky,
    }
    DomainMath.AddMagnitudeFields(payload, "damage", "damageBig", damage)
    DomainMath.AddMagnitudeFields(payload, "amount", "amountBig", damage)
    DomainMath.AddMagnitudeFields(payload, "effectiveDamage", "effectiveDamageBig", effectiveDamage)
    DomainMath.AddMagnitudeFields(payload, "monsterHp", "monsterHpBig", monster.hpBig)
    DomainMath.AddMagnitudeFields(payload, "monsterMaxHp", "monsterMaxHpBig", monster.maxHpBig)
    events[#events + 1] = PlayerTransition.Event("battle_hit", TableUtils.DeepCopy(payload))
    events[#events + 1] = PlayerTransition.Event("player_attack_hit", TableUtils.DeepCopy(payload))
    events[#events + 1] = PlayerTransition.Event("monster_damaged", TableUtils.DeepCopy(payload))
    payload.target = "monster"
    events[#events + 1] = PlayerTransition.Event("damage_dealt", payload)
    if critical then
        local criticalEvent = {
            monsterId = monster.id,
            hitIndex = hitIndex,
        }
        DomainMath.AddMagnitudeFields(criticalEvent, "amount", "amountBig", damage)
        events[#events + 1] = PlayerTransition.Event("critical_hit", criticalEvent)
    end

    local lifeSteal = math.max(0, state.stats.lifeSteal or 0)
    local maximumHp = DomainMath.StatMagnitude(state.stats, "hp")
    local currentHp = DomainMath.Magnitude(state.hpBig, state.hp, maximumHp)
    local healed = BigNumber.Min(
        BigNumber.Subtract(maximumHp, currentHp),
        BigNumber.Floor(BigNumber.MultiplyScalar(effectiveDamage, lifeSteal)))
    if not BigNumber.IsZero(healed) then
        DomainMath.SetPlayerHp(state, BigNumber.Add(currentHp, healed))
        local healPayload = {
            source = "life_steal",
            monsterId = monster.id,
        }
        DomainMath.AddMagnitudeFields(healPayload, "amount", "amountBig", healed)
        DomainMath.AddMagnitudeFields(healPayload, "playerHp", "playerHpBig", state.hpBig)
        DomainMath.AddMagnitudeFields(healPayload, "playerMaxHp", "playerMaxHpBig", maximumHp)
        DomainMath.AddMagnitudeFields(healPayload, "damage", "damageBig", effectiveDamage)
        events[#events + 1] = PlayerTransition.Event("life_steal", TableUtils.DeepCopy(healPayload))
        events[#events + 1] = PlayerTransition.Event("player_healed", healPayload)
    end

    hitIndex = hitIndex + 1
    if hitIndex <= #attack.weights then
        monster.hitIndex = hitIndex
        monster.hitFrame = attack.hitFrames[hitIndex]
        monster.phase = "windup"
        monster.phaseRemaining = math.max(CombatSequence.MIN_PHASE_SECONDS,
            attack.hitTimes[hitIndex] - attack.hitTimes[hitIndex - 1])
    else
        monster.hitIndex = #attack.weights
        monster.phase = "recovery"
        monster.phaseRemaining = math.max(CombatSequence.MIN_PHASE_SECONDS,
            attack.duration - attack.hitTimes[#attack.hitTimes])
        monster.recoverySeconds = monster.phaseRemaining
    end
end

local function resolveMonsterAttack(state, monster, events, context, callbacks)
    local damage = damageToPlayer(state, monster)
    local currentHp = DomainMath.Magnitude(state.hpBig, state.hp, DomainMath.StatMagnitude(state.stats, "hp"))
    DomainMath.SetPlayerHp(state, BigNumber.Subtract(currentHp, damage))
    local damagedEvent = {
        source = "monster_attack",
        monsterId = monster.id,
        encounterKind = monster.encounter,
        enraged = monster.enraged == true,
    }
    DomainMath.AddMagnitudeFields(damagedEvent, "amount", "amountBig", damage)
    DomainMath.AddMagnitudeFields(damagedEvent, "damage", "damageBig", damage)
    DomainMath.AddMagnitudeFields(damagedEvent, "playerHp", "playerHpBig", state.hpBig)
    DomainMath.AddMagnitudeFields(damagedEvent, "playerMaxHp", "playerMaxHpBig", DomainMath.StatMagnitude(state.stats, "hp"))
    events[#events + 1] = PlayerTransition.Event("player_damaged", damagedEvent)
    if BigNumber.IsZero(state.hpBig) then
        callbacks.handlePlayerDeath(state, monster, events, context)
        return true
    end
    local speed = monster.enraged and Catalog.BOSS_ENRAGE_SPEED_MULTIPLIER or 1
    monster.nextMonsterAttackSeconds = Catalog.ENEMY_ATTACK_SECONDS / speed
    return false
end

local function finishVictory(state, monster, rng, now, events, context, callbacks)
    events[#events + 1] = PlayerTransition.Event("battle_won", {
        monsterId = monster.id,
        eventType = monster.eventType,
        encounterKind = monster.encounter,
        floor = state.floor,
        room = monster.room,
        elapsedSeconds = monster.elapsedSeconds,
    })
    events[#events + 1] = PlayerTransition.Event("monster_defeated", {
        monsterId = monster.id,
        floor = state.floor,
        room = monster.room,
        kind = monster.encounter,
    })
    state.currentMonster = nil
    local completed, inventoryChanged = callbacks.settleVictory(
        state, monster, rng, now, events, context
    )
    if completed and not (context and context.offline) then
        -- 在线移动由服务端下发的楼层路线配置驱动，战斗结算后不再用服务端计时器模拟走路。
        state.transitionRemaining = 0
    end
    return completed, inventoryChanged
end

-- 玩家单次命中伤害计算（与放置挂机同一套公式；target 需提供 encounter/def/defBig 等怪物属性）。
-- 木桩等无防御目标传 { encounter = "normal", def = 0, defBig = BigNumber.Zero() }，其余沿用玩家面板。
function CombatEngine.PlayerHitDamage(state, target, weight, rng)
    return damageToMonster(state, target, weight, rng)
end

function CombatEngine.AdvanceActiveCombat(state, rng, now, timeStep, events, context, callbacks)
    local inventoryChanged = false
    local remaining = math.max(0, tonumber(timeStep) or 0)
    local guard = 0
    while state.currentMonster and guard < 1024 do
        guard = guard + 1
        local monster = state.currentMonster
        local rageRemaining = math.huge
        if (monster.encounter == "boss" or monster.encounter == "chapterBoss") and not monster.enraged then
            rageRemaining = math.max(0, Catalog.BOSS_ENRAGE_SECONDS - (monster.elapsedSeconds or 0))
        end
        local monsterAlive = not BigNumber.IsZero(DomainMath.Magnitude(monster.hpBig, monster.hp, 0))
        local enemyRemaining = monsterAlive
            and math.max(0, tonumber(monster.nextMonsterAttackSeconds) or Catalog.ENEMY_ATTACK_SECONDS)
            or math.huge
        local phaseRemaining = math.max(0, tonumber(monster.phaseRemaining) or 0)
        local step = math.min(remaining, phaseRemaining, enemyRemaining, rageRemaining)
        if step > 0 then
            monster.phaseRemaining = math.max(0, phaseRemaining - step)
            if enemyRemaining < math.huge then
                monster.nextMonsterAttackSeconds = math.max(0, enemyRemaining - step)
            end
            monster.elapsedSeconds = (monster.elapsedSeconds or 0) + step
            remaining = remaining - step
        end

        local resolved = false
        if (monster.encounter == "boss" or monster.encounter == "chapterBoss") and not monster.enraged
            and (monster.elapsedSeconds or 0) >= Catalog.BOSS_ENRAGE_SECONDS - 1e-6
        then
            monster.enraged = true
            monster.nextMonsterAttackSeconds = (monster.nextMonsterAttackSeconds or Catalog.ENEMY_ATTACK_SECONDS)
                / Catalog.BOSS_ENRAGE_SPEED_MULTIPLIER
            events[#events + 1] = PlayerTransition.Event("boss_enraged", {
                monsterId = monster.id,
                elapsedSeconds = monster.elapsedSeconds,
                damageMultiplier = Catalog.BOSS_ENRAGE_DAMAGE_MULTIPLIER,
                attackSpeedMultiplier = Catalog.BOSS_ENRAGE_SPEED_MULTIPLIER,
            })
            resolved = true
        end

        if state.currentMonster and (monster.phaseRemaining or 0) <= 1e-6 then
            if monster.phase == "recovery" then
                if BigNumber.IsZero(DomainMath.Magnitude(monster.hpBig, monster.hp, 0)) then
                    local completed, changed = finishVictory(state, monster, rng, now, events, context, callbacks)
                    inventoryChanged = inventoryChanged or changed
                    if not completed then
                        state.autoRun = false
                        state.pauseReason = "inventory_full"
                        return "inventory_full", inventoryChanged
                    end
                else
                    monster.attackSerial = monster.attackSerial + 1
                    local attack = randomAttack(state, monster, rng)
                    events[#events + 1] = attackStartedEvent(monster, attack)
                end
            else
                resolvePlayerHit(state, monster, rng, events)
            end
            resolved = true
        end

        if state.currentMonster
            and not BigNumber.IsZero(DomainMath.Magnitude(monster.hpBig, monster.hp, 0))
            and (monster.nextMonsterAttackSeconds or 0) <= 1e-6
        then
            if resolveMonsterAttack(state, monster, events, context, callbacks) then
                return "battle_lost", inventoryChanged
            end
            resolved = true
        end

        if not state.currentMonster then break end
        if remaining <= 1e-6 and not resolved then break end
        if step <= 0 and not resolved then break end
    end
    if not state.currentMonster then
        return state.pauseReason == "tower_aid" and "battle_lost" or "battle_won", inventoryChanged
    end
    return "combat_advanced", inventoryChanged
end

return CombatEngine
