# UrhoX 挂机塔防框架 —— 纯净框架文档

> 本目录从项目 `scripts/` 中提炼出一套**可复用的游戏框架**，去掉具体玩法数值与美术表现，保留通用的架构模式与核心代码。适用于：新项目搭建脚手架、理解权威服务器 + 云存档 + 声明式 UI 的完整链路、复用网络/状态/服务端骨架。
>
> 📌 **本文档基于仓库最新代码（commit `f2b29f5` 之后的 `main`）编写**，已覆盖共享层与领域层拆分重构后的结构。

---

## 1. 一句话概括

这是一个 **客户端表现 + 服务端权威 + 云端持久化** 的挂机塔防游戏框架：

- **服务端**是唯一权威：所有玩法结算（战斗、掉落、强化、市场、邮件、任务）都在服务端执行，通过 `serverCloud` 云变量持久化玩家档案。
- **客户端**只负责渲染与交互：通过 `ServerClient` 建立长连接，接收服务端下发的 **快照（Snapshot）+ 增量（Delta）+ 事件（Event）**，驱动声明式 UI（`urhox-libs/UI`）。
- 客户端与**服务端共享**同一套 **协议定义、状态 Schema、事件 Schema、数值库**，保证前后端对"一份状态"的校验与展示完全一致。

---

## 2. 分层架构图（最新版）

```
┌────────────────────────── 客户端 (client/, 58 文件) ────────────────────────┐
│  GameView.lua          客户端编排层：装配 View/Controller + 事件绑定 + Update │
│    │                                                                    │
│    ├── ServerClient.lua    网络层：连接/请求/快照组包/事件总线               │
│    ├── GameStateAdapter.lua  状态适配层：权威态 → 视图态（只读投影）          │
│    ├── Theme.lua           设计规范（配色/主题/稀有度/槽位/套装）             │
│    ├── ViewKit.lua        通用 UI 工具（Txt/ImageProgress/ImageButton...）  │
│    ├── ViewAssets.lua     资源与布局常量（ASSETS/LAYOUT）                   │
│    ├── ItemView.lua       装备展示工具（RarityColor/ItemImage/ItemPower）   │
│    ├── NavigationController.lua  页面路由 + 底部导航                        │
│    ├── Views（页面）        HomeView / TopBarView / InventoryView /         │
│    │                       EquipmentLoadoutView / MarketView / MailView /  │
│    │                       QuestView / LeaderboardDetailView / CodexView… │
│    ├── Controllers（交互）  EquipmentActionController / LootStashController /│
│    │                       OfflineClaimController / DailyVipController /   │
│    │                       QuestController / MailController /              │
│    │                       RewardFeedbackController / FaceSlapController / │
│    │                       LeaderboardController / GameplayDialogsController│
│    └── PlayPresentation.lua + PlayWorldView/PlayHud/PlayEffects  战斗表现层 │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  AbyssCommand / AbyssSnapshot / AbyssDelta / AbyssStatus
                │  （JSON 信封，经 UrhoX 远程事件传输）
┌───────────────▼────────────────────────── 服务端 (server/) ──────────────────┐
│  ServerMain.lua         服务端入口：生命周期 / 握手 / 快照分发 / 服务装配      │
│    │                                                                     │
│    ├── core/            框架内核（与玩法无关，可整体复用）                    │
│    │   ├── PlayerRegistry   连接与玩家会话注册表（代际管理）                  │
│    │   ├── CommandRouter    命令路由（Schema校验/幂等/串行/限流）            │
│    │   ├── RateLimiter      Token Bucket 限流                              │
│    │   ├── OperationQueue   每玩家串行操作队列（防并发写覆盖）               │
│    │   └── AdminPolicy      管理员策略                                     │
│    ├── services/        服务层（会话 / 挂机 / 市场 / 邮件 / 排行榜 / GM）    │
│    │   ├── PlayerProfileService  会话生命周期 / 离线收益 / 状态Apply         │
│    │   ├── IdleRuntimeService    挂机自动战斗驱动器                         │
│    │   ├── MarketService        交易行分片缓存 / 扫货 / 结算                 │
│    │   ├── MailService          邮件补发 / 过期清理                         │
│    │   ├── LeaderboardService   排行榜 blob 维护                            │
│    │   └── AdminService         GM 命令执行与审计                            │
│    ├── domain/          领域层（纯函数，不含IO；按职责拆分多 Engine）        │
│    │   ├── GameEngine         领域门面（聚合各子 Engine）                    │
│    │   ├── AdventureEngine    探索/挂机（AutoRun/Encounter/Story）          │
│    │   ├── CombatEngine       战斗（GetMonster/BeginBattle/AdvanceTick）    │
│    │   ├── EquipmentEngine    装备（Equip/Strengthen/Star/Decompose/Sell）  │
│    │   ├── RewardEngine       奖励（离线/宝箱/VIP/GM发奖）                  │
│    │   ├── QuestEngine        任务（跟踪/领取/每日重置）                     │
│    │   ├── MailEngine         邮件（创建/过期/附件领取）                     │
│    │   ├── MarketEngine       市场挂单/成交/信箱                            │
│    │   ├── PlayerTransition   状态迁移工具（Finalize/NoCommit/Failure）      │
│    │   ├── InventoryState / DomainMath / Catalog / StateNormalizer         │
│    ├── dao/             云存储网关（serverCloud 全能力统一封装）             │
│    │   └── ServerCloudGateway                                                │
│    └── repositories/    仓储层（状态 ↔ 云存储 映射 + 原子事务）              │
│        └── PlayerProfileRepository                                          │
└───────────────┬─────────────────────────────────────────────────────────────┘
                │  serverCloud（Score / Money / List / Item / Message / Quota / Rank）
                ▼
          云端持久化（跨重启、跨设备）
```

