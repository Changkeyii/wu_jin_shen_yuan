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
local LargeNumber = require("shared.LargeNumber")
local CombatSequence = require("shared.CombatSequence")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ActivityController = require("client.ActivityController")
local CommonPromptDialog = require("client.CommonPromptDialog")
local ServerClient = require("client.ServerClient")

local ActivityView = {}

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

-- ===== 页签状态 =====
-- tab 固定顺序：新手签到 → 轮回签到 → 每日补给（三个补给放同一子页面）
local activityTab_ = "act_signin_newbie_7"
local ACTIVITY_TABS = {
    { id = "act_signin_newbie_7", label = "新手签到", kind = "signin" },
    { id = "act_signin_loop_30", label = "轮回签到", kind = "signin" },
    { id = "strike", label = "每日补给", kind = "strike" },
}

local function BuildTabBar()
    local children = {}
    for _, entry in ipairs(ACTIVITY_TABS) do
        local active = activityTab_ == entry.id
        local currentEntry = entry
        children[#children + 1] = UI.Panel {
            width = 220,
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
    local remaining = item.remaining or 0
    local adCan = item.adCan == true
    local stumpImage = StumpImage(item.rewardKind)

    local tierBadges = {}
    for _, tier in ipairs(item.tiers or {}) do
        tierBadges[#tierBadges + 1] = UI.Card {
            width = 250, flexShrink = 0, padding = 12, gap = 4,
            backgroundColor = SURFACE_DARK,
            children = {
                Kit.CompactTxt(tier.minDamage > 0 and ("伤害 ≥ " .. tostring(tier.minDamage)) or "参与即有奖", 15, C.focus, { width = "100%", height = 24, textAlign = "left", textStroke = { width = 1, color = "#000000" } }),
                Kit.CompactTxt(RewardText(tier.reward), 13, C.textSecondary, { width = "100%", height = 36, textAlign = "left", maxLines = 2 }),
            },
        }
    end

    local function StartStrikeAction()
        ActivityController.BeginStrike(item.id, function(response)
            if response and response.ok then
                strikeId_ = item.id
                strikeRemaining_ = item.duration or 15
                strikeTimer_ = 0
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
            else
                Toast((response and response.reason) or "今日次数已用完", "warning")
            end
        end)
    end

    local function WatchAdAction()
        local accepted = _G["sdk"]:ShowRewardVideoAd(function(result)
            if result and result.success == true then
                ActivityController.UnlockExtraStrike(item.id)
            else
                Toast("需完整观看广告才能解锁额外次数", "warning")
            end
        end)
        if accepted == false then Toast("广告暂不可用，请稍后重试", "warning") end
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
                            (remaining or 0) > 0
                                and Kit.ImageButton("进入", 150, 60, ASSETS.ui.inventoryActionGold, StartStrikeAction, false)
                                or (adCan and Kit.ImageButton("看广告 +1次", 150, 60, ASSETS.ui.buttonBlueWide, WatchAdAction, false))
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

-- ===== 伤害飘字对象池 =====
local function SpawnDamageText(amount)
    for _, label in ipairs(damageLabels_) do
        if not label.active then
            label.active = true
            label.age = 0
            label.node:SetText(tostring(amount))
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

-- ===== 打桩场景（固定站位，玩家自动攻击木桩） =====
local function BuildStrikeScene(item)
    local width, height = 1080, 1560
    -- 角色与木桩整体居中：木桩在画面中央，角色在其左侧面向木桩
    local playerX, playerY = 170, 900
    local stumpX, stumpY = 390, 880
    local stumpSize = 300
    local stumpImage = StumpImage(item.rewardKind)

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

    local countdown = Kit.CompactTxt(string.format("剩余 %d 秒", math.max(1, math.ceil(strikeRemaining_))), 32, C.focus, {
        position = "absolute", left = 0, top = 48, width = width, height = 48, textAlign = "center",
        textStroke = { width = 3, color = "#000000" },
    })
    local damageLabel = Kit.CompactTxt("累计伤害 " .. tostring(item.sessionDamage or 0), 26, C.gold, {
        position = "absolute", left = 0, top = 104, width = width, height = 42, textAlign = "center",
        textStroke = { width = 2, color = "#000000" },
    })
    local targetDamage = 2400
    local ratio = math.max(0, math.min(1, (item.sessionDamage or 0) / targetDamage))
    local damageFill = UI.Panel {
        position = "absolute", left = 0, top = 0, width = math.floor(796 * ratio), height = 22,
        backgroundColor = C.gold, pointerEvents = "none",
    }
    local damageTrack = UI.Panel {
        position = "absolute", left = 142, top = 156, width = 796, height = 26,
        backgroundColor = { 8, 20, 40, 255 }, borderWidth = 2, borderColor = { 10, 16, 32, 255 },
        overflow = "hidden", children = { damageFill },
    }
    local tip = Kit.CompactTxt("限时攻击木桩，伤害越高奖励越高", 18, C.textSecondary, {
        position = "absolute", left = 0, top = 196, width = width, height = 32, textAlign = "center",
    })
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
    local count = CombatSequence.Count()
    if count <= 0 then
        currentStrikeAttackFrames_ = STRIKE_ATTACK_FRAMES
        strikeWindup_ = 0.12
        strikeRecovery_ = 0.18
        strikeHitFrame_ = 1
        strikeEndFrame_ = #STRIKE_ATTACK_FRAMES
        strikeAttackTime_ = 0.01
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
    if not strikeRefs_.player then return end
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
        strikeRefs_.player:SetStyle({
            backgroundImage = frames[frame],
            scale = 1.0 + math.max(0, 1 - t / (windup + recovery)) * 0.04,
        })
        strikeRefs_.stump:SetStyle({ scale = 1.0 + math.sin(t * 40) * 0.05 })
        if strikeRefs_.slash then
            local progress = math.max(0, math.min(1, t / windup))
            local playerX = strikeRefs_.playerX or 150
            strikeRefs_.slash:SetStyle({
                visible = progress < 1,
                left = playerX + 300 + progress * 220,
                opacity = (1 - progress) * 0.9,
                scale = 0.7 + progress * 0.8,
            })
        end
        -- 命中帧：触发一次伤害（服务端按玩家属性计算，飘字随权威结算显示）
        if not strikeHitTriggered_ and t >= windup then
            strikeHitTriggered_ = true
            if strikeId_ then ActivityController.Strike(strikeId_) end
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

-- ===== 每帧更新：自动攻击 + 伤害检测 + 倒计时 + 动画 =====
function ActivityView.Update(dt)
    if not strikeId_ then return end
    local game = GameStateAdapter.GetViewState()
    local view = game.activitiesView
    local item = nil
    for _, it in ipairs(view and view.strike or {}) do
        if it.id == strikeId_ then item = it end
    end
    if not item then strikeId_ = nil return end

    -- 攻击动画按放置挂机节奏推进（命中帧内触发一次伤害+飘字）
    UpdateAttack(dt)

    -- 累计伤害同步（伤害条/文字，随服务端权威结算；飘字由活动事件驱动显示实际伤害）
    local damage = item.sessionDamage or 0
    if damage > strikeLastDamage_ then
        strikeLastDamage_ = damage
        if strikeRefs_.damageLabel then strikeRefs_.damageLabel:SetText("累计伤害 " .. tostring(damage)) end
        if strikeRefs_.damageFill then
            local ratio = math.max(0, math.min(1, damage / 2400))
            strikeRefs_.damageFill:SetStyle({ width = math.floor(796 * ratio) })
        end
    end
    UpdateDamageTexts(dt)

    strikeRemaining_ = math.max(0, strikeRemaining_ - (dt or 0))
    if strikeRefs_.countdown then
        strikeRefs_.countdown:SetText(string.format("剩余 %d 秒", math.max(1, math.ceil(strikeRemaining_))))
    end
    if strikeRemaining_ <= 0 then
        local id = strikeId_
        strikeId_ = nil
        strikeRemaining_ = 0
        strikeTimer_ = 0
        strikeAttackTime_ = 0
        currentStrikeAttackFrames_ = nil
        damageLabels_ = {}
        strikeRefs_ = {}
        ActivityController.FinishStrike(id, function()
            -- 打桩结束后强制同步活动状态（次数/会话），确保按钮态正确
            require("client.ServerClient").RequestSnapshot()
        end)
    end
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
            else
                -- 每日补给：三个放同一子页面，竖行排列
                for _, card in ipairs(strikeCards or {}) do
                    children[#children + 1] = card
                end
            end
        end
    end
    return children
end

function ActivityView.BuildPage()
    local view = CurrentView()

    if strikeId_ then
        local active = nil
        for _, item in ipairs(view.strike or {}) do
            if item.id == strikeId_ then active = item end
        end
        if not active then strikeId_ = nil else
            return UI.Panel {
                width = "100%", height = "100%", flexShrink = 0, position = "relative",
                children = {
                    BuildStrikeScene(active),
                    Kit.BackButton {
                        left = 20, top = 20, width = 110, height = 64, fontSize = 24,
                        onClick = function()
                            CommonPromptDialog.Show {
                                kind = "confirm",
                                priority = 1250,
                                queueKey = "strike_exit_confirm",
                                title = "退出打桩",
                                message = "退出后本次打桩次数不返还，确定退出？",
                                lines = { "本次已造成的伤害会按实际结算，次数不会返还。" },
                                closeOnOverlay = false,
                                showClose = false,
                                confirmText = "确认退出",
                                cancelText = "继续打桩",
                                onConfirm = function()
                                    strikeId_ = nil
                                    strikeRemaining_ = 0
                                    strikeTimer_ = 0
                                    strikeAttackTime_ = 0
                                    currentStrikeAttackFrames_ = nil
                                    damageLabels_ = {}
                                    strikeRefs_ = {}
                                    ActivityController.FinishStrike(active.id, function()
                                        require("client.ServerClient").RequestSnapshot()
                                    end)
                                    ActivityController.Refresh()
                                end,
                            }
                        end,
                    },
                },
            }
        end
    end

    local signinCards = {}
    for _, item in ipairs(view.signin or {}) do signinCards[#signinCards + 1] = SigninCard(item) end
    local strikeCards = {}
    for _, item in ipairs(view.strike or {}) do strikeCards[#strikeCards + 1] = StrikeCard(item) end

    return UI.Panel {
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
    }
end

function ActivityView.Reset()
    strikeId_ = nil
    strikeRemaining_ = 0
    strikeTimer_ = 0
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
end

function ActivityView.IsStriking()
    return strikeId_ ~= nil
end

-- 打桩伤害飘字：监听服务端活动事件（权威实际伤害，含暴击）
ServerClient.On("delta", function(payload)
    if not strikeId_ then return end
    for _, event in ipairs((payload and payload.events) or {}) do
        local kind = event.kind or event.type
        if kind == "activity_strike_hit" then
            SpawnDamageText(event.damage or 0)
        end
    end
end)

return ActivityView
