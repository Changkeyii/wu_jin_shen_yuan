local EquipmentCatalog = require("shared.EquipmentCatalog")
local LargeNumber = require("shared.LargeNumber")

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
    return LargeNumber.Format(value or 0)
end

local function EventText(value)
    local kind = value and value.kind
    if kind == "cell_entered" then
        return string.format("前进到第%d/100格。", value.position or 0)
    elseif kind == "battle_reward" then
        return "战斗胜利：金币" .. FormatValue(value.gold) .. "、经验" .. FormatValue(value.exp) .. "。"
    elseif kind == "battle_lost" then
        return "挑战失败，已退回修整。"
    elseif kind == "equipment_drop" then
        return "获得装备：" .. tostring(value.name or value.itemId or "未知装备")
    elseif kind == "level_up" then
        return "等级提升至 " .. tostring(value.level or "?") .. " 级"
    elseif kind == "floor_advanced" then
        return "进入第" .. tostring(value.floor or "?") .. "层。"
    elseif kind == "chest_reward" then
        return "开启宝箱：金币" .. FormatValue(value.gold) .. "、碎片" .. FormatValue(value.fragments) .. "。"
    elseif kind == "merchant_trade" then
        return string.format("商人交易：消耗金币%d，获得碎片%d。", value.goldSpent or 0, value.fragments or 0)
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
    end
    return nil
end

local function ApplyEvents(state, events)
    state.logs = state.logs or {}
    for _, value in ipairs(events or {}) do
        local kind = value.kind
        if kind == "battle_won" then
            state.currentMonster = nil
        elseif kind == "battle_hit" then
            local prefix = value.lucky and "触发777" or (value.critical and "暴击" or "命中")
            state.recentDamage = prefix .. " " .. tostring(value.damage or 0) .. " 伤害，怪物剩余 " .. tostring(value.monsterHp or 0)
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
    if type(item) ~= "table" or not item.equipmentId then return item end
    local definition = EquipmentCatalog.Get(item.equipmentId)
    if not definition then return item end
    local projected = DeepCopy(definition)
    projected.id = item.id
    projected.equipmentId = definition.id
    projected.level = item.level or definition.level
    projected.enhance = item.enhance or 0
    projected.star = item.star or 0
    projected.locked = item.locked == true
    projected.acquiredAt = item.acquiredAt or 0
    projected.source = item.source or "legacy"
    projected.investedGold = item.investedGold or 0
    projected.investedFragments = item.investedFragments or 0
    projected.power = item.power
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
        schemaVersion = 1,
        revision = 0,
        updatedAt = 0,
        floor = 1,
        maxFloor = 1,
        position = 0,
        level = 1,
        exp = 0,
        nextExp = 100,
        gold = LargeNumber.Zero(),
        fragments = LargeNumber.Zero(),
        mythShards = LargeNumber.Zero(),
        autoRun = false,
        pendingOfflineSeconds = 0,
        offlineSeconds = 0,
        stepTimer = 0,
        hp = 1,
        stats = {
            atk = 0,
            def = 0,
            hp = 1,
            crit = 0,
            critDmg = 1.5,
            atkSpeed = 1,
            lifeSteal = 0,
            power = 0,
        },
        inventory = {},
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
    nextView.equipmentInventoryCount = #nextView.inventory
    nextView.inventoryCapacity = nextView.inventoryCapacity or 300
    nextView.equippedSlots = nextView.equippedSlots or nextView.equipped or {}

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
    if changes.equipped ~= nil then authoritative_.equipped = changes.equipped; changes.equipped = nil end
    if changes.consumables ~= nil then authoritative_.consumables = changes.consumables; changes.consumables = nil end
    Merge(authoritative_, changes)
    if delta.inventory ~= nil then authoritative_.inventory = ProjectInventory(delta.inventory) end
    if delta.consumables ~= nil then authoritative_.consumables = DeepCopy(delta.consumables) end
    if delta.logs ~= nil then authoritative_.logs = DeepCopy(delta.logs) end
    if delta.stats ~= nil then authoritative_.stats = DeepCopy(delta.stats) end
    if delta.revision ~= nil then authoritative_.revision = delta.revision end
    if delta.updatedAt ~= nil then authoritative_.updatedAt = delta.updatedAt end
    ApplyEvents(authoritative_, delta.events)
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