---

## 3. 目录速查（最新版）

| 路径 | 归属 | 职责 |
|------|------|------|
| `scripts/shared/` | 前后端共享 | `NetworkProtocol`（协议）、`ErrorCodes`、`GameStateSchema`（**聚合门面**）+ 拆分模块（Contracts/Policy/BoundarySchemas/Persistence/Validation/Wire）、`GameEventSchema`、数值库（`LargeNumber`/`BigNumber`）与玩法规则库（`MarketCatalog`/`MailRules`/`QuestDefinitions`/`LeaderboardCodec` 等） |
| `scripts/server/` | 服务端 | 权威逻辑 + 云持久化 |
| `scripts/client/` | 客户端 | 编排层 + Views/Controllers + 网络客户端 |
| `scripts/main.lua` | 客户端入口 | `Start()` → `GameView.Start()` |
| `server/ServerMain.lua` | 服务端入口 | 由引擎在服务端模式加载 |

---

## 4. 核心数据流（一次完整交互）

以"玩家点击 强化装备"为例：

```
客户端 UI 按钮
   │  ServerClient.Strengthen(slot, cb)          # 发出请求（requestId + command + payloadJson）
   ▼
AbyssCommand 远程事件（JSON 信封）
   ▼
ServerMain.HandleCommand ──► CommandRouter.DispatchEvent
   │  1. PlayerRegistry 查会话（未认证 → 拒绝）
   │  2. NetworkProtocol.ReadCommandEvent 校验信封（requestId/command/payload 格式）
   │  3. 查命令定义 + 幂等去重（_checkReplay）
   │  4. DecodePayload + ValidatePayload（Schema 校验）
   │  5. 鉴权（admin + authorize hook）
   │  6. RateLimiter.Check（Token Bucket 限流）
   │  7. OperationQueue.Enqueue（按玩家串行）
   ▼
GameCommands handler（异步）
   │  profileService:Apply(uid, "strengthen", mutator)
   │     mutator = GameEngine.Strengthen(state, slot, now)   # 领域门面 → EquipmentEngine
   │       → 返回 proposal{ok, state, delta, commit}
   │     → GameStateSchema.ValidateState 校验新状态（Validation 模块）
   │     → repository:Commit(uid, oldState, newState, ...)
   │         → ServerCloudGateway:BatchCommit 原子写云存储
   │     → services.sendDelta(uid, delta)        # 下发增量
   ▼
AbyssDelta 远程事件
   ▼
ServerClient.HandleDelta
   │  GameStateSchema.ValidateDelta（Wire 模块）
   │  GameStateAdapter.ApplyDelta（合并权威态 + 应用事件）
   ▼
GameStateAdapter.RebuildView（重投影视图态）
   ▼
GameView 监听到 "delta" 事件 → RefreshCurrentPage() / PlayPresentation.HandleDelta()
   ▼
UI 刷新（展示强化结果）
```

---

## 5. 关键设计原则

