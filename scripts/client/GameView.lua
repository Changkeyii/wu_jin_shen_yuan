local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local AdminPanel = require("client.AdminPanel")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")
local ItemTips = require("client.ItemTips")
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
local RewardDialogView = require("client.RewardDialogView")
local RewardFeedbackController = require("client.RewardFeedbackController")
local OfflineClaimController = require("client.OfflineClaimController")
local TopBarView = require("client.TopBarView")
local HomeView = require("client.HomeView")
local IdleSettingsView = require("client.IdleSettingsView")
local EquipmentActionController = require("client.EquipmentActionController")
local LootStashController = require("client.LootStashController")
local EquipmentUpgradePromptController = require("client.EquipmentUpgradePromptController")
local GameplayDialogsController = require("client.GameplayDialogsController")
local NavigationController = require("client.NavigationController")
local EquipmentLoadoutView = require("client.EquipmentLoadoutView")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ItemView = require("client.ItemView")

local CONFIG = GameTheme.CONFIG
local C = GameTheme.Colors
local AppTheme = GameTheme.Theme
local RARITIES = GameTheme.Rarities
local CATEGORIES = GameTheme.Categories
local SLOTS = GameTheme.Slots
local SET_ORDER = GameTheme.SetOrder
local SETS = GameTheme.Sets
local EVENT_INFO = GameTheme.EventInfo

local ASSETS = ViewAssets.ASSETS
local LAYOUT = ViewAssets.LAYOUT

local GameView = {}
local game = GameStateAdapter.GetViewState()
local uiRoot_ = nil
local screenRoot_ = nil
local pageContainer_ = nil
local needsFullRebuild_ = false
local needsPageRefresh_ = false
local inventoryState_ = {
    selectedInventoryId = nil,
    selectedSlot = "weapon",
    selectedCategory = "weapon",
    tabScrollX = 0,
    equipmentScrollY = 0,
    equipmentPageScrollY = 0,
}
local topRefs_ = {}
local viewportWidth_ = 0
local viewportHeight_ = 0

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

local actionFns_ = EquipmentActionController.Configure {
    collectOffline = OfflineClaimController.Collect,
    inventoryState = inventoryState_,
    getGame = GameStateAdapter.GetViewState,
    actionResult = ActionResult,
    requestPageRefresh = RequestPageRefresh,
}

local RefreshCurrentPage
local UpdateTopBar

UpdateTopBar = function()
    game = GameStateAdapter.GetViewState()
    TopBarView.Update(game, topRefs_)
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
        getSelectedInventoryId = function() return inventoryState_.selectedInventoryId end,
        getSelectedSlot = function() return inventoryState_.selectedSlot end,
        getSelectedCategory = function() return inventoryState_.selectedCategory end,
        setSelectedInventoryId = function(value) inventoryState_.selectedInventoryId = value end,
        setSelectedSlot = function(value) inventoryState_.selectedSlot = value end,
        setSelectedCategory = function(value) inventoryState_.selectedCategory = value end,
        getInventoryTabScrollX = function() return inventoryState_.tabScrollX end,
        setInventoryTabScrollX = function(value) inventoryState_.tabScrollX = value or 0 end,
        getEquipmentScrollY = function() return inventoryState_.equipmentScrollY end,
        setEquipmentScrollY = function(value) inventoryState_.equipmentScrollY = value or 0 end,
        getEquipmentPageScrollY = function() return inventoryState_.equipmentPageScrollY end,
        setEquipmentPageScrollY = function(value) inventoryState_.equipmentPageScrollY = value or 0 end,
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
        rarityColor = ItemView.RarityColor,
        rarityName = ItemView.RarityName,
        slotName = ItemView.SlotName,
        itemPower = ItemView.ItemPower,
        compareItemPower = function(left, right)
            return BigNumber.Compare(ItemView.ItemPower(left), ItemView.ItemPower(right))
        end,
        itemPowerText = ItemView.ItemPowerText,
        itemImage = ItemView.ItemImage,
        isEquipped = function(item) return ItemView.IsEquipped(game, item) end,
        getItemById = function(id) return ItemView.GetItemById(game, id) end,
        shortenText = Kit.ShortenText,
        compactTxt = Kit.CompactTxt,
        txt = Kit.Txt,
        imageProgress = Kit.ImageProgress,
        imageButton = Kit.ImageButton,
        pixelPanel = Kit.PixelPanel,
        sectionTitle = Kit.SectionTitle,
        formatInt = Kit.FormatInt,
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
    return EquipmentLoadoutView.Build {
        view = {
            C = C,
            assets = ASSETS,
            slots = SLOTS,
            inventoryEmptyState = ASSETS.ui.inventoryEmptyState,
            characterPortrait = ASSETS.player.icon,
            playerNickname = game.playerNickname,
            clipboard = ui,
            rarityColor = ItemView.RarityColor,
            rarityName = ItemView.RarityName,
            slotName = ItemView.SlotName,
            itemPowerText = ItemView.ItemPowerText,
            itemImage = ItemView.ItemImage,
            itemLevelText = ItemView.ItemLevelText,
            isEquipped = function(item) return ItemView.IsEquipped(game, item) end,
            shortenText = Kit.ShortenText,
            compactTxt = Kit.CompactTxt,
            txt = Kit.Txt,
            imageButton = Kit.ImageButton,
        },
        state = {
            game = game,
            readOnly = game.readOnly,
            getSelectedInventoryId = function() return inventoryState_.selectedInventoryId end,
            getSelectedSlot = function() return inventoryState_.selectedSlot end,
            setSelectedInventoryId = function(value) inventoryState_.selectedInventoryId = value end,
            setSelectedSlot = function(value) inventoryState_.selectedSlot = value end,
            getEquipmentScrollY = function() return inventoryState_.equipmentScrollY end,
            setEquipmentScrollY = function(value) inventoryState_.equipmentScrollY = value or 0 end,
            getEquipmentPageScrollY = function() return inventoryState_.equipmentPageScrollY end,
            setEquipmentPageScrollY = function(value) inventoryState_.equipmentPageScrollY = value or 0 end,
            getItemById = function(id) return ItemView.GetItemById(game, id) end,
        },
        actions = {
            requestPageRefresh = RequestPageRefresh,
            equipItem = actionFns_.EquipItem,
            unequipSlot = actionFns_.UnequipSlot,
            strengthenSelected = actionFns_.StrengthenSelected,
            starSelected = actionFns_.StarSelected,
        },
        tips = {
            show = function(item, bounds, options)
                options = options or {}
                if item and item.slot then
                    options.allowCompare = true
                    options.compareItem = game.equipped and game.equipped[item.slot] or nil
                end
                return ItemTips.Show(item, bounds, options)
            end,
            registerTrigger = ItemTips.RegisterTrigger,
        },
    }
