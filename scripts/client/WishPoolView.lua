-- WishPoolView.lua
-- 许愿池界面（与装备页一致的正式背景板）：
--   · 主面板使用 panelLarge 分割素材，无黑色遮罩、无半透明叠层
--   · 中部为正式奖励墙：装备槽卡片排布，覆盖中间可变区域，不超框
--   · 选中光效快速轮换 → 减速 → 停在服务端 stopCell → 放大 → 通用奖励弹窗
--   · 开罐：按开启数量动态生成卷轴行（1~6 行），慢速滚动 → 停下放大 → 通用奖励弹窗

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local GameStateAdapter = require("client.GameStateAdapter")
local ServerClient = require("client.ServerClient")
local WishPoolDefinitions = require("shared.WishPoolDefinitions")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local WishPoolController = require("client.WishPoolController")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local RewardDialogView = require("client.RewardDialogView")
local UIOverlay = require("client.UI.UIOverlay")

local WishPoolView = {}

local C = GameTheme.Colors
local CONFIG = GameTheme.CONFIG
local ASSETS = ViewAssets.ASSETS
local LAYOUT = ViewAssets.LAYOUT

-- BrawlForge 正式配色（不透明）
local SURFACE = { 33, 69, 138, 255 }
local SURFACE_DARK = { 10, 26, 52, 255 }
local SURFACE_BORDER = { 10, 16, 32, 255 }
local PANEL_BORDER = { 50, 196, 255, 160 }

---@type table<string, any>
local refs_ = {}
local mode_ = "main"
local animating_ = false
local animationKind_ = nil
local animationElapsed_ = 0.0
local animationStepElapsed_ = 0.0
local animationStep_ = 0
local animationSteps_ = 0
local zoomElapsed_ = 0.0
local zoomDuration_ = 0.5
local zoomDone_ = false
local selectedCell_ = 1
local selectedVisual_ = 1
local stopCell_ = 1
local waitingResult_ = false
local pendingSkip_ = false
local pendingResult_ = nil
local reelIndex_ = 1
local jarLanes_ = {}
local displayNodes_ = {}
local forceStopCell_ = nil
local requestRefresh_ = nil
local overlayHost_ = UIOverlay
local cover_ = nil
local jarOverlay_ = nil

-- 前向声明：跳过按钮回调，实现在 showJarReward 之后。
local skipAnimation = nil
-- 前向声明：开罐卷轴页构建，实现在许愿池页面构建之后（showJarOverlay 使用）。
local buildReelPage = nil

-- 全屏防点击遮罩层级：高于页面内容，低于通用奖励弹窗。
local COVER_Z_INDEX = 3500
-- 奖励弹窗层级：必须高于全屏遮罩。
local REWARD_Z_INDEX = 3700
-- 转动阶段目标总时长（秒）：步数增减不影响总时长。2 秒转动 + 0.5 秒收尾，尽快出结果。
local WISH_ANIM_SECONDS = 2.0

local function currentGame()
    return GameStateAdapter.GetViewState()
end

local function setText(ref, value)
    if ref then ref:SetText(tostring(value)) end
end

local function rarityColor(rarity)
    if rarity == "myth" then return { 255, 64, 128, 255 } end
    if rarity == "epic" then return { 190, 80, 255, 255 } end
    if rarity == "legendary" then return { 255, 190, 40, 255 } end
    if rarity == "artifact" then return { 244, 114, 182, 255 } end
    return C.focus
end

local function rarityBorderColor(cell)
    if cell.kind == "character" then return { 255, 215, 80, 255 } end
    if cell.rarity then return rarityColor(cell.rarity) end
    if cell.setId then return { 52, 185, 255, 255 } end
    return { 60, 100, 170, 255 }
end

local function middleHeight()
    return math.max(
        520,
        CONFIG.DynamicDesignHeight() - LAYOUT.TOP_ZONE_HEIGHT - LAYOUT.BOTTOM_ZONE_HEIGHT
    )
end

