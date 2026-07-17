local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local AdminPanel = require("client.AdminPanel")

local CONFIG = GameTheme.CONFIG
local C = GameTheme.Colors
local AppTheme = GameTheme.Theme
local RARITIES = GameTheme.Rarities
local CATEGORIES = GameTheme.Categories
local SLOTS = GameTheme.Slots
local SET_ORDER = GameTheme.SetOrder
local SETS = GameTheme.Sets
local EVENT_INFO = GameTheme.EventInfo

local GameView = {}
local game = GameStateAdapter.GetViewState()
local uiRoot_ = nil
local pageContainer_ = nil
local needsFullRebuild_ = false
local needsPageRefresh_ = false
local safeAreaInstalled_ = false
local selectedInventoryId_ = nil
local selectedSlot_ = "weapon"
local selectedCategory_ = "weapon"
local topRefs_ = {}
local navRefs_ = {}
---@type table<string, any>
local playRefs_ = {}
local loadingDots_ = {}
local loadingPercentLabel_ = nil
local loadingMessageLabel_ = nil
local loadingProgressBar_ = nil
local loadingActive_ = false
local loadingOverlay_ = nil
local playAssetsReady_ = false
local playAssetLoading_ = false
local textureCache_ = {}
local pendingAutoRun_ = nil
local dwpObserverId_ = nil
local loadingHideDelay_ = nil
local loadingProgress_ = 0
local loadingMessage_ = "正在加载像素字体"
local loadingTimer_ = 0
local SetLoading = nil
local ShowLoadingOverlay = nil
local EnsurePlayAssetsReady = nil
---@type number
local animationTime_ = 0
---@type number
local presentationX_ = 0
local nextEventId_ = 1
local roadEvents_ = {}
---@type number
local combatTimer_ = 0
---@type number
local combatAnimationTime_ = 0
local currentEventLocked_ = false
local currentAttackFrames_ = nil
local lastAttackSetIndex_ = nil
local pickupFx_ = nil
local currentPlayerImage_ = nil
local floatingText_ = nil
local enemyDamageBursts_ = {}
local frameEditorRefs_ = {}
local frameEditorSelected_ = "run"
local frameEditorPaused_ = false
local frameEditorVisible_ = { run = true, attackA = false, attackB = false, attackC = false }
local frameEditorOrder_ = { "run", "attackA", "attackB", "attackC" }
---@class FrameEditorParam
---@field x number
---@field y number
---@field w number
---@field h number
---@field fps number
---@field scale number
---@type table<string, FrameEditorParam>
local frameEditorParams_ = {}
local lastEventType_ = game.currentEvent or "monster"
local lastLootText_ = "等待掉落"
local lastLootIcon_ = nil
local hitBurst_ = false

