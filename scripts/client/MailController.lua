-- MailController.lua
-- 邮件入口控制器：打开邮件面板；邮件入口长按 5 秒进入 GM（仅管理员，服务端校验）。

local UI = require("urhox-libs/UI")
local GameStateAdapter = require("client.GameStateAdapter")
local MailView = require("client.MailView")
local NavigationController = require("client.NavigationController")

local MailController = {}

local LONG_PRESS_SECONDS = 5
local TITLE_TAP_COUNT = 8
local TITLE_TAP_GAP_SECONDS = 2

local pressing_ = false
local timer_ = 0
local triggered_ = false
local titleTapCount_ = 0
local titleTapGap_ = 0

--- 由邮件入口的 pointer 事件调用，上报是否正在按住
function MailController.SetPressing(pressing)
    if pressing == pressing_ then return end
    pressing_ = pressing
    if pressing then
        timer_ = 0
        triggered_ = false
    else
        timer_ = 0
    end
end

--- 长按触发后是否已进入 GM（用于抑制释放时的单击打开邮件）
function MailController.WasLongPressed()
    return triggered_
end

--- 打开 GM（管理员通道）。isAdmin 由服务端快照下发，GM 命令侧再二次校验 auth="admin"。
function MailController.OpenGM()
    local game = GameStateAdapter.GetViewState()
    if game and game.isAdmin then
        MailView.Hide()
        if game.page ~= "admin" then
            NavigationController.SwitchPage("admin")
        end
        UI.Toast.Show("管理员通道已开启", { duration = 1.5, variant = "info", position = "bottom" })
    else
        UI.Toast.Show("无管理员权限", { duration = 1.5, variant = "error", position = "bottom" })
    end
end

-- 首页标题连点只负责触发既有入口，不授予管理员权限。
function MailController.OnHomeTitleClick()
    local game = GameStateAdapter.GetViewState()
    if not game or game.page ~= "home" then
        titleTapCount_, titleTapGap_ = 0, 0
        return
    end
    titleTapCount_ = titleTapCount_ + 1
    titleTapGap_ = 0
    if titleTapCount_ >= TITLE_TAP_COUNT then
        titleTapCount_ = 0
        MailController.OpenGM()
    end
end

--- 每帧更新（由 GameView.HandleUpdate 调用）
function MailController.Update(dt)
    if titleTapCount_ > 0 then
        local game = GameStateAdapter.GetViewState()
        titleTapGap_ = titleTapGap_ + math.max(0, dt or 0)
        if not game or game.page ~= "home" or titleTapGap_ > TITLE_TAP_GAP_SECONDS then
            titleTapCount_, titleTapGap_ = 0, 0
        end
    end
    if not pressing_ or triggered_ then return end
    timer_ = timer_ + (dt or 0)
    if timer_ >= LONG_PRESS_SECONDS then
        triggered_ = true
        pressing_ = false -- 长按触发后释放按住状态，避免入口销毁后状态残留
        MailController.OpenGM()
    end
end

--- 打开邮件面板
function MailController.Open()
    if triggered_ then
        triggered_ = false
        return
    end
    MailView.Show()
end

function MailController.Reset()
    titleTapCount_, titleTapGap_ = 0, 0
    pressing_ = false
    timer_ = 0
    triggered_ = false
end

return MailController
