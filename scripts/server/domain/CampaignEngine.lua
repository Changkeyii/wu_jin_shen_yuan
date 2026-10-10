local CampaignCatalog = require("shared.CampaignCatalog")
local CampaignDefinitions = require("shared.CampaignDefinitions")
local Catalog = require("server.domain.Catalog")
local PlayerTransition = require("server.domain.PlayerTransition")
local RewardEngine = require("server.domain.RewardEngine")
local TableUtils = require("server.domain.TableUtils")

local CombatEngine = require("server.domain.CombatEngine")
local BigNumber = require("shared.BigNumber")
local DomainMath = require("server.domain.DomainMath")

local QuestEngine = require("server.domain.QuestEngine")
local RewardClaimEngine = require("server.domain.RewardClaimEngine")
local LargeNumber = require("shared.LargeNumber")

local Balance = require("shared.GameBalance")
local DungeonCatalog = require("shared.DungeonCatalog")
local DungeonEngine = require("server.domain.DungeonEngine")
local CampaignEngine = {}

local function Failure(state, now, code, reason)
    return PlayerTransition.Failure(state, now, code, reason)
end

local function StageNumber(stageId)
    local chapter, stage = tostring(stageId or ""):match("^main:c(%d+):([abc])$")
    return chapter and tonumber(chapter) or nil, stage
end

local function IsStageUnlocked(state, stage)
    return Balance.Level(state.level) >= (stage.minLevel or stage.recommendedLevel or 1)
end

local function AddReward(state, stage, events)
    if stage.exp > 0 then RewardEngine.AddExp(state, stage.exp, events) end
    if stage.gold > 0 then PlayerTransition.AddCurrency(state, "gold", stage.gold) end
    if stage.fragments > 0 then PlayerTransition.AddCurrency(state, "fragments", stage.fragments) end
    events[#events + 1] = PlayerTransition.Event("currency_granted", {
        currency = "gold",
        amount = stage.gold,
        source = "campaign",
    })
end

local function PlayerCombatStats(state)
    local stats = state.stats or Catalog.CalculateStats(state)
    local atk = math.max(8, tonumber(stats.atk) or 8)
    local def = math.max(1, tonumber(stats.def) or 1)
    local hp = math.max(40, tonumber(stats.hp) or tonumber(state.hp) or 40)
    local atkSpeed = math.max(0.6, math.min(3.0, tonumber(stats.atkSpeed) or 1))
    return {
        atk = atk,
        def = def,
        hp = hp,
        maxHp = hp,
        atkSpeed = atkSpeed,
        crit = math.max(0, math.min(0.8, tonumber(stats.crit) or 0.1)),
        critDmg = math.max(1.2, tonumber(stats.critDmg) or 1.5),
    }
end

local function ScaleEnemy(stage, player)
    local enemy = stage.enemy or {}
    if stage.dungeon then
        return { name = enemy.name, hp = enemy.hp, maxHp = enemy.hp,
            atk = enemy.atk, def = enemy.def, atkSpeed = 0.85 }
    end
    local growth = Balance.TrialGrowth(stage.recommendedLevel)
    local boss = stage.kind == "boss"
    local hp = math.floor((boss and 850 or 420) * growth * 0.85)
    return { name = enemy.name or "记忆回响", hp = hp, maxHp = hp,
        atk = math.floor((boss and 100 or 45) * growth),
        def = math.floor((boss and 40 or 25) * growth), atkSpeed = 0.85 }
end

local function ResolveMechanic(stage, player, enemy)
    local mechanic = stage.mechanic or "standard"
    local lamps = mechanic == "lamps" and 3 or 0
    local voiceHits = 0
    local voiceMisses = 0
    if mechanic == "true_voice" then
        local rolls = 3
        for _ = 1, rolls do
            if (player.atk / math.max(1, enemy.atk + enemy.def)) >= 0.85 then
                voiceHits = voiceHits + 1
            else
                voiceMisses = voiceMisses + 1
                enemy.hp = math.min(enemy.maxHp, enemy.hp + math.floor(enemy.maxHp * 0.12))
            end
        end
    elseif mechanic == "lamps" then
        local pressure = enemy.atk / math.max(1, player.def + player.atk * 0.15)
        lamps = pressure > 1.35 and 1 or (pressure > 0.95 and 2 or 3)
        if lamps < 3 then
            enemy.atk = math.floor(enemy.atk * (1 + (3 - lamps) * 0.18))
        end
    elseif mechanic == "mirror" then
        enemy.atk = math.floor(enemy.atk * 1.08)
        enemy.def = math.floor(enemy.def * 1.15)
    elseif mechanic == "oathbreak" then
        enemy.def = math.floor(enemy.def * 1.15)
        enemy.hp = math.floor(enemy.hp * 1.08)
    end
    return {
        mechanic = mechanic,
        lamps = lamps,
        voiceHits = voiceHits,
        voiceMisses = voiceMisses,
        usedAid = false,
    }
