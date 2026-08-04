local EquipmentCatalog = require("shared.EquipmentCatalog")
local ItemPresentation = require("shared.ItemPresentation")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")

local GameStateAdapter = {}

local authoritative_ = nil
local view_ = nil
local page_ = "home"
local connectionState_ = "syncing"

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
        local remainingText = value.interrupted and "，背包已满，剩余离线收益保留" or ""
        return "领取离线收益（在线1/5）：金币" .. FormatValue(value.gold) .. "、经验" .. FormatValue(value.exp) .. "、碎片" .. FormatValue(value.fragments) .. equipmentText .. remainingText .. "。"
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
        schemaVersion = 6,
        revision = 0,
        updatedAt = 0,
        floor = 1,
        maxFloor = 1,
        position = 0,
        level = 1,
        vipLevel = 0,
        dailyVip = { signInDay = 0, adDay = 0 },
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

local function RebuildView()
    if not authoritative_ then
        view_ = EmptyView()
        return view_
    end

    local nextView = DeepCopy(authoritative_)
    nextView.page = page_
    nextView.connectionState = connectionState_
    nextView.readOnly = connectionState_ ~= "ready"
    nextView.nextExp = nextView.nextExp or math.floor(100 * (1.15 ^ (math.max(1, nextView.level or 1) - 1)))
    nextView.pendingOfflineSeconds = nextView.pendingOfflineSeconds or 0
    nextView.offlineSeconds = nextView.pendingOfflineSeconds
    nextView.stepTimer = nextView.stepTimer or 0
    nextView.logs = nextView.logs or {}
    nextView.inventory = ProjectInventory(nextView.inventory or {})
    nextView.overflowLoot = ProjectInventory(nextView.overflowLoot or {})
    nextView.lootStash = nextView.lootStash or {}
    nextView.marketListings = nextView.marketListings or {}
    nextView.equipmentInventoryCount = #nextView.inventory
    nextView.inventoryCapacity = nextView.inventoryCapacity or 300
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
            local displayed = LargeNumber.ToNumber and LargeNumber.ToNumber(nextView.displayedPower) or nextView.displayedPower
            local recommended = LargeNumber.ToNumber and LargeNumber.ToNumber(nextView.recommendedPower) or nextView.recommendedPower
            if type(displayed) == "number" and type(recommended) == "number" and recommended > 0 then
                nextView.powerRatio = displayed / recommended
            end
        end
    end
    nextView.difficultyLabel = nextView.difficultyLabel or "待评估"

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
    view_ = nextView
    return view_
end

function GameStateAdapter.Reset()
    authoritative_ = nil
    view_ = nil
    page_ = "home"
    connectionState_ = "syncing"
    return RebuildView()
end

function GameStateAdapter.ApplySnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return false, "snapshot must be a table"
    end
    authoritative_ = DeepCopy(snapshot)
    NormalizeStoryGate(authoritative_)
    RebuildView()
    return true, view_
end

function GameStateAdapter.ApplySnapshotEvents(events)
    if not authoritative_ then return false end
    ApplyEvents(authoritative_, events)
    RebuildView()
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

    local changes = DeepCopy(delta.changes or delta.changed or delta.state or {})
    if changes.inventory ~= nil then authoritative_.inventory = ProjectInventory(changes.inventory); changes.inventory = nil end
    if changes.overflowLoot ~= nil then authoritative_.overflowLoot = ProjectInventory(changes.overflowLoot); changes.overflowLoot = nil end
    if changes.lootStash ~= nil then authoritative_.lootStash = DeepCopy(changes.lootStash); changes.lootStash = nil end
    if changes.equipped ~= nil then authoritative_.equipped = changes.equipped; changes.equipped = nil end
    if changes.consumables ~= nil then authoritative_.consumables = changes.consumables; changes.consumables = nil end
    if changes.stats ~= nil then authoritative_.stats = DeepCopy(changes.stats); changes.stats = nil end
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
    connectionState_ = state or "disconnected"
    RebuildView()
end

function GameStateAdapter.SetPage(page)
    page_ = page or "home"
    RebuildView()
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
