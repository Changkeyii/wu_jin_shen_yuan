# 02 · 状态与事件 Schema（shared/GameState* 拆分模块 + GameEventSchema）

> 这套 Schema 定义了"玩家档案长什么样、网络传输的快照/增量长什么样、游戏事件长什么样"，并且**前后端共用同一份校验实现**。
>
> 📌 **最新版结构**：原 `GameStateSchema.lua`（1888 行）已按职责拆分为 **1 个聚合门面 + 6 个模块**。`GameStateSchema` 只做转发，各模块职责单一。

相关文件：
- `scripts/shared/GameStateSchema.lua`（40 行）—— **聚合门面**
- `scripts/shared/GameStateContracts.lua`（164 行）—— 契约常量
- `scripts/shared/GameStatePolicy.lua`（11 行）—— 策略常量
- `scripts/shared/GameStateBoundarySchemas.lua`（365 行）—— 边界 Schema 表
- `scripts/shared/GameStatePersistence.lua`（326 行）—— 持久化/归一化/初始状态
- `scripts/shared/GameStateValidation.lua`（146 行）—— 状态校验
- `scripts/shared/GameStateWire.lua`（439 行）—— 网络快照/增量
- `scripts/shared/GameStateDefinitions.lua`（758 行）—— 持久化字段表/装备网络投影
- `scripts/shared/GameProgression.lua`（12 行）—— 经验曲线
- `scripts/shared/GameEventSchema.lua`（376 行）—— 事件校验

---

## 1. 聚合门面（GameStateSchema.lua）

```lua
local Contracts  = require("shared.GameStateContracts")
local Policy     = require("shared.GameStatePolicy")
local Boundary   = require("shared.GameStateBoundarySchemas")
local Persistence= require("shared.GameStatePersistence")
local Validation = require("shared.GameStateValidation")
local Wire       = require("shared.GameStateWire")
local Progression= require("shared.GameProgression")
local TableUtils = require("shared.TableUtils")

local GameStateSchema = {
    VERSION = Contracts.VERSION,
    INVENTORY_CAP = Policy.INVENTORY_CAP,
    TEMPORARY_LOOT_CAP = Policy.TEMPORARY_LOOT_CAP,
    LOOT_STASH_CAP = Policy.LOOT_STASH_CAP,
    OFFLINE_MAX_SECONDS = Policy.OFFLINE_MAX_SECONDS,
    MAX_LOGS = Policy.MAX_LOGS,
    MAX_APPLIED_GM_COMMANDS = Policy.MAX_APPLIED_GM_COMMANDS,
    MAX_GM_COMMAND_ID_LENGTH = Policy.MAX_GM_COMMAND_ID_LENGTH,
    SLOTS = Contracts.SLOTS,
    RARITIES = Contracts.RARITIES,
    SET_IDS = Contracts.SET_IDS,
    EVENT_TYPES = Contracts.EVENT_TYPES,
    PERSISTED_SCHEMA = Boundary.PERSISTED_SCHEMA,
    NewInitialState = Persistence.NewInitialState,
    ToPersistedState = Persistence.ToPersistedState,
    NormalizeState = Persistence.NormalizeState,
    NormalizeMarketListings = Persistence.NormalizeMarketListings,
    NormalizeAppliedGmCommandIds = Persistence.NormalizeAppliedGmCommandIds,
    ValidateState = Validation.ValidateState,
    ValidateStats = Validation.ValidateStats,
    BuildSnapshot = Wire.BuildSnapshot,
    BuildSnapshotEvents = Wire.BuildSnapshotEvents,
    BuildDelta = Wire.BuildDelta,
    ValidateSnapshot = Wire.ValidateSnapshot,
    ValidateDelta = Wire.ValidateDelta,
    DeepCopy = TableUtils.DeepCopy,
    NextExp = Progression.NextExp,
}

return GameStateSchema
```

> 业务代码仍统一 `require("shared.GameStateSchema")`，内部自动转发到各模块。新增字段/校验时按职责改对应模块即可。

---

## 2. 模块职责分工

