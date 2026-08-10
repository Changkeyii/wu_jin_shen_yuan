# 02 · 状态与事件 Schema（shared/GameStateSchema.lua + GameEventSchema.lua）

> 这套 Schema 定义了"玩家档案长什么样、网络传输的快照/增量长什么样、游戏事件长什么样"，并且**前后端共用同一份校验实现**。任何一端写出的状态都会被另一端用相同规则验证。

文件：
- `scripts/shared/GameStateSchema.lua`（1888 行）
- `scripts/shared/GameEventSchema.lua`（376 行）

---

## 1. 三个核心概念

| 概念 | 说明 | 产生端 | 消费端 |
|------|------|--------|--------|
| **权威状态（authoritative state）** | 服务端内存中、已通过 `ValidateState` 的完整玩家档案 | 服务端 | 服务端 |
| **Snapshot（快照）** | 权威状态的一次网络投影（全量，含背包） | 服务端 | 客户端 |
| **Delta（增量）** | 一次变更的差异（scalar 字段 + 可选全量背包 + 事件列表） | 服务端 | 客户端 |

三者共享 `NetworkProtocol.ValidateValue` 作为底层递归校验器（见文档 01）。

---

## 2. 常量与字段分类

```lua
GameStateSchema.VERSION = 6                 -- Schema 版本，快照/增量都必须匹配
GameStateSchema.INVENTORY_CAP = 300
GameStateSchema.TEMPORARY_LOOT_CAP = 60
GameStateSchema.LOOT_STASH_CAP = 60
GameStateSchema.OFFLINE_MAX_SECONDS = 12 * 60 * 60
GameStateSchema.MAX_LOGS = 40
GameStateSchema.MAX_APPLIED_GM_COMMANDS = 64
GameStateSchema.MAX_GM_COMMAND_ID_LENGTH = 96

GameStateSchema.SLOTS = { ... }             -- 12 个装备槽位定义
GameStateSchema.RARITIES = RarityCatalog.ORDER   -- 品质顺序
GameStateSchema.SET_IDS = { "nightmare", "lucky", "voyage", "abyss", "prophecy" }
GameStateSchema.EVENT_TYPES = { "monster", "elite", "chest", "merchant", "random", "boss", "chapter_boss" }
```

**字段白名单三张表**（防止字段漂移）：

```lua
local PERSISTED_FIELDS = { ... }   -- 哪些字段会写进云存档（45 个字段）
local SNAPSHOT_FIELDS = { ... }    -- 哪些字段进入快照
local DELTA_FIELD_SET = { ... }    -- 哪些字段允许出现在 delta.changes
```

设计要点：
- **持久化字段**：`ToPersistedState` 只挑 `PERSISTED_FIELDS` 里的字段写出，其中 `inventory`/`overflowLoot` 有专门的网络投影（去掉 `power` 等派生字段）。
- **快照字段**：`SNAPSHOT_FIELDS` 全量复制；背包经 `networkInventory()` 处理。
- **增量字段**：`BuildDelta` 只放进 `DELTA_FIELD_SET` 里的字段；未列入的白名单字段即使变了也不会出现在增量中，客户端会忽略。

---

## 3. 初始状态 `NewInitialState`

```lua
function GameStateSchema.NewInitialState(now)
    now = currentTime(now)
    return {
        schemaVersion = GameStateSchema.VERSION,
        revision = 0,                     -- 版本号：每次提交 +1，客户端据此去旧
        updatedAt = now,
        lastActiveAt = now,
        pendingOfflineSeconds = 0,
        level = 1, vipLevel = 0,
        dailyVip = { signInDay = 0, adDay = 0 },
        exp = 0, floor = 1, maxFloor = 1, position = 0,
        gold = LargeNumber.Zero(),
        fragments = LargeNumber.Zero(),
        autoRun = false, nextItemId = 1,
        inventory = {}, overflowLoot = {}, lootStash = {}, equipped = {},
        consumables = { healthPotion = 0 },
        hp = 1, hpBig = BigNumber.FromNumber(1),
        inventoryPolicy = {
            pauseOnFull = true, autoDecompose = false, autoSell = false,
            decomposeRarities = { common=false, advanced=false, rare=false, artifact=false, legendary=false, epic=false, myth=false },
            sellRarities = { common=false, advanced=false, rare=false, artifact=false, legendary=false, epic=false, myth=false },
        },
        automationPolicy = { autoEquip = false, lootAutoEquip = false, autoSkipStory = false },
        interactionMode = "normal",
        rewardPity = { epicMisses = 0, mythMisses = 0 },
        storyProgress = { introCompleted = false, highestCompletedChapter = 0, contentVersion = 1 },
        pendingStoryGate = nil, pendingEvent = nil,
        ruleAcknowledgements = {}, equipmentCollection = {}, marketListings = {},
        pendingEquipDecision = nil, previousLoadout = nil,
        appliedGmCommandIds = {},
        currentMonster = nil, logs = {}, currentEvent = "monster", recentDamage = "",
    }
end
```

