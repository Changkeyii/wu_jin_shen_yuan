-- ActivityView.lua
-- 活动系统全屏独立页面（BrawlForge 风格）：
--   · 深蓝黑机械背景板（生成素材） + UI.Card 卡片（主题黑边/锐角/阴影）
--   · 签到活动：签到格子框素材 + 每日奖励
--   · 每日补充玩法：木桩素材卡片 + 进入独立打桩场景（玩家自动攻击木桩，伤害飘字，限时结算）

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local GameStateAdapter = require("client.GameStateAdapter")
local ServerClock = require("client.ServerClock")
local ActivityDefinitions = require("shared.ActivityDefinitions")
local AbyssDefinitions = require("shared.AbyssDefinitions")
local ChallengeDefinitions = require("shared.ChallengeDefinitions")
local LargeNumber = require("shared.LargeNumber")
local CombatSequence = require("shared.CombatSequence")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ActivityController = require("client.ActivityController")
local CommonPromptDialog = require("client.CommonPromptDialog")
local ServerClient = require("client.ServerClient")
local AbyssPresentation = require("client.AbyssPresentation")
local RewardClaimController = require("client.RewardClaimController")
local BigNumber = require("shared.BigNumber")
local RarityCatalog = require("shared.RarityCatalog")
local UILayout = require("client.UI.UILayout")
local ChangedOnly = require("client.UI.ChangedOnly")
local LoadingController = require("client.LoadingController")

local DungeonCatalog = require("shared.DungeonCatalog")
local ActivityView = {}
---@type table?
local dungeonView_ = nil
local selectedDungeonTiers_ = {}
local selectedAbyssSet_ = "nightmare"

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

-- BrawlForge 蓝面 / 深黑边框
local SURFACE = { 33, 69, 138, 235 }
local SURFACE_DARK = { 10, 26, 52, 235 }
local SURFACE_CAN = { 20, 62, 36, 235 }

-- ===== 打桩场景（页内）模块状态 =====
local strikeId_ = nil
local strikeRemaining_ = 0
local strikeTimer_ = 0
local strikeAttackTime_ = 0
local strikeLastDamage_ = 0
---@type table[]
local damageLabels_ = {}
---@type table<string, any>
local strikeRefs_ = {}

local STRIKE_INTERVAL = ActivityDefinitions.STRIKE.INTERVAL
local STRIKE_ATTACK_FRAMES = ASSETS.player.attackFrameSets and ASSETS.player.attackFrameSets[1]
    or (ASSETS.player.attack and { ASSETS.player.attack } or { ASSETS.player.icon })
-- 当前攻击的随机帧组（每次攻击随机选一组，与登塔一致）
---@type table
local currentStrikeAttackFrames_ = nil
-- 当前攻击动画参数（CombatSequence 生成，与登塔速度一致）
local strikeWindup_ = 0
local strikeRecovery_ = 0
local strikeHitFrame_ = 1
local strikeEndFrame_ = 1
-- 三个攻击动画按顺序轮流播放的当前索引（A → B → C → A …）
local strikeSequenceIndex_ = 0
-- 当前攻击是否已触发命中（每次攻击仅触发一次伤害+飘字）
local strikeHitTriggered_ = false
-- 深渊 Boss 挑战（复用打桩场景动画，目标换成 Boss）
local bossActive_ = false
local bossRemaining_ = 0
local bossLastHp_ = 0
local sceneMode_ = "strike"
local sceneGeneration_ = 0
local strikeEndsAt_ = 0
local bossEndsAt_ = 0
local bossRunId_ = ""
local attackRequestPending_ = false
local finishingScene_ = false
local finishRequestPending_ = false
local finishRetryTimer_ = 0
---@type function
local FinishScene

-- 打桩额外次数激励广告状态。广告位由 @runtime.ad 自动配置，Lua 不持有广告位 ID。
local strikeAdInFlight_ = false
local strikeAdRequestPending_ = false
local strikeAdSequence_ = 0
local strikeAdElapsed_ = 0
local strikeAdFinish_ = nil
local STRIKE_AD_WATCHDOG_SECONDS = require("client.RewardVideo").WATCHDOG_SECONDS

-- ===== 页签状态 =====
-- tab 固定顺序：新手签到 → 轮回签到 → 每日补给 → 热门活动（许愿池/深渊远征/PVP）
local activityTab_ = "act_signin_newbie_7"
local selectedAbyssGrade_ = "rift"
local ACTIVITY_TABS = {
    { id = "act_signin_newbie_7", label = "新手签到", kind = "signin" },
    { id = "act_signin_loop_30", label = "轮回签到", kind = "signin" },
    { id = "strike", label = "每日补给", kind = "strike" },
    { id = "act_hot", label = "热门活动", kind = "hot" },
}

local function BuildTabBar()
    local children = {}
    for _, entry in ipairs(ACTIVITY_TABS) do
        local active = activityTab_ == entry.id
        local currentEntry = entry
        children[#children + 1] = UI.Panel {
            width = "22%",
            minWidth = 160,
            maxWidth = 240,
            height = 64,
            flexShrink = 0,
            clickable = true,
            backgroundImage = active and ASSETS.ui.inventoryTabOn or ASSETS.ui.inventoryTabOff,
            backgroundFit = "sliced",
            backgroundSlice = { 12, 18, 12, 18 },
            borderWidth = active and 2 or 1,
            borderColor = active and C.focus or C.border,
            opacity = active and 1.0 or 0.78,
            onClick = function()
                if activityTab_ ~= currentEntry.id then
                    activityTab_ = currentEntry.id
                    ActivityController.Refresh()
                end
            end,
            children = {
                Kit.Txt(currentEntry.label, active and 24 or 20, active and C.text or C.textDim, {
                    width = "100%", height = 64, textAlign = "center",
                    textStroke = { width = active and 2 or 1, color = "#000000" },
                }),
            },
        }
    end
    return UI.Panel {
        width = "100%", flexShrink = 0,
        flexDirection = "row", justifyContent = "center", gap = 16,
        children = children,
    }
end

local function StumpImage(rewardKind)
    if rewardKind == "gold" then return ASSETS.enemies.stumpGold end
    if rewardKind == "exp" then return ASSETS.enemies.stumpExp end
    return ASSETS.enemies.stumpFragments
end

local function CurrentView()
    local game = GameStateAdapter.GetViewState()
    return game.activitiesView or ActivityDefinitions.BuildView(game, ServerClock.Now())
end

local function PrepareScene(callback)
    local generation = sceneGeneration_
    LoadingController.EnsurePlayAssetsReady(function()
        if generation ~= sceneGeneration_ or GameStateAdapter.GetViewState().page ~= "activity"
            or strikeId_ or bossActive_ then return end
        callback()
    end)
end