end


local function BuildFrameEditorPage()
    return FrameEditorView.Build({
        assets = ASSETS,
        currentPlayer = ViewAssets.CurrentPlayer,
        runWidth = LAYOUT.RUN_W,
        runHeight = LAYOUT.RUN_H,
        runFps = LAYOUT.RUN_FPS,
        attackFps = LAYOUT.ATTACK_FPS,
        backgroundTop = LAYOUT.BG_TILE_TOP,
        backgroundWidth = LAYOUT.BG_TILE_W,
        txt = Kit.Txt,
        multiTxt = Kit.MultiTxt,
        pixelPanel = Kit.PixelPanel,
        imageButton = Kit.ImageButton,
        refresh = RefreshCurrentPage,
        switchPage = NavigationController.SwitchPage,
    })
end

local function ConfigurePlayPresentation()
    PlayPresentation.Configure({
        UI = UI,
        colors = C,
        eventInfo = EVENT_INFO,
        assets = ASSETS,
        txt = Kit.Txt,
        compactTxt = Kit.CompactTxt,
        shortenText = Kit.ShortenText,
        formatInt = Kit.FormatInt,
        imageProgress = Kit.ImageProgress,
        setImageProgress = Kit.SetImageProgress,
        getGame = function() return GameStateAdapter.GetViewState() end,
        getMiddleDesignHeight = function()
            return math.max(520, CONFIG.DynamicDesignHeight() - LAYOUT.TOP_ZONE_HEIGHT - LAYOUT.BOTTOM_ZONE_HEIGHT)
        end,
        updateTopBar = UpdateTopBar,
        serverClient = ServerClient,
        loadingController = LoadingController,
        actionResult = ActionResult,
        openIdleSettings = function()
            IdleSettingsView.Show {
                uiRoot = uiRoot_,
                setInventoryPolicy = actionFns_.SetInventoryPolicy,
                requestPageRefresh = RequestPageRefresh,
                actionResult = ActionResult,
            }
        end,
        openLootStash = LootStashController.Show,
        requestAutoRunChange = function(enabled, proceed)
            local currentGame = GameStateAdapter.GetViewState()
            if not enabled and currentGame.page == "play" and currentGame.autoRun and RewardFeedbackController.IsTracking() then
                return RewardFeedbackController.ShowIdleSummary(proceed)
            end
            return proceed()
        end,
        showStoryGate = GameplayDialogsController.ShowStoryGate,
        showPendingEvent = GameplayDialogsController.ShowPendingEvent,
        showEquipmentUpgrade = EquipmentUpgradePromptController.Show,
        showTowerRules = GameplayDialogsController.ShowTowerRules,
        showAidPrompt = GameplayDialogsController.ShowAidPrompt,
        itemImage = ItemView.ItemImage,
        rarityColor = ItemView.RarityColor,
        rarityName = ItemView.RarityName,
        rarities = RARITIES,
        playFeedback = AudioController.PlayFeedback,
        currentPlayer = ViewAssets.CurrentPlayer,
        getRunParams = FrameEditorView.GetRunParams,
        getAttackParams = FrameEditorView.GetAttackParams,
        runW = LAYOUT.RUN_W,
        runH = LAYOUT.RUN_H,
        runFps = LAYOUT.RUN_FPS,
        attackFps = LAYOUT.ATTACK_FPS,
        attackDuration = LAYOUT.ATTACK_DURATION,
        playerSize = LAYOUT.PLAYER_SIZE,
        playerScreenX = LAYOUT.PLAYER_SCREEN_X,
        bgTileW = LAYOUT.BG_TILE_W,
        bgTileTop = LAYOUT.BG_TILE_TOP,
        bgTileH = LAYOUT.BG_TILE_H,
        roadY = LAYOUT.ROAD_Y,
        lootSize = LAYOUT.LOOT_SIZE,
        lootFootOffset = LAYOUT.LOOT_FOOT_OFFSET,
        platformPlayerY = LAYOUT.PLATFORM_PLAYER_Y,
        enemySize = LAYOUT.ENEMY_SIZE,
        eventSpacing = LAYOUT.EVENT_SPACING,
        eventTriggerDistance = LAYOUT.EVENT_TRIGGER_DISTANCE,
        eventViewCount = LAYOUT.EVENT_VIEW_COUNT,
        presentationSpeed = LAYOUT.PRESENTATION_SPEED,
    })