> 数值字段两类：**scalar number**（`level/exp/floor/position`）和 **BigNumber**（`gold/fragments/hpBig`）。大数用三段式 `{high, mid, low}` 表示（见 `LargeNumber`），避免 27 位十进制溢出。

---

## 4. 持久化投影 `ToPersistedState`

只保留 `PERSISTED_FIELDS`，并把装备实例"规范化"成持久化形态（去派生字段、补默认值、归一化品质 ID）：

```lua
function GameStateSchema.ToPersistedState(state)
    local persisted = {}
    for _, fieldName in ipairs(PERSISTED_FIELDS) do
        local value = state[fieldName]
        if fieldName == "inventory" or fieldName == "overflowLoot" then
            local items = {}
            for _, item in ipairs(value or {}) do
                items[#items + 1] = {
                    id = item.id, equipmentId = item.equipmentId,
                    level = item.level, enhance = item.enhance, star = item.star,
                    locked = item.locked == true, acquiredAt = item.acquiredAt or 0,
                    source = item.source or "legacy", tradeable = item.tradeable == true,
                    statVersion = item.statVersion or 5,
                    budget = item.budget, budgetBig = deepCopy(item.budgetBig),
                    rarity = RarityCatalog.NormalizeId(item.rarity),
                    setEnabled = item.setEnabled ~= false, setId = item.setId,
                    roll = item.roll or 1,
                    atk = item.atk, def = item.def, hp = item.hp,
                    atkBig = deepCopy(item.atkBig), defBig = deepCopy(item.defBig),
                    hpBig = deepCopy(item.hpBig),
                    crit = item.crit, critDmg = item.critDmg, atkSpeed = item.atkSpeed,
                    lifeSteal = item.lifeSteal, damageReduction = item.damageReduction,
                    bossDamage = item.bossDamage,
                    coreAffixes = copyArray(item.coreAffixes), uniqueEffect = item.uniqueEffect,
                    aidLocked = item.aidLocked == true, aidFloor = item.aidFloor,
                    investedGold = ..., investedFragments = item.investedFragments or 0,
                }
            end
            persisted[fieldName] = items
        elseif value ~= nil then
            persisted[fieldName] = deepCopy(value)
        end
    end
    -- 兼容旧字段 itemSequence → nextItemId
    ...
    -- 移除网络派生字段 power
    for _, item in ipairs(persisted.inventory or {}) do item.power = nil end
    return persisted
end
```

---

## 5. 状态校验 `ValidateState`

**三层校验**：结构 Schema 校验 → 业务规则校验 → 引用完整性校验。

```lua
function GameStateSchema.ValidateState(state)
    if type(state) ~= "table" then return false, stateError("State must be a table", "$state") end

    -- 1) 结构校验：转持久化形态后按 PERSISTED_SCHEMA 递归校验
    local persisted = GameStateSchema.ToPersistedState(state)
    local ok, validationError = NetworkProtocol.ValidateValue(persisted, GameStateSchema.PERSISTED_SCHEMA, "$state")
    if not ok then ... return false, stateError(...) end

    -- 2) 业务规则
    if persisted.maxFloor < persisted.floor then return false, stateError("maxFloor cannot be lower than floor", "$state.maxFloor") end
    if persisted.exp >= nextExp(persisted.level) then return false, stateError("Experience must be normalized for the current level", "$state.exp") end

    -- 3) 引用完整性
    local inventoryById, allItemIds = {}, {}
    for index, item in ipairs(persisted.inventory) do
        local idKey = tostring(item.id)
        if inventoryById[idKey] then return false, stateError("Equipment ids must be unique", ...) end
        local definition = EquipmentCatalog.Get(item.equipmentId)
        if not definition then return false, stateError("Unknown equipment definition", ...) end
        inventoryById[idKey] = item
        allItemIds[idKey] = true
    end
    -- overflowLoot 与 inventory 的 id 不能重复
    -- lootStash 里的 itemId 必须存在于 inventory
    -- equipped 的 item 必须存在且 slot 匹配，一件装备不能占多个槽
    ...
    return true, nil
end
```

