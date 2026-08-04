# 无尽万灵塔 V2 UI 分层与边界合同

本文件是 V2 UI 改造的前置合同。Lua 布局只能在这些边界内组合现有正式素材；不得按透明留白猜测内容区，也不得把非九宫格素材任意拉伸。

## 根层级

```text
screenRoot（物理视口，始终铺满）
├─ backgroundLayer（cover，允许裁切，禁止黑边）
├─ safeAreaLayer
│  └─ verticalAnchorPlane（设计宽 1080，动态设计高）
│     ├─ topZone（顶锚）
│     ├─ middleZone（填充剩余高度）
│     │  ├─ pageContent
│     │  └─ battleGroundPlane（仅战斗页）
│     └─ bottomZone（底锚）
└─ overlayQueueRoot（剧情、换装、规则、确认共用队列）
```

- 横向缩放只由 `physicalWidth / 1080` 决定；设计高度动态取 `physicalHeight / scale`。
- `topZone` 固定顶锚，`bottomZone` 固定底锚，`middleZone` 使用 `top/bottom` 双边约束。
- 背景在整个物理视口使用 `cover`，即使安全区或中区高度变化也不得露出底色。
- 战斗地面从 `middleZone` 的实际高度计算，不再使用 1920 高设计稿的全局固定 Y。

## 正式素材矩形合同

坐标均为素材自身像素；`assetRect` 是源图，`visualOuterRect` 是布局外框，`contentRect` 是文字/按钮/进度条允许进入的安全内容区。

| 素材 | assetRect | visualOuterRect | contentRect / 规则 |
|---|---|---|---|
| `ui/brawlforge_bg_abyss_corridor.png` | `0,0,1080,1920` | 整个物理视口 | `cover`；中心门和道路是焦点，允许上下裁切，不加内嵌内容 |
| `brawlforge_side_scroller_route_bg_clean_*.png` | `0,0,1376,768` | 中区全宽高 | `cover`；源图地面基准约为 `y=540`，换算后夹在中区高度的 `66%–78%` |
| `ui/brawlforge_v4_top_full_bar_clean.png` | `0,0,1080,288` | `0,0,1080,288` 顶锚 | 资源文字仅进入 `36,42,1008,198` |
| `ui/brawlforge_v3_bottom_nav_bar.png` | `0,0,1080,180` | `0,bottom,1080,180` 底锚 | 导航点击区限制在 `28,24,1024,132` |
| `brawlforge_play_hp_frame_cropped.png` | `0,0,545,168` | 保持 `545:168` | 名称区 `42,28,455,34`；血条 `54,76,420,30`；HP 文本 `54,108,420,28` |
| `ui/inventory/title_panel.png` | `0,0,940,158` | 保持 `940:158` | 标题只进入 `170,38,600,72` |
| `ui/inventory/tab_on/off.png` | `0,0,160,58` | 九宫格到 `218,72` | 切片边界 `12,18,12,18`；文字区 `18,10,182,52` |
| `ui/dialog/dialog_frame.png` | `0,0,768,386` | 九宫格到至多 `900×760` | 标题 `56,34,w-112,72`；正文 `60,118,w-120,h-266`；按钮 `60,h-126,w-120,82` |
| `ui/brawlforge_v3_action_button.png` | `0,0,320,62` | 保持比例或九宫格横向扩展 | 点击内容内缩 `18,8,284,46`，最小触控高 48 |
| `image/战斗进程条轻量科技框_20260731071918.png` | `0,0,1267,94` | `0,0,1267,94`，`contain` | 能量轨道 `20,33,1228,28`；统一按 `0.60` 等比显示为 `760.2x56.4`，外框只负责轻量科技装饰并使用素材自身透明度，不得承载进度裁剪 |
| `image/战斗进程条匹配能量填充_20260731072043.png` | `0,0,1228,28` | `0,0,1228,28`，`contain` | 只能作为外框轨道 `20,33,1228,28` 的子层；统一按 `0.60` 等比显示为 `736.8x16.8`，由父级 `FillClip` 从左向右裁剪，禁止缩放背景模拟进度 |

## 中区战斗合同

- `middleRect = { x=0, y=topZoneHeight, w=1080, h=viewportH-topZoneHeight-bottomZoneHeight }`。
- `groundY = clamp(middleRect.h * 0.72, middleRect.h - 290, middleRect.h - 150)`，所有角色脚底、掉落 Icon 和光柱以该局部 Y 为基准。
- 玩家锚点是中区左侧 `22%`，怪物锚点是中区右侧 `76%`；双方血条分别锚定中区左上和右上，不得跟随整体居中容器漂移。
- 顶部状态/战力卡、中央战斗层、底部战利品条分别属于中区的上/中/下三个子层，互不覆盖。
- 战斗进程条层级固定为 `ProgressRoot -> TrackFrame -> FillClip -> EnergyFill`；`TrackFrame` 保持完整，`FillClip` 的显示宽度按章节连续进度在 `0..736.8` 间逐帧变化，能量填充始终保持 `1228:28` 的原始比例。

## 弹窗与背包合同

- 所有弹窗只能由 `DialogCoordinator` 入队；任一时刻只展示一个，关闭后再展示下一项。
- 剧情优先级高于换装，换装高于规则，规则高于普通确认；同优先级保持 FIFO。
- 分解、出售、升星消耗、批量操作必须走确认队列。
- 背包页签左右箭头各占 `64×64`，仅在对应方向仍可滚动时显示并允许点击；使用正式页签九宫格作为按钮外框，不用纯色临时块。
- 掉落表现为 `光柱 → 真实 Icon → 飞入背包/临时箱`，最终归属只读取服务端事件。
