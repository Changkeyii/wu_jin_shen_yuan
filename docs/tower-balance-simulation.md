# 无尽塔平衡模拟

本模拟同时验证固定战斗属性下的 Boss/整层路线，以及持久玩家 cohort 的掉落、换装、援助、卡层、用时和长期战力轨迹。入口是标准 Lua 5.4 脚本：

```powershell
lua tests/simulation/run.lua `
  --seed 20260723 `
  --samples 100000 `
  --progression-samples 10 `
  --progression-max-floor 1000 `
  --model aggregate `
  --out tests/simulation/results
```

快速烟测：

```powershell
lua tests/simulation/run.lua --quick --out .tmp/tower-balance-quick
```

`--quick` 在没有显式参数时使用每个独立战斗 cohort 2,000 次，并运行 1 对 auto/control 纵向 seed 到 100 层。quick 是结构烟测：报告仍如实写出纵向 `FAIL/INCONCLUSIVE`，但命令只强制战斗门禁、解析不变量和脚本无错误。正式模式强制全部纵向门禁。

## 参数

| 参数 | 含义 |
|---|---|
| `--seed <integer>` | 基础 seed，默认 `20260723` |
| `--samples <integer>` | 每个独立战斗 cohort 的样本数，默认 `100000` |
| `--progression-samples <integer>` | 纵向起始 seed 对数；每个 seed 各跑 auto/control，默认 `10` |
| `--progression-max-floor <integer>` | 纵向目标层，默认 `1000`，最低 `100` |
| `--model aggregate\|hits` | 聚合伤害模型或逐 hit 模型，默认 `aggregate` |
| `--out <directory>` | 八个固定产物的输出目录 |
| `--quick` | 战斗 2,000 次，并以 1 对 seed 跑到 100 层；不强制纵向门禁 |
| `--replay <scenario-id>` | 重放一个命名场景 |
| `--trial-seed <integer>` | 重放所需的单次 trial seed |
| `--replay-progression <cohort-seed>` | 重放一对 auto/control 纵向 cohort |

输入 seed 会经 Park-Miller MINSTD 的模数规则归一化。CSV 同时记录 `requested_base_seed`、`effective_base_seed`、每个 cohort 的 `cohort_seed`；失败 CSV 还记录 trial 开始时的 `trial_seed`。因此负数、零或超出 RNG 状态范围的输入不会造成报告 seed 与实际 RNG 状态不一致。

## 产物

固定输出如下：

| 文件 | 内容 |
|---|---|
| `key_floor_matrix.csv` | 8 个关键层 x 6 种同显示战力流派，共 48 个逻辑行 |
| `thresholds.csv` | 4 个硬指标场景各自的 Boss 与整层 route 行，共 8 行 |
| `failure_seeds.csv` | 每个 cohort 保留的可重放失败 seed 和完整场景键 |
| `progression_cohorts.csv` | 每条 auto/control 分支的完成层、战斗/过场/剧情/交互用时、重试、援助、品质掉落、pity、背包维护、换装和战力分布 |
| `progression_checkpoints.csv` | 每 100 层的软卡、战力比和累计用时分位数及各自样本数 |
| `progression_chapters.csv` | 每章尝试/成功、升级件、品质掉落及自动换装 before/after 成对试验 |
| `progression_failure_seeds.csv` | 未完成或未达 cohort 指标的可重放纵向 seed |
| `report.md` | 门禁、时长、软卡代理、采样合同和测量覆盖边界 |

所有 CSV 都使用固定列序、固定行序和 `\n` 换行。报告不写时间戳、绝对路径或本机耗时；相同代码、参数和 Lua 5.4 数值语义应产生字节一致的八个文件。

## 8 x 6 x 100k 的含义

矩阵有 48 个逻辑行，但不是 48 个独立随机 cohort。

- 流派数：6。
- 逻辑关键层：`1, 10, 50, 100, 300, 500, 1000, 5000`。
- 独立 cohort：每个流派各跑普通 Boss 代表层 1 和章节 Boss 代表层 10，共 12 个。
- 正式物理样本：`12 x 100000 = 1,200,000` 次矩阵 trial。
- 逻辑覆盖：`48 x 100000 = 4,800,000` 行样本等价，但不能表述为 480 万次独立 trial。

装备预算和角色核心继续使用 `G(f) = 2^((f-1)/50)`。敌人、推荐战力和 PowerEvaluator 使用难度增长 `G(f + D(f))`：`D(f)` 在 10 层前为 0，10 到 50 层按 smoothstep 平滑升至 `+10` 层，此后保持 `+10`。这会把长期装备轨迹从推荐线以上约 16 层校准到约 6 层，不改变 `85000` 预算、品质倍率或装备自身的 50 层翻倍斜率。

