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
local equipmentScrollY_ = 0
local equipmentPageScrollY_ = 0
local topRefs_ = {}
local navRefs_ = {}
---@type table<string, any>
local playRefs_ = {}
local loadingDots_ = {}
local loadingPercentLabel_ = nil
local loadingMessageLabel_ = nil
local loadingProgressFill_ = nil
local loadingActive_ = false
local loadingOverlay_ = nil
local playAssetsReady_ = false
local playAssetLoading_ = false
local textureCache_ = {}
local pendingAutoRun_ = nil
local requestedAutoRun_ = nil
local sessionAutoStartAttempted_ = false
local dwpObserverId_ = nil
local loadingHideDelay_ = nil
local initialSnapshotReceived_ = false
local initialDwpFinished_ = false
local loadingProgress_ = 0
local loadingMessage_ = "正在加载像素字体"
local loadingTimer_ = 0
local SetLoading = nil
local ShowLoadingOverlay = nil
local EnsurePlayAssetsReady = nil
local LAYOUT_CHECK_INTERVAL = 0.25
local layoutState_ = {
    timer = 0,
    metrics = {
        physicalWidth = 0,
        physicalHeight = 0,
        safeLeft = 0,
        safeTop = 0,
        safeRight = 0,
        safeBottom = 0,
        safeWidth = 1,
        safeHeight = 1,
        scale = 1,
        key = "",
    },
}
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
    bg = "image/brawlforge_side_scroller_route_bg_clean_20260718113310.png",
    bgMirror = "image/brawlforge_side_scroller_route_bg_clean_20260718113310.png",
    player = {
        icon = "image/brawlforge_punk_hero_fullbody_v2_20260720090901.png",
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
        topFrame = "image/ui/brawlforge_v4_top_full_bar_clean.png",
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
        inventoryTitle = "image/ui/inventory/title_panel.png",
        inventoryDetail = "image/ui/inventory/detail_panel_tall.png",
        inventorySlotEmpty = "image/ui/inventory/slot_empty.png",
        inventorySlotCommon = "image/ui/inventory/slot_common.png",
        inventorySlotRare = "image/ui/inventory/slot_rare.png",
        inventorySlotEpic = "image/ui/inventory/slot_epic.png",
        inventorySlotLegend = "image/ui/inventory/slot_legend.png",
        inventorySlotMyth = "image/ui/inventory/slot_myth.png",
        inventorySlotSelected = "image/ui/inventory/slot_selected.png",
        inventoryTabOn = "image/ui/inventory/tab_on.png",
        inventoryTabOff = "image/ui/inventory/tab_off.png",
        inventoryActionBlue = "image/ui/inventory/action_blue.png",
        inventoryActionRed = "image/ui/inventory/action_red.png",
        inventoryActionGold = "image/ui/inventory/action_gold.png",
        inventoryItemCard = "image/ui/inventory/item_card.png",
        inventoryEmptyState = "image/inventory_empty_state_20260720075957.png",
        inventoryItemCardSelected = "image/ui/inventory/item_card_selected.png",
        playHpFrame = "image/brawlforge_play_hp_frame_cropped.png",
        panelLarge = "image/ui/generated/panel_940x320.png",
        panelCompact = "image/ui/generated/panel_940x180.png",
        infoBarBlue = "image/ui/generated/info_bar_blue_520x76.png",
        infoBarGold = "image/ui/generated/info_bar_gold_520x76.png",
        lootBarGold = "image/ui/generated/loot_bar_gold_520x60.png",
        detailRow = "image/ui/generated/detail_row_520x38.png",
        statusBar = "image/ui/generated/status_bar_448x60.png",
        floorBadge = "image/ui/generated/floor_badge_150x60.png",
        equipSlot = "image/ui/generated/equip_slot_compact.png",
        equipSlotSelected = "image/ui/generated/equip_slot_compact_selected.png",
        equipmentSlotIcons = {
            weapon = "image/ui/equipment_slots/weapon.png",
            shoulder = "image/ui/equipment_slots/shoulder.png",
            coat = "image/ui/equipment_slots/coat.png",
            pants = "image/ui/equipment_slots/pants.png",
            belt = "image/ui/equipment_slots/belt.png",
            shoes = "image/ui/equipment_slots/shoes.png",
            bracelet = "image/ui/equipment_slots/bracelet.png",
            necklace = "image/ui/equipment_slots/necklace.png",
            ring = "image/ui/equipment_slots/ring.png",
            support = "image/ui/equipment_slots/support.png",
            magicstone = "image/ui/equipment_slots/magicstone.png",
            earring = "image/ui/equipment_slots/earring.png",
        },
        editorTabOn = "image/ui/generated/tab_on_170x62.png",
        editorTabOff = "image/ui/generated/tab_off_170x62.png",
        editorToggleOn = "image/ui/generated/toggle_on_170x58.png",
        editorToggleOff = "image/ui/generated/toggle_off_170x58.png",
        buttonBlue = "image/ui/generated/button_blue_150x46.png",
        buttonBlueWide = "image/ui/generated/button_blue_190x50.png",
        buttonGreen = "image/ui/generated/button_green_150x50.png",
        buttonPurple = "image/ui/generated/button_purple_150x50.png",
        buttonRed = "image/ui/generated/button_red_150x50.png",
        selectionFrame = "image/ui/generated/selection_frame_180x180.png",
        referenceFrame = "image/ui/generated/reference_frame_420x210.png",
        progressTrackLoad = "image/ui/generated/progress_track_720x30.png",
        progressFillLoad = "image/ui/generated/progress_fill_blue_720x30.png",
        progressTrackHp = "image/ui/generated/progress_track_310x24.png",
        progressFillHp = "image/ui/generated/progress_fill_red_310x24.png",
        progressTrackSet = "image/ui/generated/progress_track_560x22.png",
        progressFillSet = "image/ui/generated/progress_fill_blue_560x22.png",
        characterShadow = "image/ui/generated/character_shadow_118x14.png",
        pickupSpark = "image/ui/generated/pickup_spark_82x82.png",
        loadingDot = "image/ui/generated/loading_dot_24x24.png",
        screenOverlay = "image/ui/generated/screen_overlay_1080x1920.png",
    },
    enemies = {
        slime = "image/punk_mech_enemy_grunt_alt_20260718113945.png",
        goblin = "image/punk_mech_enemy_grunt_alt_20260718113945.png",
        skeleton = "image/punk_mech_enemy_elite_alt_20260718113641.png",
        boss = "image/punk_mech_enemy_boss_alt_20260718113640.png",
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
local ENEMY_SIZE = 190
local LOOT_SIZE = 96
local PLAYER_SCREEN_X = 180
local BG_TILE_W = 1080
local BG_TILE_TOP = 0
local BG_TILE_H = 1580
local ROAD_Y = 1220
local PLAYER_FOOT_OFFSET = 21
local LOOT_FOOT_OFFSET = 8
local PLATFORM_PLAYER_Y = ROAD_Y - RUN_H + PLAYER_FOOT_OFFSET
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

local function QuantizeLayoutValue(value, step)
    return math.floor((value or 0) / (step or 1) + 0.5) * (step or 1)
end

local function ReadLayoutMetrics()
    local physicalWidth = graphics:GetWidth()
    local physicalHeight = graphics:GetHeight()
    local safeLeft = 0
    local safeTop = 0
    local safeRight = 0
    local safeBottom = 0
    local safeRect = GetSafeAreaInsets(false)
    if safeRect then
        safeLeft = math.max(0, safeRect.min.x or 0)
        safeTop = math.max(0, safeRect.min.y or 0)
        safeRight = math.max(0, safeRect.max.x or 0)
        safeBottom = math.max(0, safeRect.max.y or 0)
    end

    local nativeSdk = rawget(_G, "sdk")
    if nativeSdk and nativeSdk.GetNativeExitMenuRect then
        local menuRect = nativeSdk:GetNativeExitMenuRect()
        if menuRect then
            local menuLeft = (menuRect.left or 0) * physicalWidth
            local menuTop = (menuRect.top or 0) * physicalHeight
            local menuRight = (menuRect.right or 0) * physicalWidth
            local menuBottom = (menuRect.bottom or 0) * physicalHeight
            if menuRect.left <= 0.25 then
                safeLeft = math.max(safeLeft, menuRight)
            else
                safeRight = math.max(safeRight, physicalWidth - menuLeft)
            end
            if menuRect.top <= 0.25 then
                safeTop = math.max(safeTop, menuBottom)
            else
                safeBottom = math.max(safeBottom, physicalHeight - menuTop)
            end
        end
    end

    safeLeft = Clamp(safeLeft, 0, physicalWidth)
    safeTop = Clamp(safeTop, 0, physicalHeight)
    safeRight = Clamp(safeRight, 0, physicalWidth - safeLeft)
    safeBottom = Clamp(safeBottom, 0, physicalHeight - safeTop)
    local safeWidth = math.max(1, physicalWidth - safeLeft - safeRight)
    local safeHeight = math.max(1, physicalHeight - safeTop - safeBottom)
    local scale = math.min(safeWidth / CONFIG.designWidth, safeHeight / CONFIG.designHeight)
    scale = math.max(0.1, scale)

    local key = table.concat({
        math.floor(physicalWidth + 0.5),
        math.floor(physicalHeight + 0.5),
        math.floor(scale * 1000 + 0.5),
        math.floor(safeLeft + 0.5),
        math.floor(safeTop + 0.5),
        math.floor(safeRight + 0.5),
        math.floor(safeBottom + 0.5),
    }, ":")
    local changed = key ~= layoutState_.metrics.key
    layoutState_.metrics = {
        physicalWidth = physicalWidth,
        physicalHeight = physicalHeight,
        safeLeft = safeLeft,
        safeTop = safeTop,
        safeRight = safeRight,
        safeBottom = safeBottom,
        safeWidth = safeWidth,
        safeHeight = safeHeight,
        scale = scale,
        key = key,
    }
    return changed
end

local function CheckLayoutMetrics(dt)
    local physicalWidth = graphics:GetWidth()
    local physicalHeight = graphics:GetHeight()
    layoutState_.timer = layoutState_.timer + (dt or 0)
    local metrics = layoutState_.metrics
    local sizeChanged = physicalWidth ~= metrics.physicalWidth or physicalHeight ~= metrics.physicalHeight
    if not sizeChanged and layoutState_.timer < LAYOUT_CHECK_INTERVAL then return end
    layoutState_.timer = 0
    if ReadLayoutMetrics() and uiRoot_ then
        UI.SetScale(layoutState_.metrics.scale)
        needsFullRebuild_ = true
    end
end

local function SafeAreaPadding()
    local scale = math.max(0.1, layoutState_.metrics.scale)
    return {
        left = layoutState_.metrics.safeLeft / scale,
        top = layoutState_.metrics.safeTop / scale,
        right = layoutState_.metrics.safeRight / scale,
        bottom = layoutState_.metrics.safeBottom / scale,
    }
end

local function ShortenText(text, maxChars)
    text = tostring(text or "")
    maxChars = maxChars or 8
    local count = 0
    local pos = 1
    while pos <= #text do
        local b = string.byte(text, pos)
        local step = 1
        if b >= 240 then step = 4
        elseif b >= 224 then step = 3
        elseif b >= 192 then step = 2 end
        if count + 1 > maxChars then break end
        count = count + 1
        pos = pos + step
    end
    if pos <= #text then
        return string.sub(text, 1, pos - 1) .. "…"
    end
    return text
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

local function CompactTxt(text, size, color, props)
    return UI.Label(CopyProps({
        text = text,
        fontSize = size or 16,
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

local function ImageProgress(width, height, value, maxValue, trackImage, fillImage)
    local ratio = Clamp((value or 0) / math.max(1, maxValue or 1), 0, 1)
    local fillClip = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = math.floor(width * ratio),
        height = height,
        overflow = "hidden",
        pointerEvents = "none",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                width = width,
                height = height,
                backgroundImage = fillImage,
                backgroundFit = "contain",
                pointerEvents = "none",
            }
        }
    }
    local root = UI.Panel {
        width = width,
        height = height,
        position = "relative",
        flexShrink = 0,
        backgroundImage = trackImage,
        backgroundFit = "contain",
        children = { fillClip },
    }
    return root, fillClip
end

local function SetImageProgress(fillClip, width, value, maxValue)
    if not fillClip then return end
    local ratio = Clamp((value or 0) / math.max(1, maxValue or 1), 0, 1)
    fillClip:SetStyle({ width = math.floor(width * ratio) })
end

local function ImageButton(text, width, height, image, onClick, disabled)
    return UI.Panel {
        width = width,
        height = height,
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
            CompactTxt(text, 20, C.text, {
                width = "100%",
                height = height,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            })
        }
    }
