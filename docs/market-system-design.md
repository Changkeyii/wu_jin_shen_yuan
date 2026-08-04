# 市场系统设计（黑市 + 交易行）

状态：**设计稿，待确认后实施**
适用版本：`Catalog.SCHEMA_VERSION = 5`、`GameStateSchema` 现行字段

---

## 0. 设计前提（来自代码调研，非假设）

| 事实 | 出处 |
|---|---|
| 多人 + 常驻世界，存在**多个服务端分片** | `.project/settings.json` → `persistent_world.enabled=true`；`ServerConfig.GetPersistentWorldKey()` |
| 命令走 `CommandRouter:Register{name,schema,rate,async,handler}`，自带 schema 校验/限流/重放缓存/按 uid 串行 | `scripts/server/core/CommandRouter.lua` |
| 状态变更走 `profileService:Apply(uid, name, mutator, cb)`，`GameEngine` 为纯状态迁移 | `scripts/server/commands/GameCommands.lua:56` |
| 存档为**乐观并发**，`revision` 必须递增，冲突报 `REVISION_MISMATCH` | `PlayerProfileRepository.lua:395` |
| `serverCloud` 可操作**任意 uid**；`BatchCommit` 是**唯一原子事务** | `ServerCloudGateway.lua:BatchCommit` |
| 云限额：读/写各 300 次/分钟（**全局共享**）、48MB/分钟 | `engine-docs/recipes/server-cloud-score.md` |
| 金币是 `LargeNumber`（三段 1e9，上限 9007199254740991），**远超云整数上限 2147483647** | `shared/LargeNumber.lua` |
| VIP 已存在，`state.vipLevel` 范围 0–40 | `GameStateSchema.lua:893` |
| 已有 `Game.Sell`（NPC 收购，100% 回收价）与 `Game.Decompose`（60%+VIP×1%，上限 100%） | `GameEngine.lua:2135 / 2085` |
| 底部导航已有 `market` 页，`CreateMarketPage` 为占位 | `GameView.lua:3171` |

### 现有回收价公式（本设计的定价锚，不改动）

```
sameLevelBattleGold = item.level * 8 + 25
recoveryGold        = sameLevelBattleGold * rarity.recoveryBattles + investedGold
```

`recoveryBattles`：普通 16 / 高级 28 / 稀有 48 / 神器 85 / 传说 150 / **史诗 260** / **神话 450**

以 100 级装备为例：史诗 = 214,500，神话 = 371,250。
同期整层（10 房，约 19 战斗当量）产出约 15,675 金币 → **一件 100 级史诗 ≈ 13.7 层的金币产出**。

---

## 1. 外部数值参考（按要求调研）

| 游戏 | 手续费 | 关键机制 | 对本设计的启示 |
|---|---|---|---|
| DNF（本作装备槽位体系同源） | 5%，付费券降至 3% | 上架数量 5 / 30 件；上架金额不得超过持有金币 | **付费/等级降费**是成熟范式 → 对应本作 VIP 降费 |
| 魔兽世界 | 普通 5% / 中立 15% | 押金未售出全额退还；社区共识：**拍卖行的首要作用是回收金币而非便利** | 手续费必须**销毁**，不得进入任何账户 |
| 放置类手游行业实践 | 建议 8–12% | 日产出回收率 70–80%；大额交易分级加税 | 8% 落在推荐带内，合理 |
| 梦幻西游 | 9% 交易税 | 高额换手税高效回收 | 8% 属偏保守但安全 |

**结论**：用户指定的 8% 基准与行业推荐一致，无需调整。

---

## 2. 页面结构（集合体）

```
市场（底部导航 market）
├── 黑市      —— NPC 收购装备（复用现有 Game.Sell / Game.Decompose）
├── 交易行    —— 玩家真实上架 / 购买（史诗+）
│   ├── 浏览（按部位/品质筛选，价格升序）
│   ├── 我的挂单（下架）
│   └── 我的信箱（领取成交金币 / 未售退回 / 购得装备）
└── [待续]    —— 预留 tab，容器按数据驱动渲染
```

Tab 容器数据驱动，新增 tab 只需往表里加一项，不改容器代码。

---

## 3. 黑市（不新增数值）

**定位**：现有 `Game.Sell` + `Game.Decompose` 的正式 UI 承载面。**不新增任何公式**——现有数值已被 `tests/simulation` 门禁验证过，重写即破坏。