固定属性矩阵的玩家样本按同一难度增长构造，因此归一化后的战斗仍保持尺度不变量。runner 在每次运行中对 6 个流派、8 个关键层检查 tower/boss/elite score、TTK 和受击/生命比例，只有误差不超过 `1e-9` 才允许复用。CSV 用 `representative_floor`、`simulation_group`、`independent_cohort` 和 `scale_invariant_reuse` 明确标注来源。

阈值部分另有 8 个独立 cohort，即 4 个场景 x Boss/route，每个同样运行 `--samples` 次。正式一次运行的固定战斗物理 trial 总数是 2,000,000。

该数字只描述固定属性战斗采样，不包含纵向模拟。纵向工作量单独按 seed 对数、auto/control 状态分支数、目标层数、实际接受换装事件数，以及由这些事件产生的下一章节完整 10 房 route 共同 seed before/after 对数报告。

## 门禁

只有原始硬指标对应的 Boss scope 参与通过/失败：

| 场景 | Boss 通过率要求 |
|---|---:|
| `regular_boss_attributes_75_boss` | >= 99% |
| `chapter_boss_attributes_90_boss` | >= 90% |
| `chapter_boss_attributes_92_boss` | >= 99% |
| `aid_attributes_102_boss` | >= 99% |

同场景的 route 行只用于诊断整层损耗和软卡风险，不继承 Boss 门槛。例如普通 Boss 的 75% 属性指标不能被误解成“75% 属性必须以 99% 概率连续通过整层”。

此外有两个解析门禁：

- 相同玩家属性在不同目标楼层下的显示战力独立性。
- 关键层随机 cohort 复用所依赖的战斗尺度不变量。

纵向正式门禁如下。每一行同时要求达到 `min n`；样本不足时状态为 `INCONCLUSIVE`，在正式模式中与 `FAIL` 一样阻断：

| 指标 | 要求 | `n` 的含义 | `min n` |
|---|---:|---|---:|
| 每 100 层软卡均值 | `3-5` | 100 层 block 观察数 | 100 |
| 通关前失败次数 P99 | `<=2` | auto 分支完成/终止楼层数 | 1000 |
| 援助后第三次挑战通过率 | `>=99%` | auto/control 自然触发的实际第三次挑战 | 100 |
| 100 层用时 P50 | `4.5-5.2h` | 到达 100 层的 auto cohort | 10 |
| 100 层用时 P90 | `<=6h` | 到达 100 层的 auto cohort | 10 |
| 每 10 层可穿戴升级件 P50 | `12-18` | auto cohort 章节数 | 100 |
| 1000 层内战力比 P50 | `1.05-1.12` | auto cohort 十层检查点 | 100 |
| 自动换装最差章节成功率差 | `>=-1pp` | 每个被比较章节的最小成对 trial 数 | 128 |
| 同属性仅切楼层的显示战力差 | `<=0.1%` | 同属性楼层对检查数 | 1 |
| 未完成目标层的 auto 分支数 | `0` | auto 分支数 | 1 |

runner 会先写完八个产物，再在正式模式的任一硬门禁失败或样本不足时以非零状态结束。

## 纵向方法和限制

V3 纵向器调用生产 `Catalog.CreateItemStats`、`RewardPolicy` 的掉落/品质/pity/弱槽偏置、`PowerEvaluator` 的换装判定、`TowerRules` 战斗尺度，以及真实 `GameEngine.ClaimAid` 发放与调优路径。角色状态会跨房间和楼层保留。

为控制运行时间，纵向器不调用逐格 `GameEngine.AdvanceOneCell`，但按生产顺序逐房推进：先模拟当前 encounter，再结算该房掉落、执行自动换装、刷新玩家属性，然后携带剩余生命进入下一房。同层前房获得的装备和层内加成会影响后续房间。

auto/control 使用相同起始 seed，但路线和掉落条件不同后 RNG 流会分叉，因此两支原始章节成功率差只作诊断。自动换装硬门禁使用另一套成对设计：每次生产规则实际接受换装时，保存 before/after 属性，在下一章节完整 10 房 route 上使用共同 trial seed 模拟，通过率差按章节聚合后取最差值。

