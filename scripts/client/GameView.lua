local UI = require("urhox-libs/UI")
local ImageCache = require("urhox-libs/UI/Core/ImageCache")
local GameTheme = require("client.Theme")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local AdminPanel = require("client.AdminPanel")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local ItemSort = require("shared.ItemSort")
local RarityCatalog = require("shared.RarityCatalog")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")
local StoryCatalog = require("shared.StoryCatalog")
local ItemTips = require("client.ItemTips")
local BackpackItemSlot = require("client.BackpackItemSlot")
local ItemSlotBase = require("client.ItemSlotBase")
local HorizontalArrowScroller = require("client.HorizontalArrowScroller")
local FrameEditorView = require("client.FrameEditorView")
local LoadingController = require("client.LoadingController")
local PlayPresentation = require("client.PlayPresentation")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DialogCoordinator = require("client.DialogCoordinator")
local AudioController = require("client.AudioController")
local EquipmentCodexView = require("client.EquipmentCodexView")
local EquipmentRecycleFilter = require("client.EquipmentRecycleFilter")
local EquipmentDispositionDialog = require("client.EquipmentDispositionDialog")
local MarketView = require("client.MarketView")
local IdleRewardAccumulator = require("client.IdleRewardAccumulator")

local CONFIG = GameTheme.CONFIG
local C = GameTheme.Colors
local AppTheme = GameTheme.Theme
local RARITIES = GameTheme.Rarities
local RARITY_ORDER = GameTheme.RarityOrder
local CATEGORIES = GameTheme.Categories
local SLOTS = GameTheme.Slots
local SET_ORDER = GameTheme.SetOrder
local SETS = GameTheme.Sets
local EVENT_INFO = GameTheme.EventInfo

local GameView = {}
local game = GameStateAdapter.GetViewState()
local uiRoot_ = nil
local screenRoot_ = nil
local idleSettingsOverlay_ = nil
local idleSettingTipOverlay_ = nil
local lootStashOverlay_ = nil
local lootStashForced_ = false
local lootStashClaimPending_ = false
local lootStashLoginGuideShown_ = false
local offlineLoginGuideShown_ = false
local offlineLoginFlowPending_ = false
local MaybeShowOfflineLoginGuide
local MaybeShowLootStashLoginGuide
local equipmentUpgradeOverlay_ = nil
local equipmentUpgradeItemId_ = nil
local pageContainer_ = nil
local needsFullRebuild_ = false
local needsPageRefresh_ = false
local selectedInventoryId_ = nil
local selectedSlot_ = "weapon"
local selectedCategory_ = "weapon"
local inventoryTabScrollX_ = 0
local equipmentScrollY_ = 0
local equipmentPageScrollY_ = 0
local OFFLINE_CLAIM_IDLE = "idle"
local OFFLINE_CLAIM_PREVIEWING = "previewing"
local OFFLINE_CLAIM_CONFIRMING = "confirming"
local OFFLINE_CLAIM_CLAIMING = "claiming"
local offlineClaimState_ = OFFLINE_CLAIM_IDLE
local offlineClaimSequence_ = 0
---@type string|nil
local offlineDialogKey_ = nil
local rewardDialogSequence_ = 0
local idleRewardTracking_ = false
local idleRewardActionPending_ = false
---@class IdleRewardItem
---@field icon string
---@field name string
---@field rarity string
---@field item table
---@class IdleRewardSummary
---@field gold table
---@field exp table
---@field fragments table
---@field equipmentItems IdleRewardItem[]
---@field equipmentById table<string, boolean>
---@field battles integer
---@type IdleRewardSummary|nil
local idleRewardSummary_ = nil
local topRefs_ = {}
local navRefs_ = {}
local viewportWidth_ = 0
local viewportHeight_ = 0
local itemIconPreloadStarted_ = false

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

