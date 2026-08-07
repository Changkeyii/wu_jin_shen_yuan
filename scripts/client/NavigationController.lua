local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local GameStateAdapter = require("client.GameStateAdapter")
local LoadingController = require("client.LoadingController")
local PlayPresentation = require("client.PlayPresentation")
local AudioController = require("client.AudioController")
local ItemTips = require("client.ItemTips")
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

local function PerformSwitch(pageId)
    local game = CurrentGame()
    if game.page == "play" and pageId ~= "play" then
        PlayPresentation.ClearCombatPresentation(true)
    end
    local function CompleteSwitch()
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

function NavigationController.SwitchPage(pageId)
    if not context_ then return end
    local game = CurrentGame()
    if game.page == pageId then return end
    ItemTips.Hide("page-switch")
    if game.page == "play" and game.autoRun and context_.isIdleRewardTracking() then
        context_.showIdleRewardSummary(function()
            PerformSwitch(pageId)
        end)
        return
    end
    PerformSwitch(pageId)
end

function NavigationController.Update(game)
    game = game or CurrentGame()
    for id, ref in pairs(refs_) do
        local active = game.page == id
        if ref.selected then ref.selected:SetStyle({ visible = active }) end
        if ref.label then ref.label:SetFontColor(active and C.text or C.textSecondary) end
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
        local button = UI.Panel {
            position = "absolute",
            left = x,
            top = 28,
            width = buttonW,
            height = 126,
            clickable = true,
            onClick = function()
                if CurrentGame().page ~= itemId then NavigationController.SwitchPage(itemId) end
            end,
            children = { buttonBg, selected, label },
        }
        refs_[itemId] = { button = button, selected = selected, label = label }
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