end

-- Trials run the exact tower combat engine on an isolated state. Only authority events
-- are sent to the common renderer; no second client-side damage simulation exists.
local function SimulateBattle(state, stage, rng)
    local player = PlayerCombatStats(state)
    local enemy = ScaleEnemy(stage, player)
    local extras = ResolveMechanic(stage, player, enemy)
    local combat = {
        stats = TableUtils.DeepCopy(state.stats or Catalog.CalculateStats(state)),
        floor = math.max(1, stage.recommendedLevel or 1), position = 1,
        autoRun = true, transitionRemaining = 0,
    }
    if extras.mechanic == "mirror" then
        combat.stats.crit = 0
        combat.stats.atkBig = BigNumber.MultiplyScalar(DomainMath.StatMagnitude(combat.stats, "atk"), 0.92)
    end
    DomainMath.SetPlayerHp(combat, DomainMath.StatMagnitude(combat.stats, "hp"))
    local waves = (stage.dungeon ~= nil or extras.mechanic == "gatekeeper" or extras.mechanic == "clear_minions")
        and math.min(9, math.max(1, math.floor(tonumber(stage.waves) or 3))) or 1
    if extras.mechanic == "gatekeeper" then waves = waves + 1 end
    local report = { frames = {}, playerMaxHp = BigNumber.Clone(combat.hpBig), waves = waves,
        limit = math.max(20, math.min(90, tonumber(stage.timeLimit) or 90)), duration = 0 }
    local elapsed, won, dead = 0, false, false
    local keep = { battle_started = true, attack_started = true, battle_hit = true,
        player_damaged = true, player_healed = true, battle_won = true, player_died = true, boss_enraged = true }
    local fields = { "kind", "monsterId", "eventType", "name", "room", "attackSerial", "sequenceIndex", "hitFrame",
        "endFrame", "windupSeconds", "recoverySeconds", "durationSeconds", "critical", "lucky",
        "damageBig", "amountBig", "monsterHpBig", "monsterMaxHpBig", "playerHpBig", "playerMaxHpBig" }
    local function Capture(events)
        for _, event in ipairs(events) do
            if keep[event.kind] then
                local frame = { t = elapsed }
                for _, field in ipairs(fields) do frame[field] = event[field] end
                if event.hitFrames then frame.hitFrame = event.hitFrames[1] end
                report.frames[#report.frames + 1] = frame
            end
        end
    end
    for wave = 1, waves do
        combat.position = wave
        local finalWave = wave == waves
        local boss = finalWave and stage.kind == "boss"
        local generated = {
            name = finalWave and enemy.name or ("无名影卒 " .. tostring(wave)),
            hpBig = BigNumber.FromNumber(math.max(1, enemy.hp * (finalWave and 1 or (stage.dungeon and 0.5 or 0.25)))),
            atkBig = BigNumber.FromNumber(math.max(1, enemy.atk * (finalWave and 1 or (stage.dungeon and 0.8 or 0.55)))),
            defBig = BigNumber.FromNumber(enemy.def),
            encounter = { room = wave, floor = combat.floor, kind = boss and "boss" or "normal",
                eventType = boss and "boss" or "monster", isChapterBoss = false },
        }
        generated.hp = BigNumber.ToNumber(generated.hpBig)
        generated.atk = BigNumber.ToNumber(generated.atkBig)
        generated.def = BigNumber.ToNumber(generated.defBig)
        local events = {}
        local context = { campaign = true, monsterDefinition = generated }
        CombatEngine.BeginBattle(combat, generated.encounter.eventType, rng, events, context)
        Capture(events)
        while combat.currentMonster and elapsed < report.limit and not dead do
            local dt = math.min(0.05, report.limit - elapsed)
            elapsed = elapsed + dt
            events = {}
            CombatEngine.AdvanceActiveCombat(combat, rng, 0, dt, events, context, {
                settleVictory = function() return true, false end,
                handlePlayerDeath = function(current, monster, out)
                    dead = true
                    current.currentMonster = nil
                    out[#out + 1] = { kind = "player_died", monsterId = monster.id }
                end,
            })
            Capture(events)
        end
        if dead or combat.currentMonster then break end
        if finalWave then won = true end
    end
    local hpRatio = BigNumber.Ratio(combat.hpBig, report.playerMaxHp) or 0
    local stars = won and (hpRatio >= 0.3 and 3 or 2) or 0
    if won and extras.mechanic == "lamps" and extras.lamps < 2 then stars = math.max(1, stars - 1) end
    if won and extras.mechanic == "true_voice" and extras.voiceMisses > 0 then stars = math.max(1, stars - 1) end
    report.duration = elapsed
    report.won, report.stars = won, stars
    return report, { won = won, stars = stars, elapsed = elapsed, mechanic = extras.mechanic }
end

local function CompleteStage(inputState, stage, now, action, battle)
    local working = PlayerTransition.Copy(inputState, now)
    local campaign = working.campaign
    local record = campaign.completedStages[stage.id]
    local firstClear = record == nil
    local stars = stage.kind == "story" and 3 or (battle and battle.stars or 1)
    if record then
        record.clearCount = math.min(1000000, record.clearCount + 1)
        record.bestStars = math.max(record.bestStars, stars)
        record.clearedAt = now
    else
        campaign.completedStages[stage.id] = {
            clearCount = 1,
            bestStars = stars,
            firstClearClaimed = true,
            clearedAt = now,
        }
        record = campaign.completedStages[stage.id]
    end
    campaign.currentStageId = stage.id
    local chapter = stage.chapter
    local chapterId = string.format("main:c%02d", chapter)
    local nextStage = nil
    if stage.stage == "a" then nextStage = CampaignCatalog.GetStage(chapterId .. ":b")
    elseif stage.stage == "b" then nextStage = CampaignCatalog.GetStage(chapterId .. ":c")
    end
    if stage.stage == "c" then
        campaign.completedChapters[chapterId] = { rewardClaimed = true, clearedAt = now }
        campaign.highestUnlockedChapter = math.max(
            campaign.highestUnlockedChapter,
            math.min(CampaignDefinitions.MAX_CHAPTER, chapter + 1)
        )
    end
    local events = {
        PlayerTransition.Event("campaign_stage_started", {
            stageId = stage.id,
            chapter = chapter,
            action = action,
        }),
    }
    if firstClear then
        AddReward(working, stage, events)
        local offer = RewardClaimEngine.CreateAdOffer(working, {
            source = "campaign", sourceKey = "campaign:first:" .. stage.id,
            baseReward = { gold = LargeNumber.FromNumber(stage.gold), exp = stage.exp, fragments = stage.fragments },
            meta = {},
        }, now)
        if offer then
            events[#events + 1] = PlayerTransition.Event("reward_offer_pending", {
                rewardId = offer.id, source = offer.source,
                baseReward = offer.baseReward, extraReward = offer.extraReward,
            })
        end
        -- First sections keep their original resource-only reward bundle.
        if stage.stage ~= "a" then
            local rarity = stage.kind == "boss" and "artifact" or "rare"
            local ok, granted = RewardEngine.AddGeneratedDrop(
                working,
                rarity,
                stage.kind == "boss",
                nil,
                now,
                "campaign",
                events,
                {
                    slot = "weapon",
                    floor = math.max(1, stage.recommendedLevel or working.floor or 1),
                    tradeable = false,
                    rollTradeable = false,
                    aidLocked = false,
                    requireInventory = true,
                    trackInLootStash = false,
                }
            )
            if ok and granted then
                granted.locked = true
                granted.tradeable = false
                granted.source = "campaign"
                granted.aidLocked = false
                events[#events + 1] = PlayerTransition.Event("equipment_granted", {
                    itemId = granted.id,
                    equipmentId = granted.equipmentId,
                    rarity = granted.rarity,
                    slot = granted.slot,
                    source = "campaign",
                })
            end
        end
    end
    events[#events + 1] = PlayerTransition.Event("campaign_stage_completed", {
        stageId = stage.id,
        chapter = chapter,
        firstClear = firstClear,
        stars = stars,
        nextStageId = nextStage and nextStage.id or "",
        chapterCompleted = stage.stage == "c",
        reward = firstClear and { gold = stage.gold, exp = stage.exp, fragments = stage.fragments } or nil,
    })
    events[#events + 1] = PlayerTransition.Event("campaign_stage_clear", {
        stageId = stage.id,
        chapter = chapter,
        stars = stars,
        firstClear = firstClear,
    })
    if battle then
        events[#events + 1] = PlayerTransition.Event("campaign_battle_clear", {
            stageId = stage.id,
            stars = stars,
            elapsed = battle.elapsed,
            mechanic = battle.mechanic,
        })
        if stage.kind == "boss" then
            events[#events + 1] = PlayerTransition.Event("campaign_boss_clear", {
                stageId = stage.id,
                stars = stars,
            })
        end
        events[#events + 1] = PlayerTransition.Event("campaign_star_earned", {
            stageId = stage.id,
            stars = stars,
            bestStars = math.max(record and record.bestStars or 0, stars),
        })
    end
    QuestEngine.Track(working, "campaign_stage_clear", 1, now)
    if battle then
        QuestEngine.Track(working, "campaign_battle_clear", 1, now)
        QuestEngine.Track(working, "campaign_star_earned", stars, now)
        if stage.kind == "boss" then
            QuestEngine.Track(working, "campaign_boss_clear", 1, now)
        end
    end
    if stage.stage == "c" then
        events[#events + 1] = PlayerTransition.Event("campaign_chapter_completed", {
            chapter = chapter,
            chapterId = chapterId,
            firstClear = firstClear,
        })
        events[#events + 1] = PlayerTransition.Event("campaign_chapter_clear", {
            chapter = chapter,
            chapterId = chapterId,
            firstClear = firstClear,
        })
        QuestEngine.Track(working, "campaign_chapter_clear", 1, now)
    end
    PlayerTransition.RefreshDerived(working)
    return PlayerTransition.Finalize(
        inputState,
        working,
        now,
        "campaign_stage_completed",
        events,
        firstClear and true or false,
        false
    )