关键不变量：
- 装备实例 id 全局唯一（inventory + overflowLoot 不重叠）
- `equipmentId` 必须存在于 `EquipmentCatalog`
- `equipped[slot]` 指向的装备其定义 `definition.slot` 必须等于该槽
- `lootStash` 元素必须都能在 `inventory` 中索引到
- 日志最多 `MAX_LOGS`（40）条

---

## 6. 快照构建与校验

### 6.1 构建 `BuildSnapshot`

```lua
function GameStateSchema.BuildSnapshot(state, options)
    options = options or {}
    local snapshot = {
        kind = "GameSnapshot",
        schemaVersion = state.schemaVersion or GameStateSchema.VERSION,
        revision = state.revision or 0,
        updatedAt = state.updatedAt or 0,
        serverTime = currentTime(options.serverTime),
        status = options.status or "ready",
        isAdmin = options.isAdmin == true,
        playerNickname = options.playerNickname,
        inventoryCapacity = options.inventoryCapacity or GameStateSchema.INVENTORY_CAP,
    }
    for _, fieldName in ipairs(SNAPSHOT_FIELDS) do
        if state[fieldName] ~= nil then snapshot[fieldName] = deepCopy(state[fieldName]) end
    end
    snapshot.inventory = networkInventory(state.inventory)      -- 装备网络投影（补 power 等）
    snapshot.overflowLoot = networkInventory(state.overflowLoot)
    snapshot.lootStash = deepCopy(state.lootStash or {})
    snapshot.equipped = deepCopy(state.equipped or {})
    snapshot.consumables = deepCopy(state.consumables or {})
    snapshot.nextExp = options.nextExp or snapshot.nextExp or nextExp(snapshot.level or 1)
    if options.stats ~= nil then snapshot.stats = deepCopy(options.stats) end

    -- 战力快照字段：从 stats 或顶层取
    for _, fieldName in ipairs({
        "displayedPower", "recommendedPower", "nextChapterRecommendedPower", "powerRatio",
        "headroomFloors", "difficultyLabel", "bossScore", "eliteScore", "estimatedEasyFloor",
    }) do
        if snapshot[fieldName] == nil and stats[fieldName] ~= nil then
            snapshot[fieldName] = deepCopy(stats[fieldName])
        end
    end
    snapshot.displayedPower = snapshot.displayedPower or stats.power or 0

    -- 注入计算钩子：itemPower（战力）、itemMarketQuote（市场底价）
    if options.itemPower ~= nil then
        for _, item in ipairs(snapshot.inventory or {}) do item.power = options.itemPower(item) end
    end
    if options.itemMarketQuote ~= nil then ... end
    return snapshot
end
```

### 6.2 校验 `ValidateSnapshot`

```lua
function GameStateSchema.ValidateSnapshot(snapshot)
    if type(snapshot) ~= "table" or snapshot.kind ~= "GameSnapshot" then
        return false, stateError("Invalid snapshot envelope", "$snapshot")
    end
    -- 未知字段拒绝（SNAPSHOT_FIELD_SET 白名单）
    for fieldName in pairs(snapshot) do
        if not SNAPSHOT_FIELD_SET[fieldName] then
            return false, stateError("Snapshot contains an unknown field", "$snapshot." .. tostring(fieldName))
        end
    end
    -- 版本必须匹配
    if snapshot.schemaVersion ~= GameStateSchema.VERSION then ... end
    -- revision 非负整数
    if type(snapshot.revision) ~= "number" or snapshot.revision < 0 ... end
    -- 必填字段
    for _, fieldName in ipairs(SNAPSHOT_REQUIRED_FIELDS) do ... end
    -- 边界字段逐项校验（SNAPSHOT_ENVELOPE_SCHEMAS / SNAPSHOT_VALUE_SCHEMAS）
    ...
    -- 背包引用完整性（loadout）
    local loadoutOk, loadoutError = validateNetworkLoadout(snapshot.inventory, snapshot.overflowLoot, snapshot.equipped, "$snapshot")
    ...
    return true, nil
end
```