end

local function PixelPanel(props)
    return UI.Panel(CopyProps({
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        padding = 20,
        gap = 12,
        overflow = "hidden",
    }, props))
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

local function EnemyFootOffset(eventType)
    return eventType == "boss" and 7 or 12
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

local function ClearCombatPresentation(advanceLockedEvent)
    if advanceLockedEvent and currentEventLocked_ and roadEvents_[1] and roadEvents_[1].kind == "enemy" then
        AdvanceRoadEvent()
    else
        currentEventLocked_ = false
        currentAttackFrames_ = nil
    end
    combatTimer_ = 0
    combatAnimationTime_ = 0
    hitBurst_ = false
    enemyDamageBursts_ = {}
    floatingText_ = nil
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
    requestedAutoRun_ = enabled
    pendingAutoRun_ = true
    if enabled then
        EnsurePlayAssetsReady(function()
            ServerClient.AutoRun(true, function(response)
                pendingAutoRun_ = nil
                if not response or not response.ok then
                    requestedAutoRun_ = nil
                    ActionResult(response)
                    return
                end
                ServerClient.RequestSnapshot(function(snapshotResponse)
                    if not snapshotResponse or not snapshotResponse.ok then
                        print("[Play] auto-run enabled; waiting for authoritative delta")
                    end
                end)
            end)
        end)
    else
        ClearCombatPresentation(false)
        ServerClient.AutoRun(false, function(response)
            pendingAutoRun_ = nil
            if not response or not response.ok then
                requestedAutoRun_ = nil
                ActionResult(response)
                return
            end
            requestedAutoRun_ = false
            ServerClient.RequestSnapshot()
        end)
    end