- 出售：100% 回收价金币（`Catalog.GetSellValue`）
- 分解：`(0.60 + VIP×0.01)` 上限 100% 的金币 **+ 碎片**（`Catalog.GetDecomposeRefund`）
- 神话不可出售/分解（现有 `maxRank ≤ 6` 约束）

**关键经济性质**：黑市收购价天然成为**交易行的价格地板**——没有理性玩家会低于 NPC 价挂单。这是在不设价格限制的前提下，唯一免费获得的价格锚，需保留。

---

## 4. 交易行

### 4.1 准入规则

| 规则 | 取值 | 依据 |
|---|---|---|
| 可上架品质 | 史诗（rank 6）、神话（rank 7） | 用户指定 |
| 上架前置 | 未穿戴、未锁定、非援助装备（`aidLocked`） | 复用 `Game.Sell` 现有过滤 |
| **购买等级准入** | `item.level ≤ 买家 floor + 10` | **见 4.4，最重要的平衡阀** |
| 同时挂单数 | `8 + floor(VIP/4)`（VIP0=8，VIP40=18） | 参考 DNF 5/30；控云数据量 |
| 挂单时长 | 48 小时，过期退回信箱 | 防账本无限增长 |
| 价格 | **不设上下限**（用户要求） | 仅受 `LargeNumber` 上限约束，见 4.3 |

### 4.2 手续费

```
feeRate    = max(0, 0.08 - vipLevel * 0.002)     -- VIP0=8%, VIP20=4%, VIP40=0%
fee        = floor(price * feeRate)
sellerGain = price - fee
```

- 与现有分解返还 `0.60 + vip*0.01` **完全同构**，不引入新概念。
- 从**成交价中扣除**（DNF/WoW 标准），买家只付标价。
- **手续费金币直接销毁**，不写入任何账户——这是本模块唯一的经济意义。
- 费率在**成交瞬间**按卖家当时 VIP 计算，并随挂单快照记录，避免争议。

### 4.3 价格上限（技术边界，非玩法限制）

用户要求不限制价格。唯一硬约束来自数据类型：`price ≤ LargeNumber.MAX_SAFE_INTEGER (9007199254740991)`。
超出即拒绝，理由为数值溢出而非玩法设定。价格以 `LargeNumber` 三段结构序列化存云，**不能用云整数**（上限仅 21.47 亿，会截断）。

### 4.4 购买等级准入线 —— 核心平衡阀

这是"避免数值破坏性大"的关键，必须保留。

装备预算按 `TowerRules.Growth(L) = 2^((L-1)/50)` 增长。一件 500 级史诗相对 1 级约为 `2^9.98 ≈ 1010×`。若不限制，50 层玩家买一件高层史诗可直接跳过约 450 层，整个纵向曲线报废。

**规则**：`item.level ≤ buyer.floor + 10`

`+10` 不是拍脑袋：`docs/tower-balance-simulation.md` 中难度增长偏移 `D(f)` 在 50 层后恒为 **+10 层**，且长期装备轨迹被校准在推荐线上方约 6 层。允许买入领先自身 10 级以内的装备，落在已模拟的包络内；超出即越界。

这是**购买准入**，不是价格限制，与用户约束不冲突。

**副作用（正向）**：神话目前既不可出售也不可分解，是唯一无出口的品质。交易行给了神话第一个流通出口，同时被等级线约束，不会造成越级。

### 4.5 低价扫货系统（系统回收）

**每日 07:00 与 20:00（UTC+8）**，系统自动扫走所有**价格 ≤ 标准值 × 10%** 的挂单。

```
standardValue = Catalog.GetSellValue(item)      -- 即 NPC 回收价，全局唯一"标准值"锚
sweepThreshold = floor(standardValue * 0.10)
命中条件：listing.price <= sweepThreshold
```

**结算**：
- 卖家**照常拿到自己的标价**（扣 8%/VIP 手续费），进信箱
- 装备被系统**销毁**，不回流市场
- 记为 `swept` 成交，写入审计流水

**为什么这个机制是必要的，且阈值 10% 精准**：

黑市 NPC 收购价 = 100% 标准值。因此任何低于 100% 的挂单在经济上都是非理性的——直接卖给 NPC 更划算。10% 的线**远低于**理性地板，正常交易**永远不可能**触发扫货。能被扫到的只有一种情况：**刻意超低价挂单，给指定小号/工作室送装备**。

