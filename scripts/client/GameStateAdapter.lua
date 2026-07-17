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

local function EventText(value)
    local kind = value and value.kind
    if kind == "cell_entered" then
        return string.format("前进到第%d/100格。", value.position or 0)
    elseif kind == "battle_reward" then
        return string.format("战斗胜利：金币%d、经验%d。", value.gold or 0, value.exp or 0)
    elseif kind == "battle_lost" then
        return "挑战失败，已退回修整。"
    elseif kind == "equipment_drop" then
        return "获得装备：" .. tostring(value.name or value.itemId or "未知装备")
    elseif kind == "level_up" then
        return "等级提升至 " .. tostring(value.level or "?") .. " 级"
    elseif kind == "floor_advanced" then
        return "进入第" .. tostring(value.floor or "?") .. "层。"
    elseif kind == "chest_reward" then
        return string.format("开启宝箱：金币%d、碎片%d。", value.gold or 0, value.fragments or 0)
    elseif kind == "merchant_trade" then
        return string.format("商人交易：消耗金币%d，获得碎片%d。", value.goldSpent or 0, value.fragments or 0)
    elseif kind == "merchant_skipped" then
        return "遇到商人，但金币不足。"
    elseif kind == "wish_pool" then
        return "许愿池回应：获得金币" .. tostring(value.gold or 0) .. "。"
    elseif kind == "teleport" then
        return "传送门启动：前进至第" .. tostring(value.position or 0) .. "格。"
    elseif kind == "altar_heal" then
        return "古代祭坛赐福：恢复生命。"
    elseif kind == "abyss_echo" then
        return "深渊回声：获得碎片" .. tostring(value.fragments or 0) .. "。"
    elseif kind == "inventory_full" then
        return "背包已满，自动挂机已暂停。"
    elseif kind == "offline_collected" then
        return string.format("领取离线收益：金币%d、经验%d、碎片%d。", value.gold or 0, value.exp or 0, value.fragments or 0)
    elseif kind == "equipment_equipped" then
        return "装备已穿戴至" .. tostring(value.slot or "目标槽位") .. "。"
    elseif kind == "equipment_decomposed" then
        return string.format("分解%d件装备，获得碎片%d。", value.count or 0, value.fragments or 0)
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
        if value.kind == "battle" then
            local prefix = value.lucky and "触发777" or (value.critical and "暴击" or "造成")
            state.recentDamage = prefix .. " " .. tostring(value.lastDamage or 0) .. " 伤害"
        end
        local text = EventText(value)
        if text then table.insert(state.logs, 1, text) end
    end
    while #state.logs > 40 do table.remove(state.logs) end
end

local function NextExp(level)
    return math.floor(100 * (1.15 ^ (math.max(1, level or 1) - 1)))
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
        gold = 0,
        fragments = 0,
        mythShards = 0,
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
    nextView.nextExp = nextView.nextExp or NextExp(nextView.level)
    nextView.pendingOfflineSeconds = nextView.pendingOfflineSeconds or 0
    nextView.offlineSeconds = nextView.pendingOfflineSeconds
    nextView.stepTimer = nextView.stepTimer or 0
    nextView.logs = nextView.logs or {}
    nextView.inventory = nextView.inventory or {}
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
    for slot, itemId in pairs(nextView.equippedSlots) do
        if type(itemId) == "table" then
            equippedObjects[slot] = itemId
        else
            equippedObjects[slot] = byId[tostring(itemId)]
        end
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
    if changes.inventory ~= nil then authoritative_.inventory = changes.inventory; changes.inventory = nil end
    if changes.equipped ~= nil then authoritative_.equipped = changes.equipped; changes.equipped = nil end
    if changes.consumables ~= nil then authoritative_.consumables = changes.consumables; changes.consumables = nil end
    Merge(authoritative_, changes)
    if delta.inventory ~= nil then authoritative_.inventory = DeepCopy(delta.inventory) end
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