---

## 7. 增量构建与校验

### 7.1 构建 `BuildDelta`

```lua
function GameStateSchema.BuildDelta(revision, changes, options)
    changes = changes or {}
    options = options or {}
    local deltaChanges = {}
    for fieldName, value in pairs(changes) do
        if DELTA_FIELD_SET[fieldName] then
            deltaChanges[fieldName] = deepCopy(value)
        end
    end

    -- 背包相关变化必须携带"全量背包"（保证客户端可重建）
    local inventoryChanged = options.inventoryChanged == true
        or changes.inventory ~= nil or changes.overflowLoot ~= nil
        or changes.lootStash ~= nil or changes.equipped ~= nil or changes.consumables ~= nil
    if inventoryChanged and options.state ~= nil then
        deltaChanges.inventory = networkInventory(options.state.inventory or {})
        deltaChanges.overflowLoot = networkInventory(options.state.overflowLoot or {})
        deltaChanges.lootStash = deepCopy(options.state.lootStash or {})
        deltaChanges.equipped = deepCopy(options.state.equipped or {})
        deltaChanges.consumables = deepCopy(options.state.consumables or {})
    end

    return {
        kind = "GameDelta",
        schemaVersion = GameStateSchema.VERSION,
        revision = revision,
        serverTime = currentTime(options.serverTime),
        inventoryChanged = inventoryChanged,
        changes = deltaChanges,
    }
end
```

> ⚠️ 重要约定：**一旦背包/装备/消耗品有任何变化，delta 必须携带全量背包**（`inventoryChanged=true` 且 `changes.inventory` 是完整列表）。否则客户端无法正确处理增删。这是 `ValidateDelta` 的强制校验项。

### 7.2 校验 `ValidateDelta`

```lua
function GameStateSchema.ValidateDelta(delta)
    if type(delta) ~= "table" or delta.kind ~= "GameDelta" then
        return false, stateError("Invalid delta envelope", "$delta")
    end
    -- 信封字段白名单 + schemaVersion + revision 检查（同上）
    ...
    -- 未知 changes 字段拒绝
    for fieldName in pairs(delta.changes) do
        if not DELTA_FIELD_SET[fieldName] then return false, stateError("Delta contains an unknown field", "$delta.changes." .. tostring(fieldName)) end
    end
    -- 背包增量必须完整
    if delta.inventoryChanged then
        if type(delta.changes.inventory) ~= "table" or ... then return false, stateError("Inventory deltas must include full inventory", "$delta.changes") end
        local loadoutOk, loadoutError = validateNetworkLoadout(delta.changes.inventory, delta.changes.overflowLoot, delta.changes.equipped, "$delta.changes")
        if not loadoutOk then return false, loadoutError end
    elseif delta.changes.inventory ~= nil or ... then
        return false, stateError("Inventory fields require inventoryChanged", "$delta.inventoryChanged")
    end
    -- 事件列表必须合法
    if delta.events ~= nil then
        local eventsOk, eventsReason = GameEventSchema.ValidateList(delta.events, "$delta.events")
        if not eventsOk then return false, stateError(eventsReason, "$delta.events") end
    end
    return true, nil
end
```

---

## 8. 网络背包投影 `networkItem / networkInventory`

装备实例在传输前的投影：保留权威数值，补网络需要的展示字段（`power`、`name` 等由构建方注入），并去掉服务端内部字段。