| 模块 | 内容 | 关键导出 |
|------|------|---------|
| `GameStateContracts` | **契约常量 + 字段白名单**：版本、槽位、稀有度、套装、事件类型、持久化/快照/增量字段表 | `VERSION / SLOTS / RARITIES / SET_IDS / EVENT_TYPES / PERSISTED_FIELDS / SNAPSHOT_FIELDS / DELTA_FIELD_SET / SNAPSHOT_FIELD_SET / DELTA_ENVELOPE_FIELD_SET` |
| `GameStatePolicy` | 容量/时长等策略常量 | `INVENTORY_CAP / TEMPORARY_LOOT_CAP / LOOT_STASH_CAP / OFFLINE_MAX_SECONDS / MAX_LOGS / MAX_APPLIED_GM_COMMANDS / MAX_GM_COMMAND_ID_LENGTH` |
| `GameStateDefinitions` | 边界 Schema 定义与校验函数 | `ITEM_SCHEMA / STATS_SCHEMA / SET_PROGRESS_SCHEMA / MARKET_LISTINGS_SCHEMA / LOADOUT_BACKUP_SCHEMA / ValidateEquipped / ValidateLootStash / ValidateConsumables / ...` |
| `GameStateBoundarySchemas` | 聚合各 Schema 成校验用表 | `PERSISTED_SCHEMA / SNAPSHOT_ENVELOPE_SCHEMAS / DELTA_ENVELOPE_SCHEMAS / SNAPSHOT_VALUE_SCHEMAS` |
| `GameStatePersistence` | 初始状态 / 持久化投影 / 归一化 | `NewInitialState / ToPersistedState / NormalizeState / NormalizeMarketListings / NormalizeAppliedGmCommandIds` |
| `GameStateValidation` | 完整状态 / stats 校验 | `ValidateState / ValidateStats` |
| `GameStateWire` | 网络快照/增量构建与校验 + **装备网络投影** | `BuildSnapshot / BuildSnapshotEvents / BuildDelta / ValidateSnapshot / ValidateDelta / networkItem / networkInventory` |
| `GameProgression` | 经验曲线 | `NextExp` |

**依赖方向**（单向，无环）：
```
GameStateContracts ◄── GameStateDefinitions（Schema 定义）
GameStateContracts ◄── GameStatePersistence / GameStateValidation / GameStateWire（字段白名单）
GameStateDefinitions ◄── GameStateBoundarySchemas（聚合 Schema 表）
GameStatePersistence / GameStateValidation / GameStateWire ──► GameStateBoundarySchemas
GameStateSchema      ──► 以上全部（门面）
```

---

## 3. 核心概念

| 概念 | 说明 | 产生端 | 消费端 |
|------|------|--------|--------|
| **权威状态** | 服务端内存中、已通过 `ValidateState` 的完整玩家档案 | 服务端 | 服务端 |
| **Snapshot（快照）** | 权威状态的网络投影（全量，含背包） | 服务端 | 客户端 |
| **Delta（增量）** | 一次变更的差异（scalar 字段 + 可选全量背包 + 事件列表） | 服务端 | 客户端 |

三者共享 `NetworkProtocol.ValidateValue` 作为底层递归校验器（见文档 01）。

---

## 4. 初始状态 `Persistence.NewInitialState`

```lua
function Persistence.NewInitialState(now)
    now = currentTime(now)
    return {
        schemaVersion = GameStateSchema.VERSION,
        revision = 0, updatedAt = now, lastActiveAt = now,
        pendingOfflineSeconds = 0,
        level = 1, vipLevel = 0,
        dailyVip = { signInDay = 0, adDay = 0 },
        exp = 0, floor = 1, maxFloor = 1, position = 0,
        gold = LargeNumber.Zero(), fragments = LargeNumber.Zero(),
        autoRun = false, nextItemId = 1,
        inventory = {}, overflowLoot = {}, lootStash = {}, equipped = {},
        consumables = { healthPotion = 0 },
        hp = 1, hpBig = BigNumber.FromNumber(1),
        inventoryPolicy = { ... }, automationPolicy = { ... },
        interactionMode = "normal",
        rewardPity = { epicMisses = 0, mythMisses = 0 },
        storyProgress = { introCompleted = false, highestCompletedChapter = 0, contentVersion = 1 },
        pendingStoryGate = nil, pendingEvent = nil,
        ruleAcknowledgements = {}, equipmentCollection = {}, marketListings = {},
        pendingEquipDecision = nil, previousLoadout = nil,
        appliedGmCommandIds = {},
        currentMonster = nil, logs = {}, currentEvent = "monster", recentDamage = "",
        -- 新增：邮件/任务（MailEngine/QuestEngine 初始化时 Ensure）
        mails = {}, mailCounter = 0, quests = {}, questCounter = 0, ...
    }
end
```