这正好补上 4.4 之后残留的最后一个漏洞。至此两个方向的滥用都有了应对：

| 滥用方向 | 手段 | 应对 |
|---|---|---|
| 送**金币**（高价买垃圾） | 高价挂单让同伙买 | 8% 手续费全额生效，大额自带损耗 + 审计流水 |
| 送**装备**（低价挂单） | 1 金币挂史诗给小号 | **低价扫货直接截胡** |

**残留风险（如实说明）**：挂单到下一个扫货点之间存在窗口期（最长约 13 小时），同伙可能在扫货前抢先买走。扫货是**威慑与截胡**，不是完全封堵。若需彻底封堵需改为挂单即时判定，但用户已指定固定时点，此处遵循。

**跨分片幂等**（关键）：多分片下必须保证一个时点只扫一次。复用 5.4 的票据锁：

```
epochId = "20260801-AM" / "20260801-PM"
1. ListAdd(MARKET_LEDGER_UID, "mksweep:"..epochId, {shard}) → 唯一 sweepBidId
2. 回读全部票据，最小 id 获胜
3. 获胜分片执行扫货；其余分片跳过
```

不引入新机制，与购买并发用同一套原语。

服务端每 60 秒检查一次是否跨越了扫货时点，跨越即触发。分片重启导致错过时点时，**下次检查会补扫**（比对 `lastSweptEpoch` 云标记），不会漏。

### 4.6 反滥用总表（在不限价前提下）

- ✅ 低价扫货截胡低价送装备（4.5）
- ✅ 8% 手续费对任意金额生效，大额财富转移自带 8% 损耗
- ✅ 购买等级准入线阻断越级白嫖（4.4）
- ✅ 买家必须真实持有金币（服务器权威校验）
- ✅ 每笔成交写入管理审计流水（`AdminService` 已存在），支持事后处置
- ✅ 上架/购买命令走 `ServerConfig.RATES` 限流
- ❌ **无法**在不限价的前提下从机制上完全阻断高价送金

高价送金属已知残留风险，依赖事后审计。

---

## 5. 技术架构

### 5.1 最难的问题：跨分片

常驻世界有多个服务端分片，交易行必须全局一致，因此**账本只能放 `serverCloud`，不能放服务端内存**。

同时有两条铁律：

1. **绝不跨分片写他人存档。** 卖家可能离线或在别的分片，直接写会与其 `revision` 乐观锁冲突导致丢档。
2. **云限额 300 读/分钟是全局共享的**，不能每次浏览都查云。

### 5.2 信箱（Mailbox）模型 —— 解决铁律 1

参照 MMO 标准做法（WoW 把金币寄给你）：

```
上架：卖家自己的分片
      BatchCommit[ 卖家存档保存(物品移出背包) + ListAdd(市场账本, 挂单) ]

购买：买家自己的分片
      BatchCommit[ 买家存档保存(扣金币) + ListDelete(挂单)
                 + ListAdd(卖家uid, "mk:mail", 成交金币)
                 + ListAdd(买家uid, "mk:mail", 装备) ]

领取：各自玩家自己的分片，读自己的信箱 → 自己的存档变更
```

**任何分片只写自己在线玩家的存档**，卖家的收益停在卖家名下的云信箱里，等他上线自取。铁律 1 满足。

单条 `BatchCommit` 覆盖"扣款 + 摘牌 + 双方入信箱"，全成或全败，无中间态。

实现上需给 `PlayerProfileRepository` 增加一个 `SaveWithOperations(userId, newState, extraOps, cb)`：把存档已有的操作数组（见 `PlayerProfileRepository.lua:352`）与市场操作拼进**同一个** `BatchCommit`。这是对现有框架的最小扩展，不是另起一套。

### 5.3 账本分桶 + 分片内缓存 —— 解决铁律 2

- 挂单键：`mk:<rarity>:<slot>`，挂在固定系统 uid `MARKET_LEDGER_UID` 下。
  2 品质 × 12 部位 = 24 个桶，单桶体量可控，且筛选浏览只需读 1 个桶。
- 每个分片对每个桶做 **内存缓存 + 30s TTL**；本分片发生写入时立即失效该桶。
- 浏览请求只读缓存，**不产生云读**。云读只在 TTL 到期时发生：24 桶 × 2 次/分钟 = 48 读/分钟，留足余量。
- 客户端看到的挂单允许有 ≤30s 陈旧；下单时服务端二次校验，失效则返回 `LISTING_GONE` 让客户端刷新。这是拍卖行的正常体验。