-- 奖励墙：随机抽取约四成罐子，按列排布成正式卡片，严格限制在奖池面板内不超框。
-- 采用「多列少行 + 卡片自适应」策略，任何屏幕高度都能一屏放下。
local function rewardGridLayout()
    local available = middleHeight()
    local panelHeight = math.min(997, math.max(240, available - 310))
    local total = #WishPoolDefinitions.DISPLAY_CELLS
    local desired = math.max(1, math.floor(total * 0.46))
    local width = math.max(900, CONFIG.designWidth - 120)
    local cols = 5
    local gap = 14
    local byWidth = math.floor((width - (cols - 1) * gap) / cols)
    local cell = Kit.Clamp(byWidth, 96, 150)
    local rows = math.max(1, math.floor((panelHeight + gap) / (cell + gap)))
    local count = math.min(desired, cols * rows)
    local gridWidth = cols * cell + (cols - 1) * gap
    local gridHeight = rows * cell + (rows - 1) * gap
    local offsetX = math.max(0, math.floor((width - gridWidth) * 0.5))
    local offsetY = math.max(0, math.floor((panelHeight - gridHeight) * 0.5))

    local order = {}
    for index = 1, total do order[index] = index end
    for index = total, 2, -1 do
        local swapIndex = math.random(1, index)
        order[index], order[swapIndex] = order[swapIndex], order[index]
    end

    local nodes = {}
    for index = 1, count do
        local row = math.floor((index - 1) / cols)
        local column = (index - 1) % cols
        nodes[index] = {
            index = order[index],
            left = offsetX + column * (cell + gap),
            top = offsetY + row * (cell + gap),
        }
    end
    return nodes, cell, width, panelHeight
end

local function actionButton(text, image, onClick, disabled)
    return UI.Panel {
        flexGrow = 1,
        flexBasis = 0,
        height = 88,
        clickable = not disabled,
        opacity = disabled and 0.45 or 1.0,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = image,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        onClick = function()
            if not disabled and onClick then onClick() end
        end,
        children = {
            Kit.CompactTxt(text, 22, C.text, {
                width = "100%",
                height = 88,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            }),
        },
    }
end

-- 动画期间全屏防点击遮罩（含右上角跳过按钮）。
-- 遮罩节点带固定 id，hideCover 支持按 id 全树兜底移除，避免引用丢失导致残留。
local COVER_NODE_ID = "wishPoolAnimationCover"

local function hideJarOverlay()
    if overlayHost_ then
        overlayHost_.Remove("wish.jar")
    elseif jarOverlay_ and jarOverlay_.parent then
        jarOverlay_.parent:RemoveChild(jarOverlay_)
    end
    jarOverlay_ = nil
end

-- 开罐动画全屏 overlay：不切换页面，在当前页之上播放卷轴 + 跳过按钮。
local function showJarOverlay()
    if not overlayHost_ or not overlayHost_.GetRoot() then
        print("[WishPool] showJarOverlay skipped: no overlay host root")
        return
    end
    hideJarOverlay()
    local reel = buildReelPage()
    jarOverlay_ = UI.Panel {
        id = "wishPoolJarOverlay",
        position = "absolute",
        left = 0, top = 0, right = 0, bottom = 0,
        zIndex = 3300,
        clickable = true,
        backgroundColor = { 4, 10, 22, 200 },
        children = {
            reel,
            -- 右上角跳过按钮
            UI.Panel {
                position = "absolute",
                right = 40,
                top = 130,
                width = 140,
                height = 68,
                flexShrink = 0,
                clickable = true,
                backgroundImage = ASSETS.ui.inventoryActionGold,
                backgroundFit = "contain",
                onClick = function() skipAnimation() end,
                children = {
                    Kit.CompactTxt("跳过", 22, C.text, {
                        width = "100%",
                        height = 68,
                        textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                        pointerEvents = "none",
                    }),
                },
            },
        },
    }
    require("client.UI.DialogSettingsAccess").Attach(jarOverlay_)
    overlayHost_.Add("wish.jar", jarOverlay_, { layer = "Blocking" })
end

local function hideCover()
    if overlayHost_ then
        overlayHost_.Remove("wish.cover")
    elseif cover_ and cover_.parent then
        cover_.parent:RemoveChild(cover_)
    end
    cover_ = nil
end

local function showCover()
    if not overlayHost_ or not overlayHost_.GetRoot() then
        print("[WishPool] showCover skipped: no overlay host root")
        return
    end
    hideCover()
    cover_ = UI.Panel {
        id = COVER_NODE_ID,
        position = "absolute",
        left = 0, top = 0, right = 0, bottom = 0,
        zIndex = COVER_Z_INDEX,
        clickable = true,
        backgroundColor = { 4, 10, 22, 70 },
        children = {
            -- 右上角跳过按钮
            UI.Panel {
                position = "absolute",
                right = 40,
                top = 130,
                width = 140,
                height = 68,
                flexShrink = 0,
                clickable = true,
                backgroundImage = ASSETS.ui.inventoryActionGold,
                backgroundFit = "contain",
                onClick = function() skipAnimation() end,
                children = {
                    Kit.CompactTxt("跳过", 22, C.text, {
                        width = "100%",
                        height = 68,
                        textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                        pointerEvents = "none",
                    }),
                },
            },
        },
    }
    overlayHost_.Add("wish.cover", cover_, { layer = "Tooltip" })
end