local function RewardText(reward)
    reward = type(reward) == "table" and reward or {}
    local parts = {}
    if reward.gold and not LargeNumber.IsZero(reward.gold) then
        parts[#parts + 1] = "金币 " .. Kit.FormatInt(reward.gold)
    end
    if (reward.fragments or 0) > 0 then
        parts[#parts + 1] = "碎片 " .. tostring(reward.fragments)
    end
    if (reward.exp or 0) > 0 then
        parts[#parts + 1] = "经验 " .. tostring(reward.exp)
    end
    if (reward.abyssTickets or 0) > 0 then
        parts[#parts + 1] = "深渊票 " .. tostring(reward.abyssTickets)
    end
    return #parts > 0 and table.concat(parts, " ") or "奖励待定"
end

local function Toast(message, variant)
    UI.Toast.Show(message, { duration = 2.4, variant = variant or "info", position = "bottom" })
end

-- 把奖励表转成道具图标数据数组（金币/经验/碎片），供 RewardIconsWidgets 构建。
-- @param reward table { gold, fragments, exp }
-- @return table[] { icon, amount, size }
local function RewardIcons(reward)
    reward = type(reward) == "table" and reward or {}
    local list = {}
    if reward.gold and not LargeNumber.IsZero(reward.gold) then
        list[#list + 1] = { icon = ASSETS.items.gold, amount = "+" .. Kit.FormatInt(reward.gold), size = 112 }
    end
    if (reward.fragments or 0) > 0 then
        list[#list + 1] = { icon = ASSETS.items.crystal, amount = "+" .. Kit.FormatInt(reward.fragments), size = 112 }
    end
    if (reward.exp or 0) > 0 then
        list[#list + 1] = { icon = ASSETS.items.crystal, amount = "+" .. Kit.FormatInt(reward.exp), size = 112 }
    end
    if (reward.abyssTickets or 0) > 0 then
        list[#list + 1] = {
            icon = AbyssDefinitions.ICON,
            amount = "+" .. tostring(reward.abyssTickets),
            size = 112,
        }
    end
    return list
end

-- 把奖励表转成实际的道具格子 Widget 数组（供 UI children 直接使用）。
-- @param reward table { gold, fragments, exp }
-- @return Widget[] RewardCell 实例列表
local function RewardIconsWidgets(reward)
    local widgets = {}
    for _, cell in ipairs(RewardIcons(reward)) do
        widgets[#widgets + 1] = Kit.RewardCell(cell)
    end
    return widgets
end

-- 签到子页面的单个签到日：正式卡片（卡片背景 + 道具格子 + 状态 + 领取按钮）。
local function SigninRow(dayEntry, canClaim, onClick)
    local claimed = dayEntry.claimed == true
    local statusText = canClaim and "可领取" or (claimed and "已领取" or "未解锁")
    local statusColor = canClaim and C.gold or (claimed and C.textSecondary or C.textDim)
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        padding = 16,
        gap = 12,
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        backgroundColor = canClaim and SURFACE_CAN or SURFACE,
        borderWidth = canClaim and 3 or 2,
        borderColor = canClaim and C.gold or C.border,
        borderRadius = 14,
        children = {
            -- 顶部：第X天 + 状态徽章
            UI.Panel {
                width = "100%", flexShrink = 0, flexDirection = "row", alignItems = "center", justifyContent = "space-between",
                children = {
                    Kit.Txt("第" .. tostring(dayEntry.day) .. "天", 24,
                        canClaim and C.gold or (claimed and C.textDim or C.text), {
                        textAlign = "left", textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                    }),
                    UI.Badge {
                        text = statusText,
                        variant = canClaim and "success" or (claimed and "primary" or "secondary"),
                    },
                },
            },
            -- 中部：正式道具格子（slot 底框）
            UI.Panel {
                width = "100%", flexShrink = 0,
                flexDirection = "row", justifyContent = "center", gap = 14,
                children = RewardIconsWidgets(dayEntry.reward),
            },
            -- 底部：领取按钮（正式按钮素材）
            UI.Panel {
                width = "100%", flexShrink = 0, flexDirection = "row", justifyContent = "flex-end",
                children = {
                    canClaim
                        and Kit.ImageButton("领取奖励", 220, 60, ASSETS.ui.inventoryActionGold, onClick, false)
                        or Kit.CompactTxt(statusText, 18, statusColor, {
                            width = 220, height = 44, textAlign = "center",
                            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                        }),
                },
            },
        },
    }
end

-- ===== 签到子页面（竖行列表，每个签到日一行，点击领取） =====
local function SigninCard(item)
    local canSign = item.canSign == true
    local completed = item.completed == true

    -- 解锁提示：可领取则提示"今日可领取"，否则提示剩余解锁时间
    local unlockHint = "今日可领取"
    if not canSign and not completed then
        local remaining = math.max(0, (item.unlockAt or 0) - ServerClock.Now())
        unlockHint = "下一份奖励 " .. Kit.FormatDuration(remaining) .. " 后解锁"
    end

    local dayRows = {}
    -- 展示全部天数（新手 7 天 / 轮回 30 天），轮回在 ScrollView 中滚动查看
    local cellCount = #item.days
    for i = 1, cellCount do
        local dayEntry = item.days[i]
        local isToday = dayEntry.isToday == true
        dayRows[#dayRows + 1] = SigninRow(dayEntry, isToday, isToday and function()
            ActivityController.SignIn(item.id, function(response)
                if response and not response.ok then
                    local reason = (response and response.reason) or "暂不能领取"
                    Toast(reason, reason == "处理中，请稍候" and "info" or "warning")
                end
            end)
        end or nil)
    end

    local statusText = completed and "已完成" or (canSign and "可签到" or "进行中")
    local statusVariant = completed and "secondary" or (canSign and "success" or "primary")

    local card = UI.Panel {
        width = "100%",
        flexShrink = 0,
        padding = 20,
        gap = 14,
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        backgroundColor = canSign and SURFACE_CAN or SURFACE,
        borderWidth = canSign and 3 or 2,
        borderColor = canSign and C.gold or C.border,
        borderRadius = 14,
        children = {
            UI.Panel {
                width = "100%", flexShrink = 0, flexDirection = "row", alignItems = "center",
                children = {
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 4, children = {
                        Kit.Txt(item.title, 28, canSign and C.gold or C.text, { width = "100%", height = 40, textAlign = "left", textStroke = { width = 2, color = "#000000" } }),
                        Kit.CompactTxt(item.desc .. (completed and "（已完成）" or ""), 16, C.textSecondary, { width = "100%", height = 26, textAlign = "left" }),
                        Kit.CompactTxt(unlockHint, 16, canSign and C.success or C.textSecondary, { width = "100%", height = 26, textAlign = "left" }),
                    } },
                    UI.Badge {
                        text = statusText,
                        variant = statusVariant,
                    },
                },
            },
            UI.Panel {
                width = "100%", flexShrink = 0, gap = 10,
                children = dayRows,
            },
        },
    }
    card.props.tabId = item.id
    return card
end

-- ===== 每日补充玩法卡片（UI.Card + 木桩素材） =====
local function StrikeCard(item)
    local tiers = item.dungeons or {}
    local tierIndex = selectedDungeonTiers_[item.id] or 1
    local selectedStage = tiers[tierIndex]
    local remaining = item.remaining or 0
    local adCan = item.adCan == true
    local stumpImage = StumpImage(item.rewardKind)

    local tierBadges = {}
    for index, stage in ipairs(tiers) do
        local available = (GameStateAdapter.GetViewState().level or 1) >= stage.minLevel
        local active = index == tierIndex
        local reward = ActivityDefinitions.RewardPreview(stage.reward, stage.recommendedLevel)
        tierBadges[#tierBadges + 1] = UI.Panel {
            width = 270, flexShrink = 0, padding = 14, gap = 6, clickable = available,
            backgroundImage = ASSETS.ui.panelCompact, backgroundFit = "sliced", backgroundSlice = { 12, 12, 12, 12 },
            borderColor = active and C.gold or C.border, borderWidth = active and 3 or 1,
            opacity = available and 1 or 0.5,
            onClick = function() selectedDungeonTiers_[item.id] = index; ActivityController.Refresh() end,
            children = {
                Kit.CompactTxt(DungeonCatalog.DIFFICULTIES[index] .. " · Lv." .. tostring(stage.recommendedLevel), 19, active and C.gold or C.text, { height = 30 }),
                Kit.MultiTxt(RewardText(reward), 17, C.textSecondary, { width = "100%", minHeight = 44 }),
            },
        }
    end

    local function StartStrikeAction()
        local stage = DungeonCatalog.GetStage(item.dungeonStageId) or selectedStage
        if not stage or dungeonView_ or strikeId_ or bossActive_ then return end
        sceneGeneration_ = sceneGeneration_ + 1
        dungeonView_ = require("client.CampaignBattleView").Create(stage, function()
            if dungeonView_ then dungeonView_:Destroy(); dungeonView_ = nil end
            sceneGeneration_ = sceneGeneration_ + 1
            ActivityController.Refresh()
        end, function() ActivityController.Refresh() end)
        ActivityController.Refresh()
    end

    local function WatchAdAction()
        if strikeAdRequestPending_ then
            Toast("额外次数正在解锁，请稍候", "info")
            return
        end
        if strikeAdInFlight_ then
            Toast("广告正在播放，请勿重复点击", "info")
            return
        end
        if not require("client.RewardVideo").IsAvailable() then
            Toast("广告暂不可用，请稍后重试", "warning")
            return
        end

        strikeAdInFlight_ = true
        strikeAdElapsed_ = 0
        strikeAdSequence_ = strikeAdSequence_ + 1
        local sequence = strikeAdSequence_
        local completed = false
        local callbackFired = false

        local function Finish(result)
            if completed or sequence ~= strikeAdSequence_ then return end
            completed = true
            strikeAdInFlight_ = false
            strikeAdElapsed_ = 0
            strikeAdFinish_ = nil
            if not result or result.success ~= true then
                Toast(
                    result and result.msg == "embed manual close"
                        and "需完整观看广告才能解锁额外次数"
                        or "广告暂不可用，请稍后重试",
                    "warning"
                )
                return
            end

            strikeAdRequestPending_ = true
            ActivityController.UnlockExtraStrike(item.id, function(response)
                if sequence ~= strikeAdSequence_ then return end
                strikeAdRequestPending_ = false
                if response and response.ok then
                    Toast("额外挑战次数已解锁", "success")
                else
                    Toast((response and response.reason) or "额外次数解锁失败", "warning")
                end
            end)
        end

        strikeAdFinish_ = Finish
        local accepted = require("client.RewardVideo").Play(function(result)
            callbackFired = true
            Finish(result)
        end)
        if accepted == false and not callbackFired then
            Finish({ success = false, msg = "广告展示请求未受理" })
        end
    end

    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        padding = 20,
        gap = 14,
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        backgroundColor = SURFACE,
        borderWidth = 2,
        borderColor = C.border,
        borderRadius = 14,
        children = {
            UI.Panel {
                width = "100%", flexShrink = 0, flexDirection = "row", alignItems = "center",
                children = {
                    UI.Panel {
                        width = 110, height = 110, flexShrink = 0,
                        backgroundImage = stumpImage, backgroundFit = "contain",
                    },
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 4, children = {
                        Kit.Txt(item.title, 28, C.text, { width = "100%", height = 40, textAlign = "left", textStroke = { width = 2, color = "#000000" } }),
                        Kit.CompactTxt(item.desc, 16, C.textSecondary, { width = "100%", height = 26, textAlign = "left" }),
                        Kit.CompactTxt("今日 " .. tostring(item.todayCount or 0) .. " / " .. tostring(item.limit or 0) .. " 次", 18, (remaining or 0) > 0 and C.success or C.textDim, { width = "100%", height = 30, textAlign = "left", textStroke = { width = 1, color = "#000000" } }),
                        Kit.CompactTxt(
                            "每类共享次数 · 胜利结算 · 失败或撤退消耗次数",
                            16,
                            C.gold,
                            { width = "100%", height = 26, textAlign = "left" }
                        ),
                    } },
                    UI.Panel {
                        width = 160, height = 160, flexShrink = 0,
                        flexDirection = "column", justifyContent = "center", alignItems = "center", gap = 10,
                        children = {
                            UI.Badge {
                                text = (remaining or 0) > 0 and ("剩余 " .. tostring(remaining) .. " 次") or "已用完",
                                variant = (remaining or 0) > 0 and "success" or "secondary",
                            },
                            -- 互斥操作：有剩余次数 → 进入；无次数且可看广告 → 看广告+1；否则 → 已用完
                            ((remaining or 0) > 0 or item.dungeonStageId)
                                and Kit.ImageButton(item.dungeonStageId and "继续副本" or "进入", 150, 60, ASSETS.ui.inventoryActionGold, StartStrikeAction, false)
                                or (adCan and Kit.ImageButton(require("client.RewardVideo").ActionText("看广告 +1次", "免广告 +1次"), 150, 60, ASSETS.ui.buttonBlueWide, WatchAdAction, false))
                                or Kit.CompactTxt("今日次数已用完", 16, C.textDim, {
                                    width = 160, height = 40, textAlign = "center",
                                    textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                                }),
                        },
                    },
                },
            },
            UI.Panel {
                width = "100%", flexShrink = 0,
                flexDirection = "row", flexWrap = "wrap", gap = 10,
                children = tierBadges,
            },
        },
    }
end

local function PlayerPower(game)
    local stats = game and game.stats or {}
    if stats.displayedPower ~= nil then return stats.displayedPower end
    return stats.power or 0
end

local function TicketCostRow(cost, color, width)
    return UI.Panel {
        width = width or "100%",
        height = 30,
        flexShrink = 0,
        flexDirection = "row",
        justifyContent = "center",
        alignItems = "center",
        gap = 6,
        children = {
            UI.Panel {
                width = 24,
                height = 24,
                flexShrink = 0,
                backgroundImage = AbyssDefinitions.ICON,
                backgroundFit = "contain",
                pointerEvents = "none",
            },
            Kit.CompactTxt("×" .. tostring(cost), 16, color or C.gold, {
                width = 72, height = 26, textAlign = "left",
            }),
        },
    }
end

local function ShowAbyssRules(view, game)
    view = view or {}
    local poolMin = view.equipmentPoolMin or 1
    local poolMax = view.equipmentPoolMax or 10
    local dropFloor = AbyssDefinitions.DropPoolFloor(game)
    local rarity = RarityCatalog.HighestUnlocked(dropFloor)
    local lines = {
        "深渊票是入场消耗，主动挑战先扣票再开战。",
        "限时挑战深渊 Boss，击杀才结算装备与返还票；未击杀只给少量碎片。",
        "装备等级池每 10 级更新一次，当前为 Lv."
            .. tostring(poolMin) .. "-" .. tostring(poolMax) .. "。",
        "品质池按当前等级与最高通关层取高，当前最高品质："
            .. (rarity and rarity.name or "普通") .. "。",
        "连续 5 次未掉装备，第 6 次必出；主动、随机、Boss 共用保底。",
        "每日广告补给最多 3 次，每次发放当前灾厄票价的 80%。",
        "激励广告只翻倍金币、经验、碎片和深渊票，装备不翻倍。",
        "挂机途中有概率遇到免费随机深渊，颜色与活动档位一致。",
    }
    for _, item in ipairs(view.grades or {}) do
        lines[#lines + 1] = item.name
            .. "：消耗 " .. tostring(item.ticketCost)
            .. " 票，推荐战力 " .. Kit.FormatInt(item.recommendedPower)
            .. "，掉率 " .. tostring(math.floor(item.dropChance * 100)) .. "%"
            .. (item.unlocked and "" or ("，Lv." .. tostring(item.minLevel) .. " 解锁"))
    end
    CommonPromptDialog.Show {
        kind = "confirm",
        priority = 1280,
        queueKey = "abyss_rules",
        title = "深渊规则",
        message = "档位、票价、装备池与保底说明",
        lines = lines,
        closeOnOverlay = true,
        showClose = true,
        confirmText = "知道了",
    }
end

-- ===== 深渊模式活动卡片 =====
local function AbyssActivityCard()
    local game = GameStateAdapter.GetViewState()
    local view = game.abyssView or AbyssDefinitions.BuildView(game)
    local selected = AbyssDefinitions.Get(selectedAbyssGrade_)
    if not selected or not AbyssDefinitions.IsUnlocked(selectedAbyssGrade_, game.level) then
        selectedAbyssGrade_ = "rift"
        selected = AbyssDefinitions.Get(selectedAbyssGrade_)
    end

    local selectedView = nil
    local setButtons = {}
    for _, entry in ipairs({ { "nightmare", "噩梦" }, { "lucky", "幸运" }, { "voyage", "远征" }, { "abyss", "深渊" }, { "prophecy", "预言" } }) do
        local setId, name = entry[1], entry[2]
        setButtons[#setButtons + 1] = Kit.ActionButton { text = name, width = 160,
            variant = selectedAbyssSet_ == setId and "reward" or "secondary",
            onClick = function() selectedAbyssSet_ = setId; ActivityController.Refresh() end }
    end
    local gradeCards = {}
    for _, item in ipairs(view.grades or {}) do
        if item.id == selectedAbyssGrade_ then selectedView = item end
        local gradeId = item.id
        local active = gradeId == selectedAbyssGrade_
        local recommended = item.recommendedPower or AbyssDefinitions.RecommendedPower(game.level, gradeId)
        local powerOk = BigNumber.Compare(PlayerPower(game), recommended) >= 0
        gradeCards[#gradeCards + 1] = UI.Panel {
            width = 280,
            height = 338,
            flexShrink = 0,
            padding = 14,
            gap = 6,
            clickable = item.unlocked == true,
            opacity = item.unlocked and 1.0 or 0.48,
            backgroundColor = SURFACE_DARK,
            borderWidth = active and 4 or 2,
            borderColor = active and item.color or C.border,
            boxShadow = active and {
                color = { item.color[1], item.color[2], item.color[3], 100 },
                offsetX = 6,
                offsetY = 6,
                blurRadius = 0,
            } or nil,
            onClick = function()
                if item.unlocked then
                    selectedAbyssGrade_ = gradeId
                    ActivityController.Refresh()
                end
            end,
            children = {
                UI.Panel {
                    width = "100%",
                    height = 132,
                    flexShrink = 0,
                    alignItems = "center",
                    children = {
                        AbyssPresentation.BuildPillar(gradeId, { width = 92, height = 132, fontSize = 13 }),
                    },
                },
                Kit.Txt(item.name, 20, item.color, {
                    width = "100%", height = 30, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                }),
                TicketCostRow(item.ticketCost, C.gold),
                Kit.CompactTxt(
                    "推荐战力 " .. Kit.FormatInt(recommended),
                    15,
                    powerOk and C.success or C.error,
                    { width = "100%", height = 24, textAlign = "center" }
                ),
                Kit.CompactTxt("装备掉率 " .. tostring(math.floor(item.dropChance * 100)) .. "%", 14, C.textSecondary, {
                    width = "100%", height = 22, textAlign = "center",
                }),
                Kit.CompactTxt(
                    item.unlocked and ("×" .. tostring(item.multiplier) .. " 已解锁")
                        or ("Lv." .. tostring(item.minLevel) .. " 解锁"),
                    14,
                    item.unlocked and C.success or C.textDim,
                    { width = "100%", height = 22, textAlign = "center" }
                ),
            },
        }
    end
    selectedView = selectedView or view.grades[1]
    local canAfford = selectedView and view.tickets >= selectedView.ticketCost
    local canEnter = selectedView and selectedView.unlocked and canAfford

    local function EnterAbyssBoss()
        if not selectedView then return end
        if not canAfford then
            Toast("深渊票不足，需要 " .. tostring(selectedView.ticketCost) .. " 张", "warning")
            return
        end
        PrepareScene(function()
            local generation = sceneGeneration_
            ActivityController.BeginAbyssBoss(selectedView.id, function(response)
                if generation ~= sceneGeneration_ then return end
                if response and response.ok then
                    sceneGeneration_ = sceneGeneration_ + 1
                    sceneMode_ = "boss"
                    bossActive_ = true
                    local challenge = GameStateAdapter.GetViewState().challengesView or {}
                    bossEndsAt_ = (challenge.sessionStartedAt or ServerClock.Now()) + ChallengeDefinitions.BOSS.DURATION
                    bossRunId_ = challenge.sessionRunId or ""
                    bossRemaining_ = math.max(0, bossEndsAt_ - ServerClock.Now())
                    finishingScene_, finishRequestPending_, attackRequestPending_ = false, false, false
                    finishRetryTimer_ = 0
                    strikeAttackTime_ = 0
                    strikeLastDamage_ = 0
                    currentStrikeAttackFrames_ = nil
                    strikeWindup_ = 0
                    strikeRecovery_ = 0
                    strikeHitFrame_ = 1
                    strikeEndFrame_ = 1
                    strikeSequenceIndex_ = 0
                    damageLabels_ = {}
                    strikeRefs_ = {}
                    ActivityController.Refresh()
                else
                    Toast((response and response.reason) or "深渊 Boss 开启失败", "warning")
                end
            end, selectedAbyssSet_)
        end)
    end

    local exclusive = game.rewardClaims and game.rewardClaims.exclusive or {}
    local dayKey = math.floor((ServerClock.Now() + 8 * 60 * 60) / (24 * 60 * 60))
    local dailyUsed = exclusive.dailyDayKey == dayKey
        and math.max(0, math.floor(tonumber(exclusive.dailyClaimed) or 0))
        or 0
    local dailyLimit = view.dailyAdLimit or AbyssDefinitions.DAILY_AD_TICKET_LIMIT
    local dailyTickets = view.dailyAdTickets or AbyssDefinitions.DailyAdTickets(game.level)
    local dailyFull = dailyUsed >= dailyLimit

    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        padding = 22,
        gap = 16,
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        backgroundColor = SURFACE,
        borderWidth = 3,
        borderColor = selectedView and selectedView.color or C.focus,
        children = {
            UI.Panel {
                width = "100%", flexShrink = 0, flexDirection = "row", alignItems = "center",
                children = {
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 4, children = {
                        UI.Panel {
                            width = "100%", height = 42, flexShrink = 0,
                            flexDirection = "row", alignItems = "center",
                            children = {
                                Kit.Txt("深渊模式", 30, C.text, {
                                    flexGrow = 1, flexBasis = 0, height = 42, textAlign = "left",
                                    textStroke = { width = 3, color = "#000000" },
                                }),
                                UI.Panel {
                                    width = 42, height = 42, flexShrink = 0,
                                    clickable = true,
                                    alignItems = "center", justifyContent = "center",
                                    backgroundColor = { 8, 24, 56, 220 },
                                    borderWidth = 2, borderColor = C.focus, borderRadius = 21,
                                    onClick = function() ShowAbyssRules(view, game) end,
                                    children = {
                                        Kit.Txt("?", 26, C.focus, {
                                            width = 42, height = 42, textAlign = "center",
                                            textStroke = { width = 2, color = "#000000" },
                                            pointerEvents = "none",
                                        }),
                                    },
                                },
                            },
                        },
                        UI.Panel {
                            width = "100%", height = 30, flexShrink = 0,
                            flexDirection = "row", alignItems = "center", gap = 8,
                            children = {
                                UI.Panel {
                                    width = 28, height = 28, flexShrink = 0,
                                    backgroundImage = AbyssDefinitions.ICON,
                                    backgroundFit = "contain",
                                    pointerEvents = "none",
                                },
                                Kit.CompactTxt(
                                    tostring(view.tickets)
                                        .. "    保底 " .. tostring(view.dryStreak) .. "/"
                                        .. tostring(math.max(1, view.guaranteeAt - 1)),
                                    18,
                                    C.gold,
                                    { flexGrow = 1, flexBasis = 0, height = 30, textAlign = "left" }
                                ),
                            },
                        },
                    } },
                },
            },
            UI.Panel {
                width = "100%",
                flexShrink = 0,
                flexDirection = "row",
                justifyContent = "center",
                gap = 16,
                children = gradeCards,
            },
            Kit.MultiTxt("目标套装 · 主动挑战掉落所选套装；100级只掉100级装备。\n史诗每10次装备掉落保底，神话每40次装备掉落保底。", 18, C.gold, { width = "100%" }),
            UI.Panel { width = "100%", flexShrink = 0, flexDirection = "row", flexWrap = "wrap", gap = 10, children = setButtons },
            UI.Panel {
                width = "100%",
                flexShrink = 0,
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                gap = 12,
                children = {
                    Kit.ImageButton(
                        dailyFull
                            and ("补给已满 " .. tostring(dailyUsed) .. "/" .. tostring(dailyLimit))
                            or (require("client.RewardVideo").ActionText("看广告补给 +", "免广告补给 +") .. tostring(dailyTickets)
                                .. "  " .. tostring(dailyUsed) .. "/" .. tostring(dailyLimit)),
                        360,
                        64,
                        dailyFull and ASSETS.ui.buttonBlueWide or ASSETS.ui.inventoryActionGold,
                        function()
                            RewardClaimController.ClaimExclusiveGift("daily")
                        end,
                        dailyFull
                    ),
                    UI.Panel {
                        flexGrow = 1, flexBasis = 0, height = 64,
                        flexDirection = "row", justifyContent = "flex-end",
                        alignItems = "center", gap = 10,
                        children = {
                            TicketCostRow(selectedView.ticketCost, selectedView.color, 110),
                            Kit.ImageButton(
                                "挑战 Boss",
                                220,
                                64,
                                canEnter and ASSETS.ui.inventoryActionGold or ASSETS.ui.buttonBlueWide,
                                EnterAbyssBoss,
                                not canEnter
                            ),
                        },
                    },
                },
            },
        },
    }
end

-- ===== 热门活动入口卡片（许愿池 / 深渊远征 / PVP）=====
-- 许愿池为已开放玩法（点击进入）；其余为“待开放”占位，点击提示。
local function HotActivityCard(spec)
    local opened = spec.opened == true
    local icon = spec.icon
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        padding = 20,
        gap = 14,
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        backgroundColor = SURFACE,
        borderWidth = 2,
        borderColor = opened and C.focus or C.border,
        borderRadius = 14,
        opacity = opened and 1.0 or 0.82,
        children = {
            UI.Panel {
                width = "100%", flexShrink = 0, flexDirection = "row", alignItems = "center",
                children = {
                    -- 左侧图标格
                    UI.Panel {
                        width = 110, height = 110, flexShrink = 0,
                        backgroundImage = icon,
                        backgroundFit = "contain",
                    },
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 4, children = {
                        Kit.Txt(spec.title, 28, opened and C.text or C.textDim, { width = "100%", height = 40, textAlign = "left", textStroke = { width = 2, color = "#000000" } }),
                        Kit.CompactTxt(spec.desc, 16, C.textSecondary, { width = "100%", height = 26, textAlign = "left" }),
                        Kit.CompactTxt(opened and spec.status or "待后续开放", 18, opened and C.success or C.textDim, { width = "100%", height = 30, textAlign = "left", textStroke = { width = 1, color = "#000000" } }),
                    } },
                    -- 右侧操作区：进入按钮与其他活动统一（金色图片按钮）
                    UI.Panel {
                        width = 170, height = 150, flexShrink = 0,
                        flexDirection = "column", justifyContent = "center", alignItems = "center", gap = 10,
                        children = {
                            opened
                                and Kit.ImageButton("进入", 150, 60, ASSETS.ui.inventoryActionGold, spec.onClick, false)
                                or UI.Badge {
                                    text = "待开放",
                                    variant = "secondary",
                                },
                        },
                    },
                },
            },
        },
    }
end

local function HotActivityCards()
    local cards = {}
    cards[#cards + 1] = HotActivityCard {
        title = "许愿补给",
        desc = "4次广告依次领取1、2、3、4张许愿券",
        status = "每日共10张 · 北京时间零点刷新",
        opened = true, icon = ASSETS.ui.wishTicket,
        onClick = function() require("client.AdGiftController").Show("wishSupply") end,
    }
    cards[#cards + 1] = HotActivityCard {
        title = "幸运礼包",
        desc = "首次通关每10层解锁一次，旧层不重复",
        status = "每次广告2张许愿券 · 机会可累计",
        opened = true, icon = ASSETS.ui.wishTicket,
        onClick = function() require("client.AdGiftController").Show("lucky") end,
    }
    cards[#cards + 1] = HotActivityCard {
        title = "塔灵礼包",
        desc = "查看全部礼包与剩余领取次数",
        status = "六种原有补给及许愿券礼包",
        opened = true,
        icon = ASSETS.items.crystal,
        onClick = function() require("client.AdGiftController").Open() end,
    }
    -- 许愿池：已开放，跳转许愿池页
    cards[#cards + 1] = HotActivityCard {
        title = "许愿池",
        desc = "许愿券抽取 · 十连8券",
        status = "开放中",
        opened = true,
        icon = ASSETS.ui.wishTicket,
        onClick = function()
            require("client.NavigationController").SwitchPage("wish")
        end,
    }
    cards[#cards + 1] = AbyssActivityCard()
    -- PVP 竞技场：玩家对战，待后续开放
    cards[#cards + 1] = HotActivityCard {
        title = "PVP 竞技场",
        desc = "玩家对战 · 战力对决",
        opened = false,
        icon = ASSETS.ui.activityPvp,
        onClick = function() Toast("PVP 竞技场筹备中，敬请期待", "info") end,
    }
    return cards
end

-- ===== 伤害飘字对象池 =====
local function SpawnDamageText(amount, critical)
    for _, label in ipairs(damageLabels_) do
        if not label.active then
            label.active = true
            label.age = 0
            ChangedOnly.Text(label.node, (critical and "暴击 " or "") .. Kit.FormatInt(amount))
            label.node:SetStyle({ visible = true, left = label.baseX, top = label.baseY })
            return
        end
    end
end

local function UpdateDamageTexts(dt)
    for _, label in ipairs(damageLabels_) do
        if label.active then
            label.age = label.age + dt
            if label.age >= 0.9 then
                label.active = false
                label.node:SetStyle({ visible = false })
            else
                label.node:SetStyle({
                    left = label.baseX + math.sin(label.age * 20) * 6,
                    top = label.baseY - label.age * 90,
                    fontColor = { 255, 90, 100, math.floor(255 * math.max(0, 1 - label.age / 0.9)) },
                    scale = 1.0 + math.max(0, 1 - label.age * 4) * 0.4,
                })
            end
        end
    end
end

-- ===== 打桩 / Boss 场景（固定站位，玩家自动攻击） =====
local function BuildStrikeScene(item, mode)
    mode = mode or "strike"
    local isBoss = mode == "boss"
    local width, height = 1080, math.max(980, UILayout.ContentHeight())
    -- 角色与木桩整体居中：木桩在画面中央，角色在其左侧面向木桩
    local playerX, playerY = 170, 900
    local stumpX, stumpY = 390, 880
    local stumpSize = isBoss and 360 or 300
    local stumpImage = isBoss and ASSETS.enemies.boss or StumpImage(item.rewardKind)

    ---@type table[]
    local sceneChildren = {
        UI.Panel { position = "absolute", left = 0, top = 0, width = width, height = height, backgroundImage = ASSETS.ui.strikeBg, backgroundFit = "cover", pointerEvents = "none" },
    }

    local stump = UI.Panel {
        position = "absolute", left = stumpX, top = stumpY, width = stumpSize, height = stumpSize,
        backgroundImage = stumpImage, backgroundFit = "contain",
    }
    sceneChildren[#sceneChildren + 1] = stump

    -- 角色帧等比放大（2:1 匹配攻击帧，与木桩尺度相当）；初始用攻击起手帧，避免立绘闪现
    local playerFirstFrame = (ASSETS.player.attackFrameSets
        and ASSETS.player.attackFrameSets[1]
        and ASSETS.player.attackFrameSets[1][1])
        or ASSETS.player.icon
    local player = UI.Panel {
        position = "absolute", left = playerX, top = playerY, width = 460, height = 230,
        backgroundImage = playerFirstFrame, backgroundFit = "contain",
    }
    sceneChildren[#sceneChildren + 1] = player

    local slash = UI.Panel {
        position = "absolute", left = playerX + 300, top = playerY + 70, width = 300, height = 130,
        visible = false, pointerEvents = "none",
        backgroundGradient = { type = "linear", direction = "to-right", from = { 255, 255, 255, 0 }, to = { 255, 220, 90, 0 } },
    }
    sceneChildren[#sceneChildren + 1] = slash

    local remaining = isBoss and bossRemaining_ or strikeRemaining_
    local countdown = Kit.CompactTxt(string.format("剩余 %d 秒", math.max(0, math.ceil(remaining))), 32, C.focus, {
        position = "absolute", left = 0, top = 48, width = width, height = 48, textAlign = "center",
        textStroke = { width = 3, color = "#000000" },
    })
    local damageText = isBoss
        and ("Boss 血量 " .. tostring(item.sessionHp or item.sessionMaxHp or 0)
            .. " / " .. tostring(item.sessionMaxHp or 0))
        or ("累计伤害 " .. tostring(item.sessionDamage or 0))
    local damageLabel = Kit.CompactTxt(damageText, 26, C.gold, {
        position = "absolute", left = 0, top = 104, width = width, height = 42, textAlign = "center",
        textStroke = { width = 2, color = "#000000" },
    })
    local targetDamage = isBoss and math.max(1, item.sessionMaxHp or 1)
        or require("shared.GameBalance").StrikeTarget(GameStateAdapter.GetViewState().level, 3)
    local currentValue = isBoss
        and math.max(0, (item.sessionMaxHp or 0) - (item.sessionHp or 0))
        or (item.sessionDamage or 0)
    local ratio = math.max(0, math.min(1, currentValue / targetDamage))
    local damageFill = UI.Panel {
        position = "absolute", left = 0, top = 0, width = math.floor(796 * ratio), height = 22,
        backgroundColor = isBoss and { 255, 90, 100, 255 } or C.gold, pointerEvents = "none",
    }
    local damageTrack = UI.Panel {
        position = "absolute", left = 142, top = 156, width = 796, height = 26,
        backgroundColor = { 8, 20, 40, 255 }, borderWidth = 2, borderColor = { 10, 16, 32, 255 },
        overflow = "hidden", children = { damageFill },
    }
    local tip = Kit.CompactTxt(
        isBoss and "限时击杀深渊 Boss，伤害计入 Boss 榜" or "限时攻击木桩，伤害越高奖励越高，并计入伤害榜",
        18,
        C.textSecondary,
        {
            position = "absolute", left = 0, top = 196, width = width, height = 32, textAlign = "center",
        }
    )
    sceneChildren[#sceneChildren + 1] = countdown
    sceneChildren[#sceneChildren + 1] = damageLabel
    sceneChildren[#sceneChildren + 1] = damageTrack
    sceneChildren[#sceneChildren + 1] = tip

    damageLabels_ = {}
    for index = 1, 6 do
        local node = Kit.CompactTxt("", 30, { 255, 90, 100, 255 }, {
            position = "absolute", left = 0, top = 0, width = 240, textAlign = "center", visible = false,
            textStroke = { width = 3, color = "#000000" },
        })
        sceneChildren[#sceneChildren + 1] = node
        damageLabels_[#damageLabels_ + 1] = {
            node = node,
            active = false,
            age = 0,
            baseX = stumpX + stumpSize * 0.5 - 120,
            baseY = stumpY - 70,
        }
    end

    strikeRefs_ = { player = player, stump = stump, slash = slash, countdown = countdown, damageLabel = damageLabel, damageFill = damageFill, playerX = playerX, stumpX = stumpX }
    strikeLastDamage_ = item.sessionDamage or 0

    return UI.Panel {
        width = "100%", height = "100%", flexShrink = 0, position = "relative", overflow = "hidden",
        children = sceneChildren,
    }
end

local function TriggerAttack()
    if not strikeRefs_.player then return end
    local count = math.min(CombatSequence.Count(), #(ASSETS.player.attackFrameSets or {}))
    if count <= 0 then
        currentStrikeAttackFrames_ = STRIKE_ATTACK_FRAMES
        strikeWindup_ = 0.12
        strikeRecovery_ = 0.18
        strikeHitFrame_ = 1
        strikeEndFrame_ = #STRIKE_ATTACK_FRAMES
        strikeAttackTime_ = 0.01
        strikeHitTriggered_ = false
        return
    end
    -- 三个攻击动画按顺序轮流完整播放：A → B → C → A …（不随机、不闪切）
    local index = (strikeSequenceIndex_ % count) + 1
    strikeSequenceIndex_ = index
    local sequence = CombatSequence.SEQUENCES[index]
    local hitFrame = sequence.hitFrames[1]
    local sets = ASSETS.player.attackFrameSets
    currentStrikeAttackFrames_ = sets and sets[index] or STRIKE_ATTACK_FRAMES
    strikeWindup_ = math.max(0.001, (hitFrame - 1) / sequence.fps)
    strikeRecovery_ = math.max(0.001, (sequence.endFrame - hitFrame + 1) / sequence.fps)
    strikeHitFrame_ = hitFrame
    strikeEndFrame_ = sequence.endFrame
    strikeAttackTime_ = 0.01
    strikeHitTriggered_ = false
    if strikeRefs_.slash then strikeRefs_.slash:SetStyle({ visible = true, opacity = 1 }) end
end

local function UpdateAttack(dt)
    if not strikeRefs_.player or finishingScene_ then return end
    if strikeAttackTime_ > 0 then
        strikeAttackTime_ = strikeAttackTime_ + dt
        local t = strikeAttackTime_
        local frames = currentStrikeAttackFrames_ or STRIKE_ATTACK_FRAMES
        local total = #frames
        local windup = math.max(0.001, strikeWindup_ or 0.12)
        local recovery = math.max(0.001, strikeRecovery_ or 0.18)
        local hitFrame = math.max(1, math.min(total, strikeHitFrame_ or 16))
        local endFrame = math.max(hitFrame, math.min(total, strikeEndFrame_ or total))
        -- 登塔式帧插值：前摇 → 命中帧 → 收招帧
        local frame
        if t < windup then
            frame = 1 + math.floor(math.max(0, math.min(1, t / windup)) * (hitFrame - 1))
        else
            frame = hitFrame + math.floor(math.max(0, math.min(1, (t - windup) / recovery)) * (endFrame - hitFrame))
        end
        frame = math.max(1, math.min(total, frame))
        ChangedOnly.Style(strikeRefs_.player, {
            backgroundImage = frames[frame],
            scale = 1.0 + math.max(0, 1 - t / (windup + recovery)) * 0.04,
        })
        ChangedOnly.Style(strikeRefs_.stump, { scale = 1.0 + math.sin(t * 40) * 0.05 })
        if strikeRefs_.slash then
            local progress = math.max(0, math.min(1, t / windup))
            local playerX = strikeRefs_.playerX or 150
            if progress < 1 then ChangedOnly.Style(strikeRefs_.slash, {
                visible = true,
                left = playerX + 300 + progress * 220,
                opacity = (1 - progress) * 0.9,
                scale = 0.7 + progress * 0.8,
            }) else ChangedOnly.Style(strikeRefs_.slash, { visible = false }) end
        end
        -- 命中帧：触发一次伤害（服务端按玩家属性计算，飘字随权威结算显示）
        if not strikeHitTriggered_ and t >= windup then
            strikeHitTriggered_ = true
            if not attackRequestPending_ then
                attackRequestPending_ = true
                local generation = sceneGeneration_
                local function OnHit(response)
                    if generation ~= sceneGeneration_ then return end
                    attackRequestPending_ = false
                    if not response or not response.ok then
                        Toast((response and response.reason) or "攻击同步失败，正在重新同步", "warning")
                        ServerClient.RequestSnapshot()
                    end
                end
                if sceneMode_ == "boss" then
                    ActivityController.StrikeAbyssBoss(OnHit)
                elseif strikeId_ then
                    ActivityController.Strike(strikeId_, OnHit)
                end
            end
        end
        if t >= windup + recovery then
            -- 动画播完：保持收招帧短暂停留，避免切换闪帧
            strikeAttackTime_ = -0.15
            currentStrikeAttackFrames_ = nil
            if strikeRefs_.slash then strikeRefs_.slash:SetStyle({ visible = false }) end
        end
    elseif strikeAttackTime_ < 0 then
        -- 收招停留：保持当前帧倒计时，播完切下一个
        strikeAttackTime_ = strikeAttackTime_ + dt
        if strikeAttackTime_ >= 0 then strikeAttackTime_ = 0 end
    else
        -- 动画空闲：开始下一次攻击动画（按顺序轮流完整播放）
        TriggerAttack()
    end
end

local function ResetScene()
    sceneGeneration_ = sceneGeneration_ + 1
    finishingScene_, finishRequestPending_, attackRequestPending_ = false, false, false
    finishRetryTimer_, strikeEndsAt_, bossEndsAt_ = 0, 0, 0
    bossRunId_ = ""
    strikeSequenceIndex_, strikeHitTriggered_ = 0, false
    strikeLastDamage_, strikeWindup_, strikeRecovery_ = 0, 0, 0
    strikeHitFrame_, strikeEndFrame_ = 1, 1
    strikeId_ = nil
    strikeRemaining_ = 0
    strikeTimer_ = 0
    strikeAttackTime_ = 0
    currentStrikeAttackFrames_ = nil
    damageLabels_ = {}
    strikeRefs_ = {}
    bossActive_ = false
    bossRemaining_ = 0
    bossLastHp_ = 0
    sceneMode_ = "strike"
end

FinishScene = function()
    if not strikeId_ and not bossActive_ then return end
    finishingScene_ = true
    if finishRequestPending_ or attackRequestPending_ or finishRetryTimer_ > 0 then return end
    finishRequestPending_ = true
    ChangedOnly.Text(strikeRefs_.countdown, "正在结算…")
    local generation = sceneGeneration_
    local function OnFinished(response)
        if generation ~= sceneGeneration_ then return end
        finishRequestPending_ = false
        if not response or not response.ok then
            finishRetryTimer_ = 2
            ChangedOnly.Text(strikeRefs_.countdown, "结算暂未完成，正在重试…")
            return
        end
        ResetScene()
        ServerClient.RequestSnapshot()
        ActivityController.Refresh()
    end
    if bossActive_ then ActivityController.FinishAbyssBoss(OnFinished)
    else ActivityController.FinishStrike(strikeId_, OnFinished) end
end

function ActivityView.UpdateAd(dt)
    if not strikeAdInFlight_ or not strikeAdFinish_ then return end
    strikeAdElapsed_ = strikeAdElapsed_ + math.max(0, tonumber(dt) or 0)
    if strikeAdElapsed_ >= STRIKE_AD_WATCHDOG_SECONDS then
        strikeAdFinish_({ success = false, msg = "广告响应超时，请稍后重试" })
    end
end

-- ===== 每帧更新：自动攻击 + 伤害检测 + 倒计时 + 动画 =====
function ActivityView.Update(dt)
    if dungeonView_ then dungeonView_:Update(dt); return end
    dt = math.max(0, tonumber(dt) or 0)
    finishRetryTimer_ = math.max(0, finishRetryTimer_ - dt)
    if bossActive_ then
        local game = GameStateAdapter.GetViewState()
        local challenge = game.challengesView or ChallengeDefinitions.BuildView(game)
        if not challenge.sessionActive then
            ResetScene()
            ActivityController.Refresh()
            return
        end
        if challenge.sessionStartedAt then
            bossEndsAt_ = challenge.sessionStartedAt + ChallengeDefinitions.BOSS.DURATION
        end
        bossRunId_ = challenge.sessionRunId or bossRunId_
        bossRemaining_ = math.max(0, bossEndsAt_ - ServerClock.Now())
        if finishingScene_ or bossRemaining_ <= 0 then FinishScene(); return end
        UpdateAttack(dt)
        local hp = challenge.sessionHp or 0
        local maxHp = math.max(1, challenge.sessionMaxHp or 1)
        local damage = challenge.sessionDamage or 0
        if hp < bossLastHp_ or damage > strikeLastDamage_ then
            bossLastHp_ = hp
            strikeLastDamage_ = damage
            if strikeRefs_.damageLabel then
                strikeRefs_.damageLabel:SetText("Boss 血量 " .. tostring(hp) .. " / " .. tostring(maxHp))
            end
            if strikeRefs_.damageFill then
                local ratio = math.max(0, math.min(1, (maxHp - hp) / maxHp))
                strikeRefs_.damageFill:SetStyle({ width = math.floor(796 * ratio) })
            end
        end
        UpdateDamageTexts(dt)
        ChangedOnly.Text(strikeRefs_.countdown, string.format("剩余 %d 秒", math.ceil(bossRemaining_)))
        if hp <= 0 then FinishScene() end
        return
    end

    if not strikeId_ then return end
    local game = GameStateAdapter.GetViewState()
    local view = game.activitiesView
    local item = nil
    for _, it in ipairs(view and view.strike or {}) do
        if it.id == strikeId_ then item = it end
    end
    if not item or not item.sessionActive then
        ResetScene()
        ActivityController.Refresh()
        return
    end
    if item.sessionStartedAt then
        strikeEndsAt_ = item.sessionStartedAt + (item.duration or 15)
    end
    strikeRemaining_ = math.max(0, strikeEndsAt_ - ServerClock.Now())
    if finishingScene_ or strikeRemaining_ <= 0 then FinishScene(); return end

    -- 攻击动画按放置挂机节奏推进（命中帧内触发一次伤害+飘字）
    UpdateAttack(dt)

    -- 累计伤害同步（伤害条/文字，随服务端权威结算；飘字由活动事件驱动显示实际伤害）
    local damage = item.sessionDamage or 0
    if damage > strikeLastDamage_ then
        strikeLastDamage_ = damage
        if strikeRefs_.damageLabel then strikeRefs_.damageLabel:SetText("累计伤害 " .. tostring(damage)) end
        if strikeRefs_.damageFill then
            local ratio = math.max(0, math.min(1, damage / require("shared.GameBalance").StrikeTarget(GameStateAdapter.GetViewState().level, 3)))
            strikeRefs_.damageFill:SetStyle({ width = math.floor(796 * ratio) })
        end
    end
    UpdateDamageTexts(dt)

    ChangedOnly.Text(strikeRefs_.countdown, string.format("剩余 %d 秒", math.ceil(strikeRemaining_)))
end

function ActivityView.ListChildren(signinCards, strikeCards)
    -- 按当前页签返回对应子页面的内容（竖行排列）
    local children = {}
    for _, entry in ipairs(ACTIVITY_TABS) do
        if entry.id == activityTab_ then
            if entry.kind == "signin" then
                for _, card in ipairs(signinCards or {}) do
                    if card and card.props and card.props.tabId == entry.id then
                        children[#children + 1] = card
                    end
                end
            elseif entry.kind == "strike" then
                -- 每日补给：三个放同一子页面，竖行排列
                for _, card in ipairs(strikeCards or {}) do
                    children[#children + 1] = card
                end
            else
                -- 热门活动：许愿池（开放）/ 深渊远征 / PVP（待开放）
                for _, card in ipairs(HotActivityCards()) do
                    children[#children + 1] = card
                end
            end
        end
    end
    return children
end

local function WrapPage(root)
    local pageTab = activityTab_
    local pageScene = sceneMode_
    local pageStrikeId, pageBossActive, generation = strikeId_, bossActive_, sceneGeneration_
    return {
        GetRoot = function() return root end,
        Update = function()
            if activityTab_ ~= pageTab or sceneMode_ ~= pageScene
                or strikeId_ ~= pageStrikeId or bossActive_ ~= pageBossActive
                or sceneGeneration_ ~= generation then return false end
            if ActivityView.IsStriking() then return true end
            return false
        end,
        Destroy = function()
            if dungeonView_ and root == dungeonView_.root then
                dungeonView_:Destroy()
                dungeonView_ = nil
                sceneGeneration_ = sceneGeneration_ + 1
                return
            end
            if root and root.Destroy then root:Destroy() end
        end,
    }
end

function ActivityView.BuildPage()
    if dungeonView_ then return WrapPage(dungeonView_.root) end
    local view = CurrentView()
    if not bossActive_ then
        local game = GameStateAdapter.GetViewState()
        local leftover = game.challengesView or ChallengeDefinitions.BuildView(game)
        if leftover.sessionActive then
            sceneMode_ = "boss"
            bossActive_ = true
            bossEndsAt_ = (leftover.sessionStartedAt or ServerClock.Now()) + ChallengeDefinitions.BOSS.DURATION
            bossRunId_ = leftover.sessionRunId or ""
            bossRemaining_ = math.max(0, bossEndsAt_ - ServerClock.Now())
        end
    end
    if not bossActive_ and not strikeId_ then
        for _, item in ipairs(view.strike or {}) do
            if item.sessionActive and not item.dungeonStageId then
                sceneMode_, strikeId_ = "strike", item.id
                strikeEndsAt_ = (item.sessionStartedAt or ServerClock.Now()) + (item.duration or 15)
                strikeRemaining_ = math.max(0, strikeEndsAt_ - ServerClock.Now())
                break
            end
        end
    end

    if bossActive_ then
        local game = GameStateAdapter.GetViewState()
        local challenge = game.challengesView or ChallengeDefinitions.BuildView(game)
        if not challenge.sessionActive then
            ResetScene()
        else
            bossLastHp_ = challenge.sessionHp or challenge.sessionMaxHp or 0
            return WrapPage(UI.Panel {
                width = "100%", height = "100%", flexShrink = 0, position = "relative",
                children = {
                    BuildStrikeScene(challenge, "boss"),
                    Kit.BackButton {
                        left = 20, top = 20, width = 110, height = 64, fontSize = 24,
                        onClick = function()
                            CommonPromptDialog.Show {
                                kind = "confirm",
                                priority = 1250,
                                queueKey = "boss_exit_confirm",
                                title = "退出深渊 Boss",
                                message = "退出后本次深渊票不返还，确定退出？",
                                lines = { "未击杀只发放少量碎片，已造成伤害仍会计入 Boss 榜。" },
                                closeOnOverlay = false,
                                showClose = false,
                                confirmText = "确认退出",
                                cancelText = "继续挑战",
                                onConfirm = function()
                                    FinishScene()
                                end,
                            }
                        end,
                    },
                },
            })
        end
    end

    if strikeId_ then
        local active = nil
        for _, item in ipairs(view.strike or {}) do
            if item.id == strikeId_ then active = item end
        end
        if not active then strikeId_ = nil else
            return WrapPage(UI.Panel {
                width = "100%", height = "100%", flexShrink = 0, position = "relative",
                children = {
                    BuildStrikeScene(active, "strike"),
                    Kit.BackButton {
                        left = 20, top = 20, width = 110, height = 64, fontSize = 24,
                        onClick = function()
                            CommonPromptDialog.Show {
                                kind = "confirm",
                                priority = 1250,
                                queueKey = "strike_exit_confirm",
                                title = "退出打桩",
                                message = "退出后本次打桩次数不返还，确定退出？",
                                lines = { "本次已造成的伤害会按实际结算，并计入伤害榜。" },
                                closeOnOverlay = false,
                                showClose = false,
                                confirmText = "确认退出",
                                cancelText = "继续打桩",
                                onConfirm = function()
                                    FinishScene()
                                end,
                            }
                        end,
                    },
                },
            })
        end
    end

    local signinCards = {}
    for _, item in ipairs(view.signin or {}) do signinCards[#signinCards + 1] = SigninCard(item) end
    local strikeCards = {}
    for _, item in ipairs(view.strike or {}) do strikeCards[#strikeCards + 1] = StrikeCard(item) end

    return WrapPage(UI.Panel {
        width = "100%", height = "100%", flexShrink = 0, position = "relative",
        children = {
            UI.Panel {
                width = "100%", height = "100%", flexShrink = 0,
                paddingLeft = 36, paddingRight = 36, paddingTop = 16, paddingBottom = 24,
                gap = 12,
                children = {
                    UI.Panel {
                        width = "100%", flexShrink = 0, height = 72, position = "relative",
                        children = {
                            Kit.Txt("活动", 34, C.text, { position = "absolute", left = 0, top = 8, width = 1000, height = 56, textAlign = "center", textStroke = { width = 3, color = "#000000" } }),
                            Kit.BackButton {
                                onClick = function() require("client.NavigationController").SwitchPage("home") end,
                            },
                        },
                    },
                    BuildTabBar(),
                    UI.ScrollView {
                        width = "100%", flexGrow = 1, flexBasis = 0,
                        scrollY = true, scrollX = false, showScrollbar = false,
                        children = {
                            UI.Panel {
                                width = "100%", flexShrink = 0, gap = 14, paddingBottom = 24,
                                children = ActivityView.ListChildren(signinCards, strikeCards),
                            },
                        },
                    },
                },
            },
        },
    })
end

function ActivityView.Reset()
    if dungeonView_ then dungeonView_:Destroy(); dungeonView_ = nil end
    ResetScene()
    strikeAdSequence_ = strikeAdSequence_ + 1
    strikeAdInFlight_ = false
    strikeAdRequestPending_ = false
    strikeAdElapsed_ = 0
    strikeAdFinish_ = nil

end

function ActivityView.IsStriking()
    return strikeId_ ~= nil or bossActive_ or dungeonView_ ~= nil
end

-- 打桩伤害飘字：监听服务端活动事件（权威实际伤害，含暴击）
ServerClient.On("delta", function(payload)
    if not ActivityView.IsStriking() then return end
    for _, event in ipairs((payload and payload.events) or {}) do
        local kind = event.kind or event.type
        if (kind == "activity_strike_hit" and strikeId_ and event.activityId == strikeId_)
            or (kind == "abyss_boss_hit" and bossActive_ and event.runId == bossRunId_) then
            SpawnDamageText(event.damage or 0, event.critical or event.lucky)
        end
    end
end)

return ActivityView