### 5.4 并发：防止一单被两人买走

`serverCloud` 没有 CAS 原语，`Add` 的回调不返回新值，因此不能用原子自增做锁。可用的确定性原语是 `list:Add` **同步返回全局唯一 listId**。

**票据锁（ticket lock）**：

1. 买家分片 `ListAdd(MARKET_LEDGER_UID, "mkbid:"..listingId, {buyer, at})` → 得到唯一 `bidId`
2. 回读该键全部票据
3. **bidId 最小者获胜**——这是共享状态的确定性函数，所有分片读到同一答案，无需协调
4. 获胜方执行 5.2 的结算 `BatchCommit`；落败方删除自己的票据并返回 `LISTING_CONTESTED`
5. 结算后挂单已删除，迟到的竞买者读不到挂单，自动失败

代价：每次购买多 1 写 + 1 读。史诗+ 成交本身是低频事件，可承受。

**兜底清扫**：若获胜方在票据与结算之间崩溃，挂单会被孤立。由过期清扫（4.1 的 48h）统一退回卖家信箱，不会永久丢失。

---

## 6. 文件规划

`GameView.lua` 已 3670 行，**市场 UI 绝不内联**（规则 #13）。

| 文件 | 职责 | 预估 |
|---|---|---|
| `scripts/shared/MarketCatalog.lua` | 费率/等级线/时长/上限常量 + 纯费用计算（**客户端复用同一函数做预览，保证与服务端一致**） | ~120 |
| `scripts/server/domain/MarketEngine.lua` | 纯状态迁移：上架扣物品、下架/领取入背包，返回 `finalize` | ~300 |
| `scripts/server/services/MarketService.lua` | 云账本、分桶缓存、票据锁、结算、过期清扫 | ~450 |
| `scripts/server/commands/MarketCommands.lua` | 6 条命令注册 | ~200 |
| `scripts/client/MarketView.lua` | 集合页 + 黑市/交易行 tab | ~600 |
| 改动 `GameView.lua` | `CreateMarketPage` 改为委托 `MarketView.Build` | ~10 |
| 改动 `PlayerProfileRepository.lua` | 新增 `SaveWithOperations` | ~40 |
| 改动 `ServerConfig.lua` | 新增 `RATES.Market*` | ~5 |
| 改动 `ServerClient.lua` | 6 个 `Market.*` 包装函数 | ~30 |
| 改动 `ErrorCodes.lua` | 市场错误码 | ~10 |

### 命令清单

| 命令 | 限流 | 说明 |
|---|---|---|
| `Market.Browse` | 读缓存，`{refillRate=2,burst=5}` | 按品质/部位筛选，返回挂单页 |
| `Market.List` | `{refillRate=0.5,burst=3}` | 上架 |
| `Market.Cancel` | `{refillRate=0.5,burst=3}` | 下架 → 退回信箱 |
| `Market.Buy` | `{refillRate=0.5,burst=2}` | 购买 |
| `Market.Mailbox` | `{refillRate=1,burst=3}` | 查信箱 |
| `Market.Collect` | `{refillRate=1,burst=3}` | 领取信箱 |

---

## 7. 交付后必须验证

1. `tests/simulation/run.lua` 全量重跑，确认纵向门禁不回归——特别是 **1000 层内战力比 P50 需仍在 1.05–1.12**。交易行是首个玩家间战力转移通道，这是它唯一可能击穿的门禁。
2. 背包上限 300 与信箱溢出的交互（信箱满时的处理）。
3. 双分片并发买同一单的压测。

---

## 8. 待确认（实施前需要你拍板）

1. **购买等级准入 `floor + 10`** —— 这是防止数值崩坏的核心，是否接受？若放宽，越级购买会直接击穿纵向曲线。
2. **同时挂单数 `8 + VIP/4`** —— 数量上限（非价格上限），用于控制云数据量，是否接受？
3. **挂单时长 48h** —— 是否合适？
4. **手续费销毁**（不进任何账户）—— 确认？
5. **黑市完全复用现有出售/分解数值**，不新增公式 —— 确认？
6. 神话是否允许上架？（本设计：允许，且受等级线约束）