local function addWishRewardCard(cards, entry)
    if not entry then return end
    if entry.rewardKind == "character" then
        local character = WishPoolDefinitions.CHARACTERS[entry.characterId]
        RewardDialogView.AddCard(
            cards,
            character and character.icon or ASSETS.ui.wishCharMark,
            character and character.name or "完整角色",
            "角色",
            "myth")
        return
    end
    local jar = WishPoolDefinitions.ResolveJar(entry.jarId)
    RewardDialogView.AddCard(
        cards,
        jar and jar.icon or ASSETS.ui.wishJarRandom,
        jar and jar.name or "装备罐",
        "",
        entry.rarity or "legendary")
end

local function showWishReward()
    local result = pendingResult_
    if not result then return end
    local cards = {}
    local draws = type(result.draws) == "table" and result.draws or nil
    if draws and #draws > 0 then
        for _, draw in ipairs(draws) do
            addWishRewardCard(cards, draw)
        end
    else
        addWishRewardCard(cards, result)
    end
    local drawCount = math.max(1, tonumber(result.count) or (draws and #draws) or 1)
    local ticketCost = tonumber(result.ticketCost)
        or (drawCount >= WishPoolDefinitions.MULTI_DRAW_COUNT
            and WishPoolDefinitions.MULTI_TICKET_COST
            or WishPoolDefinitions.SINGLE_TICKET_COST)
    local title = drawCount > 1 and string.format("十连许愿成功 x%d", drawCount) or "许愿成功"
    local message = drawCount > 1
        and string.format("消耗 %d 张许愿券，获得 %d 个奖励（已放入背包）", ticketCost, #cards)
        or "罐子已放入背包，可在背包中开启"
    RewardDialogView.Show {
        title = title,
        message = message,
        cards = cards,
        confirmText = "确认收取",
        zIndex = REWARD_Z_INDEX,
        onConfirm = function()
            hideCover()
            if requestRefresh_ then requestRefresh_() end
        end,
        onCancel = function()
            hideCover()
            if requestRefresh_ then requestRefresh_() end
        end,
    }
end

local function finalIconOf(result)
    if result and result.equipmentId then
        local definition = EquipmentCatalog.Get(result.equipmentId)
        if definition and definition.icon then return definition.icon end
    end
    return ASSETS.items.chest
end

local function showJarReward()
    local result = pendingResult_
    if not result then return end
    local lanes = (result and result.lanes) or {}
    if #lanes == 0 then lanes = { result } end
    local cards = {}
    for _, lane in ipairs(lanes) do
        local definition = lane.equipmentId and EquipmentCatalog.Get(lane.equipmentId) or nil
        RewardDialogView.AddCard(
            cards,
            finalIconOf(lane),
            lane.itemName or "装备",
            lane.level and ("Lv." .. tostring(lane.level)) or "",
            lane.rarity or "legendary",
            definition)
    end
    local summary = #lanes > 1
        and string.format("开启 %d 个装备罐，%d 件装备已放入背包", #lanes, #lanes)
        or ((WishPoolDefinitions.RARITY_NAMES[lanes[1] and lanes[1].rarity] or "") .. "装备已放入背包")
    RewardDialogView.Show {
        title = "装备罐开启",
        message = summary,
        cards = cards,
        confirmText = "确认收取",
        zIndex = REWARD_Z_INDEX,
        onConfirm = function()
            hideCover()
            mode_ = "main"
            pendingResult_ = nil
            if requestRefresh_ then requestRefresh_() end
        end,
    }
end

-- 跳过动画：立即结束并展示通用奖励弹窗，同时关闭全屏防点击遮罩。
-- 若服务端结果尚未到达（预动画阶段），停止转动并保留遮罩锁定，
-- 结果到达后直接展示奖励弹窗，不再重播动画（避免“自动消耗”观感）。
skipAnimation = function()
    if waitingResult_ then
        animationKind_ = nil
        animationStep_ = 0
        animationSteps_ = 0
        zoomDone_ = true
        pendingSkip_ = true
        print("[WishPool] skip while waiting server result")
        return
    end
    hideCover()
    hideJarOverlay()
    animationKind_ = nil
    animating_ = false
    WishPoolController.SetAnimating(false)
    forceStopCell_ = nil
    zoomDone_ = true
    waitingResult_ = false
    if pendingResult_ and pendingResult_.rewardKind then
        showWishReward()
    else
        showJarReward()
    end
    print("[WishPool] skipAnimation done")
end

local function updateSelector(zoomScale)
    zoomScale = zoomScale or 1
    for visualIndex, node in ipairs(displayNodes_) do
        local active = visualIndex == selectedVisual_
        local ref = refs_.cells[visualIndex]
        if ref then
            local scale = node.scale or 1.0
            ref:SetStyle({
                opacity = 1.0,
                scale = active and (scale * zoomScale) or scale,
                zIndex = active and 20 or 1,
            })
        end
        if refs_.cellSelectors[visualIndex] then
            refs_.cellSelectors[visualIndex]:SetStyle({ visible = active })
        end
    end
end

local function selectVisualForCell(logicalIndex)
    for visualIndex, node in ipairs(displayNodes_) do
        if node.index == logicalIndex then
            selectedVisual_ = visualIndex
            return
        end
    end
    selectedVisual_ = 1
end

local function updateCounters()
    local wishPool = currentGame().wishPool or {}
    setText(refs_.ticketVal, tostring(wishPool.tickets or 0))
    setText(refs_.multiCostVal, string.format(
        "%d券/%d抽",
        WishPoolDefinitions.MULTI_TICKET_COST,
        WishPoolDefinitions.MULTI_DRAW_COUNT))
    setText(refs_.mythPityVal, string.format("%d/%d",
        wishPool.mythPity or 0, WishPoolDefinitions.MYTH_HARD_PITY))
    setText(refs_.charPityVal, string.format("%d/%d",
        wishPool.characterPity or 0, WishPoolDefinitions.CHARACTER_HARD_PITY))
end

-- 许愿动画：点击后立即启动（预动画模式，event=nil 时先转起来），
-- 服务端 wish_drawn 事件到达后更新停靠点并让动画停靠放大。
local function startWishAnimation(event)
    if pendingSkip_ then
        -- 用户已在结果到达前跳过：直接展示结果弹窗，不再重播动画
        pendingSkip_ = false
        waitingResult_ = false
        hideCover()
        hideJarOverlay()
        animating_ = false
        WishPoolController.SetAnimating(false)
        forceStopCell_ = nil
        zoomDone_ = true
        pendingResult_ = event
        if event and event.rewardKind then
            showWishReward()
        else
            showJarReward()
        end
        print("[WishPool] result arrived after skip, show reward directly")
        return
    end
    local alreadyRunning = animating_ and animationKind_ == "wish"
    if not alreadyRunning then
        mode_ = "main"
        animating_ = true
        WishPoolController.SetAnimating(true)
        showCover()
        animationKind_ = "wish"
        animationElapsed_ = 0.0
        animationStepElapsed_ = 0.0
        animationStep_ = 0
        zoomElapsed_ = 0.0
        zoomDone_ = false
        waitingResult_ = true
        -- 预动画先转固定步数；结果未到则循环转动，避免动画提前结束
        animationSteps_ = 72
    end
    if event then
        waitingResult_ = false
        stopCell_ = math.max(1, math.min(
            #WishPoolDefinitions.DISPLAY_CELLS,
            tonumber(event.stopCell) or 1))
        pendingResult_ = event
        -- 奖池墙是随机子集：强制重建一版包含服务端停靠格子的墙，保证动画能停在正确奖励上。
        forceStopCell_ = stopCell_
        selectVisualForCell(stopCell_)
        local distance = (stopCell_ - selectedCell_) % #WishPoolDefinitions.DISPLAY_CELLS
        -- 已走步数可能超过新目标：取两者较大值，保证能自然停靠
        animationSteps_ = math.max(animationStep_ + 1, 36 + distance)
        if requestRefresh_ then requestRefresh_() end
    end
    updateSelector()
end

local function startJarAnimation(event)
    mode_ = "jar"
    animating_ = true
    WishPoolController.SetAnimating(true)
    showJarOverlay()
    animationKind_ = "jar"
    animationElapsed_ = 0.0
    animationStepElapsed_ = 0.0
    animationStep_ = 0
    zoomElapsed_ = 0.0
    zoomDone_ = false
    -- 开罐动画：60 步约 2 秒，保持节奏
    animationSteps_ = 60
    reelIndex_ = 1
    jarLanes_ = (event and event.lanes) or {}
    if #jarLanes_ == 0 then
        jarLanes_ = { event }
    end
    pendingResult_ = event
    if requestRefresh_ then requestRefresh_() end
end

local function buildRewardCell(visualIndex, cell, size, node)
    local border = rarityBorderColor(cell)
    local isSelected = visualIndex == selectedVisual_
    local isMajor = cell.kind == "character" or cell.rarity == "myth"
    local iconSize = isMajor
        and math.floor(size * 0.6)
        or math.floor(size * 0.5)
    local labelSize = 24

    local selector = UI.Panel {
        position = "absolute",
        left = -6, top = -6,
        width = size + 12, height = size + 12,
        visible = isSelected,
        borderWidth = 4,
        borderColor = C.focus,
        backgroundColor = { 67, 211, 255, 20 },
        boxShadow = {
            { x = 0, y = 0, blur = 18, color = { 62, 221, 255, 210 } },
            { x = 0, y = 0, blur = 30, color = { 160, 80, 255, 110 } },
        },
        pointerEvents = "none",
    }
    refs_.cellSelectors[visualIndex] = selector

    local cellPanel = UI.Panel {
        width = size,
        height = size,
        flexShrink = 0,
        position = "relative",
        backgroundColor = SURFACE,
        borderWidth = { 2, 2, 4, 2 },
        borderColor = SURFACE_BORDER,
        alignItems = "center",
        justifyContent = "center",
        pointerEvents = "none",
        children = {
            -- 正式装备槽底
            UI.Panel {
                position = "absolute", left = 0, top = 0,
                width = size, height = size,
                backgroundImage = ASSETS.ui.equipSlot,
                backgroundFit = "contain",
                pointerEvents = "none",
            },
            -- 品阶色内边框
            UI.Panel {
                position = "absolute",
                left = 5, top = 5,
                right = 5, bottom = 7,
                borderWidth = 2,
                borderColor = border,
                opacity = 0.9,
                pointerEvents = "none",
            },
            -- 奖励图标
            UI.Panel {
                width = iconSize, height = iconSize,
                backgroundImage = cell.icon,
                backgroundFit = "contain",
                pointerEvents = "none",
            },
            -- 底部名称标签
            UI.Panel {
                position = "absolute", left = 0, bottom = 0,
                width = size, height = labelSize,
                backgroundColor = SURFACE_DARK,
                alignItems = "center", justifyContent = "center",
                pointerEvents = "none",
                children = {
                    Kit.CompactTxt(cell.label or "", 12, C.text, {
                        width = "100%", height = labelSize, textAlign = "center",
                        textStroke = { width = 1, color = "#000000" },
                    }),
                },
            },
            selector,
        },
    }
    refs_.cells[visualIndex] = cellPanel
    return cellPanel
end

local function buildMainPage()
    refs_ = { cells = {}, cellSelectors = {} }
    local wishPool = currentGame().wishPool or {}
    -- 前端不做按钮屏蔽：重复点击由全屏遮罩 + 服务端冷却拒绝
    local tickets = wishPool.tickets or 0
    local singleDisabled = tickets < WishPoolDefinitions.SINGLE_TICKET_COST
    local multiDisabled = tickets < WishPoolDefinitions.MULTI_TICKET_COST

    local wallNodes, cell, wallWidth, wallHeight = rewardGridLayout()
    -- 服务端停靠格必须出现在奖池墙上（替换墙尾一个格子，避免动画停在错误奖励）
    if forceStopCell_ and #wallNodes > 0 then
        local present = false
        for _, node in ipairs(wallNodes) do
            if node.index == forceStopCell_ then present = true break end
        end
        if not present then
            wallNodes[#wallNodes].index = forceStopCell_
        end
    end
    displayNodes_ = wallNodes

    refs_.ticketVal = Kit.CompactTxt("0", 22, C.gold, {
        textStroke = { width = 2, color = "#000000" },
    })
    refs_.multiCostVal = Kit.CompactTxt(
        string.format("%d券/%d抽", WishPoolDefinitions.MULTI_TICKET_COST, WishPoolDefinitions.MULTI_DRAW_COUNT),
        22,
        C.mp,
        { textStroke = { width = 2, color = "#000000" } }
    )
    refs_.mythPityVal = Kit.CompactTxt("0/120", 22, { 255, 64, 128, 255 }, {
        textStroke = { width = 2, color = "#000000" },
    })
    refs_.charPityVal = Kit.CompactTxt("0/400", 22, { 255, 215, 80, 255 }, {
        textStroke = { width = 2, color = "#000000" },
    })

    local function statCell(icon, label, valueRef, offset)
        offset = offset or {}
        valueRef:SetStyle({ pointerEvents = "none" })
        return UI.Panel {
            clickable = label == "许愿券",
            onClick = label == "许愿券" and function() require("client.ResourceTips").Show("wish_ticket") end or nil,
            flexGrow = 1,
            flexBasis = 0,
            height = 62,
            left = offset.left,
            top = offset.top,
            alignItems = "center",
            justifyContent = "center",
            gap = 2,
            children = {
                UI.Panel {
                    flexDirection = "row",
                    pointerEvents = "none",
                    alignItems = "center",
                    justifyContent = "center",
                    gap = 6,
                    children = {
                        UI.Panel {
                            width = 30, height = 30,
                            backgroundImage = icon,
                            backgroundFit = "contain",
                            pointerEvents = "none",
                        },
                        Kit.CompactTxt(label, 15, C.textSecondary, {
                            textStroke = { width = 1, color = "#000000" },
                        }),
                    },
                },
                valueRef,
            },
        }
    end

    local infoPanel = UI.Panel {
        width = "100%",
        height = 88,
        flexShrink = 0,
        flexDirection = "row",
        gap = 8,
        paddingLeft = 10,
        paddingRight = 10,
        backgroundColor = SURFACE,
        borderWidth = { 2, 2, 4, 2 },
        borderColor = SURFACE_BORDER,
        children = {
            statCell(ASSETS.ui.wishTicket, "许愿券", refs_.ticketVal, { left = 13, top = 13 }),
            statCell(ASSETS.ui.wishJarRandom, "十连优惠", refs_.multiCostVal, { left = 2, top = 15 }),
            statCell(ASSETS.ui.wishJarMyth, "神话保底", refs_.mythPityVal, { left = 9, top = 13 }),
            statCell(ASSETS.ui.wishCharMark, "角色保底", refs_.charPityVal, { left = -13, top = 11 }),
        },
    }

    -- 正式奖励墙：装备槽卡片，不透明、无遮罩，严格限制在面板内。
    ---@type any[]
    local wallChildren = {}
    for visualIndex, node in ipairs(wallNodes) do
        local entry = WishPoolDefinitions.DISPLAY_CELLS[node.index]
        local panel = buildRewardCell(visualIndex, entry, cell, node)
        panel:SetStyle({
            position = "absolute",
            left = node.left,
            top = node.top,
        })
        wallChildren[#wallChildren + 1] = panel
    end

    updateCounters()
    updateSelector()

    return UI.Panel {
        width = "100%",
        height = "100%",
        position = "relative",
        children = {
            UI.Panel {
                width = "100%",
                height = "100%",
                paddingLeft = 24,
                paddingRight = 24,
                paddingTop = 10,
                paddingBottom = 14,
                gap = 10,
                children = {
                    -- 标题行
                    UI.Panel {
                        width = "100%",
                        height = 64,
                        flexShrink = 0,
                        position = "relative",
                        children = {
                            Kit.BackButton {
                                onClick = function()
                                    require("client.NavigationController").SwitchPage("home")
                                end,
                            },
                            Kit.Txt("许 愿 池", 34, C.text, {
                                position = "absolute", left = 0, top = 8,
                                width = 1000, height = 48, textAlign = "center",
                                textStroke = { width = 4, color = "#000000" },
                            }),
                        },
                    },
                    infoPanel,
                    -- 主面板：与装备页一致的正式背景板
                    UI.Panel {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 1166,
                        top = -2,
                        overflow = "hidden",
                        position = "relative",
                        backgroundImage = ASSETS.ui.panelLarge,
                        backgroundFit = "sliced",
                        backgroundSlice = { 12, 12, 12, 12 },
                        alignItems = "center",
                        justifyContent = "center",
                        children = {
                            UI.Panel {
                                position = "absolute",
                                left = 12, top = 12,
                                right = 12, bottom = 14,
                                borderWidth = 2,
                                borderColor = PANEL_BORDER,
                                pointerEvents = "none",
                            },
                            UI.Panel {
                                width = wallWidth,
                                height = wallHeight,
                                left = -7,
                                top = -3,
                                flexShrink = 0,
                                position = "relative",
                                overflow = "hidden",
                                children = wallChildren,
                            },
                        },
                    },
                    -- 操作按钮：单抽 1 券 / 十连 8 券（不再支持广告许愿）
                    UI.Panel {
                        width = "100%",
                        height = 88,
                        flexShrink = 0,
                        flexDirection = "row",
                        gap = 16,
                        children = {
                            actionButton(
                                "单次许愿 x1",
                                ASSETS.ui.inventoryActionBlue,
                                function() WishPoolController.WishWithTicket() end,
                                singleDisabled),
                            actionButton(
                                string.format("十连许愿 x%d（%d券）",
                                    WishPoolDefinitions.MULTI_DRAW_COUNT,
                                    WishPoolDefinitions.MULTI_TICKET_COST),
                                ASSETS.ui.inventoryActionGold,
                                function() WishPoolController.WishTen() end,
                                multiDisabled),
                        },
                    },
                },
            },
        },
    }
end

-- 开罐卷轴按行（lane）使用对应部位的真实装备图标池滚动。
local function reelIconsForSlot(slot)
    local pool = {}
    for _, definition in ipairs(EquipmentCatalog.GetBySlot(slot or "weapon")) do
        pool[#pool + 1] = definition.icon
    end
    if #pool == 0 then pool[1] = ASSETS.items.chest end
    local icons = {}
    for index = 1, 15 do
        icons[index] = pool[((index - 1) % #pool) + 1]
    end
    return icons
end

buildReelPage = function()
    refs_ = { cells = {}, cellSelectors = {}, reelItems = {} }
    local lanes = jarLanes_
    local laneCount = math.max(1, math.min(6, #lanes))

    ---@type any[]
    local lanePanels = {}
    local centerRefs = {}
    for lane = 1, laneCount do
        local laneResult = lanes[lane] or {}
        local icons = reelIconsForSlot(laneResult.slot)
        ---@type any[]
        local iconChildren = {}
        for column = 1, 5 do
            local iconIndex = ((reelIndex_ + column + lane * 3 - 3) % #icons) + 1
            local isCenter = column == 3
            local panel = UI.Panel {
                width = 116,
                height = 96,
                flexShrink = 0,
                backgroundImage = icons[iconIndex],
                backgroundFit = "contain",
                opacity = isCenter and 1.0 or 0.5,
                scale = isCenter and 1.05 or 0.85,
                pointerEvents = "none",
            }
            refs_.reelItems[#refs_.reelItems + 1] = {
                node = panel, lane = lane, column = column, icons = icons,
            }
            if isCenter then centerRefs[#centerRefs + 1] = panel end
            iconChildren[#iconChildren + 1] = panel
        end

        lanePanels[#lanePanels + 1] = UI.Panel {
            width = "100%",
            height = 118,
            flexShrink = 0,
            backgroundColor = SURFACE,
            borderWidth = { 2, 2, 4, 2 },
            borderColor = SURFACE_BORDER,
            alignItems = "center",
            justifyContent = "center",
            children = {
                UI.Panel {
                    flexDirection = "row",
                    gap = 10,
                    alignItems = "center",
                    justifyContent = "center",
                    children = {
                        iconChildren[1],
                        iconChildren[2],
                        UI.Panel {
                            width = 128,
                            height = 110,
                            flexShrink = 0,
                            borderWidth = 4,
                            borderColor = C.focus,
                            backgroundColor = { 67, 211, 255, 20 },
                            alignItems = "center",
                            justifyContent = "center",
                            children = { iconChildren[3] },
                        },
                        iconChildren[4],
                        iconChildren[5],
                    },
                },
            },
        }
    end
    refs_.centerRefs = centerRefs

    ---@type any[]
    local bodyChildren = {
        UI.Panel {
            width = "100%",
            height = 64,
            flexShrink = 0,
            position = "relative",
            children = {
                Kit.Txt("装备罐开启", 32, C.text, {
                    position = "absolute", left = 0, top = 8,
                    width = 1000, height = 48, textAlign = "center",
                    textStroke = { width = 4, color = "#000000" },
                }),
            },
        },
        UI.Panel {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
            position = "relative",
            backgroundImage = ASSETS.ui.panelLarge,
            backgroundFit = "sliced",
            backgroundSlice = { 12, 12, 12, 12 },
            alignItems = "center",
            justifyContent = "center",
            children = {
                UI.Panel {
                    position = "absolute",
                    left = 12, top = 12,
                    right = 12, bottom = 14,
                    borderWidth = 2,
                    borderColor = PANEL_BORDER,
                    pointerEvents = "none",
                },
                UI.Panel {
                    width = "100%",
                    gap = 12,
                    paddingLeft = 20,
                    paddingRight = 20,
                    justifyContent = "center",
                    children = lanePanels,
                },
            },
        },
    }

    return UI.Panel {
        width = "100%",
        height = "100%",
        position = "relative",
        children = {
            UI.Panel {
                width = "100%",
                height = "100%",
                paddingLeft = 24,
                paddingRight = 24,
                paddingTop = 10,
                paddingBottom = 14,
                gap = 10,
                children = bodyChildren,
            },
        },
    }
end

function WishPoolView.BuildPage()
    if mode_ == "jar" then return buildReelPage() end
    return buildMainPage()
end

function WishPoolView.HandleJarOpened(event)
    startJarAnimation(event)
end

local function updateZoom(scale)
    if animationKind_ == "wish" then
        updateSelector(scale)
    else
        for _, ref in ipairs(refs_.centerRefs or {}) do
            if ref then ref:SetStyle({ scale = 1 + (scale - 1) * 1.3 }) end
        end
    end
end

function WishPoolView.Update(dt)
    if not animating_ then return end
    dt = math.max(0, tonumber(dt) or 0)
    animationElapsed_ = animationElapsed_ + dt

    -- 看门狗：动画异常卡住（如页面切换导致 Update 中断）时强制结束并清理遮罩，
    -- 避免全屏防点击遮罩永久残留阻挡操作。
    if animationElapsed_ > 30 then
        hideCover()
        hideJarOverlay()
        animationKind_ = nil
        animating_ = false
        WishPoolController.SetAnimating(false)
        forceStopCell_ = nil
        zoomDone_ = true
        pendingResult_ = nil
        print("[WishPool] animation watchdog forced stop")
        if requestRefresh_ then requestRefresh_() end
        return
    end

    -- 放大收尾阶段
    if animationKind_ == "zoom" then
        zoomElapsed_ = zoomElapsed_ + dt
        local progress = math.min(1, zoomElapsed_ / zoomDuration_)
        local scale = 1 + 0.32 * math.sin(math.pi * progress)
        updateZoom(scale)
        if progress >= 1 then
            animationKind_ = nil
            animating_ = false
            WishPoolController.SetAnimating(false)
            hideCover()
            hideJarOverlay()
            if not zoomDone_ then
                zoomDone_ = true
                if pendingResult_ and pendingResult_.rewardKind then
                    showWishReward()
                else
                    showJarReward()
                end
            end
        end
        return
    end

    animationStepElapsed_ = animationStepElapsed_ + dt

    local progress = animationSteps_ > 0
        and animationStep_ / animationSteps_ or 1
    -- 转动阶段总时长恒定约 3 秒：步数增加时自动缩小单步间隔（变速：结尾渐慢停下）。
    -- 配合收尾 zoom（0.7s），许愿/开罐整体约 3.7 秒。
    local interval = (WISH_ANIM_SECONDS / animationSteps_) * (0.5 + progress)

    if animationStepElapsed_ < interval then
        if animationKind_ == "wish" then updateSelector() end
        return
    end
    animationStepElapsed_ = animationStepElapsed_ - interval
    animationStep_ = animationStep_ + 1

    if animationKind_ == "wish" then
        selectedCell_ = selectedCell_ % #WishPoolDefinitions.DISPLAY_CELLS + 1
        selectVisualForCell(selectedCell_)
        if animationStep_ >= animationSteps_ then
            if waitingResult_ then
                -- 服务端结果未到（预动画阶段）：继续循环转动，等待结果修正停靠点
                animationStep_ = 0
                animationStepElapsed_ = 0.0
            else
                selectedCell_ = stopCell_
                forceStopCell_ = nil
                selectVisualForCell(stopCell_)
                updateSelector()
                animationKind_ = "zoom"
                zoomElapsed_ = 0.0
            end
        else
            updateSelector()
        end
    elseif animationKind_ == "jar" then
        reelIndex_ = reelIndex_ % 15 + 1
        for _, item in ipairs(refs_.reelItems or {}) do
            local iconIndex = ((reelIndex_ + item.column + item.lane * 3 - 3)
                % #item.icons) + 1
            item.node:SetStyle({ backgroundImage = item.icons[iconIndex] })
        end
        if animationStep_ >= animationSteps_ then
            for index, ref in ipairs(refs_.centerRefs or {}) do
                local laneResult = jarLanes_[index]
                if ref then
                    ref:SetStyle({ backgroundImage = finalIconOf(laneResult) })
                end
            end
            animationKind_ = "zoom"
            zoomElapsed_ = 0.0
        end
    end
end

function WishPoolView.IsAnimating()
    return animating_
end

function WishPoolView.ReattachOverlay()
    if not animating_ then return end
    if animationKind_ == "jar" then
        showJarOverlay()
    else
        showCover()
    end
end

-- 点击许愿后立即启动动画（乐观预动画），服务端结果到达后由 wish_drawn 事件修正停靠点。
function WishPoolView.StartPendingWish()
    if animating_ then return false end
    startWishAnimation(nil)
    return true
end

-- 取消动画（请求失败等场景）：关闭遮罩、复位动画锁，不弹奖励。
function WishPoolView.CancelAnimation()
    if not animating_ then return end
    hideCover()
    hideJarOverlay()
    animationKind_ = nil
    animating_ = false
    WishPoolController.SetAnimating(false)
    forceStopCell_ = nil
    zoomDone_ = true
    waitingResult_ = false
    pendingSkip_ = false
    pendingResult_ = nil
    if requestRefresh_ then requestRefresh_() end
end

function WishPoolView.Configure(context)
    context = context or {}
    requestRefresh_ = context.requestPageRefresh
    overlayHost_ = context.overlayHost or UIOverlay
end

function WishPoolView.Reset()
    WishPoolController.SetAnimating(false)
    hideCover()
    hideJarOverlay()
    refs_ = {}
    mode_ = "main"
    animating_ = false
    animationKind_ = nil
    animationElapsed_ = 0.0
    animationStepElapsed_ = 0.0
    animationStep_ = 0
    animationSteps_ = 0
    zoomElapsed_ = 0.0
    zoomDone_ = false
    selectedCell_ = 1
    selectedVisual_ = 1
    stopCell_ = 1
    waitingResult_ = false
    pendingSkip_ = false
    pendingResult_ = nil
    reelIndex_ = 1
    jarLanes_ = {}
    displayNodes_ = {}
    forceStopCell_ = nil
    requestRefresh_ = nil
    overlayHost_ = UIOverlay
end

ServerClient.On("delta", function(payload)
    for _, event in ipairs((payload and payload.events) or {}) do
        local kind = event.kind or event.type
        if kind == "wish_drawn" then startWishAnimation(event) end
        if kind == "wish_jar_opened" then startJarAnimation(event) end
    end
end)

return WishPoolView
