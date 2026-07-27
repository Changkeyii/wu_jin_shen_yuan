local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local AdminPanel = require("client.AdminPanel")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")
local StoryCatalog = require("shared.StoryCatalog")
local ItemTooltip = require("urhox-libs/UI/Components/ItemTooltip")
local FrameEditorView = require("client.FrameEditorView")
local LoadingController = require("client.LoadingController")
local PlayPresentation = require("client.PlayPresentation")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DialogCoordinator = require("client.DialogCoordinator")
local AudioController = require("client.AudioController")

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
local pageContainer_ = nil
local needsFullRebuild_ = false
local needsPageRefresh_ = false
local selectedInventoryId_ = nil
local selectedSlot_ = "weapon"
local selectedCategory_ = "weapon"
local inventoryTabScrollX_ = 0
local equipmentScrollY_ = 0
local equipmentPageScrollY_ = 0
local collectingOffline_ = false
local rewardDialogSequence_ = 0
local topRefs_ = {}
local navRefs_ = {}
local viewportWidth_ = 0
local viewportHeight_ = 0

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
        idleSettings = "image/punk_idle_settings_icon_20260722080342.png",
        inventoryActionBlue = "image/ui/inventory/action_blue.png",
        inventoryActionRed = "image/ui/inventory/action_red.png",
        inventoryActionGold = "image/ui/inventory/action_gold.png",
        inventoryItemCard = "image/ui/inventory/item_card.png",
        inventoryEmptyState = "image/inventory_empty_state_20260720075957.png",
        inventoryItemCardSelected = "image/ui/inventory/item_card_selected.png",
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
        sword = "image/cyber_item_sword_20260725004709.png",
        armor = "image/cyber_item_armor_20260725004650.png",
        ring = "image/cyber_item_ring_20260725004652.png",
        boots = "image/cyber_item_boots_20260725004701.png",
        amulet = "image/cyber_item_amulet_20260725004651.png",
        chest = "image/cyber_item_chest_20260725004656.png",
        gold = "image/cyber_gold_coin_clear_20260725054437.png",
        potion = "image/cyber_item_potion_20260725004649.png",
        crystal = "image/cyber_item_crystal_20260725004653.png",
    },
}

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
    NO_OFFLINE_REWARD = "暂无可领取的离线收益（离线满15秒后可领取）",
    INVENTORY_FULL = "背包已满，请先清理装备后再操作",
    NOT_READY = "正在连接服务器，请稍后再试",
    RATE_LIMITED = "操作太频繁，请稍后再试",
    REQUEST_TIMEOUT = "服务器响应超时，请稍后重试",
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
    local delta = data and data.delta
    for _, value in ipairs((delta and delta.events) or {}) do
        if value.kind == "offline_collected" then return value end
    end
    return nil
end

