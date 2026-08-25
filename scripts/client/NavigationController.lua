local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local GameStateAdapter = require("client.GameStateAdapter")
local LoadingController = require("client.LoadingController")
local PlayPresentation = require("client.PlayPresentation")
local AudioController = require("client.AudioController")
local ItemTips = require("client.ItemTips")
local ItemView = require("client.ItemView")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")

local CONFIG = GameTheme.CONFIG
local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS
local LAYOUT = ViewAssets.LAYOUT

local NavigationController = {}

local context_ = nil
local refs_ = {}

local function CurrentGame()
    return GameStateAdapter.GetViewState()
end

local function IsTutorialLocked(game)
    local tutorial = (game or CurrentGame()).tutorial
    return type(tutorial) == "table" and tutorial.completed ~= true
end

local function PerformSwitch(pageId, options)
    options = options or {}
    local game = CurrentGame()
    if game.page == "play" and pageId ~= "play" then
        PlayPresentation.ClearCombatPresentation(true)
    end
    local function CompleteSwitch()
        local currentBeforeSwitch = CurrentGame()
        if IsTutorialLocked(currentBeforeSwitch) and options.tutorial ~= true then
            print("[TutorialLock] blocked deferred page switch: "
                .. tostring(currentBeforeSwitch.page) .. " -> " .. tostring(pageId))
            return
        end
        GameStateAdapter.SetPage(pageId)
        local current = CurrentGame()
        AudioController.SetPage(current.page)
        context_.refreshPage()
        if context_.onPageChanged then context_.onPageChanged(current.page) end
    end
    if pageId == "play" then
        LoadingController.EnsurePlayAssetsReady(CompleteSwitch)
        return
    end
    CompleteSwitch()
end

function NavigationController.Configure(context)
    context_ = assert(context)
end

function NavigationController.SwitchPage(pageId, options)
    options = options or {}
    if not context_ then return false end
    local game = CurrentGame()
    -- 序章由 TutorialController 独占导航控制；指针锁之外再封死程序化切页。
    if IsTutorialLocked(game) and options.tutorial ~= true then
        print("[TutorialLock] blocked page switch: " .. tostring(game.page)
            .. " -> " .. tostring(pageId))
        return false
    end
    if game.page == pageId then return true end
    ItemTips.Hide("page-switch")
    if game.page == "play" and game.autoRun and context_.isIdleRewardTracking() then
        context_.showIdleRewardSummary(function()
            PerformSwitch(pageId, options)
        end)
        return true
    end
    PerformSwitch(pageId, options)
    return true
end

local function HasEquipRedDot(game)
    game = game or CurrentGame()
    local flags = game.uiFlags
    if type(flags) == "table" and flags.hasBetterUnequipped ~= nil then
        return flags.hasBetterUnequipped == true
    end
    return ItemView.HasBetterUnequipped(game)
end

function NavigationController.Update(game)
    game = game or CurrentGame()
    for id, ref in pairs(refs_) do
        local active = game.page == id
        if ref.selected then ref.selected:SetStyle({ visible = active }) end
        if ref.label then ref.label:SetFontColor(active and C.text or C.textSecondary) end
        if ref.badge then
            local show = id == "equip" and HasEquipRedDot(game)
            ref.badge:SetStyle({ visible = show })
        end
    end
end

function NavigationController.Build(game)
    game = game or CurrentGame()
    local nav = {
        { id = "home", name = "首页" },
        { id = "bag", name = "背包" },
        { id = "codex", name = "图鉴" },
        { id = "equip", name = "装备" },
        { id = "play", name = "登塔" },
        { id = "market", name = "市场" },
    }
    -- 管理页入口已改为「邮件入口长按 5 秒」（仅管理员，服务端校验），不再出现在底部导航。

    local navAreaX = 28
    local navAreaW = 1024
    local slotW = navAreaW / #nav
    local buttonW = math.min(190, slotW - 8)
    refs_ = {}
    local children = {
        UI.Panel {
            position = "absolute",
            left = 0,
            top = 0,
            width = CONFIG.DesignW,
            height = 180,
            backgroundImage = ASSETS.ui.bottomNav,
            backgroundFit = "contain",
        },
    }

    for i, item in ipairs(nav) do
        local active = game.page == item.id
        local itemId = item.id
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
        local label = Kit.Txt(item.name, 29, active and C.text or C.textSecondary, {
            position = "absolute",
            left = 0,
            top = 42,
            width = buttonW,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
        })
        local badge = nil
        if itemId == "equip" then
            badge = UI.Panel {
                position = "absolute",
                right = math.max(8, math.floor(buttonW * 0.18)),
                top = 18,
                width = 22,
                height = 22,
                shape = "circle",
                overflow = "hidden",
                visible = HasEquipRedDot(game),
                backgroundColor = C.error,
                borderWidth = 2,
                borderColor = { 0, 0, 0, 160 },
                pointerEvents = "none",
            }
        end
        local button = UI.Panel {
            -- 序章功能介绍：底部导航高亮目标
            id = "tutorialFeatureNav:" .. tostring(itemId),
            position = "absolute",
            left = x,
            top = 28,
            width = buttonW,
            height = 126,
            overflow = "visible",
            clickable = true,
            onClick = function()
                if CurrentGame().page ~= itemId then NavigationController.SwitchPage(itemId) end
            end,
            children = { buttonBg, selected, label, badge },
        }
        refs_[itemId] = { button = button, selected = selected, label = label, badge = badge }
        children[#children + 1] = button
    end

    return UI.Panel {
        width = "100%",
        height = LAYOUT.BOTTOM_ZONE_HEIGHT,
        flexShrink = 0,
        position = "relative",
        children = children,
    }
end

function NavigationController.Reset()
    refs_ = {}
    context_ = nil
end

return NavigationController
