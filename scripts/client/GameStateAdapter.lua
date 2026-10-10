local EquipmentCatalog = require("shared.EquipmentCatalog")
local ItemPresentation = require("shared.ItemPresentation")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")
local QuestDefinitions = require("shared.QuestDefinitions")
local ActivityDefinitions = require("shared.ActivityDefinitions")
local WishPoolDefinitions = require("shared.WishPoolDefinitions")
local AbyssDefinitions = require("shared.AbyssDefinitions")
local ChallengeDefinitions = require("shared.ChallengeDefinitions")
local ServerClock = require("client.ServerClock")

local GameStateAdapter = {}

---@type table<string, any>?
local authoritative_ = nil
---@type table<string, any>?
local view_ = nil
local page_ = "home"
local connectionState_ = "syncing"
local dirtyDomains_ = { all = true }

local function MarkDirty(...)
    for index = 1, select("#", ...) do
        local domain = select(index, ...)
        if domain == "all" then
            dirtyDomains_ = { all = true }
            return
        end
        if not dirtyDomains_.all and type(domain) == "string" and domain ~= "" then
            dirtyDomains_[domain] = true
        end
    end
end

local function BeginDirtyTracking()
    dirtyDomains_ = {}
end

local function MarkDirtyForKey(key)
    local domains = {
        inventory = { "inventory" },
        overflowLoot = { "inventory" },
        lootStash = { "inventory" },
        consumables = { "inventory" },
        inventoryCapacity = { "inventory" },
        inventoryBonusSlots = { "inventory" },
        inventoryExpand = { "inventory" },
        equipped = { "equipment", "inventory" },
        equippedSlots = { "equipment", "inventory" },
        stats = { "player", "equipment" },
        hp = { "player", "combat" },
        hpBig = { "player", "combat" },
        playerMaxHp = { "player", "combat" },
        displayedPower = { "player", "equipment" },
        recommendedPower = { "progression" },
        nextChapterRecommendedPower = { "progression" },
        powerRatio = { "progression" },
        headroomFloors = { "progression" },
        difficultyLabel = { "progression" },
        floor = { "progression", "combat" },
        maxFloor = { "progression" },
        position = { "progression", "combat" },
        room = { "progression", "combat" },
        currentMonster = { "combat" },
        currentEvent = { "combat" },
        recentDamage = { "combat" },
        autoRun = { "combat" },
        stepTimer = { "combat" },
        gold = { "player", "market" },
        fragments = { "player", "market" },
        exp = { "player", "progression" },
        nextExp = { "player", "progression" },
        level = { "player", "progression", "inventory", "wish" },
        growth = { "player", "progression" },
        vipLevel = { "player" },
        adFree = { "player", "home", "activity", "bag" },
        dailyVip = { "player" },
        pendingOfflineSeconds = { "player" },
        offlineSeconds = { "player" },
        quests = { "quest" },
        rewardClaims = { "quest" },
        activities = { "activity" },
        wishPool = { "wish", "inventory" },
        abyss = { "abyss", "inventory" },
        challenges = { "challenge" },
        campaign = { "campaign", "quest" },
        marketListings = { "market" },
        tutorial = { "tutorial" },
        pendingStoryGate = { "tutorial", "combat" },
        pendingStory = { "tutorial", "combat" },
        pendingEvent = { "combat" },
        pendingEquipDecision = { "equipment", "combat" },
        playerNickname = { "player", "equipment" },
        seasonTitle = { "player", "equipment" },
        seasonFrame = { "player", "equipment" },
        seasonRewardWeekKey = { "player" },
        isAdmin = { "admin" },
        logs = { "logs" },
    }
    local ignored = {
        changes = true,
        changed = true,
        state = true,
        delta = true,
        events = true,
        snapshot = true,
        revision = true,
        updatedAt = true,
        serverTime = true,
    }
    local matched = domains[key]
    if matched then
        MarkDirty(table.unpack(matched))
    elseif not ignored[key] then
        MarkDirty("all")
    end
end

local function MarkDirtyForChanges(changes)
    for key in pairs(changes or {}) do
        MarkDirtyForKey(key)
    end
end