local function OfflineRewardItemCard(icon, name, amount, rarity)
    local rarityInfo = RARITIES[rarity or "common"] or RARITIES.common
    local color = rarityInfo.color or C.text
    return UI.Panel {
        width = 164,
        height = 188,
        flexShrink = 0,
        alignItems = "center",
        paddingTop = 12,
        gap = 8,
        backgroundImage = ASSETS.ui.inventoryItemCard,
        backgroundFit = "sliced",
        backgroundSlice = { 14, 14, 14, 14 },
        borderWidth = 3,
        borderColor = color,
        boxShadow = {
            { x = 0, y = 6, blur = 0, color = { 0, 0, 0, 90 } },
            { x = 0, y = 0, blur = 14, color = { color[1], color[2], color[3], 75 } },
        },
        children = {
            UI.Panel {
                width = 94,
                height = 94,
                backgroundImage = icon,
                backgroundFit = "contain",
                pointerEvents = "none",
            },
            CompactTxt(ShortenText(name, 7), 18, color, {
                width = 146,
                height = 30,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
            CompactTxt(amount, 20, C.text, {
                width = 146,
                height = 30,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            }),
        },
    }
end

local function AddRewardCard(cards, icon, name, amount, rarity)
    cards[#cards + 1] = OfflineRewardItemCard(icon, name, amount, rarity)
end

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
        message = options.message or "奖励已存入背包",
        lines = options.lines or {},
        closeOnOverlay = false,
        showClose = false,
        confirmText = options.confirmText or "确认收取",
        contentBuilder = function()
            return UI.Panel {
                width = "100%",
                flexShrink = 0,
                flexDirection = "row",
                flexWrap = "wrap",
                justifyContent = "center",
                gap = 14,
                paddingTop = 8,
                children = cards,
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
        if kind == "equipment_drop" or kind == "equipment_granted" or kind == "tower_aid_equipment" then
            local itemId = tostring(value.itemId or value.equipmentId or index)
            if not equipmentById[itemId] then
                equipmentById[itemId] = true
                local item = GetItemById(value.itemId) or value
                AddRewardCard(
                    cards,
                    ItemImage(item),
                    value.name or item.name or "装备",
                    RarityName(value.rarity or item.rarity or "common") .. " ×1",
                    value.rarity or item.rarity
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

local function ShowOfflineRewardDialog(value)
    value = value or {}
    local cards = {
        OfflineRewardItemCard(ASSETS.items.gold, "金币", "+" .. FormatInt(value.gold or 0), "epic"),
        OfflineRewardItemCard(ASSETS.items.crystal, "经验", "+" .. FormatInt(value.exp or 0), "advanced"),
        OfflineRewardItemCard(ASSETS.items.crystal, "碎片", "+" .. FormatInt(value.fragments or 0), "rare"),
    }
    for _, item in ipairs(value.equipmentItems or {}) do
        cards[#cards + 1] = OfflineRewardItemCard(
            ItemImage(item),
            item.name or "装备",
            RarityName(item.rarity or "common") .. " ×" .. tostring(item.quantity or 1),
            item.rarity
        )
    end
    if (value.equipment or 0) > 0 and #(value.equipmentItems or {}) == 0 then
        cards[#cards + 1] = OfflineRewardItemCard(
            ASSETS.items.chest,
            "装备",
            tostring(value.equipment or 0) .. "件",
            "rare"
        )
    end
    local lines = {
        "离线期间仅重复挑战第" .. tostring(value.floor or game.floor or 1) .. "层，不会自动突破楼层。",
        "金币、经验、碎片与最终装备掉落概率均按在线收益的1/5结算。",
    }
    if value.interrupted then
        lines[#lines + 1] = "背包已满，尚未结算的离线时间已保留。"
    elseif (value.remainingSeconds or 0) > 0 then
        lines[#lines + 1] = "剩余离线时间：" .. FormatDuration(value.remainingSeconds)
    end
    CommonPromptDialog.Show {
        kind = "equipment",
        priority = 450,
        queueKey = "offline_reward:" .. tostring(value.processedSeconds or 0) .. ":" .. tostring(value.floor or 1),
        title = "离线收益",
        message = "离线战斗结算完成",
        lines = lines,
        closeOnOverlay = false,
        showClose = false,
        confirmText = "确认收取",
        contentBuilder = function()
            return UI.Panel {
                width = "100%",
                flexShrink = 0,
                flexDirection = "row",
                flexWrap = "wrap",
                justifyContent = "center",
                gap = 14,
                paddingTop = 8,
                children = cards,
            }
        end,
    }
end

local function DecomposeRankLabel(maxRank)
    for _, rarityId in ipairs(RARITY_ORDER) do
        local rarity = RARITIES[rarityId]
        if rarity.rank == maxRank then
            return rarity.name .. "（" .. rarity.short .. "色）"
        end
    end
    return "指定品质"
end

local function CollectDecomposeCandidates(maxRank)
    game = GameStateAdapter.GetViewState()
    local candidateIds = {}
    for _, item in ipairs(game.inventory or {}) do
        local rarity = RARITIES[item.rarity]
        if item.equipmentId and item.id ~= nil
            and rarity and rarity.rank <= maxRank
            and not item.locked and not IsEquipped(item) then
            candidateIds[#candidateIds + 1] = item.id
        end
    end
    return candidateIds
end

local actionFns_ = {}
actionFns_.CollectOffline = function()
    if collectingOffline_ then
        UI.Toast.Show("正在领取离线收益，请稍候", { duration = 1.5, variant = "info", position = "bottom" })
        return
    end
    collectingOffline_ = true
    ServerClient.CollectOffline(function(response)
        collectingOffline_ = false
        if not ActionResult(response) then return end
        local reward = OfflineRewardEvent(response)
        if reward then
            ShowOfflineRewardDialog(reward)
        else
            UI.Toast.Show("离线收益已领取", { duration = 2.0, variant = "success", position = "bottom" })
        end
        -- Delta normally refreshes the page first; the snapshot is a safety net
        -- for a temporarily dropped delta so the visible totals still converge.
        ServerClient.RequestSnapshot()
    end)
end
actionFns_.EquipItem = function(item)
    if item and item.id then
        selectedSlot_ = item.slot or selectedSlot_
        ServerClient.Equip(item.id, function(response)
            if not ActionResult(response, "装备已穿戴") then return end
            RequestPageRefresh()
            -- Delta is authoritative; this snapshot only covers a dropped
            -- delta so the equipment page cannot remain visually stale.
            ServerClient.RequestSnapshot()
        end)
    end
end
actionFns_.UnequipSlot = function(slotId)
    if slotId then
        selectedSlot_ = slotId
        ServerClient.Unequip(slotId, ActionResult)
    end
end
actionFns_.AutoEquipBest = function() ServerClient.AutoEquip(ActionResult) end
actionFns_.DecomposeByRank = function(maxRank)
    local candidateIds = CollectDecomposeCandidates(maxRank)
    local count = #candidateIds
    if count <= 0 then
        UI.Toast.Show("没有符合条件的未锁定、未穿戴装备", { duration = 1.8, variant = "info", position = "bottom" })
        return
    end
    CommonPromptDialog.Show {
        kind = "confirm",
        title = "确认批量分解",
        message = "将永久分解 " .. tostring(count) .. " 件装备",
        lines = {
            "品质范围：" .. DecomposeRankLabel(maxRank) .. "及以下。",
            "已穿戴和已锁定装备会自动跳过；分解完成后无法撤销。",
        },
        cancelText = "取消",
        confirmText = "确认分解",
        danger = true,
        closeOnOverlay = false,
        zIndex = 2500,
        onConfirm = function() ServerClient.Decompose(maxRank, candidateIds, ActionResult) end,
    }
end
actionFns_.SetEquipmentLock = function(item) ServerClient.SetEquipmentLock(item.id, not item.locked, ActionResult) end
actionFns_.SetInventoryPolicy = function(policy) ServerClient.SetInventoryPolicy(policy, ActionResult) end
local function UpgradeCostLines(kind, slotId)
    local costs = game.upgradeCosts or game.equipmentUpgradeCosts or {}
    local slotCosts = costs[slotId] or {}
    local value = slotCosts[kind] or slotCosts[kind == "star" and "starUp" or "strengthen"]
    if type(value) ~= "table" then
        return { "最终消耗和成功结果由服务端结算；确认前不会扣除资源。" }
    end
    local parts = {}
    if value.gold ~= nil then parts[#parts + 1] = "金币 " .. FormatInt(value.gold) end
    if value.fragments ~= nil then parts[#parts + 1] = "碎片 " .. FormatInt(value.fragments) end
    if value.materials ~= nil then parts[#parts + 1] = "材料 " .. FormatInt(value.materials) end
    return { #parts > 0 and ("本次预计消耗：" .. table.concat(parts, "、")) or "具体消耗以服务端结算为准。" }
end
actionFns_.StrengthenSelected = function()
    local slotId = selectedSlot_
    CommonPromptDialog.Show {
        kind = "confirm",
        title = "确认强化",
        message = "将强化当前" .. SlotName(slotId) .. "装备。",
        lines = UpgradeCostLines("strengthen", slotId),
        cancelText = "取消",
        confirmText = "确认强化",
        closeOnOverlay = false,
        onConfirm = function() ServerClient.Strengthen(slotId, ActionResult) end,
    }
end
actionFns_.StarSelected = function()
    local slotId = selectedSlot_
    CommonPromptDialog.Show {
        kind = "confirm",
        title = "确认升星",
        message = "升星会消耗资源，是否为当前" .. SlotName(slotId) .. "装备升星？",
        lines = UpgradeCostLines("star", slotId),
        cancelText = "取消",
        confirmText = "确认升星",
        danger = true,
        closeOnOverlay = false,
        onConfirm = function() ServerClient.Star(slotId, ActionResult) end,
    }
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
        equipItem = actionFns_.EquipItem,
        unequipSlot = actionFns_.UnequipSlot,
        decomposeByRank = actionFns_.DecomposeByRank,
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
        showItemTooltip = function(item, bounds)
            if item then
                ItemTooltip.Show({
                    name = item.name,
                    rarity = item.rarity,
                    description = (item.setName and (item.setName .. "；") or "") .. (item.description or ""),
                    stats = {
                        ["部位"] = SlotName(item.slot),
                        ["等级"] = ItemLevelText(item),
                        ["强化"] = "+" .. tostring(item.enhance or 0),
                        ["星级"] = tostring(item.star or 0),
                        ["战力"] = ItemPowerText(item),
                    },
                }, bounds)
            end
        end,
        hideItemTooltip = ItemTooltip.Hide,
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

local function MetricLine(label, value, suffix)
    if value == nil then return nil end
    return label .. FormatInt(value) .. (suffix or "")
end

local function ShowEquipmentUpgrade(value)
    value = value or {}
    local lines = {}
    local candidates = {
        MetricLine("总战力：", value.newPower or value.displayedPower),
        MetricLine("战力提升：", value.displayedPowerDeltaBig or value.displayedPowerDelta
            or value.powerDeltaBig or value.powerDelta,
            value.powerDeltaPercent and ("（" .. string.format("%.1f%%", value.powerDeltaPercent * 100) .. "）") or ""),
        MetricLine("Boss DPS：", value.bossDps),
        MetricLine("有效生命：", value.effectiveHp or value.ehp),
        MetricLine("预计可推进：", value.estimatedEasyFloor, "层"),
        value.setChange and ("套装变化：" .. tostring(value.setChange)) or nil,
    }
    for _, line in ipairs(candidates) do if line then lines[#lines + 1] = line end end
    if #lines == 0 then lines[1] = "完整换装收益已由服务端战斗核评估。" end
    local decisionId = value.decisionId or value.itemId
    CommonPromptDialog.Show {
        kind = "equipment",
        queueKey = decisionId and ("equip:" .. tostring(decisionId)) or nil,
        title = "发现更强装备",
        message = "该装备可提升完整配装表现，是否更换？",
        lines = lines,
        contentBuilder = function()
            return UI.Panel {
                width = "100%",
                height = 58,
                flexShrink = 0,
                alignItems = "center",
                justifyContent = "center",
                children = {
                    CompactTxt(
                        ShortenText(
                            value.name or "新装备",
                            22
                        ),
                        26,
                        RarityColor(
                            value.rarity or "common"
                        ),
                        {
                            width = "100%",
                            height = 42,
                            textAlign = "center",
                            textStroke = {
                                width = 2,
                                color = "#000000",
                            },
                            pointerEvents = "none",
                        }
                    ),
                },
            }
        end,
        cancelText = "保留原装",
        confirmText = "立即更换",
        onConfirm = function()
            ServerClient.DecideEquip("equip", value.itemId, ActionResult)
        end,
        onCancel = function()
            ServerClient.DecideEquip("keep", value.itemId, ActionResult)
        end,
    }
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
        showStoryGate = ShowStoryGate,
        showEquipmentUpgrade = ShowEquipmentUpgrade,
        showTowerRules = ShowTowerRules,
        showAidPrompt = ShowAidPrompt,
        itemImage = ItemImage,
        rarityColor = RarityColor,
        rarityName = RarityName,
        rarities = RARITIES,
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

SwitchPage = function(pageId)
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
        PlayPresentation.HandleDelta(payload)
        ShowDeltaFeedback(payload)
        UpdateTopBar()
        if game.page == "play" then
            PlayPresentation.Update(0)
        elseif game.page == "home"
            or game.page == "equip"
            or game.page == "bag"
        then
            -- These pages render authoritative values as static nodes, so
            -- rebuild after every accepted server delta.
            RequestPageRefresh()
        end
    end)
    ServerClient.On("status", function(payload)
        local state = payload and payload.state or "syncing"
        if state ~= "ready" then
            collectingOffline_ = false
            PlayPresentation.CancelPendingAutoRun()
        end
        LoadingController.HandleStatus(state)
        if not LoadingController.IsActive() then
            game = GameStateAdapter.GetViewState()
            UpdateTopBar()
            if game.page == "play" then PlayPresentation.Update(0) end
        end
    end)
    ServerClient.On("adminResult", function(result) AdminPanel.HandleResult(result, RequestPageRefresh) end)
    ServerClient.On("disconnected", function()
        collectingOffline_ = false
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