纵向用时累计战斗秒数、每个已完成 encounter 的生产 `Catalog.STEP_SECONDS`（当前 12 秒）、剧情阅读时间（每行 20 秒并加每个 gate 3 秒开销），以及每次背包维护 30 秒的交互时间。`progression_cohorts.csv` 分别导出 `combat_seconds`、`transition_seconds`、`story_seconds`、`interaction_seconds`、`inventory_maintenance_events` 和 `inventory_items_removed`。EXP/level 不参与当前 `Catalog.CalculateStats` 的战斗属性，因此纵向器不另行模拟经验升级。援助门禁只统计自然发生两次失败后真正执行的第三次挑战，零事件不能按 100% 通过处理。

每个章节通关后，纵向器显式模拟一次 30 秒的玩家手动整理：保留已穿戴、锁定、援助装备，以及每个部位按 raw item power 排名前 6 的候选；其余候选不分品质移除。该规则是玩家行为假设，不等同于生产自动分解，也不代表纯无人值守。两次整理之间若背包已满，低品质掉落走模拟自动处置路径；legend+ 等装备无法腾出空间时，分支记录 `inventoryBlockedFloor` 并终止，不会静默丢弃后继续生成轨迹。只有未完成的 auto cohort 进入正式完成门禁；control 未完成仍会导出并保留失败重放信息，但只作诊断。

## 指标口径

固定战斗部分 `MEASURED`：

- 固定属性 Boss/route 通过率。
- 全部尝试、成功尝试和失败尝试各自的平均、P50、P90、P99 战斗秒数。
- 成功后的剩余生命比例。
- 全量死亡房间计数，以及 `1 - pass_rate` 的单次 route 软卡代理。
- 固定 1.02 倍属性的援助后战斗安全代理。
- 关键层静态显示战力、等价楼层、余量楼层和 tower/boss/elite score。

纵向部分会实际测量并导出：

- 自然连败两次、调用 `GameEngine.ClaimAid`、第三次挑战的状态机闭环和事件数。
- 长期掉落总量、各品质计数、最终 pity、可穿戴升级件数、背包维护/移除件数、自动处置和容量阻塞。
- 持久 auto/control cohort 的长期战力、软卡、失败次数、100 层用时和每 100 层检查点。
- 战斗、过场、剧情阅读和背包维护交互的分项用时。
- 自动换装接受事件，以及下一章节完整 10 房 route 上共同 seed 的 before/after 成对通过率。

报告不会仅凭“执行过代码路径”就写 `MEASURED`。每项纵向门禁都带实际 `n` 和 `min n`；未达到最低有效样本数时覆盖状态为 `INCONCLUSIVE`，正式报告整体为 `FAIL`。

## 失败重放

`failure_seeds.csv` 的 `replay_command` 可直接执行，例如：

```powershell
lua tests/simulation/run.lua `
  --replay regular_boss_attributes_75_route `
  --trial-seed 1584435849 `
  --model aggregate
```

重放输出场景、有效 seed、成功状态、死亡房间和战斗秒数。矩阵每个 cohort 最多保留 8 条失败 seed，阈值每个 cohort 最多保留 12 条；CSV 同时记录实际失败总数和保留上限，因此它是确定性的重放样本，不是所有失败的逐条日志。

`progression_failure_seeds.csv` 保留未完成或未达 cohort 指标的 seed（最多 64 条）。重放会以相同 seed、模型和目标层重新运行 auto/control 两支：

```powershell
lua tests/simulation/run.lua `
  --replay-progression 20560730 `
  --progression-max-floor 1000 `
  --model aggregate
```

## 确定性检查

把相同参数写入两个不同目录，然后逐文件比较 SHA-256：

```powershell
lua tests/simulation/run.lua --seed 20260723 --samples 100000 --progression-samples 10 --progression-max-floor 1000 --model aggregate --out .tmp/tower-balance-a
lua tests/simulation/run.lua --seed 20260723 --samples 100000 --progression-samples 10 --progression-max-floor 1000 --model aggregate --out .tmp/tower-balance-b

$names = @(
    'key_floor_matrix.csv', 'thresholds.csv', 'failure_seeds.csv',
    'progression_cohorts.csv', 'progression_checkpoints.csv',
    'progression_chapters.csv', 'progression_failure_seeds.csv', 'report.md'
)
foreach ($name in $names) {
    $left = (Get-FileHash ".tmp/tower-balance-a/$name" -Algorithm SHA256).Hash
    $right = (Get-FileHash ".tmp/tower-balance-b/$name" -Algorithm SHA256).Hash
    if ($left -ne $right) { throw "non-deterministic artifact: $name" }
}
```

正式固定产物存放在 `tests/simulation/results/`。若战斗公式、场景、seed 或样本数发生变化，应重新运行完整命令并再次完成双跑哈希检查。