local function PreloadItemIcons()
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
            "[GameView] item icon preload finished: success=%s failed=%d",
            tostring(success),
            tonumber(failedCount) or 0
        ))
    end)
    print("[GameView] item icon preload started: " .. tostring(#resources) .. " resources")
end

local PLAYER_SIZE = 210
local RUN_W = 420
local RUN_H = 210
local RUN_FPS = 10
local ATTACK_FPS = 16
local ATTACK_DURATION = 3.0
local ATTACK_HIT_TIMINGS = {0.18, 0.38, 0.58, 0.78, 0.93}
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

-- Vertical anchor contract (design pixels):
--   Top    [0, 310)
--   Middle [310, viewportHeight - 170)
--   Bottom [viewportHeight - 170, viewportHeight)
-- The design scale keeps the horizontal plane at 1080. Taller screens only
-- extend the middle zone; the top and bottom zones remain edge-anchored.
local TOP_ZONE_HEIGHT = 310
local BOTTOM_ZONE_HEIGHT = 170

local function CurrentPlayer()
    return ASSETS.player
end

local function CopyProps(base, extra)
    local t = {}
    if base then for k, v in pairs(base) do t[k] = v end end
    if extra then for k, v in pairs(extra) do t[k] = v end end
    return t
end

local function Clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
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
    if type(v) == "table" and (v.mantissa ~= nil or v.exponent ~= nil) then
        return BigNumber.Format(v, 4)
    end
    return LargeNumber.Format(v)
end

local function BuildCostItemCard(name, icon, owned, required, enough, options)
    options = options or {}
    local width = options.width or 176
    local height = options.height or 176
    local slotSize = options.slotSize or 106
    local slotLeft = math.floor((width - slotSize) * 0.5)
    local children = {
        UI.Panel {
            position = "absolute",
            left = slotLeft,
            top = 2,
            width = slotSize,
            height = slotSize,
            children = options.itemSlot and { options.itemSlot } or {
                UI.Panel {
                    position = "absolute",
                    left = 0,
                    top = 0,
                    width = slotSize,
                    height = slotSize,
                    backgroundImage = ASSETS.ui.inventorySlotCommon,
                    backgroundFit = "contain",
                    pointerEvents = "none",
                },
                UI.Panel {
                    position = "absolute",
                    left = 18,
                    top = 18,
                    width = slotSize - 36,
                    height = slotSize - 36,
                    backgroundImage = icon,
                    backgroundFit = "contain",
                    opacity = enough and 1.0 or 0.5,
                    pointerEvents = "none",
                },
            },
        },
        CompactTxt(name, 18, C.text, {
            position = "absolute",
            left = 8,
            top = 108,
            width = width - 16,
            height = 28,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        }),
        CompactTxt(FormatInt(owned or 0) .. "/" .. FormatInt(required or 0), 20,
            enough and C.success or C.error, {
                position = "absolute",
                left = 8,
                top = 138,
                width = width - 16,
                height = 30,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
    }
    if not enough then
        children[#children + 1] = UI.Panel {
            position = "absolute",
            left = slotLeft,
            top = 2,
            width = slotSize,
            height = slotSize,
            backgroundImage = ASSETS.ui.selectionFrame,
            backgroundFit = "contain",
            imageTint = C.error,
            opacity = 0.7,
            pointerEvents = "none",
        }
        children[#children + 1] = CompactTxt("不足", 18, C.error, {
            position = "absolute",
            left = slotLeft,
            top = 42,
            width = slotSize,
            height = 30,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        })
    end
    return UI.Panel {
        width = width,
        height = height,
        flexShrink = 0,
        position = "relative",
        overflow = "visible",
        backgroundImage = ASSETS.ui.inventoryItemCard,
        backgroundFit = "contain",
        children = children,
    }
end

local function FormatPercent(v)
    return string.format("%.1f%%", (v or 0) * 100)
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remainingSeconds = seconds % 60
    if hours > 0 then
        return string.format("%d小时%02d分", hours, minutes)
    end
    if minutes > 0 then
        return string.format("%d分%02d秒", minutes, remainingSeconds)
    end
    return string.format("%d秒", remainingSeconds)
end

local function MagnitudeRatio(value, maxValue)
    if type(value) == "table" or type(maxValue) == "table" then
        return Clamp(BigNumber.Ratio(value or 0, maxValue or 1) or 0, 0, 1)
    end
    return Clamp((value or 0) / math.max(1, maxValue or 1), 0, 1)
end

local function ImageProgress(width, height, value, maxValue, trackImage, fillImage)
    local ratio = MagnitudeRatio(value, maxValue)
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
    local ratio = MagnitudeRatio(value, maxValue)
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

local function ItemLevelText(item)
    return "Lv" .. tostring(item and (item.level or 1) or 1)
end

local function ItemPower(item)
    if not item then return 0 end
    -- Equipment comparison is server-authoritative in V5. These are aliases
    -- for evaluated values emitted by PowerEvaluator, never a local formula.
    if item.power ~= nil then return item.power end
    if item.displayedPower ~= nil then return item.displayedPower end
    if item.evaluatedPower ~= nil then return item.evaluatedPower end
    if item.powerContribution ~= nil then return item.powerContribution end
    if item.category == "material" or item.category == "consumable" then return item.quantity or 1 end
    return 0
end

local function ItemPowerText(item)
    if not item then return "待评估" end
    if item.power == nil and item.displayedPower == nil and item.evaluatedPower == nil and item.powerContribution == nil
        and item.category ~= "material" and item.category ~= "consumable" then
        return "待评估"
    end
    return FormatInt(ItemPower(item))
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
    local definition = item.equipmentId and EquipmentCatalog.Get(item.equipmentId)
    if definition and definition.icon then return definition.icon end
    return ASSETS.items.chest
end

local function RequestPageRefresh()
    needsPageRefresh_ = true
end

local function RequestFullRebuild()
    needsFullRebuild_ = true
end

local ACTION_ERROR_MESSAGES = {
    NO_OFFLINE_REWARD = "暂无可领取的离线收益（离线满3秒后可领取）",
    INVENTORY_FULL = "背包已满，请先清理装备后再操作",
    INVALID_OFFLINE_QUOTE = "离线收益预览已失效，请重新获取",
    OFFLINE_QUOTE_EXPIRED = "离线收益预览已过期，请重新获取",
    OFFLINE_QUOTE_IN_PROGRESS = "离线收益正在领取，请稍候",
    STALE_OFFLINE_QUOTE = "角色状态已变化，请重新获取离线收益预览",
    STORY_GATE_PENDING = "请先处理当前剧情，再领取离线收益",
    NOT_READY = "正在连接服务器，请稍后再试",
    RATE_LIMITED = "操作太频繁，请稍后再试",
    REQUEST_TIMEOUT = "服务器响应超时，请稍后重试",
    MATERIAL_REQUIRED = "请先选择一件升星材料",
    DUPLICATE_REQUIRED = "所选材料不再满足同款、同星级、同品阶条件，请重新选择",
}

local function ActionResult(response, successMessage)
    if response and response.ok then
        UI.Toast.Show(successMessage or "操作成功", { duration = 2.4, variant = "success", position = "bottom" })
        return true
    end
    local message = response and ACTION_ERROR_MESSAGES[response.code]
        or (response and response.reason)
        or "服务器未接受本次操作"
    UI.Toast.Show(message, { duration = 2.4, variant = "error", position = "bottom" })
    return false
end

local function OfflineRewardEvent(response)
    local data = response and response.data
    if type(data and data.reward) == "table" then return data.reward end
    local delta = data and data.delta
    for _, value in ipairs((delta and delta.events) or {}) do
        if value.kind == "offline_collected" then return value end
    end
    return nil
end

local function OfflineRewardItemCard(icon, name, amount, rarity, item)
    local displayItem = item or {
        name = name,
        rarity = rarity or "common",
        level = 1,
    }
    return BackpackItemSlot.Build({
        UI = UI,
        C = C,
        ASSETS = ASSETS,
        compactTxt = CompactTxt,
        shortenText = ShortenText,
        rarityColor = RarityColor,
        itemImage = function() return icon end,
        itemLevelText = ItemLevelText,
        isEquipped = function() return false end,
    }, displayItem, {
        width = 180,
        height = 180,
        selected = false,
        clickable = false,
        fallbackImage = icon,
        amountText = item == nil and amount or nil,
        showLevel = item ~= nil,
        showEquipped = false,
    })
end

local function AddRewardCard(cards, icon, name, amount, rarity, item)
    cards[#cards + 1] = OfflineRewardItemCard(icon, name, amount, rarity, item)
end

local function NewIdleRewardSummary()
    return IdleRewardAccumulator.New()
end

local function ResetIdleRewardSummary()
    idleRewardSummary_ = NewIdleRewardSummary()
end

local function IdleRewardHasValue()
    return IdleRewardAccumulator.HasValue(idleRewardSummary_)
end

local function StartIdleRewardTracking()
    if idleRewardTracking_ then return end
    idleRewardTracking_ = true
    ResetIdleRewardSummary()
end

local function AccumulateIdleRewards(events)
    if not idleRewardTracking_ then return end
    if not idleRewardSummary_ then ResetIdleRewardSummary() end
    IdleRewardAccumulator.Accumulate(assert(idleRewardSummary_), events, {
        getItemById = GetItemById,
        itemImage = ItemImage,
    })
end

local OfflineRewardCardPanel
local RewardDialogContent

local function ShowRewardDialog(options)
    options = options or {}
    rewardDialogSequence_ = rewardDialogSequence_ + 1
    local cards = options.cards or {}
    if #cards == 0 then return false end
    return CommonPromptDialog.Show {
        kind = "equipment",
        priority = options.priority or 320,
        queueKey = options.queueKey or ("reward:" .. tostring(rewardDialogSequence_)),
        title = options.title or "获得奖励",
        celebration = true,
        entranceDuration = 0.52,
        onPresented = function()
            AudioController.PlayFeedback(options.sound or "reward")
        end,
        dialogHeight = 1160,
        closeOnOverlay = false,
        showClose = options.showClose == true,
        cancelText = options.cancelText,
        confirmText = options.confirmText or "确认收取",
        onConfirm = options.onConfirm,
        onCancel = options.onCancel,
        contentBuilder = function()
            return RewardDialogContent(
                options.message or "奖励已存入背包",
                cards,
                options.lines or {}
            )
        end,
    }
end

local function MergeIdleRewardSummary(target, source)
    IdleRewardAccumulator.Merge(target, source)
end

local function ShowIdleRewardSummary(onConfirm)
    if not IdleRewardHasValue() then
        if onConfirm then onConfirm() end
        return false
    end
    if idleRewardActionPending_ then return true end

    local summary = assert(idleRewardSummary_)
    ResetIdleRewardSummary()
    local cards = {}
    if not BigNumber.IsZero(summary.gold) then
        AddRewardCard(cards, ASSETS.items.gold, "金币", "+" .. FormatInt(summary.gold), "epic")
    end
    if not BigNumber.IsZero(summary.exp) then
        AddRewardCard(cards, ASSETS.items.crystal, "经验", "+" .. FormatInt(summary.exp), "advanced")
    end
    if not BigNumber.IsZero(summary.fragments) then
        AddRewardCard(cards, ASSETS.items.crystal, "碎片", "+" .. FormatInt(summary.fragments), "rare")
    end
    for _, value in ipairs(summary.equipmentItems) do
        AddRewardCard(
            cards,
            value.icon,
            value.name,
            nil,
            value.rarity,
            value.item
        )
    end

    idleRewardActionPending_ = true
    rewardDialogSequence_ = rewardDialogSequence_ + 1
    local shown = ShowRewardDialog {
        priority = 450,
        queueKey = "idle_reward:" .. tostring(rewardDialogSequence_),
        title = "获得挂机奖励",
        message = "本次挂机收益已汇总",
        lines = {
            "完成战斗 " .. tostring(summary.battles or 0) .. " 场，奖励已同步到当前角色。",
        },
        confirmText = "确认并离开",
        cancelText = "继续刷宝",
        showClose = true,
        cards = cards,
        onConfirm = function()
            idleRewardActionPending_ = false
            if onConfirm then onConfirm() end
        end,
        onCancel = function()
            MergeIdleRewardSummary(assert(idleRewardSummary_), summary)
            idleRewardActionPending_ = false
        end,
    }
    if not shown then
        MergeIdleRewardSummary(assert(idleRewardSummary_), summary)
        idleRewardActionPending_ = false
    end
    return shown
end

local function IsIdleRewardEvent(kind)
    return IdleRewardAccumulator.IsRewardEvent(kind)
end

local function ShowLevelUpDialog(value)
    value = value or {}
    local previousLevel = math.max(1, tonumber(value.previousLevel) or ((tonumber(value.level) or 1) - 1))
    local level = math.max(previousLevel + 1, tonumber(value.level) or (previousLevel + 1))
    local levelsGained = math.max(1, tonumber(value.levelsGained) or (level - previousLevel))
    local currentExp = math.max(0, tonumber(value.exp) or 0)
    local nextExp = math.max(1, tonumber(value.nextExp) or 1)
    local expRatio = math.max(0, math.min(1, currentExp / nextExp))
    return CommonPromptDialog.Show {
        kind = "equipment",
        priority = 500,
        queueKey = "level_up:" .. tostring(previousLevel) .. ":" .. tostring(level),
        title = "等级提升",
        dialogHeight = 700,
        celebration = true,
        entranceDuration = 0.62,
        closeOnOverlay = false,
        showClose = false,
        confirmText = "继续冒险",
        onPresented = function()
            AudioController.PlayFeedback("levelUp")
        end,
        contentBuilder = function()
            local levelBadge = UI.Panel {
                width = 220,
                height = 220,
                flexShrink = 0,
                alignItems = "center",
                justifyContent = "center",
                backgroundColor = { 17, 36, 70, 245 },
                borderWidth = 4,
                borderColor = C.gold,
                borderRadius = 110,
                children = {
                    CompactTxt("LV", 24, C.textSecondary, {
                        position = "absolute", left = 0, top = 42,
                        width = 220, height = 34, textAlign = "center",
                        textStroke = { width = 1, color = "#000000" },
                        pointerEvents = "none",
                    }),
                    CompactTxt(tostring(level), 76, C.gold, {
                        width = 220, height = 110, textAlign = "center",
                        textStroke = { width = 3, color = "#000000" },
                        pointerEvents = "none",
                    }),
                },
            }
            levelBadge:Animate {
                keyframes = {
                    [0] = { opacity = 0, scale = 0.35, rotate = -10 },
                    [0.62] = { opacity = 1, scale = 1.16, rotate = 4 },
                    [1] = { opacity = 1, scale = 1.0, rotate = 0 },
                },
                duration = 0.72,
                easing = "easeOut",
            }
            return UI.Panel {
                width = "100%",
                flexShrink = 0,
                alignItems = "center",
                gap = 18,
                children = {
                    CompactTxt(
                        "Lv." .. tostring(previousLevel) .. "  →  Lv." .. tostring(level),
                        30,
                        C.focus,
                        {
                            width = "100%", height = 48, textAlign = "center",
                            textStroke = { width = 2, color = "#000000" },
                            pointerEvents = "none",
                        }
                    ),
                    levelBadge,
                    CompactTxt(
                        levelsGained > 1 and ("连续提升 " .. tostring(levelsGained) .. " 级") or "角色属性已全面成长",
                        23,
                        C.text,
                        {
                            width = "100%", height = 38, textAlign = "center",
                            textStroke = { width = 1, color = "#000000" },
                            pointerEvents = "none",
                        }
                    ),
                    UI.Panel {
                        width = 520, height = 28, flexShrink = 0,
                        backgroundColor = { 5, 14, 29, 235 },
                        borderWidth = 2, borderColor = C.border, borderRadius = 14,
                        overflow = "hidden",
                        children = {
                            UI.Panel {
                                width = math.floor(516 * expRatio), height = 24,
                                backgroundColor = C.focus, borderRadius = 12,
                                pointerEvents = "none",
                            },
                        },
                    },
                    CompactTxt(
                        "当前经验 " .. FormatInt(currentExp) .. " / " .. FormatInt(nextExp),
                        18,
                        C.textSecondary,
                        { width = "100%", height = 30, textAlign = "center", pointerEvents = "none" }
                    ),
                },
            }
        end,
    }
end

local function EventKey(value, index)
    return table.concat({
        tostring(value.kind or value.type or "event"),
        tostring(value.itemId or value.equipmentId or ""),
        tostring(value.floor or ""),
        tostring(value.position or ""),
        tostring(index or ""),
    }, ":")
end

local function ShowDeltaFeedback(payload)
    local events = (payload and payload.events) or {}
    local hasOfflineReward = false
    for _, value in ipairs(events) do
        local kind = value.kind or value.type
        if kind == "offline_collected" then
            hasOfflineReward = true
        elseif kind == "level_up" then
            ShowLevelUpDialog(value)
        end
    end
    if hasOfflineReward then return end
    local equipmentById = {}
    local cards = {}
    local title = "获得奖励"
    local message = "奖励已存入背包"
    local lines = {}
    local queueParts = {}
    local gold = BigNumber.FromNumber(0) ---@type table
    local exp = BigNumber.FromNumber(0) ---@type table
    local fragments = BigNumber.FromNumber(0) ---@type table
    local hasReward = false

    for index, value in ipairs(events) do
        local kind = value.kind or value.type
        queueParts[#queueParts + 1] = EventKey(value, index)
        if idleRewardTracking_ and IsIdleRewardEvent(kind) then
            -- 在线挂机奖励按会话累计，仅在切换页签或退出挂机时统一展示。
        elseif kind == "equipment_drop" or kind == "equipment_granted" or kind == "tower_aid_equipment" then
            local itemId = tostring(value.itemId or value.equipmentId or index)
            if not equipmentById[itemId] then
                equipmentById[itemId] = true
                local item = GetItemById(value.itemId) or value
                AddRewardCard(
                    cards,
                    ItemImage(item),
                    value.name or item.name or "装备",
                    nil,
                    value.rarity or item.rarity,
                    item
                )
                hasReward = true
            end
        elseif kind == "battle_reward" then
            gold = BigNumber.Add(gold, value.gold or 0)
            exp = BigNumber.Add(exp, value.exp or 0)
            title = "战斗胜利"
            message = "战斗奖励结算完成"
            hasReward = true
        elseif kind == "chest_reward" then
            gold = BigNumber.Add(gold, value.gold or 0)
            fragments = BigNumber.Add(fragments, value.fragments or 0)
            title = "宝箱奖励"
            message = "宝箱奖励已收取"
            hasReward = true
        elseif kind == "merchant_trade" then
            fragments = BigNumber.Add(fragments, value.fragments or 0)
            title = "交易奖励"
            message = "商人交易完成"
            hasReward = true
        elseif kind == "wish_pool" then
            gold = BigNumber.Add(gold, value.gold or 0)
            title = "许愿奖励"
            message = "许愿池已回应"
            hasReward = true
        elseif kind == "abyss_echo" then
            fragments = BigNumber.Add(fragments, value.fragments or 0)
            title = "深渊回响"
            message = "深渊碎片已收取"
            hasReward = true
        elseif kind == "aid_granted" or kind == "tower_aid_claimed" then
            title = "塔灵援助"
            message = "援助奖励已发放"
            if value.gold or value.fragments then
                gold = BigNumber.Add(gold, value.gold or 0)
                fragments = BigNumber.Add(fragments, value.fragments or 0)
                hasReward = true
            end
        elseif kind == "battle_lost" then
            UI.Toast.Show("挑战失败，已返回本层第1场重新整备", { duration = 2.8, variant = "error", position = "top" })
        elseif kind == "inventory_full" then
            UI.Toast.Show("背包已满，请清理装备或调整自动处理规则", { duration = 2.8, variant = "warning", position = "bottom" })
        elseif kind == "inventory_drop_skipped" then
            UI.Toast.Show("背包已满，本次装备掉落未能收取", { duration = 2.8, variant = "warning", position = "bottom" })
        elseif kind == "merchant_skipped" then
            UI.Toast.Show("金币不足，未能完成商人交易", { duration = 2.4, variant = "warning", position = "bottom" })
        elseif kind == "story_skipped" then
            UI.Toast.Show("剧情已跳过", { duration = 1.8, variant = "info", position = "bottom" })
        end
    end

    if not BigNumber.IsZero(gold) then AddRewardCard(cards, ASSETS.items.gold, "金币", "+" .. FormatInt(gold), "epic") end
    if not BigNumber.IsZero(exp) then AddRewardCard(cards, ASSETS.items.crystal, "经验", "+" .. FormatInt(exp), "advanced") end
    if not BigNumber.IsZero(fragments) then AddRewardCard(cards, ASSETS.items.crystal, "碎片", "+" .. FormatInt(fragments), "rare") end
    if not hasReward or #cards == 0 then return end

    lines[#lines + 1] = "奖励结算由服务器确认，物品已同步到当前角色。"
    ShowRewardDialog {
        queueKey = "delta_reward:" .. table.concat(queueParts, "|"),
        title = title,
        message = message,
        lines = lines,
        cards = cards,
    }
end

local function OfflineRewardCards(value)
    value = value or {}
    local cards = {
        OfflineRewardItemCard(ASSETS.items.gold, "金币", "+" .. FormatInt(value.gold or 0), "epic"),
        OfflineRewardItemCard(ASSETS.items.crystal, "经验", "+" .. FormatInt(value.exp or 0), "advanced"),
        OfflineRewardItemCard(ASSETS.items.crystal, "碎片", "+" .. FormatInt(value.fragments or 0), "rare"),
    }
    local equipmentItems = ItemSort.Sort(value.equipmentItems or {})
    for _, item in ipairs(equipmentItems) do
        cards[#cards + 1] = OfflineRewardItemCard(
            ItemImage(item),
            item.name or "装备",
            nil,
            item.rarity,
            item
        )
    end
    if (value.equipment or 0) > 0 and #(value.equipmentItems or {}) == 0 then
        cards[#cards + 1] = OfflineRewardItemCard(
            ASSETS.items.chest,
            "装备",
            nil,
            "rare"
        )
    end
    return cards
end

OfflineRewardCardPanel = function(cards, pageLabel)
    return HorizontalArrowScroller.Build {
        width = 720,
        height = 600,
        rows = 3,
        columnsPerPage = 3,
        arrowWidth = 42,
        itemWidth = 180,
        itemHeight = 180,
        gapX = 8,
        gapY = 10,
        children = cards,
        text = CompactTxt,
        arrowColor = C.focus,
        arrowBorderColor = C.focus,
        arrowBackgroundColor = { 7, 19, 39, 225 },
        pageLabel = pageLabel,
    }
end

RewardDialogContent = function(message, cards, detailLines)
    local pageLabel = CompactTxt("1 / 1", 17, C.textDim, {
        width = 92, height = 28, textAlign = "right",
        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
    })
    local details = {}
    for _, line in ipairs(detailLines or {}) do
        details[#details + 1] = CompactTxt(line, 18, C.textSecondary, {
            width = "100%", height = 26, textAlign = "center",
            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
        })
    end
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        alignItems = "center",
        gap = 14,
        children = {
            UI.Panel {
                width = 700,
                height = 44,
                flexShrink = 0,
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                paddingLeft = 14,
                paddingRight = 14,
                backgroundColor = { 7, 20, 42, 220 },
                borderWidth = 1,
                borderColor = C.border,
                borderRadius = 8,
                children = {
                    CompactTxt(message or "奖励已存入背包", 21, C.text, {
                        width = 560, height = 44, textAlign = "left",
                        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                    }),
                    pageLabel,
                },
            },
            OfflineRewardCardPanel(cards, pageLabel),
            UI.Panel {
                width = 700,
                flexShrink = 0,
                paddingTop = 8,
                gap = 4,
                borderTopWidth = 2,
                borderColor = C.border,
                children = details,
            },
        },
    }
end

local function BuildOfflineTimeSummary(value, preview)
    value = value or {}
    local primaryLabel = preview and "累计离线" or "实际结算"
    local primaryValue = preview and value.seconds or value.processedSeconds
    local secondaryLabel = preview and "预计结算" or "当前楼层"
    local secondaryValue = preview and FormatDuration(value.processedSeconds or 0)
        or ("第" .. tostring(value.floor or game.floor or 1) .. "层")
    local note
    if value.interrupted then
        note = "背包空间不足，未结算时间会继续保留"
    elseif (value.remainingSeconds or 0) > 0 then
        note = (preview and "领取后保留 " or "剩余离线 ") .. FormatDuration(value.remainingSeconds)
    else
        note = preview and "收益按在线效率的20%计算，装备结果已锁定"
            or "奖励已经服务器确认并同步到当前角色"
    end
    local function Stat(label, text, color, textAlign)
        return UI.Panel {
            width = 318, height = 64, flexShrink = 0,
            paddingLeft = 14, paddingRight = 14,
            justifyContent = "center", gap = 2,
            backgroundColor = { 7, 20, 42, 210 },
            borderWidth = 1, borderColor = C.border, borderRadius = 8,
            children = {
                CompactTxt(label, 15, C.textDim, {
                    width = "100%", height = 22, textAlign = textAlign,
                }),
                CompactTxt(text, 20, color, {
                    width = "100%", height = 28, textAlign = textAlign,
                    textStroke = { width = 1, color = "#000000" },
                }),
            },
        }
    end
    return UI.Panel {
        width = 700, flexShrink = 0, gap = 8,
        children = {
            UI.Panel {
                width = 700, height = 64, flexDirection = "row",
                justifyContent = "space-between",
                children = {
                    Stat(primaryLabel, FormatDuration(primaryValue or 0), C.gold, "left"),
                    Stat(secondaryLabel, secondaryValue, C.focus, "right"),
                },
            },
            CompactTxt(note, 16, C.textSecondary, {
                width = 700, height = 26, textAlign = "center",
                textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
            }),
        },
    }
end

local function OfflinePreviewContent(value)
    local cards = OfflineRewardCards(value)
    local pageLabel = CompactTxt("1 / 1", 17, C.textDim, {
        width = 92, height = 28, textAlign = "right",
        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
    })
    return UI.Panel {
        width = "100%", flexShrink = 0, alignItems = "center", gap = 12,
        children = {
            UI.Panel {
                width = 700, height = 42, flexShrink = 0,
                flexDirection = "row", alignItems = "center", justifyContent = "space-between",
                paddingLeft = 14, paddingRight = 14,
                backgroundColor = { 7, 20, 42, 220 },
                borderWidth = 1, borderColor = C.border, borderRadius = 8,
                children = {
                    CompactTxt("预计奖励", 21, C.text, {
                        width = 500, height = 42, textAlign = "left",
                        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                    }),
                    pageLabel,
                },
            },
            OfflineRewardCardPanel(cards, pageLabel),
            UI.Panel {
                width = 700,
                height = 28,
                flexShrink = 0,
                pointerEvents = "none",
            },
            BuildOfflineTimeSummary(value, true),
        },
    }
end

local function ShowOfflineRewardDialog(value, onCompleted)
    value = value or {}
    local cards = OfflineRewardCards(value)
    local lines = {
        "本次实际结算：" .. FormatDuration(value.processedSeconds or 0),
        "离线期间仅重复挑战第" .. tostring(value.floor or game.floor or 1) .. "层，不会自动突破楼层。",
        "奖励已经过服务器确认并同步到当前角色。",
    }
    if value.interrupted then
        lines[#lines + 1] = "背包已满，尚未结算的离线时间已保留。"
    elseif (value.remainingSeconds or 0) > 0 then
        lines[#lines + 1] = "剩余离线时间：" .. FormatDuration(value.remainingSeconds)
    end
    local shown = ShowRewardDialog {
        priority = 450,
        queueKey = "offline_reward:" .. tostring(value.processedSeconds or 0) .. ":" .. tostring(value.floor or 1),
        title = "获得离线奖励",
        message = "离线收益已领取",
        lines = lines,
        confirmText = "确认收取",
        cards = cards,
        onConfirm = onCompleted,
        onCancel = onCompleted,
    }
    if not shown and onCompleted then onCompleted() end
    return shown
end

local function ShowOfflinePreviewDialog(quoteToken, value, onClaim, onCancel, forceClaim)
    value = value or {}
    local dialogKey = "offline_preview:" .. tostring(quoteToken)
    local cancelText = "稍后领取"
    if forceClaim then cancelText = nil end
    offlineDialogKey_ = dialogKey
    return CommonPromptDialog.Show {
        kind = "confirm",
        priority = 460,
        queueKey = dialogKey,
        title = "离线收益预览",
        dialogHeight = 1100,
        titleTop = -7,
        closeTop = 17,
        closeRight = 22,
        buttonTop = 1017,
        cancelButtonLeft = 108,
        confirmButtonLeft = forceClaim and 300 or 492,
        cancelTextLeft = 2,
        cancelTextTop = -2,
        cancelText = cancelText,
        showClose = not forceClaim,
        confirmText = "确认领取",
        closeOnOverlay = false,
        contentBuilder = function()
            return OfflinePreviewContent(value)
        end,
        onConfirm = onClaim,
        onCancel = onCancel,
    }
end

local function CollectDecomposeCandidateItems(selection)
    game = GameStateAdapter.GetViewState()
    selection = type(selection) == "table" and selection or {}
    local items = {}
    for _, item in ipairs(game.inventory or {}) do
        local rarityId = RarityCatalog.NormalizeId(item.rarity)
        if item.equipmentId and item.id ~= nil
            and selection[rarityId] == true
            and rarityId ~= "myth"
            and not item.locked and not item.aidLocked and not IsEquipped(item) then
            items[#items + 1] = item
        end
    end
    return items
end

local function ShowDecomposeRewardDialog(gold, fragments, count)
    local cards = {}
    if not LargeNumber.IsZero(gold) then
        AddRewardCard(cards, ASSETS.items.gold, "金币", "+" .. FormatInt(gold), "epic")
    end
    if fragments and fragments > 0 then
        AddRewardCard(cards, ASSETS.items.crystal, "碎片", "+" .. FormatInt(fragments), "rare")
    end
    if #cards == 0 then return end
    ShowRewardDialog {
        title = "分解成功",
        message = "已分解 " .. tostring(count) .. " 件装备",
        lines = { "返还资源已存入账户" },
        cards = cards,
        confirmText = "确认收取",
    }
end

local function CompleteOfflineLoginFlow()
    if not offlineLoginFlowPending_ then return end
    offlineLoginFlowPending_ = false
    game = GameStateAdapter.GetViewState()
    if MaybeShowLootStashLoginGuide then
        MaybeShowLootStashLoginGuide()
    end
end

local actionFns_ = {}
actionFns_.CollectOffline = function(onCompleted)
    if not onCompleted and offlineLoginFlowPending_ then
        onCompleted = CompleteOfflineLoginFlow
    end
    if offlineClaimState_ == OFFLINE_CLAIM_PREVIEWING then
        UI.Toast.Show("正在获取离线收益预览，请稍候", { duration = 1.5, variant = "info", position = "bottom" })
        return
    end
    if offlineClaimState_ == OFFLINE_CLAIM_CONFIRMING then
        if offlineDialogKey_ and DialogCoordinator.HasKey(offlineDialogKey_) then
            UI.Toast.Show("离线收益确认弹窗正在等待显示", { duration = 1.5, variant = "info", position = "bottom" })
            return
        end
        offlineDialogKey_ = nil
        offlineClaimState_ = OFFLINE_CLAIM_IDLE
    end
    if offlineClaimState_ == OFFLINE_CLAIM_CLAIMING then
        UI.Toast.Show("离线收益正在领取，请稍候", { duration = 1.5, variant = "info", position = "bottom" })
        return
    end

    offlineClaimSequence_ = offlineClaimSequence_ + 1
    local sequence = offlineClaimSequence_
    local loadingDialogKey = "offline_preview_loading:" .. tostring(sequence)
    offlineDialogKey_ = loadingDialogKey
    offlineClaimState_ = OFFLINE_CLAIM_PREVIEWING
    print("[OfflineClaim] preview requested sequence=" .. tostring(sequence))
    local loadingShown = CommonPromptDialog.Show {
        kind = "confirm",
        priority = 460,
        queueKey = loadingDialogKey,
        title = "离线收益",
        message = "正在计算离线收益，请稍候……",
        lines = { "服务器正在锁定本次预计奖励，完成后会显示确认领取内容。" },
        closeOnOverlay = false,
        showClose = false,
        showConfirm = false,
    }
    if not loadingShown then
        offlineDialogKey_ = nil
        offlineClaimState_ = OFFLINE_CLAIM_IDLE
        print("[OfflineClaim] loading dialog rejected sequence=" .. tostring(sequence))
        UI.Toast.Show("当前有其他弹窗，请稍后重试", { duration = 1.8, variant = "info", position = "bottom" })
        return
    end
    ServerClient.PreviewOffline(function(response)
        if sequence ~= offlineClaimSequence_ then return end
        DialogCoordinator.CancelByKey(loadingDialogKey)
        offlineDialogKey_ = nil
        if not response or not response.ok then
            offlineClaimState_ = OFFLINE_CLAIM_IDLE
            print("[OfflineClaim] preview failed sequence=" .. tostring(sequence)
                .. " code=" .. tostring(response and response.code))
            ActionResult(response)
            return
        end
        local data = response.data or {}
        local quoteToken = data.quoteToken
        local preview = data.preview
        if type(quoteToken) ~= "string" or type(preview) ~= "table" then
            offlineClaimState_ = OFFLINE_CLAIM_IDLE
            print("[OfflineClaim] invalid preview response sequence=" .. tostring(sequence))
            ActionResult({ ok = false, reason = "服务器返回的离线预览无效" })
            return
        end

        offlineClaimState_ = OFFLINE_CLAIM_CONFIRMING
        local shown = ShowOfflinePreviewDialog(quoteToken, preview, function()
            if sequence ~= offlineClaimSequence_ then return end
            offlineDialogKey_ = nil
            offlineClaimState_ = OFFLINE_CLAIM_CLAIMING
            print("[OfflineClaim] claim confirmed sequence=" .. tostring(sequence))
            ServerClient.CollectOffline(quoteToken, function(claimResponse)
                if sequence ~= offlineClaimSequence_ then return end
                offlineClaimState_ = OFFLINE_CLAIM_IDLE
                if not ActionResult(claimResponse) then
                    print("[OfflineClaim] claim failed sequence=" .. tostring(sequence)
                        .. " code=" .. tostring(claimResponse and claimResponse.code))
                    return
                end
                print("[OfflineClaim] claim completed sequence=" .. tostring(sequence))
                local reward = OfflineRewardEvent(claimResponse)
                if reward then
                    ShowOfflineRewardDialog(reward, onCompleted)
                else
                    UI.Toast.Show("离线收益已领取", { duration = 2.0, variant = "success", position = "bottom" })
                    if onCompleted then onCompleted() end
                end
                ServerClient.RequestSnapshot()
            end)
        end, function()
            if sequence ~= offlineClaimSequence_ then return end
            offlineDialogKey_ = nil
            offlineClaimState_ = OFFLINE_CLAIM_IDLE
            print("[OfflineClaim] preview closed sequence=" .. tostring(sequence))
        end, offlineLoginFlowPending_)
        if not shown then
            offlineDialogKey_ = nil
            offlineClaimState_ = OFFLINE_CLAIM_IDLE
            print("[OfflineClaim] preview dialog rejected sequence=" .. tostring(sequence))
            UI.Toast.Show("当前有其他弹窗，请稍后重试", { duration = 1.8, variant = "info", position = "bottom" })
            return
        end
        print("[OfflineClaim] preview dialog queued sequence=" .. tostring(sequence))
    end)
end
actionFns_.EquipItem = function(item)
    if not (item and item.id) then return end

    local function EquipConfirmed()
        selectedSlot_ = item.slot or selectedSlot_
        ServerClient.Equip(item.id, function(response)
            if not ActionResult(response, "装备已穿戴") then return end
            RequestPageRefresh()
            -- Delta is authoritative; this snapshot only covers a dropped
            -- delta so the equipment page cannot remain visually stale.
            ServerClient.RequestSnapshot()
        end)
    end

    if item.tradeable ~= true then
        EquipConfirmed()
        return
    end

    print("[EquipmentTrade] showing bind confirmation itemId=" .. tostring(item.id))
    CommonPromptDialog.Show {
        kind = "equipment",
        priority = 420,
        queueKey = "equip_tradeable:" .. tostring(item.id),
        title = "确认装配可交易装备",
        message = tostring(item.name or "该装备") .. "装配后将永久变为不可交易装备。",
        lines = {
            "该变化不可撤销。",
            "卸下或撤销换装后也不会恢复可交易状态。",
        },
        closeOnOverlay = false,
        showClose = true,
        cancelText = "取消",
        confirmText = "确认装配",
        onConfirm = EquipConfirmed,
    }
end
actionFns_.UnequipSlot = function(slotId)
    if slotId then
        selectedSlot_ = slotId
        ServerClient.Unequip(slotId, ActionResult)
    end
end
actionFns_.AutoEquipBest = function() ServerClient.AutoEquip(ActionResult) end
actionFns_.DecomposeByFilter = function()
    local filter = EquipmentRecycleFilter.Get("decompose")
    local maximumRank = EquipmentRecycleFilter.MaxSelectedRank("decompose")
    local items = CollectDecomposeCandidateItems(filter)
    if #items == 0 then
        UI.Toast.Show("没有符合条件的未锁定、未穿戴装备", { duration = 1.8, variant = "info", position = "bottom" })
        return
    end
    local selected = {}
    for _, item in ipairs(items) do selected[item.id] = true end
    local refunds = {}
    local totalGoldText, totalFragText, headerCountText
    local cellRefs = {}

    local function RecomputeTotals()
        local gold = LargeNumber.Zero()
        local frag = 0
        for _, item in ipairs(items) do
            if selected[item.id] then
                local r = refunds[item.id]
                if r then
                    gold = LargeNumber.Add(gold, r.gold or 0)
                    frag = frag + (r.fragments or 0)
                end
            end
        end
        return gold, frag
    end

    local function SelectedCount()
        local n = 0
        for _, item in ipairs(items) do
            if selected[item.id] then n = n + 1 end
        end
        return n
    end

    local function UpdateTotalsInPlace()
        local gold, frag = RecomputeTotals()
        if totalGoldText then totalGoldText:SetText("+" .. FormatInt(gold)) end
        if totalFragText then totalFragText:SetText("+" .. FormatInt(frag)) end
        if headerCountText then
            headerCountText:SetText("即将分解 " .. tostring(SelectedCount()) .. " / "
                .. tostring(#items) .. " 件装备（筛选："
                .. EquipmentRecycleFilter.Summary("decompose") .. "）")
        end
    end

    local function UpdateCellInPlace(itemId)
        local ref = cellRefs[itemId]
        if not ref then return end
        local on = selected[itemId]
        ref.cell:SetBackgroundColor(on and { 30, 90, 150, 120 } or { 12, 22, 40, 120 })
        ref.cell:SetBorderColor(on and C.focus or C.border)
        ref.label:SetText(on and "✓ 已选择" or "○ 未选择")
        ref.label:SetFontColor(on and C.success or C.textDim)
    end

    local function DoDecompose()
        local ids = {}
        for _, item in ipairs(items) do
            if selected[item.id] then ids[#ids + 1] = item.id end
        end
        if #ids == 0 then
            UI.Toast.Show("请至少选择一件装备", { duration = 1.6, variant = "info", position = "bottom" })
            return false
        end
        ServerClient.Decompose(maximumRank, ids, function(response)
            if not (response and response.ok) then
                ActionResult(response)
                return
            end
            local reward = response.data and response.data.reward or {}
            local gold = reward.gold or 0
            local frag = reward.fragments or 0
            local count = reward.count or #ids
            RequestPageRefresh()
            UI.Toast.Show("分解成功", { duration = 2.0, variant = "success", position = "bottom" })
            ShowDecomposeRewardDialog(gold, frag, count)
        end)
    end

    local gridChildren = {}
    for _, item in ipairs(items) do
        local label = CompactTxt(selected[item.id] and "✓ 已选择" or "○ 未选择", 15,
            selected[item.id] and C.success or C.textDim, {
                width = "100%", height = 22, textAlign = "center",
                textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
            })
        local card = OfflineRewardItemCard(
            ItemImage(item),
            item.name or "装备",
            nil,
            item.rarity or "common",
            item
        )
        card:SetProp("pointerEvents", "none")
        local cell = UI.Panel {
            width = 186,
            height = 216,
            flexShrink = 0,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            gap = 4,
            paddingTop = 6,
            paddingBottom = 6,
            backgroundColor = selected[item.id] and { 30, 90, 150, 120 } or { 12, 22, 40, 120 },
            borderWidth = 2,
            borderColor = selected[item.id] and C.focus or C.border,
            borderRadius = 10,
            onClick = function()
                selected[item.id] = not selected[item.id]
                UpdateCellInPlace(item.id)
                UpdateTotalsInPlace()
            end,
            children = {
                card,
                label,
            },
        }
        cellRefs[item.id] = { cell = cell, label = label }
        gridChildren[#gridChildren + 1] = cell
    end

    local gold0, frag0 = RecomputeTotals()
    totalGoldText = CompactTxt("+" .. FormatInt(gold0), 24, C.gold, {
        width = 200, height = 34, textAlign = "right",
        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
    })
    totalFragText = CompactTxt("+" .. FormatInt(frag0), 24, C.secondary, {
        width = 200, height = 34, textAlign = "right",
        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
    })
    headerCountText = CompactTxt(
        "即将分解 " .. tostring(SelectedCount()) .. " / " .. tostring(#items)
            .. " 件装备（筛选：" .. EquipmentRecycleFilter.Summary("decompose") .. "）",
        24, C.text, {
            width = "100%", height = 36, textAlign = "center",
            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
        })

    local content = UI.Panel {
        width = "100%",
        height = 660,
        flexShrink = 0,
        gap = 12,
        children = {
            headerCountText,
            UI.ScrollView {
                width = "100%",
                flexGrow = 1,
                flexBasis = 0,
                scrollX = false,
                scrollY = true,
                showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%",
                        flexShrink = 0,
                        alignItems = "center",
                        paddingBottom = 12,
                        children = {
                            UI.Panel {
                                width = 582,
                                flexShrink = 0,
                                flexDirection = "row",
                                flexWrap = "wrap",
                                gap = 12,
                                justifyContent = "flex-start",
                                alignItems = "flex-start",
                                alignContent = "flex-start",
                                children = gridChildren,
                            },
                        },
                    },
                },
            },
            UI.Panel {
                width = "100%",
                height = 64,
                flexShrink = 0,
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "center",
                gap = 32,
                paddingTop = 10,
                borderTopWidth = 2,
                borderColor = C.border,
                children = {
                    CompactTxt("分解总获得", 21, C.text, {
                        width = 150, height = 34, textAlign = "left",
                        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                    }),
                    UI.Panel {
                        width = 200, height = 44, flexShrink = 0,
                        flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 8,
                        children = {
                            UI.Panel { width = 36, height = 36, flexShrink = 0, backgroundImage = ASSETS.items.gold, backgroundFit = "contain" },
                            totalGoldText,
                        },
                    },
                    UI.Panel {
                        width = 200, height = 44, flexShrink = 0,
                        flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 8,
                        children = {
                            UI.Panel { width = 36, height = 36, flexShrink = 0, backgroundImage = ASSETS.items.crystal, backgroundFit = "contain" },
                            totalFragText,
                        },
                    },
                },
            },
        },
    }

    CommonPromptDialog.Show {
        kind = "confirm",
        priority = 150,
        queueKey = "decompose-preview",
        title = "分解预览",
        dialogWidth = 900,
        dialogHeight = 1040,
        message = nil,
        lines = { "点击卡片可取消选择；分解完成后无法撤销。" },
        cancelText = "取消",
        confirmText = "确认分解",
        danger = true,
        closeOnOverlay = false,
        zIndex = 2500,
        bodyScrollY = false,
        content = content,
        onConfirm = DoDecompose,
    }

    for _, item in ipairs(items) do
        ServerClient.DecomposePreview(item.id, function(response)
            if response and response.ok and type(response.data) == "table" then
                refunds[item.id] = {
                    gold = response.data.gold or 0,
                    fragments = response.data.fragments or 0,
                    rate = response.data.rate or 0,
                }
                UpdateTotalsInPlace()
            end
        end)
    end
end
actionFns_.SetEquipmentLock = function(item)
    ServerClient.SetEquipmentLock(item.id, not item.locked, function(response)
        if not ActionResult(response, item.locked and "装备已解锁" or "装备已锁定") then return end
        RequestPageRefresh()
    end)
end
actionFns_.SetInventoryPolicy = function(policy) ServerClient.SetInventoryPolicy(policy, ActionResult) end
actionFns_.StrengthenSelected = function()
    local slotId = selectedSlot_
    ServerClient.StrengthenPreview(slotId, function(response)
        if not response or not response.ok or type(response.data) ~= "table" then
            ActionResult(response)
            return
        end
        local preview = response.data
        local content = UI.Panel {
            width = "100%",
            height = 300,
            flexShrink = 0,
            alignItems = "center",
            gap = 10,
            children = {
                CompactTxt(
                    "+" .. tostring(preview.currentEnhance or 0)
                        .. "  →  +" .. tostring(preview.nextEnhance or 0),
                    28,
                    preview.atMax and C.error or C.gold,
                    {
                        width = "100%",
                        height = 42,
                        textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                    }
                ),
                CompactTxt(
                    preview.atMax and "已达到当前强化上限" or "强化所需材料",
                    20,
                    preview.atMax and C.error or C.textSecondary,
                    { width = "100%", height = 30, textAlign = "center" }
                ),
                UI.Panel {
                    width = "100%",
                    height = 176,
                    flexDirection = "row",
                    justifyContent = "center",
                    gap = 28,
                    children = {
                        BuildCostItemCard(
                            "金币",
                            ASSETS.items.gold,
                            preview.goldOwned,
                            preview.gold,
                            preview.goldEnough == true
                        ),
                        BuildCostItemCard(
                            "装备碎片",
                            ASSETS.items.crystal,
                            preview.fragmentsOwned,
                            preview.fragments,
                            preview.fragmentsEnough == true
                        ),
                    },
                },
            },
        }
        CommonPromptDialog.Show {
            kind = "confirm",
            title = "确认强化",
            content = content,
            dialogWidth = 900,
            dialogHeight = 640,
            bodyTop = 86,
            bodyHeight = 380,
            bodyScrollY = false,
            buttonTop = 532,
            cancelText = "取消",
            confirmText = "确认强化",
            confirmEnabled = preview.canStrengthen == true,
            closeOnOverlay = false,
            onConfirm = function()
                ServerClient.Strengthen(slotId, function(result)
                    ActionResult(result, "强化成功")
                    if result and result.ok then RequestPageRefresh() end
                end)
            end,
        }
    end)
end
actionFns_.StarSelected = function()
    local slotId = selectedSlot_
    ServerClient.StarPreview(slotId, function(response)
        if not response or not response.ok or type(response.data) ~= "table" then
            ActionResult(response)
            return
        end
        local preview = response.data
        local materials = type(preview.materials) == "table" and preview.materials or {}
        local selectedMaterialId = materials[1] and materials[1].itemId or nil
        local materialContext = {
            C = C,
            ASSETS = ASSETS,
            itemImage = ItemImage,
            itemLevelText = ItemLevelText,
            compactTxt = CompactTxt,
            rarityColor = RarityColor,
            shortenText = ShortenText,
            isEquipped = function() return false end,
            showItemTips = ItemTips.Show,
            registerItemTipsTrigger = ItemTips.RegisterTrigger,
        }
        local starContent = UI.Panel {
            width = "100%",
            height = 562,
            flexShrink = 0,
            alignItems = "center",
            gap = 8,
        }

        local function RebuildStarContent()
            starContent:ClearChildren()
            local selectedMaterial = nil
            for _, candidate in ipairs(materials) do
                if tostring(candidate.itemId) == tostring(selectedMaterialId) then
                    selectedMaterial = candidate
                    break
                end
            end
            local duplicateCount = preview.duplicateCount or 1
            local materialOwned = preview.materialOwned or #materials
            local materialEnough = materialOwned >= duplicateCount
            local materialSlot = ItemSlotBase.Build(materialContext, selectedMaterial, {
                size = 106,
                selected = selectedMaterial ~= nil,
                showEquipped = false,
            })

            starContent:AddChild(CompactTxt(
                tostring(preview.currentStar or 0)
                    .. " 星  →  " .. tostring(preview.nextStar or 0) .. " 星",
                28,
                preview.atMax and C.error or C.gold,
                {
                    width = "100%",
                    height = 40,
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                }
            ))
            starContent:AddChild(CompactTxt(
                preview.atMax and "已达到最高星级" or "升星所需材料",
                20,
                preview.atMax and C.error or C.textSecondary,
                { width = "100%", height = 28, textAlign = "center" }
            ))
            starContent:AddChild(UI.Panel {
                width = "100%",
                height = 176,
                flexDirection = "row",
                justifyContent = "center",
                gap = 18,
                children = {
                    BuildCostItemCard(
                        "金币",
                        ASSETS.items.gold,
                        preview.goldOwned,
                        preview.gold,
                        preview.goldEnough == true,
                        { width = 170 }
                    ),
                    BuildCostItemCard(
                        "装备碎片",
                        ASSETS.items.crystal,
                        preview.fragmentsOwned,
                        preview.fragments,
                        preview.fragmentsEnough == true,
                        { width = 170 }
                    ),
                    BuildCostItemCard(
                        "同款装备",
                        nil,
                        materialOwned,
                        duplicateCount,
                        materialEnough,
                        { width = 170, itemSlot = materialSlot }
                    ),
                },
            })
            starContent:AddChild(CompactTxt(
                #materials > 1 and "选择要消耗的同款、同星级、同品阶装备" or "升星装备材料",
                19,
                #materials > 0 and C.textSecondary or C.error,
                { width = "100%", height = 28, textAlign = "center" }
            ))

            if #materials == 0 then
                starContent:AddChild(UI.Panel {
                    width = 128,
                    height = 128,
                    position = "relative",
                    children = {
                        ItemSlotBase.Build(materialContext, nil, { size = 124 }),
                        CompactTxt("缺少", 20, C.error, {
                            position = "absolute",
                            left = 0,
                            top = 45,
                            width = 124,
                            height = 34,
                            textAlign = "center",
                            textStroke = { width = 2, color = "#000000" },
                        }),
                    },
                })
            else
                local cards = {}
                for _, candidate in ipairs(materials) do
                    local material = candidate
                    local selected = tostring(material.itemId) == tostring(selectedMaterialId)
                    cards[#cards + 1] = BackpackItemSlot.Build(materialContext, material, {
                        width = 132,
                        height = 146,
                        selected = selected,
                        clickable = true,
                        showEquipped = false,
                        amountText = selected and "已选择" or "点击选择",
                        onClick = function()
                            selectedMaterialId = material.itemId
                            RebuildStarContent()
                        end,
                    })
                end
                starContent:AddChild(UI.ScrollView {
                    width = "100%",
                    height = 150,
                    scrollX = true,
                    scrollY = false,
                    showScrollbar = false,
                    children = {
                        UI.Panel {
                            height = 146,
                            flexDirection = "row",
                            gap = 10,
                            justifyContent = #cards <= 5 and "center" or "flex-start",
                            children = cards,
                        },
                    },
                })
            end
        end
        RebuildStarContent()

        CommonPromptDialog.Show {
            kind = "confirm",
            title = "确认升星",
            content = starContent,
            dialogWidth = 900,
            dialogHeight = 860,
            bodyTop = 82,
            bodyHeight = 638,
            bodyScrollY = false,
            buttonTop = 752,
            cancelText = "取消",
            confirmText = "确认升星",
            confirmEnabled = preview.canStar == true and selectedMaterialId ~= nil,
            danger = true,
            closeOnOverlay = false,
            onConfirm = function()
                ServerClient.Star(slotId, selectedMaterialId, function(result)
                    ActionResult(result, "升星成功")
                    if result and result.ok then RequestPageRefresh() end
                end)
            end,
        }
    end)
end

local RefreshCurrentPage
local SwitchPage
local UpdateTopBar
local UpdateBottomNav

UpdateTopBar = function()
    if not topRefs_ then return end
    game = GameStateAdapter.GetViewState()
    if topRefs_.floor then topRefs_.floor:SetText("层  第" .. tostring(game.floor or 1) .. "层") end
    if topRefs_.level then topRefs_.level:SetText("Lv." .. tostring(game.level or 1)) end
    if topRefs_.gold then topRefs_.gold:SetText("金币  " .. FormatInt(game.gold or 0)) end
    if topRefs_.fragments then topRefs_.fragments:SetText("碎片  " .. FormatInt(game.fragments or 0)) end
end

local function CreateTopBar()
    topRefs_.floor = Txt("层  第" .. tostring(game.floor or 1) .. "层", 22, C.focus, { whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
    topRefs_.level = Txt("Lv." .. tostring(game.level or 1), 22, C.focus, { whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center", textStroke = { width = 2, color = "#000000" } })
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
        height = TOP_ZONE_HEIGHT,
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
            ResourceText(316, topRefs_.level),
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

local function CloseIdleSettingTip()
    idleSettingTipOverlay_ = nil
end

local function ShowIdleSettingTip(title, description)
    CommonPromptDialog.Show {
        kind = "rules",
        queueKey = "rule:" .. tostring(title),
        title = title,
        message = description,
        confirmText = "知道了",
    }
end

local function CreateIdlePolicySwitchRow(title, value, disabled, onChange, switchRegistry, switchId, tipTitle, tipDescription)
    local switch = UI.Toggle {
        width = 78,
        height = 42,
        trackWidth = 64,
        trackHeight = 32,
        thumbSize = 26,
        value = value == true,
        disabled = disabled,
        trackBg = { 28, 42, 65, 255 },
        trackCheckedBgColor = C.success,
        trackBorderColor = C.border,
        thumbCheckedColor = C.text,
        onChange = function(_, checked)
            if onChange then onChange(checked) end
        end,
    }
    if switchRegistry and switchId then
        switchRegistry[switchId] = switch
    end
    return UI.Panel {
        width = "100%",
        height = 86,
        flexShrink = 0,
        position = "relative",
        backgroundImage = ASSETS.ui.infoBarBlue,
        backgroundFit = "sliced",
        backgroundSlice = { 10, 10, 10, 10 },
        opacity = disabled and 0.5 or 1.0,
        children = {
            Txt(title, 22, C.text, {
                position = "absolute",
                left = 24,
                top = 17,
                width = 610,
                height = 36,
                textStroke = { width = 1, color = "#000000" },
            }),
            UI.Panel {
                position = "absolute",
                right = 118,
                top = 13,
                width = 44,
                height = 44,
                clickable = true,
                backgroundImage = "image/ui/dialog/help_button.png",
                backgroundFit = "contain",
                onClick = function()
                    ShowIdleSettingTip(tipTitle or title, tipDescription or "暂无详细说明。")
                end,
            },
            UI.Panel {
                position = "absolute",
                right = 24,
                top = 14,
                width = 78,
                height = 42,
                children = { switch },
            },
        },
    }
end

local function CloseIdleSettings()
    CloseIdleSettingTip()
    if idleSettingsOverlay_ and uiRoot_ then
        uiRoot_:RemoveChild(idleSettingsOverlay_)
    end
    idleSettingsOverlay_ = nil
end

local function ShowIdleSettings()
    if not uiRoot_ then return end
    CloseIdleSettings()
    game = GameStateAdapter.GetViewState()
    local policy = game.inventoryPolicy or {
        pauseOnFull = true,
        autoDecompose = false,
        autoSell = false,
        decomposeRarities = {},
        sellRarities = {},
    }
    local pauseOnFull = policy.pauseOnFull ~= false
    local autoDecompose = policy.autoDecompose == true
    local autoSell = policy.autoSell == true
    local sourceDecompose = policy.decomposeRarities or {}
    local sourceSell = policy.sellRarities or {}
    local decomposeRarities = {
        common = sourceDecompose.common == true,
        advanced = sourceDecompose.advanced == true or sourceDecompose.blue == true,
        rare = sourceDecompose.rare == true or sourceDecompose.purple == true,
        artifact = sourceDecompose.artifact == true,
        legendary = sourceDecompose.legendary == true or sourceDecompose.legend == true,
        epic = sourceDecompose.epic == true,
        myth = false,
    }
    local sellRarities = {
        common = sourceSell.common == true,
        advanced = sourceSell.advanced == true or sourceSell.blue == true,
        rare = sourceSell.rare == true or sourceSell.purple == true,
        artifact = sourceSell.artifact == true,
        legendary = sourceSell.legendary == true or sourceSell.legend == true,
        epic = sourceSell.epic == true,
        myth = false,
    }
    local readOnly = game.readOnly == true
    local automationPolicy = game.automationPolicy or {}
    local lootAutoEquip = automationPolicy.lootAutoEquip == true
    local switches = {}
    local settingsHeight = Clamp(CONFIG.DynamicDesignHeight() - 96, 760, 1660)

    local function BuildPolicy()
        return {
            pauseOnFull = pauseOnFull,
            autoDecompose = autoDecompose,
            autoSell = autoSell,
            decomposeRarities = decomposeRarities,
            sellRarities = sellRarities,
        }
    end

    local function ApplyPolicy()
        actionFns_.SetInventoryPolicy(BuildPolicy())
        RequestPageRefresh()
    end

    local function ConfirmPolicyEnable(options)
        local switch = switches[options.switchId]
        if switch then switch.props.value = false end
        CommonPromptDialog.Show {
            kind = "confirm",
            title = options.title,
            message = options.message,
            lines = options.lines,
            cancelText = "取消",
            confirmText = "确认启用",
            danger = true,
            closeOnOverlay = false,
            zIndex = 2500,
            onCancel = function()
                if switch then switch.props.value = false end
            end,
            onConfirm = function()
                if switch then switch.props.value = true end
                options.apply()
            end,
        }
    end

    local function SetRarity(kind, rarityId, enabled)
        local target = kind == "decompose" and decomposeRarities or sellRarities
        local other = kind == "decompose" and sellRarities or decomposeRarities
        if not enabled then
            target[rarityId] = false
            ApplyPolicy()
            return
        end
        local actionName = kind == "decompose" and "自动分解" or "自动出售"
        ConfirmPolicyEnable {
            switchId = kind .. "_" .. rarityId,
            title = "确认开启" .. actionName,
            message = "开启后，符合条件的" .. RarityName(rarityId) .. "装备会被" .. actionName .. "。",
            lines = { "该设置会影响后续挂机掉落；神话、已穿戴和已锁定装备仍受保护。" },
            apply = function()
                target[rarityId] = true
                other[rarityId] = false
                local otherSwitch = switches[kind == "decompose" and ("sell_" .. rarityId) or ("decompose_" .. rarityId)]
                if otherSwitch then otherSwitch.props.value = false end
                ApplyPolicy()
            end,
        }
    end

    local function AddSwitch(id, title, description, value, onChange)
        return CreateIdlePolicySwitchRow(title, value, readOnly, onChange, switches, id, title, description)
    end

    local function CreateAudioVolumeRow(title, value, onChange)
        local valueLabel = CompactTxt(string.format("%d%%", math.floor(value * 100 + 0.5)), 20, C.focus, {
            position = "absolute",
            right = 24,
            top = 24,
            width = 92,
            height = 38,
            textAlign = "right",
            textStroke = { width = 1, color = "#000000" },
        })
        local slider = UI.Slider {
            width = 520,
            height = 42,
            value = math.floor(value * 100 + 0.5),
            min = 0,
            max = 100,
            step = 1,
            trackHeight = 10,
            thumbSize = 30,
            trackBgColor = { 22, 35, 56, 255 },
            trackFillColor = C.focus,
            thumbColor = C.text,
            thumbBorderColor = C.focus,
            thumbBorderWidth = 2,
            onChange = function(_, sliderValue)
                local normalized = sliderValue / 100
                valueLabel:SetText(string.format("%d%%", math.floor(sliderValue + 0.5)))
                if onChange then onChange(normalized) end
            end,
        }
        return UI.Panel {
            width = "100%",
            height = 86,
            flexShrink = 0,
            position = "relative",
            backgroundImage = ASSETS.ui.infoBarBlue,
            backgroundFit = "sliced",
            backgroundSlice = { 10, 10, 10, 10 },
            children = {
                Txt(title, 22, C.text, {
                    position = "absolute",
                    left = 24,
                    top = 17,
                    width = 220,
                    height = 36,
                    textStroke = { width = 1, color = "#000000" },
                }),
                UI.Panel {
                    position = "absolute",
                    left = 250,
                    top = 22,
                    width = 560,
                    height = 42,
                    children = { slider },
                },
                valueLabel,
            },
        }
    end

    local body = UI.ScrollView {
        position = "absolute",
        left = 58,
        top = 144,
        width = 872,
        height = math.max(500, settingsHeight - 260),
        scrollY = true,
        scrollX = false,
        showScrollbar = false,
        children = {
            UI.Panel {
                width = "100%",
                flexShrink = 0,
                gap = 16,
                paddingBottom = 32,
                children = {
                    Txt("装备处理", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    AddSwitch("loot_auto_equip", "刷宝掉落自动装备", "默认关闭。关闭时装备先进入暂存箱；发现更强同部位装备仍会显示非阻塞对比提示，由玩家决定是否穿戴。", lootAutoEquip, function(value)
                        lootAutoEquip = value
                        ServerClient.SetAutomationPolicy({
                            autoEquip = value,
                            lootAutoEquip = value,
                            autoSkipStory = automationPolicy.autoSkipStory == true,
                        }, ActionResult)
                    end),
                    Txt("背包满时的处理规则", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    AddSwitch("pause", "背包满后暂停挂机", "开启后，背包满且没有可自动处理的装备时，挂机会暂停。关闭后将跳过无法处理的掉落并继续挂机。", pauseOnFull, function(value)
                        pauseOnFull = value
                        ApplyPolicy()
                    end),
                    AddSwitch("decompose", "启用自动分解", "开启后，分解列表中打开的品质。自动分解与自动出售互斥，开启本项会自动关闭自动出售。", autoDecompose, function(value)
                        if not value then
                            autoDecompose = false
                            ApplyPolicy()
                            return
                        end
                        ConfirmPolicyEnable {
                            switchId = "decompose",
                            title = "确认启用自动分解",
                            message = "启用后，挂机过程中符合品质规则的装备会被自动分解。",
                            lines = { "自动分解与自动出售互斥；已穿戴、已锁定和神话装备仍受保护。" },
                            apply = function()
                                autoDecompose = true
                                autoSell = false
                                if switches.sell then switches.sell.props.value = false end
                                ApplyPolicy()
                            end,
                        }
                    end),
                    AddSwitch("sell", "启用自动出售", "开启后，出售列表中打开的品质并获得金币。自动出售与自动分解互斥，开启本项会自动关闭自动分解。", autoSell, function(value)
                        if not value then
                            autoSell = false
                            ApplyPolicy()
                            return
                        end
                        ConfirmPolicyEnable {
                            switchId = "sell",
                            title = "确认启用自动出售",
                            message = "启用后，挂机过程中符合品质规则的装备会被自动出售。",
                            lines = { "自动出售与自动分解互斥；已穿戴、已锁定和神话装备仍受保护。" },
                            apply = function()
                                autoSell = true
                                autoDecompose = false
                                if switches.decompose then switches.decompose.props.value = false end
                                ApplyPolicy()
                            end,
                        }
                    end),
                    Txt("声音设置", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    CreateAudioVolumeRow("背景音乐", AudioController.GetMusicVolume(), AudioController.SetMusicVolume),
                    CreateAudioVolumeRow("音效", AudioController.GetSfxVolume(), AudioController.SetSfxVolume),
                    Txt("自动分解品质", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    AddSwitch("decompose_common", "分解：普通 / 白色", "价值最低，适合作为第一优先级的自动分解对象。", decomposeRarities.common, function(value) SetRarity("decompose", "common", value) end),
                    AddSwitch("decompose_advanced", "分解：高级 / 蓝色", "高级装备将按当前规则自动分解。", decomposeRarities.advanced, function(value) SetRarity("decompose", "advanced", value) end),
                    AddSwitch("decompose_rare", "分解：稀有 / 紫色", "稀有装备价值较高，开启前请确认。", decomposeRarities.rare, function(value) SetRarity("decompose", "rare", value) end),
                    AddSwitch("decompose_artifact", "分解：神器 / 粉色", "神器装备带有核心词条，开启前请确认。", decomposeRarities.artifact, function(value) SetRarity("decompose", "artifact", value) end),
                    AddSwitch("decompose_legendary", "分解：传说 / 赤红", "传说装备默认关闭，避免误分解。", decomposeRarities.legendary, function(value) SetRarity("decompose", "legendary", value) end),
                    AddSwitch("decompose_epic", "分解：史诗 / 橙金", "史诗装备属于套装体系，开启前请确认。", decomposeRarities.epic, function(value) SetRarity("decompose", "epic", value) end),
                    Txt("自动出售品质", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    AddSwitch("sell_common", "出售：普通 / 白色", "价值最低，适合作为第一优先级的自动出售对象。", sellRarities.common, function(value) SetRarity("sell", "common", value) end),
                    AddSwitch("sell_advanced", "出售：高级 / 蓝色", "高级装备将按当前规则自动出售并获得金币。", sellRarities.advanced, function(value) SetRarity("sell", "advanced", value) end),
                    AddSwitch("sell_rare", "出售：稀有 / 紫色", "稀有装备价值较高，开启前请确认。", sellRarities.rare, function(value) SetRarity("sell", "rare", value) end),
                    AddSwitch("sell_artifact", "出售：神器 / 粉色", "神器装备带有核心词条，开启前请确认。", sellRarities.artifact, function(value) SetRarity("sell", "artifact", value) end),
                    AddSwitch("sell_legendary", "出售：传说 / 赤红", "传说装备默认关闭，避免误出售。", sellRarities.legendary, function(value) SetRarity("sell", "legendary", value) end),
                    AddSwitch("sell_epic", "出售：史诗 / 橙金", "史诗装备属于套装体系，开启前请确认。", sellRarities.epic, function(value) SetRarity("sell", "epic", value) end),
                    CreateIdlePolicySwitchRow("神话品质保护", true, true, nil, switches, "myth", "神话品质保护", "神话品质永久保护，不会被自动分解或出售。需要处理时，请到背包中手动操作。"),
                },
            },
        },
    }
    local panel = UI.Panel {
        position = "relative",
        width = 996,
        height = settingsHeight,
        zIndex = 2100,
        clickable = true,
        overflow = "hidden",
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 14, 14, 14, 14 },
        children = {
            Txt("挂机自动处理设置", 32, C.text, { position = "absolute", left = 90, top = 34, width = 760, height = 48, textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
            UI.Panel {
                position = "absolute",
                right = 22,
                top = 24,
                width = 64,
                height = 64,
                clickable = true,
                backgroundImage = "image/ui/dialog/close_button.png",
                backgroundFit = "contain",
                onClick = CloseIdleSettings,
            },
            body,
        },
    }
    idleSettingsOverlay_ = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        zIndex = 2000,
        pointerEvents = "box-none",
        alignItems = "center",
        justifyContent = "center",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                right = 0,
                bottom = 0,
                clickable = true,
                backgroundImage = ASSETS.ui.screenOverlay,
                backgroundFit = "cover",
                onClick = CloseIdleSettings,
            },
            panel,
        },
    }
    uiRoot_:AddChild(idleSettingsOverlay_)
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
            UI.Panel {
                position = "absolute",
                left = 890,
                top = 184,
                width = 64,
                height = 64,
                clickable = true,
                backgroundImage = "image/ui/dialog/help_button.png",
                backgroundFit = "contain",
                onClick = function()
                    CommonPromptDialog.Show {
                        kind = "rules",
                        queueKey = "rules:tower-reward",
                        title = "挂机刷宝说明",
                        message = "在线战斗收益为100%；离线收益固定按20%结算且只折算一次。",
                        lines = {
                            "每层10场：7普通、2精英、1 Boss；每10层为章节 Boss。",
                            "死亡后回到本层第1场，双方满血，已获得奖励保留。",
                            "离线金币、经验、碎片及最终掉落概率均为在线效率的1/5。",
                            "离线时间最多累计 12 小时；背包已满时，未结算时间会保留。",
                            "当前累计离线：" .. FormatDuration(game.pendingOfflineSeconds),
                        },
                        confirmText = "知道了",
                    }
                end,
            },
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
                pointerEvents = "box-none",
                children = {
                    UI.Panel {
                        position = "absolute", left = 0, top = 0, width = 300, height = 44,
                        clickable = true, alignItems = "center", justifyContent = "center",
                        onClick = function() SwitchPage("play") end,
                        children = {
                            Txt("进入刷宝", 23, C.text, {
                                position = "absolute", left = -2, top = 15, width = "100%",
                                textAlign = "center", textStroke = { width = 3, color = "#000000" },
                                pointerEvents = "none",
                            }),
                        },
                    },
                    UI.Panel {
                        position = "absolute", left = 0, top = 62, width = 300, height = 44,
                        clickable = not game.readOnly, opacity = game.readOnly and 0.45 or 1.0,
                        alignItems = "center", justifyContent = "center",
                        onClick = function()
                            if not game.readOnly and not PlayPresentation.SetAutoRun(not game.autoRun) then
                                UI.Toast.Show("挂机状态正在同步，请稍候", {
                                    duration = 1.5,
                                    variant = "info",
                                    position = "bottom",
                                })
                            end
                        end,
                        children = {
                            Txt(game.autoRun and "暂停挂机" or "开始挂机", 23, C.text, {
                                position = "absolute", left = -2, top = 11, width = "100%",
                                textAlign = "center", textStroke = { width = 3, color = "#000000" },
                                pointerEvents = "none",
                            }),
                        },
                    },
                    UI.Panel {
                        position = "absolute", left = 0, top = 124, width = 300, height = 44,
                        clickable = not game.readOnly, opacity = game.readOnly and 0.45 or 1.0,
                        alignItems = "center", justifyContent = "center",
                        onClick = function()
                            if not game.readOnly then actionFns_.CollectOffline() end
                        end,
                        children = {
                            Txt("领取离线", 23, C.text, {
                                position = "absolute", left = -4, top = 9, width = "100%",
                                textAlign = "center", textStroke = { width = 3, color = "#000000" },
                                pointerEvents = "none",
                            }),
                        },
                    },
                }
            },

            UI.Panel {
                position = "absolute",
                left = statGridX,
                top = 604,
                width = statGridW,
                height = statGridH,
                children = {
                    UI.Panel { position = "absolute", left = 0, top = 0, width = statCardW, height = statCardH, children = { FormalStatCard("攻击", FormatInt(stats.atkBig or stats.atk), C.primary, ASSETS.ui.statAtk, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = 0, width = statCardW, height = statCardH, children = { FormalStatCard("防御", FormatInt(stats.defBig or stats.def), C.textSecondary, ASSETS.ui.statDef, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = 0, top = statCardH + statRowGapY, width = statCardW, height = statCardH, children = { FormalStatCard("暴击", FormatPercent(stats.crit), C.gold, ASSETS.ui.statCrit, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = statCardH + statRowGapY, width = statCardW, height = statCardH, children = { FormalStatCard("攻速", string.format("%.1f", stats.atkSpeed), C.mp, ASSETS.ui.statSpeed, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = 0, top = (statCardH + statRowGapY) * 2, width = statCardW, height = statCardH, children = { FormalStatCard("生命", FormatInt(game.hpBig or game.hp) .. "/" .. FormatInt(game.playerMaxHp or stats.hpBig or stats.hp), C.hp, ASSETS.ui.statHp, statCardW, statCardH) } },
                    UI.Panel { position = "absolute", left = statCardW + statGapX, top = (statCardH + statRowGapY) * 2, width = statCardW, height = statCardH, children = { FormalStatCard("战力", (game.displayedPower or stats.power) and FormatInt(game.displayedPower or stats.power) or "待评估", C.gold, ASSETS.ui.statPower, statCardW, statCardH) } },
                }
            },
        }
    }
end

local InventoryView = require("client.InventoryView")
local BuildDispositionContext

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
        getInventoryTabScrollX = function() return inventoryTabScrollX_ end,
        setInventoryTabScrollX = function(value) inventoryTabScrollX_ = value or 0 end,
        getEquipmentScrollY = function() return equipmentScrollY_ end,
        setEquipmentScrollY = function(value) equipmentScrollY_ = value or 0 end,
        getEquipmentPageScrollY = function() return equipmentPageScrollY_ end,
        setEquipmentPageScrollY = function(value) equipmentPageScrollY_ = value or 0 end,
        requestPageRefresh = RequestPageRefresh,
        requestDecomposePreview = ServerClient.DecomposePreview,
        equipItem = actionFns_.EquipItem,
        unequipSlot = actionFns_.UnequipSlot,
        decomposeByFilter = actionFns_.DecomposeByFilter,
        showDecomposeFilter = function(onSaved)
            EquipmentRecycleFilter.Show("decompose", { onSaved = onSaved })
        end,
        showDisposition = function(mode, items)
            EquipmentDispositionDialog.Show(BuildDispositionContext(), { mode = mode, items = items })
        end,
        setEquipmentLock = actionFns_.SetEquipmentLock,
        autoEquipBest = actionFns_.AutoEquipBest,
        strengthenSelected = actionFns_.StrengthenSelected,
        starSelected = actionFns_.StarSelected,
        readOnly = game.readOnly,
        rarityColor = RarityColor,
        rarityName = RarityName,
        slotName = SlotName,
        itemPower = ItemPower,
        compareItemPower = function(left, right)
            return BigNumber.Compare(ItemPower(left), ItemPower(right))
        end,
        itemPowerText = ItemPowerText,
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
        getEquipmentDefinition = EquipmentCatalog.Get,
        showItemTips = function(item, bounds, options)
            options = options or {}
            if options.source == "equipment" and item and item.slot then
                options.allowCompare = true
                options.compareItem = game.equipped and game.equipped[item.slot] or nil
            end
            return ItemTips.Show(item, bounds, options)
        end,
        registerItemTipsTrigger = ItemTips.RegisterTrigger,
    }
end

local function BuildInventoryPage()
    return InventoryView.BuildInventoryPage(BuildInventoryContext())
end

local function BuildEquipmentPage()
    return InventoryView.BuildEquipmentPage(BuildInventoryContext())
end


local function BuildFrameEditorPage()
    return FrameEditorView.Build({
        assets = ASSETS,
        currentPlayer = CurrentPlayer,
        runWidth = RUN_W,
        runHeight = RUN_H,
        runFps = RUN_FPS,
        attackFps = ATTACK_FPS,
        backgroundTop = BG_TILE_TOP,
        backgroundWidth = BG_TILE_W,
        txt = Txt,
        multiTxt = MultiTxt,
        pixelPanel = PixelPanel,
        imageButton = ImageButton,
        refresh = RefreshCurrentPage,
        switchPage = SwitchPage,
    })
end

local function SendStoryDecision(story, action, lineIndex)
    if not story or not story.storyId then return end
    ServerClient.AdvanceStory(action, story.storyId, lineIndex, function(response)
        if not response or not response.ok then ActionResult(response) end
    end)
end

local function ShowStoryGate(story)
    if type(story) ~= "table" or type(story.lines) ~= "table" or #story.lines == 0 then return false end
    return CommonPromptDialog.Show {
        kind = "story",
        queueKey = "story:" .. tostring(story.storyId or story.chapter or "unknown") .. ":" .. tostring(story.phase or "gate"),
        title = story.title or story.speaker or (story.chapter and ("第" .. tostring(story.chapter) .. "章") or "万灵塔记忆"),
        pages = story.lines,
        cancelText = "跳过",
        confirmText = "进入下一幕",
        closeOnOverlay = false,
        onPageAdvance = function(index) SendStoryDecision(story, "next", index) end,
        onConfirm = function() SendStoryDecision(story, "complete", #story.lines) end,
        onCancel = function() SendStoryDecision(story, "skip") end,
    }
end

local EVENT_LABELS = {
    chest = { title = "发现宝箱", confirm = "开启宝箱" },
    merchant = { title = "神秘商人", confirm = "确认购买" },
    randomEvent = { title = "奇遇事件", confirm = "接受" },
}

local function SendEventDecision(pendingEvent, action)
    if not pendingEvent or not pendingEvent.eventId then return end
    ServerClient.ResolveEvent(pendingEvent.eventId, action, function(response)
        if not response or not response.ok then ActionResult(response) end
    end)
end

-- 交互事件弹窗：玩家必须主动选择；服务端超时会按 skip 结算。
local function ShowPendingEvent(pendingEvent)
    if type(pendingEvent) ~= "table" or not pendingEvent.eventId then return false end
    local label = EVENT_LABELS[pendingEvent.eventType] or { title = "遭遇事件", confirm = "确认" }

    local lines = {}
    if pendingEvent.description then lines[#lines + 1] = tostring(pendingEvent.description) end
    if pendingEvent.goldCost then
        lines[#lines + 1] = "花费金币：" .. LargeNumber.ToString(pendingEvent.goldCost)
    end
    if pendingEvent.fragmentsReward then
        lines[#lines + 1] = "获得碎片：" .. tostring(pendingEvent.fragmentsReward)
    end
    local remaining = math.max(0, (tonumber(pendingEvent.expiresAt) or 0) - os.time())
    lines[#lines + 1] = "未选择将在 " .. tostring(remaining) .. " 秒后自动跳过"

    return CommonPromptDialog.Show {
        kind = "event",
        queueKey = "event:" .. tostring(pendingEvent.eventId),
        title = pendingEvent.title or label.title,
        lines = lines,
        confirmText = label.confirm,
        cancelText = "跳过",
        closeOnOverlay = false,
        showClose = false,
        onConfirm = function() SendEventDecision(pendingEvent, "accept") end,
        onCancel = function() SendEventDecision(pendingEvent, "skip") end,
    }
end

local function CloseLootStash(force)
    if lootStashForced_ and force ~= true then return false end
    if lootStashOverlay_ and uiRoot_ then uiRoot_:RemoveChild(lootStashOverlay_) end
    lootStashOverlay_ = nil
    lootStashForced_ = false
    return true
end

local function LootStashItems()
    game = GameStateAdapter.GetViewState()
    local items = {}
    for _, itemId in ipairs(game.lootStash or {}) do
        local item = GetItemById(itemId)
        if item then items[#items + 1] = item end
    end
    return ItemSort.Sort(items)
end

local function ShowLootStash(forced)
    if not uiRoot_ then return false end
    CloseLootStash(true)
    lootStashForced_ = forced == true
    local items = LootStashItems()
    local claimedItems = {}
    for _, item in ipairs(items) do claimedItems[#claimedItems + 1] = item end
    local cards = {}
    local slotContext = BuildInventoryContext()
    for _, item in ipairs(items) do
        cards[#cards + 1] = BackpackItemSlot.Build(slotContext, item, {
            width = 180,
            height = 180,
            clickable = true,
            onClick = function() actionFns_.EquipItem(item) end,
        })
    end
    local content
    if #cards == 0 then
        content = UI.Panel {
            width = 720, height = 560, flexShrink = 0,
            alignItems = "center", justifyContent = "center",
            children = { CompactTxt("暂存箱为空", 24, C.textSecondary, {
                width = "100%", height = 48, textAlign = "center",
            }) },
        }
    else
        local pageLabel = CompactTxt("1 / 1", 17, C.textDim, {
            width = 92, height = 28, textAlign = "right",
        })
        content = OfflineRewardCardPanel(cards, pageLabel)
    end

    local dialogChildren = {
        Txt("在线挂机暂存箱", 32, C.text, {
            position = "absolute", left = 80, top = 30,
            width = 740, height = 54, textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
        }),
        CompactTxt("在线挂机获得的装备已进入背包；点击格子可穿戴，或全部收取后关闭暂存箱", 18, C.textSecondary, {
            position = "absolute", left = 80, top = 88,
            width = 740, height = 34, textAlign = "center",
        }),
        UI.Panel {
            position = "absolute", left = 90, top = 140,
            width = 720, height = 620, children = { content },
        },
        UI.Panel {
            position = "absolute", left = 300, top = 790,
            width = 300, height = 72,
            children = { ImageButton("全部收取", 300, 72, ASSETS.ui.buttonGreen, function()
                if lootStashClaimPending_ then return end
                lootStashClaimPending_ = true
                ServerClient.ClaimLootStash(function(response)
                    lootStashClaimPending_ = false
                    if not ActionResult(response, "暂存装备已全部收取") then return end
                    CloseLootStash(true)
                    local rewardCards = {}
                    for _, item in ipairs(claimedItems) do
                        AddRewardCard(
                            rewardCards,
                            ItemImage(item),
                            item.name or "装备",
                            nil,
                            item.rarity or "common",
                            item
                        )
                    end
                    ShowRewardDialog {
                        title = "暂存箱收取成功",
                        message = "已收取 " .. tostring(#claimedItems) .. " 件在线挂机装备",
                        lines = { "装备已存入背包，可前往背包查看或穿戴。" },
                        confirmText = "确认收取",
                        cards = rewardCards,
                    }
                    ServerClient.RequestSnapshot()
                end)
            end, false) },
        },
    }
    if not lootStashForced_ then
        dialogChildren[#dialogChildren + 1] = UI.Panel {
            position = "absolute", right = 22, top = 22,
            width = 64, height = 64, clickable = true,
            backgroundImage = "image/ui/dialog/close_button.png",
            backgroundFit = "contain", onClick = CloseLootStash,
        }
    end

    lootStashOverlay_ = UI.Panel {
        position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        zIndex = 2200, pointerEvents = "box-none",
        alignItems = "center", justifyContent = "center",
        children = {
            UI.Panel {
                position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
                clickable = true, backgroundImage = "image/ui/generated/screen_overlay_1080x1920.png", backgroundFit = "cover",
                onClick = CloseLootStash,
            },
            UI.Panel {
                position = "relative", width = 900, height = 900,
                clickable = true, overflow = "hidden",
                backgroundImage = ASSETS.ui.panelLarge, backgroundFit = "sliced",
                backgroundSlice = { 14, 14, 14, 14 },
                children = dialogChildren,
            },
        },
    }
    uiRoot_:AddChild(lootStashOverlay_)
    return true
end

-- 上线后若服务端已冻结离线收益，强引导先领取再进入在线玩法。
MaybeShowOfflineLoginGuide = function()
    if offlineLoginGuideShown_ then return false end
    if (game.pendingOfflineSeconds or 0) <= 0 then return false end
    offlineLoginGuideShown_ = true
    local shown = CommonPromptDialog.Show {
        kind = "confirm",
        priority = 1200,
        queueKey = "offline_login_guide",
        title = "离线收益待领取",
        message = "本次离线收益已由服务器结算完成，请先领取。",
        lines = {
            "离线奖励在上线时已锁定，不会受本次在线挂机影响。",
            "领取后金币与装备会直接并入当前角色。",
        },
        closeOnOverlay = false,
        showClose = false,
        confirmText = "领取离线收益",
        onConfirm = function()
            if actionFns_.CollectOffline then
                actionFns_.CollectOffline(CompleteOfflineLoginFlow)
            end
        end,
    }
    if shown then
        offlineLoginFlowPending_ = true
    else
        offlineLoginGuideShown_ = false
    end
    return shown
end

MaybeShowLootStashLoginGuide = function()
    if offlineLoginFlowPending_ then return false end
    if lootStashLoginGuideShown_ then return false end
    if #(game.lootStash or {}) == 0 then return false end
    lootStashLoginGuideShown_ = true
    local count = #game.lootStash
    local shown = CommonPromptDialog.Show {
        kind = "confirm",
        priority = 1000,
        queueKey = "loot_stash_login_guide",
        title = "在线挂机暂存箱待收取",
        message = "上次在线挂机还有 " .. tostring(count) .. " 件装备留在暂存箱中。",
        lines = {
            "请先前往暂存箱确认并全部收取。",
            "离线期间不会继续推进在线挂机，也不会向该暂存箱新增装备。",
        },
        closeOnOverlay = false,
        showClose = false,
        confirmText = "前往收取",
        onConfirm = function() ShowLootStash(true) end,
    }
    if not shown then lootStashLoginGuideShown_ = false end
    return shown
end

local function ShowEquipmentUpgrade(value)
    value = value or {}
    local decisionId = value.decisionId or value.itemId
    if not uiRoot_ or decisionId == nil or tostring(decisionId) == tostring(equipmentUpgradeItemId_) then return false end
    if equipmentUpgradeOverlay_ then uiRoot_:RemoveChild(equipmentUpgradeOverlay_) end
    equipmentUpgradeItemId_ = decisionId
    local item = GetItemById(value.itemId) or value
    local current = game.equipped and game.equipped[item.slot] or nil
    local slotContext = BuildInventoryContext()
    local function Close()
        if equipmentUpgradeOverlay_ and uiRoot_ then uiRoot_:RemoveChild(equipmentUpgradeOverlay_) end
        equipmentUpgradeOverlay_ = nil
        equipmentUpgradeItemId_ = nil
    end
    local children = {
        CompactTxt("发现更强装备", 22, C.gold, {
            position = "absolute", left = 18, top = 10, width = 444, height = 34,
            textAlign = "center", textStroke = { width = 2, color = "#000000" },
        }),
        CompactTxt("当前", 16, C.textSecondary, {
            position = "absolute", left = 24, top = 52, width = 180, height = 26, textAlign = "center",
        }),
        CompactTxt("新装备", 16, C.focus, {
            position = "absolute", left = 276, top = 52, width = 180, height = 26, textAlign = "center",
        }),
        UI.Panel {
            position = "absolute", left = 24, top = 78, width = 180, height = 180,
            children = { BackpackItemSlot.Build(slotContext, current or {
                name = "未装备", rarity = "common", level = 1,
            }, { width = 180, height = 180, clickable = false, showEquipped = false }) },
        },
        UI.Panel {
            position = "absolute", left = 276, top = 78, width = 180, height = 180,
            children = { BackpackItemSlot.Build(slotContext, item, {
                width = 180, height = 180, clickable = false, showEquipped = false,
            }) },
        },
        CompactTxt("战力提升 " .. FormatInt(value.displayedPowerDeltaBig or value.displayedPowerDelta or 0), 18, C.success, {
            position = "absolute", left = 20, top = 270, width = 440, height = 30, textAlign = "center",
            textStroke = { width = 1, color = "#000000" },
        }),
        UI.Panel {
            position = "absolute", left = 24, top = 312, width = 200, height = 58,
            children = { ImageButton("保留原装", 200, 58, ASSETS.ui.buttonBlueWide, function()
                Close()
                ServerClient.DecideEquip("keep", value.itemId, ActionResult)
            end, false) },
        },
        UI.Panel {
            position = "absolute", right = 24, top = 312, width = 200, height = 58,
            children = { ImageButton("立即装备", 200, 58, ASSETS.ui.buttonGreen, function()
                Close()
                ServerClient.DecideEquip("equip", value.itemId, function(response)
                    ActionResult(response, response and response.ok and "装备已穿戴" or nil)
                    if lootStashOverlay_ then ShowLootStash(lootStashForced_) end
                end)
            end, false) },
        },
    }
    equipmentUpgradeOverlay_ = UI.Panel {
        position = "absolute", right = 24, top = 340,
        width = 480, height = 398, zIndex = 1800,
        clickable = true, overflow = "hidden",
        backgroundImage = ASSETS.ui.panelLarge, backgroundFit = "sliced",
        backgroundSlice = { 14, 14, 14, 14 },
        boxShadow = { { x = 0, y = 6, blur = 16, color = { 0, 0, 0, 150 } } },
        children = children,
    }
    uiRoot_:AddChild(equipmentUpgradeOverlay_)
    return true
end

local function ShowTowerRules()
    local function AcknowledgeTowerRules()
        ServerClient.AcknowledgeRules(StoryCatalog.RULE_ID, function(response)
            if not response or not response.ok then ActionResult(response) end
        end)
    end
    CommonPromptDialog.Show {
        kind = "rules",
        queueKey = "rules:" .. StoryCatalog.RULE_ID,
        title = "无尽万灵塔规则",
        message = "在线战斗收益100%，离线固定奖励与最终掉落概率均为20%，只折算一次。",
        lines = {
            "每层10场：7普通、2精英、1 Boss；每10层为章节 Boss。",
            "死亡后回到本层第1场，双方满血，已获得奖励保留。",
            "连续失败两次会准备塔灵援助，第三次挑战前可领取定向装备。",
            "挂机开关只负责运行/暂停，不改变在线收益倍率。",
        },
        confirmText = "知道了",
        onConfirm = AcknowledgeTowerRules,
        onCancel = AcknowledgeTowerRules,
    }
end

local function ShowAidPrompt(value)
    CommonPromptDialog.Show {
        kind = "equipment",
        priority = 500,
        queueKey = "aid:" .. tostring(value and (value.aidId or value.floor) or "pending"),
        title = "塔灵援助",
        message = "连续失败后必须领取最低限度援助，领取后会自动继续挑战。",
        lines = {
            "援助只补到当前层可挑战线，不会提供碾压强度。",
            "援助装备通关前不可出售或分解。",
        },
        closeOnOverlay = false,
        showClose = false,
        confirmText = "领取并继续",
        onConfirm = function()
            ServerClient.ClaimAid(function(response)
                if not ActionResult(response, response and response.ok and "援助已领取" or nil) then
                    ShowAidPrompt(value)
                    return
                end
                ServerClient.AutoRun(true, function(autoRunResponse)
                    ActionResult(autoRunResponse, autoRunResponse and autoRunResponse.ok and "已继续刷宝" or nil)
                end)
            end)
        end,
    }
end

local function ConfigurePlayPresentation()
    PlayPresentation.Configure({
        UI = UI,
        colors = C,
        eventInfo = EVENT_INFO,
        assets = ASSETS,
        txt = Txt,
        compactTxt = CompactTxt,
        shortenText = ShortenText,
        formatInt = FormatInt,
        imageProgress = ImageProgress,
        setImageProgress = SetImageProgress,
        getGame = function() return GameStateAdapter.GetViewState() end,
        getMiddleDesignHeight = function()
            return math.max(520, CONFIG.DynamicDesignHeight() - TOP_ZONE_HEIGHT - BOTTOM_ZONE_HEIGHT)
        end,
        updateTopBar = UpdateTopBar,
        serverClient = ServerClient,
        loadingController = LoadingController,
        actionResult = ActionResult,
        openIdleSettings = ShowIdleSettings,
        openLootStash = ShowLootStash,
        requestAutoRunChange = function(enabled, proceed)
            local currentGame = GameStateAdapter.GetViewState()
            if not enabled and currentGame.page == "play" and currentGame.autoRun and idleRewardTracking_ then
                return ShowIdleRewardSummary(proceed)
            end
            return proceed()
        end,
        showStoryGate = ShowStoryGate,
        showPendingEvent = ShowPendingEvent,
        showEquipmentUpgrade = ShowEquipmentUpgrade,
        showTowerRules = ShowTowerRules,
        showAidPrompt = ShowAidPrompt,
        itemImage = ItemImage,
        rarityColor = RarityColor,
        rarityName = RarityName,
        rarities = RARITIES,
        playFeedback = AudioController.PlayFeedback,
        currentPlayer = CurrentPlayer,
        getRunParams = FrameEditorView.GetRunParams,
        getAttackParams = FrameEditorView.GetAttackParams,
        runW = RUN_W,
        runH = RUN_H,
        runFps = RUN_FPS,
        attackFps = ATTACK_FPS,
        attackDuration = ATTACK_DURATION,
        playerSize = PLAYER_SIZE,
        playerScreenX = PLAYER_SCREEN_X,
        bgTileW = BG_TILE_W,
        bgTileTop = BG_TILE_TOP,
        bgTileH = BG_TILE_H,
        roadY = ROAD_Y,
        lootSize = LOOT_SIZE,
        lootFootOffset = LOOT_FOOT_OFFSET,
        platformPlayerY = PLATFORM_PLAYER_Y,
        enemySize = ENEMY_SIZE,
        eventSpacing = EVENT_SPACING,
        eventTriggerDistance = EVENT_TRIGGER_DISTANCE,
        eventViewCount = EVENT_VIEW_COUNT,
        presentationSpeed = PRESENTATION_SPEED,
    })
end

local function CreatePlayPage()
    return PlayPresentation.BuildPage()
end

BuildDispositionContext = function()
    return {
        C = C,
        ASSETS = ASSETS,
        compactTxt = CompactTxt,
        shortenText = ShortenText,
        rarityColor = RarityColor,
        itemImage = ItemImage,
        itemLevelText = ItemLevelText,
        isEquipped = IsEquipped,
        formatInt = FormatInt,
        onRefresh = RequestPageRefresh,
        toast = function(message, variant)
            UI.Toast.Show(message, { duration = 1.8, variant = variant or "info", position = "bottom" })
        end,
        onError = ActionResult,
        showReward = function(mode, reward)
            local cards = {}
            if not LargeNumber.IsZero(reward.gold) then
                AddRewardCard(cards, ASSETS.items.gold, "金币", "+" .. FormatInt(reward.gold), "epic")
            end
            if not LargeNumber.IsZero(reward.fragments) then
                AddRewardCard(cards, ASSETS.items.crystal, "碎片", "+" .. FormatInt(reward.fragments), "rare")
            end
            ShowRewardDialog {
                title = mode == "sell" and "出售成功" or "分解成功",
                message = string.format("已%s %d 件装备", mode == "sell" and "出售" or "分解", reward.count or 0),
                lines = { "获得资源已存入账户" },
                cards = cards,
                confirmText = "确认收取",
            }
        end,
    }
end

local function CreateMarketPage()
    return MarketView.Build {
        game = GameStateAdapter.GetViewState(),
        C = C,
        ASSETS = ASSETS,
        txt = Txt,
        compactTxt = CompactTxt,
        formatInt = FormatInt,
        rarityColor = RarityColor,
        itemImage = ItemImage,
        itemLevelText = ItemLevelText,
        isEquipped = IsEquipped,
        shortenText = ShortenText,
        showItemTips = ItemTips.Show,
        registerItemTipsTrigger = ItemTips.RegisterTrigger,
        setEquipmentLock = actionFns_.SetEquipmentLock,
        dispositionContext = BuildDispositionContext(),
        onRefresh = RequestPageRefresh,
        showPrompt = function(options)
            return CommonPromptDialog.Show(options)
        end,
    }
end

local function CreatePageContent()
    if game.page == "admin" and game.isAdmin then return AdminPanel.Build(UI, { onChanged = RequestPageRefresh, readOnly = game.readOnly }) end
    if game.page == "bag" then return BuildInventoryPage() end
    if game.page == "codex" then
        return EquipmentCodexView.Build {
            game = game,
            C = C,
            ASSETS = ASSETS,
            txt = Txt,
            compactTxt = CompactTxt,
            formatInt = FormatInt,
            rarityColor = RarityColor,
            itemImage = ItemImage,
            itemLevelText = ItemLevelText,
            onRefresh = RequestPageRefresh,
        }
    end
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
    if game.page == "play" then return PlayPresentation.BuildPage() end
    if game.page == "market" then return CreateMarketPage() end
    if game.page == "frameEditor" then return BuildFrameEditorPage() end
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

local function PerformPageSwitch(pageId)
    local leavingPlay = game.page == "play" and pageId ~= "play"
    if leavingPlay then PlayPresentation.ClearCombatPresentation(true) end
    if pageId == "play" then
        LoadingController.EnsurePlayAssetsReady(function()
            GameStateAdapter.SetPage(pageId)
            game = GameStateAdapter.GetViewState()
            AudioController.SetPage(game.page)
            RefreshCurrentPage()
        end)
        return
    end
    GameStateAdapter.SetPage(pageId)
    game = GameStateAdapter.GetViewState()
    AudioController.SetPage(game.page)
    RefreshCurrentPage()
end

SwitchPage = function(pageId)
    if game.page == pageId then return end
    ItemTips.Hide("page-switch")
    if game.page == "play" and game.autoRun and idleRewardTracking_ then
        ShowIdleRewardSummary(function()
            PerformPageSwitch(pageId)
        end)
        return
    end
    PerformPageSwitch(pageId)
end

local function CreateBottomNav()
    local nav = {
        { id = "home", name = "首页" },
        { id = "bag", name = "背包" },
        { id = "codex", name = "图鉴" },
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
        height = BOTTOM_ZONE_HEIGHT,
        flexShrink = 0,
        position = "relative",
        children = children,
    }
end

local function BuildRoot()
    game = GameStateAdapter.GetViewState()
    local initialPageChildren = {}
    if game.connectionState == "ready" then
        initialPageChildren[1] = CreatePageContent()
    end
    pageContainer_ = UI.Panel {
        id = "middlePageContainer",
        width = "100%",
        height = "100%",
        overflow = "hidden",
        children = initialPageChildren,
    }

    local topZone = UI.Panel {
        id = "topZone",
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        height = TOP_ZONE_HEIGHT,
        overflow = "hidden",
        pointerEvents = "box-none",
        children = { CreateTopBar() },
    }

    local middleZone = UI.Panel {
        id = "middleZone",
        position = "absolute",
        left = 0,
        top = TOP_ZONE_HEIGHT,
        right = 0,
        bottom = BOTTOM_ZONE_HEIGHT,
        overflow = "hidden",
        pointerEvents = "box-none",
        children = { pageContainer_ },
    }

    local bottomZone = UI.Panel {
        id = "bottomZone",
        position = "absolute",
        left = 0,
        right = 0,
        bottom = 0,
        height = BOTTOM_ZONE_HEIGHT,
        overflow = "hidden",
        pointerEvents = "box-none",
        children = { CreateBottomNav() },
    }

    uiRoot_ = UI.Panel {
        id = "verticalAnchorPlane",
        width = CONFIG.DesignW,
        height = "100%",
        flexShrink = 0,
        position = "relative",
        overflow = "hidden",
        pointerEvents = "box-none",
        children = { topZone, middleZone, bottomZone },
    }

    -- SafeAreaView must fill the physical viewport. Its normal-flow child is
    -- the anchor plane, so absolute zone coordinates are relative to the safe
    -- content box rather than to a vertically centered 1920px stage.
    local safeContent = UI.SafeAreaView {
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        edges = { "top", "bottom" },
        nativeMenuInset = true,
        alignItems = "center",
        pointerEvents = "box-none",
        children = {
            UI.Panel {
                width = "100%",
                flexGrow = 1,
                flexBasis = 0,
                alignItems = "center",
                position = "relative",
                pointerEvents = "box-none",
                children = { uiRoot_ },
            },
        },
    }

    screenRoot_ = UI.Panel {
        id = "screenRoot",
        width = "100%",
        height = "100%",
        position = "relative",
        overflow = "hidden",
        backgroundColor = C.background,
        pointerEvents = "box-none",
        children = {
            CreateBackground(),
            safeContent,
        }
    }
    UI.SetRoot(screenRoot_, true)
    CommonPromptDialog.Configure {
        txt = Txt,
        multiTxt = MultiTxt,
    }
    CommonPromptDialog.AttachRoot(screenRoot_)
    ItemTips.Configure {
        C = C,
        ASSETS = ASSETS,
        compactTxt = CompactTxt,
        multiTxt = MultiTxt,
        shortenText = ShortenText,
        rarityColor = RarityColor,
        rarityName = RarityName,
        slotName = SlotName,
        itemImage = ItemImage,
        itemLevelText = ItemLevelText,
        itemPower = ItemPower,
        itemPowerText = ItemPowerText,
        compareMagnitude = BigNumber.Compare,
        formatInt = FormatInt,
        isEquipped = IsEquipped,
        requestDecomposePreview = ServerClient.DecomposePreview,
        showDisposition = function(mode, items)
            EquipmentDispositionDialog.Show(BuildDispositionContext(), { mode = mode, items = items })
        end,
    }
    ItemTips.AttachRoot(screenRoot_)
    LoadingController.AttachRoot(uiRoot_)
    if game.page == "play" then
        LoadingController.EnsurePlayAssetsReady(function() PlayPresentation.Update(0) end)
    end
end

local function InitUI()
    UI.Init({
        theme = AppTheme,
        scale = CONFIG.ViewportScale,
    })
    UI.SetOverflowWarnings(false)
end

local function BindServerEvents()
    ServerClient.On("snapshot", function()
        game = GameStateAdapter.GetViewState()
        if game.autoRun then
            StartIdleRewardTracking()
        elseif idleRewardTracking_ and not idleRewardActionPending_ and not IdleRewardHasValue() then
            idleRewardTracking_ = false
            ResetIdleRewardSummary()
        end
        MaybeShowOfflineLoginGuide()
        MaybeShowLootStashLoginGuide()
        PlayPresentation.HandleSnapshot()
        UpdateTopBar()
        if pageContainer_ then
            RefreshCurrentPage()
        else
            BuildRoot()
        end
        LoadingController.MarkSnapshotReceived()
    end)
    ServerClient.On("snapshotProgress", function(payload)
        LoadingController.MarkSnapshotProgress(payload and payload.received, payload and payload.total)
    end)
    ServerClient.On("delta", function(payload)
        game = GameStateAdapter.GetViewState()
        if game.autoRun then StartIdleRewardTracking() end
        AccumulateIdleRewards(payload and payload.events)
        PlayPresentation.HandleDelta(payload)
        ShowDeltaFeedback(payload)
        UpdateTopBar()
        if game.page == "play" then
            PlayPresentation.Update(0)
        elseif game.page == "home"
            or game.page == "equip"
            or game.page == "bag"
            or game.page == "codex"
        then
            -- These pages render authoritative values as static nodes, so
            -- rebuild after every accepted server delta.
            RequestPageRefresh()
        end
    end)
    ServerClient.On("status", function(payload)
        local state = payload and payload.state or "syncing"
        if state ~= "ready" then
            offlineClaimSequence_ = offlineClaimSequence_ + 1
            if offlineDialogKey_ then DialogCoordinator.CancelByKey(offlineDialogKey_) end
            offlineClaimState_ = OFFLINE_CLAIM_IDLE
            offlineDialogKey_ = nil
            lootStashLoginGuideShown_ = false
            offlineLoginGuideShown_ = false
            offlineLoginFlowPending_ = false
            lootStashClaimPending_ = false
            DialogCoordinator.CancelByKey("loot_stash_login_guide")
            CloseLootStash(true)
            PlayPresentation.CancelPendingAutoRun()
        end
        LoadingController.HandleStatus(state)
        if state == "ready" then
            PreloadItemIcons()
        end
        if not LoadingController.IsActive() then
            game = GameStateAdapter.GetViewState()
            UpdateTopBar()
            if game.page == "play" then PlayPresentation.Update(0) end
        end
    end)
    ServerClient.On("adminResult", function(result) AdminPanel.HandleResult(result, RequestPageRefresh) end)
    ServerClient.On("disconnected", function()
        offlineClaimSequence_ = offlineClaimSequence_ + 1
        if offlineDialogKey_ then DialogCoordinator.CancelByKey(offlineDialogKey_) end
        offlineClaimState_ = OFFLINE_CLAIM_IDLE
        offlineDialogKey_ = nil
        lootStashLoginGuideShown_ = false
        offlineLoginGuideShown_ = false
        offlineLoginFlowPending_ = false
        lootStashClaimPending_ = false
        DialogCoordinator.CancelByKey("loot_stash_login_guide")
        CloseLootStash(true)
        PlayPresentation.CancelPendingAutoRun()
        LoadingController.HandleDisconnected()
        if not LoadingController.IsActive() then
            game = GameStateAdapter.GetViewState()
            UpdateTopBar()
            if game.page == "play" then PlayPresentation.Update(0) end
        end
    end)
    ServerClient.On("error", function(error)
        UI.Toast.Show(error.reason or "网络数据错误", { duration = 2, variant = "error", position = "bottom" })
        LoadingController.HandleError(error.reason)
        if not LoadingController.IsActive() then
            game = GameStateAdapter.GetViewState()
            UpdateTopBar()
            if game.page == "play" then PlayPresentation.Update(0) end
        end
    end)
end

function GameView.Start()
    graphics.windowTitle = CONFIG.Title
    LoadingController.Configure({
        title = CONFIG.Title,
        assets = ASSETS,
        currentPlayer = CurrentPlayer,
        txt = Txt,
        multiTxt = MultiTxt,
        pixelPanel = PixelPanel,
        imageProgress = ImageProgress,
        setImageProgress = SetImageProgress,
    })
    ConfigurePlayPresentation()
    InitUI()
    AudioController.Start()
    viewportWidth_ = graphics:GetWidth()
    viewportHeight_ = graphics:GetHeight()
    ProbeOptionalFonts()
    game = GameStateAdapter.GetViewState()
    BuildRoot()
    AudioController.SetPage(game.page)
    LoadingController.Start(uiRoot_)
    BindServerEvents()
    local ok, reason = ServerClient.Start()
    if not ok then
        LoadingController.HandleError()
        print("[GameView] server start failed: " .. tostring(reason))
    end
    SubscribeToEvent("Update", function(eventType, eventData) GameView.HandleUpdate(eventType, eventData) end)
    print("=== " .. CONFIG.Title .. " client started with DWP loading ===")
end

function GameView.Stop()
    UnsubscribeFromEvent("Update")
    PlayPresentation.Reset()
    CommonPromptDialog.Reset()
    DialogCoordinator.Clear(false)
    ItemTips.Stop()
    LoadingController.Stop()
    ServerClient.Stop()
    AudioController.Stop()
    UI.Shutdown()
end

---@param eventType StringHash|string
---@param eventData VariantMap
function GameView.HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")
    ServerClient.Update(dt)
    LoadingController.Update(dt)
    local state = GameStateAdapter.GetViewState()
    game = state
    if game.page == "play" then PlayPresentation.Update(dt) end
    if game.page == "frameEditor" then FrameEditorView.Update(dt) end
    local physicalWidth = graphics:GetWidth()
    local physicalHeight = graphics:GetHeight()
    if physicalWidth ~= viewportWidth_ or physicalHeight ~= viewportHeight_ then
        viewportWidth_ = physicalWidth
        viewportHeight_ = physicalHeight
        RequestFullRebuild()
    end
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