local function BuildFrames(path, count)
    local frames = {}
    for i = 1, count do
        frames[#frames + 1] = string.format("%s/%02d.png", path, i)
    end
    return frames
end

local ASSETS = {
    bg = "image/brawlforge_play_battle_bg_20260716014006.png",
    bgMirror = "image/brawlforge_play_battle_bg_20260716014006_mirror.png",
    player = {
        icon = "image/brawlforge_job_spear_from_sprites_transparent_20260716102831.png",
        sprite = "image/endless_corridor/runner/frames/player_run/01.png",
        attack = "image/endless_corridor/runner/frames/player_attack/01.png",
        idle = { "image/endless_corridor/runner/frames/player_run/01.png" },
        run = BuildFrames("image/endless_corridor/runner/frames/player_run", 16),
        attackFrameSets = {
            BuildFrames("image/endless_corridor/runner/frames/player_attack_a", 48),
            BuildFrames("image/endless_corridor/runner/frames/player_attack_b", 48),
            BuildFrames("image/endless_corridor/runner/frames/player_attack_c", 48),
        },
    },
    ui = {
        bg = "image/ui/brawlforge_bg_abyss_corridor.png",
        topFrame = "image/ui/brawlforge_v7_top_refstyle_clean.png",
        heroPanel = "image/ui/brawlforge_home_hero_panel.png",
        statCard = "image/ui/brawlforge_stat_card_frame.png",
        button = "image/ui/brawlforge_v3_action_button.png",
        bottomNav = "image/ui/brawlforge_v3_bottom_nav_bar.png",
        navSelected = "image/ui/brawlforge_v3_nav_button.png",
        statAtk = "image/ui/brawlforge_stat_atk.png",
        statDef = "image/ui/brawlforge_stat_def.png",
        statCrit = "image/ui/brawlforge_stat_crit.png",
        statSpeed = "image/ui/brawlforge_stat_speed.png",
        statHp = "image/ui/brawlforge_stat_hp.png",
        statPower = "image/ui/brawlforge_stat_power.png",
    },
    enemies = {
        slime = "image/brawlforge_enemy_slime_20260716014018.png",
        goblin = "image/brawlforge_enemy_goblin_20260716014019.png",
        skeleton = "image/brawlforge_enemy_skeleton_20260716014006.png",
        boss = "image/brawlforge_enemy_boss_20260716014007.png",
    },
    items = {
        sword = "image/pixel_item_sword_20260713175812.png",
        armor = "image/pixel_item_armor_20260713175625.png",
        ring = "image/pixel_item_ring_20260713175624.png",
        boots = "image/pixel_item_boots_20260713175628.png",
        amulet = "image/pixel_item_amulet_20260713175651.png",
        chest = "image/pixel_item_chest_20260713175627.png",
        gold = "image/pixel_item_gold_20260713175638.png",
        potion = "image/pixel_item_potion_20260713175813.png",
        crystal = "image/pixel_item_crystal_20260713175626.png",
    },
}

local PLAYER_SIZE = 210
local RUN_W = 420
local RUN_H = 210
local RUN_FPS = 10
local ATTACK_FPS = 16
local ATTACK_DURATION = 3.0
local ATTACK_HIT_TIMINGS = {0.18, 0.38, 0.58, 0.78, 0.93}
local ATTACK_W = RUN_W
local ATTACK_H = RUN_H
local ENEMY_SIZE = 150
local LOOT_SIZE = 96
local PLAYER_SCREEN_X = 260
local BG_TILE_W = 980
local BG_TILE_TOP = 150
local ROAD_Y = 790
local PLATFORM_PLAYER_Y = ROAD_Y - PLAYER_SIZE + 20
local EVENT_SPACING = 420
local EVENT_TRIGGER_DISTANCE = 120
local EVENT_VIEW_COUNT = 8
local PRESENTATION_SPEED = 96
local MIN_FONT_SIZE = 24

frameEditorParams_ = {
    run = { x = 0, y = -5, w = RUN_W, h = RUN_H, fps = RUN_FPS, scale = 1.1 },
    attackA = { x = 150, y = -45, w = RUN_W, h = RUN_H, fps = ATTACK_FPS, scale = 1.7 },
    attackB = { x = 30, y = -45, w = RUN_W, h = RUN_H, fps = ATTACK_FPS, scale = 1.4 },
    attackC = { x = 135, y = -20, w = RUN_W, h = RUN_H, fps = ATTACK_FPS, scale = 1.7 },
}

local function CurrentPlayer()
    return ASSETS.player
end

local function FrameAt(frames, fps, time)
    if not frames or #frames == 0 then return CurrentPlayer().icon end
    local idx = math.floor((time or animationTime_) * (fps or 8)) % #frames + 1
    return frames[idx]
end

local function CopyProps(base, extra)
    local t = {}
    if base then for k, v in pairs(base) do t[k] = v end end
    if extra then for k, v in pairs(extra) do t[k] = v end end
    return t
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function FontSize(size)
    return math.max(MIN_FONT_SIZE, size or MIN_FONT_SIZE)
end

local function Txt(text, size, color, props)
    return UI.Label(CopyProps({
        text = text,
        fontSize = FontSize(size),
        fontWeight = "bold",
        fontColor = color or C.text,
        whiteSpace = "nowrap",
    }, props))
end

local function MultiTxt(text, size, color, props)
    return UI.Label(CopyProps({
        text = text,
        fontSize = FontSize(size),
        fontWeight = "bold",
        fontColor = color or C.textSecondary,
        width = "100%",
        whiteSpace = "normal",
        wordBreak = "break-word",
        lineHeight = 1.25,
    }, props))
end

local function FormatInt(v)
    v = math.floor(v or 0)
    if v >= 100000000 then return string.format("%.1f亿", v / 100000000) end
    if v >= 10000 then return string.format("%.1f万", v / 10000) end
    return tostring(v)
end

local function FormatPercent(v)
    return string.format("%.1f%%", (v or 0) * 100)
end

local function PixelPanel(props)
    return UI.Panel(CopyProps({
        backgroundColor = C.surface,
        borderWidth = 4,
        borderColor = C.border,
        padding = 20,
        gap = 12,
        overflow = "hidden",
    }, props))
end

local function PixelChip(label, value, color, valueRef)
    local valueLabel = valueRef or Txt(value, 24, color or C.text, {})
    return UI.Panel {
        height = 68,
        paddingLeft = 14,
        paddingRight = 14,
        flexDirection = "row",
        alignItems = "center",
        gap = 8,
        backgroundColor = C.surfaceDark,
        borderWidth = 3,
        borderColor = color or C.border,
        children = {
            Txt(label, 24, C.textDim),
            valueLabel,
        }
    }
end

local function StatBox(label, value, color, icon)
    local children = {}
    if icon then
        children[#children + 1] = UI.Panel { width = 54, height = 54, backgroundImage = icon, backgroundFit = "contain", flexShrink = 0 }
    end
    children[#children + 1] = UI.Panel {
        flexGrow = 1,
        flexBasis = 0,
        flexShrink = 1,
        children = {
            Txt(label, 24, C.textDim, { width = "100%" }),
            Txt(value, 26, color or C.text, { width = "100%" }),
        }
    }
    return UI.Panel {
        width = 310,
        height = 96,
        flexDirection = "row",
        alignItems = "center",
        gap = 10,
        padding = 12,
        backgroundColor = C.surfaceDark,
        borderWidth = 3,
        borderColor = color or C.border,
        children = children,
    }
end

local function SectionTitle(title, sub)
    return UI.Panel {
        width = "100%",
        gap = 4,
        children = {
            Txt(title, 28, C.text, { width = "100%", textStroke = { width = 2, color = "#000000" } }),
            sub and Txt(sub, 24, C.textSecondary, { width = "100%" }) or nil,
        }
    }
end

local function RarityColor(rarity)
    return (RARITIES[rarity] and RARITIES[rarity].color) or C.textSecondary
end

local function RarityName(rarity)
    return (RARITIES[rarity] and RARITIES[rarity].name) or "未知"
end

local function SlotById(id)
    for _, slot in ipairs(SLOTS) do
        if slot.id == id then return slot end
    end
    return nil
end

local function SlotName(id)
    local slot = SlotById(id)
    return slot and slot.name or id
end

local function ItemPower(item)
    if item.power then return item.power end
    if item.category == "material" or item.category == "consumable" then return item.quantity or 1 end
    local rarity = RARITIES[item.rarity] or RARITIES.common
    local atk = item.atk or 0
    local def = item.def or 0
    local hp = item.hp or 0
    local crit = item.crit or 0
    local critDmg = item.critDmg or 0
    local atkSpeed = item.atkSpeed or 0
    return math.floor((atk * 7 + def * 3 + hp * 0.55 + crit * 2000 + critDmg * 900 + atkSpeed * 650) * rarity.mult)
end

local function GetItemById(id)
    if id == nil then return nil end
    for _, item in ipairs(game.inventory or {}) do
        if tostring(item.id) == tostring(id) then return item end
    end
    return nil
end

local function IsEquipped(item)
    if not item then return false end
    for _, equipped in pairs(game.equipped or {}) do
        if equipped and tostring(equipped.id) == tostring(item.id) then return true end
    end
    return false
end

local function ItemImage(item)
    if not item then return ASSETS.items.chest end
    if item.category == "consumable" then return ASSETS.items.potion end
    if item.category == "material" then return ASSETS.items.crystal end
    local slot = item.slot or ""
    if slot == "weapon" then return ASSETS.items.sword end
    if slot == "shoes" then return ASSETS.items.boots end
    if slot == "ring" or slot == "bracelet" or slot == "necklace" then return ASSETS.items.ring end
    if slot == "support" or slot == "magicstone" or slot == "earring" then return ASSETS.items.amulet end
    if item.category == "armor" then return ASSETS.items.armor end
    if item.category == "weapon" then return ASSETS.items.sword end
    if item.category == "jewelry" then return ASSETS.items.ring end
    if item.category == "special" then return ASSETS.items.amulet end
    return ASSETS.items.chest
end

local function EnemyImageForStep(step, eventType)
    if eventType == "boss" then return ASSETS.enemies.boss end
    if eventType == "elite" then return ASSETS.enemies.skeleton end
    local value = step % 3
    if value == 0 then return ASSETS.enemies.slime end
    if value == 1 then return ASSETS.enemies.goblin end
    return ASSETS.enemies.skeleton
end

local function EventIcon(eventType)
    if eventType == "chest" then return ASSETS.items.chest end
    if eventType == "merchant" then return ASSETS.items.gold end
    if eventType == "random" then return ASSETS.items.crystal end
    return nil
end

local function IsCombatEvent(eventType)
    return eventType == "monster" or eventType == "elite" or eventType == "boss"
end

local function DeterministicEventType(index)
    local value = (index * 73 + (game.floor or 1) * 29) % 100
    if value < 58 then return "monster" end
    if value < 70 then return "elite" end
    if value < 82 then return "chest" end
    if value < 90 then return "random" end
    if value < 96 then return "merchant" end
    return "boss"
end

local function MakeRoadEvent(index)
    local eventType = DeterministicEventType(index)
    local isEnemy = IsCombatEvent(eventType)
    return {
        id = index,
        x = 820 + (index - 1) * EVENT_SPACING,
        kind = isEnemy and "enemy" or "loot",
        eventType = eventType,
        image = isEnemy and EnemyImageForStep(index, eventType) or (EventIcon(eventType) or ASSETS.items.crystal),
    }
end

local function EnsureRoadEvents()
    while #roadEvents_ < EVENT_VIEW_COUNT do
        roadEvents_[#roadEvents_ + 1] = MakeRoadEvent(nextEventId_)
        nextEventId_ = nextEventId_ + 1
    end
end

local function AdvanceRoadEvent()
    table.remove(roadEvents_, 1)
    roadEvents_[#roadEvents_ + 1] = MakeRoadEvent(nextEventId_)
    nextEventId_ = nextEventId_ + 1
    currentEventLocked_ = false
    currentAttackFrames_ = nil
end

local function RequestPageRefresh()
    needsPageRefresh_ = true
end

local function RequestFullRebuild()
    needsFullRebuild_ = true
end

local function ActionResult(response)
    if response and response.ok then return end
    UI.Toast.Show((response and response.reason) or "服务器未接受本次操作", { duration = 2, variant = "error", position = "bottom" })
end

local function SetAutoRun(enabled)
    if enabled then
        pendingAutoRun_ = true
        EnsurePlayAssetsReady(function()
            pendingAutoRun_ = nil
            ServerClient.AutoRun(true, ActionResult)
        end)
    else
        pendingAutoRun_ = nil
        ServerClient.AutoRun(false, ActionResult)
    end
end
local function CollectOffline() ServerClient.CollectOffline(ActionResult) end
local function EquipItem(item)
    if item and item.id then
        selectedSlot_ = item.slot or selectedSlot_
        ServerClient.Equip(item.id, ActionResult)
    end
end
local function AutoEquipBest() ServerClient.AutoEquip(ActionResult) end
local function DecomposeByRank(maxRank) ServerClient.Decompose(maxRank, ActionResult) end
local function StrengthenSelected() ServerClient.Strengthen(selectedSlot_, ActionResult) end
local function StarSelected() ServerClient.Star(selectedSlot_, ActionResult) end

local function CurrentRunStatus()
    local status = game.autoRun and "刷宝中" or "暂停"
    local color = game.autoRun and C.success or C.warning
    if game.connectionState == "syncing" then status, color = "同步", C.mp end
    if game.connectionState == "disconnected" then status, color = "断线", C.error end
    if game.readOnly then status, color = "只读", C.warning end
    return status, color
end

local UpdatePlayVisuals
local RefreshCurrentPage
local SwitchPage
local UpdateTopBar
local UpdateBottomNav
local UpdateFrameEditorVisuals

UpdateTopBar = function()
    if not topRefs_ then return end
    game = GameStateAdapter.GetViewState()
    if topRefs_.floor then topRefs_.floor:SetText("层  第" .. tostring(game.floor or 1) .. "层") end
    if topRefs_.power then topRefs_.power:SetText("战力  " .. FormatInt(game.stats and game.stats.power or 0)) end
    if topRefs_.gold then topRefs_.gold:SetText("金币  " .. FormatInt(game.gold or 0)) end
    if topRefs_.fragments then topRefs_.fragments:SetText("碎片  " .. FormatInt(game.fragments or 0)) end
end

local function CreateTopBar()
    topRefs_.floor = Txt("层  第" .. tostring(game.floor or 1) .. "层", 24, C.focus, { whiteSpace = "nowrap", width = 220, height = 56, minHeight = 45, left = -18, top = -13, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    topRefs_.power = Txt("战力  " .. FormatInt(game.stats.power), 24, C.gold, { whiteSpace = "nowrap", width = 235, height = 56, minHeight = 45, top = -15, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    topRefs_.gold = Txt("金币  " .. FormatInt(game.gold), 24, C.gold, { whiteSpace = "nowrap", width = 220, height = 56, minHeight = 45, left = -2, top = -15, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    topRefs_.fragments = Txt("碎片  " .. FormatInt(game.fragments), 24, C.secondary, { whiteSpace = "nowrap", width = 220, height = 56, minHeight = 45, left = 15, top = -13, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    local function ResourceText(x, valueRef)
        return UI.Panel {
            position = "absolute",
            left = x,
            top = 232,
            width = 230,
            height = 60,
            alignItems = "center",
            justifyContent = "center",
            overflow = "visible",
            children = { valueRef }
        }
    end

    return UI.Panel {
        width = "100%",
        height = 330,
        flexShrink = 0,
        position = "relative",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 14,
                width = 1080,
                height = 300,
                backgroundImage = ASSETS.ui.topFrame,
                backgroundFit = "contain",
            },
            Txt("无尽深渊", 30, C.text, {
                position = "absolute",
                left = 96,
                top = 90,
                width = 220,
                height = 56,
                whiteSpace = "nowrap",
                textAlign = "center",
                textStroke = { width = 3, color = "#000000" },
            }),
            Txt("解放双手，自动推进探索", 21, C.textSecondary, {
                position = "absolute",
                left = 412,
                top = 104,
                width = 550,
                height = 48,
                whiteSpace = "nowrap",
                textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
            }),
            ResourceText(76, topRefs_.floor),
            ResourceText(300, topRefs_.power),
            ResourceText(540, topRefs_.gold),
            ResourceText(780, topRefs_.fragments),
        }
    }
end

local function ProbeOptionalFonts()
    local paths = {
        "Fonts/FusionPixel-12px-Prop-zh_hans.ttf",
        "Fonts/FusionPixel-12px-Prop-zh_hans-Bold.ttf",
        "Fonts/FusionPixel-12px-Mono-zh_hans.ttf",
        "Fonts/NotoSansSC-Black.ttf",
    }
    print("[FontP0] UI theme uses built-in/default font fallback; optional custom fonts are probe-only.")
    for _, path in ipairs(paths) do
        local ok, font = pcall(function()
            return cache:GetResource("Font", path)
        end)
        if ok and font then
            print("[FontP0] optional font probe OK: " .. path)
        else
            print("[FontP0] optional font probe FAILED, fallback remains active: " .. path)
        end
    end
end

local function CacheTexture(path)
    if not path or textureCache_[path] then return true end
    local texture = cache:GetResource("Texture2D", path)
    if texture then
        textureCache_[path] = texture
        return true
    end
    return false
end

local function CollectPlayAssetPaths()
    local paths = { ASSETS.bg, ASSETS.bgMirror }
    local player = CurrentPlayer()
    local function Add(path)
        if path then paths[#paths + 1] = path end
    end
    Add(player.icon)
    Add(player.sprite)
    Add(player.attack)
    for _, path in ipairs(player.idle or {}) do Add(path) end
    for _, path in ipairs(player.run or {}) do Add(path) end
    for _, set in ipairs(player.attackFrameSets or {}) do
        for _, path in ipairs(set) do Add(path) end
    end
    for _, path in pairs(ASSETS.ui) do Add(path) end
    for _, path in pairs(ASSETS.enemies) do Add(path) end
    for _, path in pairs(ASSETS.items) do Add(path) end
    local unique = {}
    local result = {}
    for _, path in ipairs(paths) do
        if path and not unique[path] then
            unique[path] = true
            result[#result + 1] = path
        end
    end
    return result
end

EnsurePlayAssetsReady = function(onReady)
    if playAssetsReady_ then
        if onReady then onReady() end
        return
    end
    if playAssetLoading_ then return end
    playAssetLoading_ = true
    local paths = CollectPlayAssetPaths()
    local total = #paths
    local completed = 0
    ShowLoadingOverlay(8, "正在预热战斗序列帧")
    if total == 0 then
        playAssetsReady_ = true
        playAssetLoading_ = false
        SetLoading(100, "战斗资源已就绪")
        loadingHideDelay_ = 0.2
        if onReady then onReady() end
        return
    end
    for _, path in ipairs(paths) do
        if textureCache_[path] then
            completed = completed + 1
            SetLoading(8 + math.floor(completed / total * 88), string.format("正在预热战斗资源 %d/%d", completed, total))
            if completed >= total then
                playAssetsReady_ = true
                playAssetLoading_ = false
                SetLoading(100, "战斗资源已就绪")
                loadingHideDelay_ = 0.2
                if onReady then onReady() end
            end
        else
            cache:GetResourceAsync("Texture2D", path, function(resource)
                if resource then textureCache_[path] = resource end
                completed = completed + 1
                SetLoading(8 + math.floor(completed / total * 88), string.format("正在预热战斗资源 %d/%d", completed, total))
                if completed >= total then
                    playAssetsReady_ = true
                    playAssetLoading_ = false
                    SetLoading(100, "战斗资源已就绪")
                    loadingHideDelay_ = 0.2
                    if onReady then onReady() end
                end
            end)
        end
    end
end

local function PreloadAssets()
    -- DWP 策略：不在启动阶段主动 GetResource 全量媒体资源。
    -- UI 中的 backgroundImage 会触发引擎占位和后台下载，下载完成后热替换。
    print("[DWP] media resources use download-while-playing; startup will not block on textures or frames.")
end

local function FormalButton(text, width, onClick, disabled, height)
    local buttonHeight = height or 92
    return UI.Panel {
        width = width or 300,
        height = buttonHeight,
        clickable = not disabled,
        alignItems = "center",
        justifyContent = "center",
        opacity = disabled and 0.45 or 1.0,
        backgroundImage = ASSETS.ui.button,
        backgroundFit = "contain",
        onClick = function()
            if not disabled and onClick then onClick() end
        end,
        children = {
            Txt(text, buttonHeight < 90 and 24 or 28, C.text, { width = "100%", textAlign = "center", textStroke = { width = 3, color = "#000000" } }),
        }
    }
end

local function FormalStatCard(label, value, color, icon, width, height)
    local cardW = width or 600
    local cardH = height or 400
    local iconSize = math.floor(cardH * 0.44)
    local leftPad = 52
    local labelRight = 66
    local valueRight = 68
    local topPad = 63
    local bottomPad = 66
    local textW = math.floor(cardW * 0.623)
    return UI.Panel {
        width = cardW,
        height = cardH,
        position = "relative",
        backgroundImage = ASSETS.ui.statCard,
        backgroundFit = "fill",
        children = {
            UI.Panel {
                position = "absolute",
                left = leftPad,
                top = math.floor((cardH - iconSize) * 0.52),
                width = iconSize,
                height = iconSize,
                backgroundImage = icon,
                backgroundFit = "contain",
            },
            Txt(label, 22, C.textSecondary, {
                position = "absolute",
                right = labelRight,
                top = topPad,
                width = textW,
                textAlign = "right",
                textStroke = { width = 2, color = "#000000" },
            }),
            Txt(value, 28, color or C.text, {
                position = "absolute",
                right = valueRight,
                bottom = bottomPad,
                width = textW,
                textAlign = "right",
                textStroke = { width = 2, color = "#000000" },
            }),
        }
    }
end

local function CreateBackground()
    return UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        backgroundImage = ASSETS.ui.bg,
        backgroundFit = "cover",
        pointerEvents = "none",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                right = 0,
                bottom = 0,
                backgroundColor = {5, 12, 32, 92},
            },
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                right = 0,
                height = 520,
                backgroundColor = {90, 20, 20, 52},
            },
        }
    }
end

local function CreateCharacterPortrait()
    return UI.Panel {
        width = "100%",
        alignItems = "center",
        children = {
            UI.Panel {
                width = 300,
                height = 300,
                padding = 12,
                backgroundColor = C.surfaceDark,
                borderWidth = 4,
                borderColor = C.primary,
                children = {
                    UI.Panel { width = "100%", height = "100%", backgroundImage = CurrentPlayer().icon, backgroundFit = "contain" },
                }
            },
        }
    }
end

local function CreateHomePage()
    local stats = game.stats
    local statCardW = 480
    local statCardH = 220
    local statGapX = 12
    local statRowGapY = 10
    local statGridW = statCardW * 2 + statGapX
    local statGridH = statCardH * 3 + statRowGapY * 2
    local statGridX = math.floor((CONFIG.DesignW - statGridW) * 0.5)
    return UI.Panel {
        width = "100%",
        height = "100%",
        position = "relative",
        children = {
            UI.Panel {
                position = "absolute",
                left = 16,
                top = 0,
                width = 1048,
                height = 620,
                backgroundColor = {6, 8, 20, 70},
                borderWidth = 2,
                borderColor = {255, 210, 120, 28},
            },
            UI.Panel {
                position = "absolute",
                left = 16,
                top = 0,
                width = 1048,
                height = 620,
                backgroundImage = ASSETS.ui.heroPanel,
                backgroundFit = "contain",
            },
            UI.Panel {
                position = "absolute",
                left = 74,
                top = 148,
                width = 360,
                height = 310,
                alignItems = "center",
                justifyContent = "center",
                children = {
                    Txt("赤焰枪刃", 28, C.gold, { position = "absolute", left = 72, top = 7, width = "100%", textAlign = "center", textStroke = { width = 3, color = "#000000" } }),
                    UI.Panel { position = "absolute", left = 59, top = 67, width = 360, height = 280, backgroundImage = CurrentPlayer().icon, backgroundFit = "contain" },
                }
            },
            Txt("挂机刷宝", 34, C.text, {
                position = "absolute",
                left = 612,
                top = 196,
                width = 270,
                textAlign = "center",
                textStroke = { width = 4, color = "#000000" },
            }),
            MultiTxt("解放双手", 22, C.textSecondary, {
                position = "absolute",
                left = 612,
                top = 254,
                width = 270,
                height = 52,
                maxLines = 2,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            }),
            UI.Panel {
                position = "absolute",
                left = 612,
                top = 316,
                width = 300,
                height = 168,
                children = {
                    UI.Panel { position = "absolute", left = 0, top = 0, width = 300, height = 44, clickable = true, alignItems = "center", justifyContent = "center", onClick = function() SwitchPage("play") end, children = { Txt("进入刷宝", 23, C.text, { position = "absolute", left = -2, top = 15, width = "100%", textAlign = "center", textStroke = { width = 3, color = "#000000" } }) } },
                    UI.Panel { position = "absolute", left = 0, top = 62, width = 300, height = 44, clickable = not game.readOnly, opacity = game.readOnly and 0.45 or 1.0, alignItems = "center", justifyContent = "center", onClick = function() if not game.readOnly then SetAutoRun(not game.autoRun) end end, children = { Txt(game.autoRun and "暂停挂机" or "开始挂机", 23, C.text, { position = "absolute", left = -2, top = 11, width = "100%", textAlign = "center", textStroke = { width = 3, color = "#000000" } }) } },
                    UI.Panel { position = "absolute", left = 0, top = 124, width = 300, height = 44, clickable = not game.readOnly, opacity = game.readOnly and 0.45 or 1.0, alignItems = "center", justifyContent = "center", onClick = function() if not game.readOnly then CollectOffline() end end, children = { Txt("领取离线", 23, C.text, { position = "absolute", left = -4, top = 9, width = "100%", textAlign = "center", textStroke = { width = 3, color = "#000000" } }) } },
                }
            },

            UI.Panel {
                position = "absolute",
                left = statGridX,
                top = 604,
                width = statGridW,
                height = statGridH,
                children = {
                    UI.Panel { position = "absolute", left = 0, top = 0, width = statCardW, height = statCardH, children = { FormalStatCard("攻击", FormatInt(stats.atk), C.primary, ASSETS.ui.statAtk, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = 0, width = statCardW, height = statCardH, children = { FormalStatCard("防御", FormatInt(stats.def), C.textSecondary, ASSETS.ui.statDef, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = 0, top = statCardH + statRowGapY, width = statCardW, height = statCardH, children = { FormalStatCard("暴击", FormatPercent(stats.crit), C.gold, ASSETS.ui.statCrit, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = statCardH + statRowGapY, width = statCardW, height = statCardH, children = { FormalStatCard("攻速", string.format("%.1f", stats.atkSpeed), C.mp, ASSETS.ui.statSpeed, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = 0, top = (statCardH + statRowGapY) * 2, width = statCardW, height = statCardH, children = { FormalStatCard("生命", FormatInt(game.hp) .. "/" .. FormatInt(stats.hp), C.hp, ASSETS.ui.statHp, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = (statCardH + statRowGapY) * 2, width = statCardW, height = statCardH, children = { FormalStatCard("战力", FormatInt(stats.power), C.gold, ASSETS.ui.statPower, statCardW, statCardH) } },
                }
            },
        }
    }
end

local function FilteredInventory()
    local list = {}
    for _, item in ipairs(game.inventory or {}) do
        if item.category == selectedCategory_ then list[#list + 1] = item end
    end
    table.sort(list, function(a, b)
        local ra = RARITIES[a.rarity] and RARITIES[a.rarity].rank or 0
        local rb = RARITIES[b.rarity] and RARITIES[b.rarity].rank or 0
        if ra ~= rb then return ra > rb end
        return ItemPower(a) > ItemPower(b)
    end)
    return list
end

local function CreateItemIconCard(item, width, height)
    local selected = selectedInventoryId_ == item.id
    local rarityColor = RarityColor(item.rarity)
    local equipped = IsEquipped(item)
    return UI.Panel {
        width = width or 214,
        height = height or 236,
        clickable = true,
        padding = 12,
        gap = 8,
        backgroundColor = selected and C.surfaceHover or C.surface,
        borderWidth = 4,
        borderColor = selected and C.primary or rarityColor,
        onClick = function()
            selectedInventoryId_ = item.id
            RequestPageRefresh()
        end,
        children = {
            UI.Panel {
                width = "100%",
                height = 96,
                alignItems = "center",
                justifyContent = "center",
                backgroundColor = C.surfaceDark,
                borderWidth = 2,
                borderColor = rarityColor,
                children = {
                    UI.Panel { width = 88, height = 88, backgroundImage = ItemImage(item), backgroundFit = "contain" },
                }
            },
            Txt(RarityName(item.rarity), 24, rarityColor, { width = "100%", textAlign = "center" }),
            MultiTxt(item.name or "未知装备", 24, C.text, { height = 58, maxLines = 2, textAlign = "center" }),
            Txt(equipped and "已穿戴" or ("战力 " .. FormatInt(ItemPower(item))), 24, equipped and C.success or C.gold, { width = "100%", textAlign = "center" }),
        }
    }
end

local function CreateInventoryTabs()
    local children = {}
    for _, cat in ipairs(CATEGORIES) do
        children[#children + 1] = UI.Button {
            text = cat.name,
            variant = selectedCategory_ == cat.id and "primary" or "secondary",
            width = 150,
            onClick = function()
                selectedCategory_ = cat.id
                selectedInventoryId_ = nil
                RequestPageRefresh()
            end,
        }
    end
    return UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 10, children = children }
end

local function CreateSelectedItemDetail()
    local item = GetItemById(selectedInventoryId_)
    if not item then
        return PixelPanel {
            width = "100%",
            height = 220,
            children = {
                SectionTitle("装备详情", "点选图片卡查看装备，装备和道具都使用像素图标"),
                UI.Panel { width = 96, height = 96, backgroundImage = ASSETS.items.chest, backgroundFit = "contain", alignSelf = "center" },
            }
        }
    end
    local slotText = item.slot and SlotName(item.slot) or (item.category or "物品")
    local setText = item.setId and (SETS[item.setId].short .. "套") or "散件"
    return PixelPanel {
        width = "100%",
        flexDirection = "row",
        gap = 18,
        children = {
            UI.Panel {
                width = 154,
                height = 154,
                flexShrink = 0,
                padding = 10,
                backgroundColor = C.surfaceDark,
                borderWidth = 4,
                borderColor = RarityColor(item.rarity),
                children = {
                    UI.Panel { width = "100%", height = "100%", backgroundImage = ItemImage(item), backgroundFit = "contain" },
                }
            },
            UI.Panel {
                flexGrow = 1,
                flexBasis = 0,
                flexShrink = 1,
                gap = 10,
                children = {
                    SectionTitle(item.name or "未知装备", RarityName(item.rarity) .. " / " .. slotText .. " / " .. setText),
                    UI.Panel {
                        width = "100%",
                        flexDirection = "row",
                        gap = 12,
                        children = {
                            StatBox("战力", FormatInt(ItemPower(item)), C.gold, ItemImage(item)),
                            StatBox("数量", FormatInt(item.quantity or 1), C.textSecondary, ASSETS.items.crystal),
                        }
                    },
                    item.slot and UI.Panel {
                        width = "100%",
                        flexDirection = "row",
                        gap = 12,
                        children = {
                            UI.Button { text = "穿戴", variant = "primary", width = 170, disabled = game.readOnly, onClick = function() EquipItem(item) end },
                            UI.Button { text = "查看", variant = "secondary", width = 150, onClick = function() UI.Toast.Show(item.name or "装备", { duration = 2, variant = "info" }) end },
                        }
                    } or nil,
                }
            }
        }
    }
end

local function CreateInventoryPage()
    local cards = {}
    for _, item in ipairs(FilteredInventory()) do cards[#cards + 1] = CreateItemIconCard(item) end
    if #cards == 0 then
        cards[#cards + 1] = UI.Panel { width = 214, height = 236, alignItems = "center", justifyContent = "center", backgroundColor = C.surfaceDark, borderWidth = 4, borderColor = C.border, children = { UI.Panel { width = 96, height = 96, backgroundImage = ASSETS.items.chest, backgroundFit = "contain" } } }
    end
    return UI.Panel {
        width = "100%",
        height = "100%",
        padding = 24,
        gap = 14,
        children = {
            PixelPanel {
                width = "100%",
                children = {
                    SectionTitle("像素背包", string.format("装备 %d/%d，按图片分类管理", game.equipmentInventoryCount or 0, game.inventoryCapacity or 300)),
                    CreateInventoryTabs(),
                    UI.Panel {
                        width = "100%",
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 10,
                        children = {
                            UI.Button { text = "分解白", variant = "secondary", width = 150, disabled = game.readOnly, onClick = function() DecomposeByRank(1) end },
                            UI.Button { text = "分解蓝", variant = "secondary", width = 150, disabled = game.readOnly, onClick = function() DecomposeByRank(2) end },
                            UI.Button { text = "分解紫", variant = "danger", width = 150, disabled = game.readOnly, onClick = function() DecomposeByRank(3) end },
                            UI.Button { text = "分解橙", variant = "danger", width = 150, disabled = game.readOnly, onClick = function() DecomposeByRank(4) end },
                        }
                    },
                }
            },
            CreateSelectedItemDetail(),
            UI.ScrollView {
                width = "100%",
                flexGrow = 1,
                flexBasis = 0,
                scrollY = true,
                showScrollbar = true,
                children = {
                    UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", justifyContent = "center", gap = 14, paddingBottom = 28, children = cards }
                }
            }
        }
    }
end

local function CreateEquipSlot(slot)
    local item = game.equipped and game.equipped[slot.id]
    local selected = selectedSlot_ == slot.id
    local color = item and RarityColor(item.rarity) or C.border
    return UI.Panel {
        width = 214,
        height = 212,
        clickable = true,
        padding = 10,
        backgroundColor = selected and C.surfaceHover or C.surface,
        borderWidth = 4,
        borderColor = selected and C.primary or color,
        onClick = function()
            selectedSlot_ = slot.id
            RequestPageRefresh()
        end,
        children = {
            UI.Panel {
                width = "100%",
                height = 98,
                backgroundColor = C.surfaceDark,
                borderWidth = 2,
                borderColor = color,
                alignItems = "center",
                justifyContent = "center",
                children = {
                    UI.Panel { width = 86, height = 86, backgroundImage = item and ItemImage(item) or ASSETS.items.chest, backgroundFit = "contain", opacity = item and 1 or 0.42 },
                }
            },
            Txt(slot.name, 24, selected and C.primary or C.textSecondary, { width = "100%", textAlign = "center" }),
            Txt(item and ("+" .. tostring(item.enhance or 0) .. " / " .. tostring(item.star or 0) .. "★") or "空槽", 24, item and C.gold or C.textDim, { width = "100%", textAlign = "center" }),
        }
    }
end

local function CreateSetOverview()
    local counts = {}
    for _, item in pairs(game.equipped or {}) do
        if item and item.setId then counts[item.setId] = (counts[item.setId] or 0) + (item.rarity == "myth" and 2 or 1) end
    end
    local children = { SectionTitle("套装图鉴", "以像素卡片显示套装进度") }
    for _, setId in ipairs(SET_ORDER) do
        local set = SETS[setId]
        local count = counts[setId] or 0
        children[#children + 1] = UI.Panel {
            width = "100%",
            height = 76,
            flexDirection = "row",
            alignItems = "center",
            padding = 10,
            gap = 12,
            backgroundColor = C.surfaceDark,
            borderWidth = 3,
            borderColor = set.color,
            children = {
                UI.Panel { width = 54, height = 54, backgroundImage = ASSETS.items.crystal, backgroundFit = "contain", imageTint = set.color },
                Txt(set.short, 24, set.color, { width = 92 }),
                UI.ProgressBar { flexGrow = 1, flexBasis = 0, height = 22, value = count, max = 12, fillColor = set.color },
                Txt(tostring(count) .. "/12", 24, C.text, { width = 80, textAlign = "right" }),
            }
        }
    end
    return PixelPanel { width = "100%", children = children }
end

local function CreateEquipmentPage()
    local slots = {}
    for _, slot in ipairs(SLOTS) do slots[#slots + 1] = CreateEquipSlot(slot) end
    local selectedItem = game.equipped and game.equipped[selectedSlot_]
    return UI.ScrollView {
        width = "100%",
        height = "100%",
        scrollY = true,
        showScrollbar = false,
        children = {
            UI.Panel {
                width = "100%",
                padding = 24,
                gap = 16,
                children = {
                    PixelPanel {
                        width = "100%",
                        children = {
                            SectionTitle("像素装备盘", "12槽装备全部用图片格展示"),
                            UI.Panel {
                                width = "100%",
                                flexDirection = "row",
                                gap = 12,
                                children = {
                                    UI.Button { text = "一键最优", variant = "primary", width = 190, disabled = game.readOnly, onClick = function() AutoEquipBest() end },
                                    UI.Button { text = "强化", variant = "success", width = 150, disabled = game.readOnly, onClick = function() StrengthenSelected() end },
                                    UI.Button { text = "升星", variant = "secondary", width = 150, disabled = game.readOnly, onClick = function() StarSelected() end },
                                }
                            },
                        }
                    },
                    PixelPanel {
                        width = "100%",
                        flexDirection = "row",
                        gap = 18,
                        children = {
                            UI.Panel { width = 124, height = 124, backgroundImage = selectedItem and ItemImage(selectedItem) or ASSETS.items.chest, backgroundFit = "contain", flexShrink = 0 },
                            UI.Panel {
                                flexGrow = 1,
                                flexBasis = 0,
                                flexShrink = 1,
                                children = {
                                    SectionTitle("当前槽位：" .. SlotName(selectedSlot_), selectedItem and (selectedItem.name .. " / " .. RarityName(selectedItem.rarity)) or "未穿戴装备"),
                                    selectedItem and Txt("战力 " .. FormatInt(ItemPower(selectedItem)), 26, C.gold, {}) or Txt("空槽", 26, C.textDim, {}),
                                }
                            }
                        }
                    },
                    UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", justifyContent = "center", gap = 14, children = slots },
                    CreateSetOverview(),
                }
            }
        }
    }
end

---@return string, string[], FrameEditorParam
local function EditorFrameConfig(id)
    local player = CurrentPlayer()
    if id == "attackA" then return "攻击A", player.attackFrameSets[1], frameEditorParams_.attackA end
    if id == "attackB" then return "攻击B", player.attackFrameSets[2], frameEditorParams_.attackB end
    if id == "attackC" then return "攻击C", player.attackFrameSets[3], frameEditorParams_.attackC end
    return "跑步", player.run, frameEditorParams_.run
end

---@param params FrameEditorParam
---@param key string
---@param step number
local function AdjustFrameEditorParam(params, key, step)
    if key == "x" then params.x = params.x + step
    elseif key == "y" then params.y = params.y + step
    elseif key == "w" then params.w = params.w + step
    elseif key == "h" then params.h = params.h + step
    elseif key == "fps" then params.fps = params.fps + step
    elseif key == "scale" then params.scale = math.max(0.2, params.scale + step) end
end

---@param params FrameEditorParam
local function ResetFrameEditorParam(params)
    params.x = 0
    params.y = 0
    params.w = RUN_W
    params.h = RUN_H
    params.fps = frameEditorSelected_ == "run" and RUN_FPS or ATTACK_FPS
    params.scale = 1.0
end

local function ParamsForAttackFrames(frames)
    local player = CurrentPlayer()
    if player.attackFrameSets then
        if frames == player.attackFrameSets[1] then return frameEditorParams_.attackA end
        if frames == player.attackFrameSets[2] then return frameEditorParams_.attackB end
        if frames == player.attackFrameSets[3] then return frameEditorParams_.attackC end
    end
    return frameEditorParams_.attackA
end

local function CreateEditorButton(text, onClick, props)
    return UI.Button(CopyProps({ text = text, width = 118, height = 58, onClick = onClick }, props))
end

local function CreateEditorAdjustRow(label, key, step)
    local params = frameEditorParams_[frameEditorSelected_]
    local valueLabel = Txt(label .. " " .. tostring(params[key]), 24, C.text, { width = 160 })
    return UI.Panel {
        width = "100%",
        flexDirection = "row",
        alignItems = "center",
        gap = 10,
        children = {
            valueLabel,
            CreateEditorButton("-" .. tostring(step), function()
                AdjustFrameEditorParam(params, key, -step)
                valueLabel:SetText(label .. " " .. tostring(params[key]))
                UpdateFrameEditorVisuals(0)
            end, { variant = "secondary" }),
            CreateEditorButton("+" .. tostring(step), function()
                AdjustFrameEditorParam(params, key, step)
                valueLabel:SetText(label .. " " .. tostring(params[key]))
                UpdateFrameEditorVisuals(0)
            end, { variant = "primary" }),
        }
    }
end

local function CopyFrameEditorSettings()
    local lines = {
        "-- frame editor settings",
        "frameEditorParams = {",
    }
    for _, id in ipairs(frameEditorOrder_) do
        local p = frameEditorParams_[id]
        lines[#lines + 1] = string.format("    %s = { x = %d, y = %d, w = %d, h = %d, fps = %d, scale = %.2f },", id, p.x, p.y, p.w, p.h, p.fps, p.scale)
    end
    lines[#lines + 1] = "}"
    local text = table.concat(lines, "\n")
    ui.useSystemClipboard = true
    ui:SetClipboardText(text)
    UI.Toast.Show("已复制调帧参数", { duration = 1.6, variant = "success", position = "bottom" })
end

local function CreateFrameEditorToggle(item)
    local visible = frameEditorVisible_[item.id] == true
    return UI.Panel {
        width = 170,
        height = 58,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        backgroundColor = visible and C.secondary or C.surfaceDark,
        borderWidth = 3,
        borderColor = visible and C.secondaryPressed or C.border,
        onClick = function()
            frameEditorVisible_[item.id] = not frameEditorVisible_[item.id]
            local anyVisible = false
            for _, id in ipairs(frameEditorOrder_) do
                if frameEditorVisible_[id] then anyVisible = true; break end
            end
            if not anyVisible then frameEditorVisible_[item.id] = true end
            RefreshCurrentPage()
        end,
        children = { Txt((visible and "显示 " or "隐藏 ") .. item.name, 23, visible and C.background or C.textSecondary, { width = "100%", textAlign = "center" }) },
    }
end

local function CreateFrameEditorPage()
    frameEditorRefs_ = { previews = {} }
    local tabs = {}
    local toggles = {}
    local options = {
        { id = "run", name = "跑步" },
        { id = "attackA", name = "攻击A" },
        { id = "attackB", name = "攻击B" },
        { id = "attackC", name = "攻击C" },
    }
    for _, item in ipairs(options) do
        local active = frameEditorSelected_ == item.id
        tabs[#tabs + 1] = UI.Panel {
            width = 170,
            height = 62,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundColor = active and C.primary or C.surfaceDark,
            borderWidth = 3,
            borderColor = active and C.primaryPressed or C.border,
            onClick = function()
                frameEditorSelected_ = item.id
                frameEditorVisible_[item.id] = true
                RefreshCurrentPage()
            end,
            children = { Txt("编辑 " .. item.name, 24, active and C.background or C.text, { width = "100%", textAlign = "center" }) },
        }
        toggles[#toggles + 1] = CreateFrameEditorToggle(item)
    end

    local title, frames, params = EditorFrameConfig(frameEditorSelected_)
    for _, id in ipairs(frameEditorOrder_) do
        local _, itemFrames, itemParams = EditorFrameConfig(id)
        local preview = UI.Panel {
            position = "absolute",
            left = 0,
            top = 0,
            width = itemParams.w,
            height = itemParams.h,
            backgroundImage = itemFrames[1],
            backgroundFit = "contain",
            visible = frameEditorVisible_[id] == true,
            opacity = id == frameEditorSelected_ and 1.0 or 0.62,
        }
        frameEditorRefs_.previews[id] = preview
    end
    frameEditorRefs_.preview = frameEditorRefs_.previews[frameEditorSelected_]
    frameEditorRefs_.reference = UI.Panel { position = "absolute", left = 330, top = 390, width = RUN_W, height = RUN_H, borderWidth = 3, borderColor = {255, 217, 61, 180}, backgroundColor = {255, 217, 61, 28} }
    frameEditorRefs_.info = Txt("", 24, C.textSecondary, { width = "100%" })
    frameEditorRefs_.title = Txt(title, 32, C.primary, { width = "100%", textStroke = { width = 2, color = "#000000" } })

    local controls = PixelPanel {
        width = "100%",
        gap = 12,
        children = {
            frameEditorRefs_.title,
            frameEditorRefs_.info,
            UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 10, children = tabs },
            UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 10, children = toggles },
            UI.Panel { width = "100%", flexDirection = "row", gap = 10, children = {
                CreateEditorButton(frameEditorPaused_ and "继续" or "暂停", function()
                    frameEditorPaused_ = not frameEditorPaused_
                    RefreshCurrentPage()
                end, { variant = frameEditorPaused_ and "success" or "secondary", width = 150 }),
                CreateEditorButton("复制参数", function() CopyFrameEditorSettings() end, { variant = "primary", width = 180 }),
            } },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                gap = 14,
                children = {
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 10, children = {
                        CreateEditorAdjustRow("X偏移", "x", 5),
                        CreateEditorAdjustRow("Y偏移", "y", 5),
                        CreateEditorAdjustRow("宽度", "w", 10),
                    } },
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 10, children = {
                        CreateEditorAdjustRow("高度", "h", 10),
                        CreateEditorAdjustRow("缩放", "scale", 0.1),
                        CreateEditorAdjustRow("帧率", "fps", 1),
                        UI.Panel { width = "100%", flexDirection = "row", gap = 10, children = {
                            CreateEditorButton("重置", function()
                                ResetFrameEditorParam(params)
                                RefreshCurrentPage()
                            end, { variant = "danger", width = 150 }),
                            CreateEditorButton("去刷宝看效果", function() SwitchPage("play") end, { variant = "success", width = 220 }),
                        } },
                    } },
                }
            },
            MultiTxt("提示：先点“编辑”选择要调整的动作，再点“显示/隐藏”同时叠加多套序列帧对比。暂停后画面冻结，方便看大小和位置。点“复制参数”会复制当前全部调帧参数，发给我即可固化到默认代码。", 24, C.textDim, { width = "100%" }),
        }
    }

    local sceneChildren = {
        UI.Panel { position = "absolute", left = 0, top = BG_TILE_TOP, width = BG_TILE_W, bottom = -BG_TILE_TOP, backgroundImage = ASSETS.bg, backgroundFit = "cover", opacity = 0.45 },
        frameEditorRefs_.reference,
    }
    for _, id in ipairs(frameEditorOrder_) do
        sceneChildren[#sceneChildren + 1] = frameEditorRefs_.previews[id]
    end

    local scene = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        position = "relative",
        overflow = "hidden",
        backgroundColor = {9, 9, 25, 255},
        borderWidth = 4,
        borderColor = C.border,
        children = sceneChildren,
    }

    UpdateFrameEditorVisuals(0)
    return UI.Panel {
        width = "100%",
        height = "100%",
        padding = 24,
        gap = 14,
        children = { controls, scene },
    }
end

UpdateFrameEditorVisuals = function(dt)
    if not frameEditorRefs_ or not frameEditorRefs_.previews then return end
    if not frameEditorPaused_ then animationTime_ = animationTime_ + (dt or 0) end
    local refLeft = 330
    local refTop = 390
    for _, id in ipairs(frameEditorOrder_) do
        local _, frames, params = EditorFrameConfig(id)
        local preview = frameEditorRefs_.previews[id]
        if preview then
            preview:SetStyle({
                visible = frameEditorVisible_[id] == true,
                left = refLeft + params.x,
                top = refTop + params.y,
                width = math.max(20, params.w),
                height = math.max(20, params.h),
                scale = params.scale,
                opacity = id == frameEditorSelected_ and 1.0 or 0.62,
                backgroundImage = FrameAt(frames, params.fps, animationTime_),
            })
        end
    end
    if frameEditorRefs_.reference then
        frameEditorRefs_.reference:SetStyle({ left = refLeft, top = refTop, width = RUN_W, height = RUN_H })
    end
    local title, _, params = EditorFrameConfig(frameEditorSelected_)
    if frameEditorRefs_.title then frameEditorRefs_.title:SetText(title .. (frameEditorPaused_ and " / 已暂停" or "")) end
    if frameEditorRefs_.info then
        frameEditorRefs_.info:SetText(string.format("x=%d  y=%d  w=%d  h=%d  fps=%d  scale=%.1f", params.x, params.y, params.w, params.h, params.fps, params.scale))
    end
end

local function CreatePlayPage()
    EnsureRoadEvents()
    playRefs_ = { objects = {}, bgTiles = {} }
    currentPlayerImage_ = nil
    playRefs_.bgTiles[1] = UI.Panel { position = "absolute", left = 0, top = BG_TILE_TOP, width = BG_TILE_W, bottom = -BG_TILE_TOP, backgroundImage = ASSETS.bg, backgroundFit = "cover" }
    playRefs_.bgTiles[2] = UI.Panel { position = "absolute", left = BG_TILE_W, top = BG_TILE_TOP, width = BG_TILE_W, bottom = -BG_TILE_TOP, backgroundImage = ASSETS.bgMirror, backgroundFit = "cover" }
    playRefs_.bgTiles[3] = UI.Panel { position = "absolute", left = BG_TILE_W * 2, top = BG_TILE_TOP, width = BG_TILE_W, bottom = -BG_TILE_TOP, backgroundImage = ASSETS.bg, backgroundFit = "cover" }
    playRefs_.playerShadow = UI.Panel { position = "absolute", left = PLAYER_SCREEN_X + 42, top = ROAD_Y - 8, width = 132, height = 18, backgroundColor = {0, 0, 0, 96} }
    playRefs_.player = UI.Panel { position = "absolute", left = PLAYER_SCREEN_X, top = PLATFORM_PLAYER_Y, width = RUN_W, height = RUN_H, backgroundImage = CurrentPlayer().sprite or CurrentPlayer().icon, backgroundFit = "contain" }

    for i = 1, EVENT_VIEW_COUNT do
        local obj = UI.Panel { position = "absolute", left = 0, top = 0, width = ENEMY_SIZE, height = ENEMY_SIZE, backgroundImage = ASSETS.enemies.slime, backgroundFit = "contain", visible = true }
        playRefs_.objects[i] = obj
    end

    playRefs_.pickup = UI.Panel { position = "absolute", left = 0, top = 0, width = LOOT_SIZE, height = LOOT_SIZE, backgroundImage = ASSETS.items.crystal, backgroundFit = "contain", visible = false }
    playRefs_.pickupSpark = UI.Panel { position = "absolute", left = 0, top = 0, width = 82, height = 82, backgroundColor = {255, 217, 61, 80}, borderWidth = 4, borderColor = {255, 255, 255, 210}, visible = false }
    playRefs_.floatLabel = Txt("", 30, C.gold, { position = "absolute", left = 0, top = 0, width = 360, textAlign = "center", visible = false, textStroke = { width = 2, color = "#000000" } })
    playRefs_.enemyDamageLabels = {}
    for i = 1, #ATTACK_HIT_TIMINGS do
        playRefs_.enemyDamageLabels[i] = Txt("", 34, C.hp, { position = "absolute", left = 0, top = 0, width = 360, textAlign = "center", visible = false, textStroke = { width = 3, color = "#000000" } })
    end
    playRefs_.event = Txt("向右移动", 28, C.primary, { width = "100%" })
    playRefs_.progress = Txt("第1层", 28, C.focus, {})
    playRefs_.lootLabel = Txt(lastLootText_, 26, C.gold, { width = "100%" })
    playRefs_.hpBar = UI.ProgressBar { width = "100%", height = 24, value = game.hp or 1, max = game.stats.hp or 1, fillColor = C.hp }
    playRefs_.runButtonLabel = Txt(game.autoRun and "刷宝中" or "开始刷宝", 28, C.text, { width = "100%", textAlign = "center", textStroke = { width = 2, color = "#000000" } })

    ---@type table
    local sceneChildren = { playRefs_.bgTiles[1], playRefs_.bgTiles[2], playRefs_.bgTiles[3] }
    for i = 1, #playRefs_.objects do sceneChildren[#sceneChildren + 1] = playRefs_.objects[i] end
    sceneChildren[#sceneChildren + 1] = playRefs_.playerShadow
    sceneChildren[#sceneChildren + 1] = playRefs_.player
    sceneChildren[#sceneChildren + 1] = playRefs_.pickup
    sceneChildren[#sceneChildren + 1] = playRefs_.pickupSpark
    sceneChildren[#sceneChildren + 1] = playRefs_.floatLabel
    for i = 1, #playRefs_.enemyDamageLabels do sceneChildren[#sceneChildren + 1] = playRefs_.enemyDamageLabels[i] end

    local runButton = UI.Panel {
        width = 236,
        height = 86,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        backgroundColor = game.autoRun and C.primary or C.secondary,
        borderWidth = 4,
        borderColor = game.autoRun and C.primaryPressed or C.secondaryPressed,
        onClick = function()
            if not game.readOnly and not playAssetLoading_ then SetAutoRun(not game.autoRun) end
        end,
        children = { playRefs_.runButtonLabel },
    }
    playRefs_.runButton = runButton

    local root = UI.Panel {
        width = "100%",
        height = "100%",
        padding = 24,
        children = {
            PixelPanel {
                width = "100%",
                height = "100%",
                padding = 18,
                children = {
                    UI.Panel {
                        width = "100%",
                        height = 92,
                        flexDirection = "row",
                        alignItems = "center",
                        justifyContent = "space-between",
                        gap = 14,
                        children = {
                            UI.Panel { flexGrow = 1, flexBasis = 0, flexShrink = 1, children = { playRefs_.event, playRefs_.lootLabel } },
                            playRefs_.progress,
                            runButton,
                        }
                    },
                    UI.Panel { width = "100%", children = { Txt("生命", 24, C.textSecondary), playRefs_.hpBar } },
                    UI.Panel {
                        width = "100%",
                        flexGrow = 1,
                        flexBasis = 0,
                        position = "relative",
                        overflow = "hidden",
                        backgroundColor = {9, 9, 25, 255},
                        borderWidth = 4,
                        borderColor = C.border,
                        children = sceneChildren,
                    },
                    UI.Panel {
                        width = "100%",
                        height = 110,
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 16,
                        children = {
                            UI.Panel { width = 88, height = 88, backgroundImage = lastLootIcon_ or ASSETS.items.chest, backgroundFit = "contain" },
                            UI.Panel { flexGrow = 1, flexBasis = 0, flexShrink = 1, children = { Txt("最近获得", 24, C.textDim), Txt(lastLootText_, 28, C.gold, { width = "100%" }) } },
                            UI.Panel { width = 88, height = 88, backgroundImage = ASSETS.items.gold, backgroundFit = "contain" },
                        }
                    },
                }
            }
        }
    }
    UpdatePlayVisuals(0)
    return root
end

local function CreatePageContent()
    if game.page == "admin" and game.isAdmin then return AdminPanel.Build(UI, { onChanged = RequestPageRefresh, readOnly = game.readOnly }) end
    if game.page == "bag" then return CreateInventoryPage() end
    if game.page == "equip" then return CreateEquipmentPage() end
    if game.page == "play" then return CreatePlayPage() end
    if game.page == "frameEditor" then return CreateFrameEditorPage() end
    return CreateHomePage()
end

UpdateBottomNav = function()
    if not navRefs_ then return end
    for id, ref in pairs(navRefs_) do
        local active = game.page == id
        if ref.selected then ref.selected:SetStyle({ visible = active }) end
        if ref.label then ref.label:SetFontColor(active and C.text or C.textSecondary) end
    end
end

RefreshCurrentPage = function()
    if not pageContainer_ then RequestFullRebuild(); return end
    game = GameStateAdapter.GetViewState()
    pageContainer_:ClearChildren()
    pageContainer_:AddChild(CreatePageContent())
    UpdateTopBar()
    UpdateBottomNav()
end

SwitchPage = function(pageId)
    if pageId == "play" then
        EnsurePlayAssetsReady(function()
            GameStateAdapter.SetPage(pageId)
            game = GameStateAdapter.GetViewState()
            RefreshCurrentPage()
        end)
        return
    end
    GameStateAdapter.SetPage(pageId)
    game = GameStateAdapter.GetViewState()
    RefreshCurrentPage()
end

local function CreateBottomNav()
    local nav = {
        { id = "home", name = "首页" },
        { id = "bag", name = "背包" },
        { id = "equip", name = "装备" },
        { id = "play", name = "刷宝" },
        { id = "frameEditor", name = "调帧" },
    }
    if game.isAdmin then nav[#nav + 1] = { id = "admin", name = "管理" } end
    local navAreaX = 28
    local navAreaW = 1024
    local navBgX = 0
    local navBgW = CONFIG.DesignW
    local slotW = navAreaW / #nav
    local buttonW = math.min(190, slotW - 8)
    navRefs_ = {}
    local children = {
        UI.Panel {
            position = "absolute",
            left = navBgX,
            top = 0,
            width = navBgW,
            height = 180,
            backgroundImage = ASSETS.ui.bottomNav,
            backgroundFit = "contain",
        },
    }
    for i, item in ipairs(nav) do
        local active = game.page == item.id
        local x = math.floor(navAreaX + (i - 1) * slotW + (slotW - buttonW) * 0.5)
        local buttonBg = UI.Panel {
            position = "absolute",
            left = 0,
            top = 0,
            width = buttonW,
            height = 126,
            backgroundImage = ASSETS.ui.navSelected,
            backgroundFit = "contain",
            opacity = active and 1.0 or 0.82,
        }
        local selected = UI.Panel {
            position = "absolute",
            left = 0,
            top = 0,
            width = buttonW,
            height = 126,
            visible = active,
            backgroundColor = {31, 162, 255, 36},
            borderWidth = 3,
            borderColor = C.focus,
        }
        local label = Txt(item.name, 29, active and C.text or C.textSecondary, {
            position = "absolute",
            left = 0,
            top = 42,
            width = buttonW,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
        })
        local button = UI.Panel {
            position = "absolute",
            left = x,
            top = 28,
            width = buttonW,
            height = 126,
            clickable = true,
            onClick = function()
                if game.page ~= item.id then SwitchPage(item.id) end
            end,
            children = {
                buttonBg,
                selected,
                label,
            }
        }
        navRefs_[item.id] = { button = button, selected = selected, label = label }
        children[#children + 1] = button
    end
    return UI.Panel {
        width = "100%",
        height = 170,
        flexShrink = 0,
        position = "relative",
        children = children,
    }
end

local function CreateLoadingOverlay()
    loadingDots_ = {}
    loadingPercentLabel_ = Txt(string.format("%d%%", math.floor(loadingProgress_)), 36, C.primary, { width = "100%", textAlign = "center" })
    loadingMessageLabel_ = MultiTxt(loadingMessage_, 28, C.textSecondary, { width = "100%", textAlign = "center", maxLines = 2 })
    loadingProgressBar_ = UI.ProgressBar { width = 720, height = 30, value = loadingProgress_, max = 100, fillColor = C.primary }
    local dotLayer = UI.Panel { width = 240, height = 240, position = "relative" }
    for i = 1, 12 do
        local dot = UI.Panel { position = "absolute", left = 108, top = 108, width = 24, height = 24, backgroundColor = C.primary }
        loadingDots_[i] = dot
        dotLayer:AddChild(dot)
    end
    loadingOverlay_ = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        zIndex = 1000,
        backgroundColor = {0, 0, 0, 178},
        alignItems = "center",
        justifyContent = "center",
        paddingLeft = 80,
        paddingRight = 80,
        children = {
            PixelPanel {
                width = "100%",
                alignItems = "center",
                gap = 32,
                children = {
                    Txt(CONFIG.Title, 34, C.text, { width = "100%", textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
                    Txt("资源加载中", 24, C.textDim, { width = "100%", textAlign = "center" }),
                    dotLayer,
                    loadingPercentLabel_,
                    loadingMessageLabel_,
                    loadingProgressBar_,
                }
            }
        }
    }
    if uiRoot_ then
        uiRoot_:AddChild(loadingOverlay_)
    end
end

ShowLoadingOverlay = function(progress, message)
    loadingActive_ = true
    loadingHideDelay_ = nil
    SetLoading(progress or 0, message or "正在加载资源")
    if loadingOverlay_ then
        loadingOverlay_:Show()
    else
        CreateLoadingOverlay()
    end
end

local function HideLoadingOverlay()
    loadingActive_ = false
    loadingHideDelay_ = nil
    if loadingOverlay_ then
        loadingOverlay_:Hide()
    end
end

local function StartDwpLoadingOverlay()
    ShowLoadingOverlay(5, "正在进入游戏，后台加载资源")
    PreloadAssets()
    if dwpObserverId_ then
        cache:StopObservingDownloads(dwpObserverId_)
        dwpObserverId_ = nil
    end
    dwpObserverId_ = cache:ObserveDownloads(
        function(completedCount, totalCount, completedBytes)
            local progress = 20
            if totalCount and totalCount > 0 then
                progress = 20 + math.floor((completedCount / totalCount) * 75)
            end
            SetLoading(progress, string.format("正在加载资源 %d/%d", completedCount or 0, totalCount or 0))
        end,
        function(completedBytes)
            SetLoading(100, "资源加载完成")
            loadingHideDelay_ = 0.35
            if dwpObserverId_ then
                cache:StopObservingDownloads(dwpObserverId_)
                dwpObserverId_ = nil
            end
        end
    )
end

SetLoading = function(progress, message)
    loadingProgress_ = Clamp(progress or loadingProgress_, 0, 100)
    loadingMessage_ = message or loadingMessage_
    if loadingPercentLabel_ then loadingPercentLabel_:SetText(string.format("%d%%", math.floor(loadingProgress_))) end
    if loadingMessageLabel_ then loadingMessageLabel_:SetText(loadingMessage_) end
    if loadingProgressBar_ then loadingProgressBar_:SetValue(loadingProgress_) end
end

local function UpdateLoadingSpinner(dt)
    if not loadingActive_ then return end
    loadingTimer_ = loadingTimer_ + dt
    local radius = 84
    for i, dot in ipairs(loadingDots_) do
        local angle = loadingTimer_ * 5.2 + (i - 1) * math.pi * 2 / 12
        local alpha = math.floor(80 + 175 * (i / 12))
        dot:SetStyle({
            left = 108 + math.cos(angle) * radius,
            top = 108 + math.sin(angle) * radius,
            backgroundColor = {33, 189, 174, alpha},
        })
    end
end

local function SelectAttackFrames(job)
    local sets = job.attackFrameSets
    if sets and #sets > 0 then
        local index = 1
        if #sets > 1 then
            index = math.random(1, #sets - 1)
            if lastAttackSetIndex_ and index >= lastAttackSetIndex_ then index = index + 1 end
        end
        lastAttackSetIndex_ = index
        return sets[index], index
    end
    return job.attackFrames or { job.attack or job.sprite or job.icon }, nil
end

local function TriggerPickupVisual(image, startX, startY, text)
    pickupFx_ = {
        age = 0,
        duration = 0.52,
        image = image or ASSETS.items.crystal,
        startX = startX or (PLAYER_SCREEN_X + 280),
        startY = startY or (ROAD_Y - LOOT_SIZE),
        endX = PLAYER_SCREEN_X + 76,
        endY = PLATFORM_PLAYER_Y + 70,
        text = text or "获得道具",
    }
    lastLootText_ = pickupFx_.text
    lastLootIcon_ = pickupFx_.image
end

local function AddEnemyDamageBurst(text, baseX, baseY, delay, variant)
    enemyDamageBursts_[#enemyDamageBursts_ + 1] = {
        age = -(delay or 0),
        text = text or "命中",
        baseX = baseX or (PLAYER_SCREEN_X + 360),
        baseY = baseY or (ROAD_Y - ENEMY_SIZE - 72),
        variant = variant or 1,
    }
end

local function ScheduleAttackDamageText(text, eventType, isBurst)
    local damageText = text or "命中"
    local currentForDamage = roadEvents_[1]
    local enemyX = currentForDamage and (currentForDamage.x - presentationX_ - 96) or (PLAYER_SCREEN_X + 360)
    local enemyY = ROAD_Y - ENEMY_SIZE - 72
    local comboPrefix = eventType == "boss" and "破盾" or (eventType == "elite" and "重击" or "连击")
    for i, timing in ipairs(ATTACK_HIT_TIMINGS) do
        local label = damageText
        if i > 1 then label = comboPrefix .. " " .. FormatInt((game.stats and game.stats.atk) or 0) end
        if isBurst and i == 1 then label = damageText end
        AddEnemyDamageBurst(label, enemyX + (i - 3) * 18, enemyY - (i % 2) * 18, timing * ATTACK_DURATION, i)
    end
end

local function TriggerCombatVisual(text, eventType, isBurst)
    if combatTimer_ <= 0 then combatTimer_ = ATTACK_DURATION end
    hitBurst_ = isBurst == true
    lastEventType_ = eventType or lastEventType_
    floatingText_ = { age = 0.0, text = isBurst and (text or "暴击") or "连击" }
    local hasActiveDamage = false
    for _, burst in ipairs(enemyDamageBursts_) do
        if burst.age < 1.05 then hasActiveDamage = true; break end
    end
    if not hasActiveDamage then
        ScheduleAttackDamageText(text or "命中", eventType, isBurst)
    end
end

local function BeginEnemyAttack(event)
    currentEventLocked_ = true
    currentAttackFrames_ = SelectAttackFrames(CurrentPlayer())
    combatAnimationTime_ = 0
    combatTimer_ = ATTACK_DURATION
    enemyDamageBursts_ = {}
    TriggerCombatVisual("命中 " .. FormatInt((game.stats and game.stats.atk) or 0), event and event.eventType or "monster", false)
end

local function HandleDeltaVisual(payload)
    game = GameStateAdapter.GetViewState()
    for _, value in ipairs((payload and payload.events) or {}) do
        if value.kind == "cell_entered" then
            lastEventType_ = value.eventType or lastEventType_
        elseif value.kind == "battle" then
            local isBurst = value.lucky or value.critical
            local prefix = value.lucky and "幸运一击" or (value.critical and "暴击" or "命中")
            TriggerCombatVisual(prefix .. " " .. FormatInt(value.lastDamage or 0), value.eventType, isBurst)
        elseif value.kind == "battle_reward" then
            lastLootText_ = "金币+" .. FormatInt(value.gold or 0) .. " 经验+" .. FormatInt(value.exp or 0)
            lastLootIcon_ = ASSETS.items.gold
        elseif value.kind == "equipment_drop" then
            lastLootText_ = tostring(value.name or "装备掉落")
            lastLootIcon_ = ASSETS.items.sword
        elseif value.kind == "chest_reward" then
            lastLootText_ = "宝箱+" .. FormatInt(value.gold or 0)
            lastLootIcon_ = ASSETS.items.chest
        end
    end
    UpdateTopBar()
    if game.page == "play" then UpdatePlayVisuals(0) end
end

UpdatePlayVisuals = function(dt)
    if not playRefs_ or not playRefs_.player then return end
    EnsureRoadEvents()
    animationTime_ = animationTime_ + dt
    combatTimer_ = math.max(0, combatTimer_ - dt)
    combatAnimationTime_ = combatTimer_ > 0 and (combatAnimationTime_ + dt) or 0
    game = GameStateAdapter.GetViewState()

    local current = roadEvents_[1]
    local currentDistance = current and (current.x - presentationX_ - PLAYER_SCREEN_X) or 9999
    local enemyInRange = current and current.kind == "enemy" and currentDistance <= EVENT_TRIGGER_DISTANCE
    local shouldStopForEvent = (currentEventLocked_ and current and current.kind == "enemy" and combatTimer_ > 0) or enemyInRange
    local speed = (game.autoRun and not shouldStopForEvent) and PRESENTATION_SPEED or 0
    presentationX_ = presentationX_ + speed * dt
    currentDistance = current and (current.x - presentationX_ - PLAYER_SCREEN_X) or 9999
    local inTriggerRange = current and currentDistance <= EVENT_TRIGGER_DISTANCE
    if current and inTriggerRange and not currentEventLocked_ then
        if current.kind == "enemy" then
            BeginEnemyAttack(current)
        else
            local pickupText = current.eventType == "chest" and "打开宝箱" or "获得道具"
            TriggerPickupVisual(current.image, current.x - presentationX_, ROAD_Y - LOOT_SIZE + 4, pickupText)
            AdvanceRoadEvent()
        end
    end
    if current and currentEventLocked_ and current.kind == "enemy" and combatTimer_ <= 0 then
        AdvanceRoadEvent()
        current = roadEvents_[1]
        currentDistance = current and (current.x - presentationX_ - PLAYER_SCREEN_X) or 9999
    end

    local bgShift = -(presentationX_ % (BG_TILE_W * 2))
    if playRefs_.bgTiles then
        playRefs_.bgTiles[1]:SetStyle({ left = bgShift })
        playRefs_.bgTiles[2]:SetStyle({ left = bgShift + BG_TILE_W })
        playRefs_.bgTiles[3]:SetStyle({ left = bgShift + BG_TILE_W * 2 })
    end

    local currentEvent = roadEvents_[1]
    local distance = currentEvent and (currentEvent.x - presentationX_ - PLAYER_SCREEN_X) or 9999
    local isAttacking = currentEvent and currentEvent.kind == "enemy" and distance <= EVENT_TRIGGER_DISTANCE
    local isPicking = currentEvent and currentEvent.kind == "loot" and distance <= EVENT_TRIGGER_DISTANCE

    local job = CurrentPlayer()
    local attackFrames = currentAttackFrames_ or job.attackFrames or { job.attack or job.sprite or job.icon }
    local movementFrames = game.autoRun and job.run or job.idle
    local activeParams = isAttacking and ParamsForAttackFrames(attackFrames) or frameEditorParams_.run
    local activeFps = isAttacking and activeParams.fps or (game.autoRun and activeParams.fps or 8)
    local playerImage = isAttacking and FrameAt(attackFrames, activeFps, combatAnimationTime_) or FrameAt(movementFrames, activeFps)
    local walkBob = (game.autoRun and not isAttacking) and math.sin(animationTime_ * 6.0) * 3 or math.sin(animationTime_ * 2.0) * 2
    local walkLean = (game.autoRun and not isAttacking) and math.sin(animationTime_ * 6.0) * 4 or 0
    local attackPulse = isAttacking and math.max(0, math.sin(combatAnimationTime_ * 11.0)) or 0
    local actionLeft = PLAYER_SCREEN_X - (RUN_W - PLAYER_SIZE) * 0.42
    local actionTop = ROAD_Y - RUN_H + 20
    local idleLeft = PLAYER_SCREEN_X
    local idleTop = PLATFORM_PLAYER_Y
    local useActionBox = isAttacking or (game.autoRun and not isPicking)
    local targetLeft = useActionBox and (actionLeft + activeParams.x) or idleLeft
    local targetTop = useActionBox and (actionTop + activeParams.y) or idleTop
    local targetW = useActionBox and activeParams.w or PLAYER_SIZE
    local targetH = useActionBox and activeParams.h or PLAYER_SIZE
    local targetScale = useActionBox and activeParams.scale or 1.0
    local playerStyle = {
        left = targetLeft + walkLean + attackPulse * 3,
        top = targetTop + walkBob - attackPulse * 2,
        width = targetW,
        height = targetH,
        scale = targetScale + (isAttacking and attackPulse * 0.04 or 0),
    }
    if playerImage ~= currentPlayerImage_ then
        playerStyle.backgroundImage = playerImage
        currentPlayerImage_ = playerImage
    end
    playRefs_.player:SetStyle(playerStyle)
    if playRefs_.playerShadow then
        playRefs_.playerShadow:SetStyle({ left = PLAYER_SCREEN_X + 42 + walkLean + attackPulse * 3, top = ROAD_Y - 8 })
    end

    for i, node in ipairs(playRefs_.objects or {}) do
        local event = roadEvents_[i]
        if event then
            local x = event.x - presentationX_
            local w = event.kind == "enemy" and ENEMY_SIZE or LOOT_SIZE
            local h = event.kind == "enemy" and ENEMY_SIZE or LOOT_SIZE
            local top = event.kind == "enemy" and (ROAD_Y - ENEMY_SIZE + 8) or (ROAD_Y - LOOT_SIZE + 4)
            local active = i == 1 and (isAttacking or isPicking)
            local pulse = active and math.sin(animationTime_ * 18) * 5 or 0
            node:SetStyle({
                visible = x > -180 and x < 1180,
                left = x,
                top = top + pulse,
                width = w,
                height = h,
                backgroundImage = event.image,
                opacity = (i == 1 and isAttacking) and 0.86 or 1.0,
                scale = active and 1.05 or 1.0,
            })
        else
            node:SetStyle({ visible = false })
        end
    end

    if playRefs_.event then
        local eventType = currentEvent and currentEvent.eventType or "monster"
        local actionText = isAttacking and "正在攻击" or (isPicking and "正在拾取" or "向右移动")
        playRefs_.event:SetText(actionText .. " / " .. ((EVENT_INFO[eventType] and EVENT_INFO[eventType].name) or "前方道路"))
        playRefs_.event:SetFontColor((EVENT_INFO[eventType] and EVENT_INFO[eventType].color) or C.primary)
    end
    if playRefs_.progress then playRefs_.progress:SetText("第" .. tostring(game.floor or 1) .. "层  距离" .. tostring(math.floor(presentationX_ / 10))) end
    if playRefs_.lootLabel then playRefs_.lootLabel:SetText(lastLootText_) end
    if playRefs_.hpBar then
        playRefs_.hpBar:SetMax((game.stats and game.stats.hp) or 1)
        playRefs_.hpBar:SetValue(game.hp or 1)
    end
    if playRefs_.runButtonLabel then playRefs_.runButtonLabel:SetText(pendingAutoRun_ and "加载中" or (game.autoRun and "刷宝中" or "开始刷宝")) end
    if playRefs_.runButton then
        playRefs_.runButton:SetStyle({ backgroundColor = game.autoRun and C.primary or C.secondary, borderColor = game.autoRun and C.primaryPressed or C.secondaryPressed, opacity = (game.readOnly or playAssetLoading_) and 0.45 or 1.0 })
    end

    if pickupFx_ and playRefs_.pickup then
        pickupFx_.age = pickupFx_.age + dt
        local t = Clamp(pickupFx_.age / pickupFx_.duration, 0, 1)
        local ease = 1 - (1 - t) * (1 - t)
        local x = pickupFx_.startX + (pickupFx_.endX - pickupFx_.startX) * ease
        local y = pickupFx_.startY + (pickupFx_.endY - pickupFx_.startY) * ease - math.sin(t * math.pi) * 58
        local size = LOOT_SIZE * (1.0 - 0.62 * ease)
        playRefs_.pickup:SetStyle({
            visible = t < 1,
            left = x,
            top = y,
            width = size,
            height = size,
            backgroundImage = pickupFx_.image,
            opacity = 1.0 - t * 0.12,
            scale = 1.0 + math.sin(t * math.pi) * 0.28,
        })
        if playRefs_.pickupSpark then
            playRefs_.pickupSpark:SetStyle({
                visible = t > 0.68 and t < 1,
                left = pickupFx_.endX - 10,
                top = pickupFx_.endY - 10,
                opacity = (1 - t) * 1.8,
                scale = 0.7 + t * 0.8,
            })
        end
        if t >= 1 then pickupFx_ = nil end
    else
        if playRefs_.pickup then playRefs_.pickup:SetStyle({ visible = false }) end
        if playRefs_.pickupSpark then playRefs_.pickupSpark:SetStyle({ visible = false }) end
    end

    if playRefs_.enemyDamageLabels then
        for i = #enemyDamageBursts_, 1, -1 do
            local burst = enemyDamageBursts_[i]
            burst.age = burst.age + dt
            if burst.age >= 1.05 then table.remove(enemyDamageBursts_, i) end
        end
        for i, label in ipairs(playRefs_.enemyDamageLabels) do
            local burst = enemyDamageBursts_[i]
            if burst and burst.age >= 0 then
                local age = burst.age
                local alpha = math.floor(255 * math.max(0, 1 - age / 0.95))
                local shake = math.sin(age * 22.0 + (burst.variant or 1)) * 7
                local lift = age * (78 + (burst.variant or 1) * 4)
                local pop = 1.0 + math.max(0, 1 - age * 4.0) * 0.42
                label:SetText(burst.text)
                label:SetStyle({
                    visible = age < 0.95,
                    left = burst.baseX + shake,
                    top = burst.baseY - lift,
                    fontColor = {255, 83, 93, alpha},
                    scale = pop,
                })
            else
                label:SetStyle({ visible = false })
            end
        end
    end

    if floatingText_ and playRefs_.floatLabel then
        floatingText_.age = floatingText_.age + dt
        local alpha = math.floor(255 * math.max(0, 1 - floatingText_.age / 1.0))
        playRefs_.floatLabel:SetText(floatingText_.text)
        playRefs_.floatLabel:SetStyle({ visible = floatingText_.age < 1.0, left = PLAYER_SCREEN_X + 120, top = PLATFORM_PLAYER_Y - 52 - floatingText_.age * 70, fontColor = {255, 217, 61, alpha} })
        if floatingText_.age >= 1.0 then floatingText_ = nil end
    elseif playRefs_.floatLabel then
        playRefs_.floatLabel:SetStyle({ visible = false })
    end
end

local function InstallSafeAreaWrapper()
    if safeAreaInstalled_ then return end
    local oldSetRoot = UI.SetRoot
    UI.SetRoot = function(widget, destroyOld)
        if widget then
            oldSetRoot(UI.SafeAreaView {
                width = "100%",
                height = "100%",
                edges = "vertical",
                nativeMenuInset = true,
                pointerEvents = "box-none",
                children = { widget },
            }, destroyOld)
        else
            oldSetRoot(nil, destroyOld)
        end
    end
    safeAreaInstalled_ = true
end

local function BuildRoot()
    game = GameStateAdapter.GetViewState()
    pageContainer_ = UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, overflow = "hidden", children = { CreatePageContent() } }
    uiRoot_ = UI.Panel {
        width = "100%",
        height = "100%",
        pointerEvents = "box-none",
        children = {
            CreateBackground(),
            UI.Panel {
                width = "100%",
                height = "100%",
                flexDirection = "column",
                children = { CreateTopBar(), pageContainer_, CreateBottomNav() },
            },
        }
    }
    UI.SetRoot(uiRoot_, true)
    if game.page == "play" then
        EnsurePlayAssetsReady(function() UpdatePlayVisuals(0) end)
    end
end

local function InitUI()
    UI.Init({ theme = AppTheme, scale = UI.Scale.DESIGN_RESOLUTION(CONFIG.DesignW, CONFIG.DesignH) })
    InstallSafeAreaWrapper()
    UI.SetOverflowWarnings(false)
end

local function BindServerEvents()
    ServerClient.On("snapshot", function()
        game = GameStateAdapter.GetViewState()
        UpdateTopBar()
        if pageContainer_ then
            RefreshCurrentPage()
        else
            BuildRoot()
        end
        if loadingActive_ then
            SetLoading(math.max(loadingProgress_, 80), "常驻服状态已同步，继续加载资源")
        end
    end)
    ServerClient.On("delta", HandleDeltaVisual)
    ServerClient.On("status", function(payload)
        local state = payload and payload.state or "syncing"
        if loadingActive_ then
            if state == "ready" then SetLoading(95, "已完成加载常驻服状态")
            elseif state == "syncing" then SetLoading(70, "正在加载常驻服状态")
            else SetLoading(60, "正在连接常驻服") end
        else
            game = GameStateAdapter.GetViewState()
            UpdateTopBar()
            if game.page == "play" then UpdatePlayVisuals(0) end
        end
    end)
    ServerClient.On("adminResult", function(result) AdminPanel.HandleResult(result, RequestPageRefresh) end)
    ServerClient.On("disconnected", function()
        if loadingActive_ then SetLoading(45, "正在重连常驻服")
        else game = GameStateAdapter.GetViewState(); UpdateTopBar(); if game.page == "play" then UpdatePlayVisuals(0) end end
    end)
    ServerClient.On("error", function(error)
        UI.Toast.Show(error.reason or "网络数据错误", { duration = 2, variant = "error", position = "bottom" })
        if loadingActive_ then SetLoading(45, "正在重试加载网络数据")
        else game = GameStateAdapter.GetViewState(); UpdateTopBar(); if game.page == "play" then UpdatePlayVisuals(0) end end
    end)
end

function GameView.Start()
    graphics.windowTitle = CONFIG.Title
    InitUI()
    ProbeOptionalFonts()
    game = GameStateAdapter.GetViewState()
    BuildRoot()
    StartDwpLoadingOverlay()
    BindServerEvents()
    local ok, reason = ServerClient.Start()
    if not ok then
        SetLoading(45, reason or "正在重试连接常驻服")
    end
    SubscribeToEvent("Update", function(eventType, eventData) GameView.HandleUpdate(eventType, eventData) end)
    print("=== " .. CONFIG.Title .. " client started with DWP loading ===")
end

function GameView.Stop()
    UnsubscribeFromEvent("Update")
    if dwpObserverId_ then
        cache:StopObservingDownloads(dwpObserverId_)
        dwpObserverId_ = nil
    end
    ServerClient.Stop()
    UI.Shutdown()
end

---@param eventType StringHash|string
---@param eventData VariantMap
function GameView.HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")
    if loadingActive_ then
        UpdateLoadingSpinner(dt)
        if loadingHideDelay_ then
            loadingHideDelay_ = loadingHideDelay_ - dt
            if loadingHideDelay_ <= 0 then
                HideLoadingOverlay()
            end
        end
    end
    local state = GameStateAdapter.GetViewState()
    game = state
    if game.page == "play" then UpdatePlayVisuals(dt) end
    if game.page == "frameEditor" then UpdateFrameEditorVisuals(dt) end
    if needsFullRebuild_ then
        needsFullRebuild_ = false
        needsPageRefresh_ = false
        BuildRoot()
    elseif needsPageRefresh_ then
        needsPageRefresh_ = false
        RefreshCurrentPage()
    end
end

return GameView