end

function CampaignEngine.PlayStage(inputState, stageId, action, now)
    local stage = CampaignCatalog.GetStage(stageId) or DungeonCatalog.GetStage(stageId)
    if not stage then return Failure(inputState, now, "CAMPAIGN_STAGE_UNKNOWN", "剧情关卡不存在") end
    if action ~= "complete" and action ~= "challenge" then
        return Failure(inputState, now, "CAMPAIGN_ACTION_INVALID", "剧情操作无效")
    end
    local workingCampaign = inputState.campaign or CampaignDefinitions.NewState()
    if not IsStageUnlocked(inputState, stage) then
        return Failure(inputState, now, "CAMPAIGN_STAGE_LOCKED", "达到推荐等级后可直接选关")
    end
    if stage.kind ~= "story" and action ~= "challenge" then
        return Failure(inputState, now, "CAMPAIGN_ACTION_INVALID", "战斗关卡需要发起挑战")
    end
    if stage.kind == "story" and action ~= "complete" then
        return Failure(inputState, now, "CAMPAIGN_ACTION_INVALID", "剧情关卡需要完成阅读")
    end

    if stage.kind ~= "story" then
        return Failure(inputState, now, "CAMPAIGN_TRIAL_REQUIRED", "请进入章节试炼后完成战斗")
    end
    return CompleteStage(inputState, stage, now, action, nil)