local function MarkDirtyForEvent(event)
    local kind = type(event) == "table" and (event.kind or event.type) or nil
    local domains = {
        battle_won = { "combat", "progression", "player" },
        monster_defeated = { "combat", "progression", "player" },
        battle_started = { "combat" },
        monster_spawned = { "combat" },
        battle_hit = { "combat" },
        damage_dealt = { "combat" },
        player_attack_hit = { "combat" },
        player_damaged = { "combat", "player" },
        player_healed = { "combat", "player" },
        life_steal = { "combat", "player" },
        player_died = { "combat", "player" },
        player_revived = { "combat", "player" },
        floor_reset = { "combat", "progression" },
        floor_advanced = { "combat", "progression" },
        cell_entered = { "combat", "progression" },
        equipment_drop = { "inventory", "equipment" },
        loot_dropped = { "inventory", "equipment" },
        loot_settled = { "inventory" },
        equipment_equipped = { "inventory", "equipment" },
        equipment_unequipped = { "inventory", "equipment" },
        equipment_decomposed = { "inventory", "equipment", "player" },
        equipment_auto_disposed = { "inventory", "equipment", "player" },
        equipment_lock_changed = { "inventory", "equipment" },
        equipment_strengthened = { "inventory", "equipment", "player" },
        equipment_starred = { "inventory", "equipment", "player" },
        equipment_upgrade_available = { "inventory", "equipment" },
        equipment_reverted = { "inventory", "equipment" },
        equip_undone = { "inventory", "equipment" },
        inventory_full = { "inventory" },
        inventory_drop_skipped = { "inventory" },
        inventory_policy_changed = { "inventory" },
        quest_claimed = { "quest", "player" },
        activity_signed = { "activity", "player" },
        activity_claimed = { "activity", "player" },
        wish_drawn = { "wish", "inventory" },
        wish_jar_opened = { "wish", "inventory" },
        wish_jar_recycled = { "wish", "inventory", "player" },
        abyss_echo = { "abyss", "player" },
        offline_collected = { "player", "inventory" },
        story_gate = { "tutorial", "combat" },
        story_advanced = { "tutorial", "combat" },
        story_completed = { "tutorial", "combat" },
        story_skipped = { "tutorial", "combat" },
        tutorial_step = { "tutorial" },
        tutorial_completed = { "tutorial" },
        campaign_stage_completed = { "campaign", "quest", "player" },
        campaign_stage_clear = { "campaign", "quest", "player" },
        campaign_chapter_completed = { "campaign", "quest" },
        campaign_chapter_clear = { "campaign", "quest" },
        campaign_star_earned = { "campaign", "quest" },
        campaign_battle_clear = { "campaign", "quest" },
        campaign_boss_clear = { "campaign", "quest" },
        event_pending = { "combat" },
        event_resolved = { "combat" },
        equip_decision_applied = { "equipment", "combat" },
    }
    if domains[kind] then
        MarkDirty(table.unpack(domains[kind]))
    elseif kind then
        MarkDirty("all")
    end
end

local function MarkDirtyForEvents(events)
    for _, event in ipairs(events or {}) do
        MarkDirtyForEvent(event)
    end
end

local function DeepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do
        copy[DeepCopy(key, seen)] = DeepCopy(child, seen)
    end
    return copy
end

local function CopyStoryGate(value)
    if type(value) ~= "table" then return nil end
    return {
        storyId = value.storyId,
        chapter = value.chapter,
        floor = value.floor,
        phase = value.phase,
        title = value.title,
        lines = DeepCopy(value.lines),
        lineIndex = value.lineIndex,
    }
end

local function NormalizeStoryGate(state)
    if type(state) ~= "table" then return end
    if type(state.pendingStoryGate) == "table" then
        state.pendingStoryGate = CopyStoryGate(state.pendingStoryGate)
    elseif type(state.pendingStory) == "table" then
        state.pendingStoryGate = CopyStoryGate(state.pendingStory)
    end
    state.pendingStory = nil
end

local function Merge(target, patch)
    for key, value in pairs(patch or {}) do
        if type(value) == "table" and type(target[key]) == "table" then
            Merge(target[key], value)
        else
            target[key] = DeepCopy(value)
        end
    end
end

local function FormatValue(value)
    if type(value) == "table" and (value.mantissa ~= nil or value.exponent ~= nil) then
        return BigNumber.Format(value, 4)
    end
    return LargeNumber.Format(value or 0)
end

local function FirstNumber(...)
    for index = 1, select("#", ...) do
        local value = select(index, ...)
        if type(value) == "number" then return value end
    end
    return nil
end

