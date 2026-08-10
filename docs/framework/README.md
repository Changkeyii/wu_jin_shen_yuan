# UrhoX 挂机塔防框架 —— 纯净框架文档

> 本目录从项目 `scripts/` 中提炼出一套**可复用的游戏框架**，去掉具体玩法数值与美术表现，保留通用的架构模式与核心代码。适用于：新项目搭建脚手架、理解权威服务器 + 云存档 + 声明式 UI 的完整链路、复用网络/状态/服务端骨架。

---

## 1. 一句话概括

这是一个 **客户端表现 + 服务端权威 + 云端持久化** 的挂机塔防游戏框架：

- **服务端**是唯一权威：所有玩法结算（战斗、掉落、强化、市场交易）都在服务端执行，通过 `serverCloud` 云变量持久化玩家档案。
- **客户端**只负责渲染与交互：通过 `ServerClient` 建立长连接，接收服务端下发的 **快照（Snapshot）+ 增量（Delta）+ 事件（Event）**，驱动声明式 UI（`urhox-libs/UI`）。
- 客户端与**服务端共享**同一套 **协议定义、状态 Schema、事件 Schema、数值库**，保证前后端对"一份状态"的校验与展示完全一致。

---

## 2. 分层架构图

```
┌────────────────────────── 客户端 (client/) ──────────────────────────┐
│  GameView.lua          客户端入口：初始化 UI / 绑定事件 / 每帧 Update │
│    │                                                              │
│    ├── Theme.lua        设计规范（颜色/主题/装备槽/稀有度/套装表）     │
│    ├── ServerClient.lua 网络层：连接/请求/快照组包/监听分发            │
│    ├── GameStateAdapter.lua  状态适配层：权威态 → 视图态（只读投影）   │
│    ├── PlayPresentation.lua  战斗/场景表现层（横版卷轴 + 帧动画）      │
│    └── UI 组件族          InventoryView / MarketView / ItemTips ...   │
└───────────────┬─────────────────────────────────────────────────────┘
                │  AbyssCommand / AbyssSnapshot / AbyssDelta / AbyssStatus
                │  （JSON 信封，经 UrhoX 远程事件传输）
┌───────────────▼────────────────────────── 服务端 (server/) ──────────┐
│  ServerMain.lua         服务端入口：生命周期 / 握手 / 快照分发         │
│    │                                                              │
│    ├── core/            框架内核                                    │
│    │   ├── PlayerRegistry   连接与玩家会话注册表（代际管理）           │
│    │   ├── CommandRouter    命令路由（Schema校验/幂等/串行/限流）      │
│    │   ├── RateLimiter      Token Bucket 限流                        │
│    │   ├── OperationQueue   每玩家串行操作队列（防并发写覆盖）         │
│    │   └── AdminPolicy      管理员策略                              │
│    ├── services/        服务层                                      │
│    │   ├── PlayerProfileService  会话生命周期 / 离线收益 / 状态Apply   │
│    │   ├── IdleRuntimeService    挂机自动战斗驱动器                   │
│    │   ├── MarketService        交易行分片缓存 / 扫货 / 结算           │
│    │   └── AdminService          GM 命令执行与审计                    │
│    ├── domain/          领域层（纯函数，不含IO）                     │
│    │   ├── GameEngine          塔防玩法状态机（move/combat/loot...）  │
│    │   ├── MarketEngine        市场挂单 / 成交 / 信箱                 │
│    │   ├── Catalog            装备/数值定义                          │
│    │   └── StateNormalizer    存档归一化                             │
│    ├── dao/             云存储网关                                  │
│    │   └── ServerCloudGateway  serverCloud 全部能力的统一封装         │
│    └── repositories/    仓储层（状态 ↔ 云存储 映射）                 │
│        └── PlayerProfileRepository                                  │
└───────────────┬─────────────────────────────────────────────────────┘
                │  serverCloud（云变量：Score / Money / List / Item / Message / Quota / Rank）
                ▼
          云端持久化（跨重启、跨设备）
```

---

## 3. 目录速查