---

## 5. 持久化投影 `Persistence.ToPersistedState`

只保留 `Contracts.PERSISTED_FIELDS`（字段白名单定义在 `GameStateContracts`），装备实例规范化（去派生字段、补默认值、归一化品质 ID）：

```lua
local PERSISTED_FIELDS = Contracts.PERSISTED_FIELDS   -- 白名单来自 GameStateContracts

function Persistence.ToPersistedState(state)
    local persisted = {}
    for _, fieldName in ipairs(PERSISTED_FIELDS) do
        local value = state[fieldName]
        if fieldName == "inventory" or fieldName == "overflowLoot" then
            local items = {}
            for _, item in ipairs(value or {}) do
                items[#items + 1] = normalizeEquipmentItem(item)   -- 装备规范化（去 power 等派生字段）
            end
            persisted[fieldName] = items
        elseif value ~= nil then
            persisted[fieldName] = TableUtils.DeepCopy(value)
        end
    end
    -- 兼容旧字段 itemSequence → nextItemId；移除派生字段 power
    ...
    return persisted
end
```

---

## 6. 状态校验 `Validation.ValidateState`

```lua
function Validation.ValidateState(state)
    if type(state) ~= "table" then return false, stateError("State must be a table", "$state") end
    -- 1) 结构校验：转持久化形态后按 Boundary.PERSISTED_SCHEMA 递归校验
    local persisted = Persistence.ToPersistedState(state)
    local ok, validationError = NetworkProtocol.ValidateValue(persisted, Boundary.PERSISTED_SCHEMA, "$state")
    if not ok then ... return false, stateError(...) end
    -- 2) 业务规则：maxFloor >= floor；exp 已归一化到当前等级
    -- 3) 引用完整性：装备 id 唯一；equipmentId 在 Catalog；equipped slot 匹配；lootStash 引用有效
    ...
    return true, nil
end
```

---

## 7. 网络快照/增量 `GameStateWire`

### 7.1 构建

```lua
-- Wire 内部仍用 GameStateSchema.* 别名指向自身构建函数（见 return 表）：
-- BuildSnapshot / BuildSnapshotEvents / BuildDelta / ValidateSnapshot / ValidateDelta

function Wire.BuildSnapshot(state, options)
    -- kind="GameSnapshot"、schemaVersion、revision、serverTime、status、isAdmin、playerNickname、inventoryCapacity
    -- + SNAPSHOT_FIELDS 全量拷贝 + inventory/overflowLoot 网络投影
    -- + itemPower / itemMarketQuote 计算钩子
    -- + stats 战力快照字段（displayedPower/recommendedPower/powerRatio/...）
    ...
end

function Wire.BuildDelta(revision, changes, options)
    -- 只保留 DELTA_FIELD_SET 字段
    -- 背包变化时强制携带全量 inventory/overflowLoot/equipped/consumables
    -- 返回 { kind="GameDelta", schemaVersion, revision, inventoryChanged, changes }
end
```

### 7.2 校验

```lua
function Wire.ValidateSnapshot(snapshot)
    -- kind 必须是 GameSnapshot；字段白名单（SNAPSHOT_FIELD_SET）
    -- schemaVersion 必须匹配；revision 非负整数；必填字段；边界 Schema 逐项校验
    -- validateNetworkLoadout（背包引用完整性）
    ...
end

function Wire.ValidateDelta(delta)
    -- kind 必须是 GameDelta；信封字段白名单；changes 字段白名单
    -- inventoryChanged=true 时必须带全量背包；否则背包字段不允许出现
    -- 事件列表经 GameEventSchema.ValidateList 校验
    ...
end
```