```lua
local function networkItem(item)
    local result = {
        id = item.id,
        equipmentId = item.equipmentId,
        level = item.level, enhance = item.enhance, star = item.star,
        rarity = item.rarity,
        locked = item.locked == true, source = item.source,
        statVersion = item.statVersion,
        atk = item.atk, def = item.def, hp = item.hp,
        atkBig = copyBig(item.atkBig), defBig = copyBig(item.defBig), hpBig = copyBig(item.hpBig),
        crit = item.crit, critDmg = item.critDmg, atkSpeed = item.atkSpeed,
        lifeSteal = item.lifeSteal, damageReduction = item.damageReduction, bossDamage = item.bossDamage,
        coreAffixes = copyArray(item.coreAffixes),
        setEnabled = item.setEnabled, setId = item.setId,
        budget = item.budget, budgetBig = copyBig(item.budgetBig),
        investedGold = ..., investedFragments = item.investedFragments,
    }
    return result
end

local function networkInventory(items)
    local result = {}
    for _, item in ipairs(items or {}) do result[#result + 1] = networkItem(item) end
    return result
end
```

---

## 9. 事件 Schema（GameEventSchema）

每个事件定义 `type` + `kind` + 字段约束，用 `NetworkProtocol.ValidateValue` 校验。核心 API：

```lua
GameEventSchema.VERSION = 3
GameEventSchema.MAX_EVENTS = 128

function GameEventSchema.IsKnown(eventType)
    return KNOWN[eventType] == true
end

function GameEventSchema.Validate(event, path)      -- 校验单个事件
function GameEventSchema.ValidateList(events, path) -- 校验事件列表
```

典型事件定义（节选自 `GameEventSchema.lua`）：

```lua
local KNOWN = {
    cell_entered = { ... },
    battle_started = { fields = { monster = {}, floor = {}, room = {} }, ... },
    monster_spawned = { ... },
    player_attack_hit = { fields = { amount = {}, amountBig = {}, critical = {}, ... } },
    player_damaged = { fields = { amount = {}, hp = {}, maxHp = {}, source = {} }, ... },
    player_healed = { ... },
    battle_won / battle_lost / monster_defeated = { ... },
    battle_reward = { fields = { gold = {}, exp = {} }, ... },
    loot_dropped = { fields = { itemId = {}, name = {}, rarity = {}, icon = {} }, ... },
    loot_settled = { fields = { outcome = {} }, ... },
    level_up = { fields = { level = {} }, ... },
    floor_advanced / floor_reset = { ... },
    story_gate / story_advanced / story_completed = { ... },
    event_pending / event_resolved = { ... },
    equipment_drop / equipment_equipped / equipment_unequipped = { ... },
    equipment_decomposed / equipment_sold = { fields = { count = {}, gold = {}, fragments = {} }, ... },
    equipment_strengthened / equipment_starred = { ... },
    offline_collected = { fields = { gold = {}, exp = {}, fragments = {}, equipment = {} }, ... },
    ...
}
```

---

## 10. 状态生命周期（服务端视角）

```
NewInitialState / StateFactory.Create
      │  StateNormalizer.Normalize        （补默认值、迁移旧版本、补 BigNumber）
      ▼
authoritative state  ── ValidateState ──►  合法
      │
      │  GameEngine.Strengthen(state, ...)  （领域纯函数）
      ▼
proposal{ ok, state, delta, commit, events }
      │  ValidateState(proposal.state)
      │  repository:Commit(old, new)   （写云存储）
      ▼
session.state = proposal.state
      │
      ├──► SendSnapshot（全量，含 itemPower/itemMarketQuote 钩子）
      └──► SendDelta（增量 + 事件）
```

---

## 11. 前后端如何共用

| 动作 | 服务端 | 客户端 |
|------|--------|--------|
| 构建快照 | `GameStateSchema.BuildSnapshot` | — |
| 校验快照 | `ValidateSnapshot`（发送前） | `ValidateSnapshot`（接收后，`ServerClient.ApplyCompleteSnapshot`） |
| 构建增量 | `GameStateSchema.BuildDelta` | — |
| 校验增量 | `ValidateDelta`（发送前） | `ValidateDelta`（接收后，`ServerClient.HandleDelta`） |
| 校验完整状态 | `ValidateState`（Apply 前后） | — |
| 校验事件 | `GameEventSchema.ValidateList` | `GameEventSchema.ValidateList`（`PrepareEventsForClient`） |

> 正是因为前后端共用这份 Schema，客户端可以信任"服务端下发的快照/增量一定通过校验"；任何一端发现校验失败都会主动回退到**全量快照重新同步**（`ServerClient.RequestSnapshot`），保证最终一致。