| 路径 | 归属 | 职责 |
|------|------|------|
| `scripts/shared/` | 前后端共享 | `NetworkProtocol`（协议）、`ErrorCodes`（错误码）、`GameStateSchema`（状态Schema）、`GameEventSchema`（事件Schema）、数值库（`LargeNumber`/`BigNumber`）与玩法规则库 |
| `scripts/server/` | 服务端 | 权威逻辑 + 云持久化 |
| `scripts/client/` | 客户端 | 表现层 + UI + 网络客户端 |
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
   │     mutator = GameEngine.Strengthen(state, slot, now)
   │       → 返回 proposal{ok, state, delta, commit}
   │     → GameStateSchema.ValidateState 校验新状态
   │     → repository:Commit(uid, oldState, newState, ...)
   │         → ServerCloudGateway:BatchCommit 原子写云存储
   │     → services.sendDelta(uid, delta)        # 下发增量
   ▼
AbyssDelta 远程事件
   ▼
ServerClient.HandleDelta
   │  GameStateSchema.ValidateDelta
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
| **单向数据流** | `GameStateAdapter` | 权威态 `authoritative_` → 投影 `view_`，UI 只读 `view_`，绝不直接改权威态 |
| **领域层纯函数** | `GameEngine`/`MarketEngine` | 每个玩法函数 `f(inputState, ...) → proposal`，proposal 含 `state/delta/commit/events`，不含任何 IO |
| **每玩家串行** | `OperationQueue` | 同一玩家所有变更按队列串行，配合 revision 防止并发写覆盖 |
| **云存储事务** | `ServerCloudGateway:BatchCommit` | 玩家档案 + 市场账本 + 信箱同批原子提交 |
| **幂等请求** | `CommandRouter` | requestId 去重：重放相同请求返回缓存响应；不同内容复用则拒绝 |
| **前后端共享 Schema** | `shared/GameStateSchema` | 同一份校验代码服务端校验、客户端校验，杜绝"字段漂移" |

---

## 6. 文档索引

| 文档 | 内容 |
|------|------|
| [01-网络协议层.md](./01-网络协议层.md) | `NetworkProtocol`（信封/远程事件/Validate 校验器）、`ErrorCodes` 错误码体系 |
| [02-状态与事件Schema.md](./02-状态与事件Schema.md) | `GameStateSchema`（持久化/Snapshot/Delta/校验）、`GameEventSchema`（事件校验） |
| [03-服务端核心.md](./03-服务端核心.md) | `ServerMain` 生命周期、`PlayerRegistry`、`CommandRouter`、`RateLimiter`、`OperationQueue`、`AdminPolicy` |
| [04-服务端数据层.md](./04-服务端数据层.md) | `ServerCloudGateway` 云存储封装、`PlayerProfileRepository` 持久化映射与事务提交 |
| [05-服务端服务与领域层.md](./05-服务端服务与领域层.md) | `PlayerProfileService`、`IdleRuntimeService`、`MarketService/MarketEngine`、`GameEngine` 领域函数约定、`StateFactory` |
| [06-客户端网络与状态适配.md](./06-客户端网络与状态适配.md) | `ServerClient` 网络客户端、`GameStateAdapter` 权威态→视图态投影 |
| [07-客户端UI与表现框架.md](./07-客户端UI与表现框架.md) | `GameView` 入口与页面系统、`Theme` 设计规范、`PlayPresentation` 表现层、UI 组件模式 |

---

## 7. 规模参考（行数）

| 文件 | 行数 | 角色 |
|------|------|------|
| `server/domain/GameEngine.lua` | 3795 | 领域状态机（最大） |
| `client/GameView.lua` | 3852 | 客户端入口与页面 |
| `shared/GameStateSchema.lua` | 1888 | 状态 Schema |
| `client/PlayPresentation.lua` | 1696 | 战斗表现层 |
| `client/InventoryView.lua` | 1616 | 背包页 |
| `shared/NetworkProtocol.lua` | 469 | 协议与校验器 |
| `server/core/CommandRouter.lua` | 503 | 命令路由 |
| 总计 | ~31800 | 含玩法数值与 UI |

---

## 8. 如何复用本框架

1. **想搭"常驻服挂机 + 云存档 + 声明式 UI"游戏** → 复制 `shared/` + `server/core|dao|repositories` + `client/ServerClient.lua` + `client/GameStateAdapter.lua` 骨架。
2. **想改造玩法** → 重写 `server/domain/GameEngine.lua` 的领域函数，替换 `shared/` 里的玩法规则库，客户端 UI 按 `GameStateAdapter.GetViewState()` 的字段重建页面。
3. **想换 UI 风格** → 只改 `client/Theme.lua`，或套用 `ui-astroon` / `ui-pixelforge` 等 UI 风格 skill。