local function EventText(value)
    local kind = value and value.kind
    if kind == "cell_entered" then
        return string.format("前进到第%d/100格。", value.position or 0)
    elseif kind == "battle_reward" then
        return "战斗胜利：金币" .. FormatValue(value.gold) .. "、经验" .. FormatValue(value.exp) .. "。"
    elseif kind == "battle_lost" then
        return "挑战失败，已回到本层第1场重新整备。"
    elseif kind == "equipment_drop" or kind == "loot_dropped" then
        return "获得装备：" .. tostring(value.name or value.itemId or "未知装备")
    elseif kind == "loot_settled" then
        local outcome = value.outcome or value.destination or "inventory"
        return (outcome == "temporary_box" or outcome == "temporary_loot")
            and "背包已满，战利品已进入临时战利品箱。" or "战利品已自动拾取。"
    elseif kind == "level_up" then
        return "等级提升至 " .. tostring(value.level or "?") .. " 级"
    elseif kind == "floor_advanced" then
        return "进入第" .. tostring(value.floor or "?") .. "层。"
    elseif kind == "floor_reset" then
        return "本层重置：从第1场重新开始，已获得奖励保留。"
    elseif kind == "player_damaged" then
        return "受到 " .. FormatValue(value.amountBig or value.damageBig or value.amount or value.damage) .. " 点伤害。"
    elseif kind == "player_healed" or kind == "life_steal" then
        local source = value.source == "floor_rest" and "层间休整"
            or value.source == "revive" and "复活"
            or "吸血"
        return source .. "恢复 " .. FormatValue(value.amountBig or value.amount) .. " 点生命。"
    elseif kind == "player_died" then
        return "角色倒下，本层将从第1场重新开始。"
    elseif kind == "player_revived" then
        return "角色已复活并返回本层初始位置。"
    elseif kind == "boss_enraged" then
        return "Boss进入狂暴：伤害和攻击速度提升。"
    elseif kind == "aid_pending" or kind == "tower_aid_requested" then
        return "连续失败两次，塔灵援助已准备。"
    elseif kind == "aid_granted" then
        return "塔灵援助装备已发放。"
    elseif kind == "chest_reward" then
        return "开启宝箱：金币" .. FormatValue(value.gold) .. "、碎片" .. FormatValue(value.fragments) .. "。"
    elseif kind == "merchant_trade" then
        return "商人交易：消耗金币" .. FormatValue(value.goldSpent)
            .. "，获得碎片" .. FormatValue(value.fragments) .. "。"
    elseif kind == "merchant_skipped" then
        return "遇到商人，但金币不足。"
    elseif kind == "wish_pool" then
        return "许愿池回应：获得金币" .. FormatValue(value.gold) .. "。"
    elseif kind == "teleport" then
        return "传送门启动：前进至第" .. tostring(value.position or 0) .. "格。"
    elseif kind == "altar_heal" then
        return "古代祭坛赐福：恢复生命。"
    elseif kind == "abyss_echo" then
        return "深渊回声：获得碎片" .. tostring(value.fragments or 0) .. "。"
    elseif kind == "inventory_full" then
        return "背包已满，自动挂机已暂停。"
    elseif kind == "inventory_drop_skipped" then
        return "背包已满，本次无法处理的装备掉落已跳过，挂机继续。"
    elseif kind == "offline_collected" then
        local equipmentText = (value.equipment or 0) > 0 and ("、装备" .. tostring(value.equipment) .. "件") or ""
        local remainingText = (value.remainingSeconds or 0) > 0 and "，剩余离线时长保留" or ""
        return "领取离线收益（在线1/10）：金币" .. FormatValue(value.gold) .. "、经验" .. FormatValue(value.exp) .. "、碎片" .. FormatValue(value.fragments) .. equipmentText .. remainingText .. "。"
    elseif kind == "equipment_equipped" then
        return "装备已穿戴至" .. tostring(value.slot or "目标槽位") .. "。"
    elseif kind == "equipment_unequipped" then
        return "已卸下" .. tostring(value.slot or "目标槽位") .. "装备。"
    elseif kind == "equipment_decomposed" then
        return "分解" .. tostring(value.count or 0) .. "件装备，返还金币" .. FormatValue(value.gold) .. "、碎片" .. FormatValue(value.fragments) .. "。"
    elseif kind == "equipment_auto_disposed" then
        return "背包自动" .. (value.mode == "sell" and "出售" or "分解") .. "装备，获得金币" .. FormatValue(value.gold) .. "、碎片" .. FormatValue(value.fragments) .. "。"
    elseif kind == "equipment_lock_changed" then
        return value.locked and "装备已锁定。" or "装备已解锁。"
    elseif kind == "inventory_policy_changed" then
        local policy = value.inventoryPolicy or {}
        local parts = {}
        if policy.pauseOnFull then parts[#parts + 1] = "满包暂停" end
        if policy.autoDecompose then parts[#parts + 1] = "自动分解" end
        if policy.autoSell then parts[#parts + 1] = "自动出售" end
        return "背包规则已更新：" .. (#parts > 0 and table.concat(parts, "、") or "不自动处理") .. "。"
    elseif kind == "equipment_strengthened" then
        return "装备强化至 +" .. tostring(value.enhance or 0) .. "。"
    elseif kind == "equipment_starred" then
        return "装备升至 " .. tostring(value.star or 0) .. " 星。"
    elseif kind == "equipment_upgrade_available" then
        return "发现可提升整套战力的装备。"
    elseif kind == "equipment_reverted" or kind == "equip_undone" then
        return "已撤回上一次自动换装。"
    elseif kind == "quest_claimed" then
        local questDef = QuestDefinitions.Get(value and value.questId)
        return "完成任务「" .. tostring(questDef and questDef.title or value and value.questId or "任务") .. "」，奖励已发放。"
    elseif kind == "activity_signed" then
        local activityDef = ActivityDefinitions.Get(value and value.activityId)
        return "活动签到：「" .. tostring(activityDef and activityDef.title or "活动") .. "」第"
            .. tostring(value.day or 1) .. "天奖励已发放。"
    elseif kind == "activity_claimed" then
        local activityDef = ActivityDefinitions.Get(value and value.activityId)
        return "活动奖励已发放：「" .. tostring(activityDef and activityDef.title or "活动") .. "」。"
    end
    return nil
end

local function ApplyEvents(state, events)
    state.logs = state.logs or {}
    for _, value in ipairs(events or {}) do
        local kind = value.kind
        if kind == "battle_won" or kind == "monster_defeated" then
            state.currentMonster = nil
        elseif kind == "battle_started" or kind == "monster_spawned" then
            local monster = type(value.monster) == "table" and DeepCopy(value.monster) or {}
            monster.id = monster.id or value.monsterId
            monster.name = monster.name or value.name
            monster.eventType = monster.eventType or value.eventType
            monster.encounterKind = monster.encounterKind or value.encounterKind
            monster.hpBig = value.monsterHpBig or value.hpBig or monster.hpBig
            monster.maxHpBig = value.monsterMaxHpBig or value.maxHpBig or monster.maxHpBig or monster.hpBig
            monster.hp = FirstNumber(value.monsterHp, value.hp, monster.hp)
            monster.maxHp = FirstNumber(value.monsterMaxHp, value.maxHp, monster.maxHp, monster.hp)
            monster.floor = value.floor or monster.floor or state.floor
            monster.room = value.room or monster.room or state.room
            monster.isChapterBoss = value.isChapterBoss == true or monster.encounterKind == "chapterBoss"
            state.currentMonster = monster
        elseif kind == "battle_hit" or kind == "damage_dealt" or kind == "player_attack_hit" then
            local prefix = value.lucky and "触发777" or (value.critical and "暴击" or "命中")
            local damage = value.amountBig or value.damageBig or value.amount or value.damage or 0
            local monsterHp = value.targetHpBig or value.monsterHpBig or value.targetHp or value.monsterHp
            local monsterMaxHp = value.targetMaxHpBig or value.monsterMaxHpBig
                or value.targetMaxHp or value.monsterMaxHp
            state.recentDamage = prefix .. " " .. FormatValue(damage) .. " 伤害"
            if state.currentMonster and monsterHp ~= nil then
                if type(monsterHp) == "table" then
                    state.currentMonster.hpBig = monsterHp
                else
                    state.currentMonster.hp = monsterHp
                end
                if type(monsterMaxHp) == "table" then
                    state.currentMonster.maxHpBig = monsterMaxHp
                elseif monsterMaxHp ~= nil then
                    state.currentMonster.maxHp = monsterMaxHp
                end
            end
        elseif kind == "player_damaged" then
            state.hpBig = value.hpBig or value.playerHpBig or state.hpBig
            state.hp = FirstNumber(value.hp, value.playerHp, state.hp)
            state.playerMaxHp = value.maxHpBig or value.playerMaxHpBig
                or value.maxHp or value.playerMaxHp or state.playerMaxHp
        elseif kind == "player_healed" or kind == "life_steal" then
            state.hpBig = value.hpBig or value.playerHpBig or state.hpBig
            state.hp = FirstNumber(value.hp, value.playerHp, state.hp)
            state.playerMaxHp = value.maxHpBig or value.playerMaxHpBig
                or value.maxHp or value.playerMaxHp or state.playerMaxHp
        elseif kind == "player_died" then
            state.hp = 0
            state.hpBig = BigNumber.Zero()
        elseif kind == "player_revived" then
            state.hpBig = value.hpBig or value.playerHpBig or state.hpBig
            state.hp = FirstNumber(value.hp, value.playerHp, state.hp)
            state.playerMaxHp = value.maxHpBig or value.playerMaxHpBig
                or value.maxHp or value.playerMaxHp or state.playerMaxHp
            state.room = value.room or 1
        elseif kind == "floor_reset" then
            state.room = value.room or 1
            state.currentMonster = nil
        elseif kind == "story_gate" then
            state.pendingStoryGate = CopyStoryGate(value)
            state.pendingStory = nil
        elseif kind == "story_advanced" then
            local gate = state.pendingStoryGate
            if type(gate) == "table" and (value.storyId == nil or value.storyId == gate.storyId) then
                gate.lineIndex = value.lineIndex or gate.lineIndex
            end
        elseif kind == "story_completed" or kind == "story_skipped" then
            state.pendingStoryGate = nil
            state.pendingStory = nil
        elseif kind == "event_pending" then
            state.pendingEvent = {
                eventId = value.eventId,
                eventType = value.eventType,
                floor = value.floor,
                room = value.room,
                encounterId = value.encounterId,
                expiresAt = value.expiresAt,
                actions = value.actions,
                title = value.title,
                description = value.description,
                goldCost = value.goldCost,
                fragmentsReward = value.fragmentsReward,
            }
        elseif kind == "event_resolved" then
            state.pendingEvent = nil
        elseif kind == "equip_decision_applied" then
            state.pendingEquipDecision = nil
        elseif kind == "tutorial_step" then
            -- 事件兜底同步：即使 delta.changes 漏了 tutorial，也按事件推进客户端状态。
            local step = tonumber(value.step) or 1
            step = math.max(1, math.min(6, math.floor(step)))
            state.tutorial = {
                step = step,
                completed = value.completed == true or step >= 6,
            }
        elseif kind == "tutorial_completed" then
            state.tutorial = { step = 6, completed = true }
        elseif kind == "battle" then
            local prefix = value.lucky and "触发777" or (value.critical and "暴击" or "造成")
            state.recentDamage = prefix .. " " .. tostring(value.lastDamage or 0) .. " 伤害"
        end
        local text = EventText(value)
        if text then table.insert(state.logs, 1, text) end
    end
    while #state.logs > 40 do table.remove(state.logs) end
end

local function ProjectEquipment(item)
    if type(item) ~= "table" then return item end
    if not item.equipmentId then
        local projected = DeepCopy(item)
        projected.rawName = item.rawName or item.name
        projected.name = ItemPresentation.DisplayName(projected, "未知道具")
        return projected
    end
    local definition = EquipmentCatalog.Get(item.equipmentId)
    if not definition then
        local projected = DeepCopy(item)
        projected.rawName = item.rawName or item.name
        projected.name = ItemPresentation.DisplayName(projected, "未知装备")
        return projected
    end
    local projected = DeepCopy(definition)
    -- V5 instances carry their rolled authoritative stats. Definition values
    -- are visual/catalog fallbacks only; never overwrite server-provided data.
    for key, value in pairs(item) do projected[key] = DeepCopy(value) end
    projected.id = item.id
    projected.equipmentId = item.equipmentId or definition.id
    projected.rawName = item.rawName or item.name or definition.name
    projected.name = ItemPresentation.DisplayName(projected, definition.name)
    projected.level = item.level or definition.level
    projected.enhance = item.enhance or 0
    projected.star = item.star or 0
    projected.locked = item.locked == true
    projected.acquiredAt = item.acquiredAt or 0
    projected.source = item.source or "legacy"
    projected.investedGold = LargeNumber.IsLargeNumber(item.investedGold)
        and LargeNumber.Normalize(item.investedGold)
        or LargeNumber.FromNumber(item.investedGold)
    projected.investedFragments = item.investedFragments or 0
    return projected
end

local function ProjectInventory(items)
    local projected = {}
    for _, item in ipairs(items or {}) do
        projected[#projected + 1] = ProjectEquipment(item)
    end
    return projected
end


local function EmptyView()
    return {
        schemaVersion = 10,
        revision = 0,
        updatedAt = 0,
        floor = 1,
        maxFloor = 1,
        position = 0,
        level = 1,
        vipLevel = 0,
        adFree = false,
        dailyVip = { signInDay = 0, adDay = 0 },
        wishPool = {
            tickets = 0, jars = {}, adDayKey = 0, adUsed = 0, totalWishes = 0,
            mythPity = 0, mythGuarantees = 0, characterPity = 0,
            ownedCharacters = { ember_blade = true }, characterMarks = {},
        },
        abyss = AbyssDefinitions.NewState(),
        rewardClaims = require("shared.RewardClaimDefinitions").NewState(),
        challenges = ChallengeDefinitions.NewState(),
        campaign = require("shared.CampaignDefinitions").NewState(),
        exp = 0,
        nextExp = 100,
        gold = LargeNumber.Zero(),
        fragments = LargeNumber.Zero(),
        autoRun = false,
        pendingOfflineSeconds = 0,
        offlineSeconds = 0,
        stepTimer = 0,
        hp = 1,
        hpBig = BigNumber.FromNumber(1),
        playerMaxHp = 1,
        displayedPower = nil,
        recommendedPower = nil,
        nextChapterRecommendedPower = nil,
        powerRatio = nil,
        headroomFloors = nil,
        difficultyLabel = "待评估",
        bossScore = nil,
        eliteScore = nil,
        estimatedEasyFloor = nil,
        stats = {
            atk = 0,
            def = 0,
            hp = 1,
            atkBig = BigNumber.Zero(),
            defBig = BigNumber.Zero(),
            hpBig = BigNumber.FromNumber(1),
            crit = 0,
            critDmg = 1.5,
            atkSpeed = 1,
            lifeSteal = 0,
            power = 0,
        },
        inventory = {},
        overflowLoot = {},
        lootStash = {},
        marketListings = {},
        equipped = {},
        equippedSlots = {},
        logs = { "正在连接权威服务器..." },
        currentEvent = "monster",
        recentDamage = "等待服务端同步",
        playerNickname = nil,
        page = page_,
        isAdmin = false,
        readOnly = true,
        connectionState = connectionState_,
    }
end

local function ShallowCopy(source)
    local copy = {}
    for key, value in pairs(source or {}) do copy[key] = value end
    return copy
end

local function NeedsInventoryProjection(domains)
    return not domains or domains.all or domains.inventory or domains.equipment or domains.wish or domains.abyss
end

local function RebuildView(reuseProjectedInventory)
    if not authoritative_ then
        view_ = EmptyView()
        return view_
    end

    local reuseInventory = view_
        and view_.itemById
        and (reuseProjectedInventory or not NeedsInventoryProjection(dirtyDomains_))
    local nextView = ShallowCopy(authoritative_)
    nextView.page = page_
    nextView.connectionState = connectionState_
    nextView.readOnly = connectionState_ ~= "ready"
    nextView.nextExp = nextView.nextExp or require("shared.GameProgression").NextExp(nextView.level)
    nextView.pendingOfflineSeconds = nextView.pendingOfflineSeconds or 0
    nextView.offlineSeconds = nextView.pendingOfflineSeconds
    nextView.stepTimer = nextView.stepTimer or 0
    nextView.logs = nextView.logs or {}
    if reuseInventory then
        nextView.inventory = view_.inventory
        nextView.overflowLoot = view_.overflowLoot
        nextView.itemById = view_.itemById
        nextView.equipped = view_.equipped
        nextView.equippedSlotByItemId = view_.equippedSlotByItemId
        nextView.equipmentInventoryCount = view_.equipmentInventoryCount
        nextView.uiFlags = view_.uiFlags
    else
        nextView.inventory = ProjectInventory(nextView.inventory or {})
        nextView.overflowLoot = ProjectInventory(nextView.overflowLoot or {})
    end
    nextView.lootStash = nextView.lootStash or {}
    nextView.marketListings = nextView.marketListings or {}
    nextView.equipmentInventoryCount = #nextView.inventory
    do
        local bonus = math.max(0, math.min(700, math.floor(tonumber(nextView.inventoryBonusSlots) or 0)))
        local localCap = 300 + bonus
        local serverCap = tonumber(nextView.inventoryCapacity)
        nextView.inventoryCapacity = math.max(localCap, serverCap or 0)
        nextView.inventoryBonusSlots = bonus
        nextView.inventoryExpand = type(nextView.inventoryExpand) == "table"
            and nextView.inventoryExpand
            or { adDayKey = 0, adUsed = 0 }
    end
    nextView.equippedSlots = nextView.equippedSlots or nextView.equipped or {}
    nextView.room = nextView.room or nextView.encounter or math.max(1, math.min(10, (nextView.position or 0) + 1))
    nextView.playerMaxHp = nextView.playerMaxHp
        or (nextView.stats and (nextView.stats.hpBig or nextView.stats.hp))
        or nextView.hpBig or nextView.hp or 1
    nextView.displayedPower = nextView.displayedPower or (nextView.stats and nextView.stats.power)
    if nextView.stats and nextView.displayedPower ~= nil then nextView.stats.power = nextView.displayedPower end
    if nextView.powerRatio == nil and nextView.displayedPower ~= nil and nextView.recommendedPower ~= nil then
        if type(nextView.displayedPower) == "table" and nextView.displayedPower.mantissa ~= nil then
            nextView.powerRatio = BigNumber.Ratio(nextView.displayedPower, nextView.recommendedPower)
        else
            local toNumber = rawget(LargeNumber, "ToNumber")
            local displayed = toNumber and toNumber(nextView.displayedPower) or nextView.displayedPower
            local recommended = toNumber and toNumber(nextView.recommendedPower) or nextView.recommendedPower
            if type(displayed) == "number" and type(recommended) == "number" and recommended > 0 then
                nextView.powerRatio = displayed / recommended
            end
        end
    end
    nextView.difficultyLabel = nextView.difficultyLabel or "待评估"

    if not reuseInventory then
        if nextView.consumables and nextView.consumables.healthPotion then
            nextView.inventory[#nextView.inventory + 1] = {
                id = "consumable:healthPotion",
                name = "生命药水",
                category = "consumable",
                rarity = "blue",
                quantity = nextView.consumables.healthPotion,
                desc = "战斗补给，由服务端道具仓储管理。",
            }
        elseif nextView.consumables then
            for _, item in ipairs(nextView.consumables) do
                local projected = DeepCopy(item)
                projected.id = projected.id or projected.itemId or ("consumable:" .. tostring(projected.name or #nextView.inventory + 1))
                projected.category = projected.category or "consumable"
                projected.rarity = projected.rarity or "blue"
                projected.quantity = projected.quantity or projected.count or 0
                nextView.inventory[#nextView.inventory + 1] = projected
            end
        end
    end

    -- 许愿券是背包道具（可堆叠）：由服务端 wishPool.tickets 权威计数投影展示。
    local wishTickets = nextView.wishPool and nextView.wishPool.tickets or 0
    if not reuseInventory and wishTickets > 0 then
        nextView.inventory[#nextView.inventory + 1] = {
            id = "wish_ticket",
            name = "许愿券",
            category = "consumable",
            rarity = "legendary",
            quantity = wishTickets,
            icon = WishPoolDefinitions.ICONS.ticket,
            desc = "许愿池专用许愿券，使用后可随机获得装备罐或完整角色。",
        }
    end

    local abyssTickets = nextView.abyss and nextView.abyss.tickets or 0
    if not reuseInventory and abyssTickets > 0 then
        nextView.inventory[#nextView.inventory + 1] = {
            id = "abyss_ticket",
            name = "深渊票",
            category = "consumable",
            rarity = "epic",
            quantity = abyssTickets,
            icon = AbyssDefinitions.ICON,
            desc = "活动页主动深渊的入场凭证；玩家等级每 10 级提高基础消耗。",
        }
    end

    -- 许愿池罐子是背包道具（可开启）：投影为 wishjar 分类道具。
    -- 服务端权威库存仍在 wishPool.jars，开罐命令由服务端校验扣除。
    local wishPoolJars = nextView.wishPool and nextView.wishPool.jars
    if not reuseInventory and type(wishPoolJars) == "table" then
        for jarId, count in pairs(wishPoolJars) do
            local jar = WishPoolDefinitions.ResolveJar(jarId)
            if jar and count > 0 then
                nextView.inventory[#nextView.inventory + 1] = {
                    id = "wishjar:" .. jarId,
                    jarId = jarId,
                    level = jar.level,
                    name = jar.name,
                    category = "wishjar",
                    rarity = jar.rarity
                        or (jar.setId and "epic" or "legendary"),
                    quantity = count,
                    icon = jar.icon,
                    desc = string.format("固定产出%d级装备；%d级可穿戴。", jar.level, jar.level == 5 and 1 or jar.level),
                }
            end
        end
    end

    if not reuseInventory then
    for _, item in ipairs(nextView.inventory) do
        item.rawName = item.rawName or item.name
        item.name = ItemPresentation.DisplayName(item, "未知道具")
    end
    for _, item in ipairs(nextView.overflowLoot) do
        item.rawName = item.rawName or item.name
        item.name = ItemPresentation.DisplayName(item, "未知道具")
    end

    local byId = {}
    for _, item in ipairs(nextView.inventory) do
        byId[tostring(item.id)] = item
    end
    local equippedObjects = {}
    local equippedSlotByItemId = {}
    for slot, itemId in pairs(nextView.equippedSlots) do
        if type(itemId) == "table" then
            equippedObjects[slot] = itemId
            if itemId.id ~= nil then equippedSlotByItemId[tostring(itemId.id)] = slot end
        else
            equippedObjects[slot] = byId[tostring(itemId)]
            equippedSlotByItemId[tostring(itemId)] = slot
        end
    end
    for _, item in ipairs(nextView.inventory) do
        item.equippedSlot = equippedSlotByItemId[tostring(item.id)]
        item.isEquipped = item.equippedSlot ~= nil
    end
    nextView.equipped = equippedObjects
    nextView.itemById = byId
    nextView.equippedSlotByItemId = equippedSlotByItemId
    nextView.uiFlags = nextView.uiFlags or {}
    local betterUnequippedSlots = {}
    local equippedCountBySet = {}
    local equippedRegionBySet = {}
    local equippedSetBySlot = {}
    for slotId, current in pairs(equippedObjects) do
        if current and current.setEnabled == true and current.setId then
            local setId = current.setId
            equippedCountBySet[setId] = (equippedCountBySet[setId] or 0) + 1
            equippedSetBySlot[slotId] = setId
            local region = EquipmentCatalog.REGION_BY_SLOT[slotId] or current.region
            if region then
                equippedRegionBySet[setId] = equippedRegionBySet[setId] or {}
                equippedRegionBySet[setId][region] = (equippedRegionBySet[setId][region] or 0) + 1
            end
        end
    end
    for _, item in ipairs(nextView.inventory) do
        if item
            and item.slot
            and item.equipmentId
            and not item.aidLocked
            and not item.isEquipped
        then
            local current = equippedObjects[item.slot]
            local locked = current and (current.locked or current.aidLocked)
            if not locked then
                local itemPower = item.power or item.displayedPower or item.evaluatedPower or item.powerContribution or 0
                local currentPower = current and (current.power or current.displayedPower
                    or current.evaluatedPower or current.powerContribution) or 0
                if not current or BigNumber.Compare(itemPower, currentPower) > 0 then
                    betterUnequippedSlots[item.slot] = true
                elseif item.setEnabled == true and item.setId
                    and equippedSetBySlot[item.slot] ~= item.setId
                then
                    local setId = item.setId
                    local count = equippedCountBySet[setId] or 0
                    local region = EquipmentCatalog.REGION_BY_SLOT[item.slot] or item.region
                    local regionCount = region and equippedRegionBySet[setId]
                        and (equippedRegionBySet[setId][region] or 0) or 0
                    local completesSet = count + 1 == 3 or count + 1 == 6
                        or count + 1 == 9 or count + 1 == 12
                    local completesRegion = region ~= nil and region ~= "weapon" and regionCount + 1 == 3
                    if completesSet or completesRegion then
                        betterUnequippedSlots[item.slot] = true
                    end
                end
            end
        end
    end
    nextView.uiFlags.betterUnequippedSlots = betterUnequippedSlots
    nextView.uiFlags.hasBetterUnequipped = next(betterUnequippedSlots) ~= nil
    end
    -- 许愿池展示所需的日切只影响客户端文案，不改变服务端权威计数。
    nextView.wishPool = nextView.wishPool or {
        tickets = 0, jars = {}, adDayKey = 0, adUsed = 0, totalWishes = 0,
        mythPity = 0, mythGuarantees = 0, characterPity = 0,
        ownedCharacters = { ember_blade = true }, characterMarks = {},
    }
    local wishDayKey = WishPoolDefinitions.DayKey(ServerClock.Now())
    nextView.wishPool.displayAdUsed = nextView.wishPool.adDayKey == wishDayKey
        and (nextView.wishPool.adUsed or 0) or 0
    nextView.abyss = nextView.abyss or AbyssDefinitions.NewState()
    if not dirtyDomains_ or dirtyDomains_.all or dirtyDomains_.abyss or not (view_ and view_.abyssView) then
        nextView.abyssView = AbyssDefinitions.BuildView(nextView)
    else
        nextView.abyssView = view_.abyssView
    end
    nextView.challenges = nextView.challenges or ChallengeDefinitions.NewState()
    if not dirtyDomains_ or dirtyDomains_.all or dirtyDomains_.challenge or not (view_ and view_.challengesView) then
        nextView.challengesView = ChallengeDefinitions.BuildView(nextView, ServerClock.Now())
    else
        nextView.challengesView = view_.challengesView
    end
    if not dirtyDomains_ or dirtyDomains_.all or dirtyDomains_.quest or dirtyDomains_.campaign or not (view_ and view_.questsView) then
        nextView.questsView = QuestDefinitions.BuildView(nextView, ServerClock.DayKey(ServerClock.Now()))
    else
        nextView.questsView = view_.questsView
    end
    if not dirtyDomains_ or dirtyDomains_.all or dirtyDomains_.activity or not (view_ and view_.activitiesView) then
        nextView.activitiesView = ActivityDefinitions.BuildView(nextView, ServerClock.Now())
    else
        nextView.activitiesView = view_.activitiesView
    end
    view_ = nextView
    return view_
end

function GameStateAdapter.Reset()
    authoritative_ = nil
    view_ = nil
    page_ = "home"
    connectionState_ = "syncing"
    dirtyDomains_ = { all = true }
    return RebuildView()
end

function GameStateAdapter.ApplySnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return false, "snapshot must be a table"
    end
    authoritative_ = DeepCopy(snapshot)
    NormalizeStoryGate(authoritative_)
    dirtyDomains_ = { all = true }
    RebuildView()
    return true, view_
end

function GameStateAdapter.ApplySnapshotEvents(events)
    if not authoritative_ then return false end
    if not events or #events == 0 then return true end
    MarkDirtyForEvents(events)
    ApplyEvents(authoritative_, events)
    -- Snapshot events update combat/gates/logs, never the inventory just projected.
    RebuildView(true)
    return true
end

function GameStateAdapter.ApplyDelta(delta)
    if type(delta) ~= "table" then
        return false, "delta must be a table"
    end
    if delta.snapshot then
        return GameStateAdapter.ApplySnapshot(delta.snapshot)
    end
    if not authoritative_ then
        return false, "snapshot required before delta"
    end
    if delta.revision and authoritative_.revision and delta.revision <= authoritative_.revision then
        return true, view_
    end

    BeginDirtyTracking()
    local changes = DeepCopy(delta.changes or delta.changed or delta.state or {})
    MarkDirtyForChanges(changes)
    MarkDirtyForChanges({
        inventory = delta.inventory,
        consumables = delta.consumables,
        logs = delta.logs,
        stats = delta.stats,
    })
    MarkDirtyForEvents(delta.events)
    if next(dirtyDomains_) == nil then MarkDirty("meta") end
    if changes.inventory ~= nil then authoritative_.inventory = ProjectInventory(changes.inventory); changes.inventory = nil end
    if changes.inventoryPatch ~= nil then
        local patch = changes.inventoryPatch
        authoritative_.inventory = authoritative_.inventory or {}
        if type(patch.removed) == "table" then
            local removed = {}
            for _, itemId in ipairs(patch.removed) do removed[tostring(itemId)] = true end
            local kept = {}
            for _, item in ipairs(authoritative_.inventory) do
                if not removed[tostring(item.id)] then kept[#kept + 1] = item end
            end
            authoritative_.inventory = kept
        end
        if type(patch.updated) == "table" then
            local byId = {}
            for _, item in ipairs(authoritative_.inventory) do byId[tostring(item.id)] = item end
            for _, item in ipairs(patch.updated) do
                local current = byId[tostring(item.id)]
                if current then
                    for key, value in pairs(item) do current[key] = DeepCopy(value) end
                else
                    authoritative_.inventory[#authoritative_.inventory + 1] = ProjectEquipment(item)
                end
            end
        end
        if type(patch.added) == "table" then
            for _, item in ipairs(patch.added) do
                authoritative_.inventory[#authoritative_.inventory + 1] = ProjectEquipment(item)
            end
        end
        changes.inventoryPatch = nil
        MarkDirty("inventory")
    end
    if changes.overflowLoot ~= nil then authoritative_.overflowLoot = ProjectInventory(changes.overflowLoot); changes.overflowLoot = nil end
    if changes.lootStash ~= nil then authoritative_.lootStash = DeepCopy(changes.lootStash); changes.lootStash = nil end
    if changes.equipped ~= nil then authoritative_.equipped = changes.equipped; changes.equipped = nil end
    if changes.consumables ~= nil then authoritative_.consumables = changes.consumables; changes.consumables = nil end
    if changes.stats ~= nil then authoritative_.stats = DeepCopy(changes.stats); changes.stats = nil end
    -- activities/quests 整体替换：递归深合并会导致被删除的字段（如打桩 session 清空）残留
    if changes.activities ~= nil then authoritative_.activities = DeepCopy(changes.activities); changes.activities = nil end
    if changes.quests ~= nil then authoritative_.quests = DeepCopy(changes.quests); changes.quests = nil end
    if changes.wishPool ~= nil then authoritative_.wishPool = DeepCopy(changes.wishPool); changes.wishPool = nil end
    if changes.abyss ~= nil then authoritative_.abyss = DeepCopy(changes.abyss); changes.abyss = nil end
    if changes.rewardClaims ~= nil then
        authoritative_.rewardClaims = DeepCopy(changes.rewardClaims)
        changes.rewardClaims = nil
    end
    if changes.challenges ~= nil then
        authoritative_.challenges = DeepCopy(changes.challenges)
        changes.challenges = nil
    end
    Merge(authoritative_, changes)
    if delta.inventory ~= nil then authoritative_.inventory = ProjectInventory(delta.inventory) end
    if delta.consumables ~= nil then authoritative_.consumables = DeepCopy(delta.consumables) end
    if delta.logs ~= nil then authoritative_.logs = DeepCopy(delta.logs) end
    if delta.stats ~= nil then authoritative_.stats = DeepCopy(delta.stats) end
    if delta.revision ~= nil then authoritative_.revision = delta.revision end
    if delta.updatedAt ~= nil then authoritative_.updatedAt = delta.updatedAt end
    ApplyEvents(authoritative_, delta.events)
    NormalizeStoryGate(authoritative_)
    RebuildView()
    return true, view_
end

function GameStateAdapter.SetConnectionState(state)
    local nextState = state or "disconnected"
    if connectionState_ == nextState then return end
    connectionState_ = nextState
    MarkDirty("all")
    RebuildView(true)
end

function GameStateAdapter.SetPage(page)
    page_ = page or "home"
    MarkDirty("all")
    RebuildView()
end

function GameStateAdapter.GetDirtyDomains()
    return DeepCopy(dirtyDomains_)
end

function GameStateAdapter.GetViewState()
    return view_ or RebuildView()
end

function GameStateAdapter.GetRevision()
    return authoritative_ and authoritative_.revision or 0
end

function GameStateAdapter.IsAdmin()
    return authoritative_ ~= nil and authoritative_.isAdmin == true
end

return GameStateAdapter