end

function CampaignEngine.PrepareTrial(state, stageId, rng)
    local stage = CampaignCatalog.GetStage(stageId) or DungeonCatalog.GetStage(stageId)
    if not stage or stage.kind == "story" then return nil, "请选择战斗关卡" end
    if not IsStageUnlocked(state, stage) then
        return nil, "达到推荐等级后可直接选关"
    end
    return SimulateBattle(state, stage, rng)
end

-- outcome comes only from the server session; clients submit an opaque trial ID.
function CampaignEngine.SettleTrial(state, stageId, outcome, now, runId)
    local stage = CampaignCatalog.GetStage(stageId) or DungeonCatalog.GetStage(stageId)
    if stage and stage.dungeon then return DungeonEngine.Settle(state, stage, outcome, now, runId) end
    if not stage or not outcome or not outcome.won then
        return PlayerTransition.NoCommit(state, now, "campaign_trial_lost")
    end
    return CompleteStage(state, stage, now, "challenge", outcome)
end

function CampaignEngine.ViewState(state)
    local campaign = CampaignDefinitions.Sanitize(state and state.campaign)
    local completed = {}
    for stageId, record in pairs(campaign.completedStages) do
        completed[stageId] = TableUtils.DeepCopy(record)
    end
    return {
        contentVersion = campaign.contentVersion,
        highestUnlockedChapter = campaign.highestUnlockedChapter,
        currentStageId = campaign.currentStageId,
        completedStages = completed,
        completedChapters = TableUtils.DeepCopy(campaign.completedChapters),
        choices = TableUtils.DeepCopy(campaign.choices),
        sweepDayKey = campaign.sweepDayKey,
        sweepUsed = campaign.sweepUsed,
        echoDayKey = campaign.echoDayKey,
        echoStageIds = TableUtils.DeepCopy(campaign.echoStageIds),
        echoClaimed = TableUtils.DeepCopy(campaign.echoClaimed),
    }