| 原则 | 实现位置 | 说明 |
|------|---------|------|
| **权威服务器** | `server/` | 客户端所有输入都变成命令；所有结算在服务端；客户端只读 |
| **快照 + 增量** | `ServerMain` / `ServerClient` | 连接后先全量快照（分片传输），之后只推 Delta；客户端按 revision 去旧 |
| **单向数据流** | `GameStateAdapter` | 权威态 `authoritative_` → 投影 `view_`，UI 只读 `view_` |
| **领域层纯函数 + 拆分** | `server/domain/*Engine` | 每个玩法函数 `f(inputState, ...) → proposal`；按职责拆成多个 Engine，通过 `GameEngine` 门面聚合 |
| **每玩家串行** | `OperationQueue` | 同一玩家所有变更按队列串行，配合 revision 防止并发写覆盖 |
| **云存储事务** | `ServerCloudGateway:BatchCommit` | 玩家档案 + 市场账本 + 信箱同批原子提交 |
| **幂等请求** | `CommandRouter` | requestId 去重：重放相同请求返回缓存响应；不同内容复用则拒绝 |
| **前后端共享 Schema** | `shared/GameState*` | 同一份校验代码服务端校验、客户端校验，杜绝"字段漂移" |
| **客户端 Controller/View 拆分** | `client/*Controller.lua` | 交互逻辑（Controller）与渲染（View）分离，`GameView` 只做装配 |

---

## 6. 文档索引

| 文档 | 内容 |
|------|------|
| [01-网络协议层.md](./01-网络协议层.md) | `NetworkProtocol`（信封/远程事件/Validate 校验器）、`ErrorCodes` 错误码体系 |
| [02-状态与事件Schema.md](./02-状态与事件Schema.md) | `GameStateSchema` **聚合门面 + 6 个拆分模块**（Contracts/Policy/BoundarySchemas/Persistence/Validation/Wire）、`GameEventSchema` |
| [03-服务端核心.md](./03-服务端核心.md) | `ServerMain` 生命周期、`PlayerRegistry`、`CommandRouter`、`RateLimiter`、`OperationQueue`、`AdminPolicy` |
| [04-服务端数据层.md](./04-服务端数据层.md) | `ServerCloudGateway` 云存储封装、`PlayerProfileRepository` 持久化映射与事务提交 |
| [05-服务端服务与领域层.md](./05-服务端服务与领域层.md) | 服务层（Profile/Idle/Market/Mail/Leaderboard/Admin）+ 领域层拆分（各 Engine）+ proposal 协议 |
| [06-客户端网络与状态适配.md](./06-客户端网络与状态适配.md) | `ServerClient` 网络客户端、`GameStateAdapter` 权威态→视图态投影 |
| [07-客户端UI与表现框架.md](./07-客户端UI与表现框架.md) | `GameView` 编排层、`ViewKit`/`ViewAssets`/`NavigationController`、Controller/View 模式、`PlayPresentation` |

---

## 7. 规模参考（最新版行数）

| 文件 | 行数 | 角色 |
|------|------|------|
| `client/GameView.lua` | 904 | 客户端编排层（从 3852 拆分而来） |
| `server/domain/EquipmentEngine.lua` | 960 | 装备领域 |
| `client/PlayPresentation.lua` | 993 | 战斗表现层（从 1696 精简） |
| `server/domain/GameEngine.lua` | 891 | 领域门面（从 3795 拆分而来） |
| `client/ItemTips.lua` | 937 | 装备提示 |
| `shared/GameStateSchema.lua` | 40 | **聚合门面**（从 1888 拆分为 6 个模块） |
| `shared/GameStateDefinitions.lua` | 758 | 字段定义（拆分自 Schema） |
| `shared/GameStateWire.lua` | 439 | 网络快照/增量（拆分自 Schema） |
| `server/core/CommandRouter.lua` | 503 | 命令路由 |
| 客户端合计 | ~19269 | 58 个文件 |

---

## 8. 如何复用本框架

1. **想搭"常驻服挂机 + 云存档 + 声明式 UI"游戏** → 复制 `shared/` + `server/core|dao|repositories` + `client/ServerClient.lua` + `client/GameStateAdapter.lua` 骨架。
2. **想改造玩法** → 在 `server/domain/` 下按职责新增/改写 Engine（沿用 `PlayerTransition.Finalize` 的 proposal 约定），共享层按需扩展 `GameState*` 模块，客户端页面按"View + Controller"模式新增。
3. **想换 UI 风格** → 只改 `client/Theme.lua`，或套用 `ui-astroon` / `ui-pixelforge` 等 UI 风格 skill。
