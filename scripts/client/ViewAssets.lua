-- ViewAssets.lua
-- 客户端界面资源表与布局常量。
-- 从 GameView.lua 抽出，避免单文件超出 Lua 主块 200 个局部变量上限。

local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local EquipmentCatalog = require("shared.EquipmentCatalog")

local ViewAssets = {}

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
        inventoryDetailCompact = "image/ui/inventory/detail_panel.png",
        inventorySlotEmpty = "image/ui/inventory/slot_empty.png",
        inventorySlotCommon = "image/ui/inventory/slot_common.png",
        inventorySlotRare = "image/ui/inventory/slot_rare.png",
        inventorySlotEpic = "image/ui/inventory/slot_epic.png",
        inventorySlotLegend = "image/ui/inventory/slot_legend.png",
        inventorySlotMyth = "image/ui/inventory/slot_myth.png",
        inventorySlotSelected = "image/ui/inventory/slot_selected.png",
        inventoryTabOn = "image/ui/inventory/tab_on.png",
        inventoryTabOff = "image/ui/inventory/tab_off.png",
        idleSettings = "image/punk_idle_settings_icon_20260722080342.png",
        inventoryActionBlue = "image/ui/inventory/action_blue.png",
        inventoryActionRed = "image/ui/inventory/action_red.png",
        inventoryActionGold = "image/ui/inventory/action_gold.png",
        vipArt = "image/ui/vip_art.png",
        vipDigits = {
            "image/ui/digits/digit_0.png",
            "image/ui/digits/digit_1.png",
            "image/ui/digits/digit_2.png",
            "image/ui/digits/digit_3.png",
            "image/ui/digits/digit_4.png",
            "image/ui/digits/digit_5.png",
            "image/ui/digits/digit_6.png",
            "image/ui/digits/digit_7.png",
            "image/ui/digits/digit_8.png",
            "image/ui/digits/digit_9.png",
        },
        inventoryItemCard = "image/ui/inventory/item_card.png",
        inventoryEmptyState = "image/inventory_empty_state_20260720075957.png",
        inventoryItemCardSelected = "image/ui/inventory/item_card_selected.png",
        marketBackground = "image/ui/market/background.png",
        marketTitlePanel = "image/ui/market/title_panel.png",
        marketMainFrame = "image/ui/market/main_frame.png",
        marketTabOn = "image/ui/market/tab_on.png",
        marketTabOff = "image/ui/market/tab_off.png",
        marketListingCard = "image/ui/market/listing_card.png",
        marketBlackCounter = "image/ui/market/black_counter.png",
        itemTipsMainFrame = "image/ui/itemtips/main_frame.png",
        itemTipsMainFrameCompare = "image/ui/itemtips/main_frame_compare.png",
        itemTipsDetailRow = "image/ui/itemtips/detail_row.png",
        itemTipsCompareFrame = "image/ui/itemtips/compare_frame.png",
        itemTipsCompareButton = "image/ui/itemtips/compare_button.png",
        itemTipsCloseButton = "image/ui/itemtips/close_button.png",
        playHpFrame = "image/brawlforge_play_hp_frame_cropped.png",
        playAutoRunButton = "image/brawlforge_play_autorun_button_cropped.png",
        panelLarge = "image/ui/generated/panel_940x320.png",
        panelCompact = "image/ui/generated/panel_940x180.png",
        infoBarBlue = "image/ui/generated/info_bar_blue_520x76.png",
        infoBarGold = "image/ui/generated/info_bar_gold_520x76.png",
        lootBarGold = "image/ui/generated/loot_bar_gold_520x60.png",
        detailRow = "image/ui/generated/detail_row_520x38.png",
        statusBar = "image/ui/generated/status_bar_448x60.png",
        floorBadge = "image/ui/generated/floor_badge_150x60.png",
        chapterProgressLeftCap = "image/ui/generated/chapter_progress_left_cap_48x42.png",
        chapterProgressMid = "image/ui/generated/chapter_progress_mid_96x42.png",
        chapterProgressRightCap = "image/ui/generated/chapter_progress_right_cap_48x42.png",
        chapterProgressEnergyMid = "image/ui/generated/chapter_progress_energy_mid_96x24.png",
        chapterProgressNodeNormal = "image/ui/generated/chapter_progress_node_normal_56x56.png",
        chapterProgressNodeElite = "image/ui/generated/chapter_progress_node_elite_56x56.png",
        chapterProgressNodeBoss = "image/ui/generated/chapter_progress_node_boss_64x64.png",
        chapterProgressNodeAbyss = "image/ui/generated/chapter_progress_node_abyss_64x64.png",
        equipSlot = "image/ui/generated/equip_slot_compact.png",
        equipSlotSelected = "image/ui/generated/equip_slot_compact_selected.png",
        equipmentSlotIcons = {
            weapon = "image/empty_punk_weapon_icon_20260722074321.png",
            shoulder = "image/empty_punk_shoulder_icon_20260722074323.png",
            coat = "image/empty_punk_coat_icon_20260722074334.png",
            pants = "image/empty_punk_pants_icon_20260722074327.png",
            belt = "image/empty_punk_belt_icon_20260722074325.png",
            shoes = "image/empty_punk_shoes_icon_20260722074322.png",
            bracelet = "image/empty_punk_bracelet_icon_20260722074324.png",
            necklace = "image/empty_punk_necklace_icon_20260722074326.png",
            ring = "image/empty_punk_ring_icon_20260722074323.png",
            support = "image/empty_punk_support_icon_20260722074320.png",
            magicstone = "image/empty_punk_magicstone_icon_20260722074400.png",
            earring = "image/empty_punk_earring_icon_20260722074358.png",
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

-- 垂直分区契约（设计像素）：
--   顶部 [0, 310)
--   中部 [310, viewportHeight - 170)
--   底部 [viewportHeight - 170, viewportHeight)
-- 设计缩放保持水平面为 1080。更高的屏幕只扩展中部区域，
-- 顶部和底部区域始终吸附屏幕边缘。
local LAYOUT = {
    PLAYER_SIZE = 210,
    RUN_W = 420,
    RUN_H = 210,
    RUN_FPS = 10,
    ATTACK_FPS = 16,
    ATTACK_DURATION = 3.0,
    ATTACK_HIT_TIMINGS = { 0.18, 0.38, 0.58, 0.78, 0.93 },
    ENEMY_SIZE = 190,
    LOOT_SIZE = 96,
    PLAYER_SCREEN_X = 180,
    BG_TILE_W = 1080,
    BG_TILE_TOP = 0,
    BG_TILE_H = 1580,
    ROAD_Y = 1220,
    PLAYER_FOOT_OFFSET = 21,
    LOOT_FOOT_OFFSET = 8,
    EVENT_SPACING = 420,
    EVENT_TRIGGER_DISTANCE = 120,
    EVENT_VIEW_COUNT = 8,
    PRESENTATION_SPEED = 96,
    MIN_FONT_SIZE = 24,
    TOP_ZONE_HEIGHT = 310,
    BOTTOM_ZONE_HEIGHT = 170,
}

LAYOUT.PLATFORM_PLAYER_Y = LAYOUT.ROAD_Y - LAYOUT.RUN_H + LAYOUT.PLAYER_FOOT_OFFSET

ViewAssets.ASSETS = ASSETS
ViewAssets.LAYOUT = LAYOUT

local itemIconPreloadStarted_ = false

function ViewAssets.PreloadItemIcons()
    if itemIconPreloadStarted_ then return end
    itemIconPreloadStarted_ = true

    local resources = { EquipmentCatalog.ATLAS_PATH }
    for _, path in pairs(ASSETS.items) do
        resources[#resources + 1] = path
    end

    GetCache():DownloadResources(resources, function(success, failedCount)
        if success then
            for _, path in ipairs(resources) do
                ImageCache.Get(path)
            end
        end
        print(string.format(
            "[ViewAssets] item icon preload finished: success=%s failed=%d",
            tostring(success),
            tonumber(failedCount) or 0
        ))
    end)
    print("[ViewAssets] item icon preload started: " .. tostring(#resources) .. " resources")
end

function ViewAssets.CurrentPlayer()
    return ASSETS.player
end

return ViewAssets