end

local function DayKey(now)
    return math.floor(((tonumber(now) or os.time()) + 8 * 3600) / 86400)
end

local function EnsureDaily(campaign, now)
    local dayKey = DayKey(now)
    if campaign.sweepDayKey ~= dayKey then
        campaign.sweepDayKey = dayKey
        campaign.sweepUsed = 0
    end
    if campaign.echoDayKey ~= dayKey then
        campaign.echoDayKey = dayKey
        campaign.echoClaimed = {}
        local completed = {}
        for stageId in pairs(campaign.completedStages or {}) do
            completed[#completed + 1] = stageId
        end
        table.sort(completed)
        local selected = {}
        local seed = dayKey
        for index = 1, math.min(3, #completed) do
            seed = (seed * 1103515245 + 12345) % 2147483648
            local pick = (seed % #completed) + 1
            selected[#selected + 1] = completed[pick]
            table.remove(completed, pick)
            if #completed == 0 then break end
        end
        campaign.echoStageIds = selected
    end
end

function CampaignEngine.SweepStage(inputState, stageId, now)
    local stage = CampaignCatalog.GetStage(stageId) or DungeonCatalog.GetStage(stageId)
    if not stage then return Failure(inputState, now, "CAMPAIGN_STAGE_UNKNOWN", "剧情关卡不存在") end
    local working = PlayerTransition.Copy(inputState, now)
    working.campaign = CampaignDefinitions.Sanitize(working.campaign)
    EnsureDaily(working.campaign, now)
    if not working.campaign.completedStages[stage.id] then
        return Failure(inputState, now, "CAMPAIGN_STAGE_LOCKED", "通关后才能扫荡")
    end
    if (working.campaign.sweepUsed or 0) >= 3 then
        return Failure(inputState, now, "CAMPAIGN_SWEEP_LIMIT", "今日扫荡次数已用完")
    end
    working.campaign.sweepUsed = (working.campaign.sweepUsed or 0) + 1
    local events = { PlayerTransition.Event("campaign_stage_swept", { stageId = stage.id }) }
    RewardEngine.AddExp(working, math.floor((stage.exp or 0) * 0.35), events)
    if (stage.gold or 0) > 0 then PlayerTransition.AddCurrency(working, "gold", math.floor(stage.gold * 0.35)) end
    if (stage.fragments or 0) > 0 then PlayerTransition.AddCurrency(working, "fragments", math.max(1, math.floor(stage.fragments * 0.35))) end
    PlayerTransition.RefreshDerived(working)
    return PlayerTransition.Finalize(inputState, working, now, "campaign_stage_swept", events, false, false)
end

function CampaignEngine.ClaimEcho(inputState, stageId, now)
    local stage = CampaignCatalog.GetStage(stageId) or DungeonCatalog.GetStage(stageId)
    if not stage then return Failure(inputState, now, "CAMPAIGN_STAGE_UNKNOWN", "剧情关卡不存在") end
    local working = PlayerTransition.Copy(inputState, now)
    working.campaign = CampaignDefinitions.Sanitize(working.campaign)
    EnsureDaily(working.campaign, now)
    local allowed = false
    for _, id in ipairs(working.campaign.echoStageIds or {}) do
        if id == stage.id then allowed = true; break end
    end
    if not allowed then return Failure(inputState, now, "CAMPAIGN_ECHO_LOCKED", "今日回响未开放此关") end
    if working.campaign.echoClaimed[stage.id] then
        return Failure(inputState, now, "CAMPAIGN_ECHO_CLAIMED", "今日回响已领取")
    end
    working.campaign.echoClaimed[stage.id] = true
    local events = { PlayerTransition.Event("campaign_echo_claimed", { stageId = stage.id }) }
    RewardEngine.AddExp(working, math.floor((stage.exp or 0) * 0.2), events)
    if (stage.gold or 0) > 0 then PlayerTransition.AddCurrency(working, "gold", math.floor(stage.gold * 0.2)) end
    if (stage.fragments or 0) > 0 then PlayerTransition.AddCurrency(working, "fragments", math.max(1, math.floor(stage.fragments * 0.2))) end
    PlayerTransition.RefreshDerived(working)
    return PlayerTransition.Finalize(inputState, working, now, "campaign_echo_claimed", events, false, false)
end

return CampaignEngine