end

local function CreatePlayPage()
    return PlayPresentation.BuildPage()
end

BuildDispositionContext = function()
    return {
        C = C,
        ASSETS = ASSETS,
        compactTxt = Kit.CompactTxt,
        shortenText = Kit.ShortenText,
        rarityColor = ItemView.RarityColor,
        itemImage = ItemView.ItemImage,
        itemLevelText = ItemView.ItemLevelText,
        isEquipped = function(item) return ItemView.IsEquipped(game, item) end,
        formatInt = Kit.FormatInt,
        onRefresh = RequestPageRefresh,
        toast = function(message, variant)
            UI.Toast.Show(message, { duration = 1.8, variant = variant or "info", position = "bottom" })
        end,
        onError = ActionResult,
        showReward = function(mode, reward)
            local cards = {}
            if not LargeNumber.IsZero(reward.gold) then
                RewardDialogView.AddCard(cards, ASSETS.items.gold, "金币", "+" .. Kit.FormatInt(reward.gold), "epic")
            end
            if not LargeNumber.IsZero(reward.fragments) then
                RewardDialogView.AddCard(cards, ASSETS.items.crystal, "碎片", "+" .. Kit.FormatInt(reward.fragments), "rare")
            end
            RewardDialogView.Show {
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
        txt = Kit.Txt,
        compactTxt = Kit.CompactTxt,
        formatInt = Kit.FormatInt,
        rarityColor = ItemView.RarityColor,
        itemImage = ItemView.ItemImage,
        itemLevelText = ItemView.ItemLevelText,
        isEquipped = function(item) return ItemView.IsEquipped(game, item) end,
        shortenText = Kit.ShortenText,
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
            txt = Kit.Txt,
            compactTxt = Kit.CompactTxt,
            formatInt = Kit.FormatInt,
            rarityColor = ItemView.RarityColor,
            itemImage = ItemView.ItemImage,
            itemLevelText = ItemView.ItemLevelText,
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
                children = { Kit.CompactTxt("正在同步 Tap 昵称…", 24, C.textSecondary, { width = "100%", textAlign = "center" }) },
            }
        end
        return BuildEquipmentPage()
    end
    if game.page == "play" then return PlayPresentation.BuildPage() end
    if game.page == "market" then return CreateMarketPage() end
    if game.page == "frameEditor" then return BuildFrameEditorPage() end
    return HomeView.Build {
        game = game,
        onEnterPlay = function() NavigationController.SwitchPage("play") end,
        onToggleAutoRun = PlayPresentation.SetAutoRun,
        onCollectOffline = actionFns_.CollectOffline,
    }
end

RefreshCurrentPage = function()
    if not pageContainer_ then RequestFullRebuild(); return end
    game = GameStateAdapter.GetViewState()
    pageContainer_:ClearChildren()
    pageContainer_:AddChild(CreatePageContent())
    UpdateTopBar()
    NavigationController.Update(game)
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
        height = LAYOUT.TOP_ZONE_HEIGHT,
        overflow = "hidden",
        pointerEvents = "box-none",
        children = { TopBarView.Build(game, topRefs_) },
    }

    local middleZone = UI.Panel {
        id = "middleZone",
        position = "absolute",
        left = 0,
        top = LAYOUT.TOP_ZONE_HEIGHT,
        right = 0,
        bottom = LAYOUT.BOTTOM_ZONE_HEIGHT,
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
        height = LAYOUT.BOTTOM_ZONE_HEIGHT,
        overflow = "hidden",
        pointerEvents = "box-none",
        children = { NavigationController.Build(game) },
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
    LootStashController.AttachRoot(uiRoot_)
    EquipmentUpgradePromptController.AttachRoot(uiRoot_)
    CommonPromptDialog.Configure {
        txt = Kit.Txt,
        multiTxt = Kit.MultiTxt,
    }
    CommonPromptDialog.AttachRoot(screenRoot_)
    ItemTips.Configure {
        C = C,
        ASSETS = ASSETS,
        compactTxt = Kit.CompactTxt,
        multiTxt = Kit.MultiTxt,
        shortenText = Kit.ShortenText,
        rarityColor = ItemView.RarityColor,
        rarityName = ItemView.RarityName,
        slotName = ItemView.SlotName,
        itemImage = ItemView.ItemImage,
        itemLevelText = ItemView.ItemLevelText,
        itemPower = ItemView.ItemPower,
        itemPowerText = ItemView.ItemPowerText,
        compareMagnitude = BigNumber.Compare,
        formatInt = Kit.FormatInt,
        isEquipped = function(item) return ItemView.IsEquipped(game, item) end,
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
        RewardFeedbackController.SyncSnapshot()
        OfflineClaimController.MaybeShowLoginGuide()
        LootStashController.MaybeShowLoginGuide()
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
        RewardFeedbackController.AccumulateDelta(payload)
        PlayPresentation.HandleDelta(payload)
        RewardFeedbackController.PresentDelta(payload)
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
            OfflineClaimController.Reset()
            LootStashController.ResetConnection()
            PlayPresentation.CancelPendingAutoRun()
        end
        LoadingController.HandleStatus(state)
        if state == "ready" then
            ViewAssets.PreloadItemIcons()
        end
        if not LoadingController.IsActive() then
            game = GameStateAdapter.GetViewState()
            UpdateTopBar()
            if game.page == "play" then PlayPresentation.Update(0) end
        end
    end)
    ServerClient.On("adminResult", function(result) AdminPanel.HandleResult(result, RequestPageRefresh) end)
    ServerClient.On("disconnected", function()
        OfflineClaimController.Reset()
        LootStashController.ResetConnection()
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
    NavigationController.Configure {
        refreshPage = function() RefreshCurrentPage() end,
        isIdleRewardTracking = RewardFeedbackController.IsTracking,
        showIdleRewardSummary = RewardFeedbackController.ShowIdleSummary,
    }
    GameplayDialogsController.Configure {
        actionResult = ActionResult,
    }
    EquipmentUpgradePromptController.Configure {
        buildInventoryContext = BuildInventoryContext,
        actionResult = ActionResult,
        refreshLootStash = LootStashController.RefreshIfOpen,
    }
    LootStashController.Configure {
        buildInventoryContext = BuildInventoryContext,
        equipItem = actionFns_.EquipItem,
        actionResult = ActionResult,
        isOfflineLoginFlowPending = OfflineClaimController.IsLoginFlowPending,
    }
    OfflineClaimController.Configure {
        showActionResult = ActionResult,
        onLoginFlowCompleted = function()
            game = GameStateAdapter.GetViewState()
            LootStashController.MaybeShowLoginGuide()
        end,
    }
    graphics.windowTitle = CONFIG.Title
    LoadingController.Configure({
        title = CONFIG.Title,
        assets = ASSETS,
        currentPlayer = ViewAssets.CurrentPlayer,
        txt = Kit.Txt,
        multiTxt = Kit.MultiTxt,
        pixelPanel = Kit.PixelPanel,
        imageProgress = Kit.ImageProgress,
        setImageProgress = Kit.SetImageProgress,
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
    RewardFeedbackController.Reset()
    NavigationController.Reset()
    EquipmentUpgradePromptController.Reset()
    LootStashController.Reset()
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
