local CampaignCatalog = require("shared.CampaignCatalog")
local CampaignDefinitions = require("shared.CampaignDefinitions")
local Catalog = require("server.domain.Catalog")
local PlayerTransition = require("server.domain.PlayerTransition")
local RewardEngine = require("server.domain.RewardEngine")
local TableUtils = require("server.domain.TableUtils")

local QuestEngine = require("server.domain.QuestEngine")

local CampaignEngine = {}

local function Failure(state, now, code, reason)
    return PlayerTransition.Failure(state, now, code, reason)
end

local function StageNumber(stageId)
    local chapter, stage = tostring(stageId or ""):match("^main:c(%d+):([abc])$")
    return chapter and tonumber(chapter) or nil, stage
end

local function IsStageUnlocked(campaign, stage)
    local chapter, stageCode = StageNumber(stage.id)
    if not chapter or chapter > (campaign.highestUnlockedChapter or 1) then return false end
    if stageCode == "a" then return true end
    local previousCode = stageCode == "b" and "a" or "b"
    local previous = campaign.completedStages["main:c" .. string.format("%02d", chapter) .. ":" .. previousCode]
    return previous ~= nil
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
    local enemy = stage.enemy or { name = "记忆回响", hp = 120, atk = 10, def = 3 }
    local level = math.max(1, stage.recommendedLevel or 1)
    local hp = math.max(40, math.floor((enemy.hp or 80) + player.atk * 1.6 + level * 18))
    local atk = math.max(4, math.floor((enemy.atk or 8) + player.def * 0.18 + level * 1.4))
    local def = math.max(1, math.floor((enemy.def or 2) + level * 0.6))
    return {
        name = enemy.name or "记忆回响",
        hp = hp,
        maxHp = hp,
        atk = atk,
        def = def,
        atkSpeed = 0.85,
    }
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
        enemy.atk = math.max(enemy.atk, math.floor(player.atk * 0.72))
        enemy.def = math.max(enemy.def, math.floor(player.def * 0.45))
    elseif mechanic == "gatekeeper" or mechanic == "clear_minions" then
        local waves = math.max(1, math.floor(tonumber(stage.waves) or 3))
        enemy.hp = enemy.hp + math.floor(player.atk * 0.35 * waves)
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

local function SimulateBattle(state, stage)
    local player = PlayerCombatStats(state)
    local enemy = ScaleEnemy(stage, player)
    local extras = ResolveMechanic(stage, player, enemy)
    local elapsed = 0
    local limit = math.max(20, tonumber(stage.timeLimit) or 90)
    local playerCd = 0
    local enemyCd = 0
    local log = {}
    while elapsed < limit and player.hp > 0 and enemy.hp > 0 do
        local step = 0.2
        elapsed = elapsed + step
        playerCd = playerCd - step
        enemyCd = enemyCd - step
        if playerCd <= 0 then
            local crit = extras.mechanic == "mirror" and false or (math.random() < player.crit)
            local damage = math.max(1, math.floor((player.atk - enemy.def * 0.35) * (crit and player.critDmg or 1)))
            if extras.mechanic == "mirror" then
                damage = math.max(1, math.floor(damage * 0.92))
            end
            enemy.hp = enemy.hp - damage
            playerCd = 1 / player.atkSpeed
            log[#log + 1] = { actor = "player", damage = damage, crit = crit, hp = enemy.hp }
        end
        if enemy.hp <= 0 then break end
        if enemyCd <= 0 then
            local damage = math.max(1, math.floor(enemy.atk - player.def * 0.4))
            player.hp = player.hp - damage
            enemyCd = 1 / enemy.atkSpeed
            log[#log + 1] = { actor = "enemy", damage = damage, hp = player.hp }
        end
    end
    local won = enemy.hp <= 0 and player.hp > 0
    local hpRatio = player.hp / math.max(1, player.maxHp)
    local stars = 0
    if won then
        stars = 1
        if elapsed <= limit then stars = stars + 1 end
        if hpRatio >= 0.3 then stars = stars + 1 end
        if extras.usedAid then stars = math.max(1, stars - 1) end
        if extras.mechanic == "lamps" and extras.lamps < 2 then stars = math.max(1, stars - 1) end
        if extras.mechanic == "true_voice" and extras.voiceMisses > 0 then stars = math.max(1, stars - 1) end
        stars = math.max(1, math.min(3, stars))
    end
    return {
        won = won,
        stars = stars,
        elapsed = elapsed,
        hpRatio = hpRatio,
        playerHp = math.max(0, math.floor(player.hp)),
        playerMaxHp = player.maxHp,
        enemyName = enemy.name,
        enemyHp = math.max(0, math.floor(enemy.hp)),
        enemyMaxHp = enemy.maxHp,
        mechanic = extras.mechanic,
        lamps = extras.lamps,
        log = log,
    }
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
        if stage.kind ~= "story" then
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
    local stage = CampaignCatalog.GetStage(stageId)
    if not stage then return Failure(inputState, now, "CAMPAIGN_STAGE_UNKNOWN", "剧情关卡不存在") end
    if action ~= "complete" and action ~= "challenge" then
        return Failure(inputState, now, "CAMPAIGN_ACTION_INVALID", "剧情操作无效")
    end
    local workingCampaign = inputState.campaign or CampaignDefinitions.NewState()
    if not IsStageUnlocked(workingCampaign, stage) then
        return Failure(inputState, now, "CAMPAIGN_STAGE_LOCKED", "请先完成前置剧情")
    end
    if stage.kind ~= "story" and action ~= "challenge" then
        return Failure(inputState, now, "CAMPAIGN_ACTION_INVALID", "战斗关卡需要发起挑战")
    end
    if stage.kind == "story" and action ~= "complete" then
        return Failure(inputState, now, "CAMPAIGN_ACTION_INVALID", "剧情关卡需要完成阅读")
    end

    local battle = nil
    if stage.kind ~= "story" then
        battle = SimulateBattle(inputState, stage)
        if not battle.won then
            return Failure(inputState, now, "CAMPAIGN_BATTLE_FAILED", "挑战失败，调整节奏后再战")
        end
    end
    return CompleteStage(inputState, stage, now, action, battle)
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
    local stage = CampaignCatalog.GetStage(stageId)
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
    local stage = CampaignCatalog.GetStage(stageId)
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