end
local actionFns_ = {}
actionFns_.CollectOffline = function() ServerClient.CollectOffline(ActionResult) end
actionFns_.EquipItem = function(item)
    if item and item.id then
        selectedSlot_ = item.slot or selectedSlot_
        ServerClient.Equip(item.id, ActionResult)
    end
end
actionFns_.UnequipSlot = function(slotId)
    if slotId then
        selectedSlot_ = slotId
        ServerClient.Unequip(slotId, ActionResult)
    end
end
actionFns_.AutoEquipBest = function() ServerClient.AutoEquip(ActionResult) end
actionFns_.DecomposeByRank = function(maxRank) ServerClient.Decompose(maxRank, ActionResult) end
actionFns_.StrengthenSelected = function() ServerClient.Strengthen(selectedSlot_, ActionResult) end
actionFns_.StarSelected = function() ServerClient.Star(selectedSlot_, ActionResult) end

local CollectOffline = actionFns_.CollectOffline
local EquipItem = actionFns_.EquipItem
local AutoEquipBest = actionFns_.AutoEquipBest
local DecomposeByRank = actionFns_.DecomposeByRank
local StrengthenSelected = actionFns_.StrengthenSelected
local StarSelected = actionFns_.StarSelected

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
    topRefs_.floor = Txt("层  第" .. tostring(game.floor or 1) .. "层", 22, C.focus, { whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    topRefs_.power = Txt("战力  " .. FormatInt(game.stats.power), 22, C.gold, { whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    topRefs_.gold = Txt("金币  " .. FormatInt(game.gold), 22, C.gold, { whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    topRefs_.fragments = Txt("碎片  " .. FormatInt(game.fragments), 22, C.secondary, { whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    local function ResourceText(x, valueRef)
        return UI.Panel {
            position = "absolute",
            left = x,
            top = 222,
            width = 210,
            height = 42,
            alignItems = "center",
            justifyContent = "center",
            overflow = "hidden",
            children = { valueRef }
        }
    end

    return UI.Panel {
        width = "100%",
        height = 310,
        flexShrink = 0,
        position = "relative",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                width = 1080,
                height = 288,
                backgroundImage = ASSETS.ui.topFrame,
                backgroundFit = "contain",
            },
            Txt("无尽深渊", 28, C.text, {
                position = "absolute",
                left = 80,
                top = 58,
                width = 270,
                height = 72,
                whiteSpace = "nowrap",
                textAlign = "center",
                textStroke = { width = 3, color = "#000000" },
            }),
            Txt("解放双手，自动推进探索", 21, C.textSecondary, {
                position = "absolute",
                left = 458,
                top = 74,
                width = 520,
                height = 48,
                whiteSpace = "nowrap",
                textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
            }),
            ResourceText(86, topRefs_.floor),
            ResourceText(316, topRefs_.power),
            ResourceText(546, topRefs_.gold),
            ResourceText(776, topRefs_.fragments),
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
        if type(path) == "string" then
            paths[#paths + 1] = path
        elseif type(path) == "table" then
            for _, nestedPath in pairs(path) do
                Add(nestedPath)
            end
        end
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
        if initialSnapshotReceived_ and initialDwpFinished_ then
            loadingHideDelay_ = 0.2
        end
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
                if initialSnapshotReceived_ and initialDwpFinished_ then
                    loadingHideDelay_ = 0.2
                end
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
                    if initialSnapshotReceived_ and initialDwpFinished_ then
                        loadingHideDelay_ = 0.2
                    end
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
        backgroundFit = "contain",
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
                    UI.Panel { position = "absolute", left = 0, top = 124, width = 300, height = 44, clickable = not game.readOnly, opacity = game.readOnly and 0.45 or 1.0, alignItems = "center", justifyContent = "center", onClick = function() if not game.readOnly then actionFns_.CollectOffline() end end, children = { Txt("领取离线", 23, C.text, { position = "absolute", left = -4, top = 9, width = "100%", textAlign = "center", textStroke = { width = 3, color = "#000000" } }) } },
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

local InventoryView = require("client.InventoryView")

local function BuildInventoryContext()
    return {
        UI = UI,
        ui = ui,
        C = C,
        ASSETS = ASSETS,
        RARITIES = RARITIES,
        SET_ORDER = SET_ORDER,
        SETS = SETS,
        SLOTS = SLOTS,
        CATEGORIES = CATEGORIES,
        inventoryEmptyState = ASSETS.ui.inventoryEmptyState,
        characterPortrait = ASSETS.player.icon,
        playerNickname = game.playerNickname,
        game = game,
        getSelectedInventoryId = function() return selectedInventoryId_ end,
        getSelectedSlot = function() return selectedSlot_ end,
        getSelectedCategory = function() return selectedCategory_ end,
        setSelectedInventoryId = function(value) selectedInventoryId_ = value end,
        setSelectedSlot = function(value) selectedSlot_ = value end,
        setSelectedCategory = function(value) selectedCategory_ = value end,
        getEquipmentScrollY = function() return equipmentScrollY_ end,
        setEquipmentScrollY = function(value) equipmentScrollY_ = value or 0 end,
        getEquipmentPageScrollY = function() return equipmentPageScrollY_ end,
        setEquipmentPageScrollY = function(value) equipmentPageScrollY_ = value or 0 end,
        requestPageRefresh = RequestPageRefresh,
        equipItem = actionFns_.EquipItem,
        unequipSlot = actionFns_.UnequipSlot,
        decomposeByRank = actionFns_.DecomposeByRank,
        autoEquipBest = actionFns_.AutoEquipBest,
        strengthenSelected = actionFns_.StrengthenSelected,
        starSelected = actionFns_.StarSelected,
        readOnly = game.readOnly,
        rarityColor = RarityColor,
        rarityName = RarityName,
        slotName = SlotName,
        itemPower = ItemPower,
        itemImage = ItemImage,
        isEquipped = IsEquipped,
        getItemById = GetItemById,
        shortenText = ShortenText,
        compactTxt = CompactTxt,
        txt = Txt,
        imageProgress = ImageProgress,
        imageButton = ImageButton,
        pixelPanel = PixelPanel,
        sectionTitle = SectionTitle,
        formatInt = FormatInt,
    }
end

local function BuildInventoryPage()
    return InventoryView.BuildInventoryPage(BuildInventoryContext())
end

local function BuildEquipmentPage()
    return InventoryView.BuildEquipmentPage(BuildInventoryContext())
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
    props = props or {}
    local variant = props.variant or "primary"
    local image = ASSETS.ui.buttonBlue
    if variant == "secondary" then image = ASSETS.ui.buttonPurple
    elseif variant == "success" then image = ASSETS.ui.buttonGreen
    elseif variant == "danger" then image = ASSETS.ui.buttonRed end
    return ImageButton(text, props.width or 118, props.height or 58, image, onClick, props.disabled == true)
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
        backgroundImage = visible and ASSETS.ui.editorToggleOn or ASSETS.ui.editorToggleOff,
        backgroundFit = "contain",
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
            backgroundImage = active and ASSETS.ui.editorTabOn or ASSETS.ui.editorTabOff,
            backgroundFit = "contain",
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
    frameEditorRefs_.reference = UI.Panel { position = "absolute", left = 330, top = 390, width = RUN_W, height = RUN_H, backgroundImage = ASSETS.ui.referenceFrame, backgroundFit = "contain" }
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
        backgroundImage = ASSETS.bg,
        backgroundFit = "cover",
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
    playRefs_.bgTiles[1] = UI.Panel { position = "absolute", left = 0, top = BG_TILE_TOP, width = BG_TILE_W, height = BG_TILE_H, backgroundImage = ASSETS.bg, backgroundFit = "cover" }
    playRefs_.bgTiles[2] = UI.Panel { position = "absolute", left = BG_TILE_W, top = BG_TILE_TOP, width = BG_TILE_W, height = BG_TILE_H, backgroundImage = ASSETS.bgMirror, backgroundFit = "cover" }
    playRefs_.bgTiles[3] = UI.Panel { position = "absolute", left = BG_TILE_W * 2, top = BG_TILE_TOP, width = BG_TILE_W, height = BG_TILE_H, backgroundImage = ASSETS.bg, backgroundFit = "cover" }
    playRefs_.playerShadow = UI.Panel { position = "absolute", left = PLAYER_SCREEN_X + 168, top = ROAD_Y - 12, width = 118, height = 14, backgroundImage = ASSETS.ui.characterShadow, backgroundFit = "contain" }
    playRefs_.player = UI.Panel { position = "absolute", left = PLAYER_SCREEN_X, top = PLATFORM_PLAYER_Y, width = RUN_W, height = RUN_H, backgroundImage = CurrentPlayer().sprite or CurrentPlayer().icon, backgroundFit = "contain" }

    for i = 1, EVENT_VIEW_COUNT do
        local obj = UI.Panel { position = "absolute", left = 0, top = 0, width = ENEMY_SIZE, height = ENEMY_SIZE, backgroundImage = ASSETS.enemies.slime, backgroundFit = "contain", visible = true }
        playRefs_.objects[i] = obj
    end

    playRefs_.pickup = UI.Panel { position = "absolute", left = 0, top = 0, width = LOOT_SIZE, height = LOOT_SIZE, backgroundImage = ASSETS.items.crystal, backgroundFit = "contain", visible = false }
    playRefs_.pickupSpark = UI.Panel { position = "absolute", left = 0, top = 0, width = 82, height = 82, backgroundImage = ASSETS.ui.pickupSpark, backgroundFit = "contain", visible = false }
    playRefs_.floatLabel = Txt("", 30, C.gold, { position = "absolute", left = 0, top = 0, width = 360, textAlign = "center", visible = false, textStroke = { width = 2, color = "#000000" } })
    playRefs_.enemyDamageLabels = {}
    for i = 1, #ATTACK_HIT_TIMINGS do
        playRefs_.enemyDamageLabels[i] = Txt("", 34, C.hp, { position = "absolute", left = 0, top = 0, width = 360, textAlign = "center", visible = false, textStroke = { width = 3, color = "#000000" } })
    end
    playRefs_.event = CompactTxt("向右移动", 20, C.primary, { width = "100%" })
    playRefs_.progress = CompactTxt("第1层", 20, C.focus, {})
    playRefs_.lootLabel = CompactTxt(lastLootText_, 18, C.gold, { width = "100%" })
    local hpProgress
    hpProgress, playRefs_.hpFill = ImageProgress(310, 24, game.hp or 1, game.stats.hp or 1, ASSETS.ui.progressTrackHp, ASSETS.ui.progressFillHp)
    playRefs_.hpBar = hpProgress
    playRefs_.runButtonLabel = CompactTxt(game.autoRun and "刷宝中" or "开始刷宝", 20, C.text, { width = "100%", textAlign = "center", textStroke = { width = 2, color = "#000000" } })

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
        position = "absolute",
        right = 26,
        top = 42,
        width = 230,
        height = 72,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = "image/brawlforge_play_autorun_button_flat_20260718124728.png",
        backgroundFit = "contain",
        onClick = function()
            if not game.readOnly and not playAssetLoading_ and not pendingAutoRun_ then
                local currentAutoRun = game.autoRun
                if requestedAutoRun_ ~= nil then currentAutoRun = requestedAutoRun_ end
                SetAutoRun(not currentAutoRun)
            end
        end,
        children = { playRefs_.runButtonLabel },
    }
    playRefs_.runButton = runButton

    local root = UI.Panel {
        width = "100%",
        height = "100%",
        position = "relative",
        overflow = "hidden",
        backgroundImage = ASSETS.bg,
        backgroundFit = "cover",
        children = sceneChildren,
    }

    playRefs_.event:SetStyle({ position = "absolute", left = 22, top = 17, width = 406, textAlign = "center" })
    local statusFrame = UI.Panel {
        position = "absolute", left = 26, top = 42, width = 448, height = 60,
        backgroundImage = ASSETS.ui.statusBar, backgroundFit = "contain",
        children = { playRefs_.event },
    }

    playRefs_.progress:SetStyle({ position = "absolute", left = 0, top = 19, width = 150, textAlign = "center" })
    local floorBadge = UI.Panel {
        position = "absolute", left = 476, top = 42, width = 150, height = 60,
        backgroundImage = ASSETS.ui.floorBadge, backgroundFit = "contain",
        children = { playRefs_.progress },
    }

    playRefs_.lootLabel:SetStyle({ visible = false })

    local hpFrame = UI.Panel {
        position = "absolute", left = 30, top = 174, width = 545, height = 168,
        backgroundImage = ASSETS.ui.playHpFrame, backgroundFit = "contain",
        children = {
            Txt("生命", 24, C.hp, { position = "absolute", left = 74, top = 55, width = 92, textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
            UI.Panel { position = "absolute", left = 176, top = 66, width = 310, height = 28, children = { playRefs_.hpBar } },
        }
    }

    playRefs_.lootTrayIcon = UI.Panel { position = "absolute", left = 10, top = 8, width = 44, height = 44, backgroundImage = lastLootIcon_ or ASSETS.items.chest, backgroundFit = "contain" }
    playRefs_.lootTrayLabel = CompactTxt(lastLootText_, 18, C.gold, { position = "absolute", left = 68, top = 18, width = 410, textStroke = { width = 2, color = "#000000" } })
    local lootTray = UI.Panel {
        position = "absolute", left = 26, bottom = 20, width = 520, height = 60,
        backgroundImage = ASSETS.ui.lootBarGold, backgroundFit = "contain",
        children = { playRefs_.lootTrayIcon, playRefs_.lootTrayLabel },
    }

    root:AddChild(statusFrame)
    root:AddChild(floorBadge)
    root:AddChild(hpFrame)
    root:AddChild(runButton)
    root:AddChild(lootTray)
    UpdatePlayVisuals(0)
    return root
end

local function CreateMarketPage()
    return UI.Panel {
        width = "100%",
        height = "100%",
        alignItems = "center",
        justifyContent = "center",
        children = {
            UI.Panel {
                width = 860,
                height = 420,
                backgroundImage = ASSETS.ui.panelLarge,
                backgroundFit = "sliced",
                backgroundSlice = { 12, 12, 12, 12 },
                alignItems = "center",
                justifyContent = "center",
                gap = 18,
                children = {
                    Txt("市场", 36, C.text, { width = "100%", textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
                    CompactTxt("市场功能暂未开放", 24, C.textSecondary, { width = "100%", textAlign = "center" }),
                },
            },
        },
    }
end

local function CreatePageContent()
    if game.page == "admin" and game.isAdmin then return AdminPanel.Build(UI, { onChanged = RequestPageRefresh, readOnly = game.readOnly }) end
    if game.page == "bag" then return BuildInventoryPage() end
    if game.page == "equip" then
        if type(game.playerNickname) ~= "string" or game.playerNickname == "" then
            return UI.Panel {
                width = "100%",
                height = "100%",
                alignItems = "center",
                justifyContent = "center",
                children = { CompactTxt("正在同步 Tap 昵称…", 24, C.textSecondary, { width = "100%", textAlign = "center" }) },
            }
        end
        return BuildEquipmentPage()
    end
    if game.page == "play" then return CreatePlayPage() end
    if game.page == "market" then return CreateMarketPage() end
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
    local leavingPlay = game.page == "play" and pageId ~= "play"
    if leavingPlay then ClearCombatPresentation(true) end
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
        { id = "market", name = "市场" },
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
            backgroundImage = ASSETS.ui.navSelected,
            backgroundFit = "contain",
            imageTint = C.focus,
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
    local loadingProgress
    loadingProgress, loadingProgressFill_ = ImageProgress(720, 30, loadingProgress_, 100, ASSETS.ui.progressTrackLoad, ASSETS.ui.progressFillLoad)
    local dotLayer = UI.Panel { width = 240, height = 240, position = "relative" }
    for i = 1, 12 do
        local dot = UI.Panel { position = "absolute", left = 108, top = 108, width = 24, height = 24, backgroundImage = ASSETS.ui.loadingDot, backgroundFit = "contain" }
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
        backgroundImage = ASSETS.ui.screenOverlay,
        backgroundFit = "contain",
        alignItems = "center",
        justifyContent = "center",
        paddingLeft = 80,
        paddingRight = 80,
        children = {
            PixelPanel {
                width = 940,
                height = 760,
                alignItems = "center",
                justifyContent = "center",
                gap = 32,
                children = {
                    Txt(CONFIG.Title, 34, C.text, { width = "100%", textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
                    Txt("资源加载中", 24, C.textDim, { width = "100%", textAlign = "center" }),
                    dotLayer,
                    loadingPercentLabel_,
                    loadingMessageLabel_,
                    loadingProgress,
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
            initialDwpFinished_ = true
            SetLoading(100, "资源加载完成")
            if initialSnapshotReceived_ then
                loadingHideDelay_ = 0.35
            end
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
    SetImageProgress(loadingProgressFill_, 720, loadingProgress_, 100)
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
            opacity = alpha / 255,
            scale = 0.7 + 0.3 * (i / 12),
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
        elseif value.kind == "auto_run_changed" then
            requestedAutoRun_ = nil
            pendingAutoRun_ = nil
            if value.enabled == false then ClearCombatPresentation(false) end
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
    if requestedAutoRun_ ~= nil and game.autoRun == requestedAutoRun_ then
        requestedAutoRun_ = nil
        pendingAutoRun_ = nil
    end

    local visualAutoRun = game.autoRun
    if requestedAutoRun_ ~= nil then visualAutoRun = requestedAutoRun_ end
    local current = roadEvents_[1]
    local currentDistance = current and (current.x - presentationX_ - PLAYER_SCREEN_X) or 9999
    local enemyInRange = current and current.kind == "enemy" and currentDistance <= EVENT_TRIGGER_DISTANCE
    local shouldStopForEvent = (currentEventLocked_ and current and current.kind == "enemy" and combatTimer_ > 0) or enemyInRange
    local speed = (visualAutoRun and not shouldStopForEvent) and PRESENTATION_SPEED or 0
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
    local isAttacking = currentEventLocked_ and combatTimer_ > 0 and currentEvent and currentEvent.kind == "enemy" and distance <= EVENT_TRIGGER_DISTANCE
    local isPicking = currentEvent and currentEvent.kind == "loot" and distance <= EVENT_TRIGGER_DISTANCE

    local job = CurrentPlayer()
    local attackFrames = currentAttackFrames_ or job.attackFrames or { job.attack or job.sprite or job.icon }
    local movementFrames = visualAutoRun and job.run or job.idle
    local activeParams = isAttacking and ParamsForAttackFrames(attackFrames) or frameEditorParams_.run
    local activeFps = isAttacking and activeParams.fps or (visualAutoRun and activeParams.fps or 8)
    local playerImage = isAttacking and FrameAt(attackFrames, activeFps, combatAnimationTime_) or FrameAt(movementFrames, activeFps)
    local walkBob = (visualAutoRun and not isAttacking) and math.sin(animationTime_ * 6.0) * 3 or math.sin(animationTime_ * 2.0) * 2
    local walkLean = (visualAutoRun and not isAttacking) and math.sin(animationTime_ * 6.0) * 4 or 0
    local attackPulse = isAttacking and math.max(0, math.sin(combatAnimationTime_ * 11.0)) or 0
    local actionLeft = PLAYER_SCREEN_X - (RUN_W - PLAYER_SIZE) * 0.42
    local actionTop = ROAD_Y - RUN_H + 20
    local idleLeft = PLAYER_SCREEN_X
    local idleTop = PLATFORM_PLAYER_Y
    local useActionBox = isAttacking or not isPicking
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
            local top = event.kind == "enemy" and (ROAD_Y - ENEMY_SIZE + EnemyFootOffset(event.eventType)) or (ROAD_Y - LOOT_SIZE + LOOT_FOOT_OFFSET)
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
    if playRefs_.lootTrayLabel then playRefs_.lootTrayLabel:SetText(lastLootText_) end
    if playRefs_.lootTrayIcon and lastLootIcon_ then playRefs_.lootTrayIcon:SetStyle({ backgroundImage = lastLootIcon_ }) end
    if playRefs_.hpFill then
        SetImageProgress(playRefs_.hpFill, 310, game.hp or 1, (game.stats and game.stats.hp) or 1)
    end
    if playRefs_.runButtonLabel then playRefs_.runButtonLabel:SetText(pendingAutoRun_ and "同步中" or (visualAutoRun and "刷宝中" or "开始刷宝")) end
    if playRefs_.runButton then
        playRefs_.runButton:SetStyle({ opacity = (game.readOnly or playAssetLoading_) and 0.45 or 1.0 })
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
            local padding = SafeAreaPadding()
            oldSetRoot(UI.Panel {
                width = "100%",
                height = "100%",
                position = "relative",
                pointerEvents = "box-none",
                children = {
                    UI.Panel {
                        position = "absolute",
                        left = padding.left,
                        top = padding.top,
                        right = padding.right,
                        bottom = padding.bottom,
                        alignItems = "center",
                        justifyContent = "center",
                        pointerEvents = "box-none",
                        children = {
                            UI.Panel {
                                width = CONFIG.designWidth,
                                height = CONFIG.designHeight,
                                flexShrink = 0,
                                pointerEvents = "box-none",
                                children = { widget },
                            },
                        },
                    },
                },
            }, destroyOld)
        else
            oldSetRoot(nil, destroyOld)
        end
    end
    safeAreaInstalled_ = true
end

local function BuildRoot()
    game = GameStateAdapter.GetViewState()
    local initialPageChildren = {}
    if initialSnapshotReceived_ then
        initialPageChildren[1] = CreatePageContent()
    end
    pageContainer_ = UI.Panel { width = "100%", height = "100%", flexGrow = 1, flexBasis = 0, alignSelf = "stretch", overflow = "hidden", children = initialPageChildren }
    uiRoot_ = UI.Panel {
        width = "100%",
        height = "100%",
        alignItems = "stretch",
        pointerEvents = "box-none",
        children = {
            CreateBackground(),
            UI.Panel {
                width = "100%",
                height = "100%",
                alignItems = "stretch",
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
    ReadLayoutMetrics()
    UI.Init({ theme = AppTheme, scale = layoutState_.metrics.scale })
    InstallSafeAreaWrapper()
    UI.SetOverflowWarnings(false)
end

local function BindServerEvents()
    ServerClient.On("snapshot", function()
        game = GameStateAdapter.GetViewState()
        if not sessionAutoStartAttempted_ then
            sessionAutoStartAttempted_ = true
            if not game.autoRun then
                requestedAutoRun_ = true
                pendingAutoRun_ = true
                print("[Play] authoritative auto-run is off; requesting automatic start")
                ServerClient.AutoRun(true, function(response)
                    pendingAutoRun_ = nil
                    if response and response.ok then
                        ServerClient.RequestSnapshot()
                    else
                        requestedAutoRun_ = nil
                        print("[Play] automatic start rejected: " .. tostring(response and response.reason or "unknown"))
                    end
                end)
            end
        end
        if requestedAutoRun_ ~= nil and game.autoRun == requestedAutoRun_ then
            requestedAutoRun_ = nil
            pendingAutoRun_ = nil
        end
        UpdateTopBar()
        if pageContainer_ then
            RefreshCurrentPage()
        else
            BuildRoot()
        end
        if not initialSnapshotReceived_ then
            initialSnapshotReceived_ = true
            if initialDwpFinished_ then
                loadingHideDelay_ = 0.35
            end
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
    initialSnapshotReceived_ = false
    initialDwpFinished_ = false
    loadingHideDelay_ = nil
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
    ClearCombatPresentation(false)
    initialSnapshotReceived_ = false
    initialDwpFinished_ = false
    loadingHideDelay_ = nil
    requestedAutoRun_ = nil
    pendingAutoRun_ = nil
    sessionAutoStartAttempted_ = false
    pickupFx_ = nil
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
    CheckLayoutMetrics(dt)
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