> ⚠️ **重要约定**：一旦背包/装备/消耗品有任何变化，delta 必须携带**全量背包**（`inventoryChanged=true` 且 `changes.inventory` 是完整列表），否则 `ValidateDelta` 拒绝。

---

## 8. 装备网络投影（GameStateWire.networkItem / networkInventory）

网络传输前的装备投影（在 `GameStateWire.lua` 内部）：保留权威 roll 数值，去掉服务端内部字段：

```lua
-- GameStateWire.lua 内部函数
local function networkItem(item)
    return {
        id = item.id, equipmentId = item.equipmentId,
        level = item.level, enhance = item.enhance, star = item.star,
        rarity = RarityCatalog.NormalizeId(item.rarity),
        locked = item.locked == true, source = item.source,
        statVersion = item.statVersion or 5,
        atk = item.atk, def = item.def, hp = item.hp,
        atkBig = copyBig(item.atkBig), defBig = copyBig(item.defBig), hpBig = copyBig(item.hpBig),
        crit = item.crit, critDmg = item.critDmg, atkSpeed = item.atkSpeed,
        lifeSteal = item.lifeSteal, damageReduction = item.damageReduction, bossDamage = item.bossDamage,
        coreAffixes = copyArray(item.coreAffixes), setEnabled = item.setEnabled, setId = item.setId,
        budget = item.budget, budgetBig = copyBig(item.budgetBig),
        investedGold = ..., investedFragments = item.investedFragments,
    }
end

local function networkInventory(items)   -- 批量投影（快照/增量的背包都用它）
    local result = {}
    for _, item in ipairs(items or {}) do result[#result + 1] = networkItem(item) end
    return result
end
```

`Wire.BuildSnapshot` / `Wire.BuildDelta` 在背包字段处调用 `networkInventory` 生成网络背包。

---

## 9. 事件 Schema（GameEventSchema）

```lua
GameEventSchema.VERSION = 3
GameEventSchema.MAX_EVENTS = 128

function GameEventSchema.IsKnown(eventType)        -- 事件类型是否已知
function GameEventSchema.Validate(event, path)     -- 校验单个事件
function GameEventSchema.ValidateList(events, path)-- 校验事件列表
GameEventSchema.KNOWN = KNOWN                      -- 事件定义表
```

典型事件（节选）：`cell_entered / battle_started / monster_spawned / player_attack_hit / player_damaged / player_healed / battle_won / battle_lost / battle_reward / loot_dropped / loot_settled / level_up / floor_advanced / floor_reset / story_gate / event_pending / event_resolved / equipment_equipped / equipment_decomposed / equipment_sold / equipment_strengthened / equipment_starred / offline_collected / mail_received / quest_progress / quest_claimed ...`

---

## 10. 状态生命周期（服务端视角）

```
NewInitialState / StateFactory.Create
      │  Persistence.NormalizeState（补默认值/迁移旧版本/补 BigNumber）
      ▼
authoritative state ── Validation.ValidateState ──► 合法
      │
      │  GameEngine.XXX(state, ...)  （领域纯函数，见文档 05）
      ▼
proposal{ ok, state, delta, commit, events }
      │  Validation.ValidateState(proposal.state)
      │  repository:Commit(old, new)（写云存储）
      ▼
session.state = proposal.state
      │
      ├──► Wire.BuildSnapshot（全量，含 itemPower/itemMarketQuote 钩子）
      └──► Wire.BuildDelta（增量 + 事件）
```

---

## 11. 前后端如何共用

| 动作 | 服务端 | 客户端 |
|------|--------|--------|
| 构建快照 | `GameStateSchema.BuildSnapshot` | — |
| 校验快照 | `ValidateSnapshot`（发送前） | `ValidateSnapshot`（接收后，`ServerClient`） |
| 构建增量 | `GameStateSchema.BuildDelta` | — |
| 校验增量 | `ValidateDelta`（发送前） | `ValidateDelta`（接收后，`ServerClient.HandleDelta`） |
| 校验完整状态 | `ValidateState`（Apply 前后） | — |
| 校验事件 | `GameEventSchema.ValidateList` | `GameEventSchema.ValidateList` |

> 前后端共用同一份 Schema，任何一端校验失败都会回退到**全量快照重新同步**（`ServerClient.RequestSnapshot`），保证最终一致。
