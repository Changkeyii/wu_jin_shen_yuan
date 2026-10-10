local UI = require("urhox-libs/UI")
local Server = require("client.ServerClient")
local Adapter = require("client.GameStateAdapter")
local Dialogs = require("client.DialogCoordinator")
local View = require("client.AdGiftView")
local Video = require("client.RewardVideo")
local D = require("shared.AdGiftDefinitions")
local M = {}
local busy, generation = false, 0
local autoPromptUsed = false
local wasRunning = false
local hint --[[@type string?]]
local receipt --[[@type table?]]
local function toast(message)
    UI.Toast.Show(message, { duration = 2.2, variant = "info", position = "bottom" })
end
local function available()
    local game = Adapter.GetViewState()
    return game and not game.readOnly and game.tutorial and game.tutorial.completed == true
end
local function failure(response)
    return response and (response.reason or (response.error and response.error.reason)) or "网络繁忙，请重新领取"
end
local claim
local function showReceipt()
    if not receipt then return false end
    local quote = receipt
    return View.Reward(quote, { message = Video.ActionText("广告已完成，奖励等待到账", "免广告身份已确认，奖励等待到账"), confirmText = "重试领取", cancelText = "稍后领取",
        lines = { "领取资格已确认，可直接重试领取。", "可从活动页的塔灵礼包继续领取。" },
        onConfirm = function() claim(quote) end })
end
claim = function(quote)
    if busy then return end
    busy = true
    local current = generation
    if View.Pending then View.Pending("正在确认奖励，请稍候……") end
    Server.ClaimAdGift(quote.id, function(result)
        if current ~= generation then return end
        if Dialogs.CancelByKey then Dialogs.CancelByKey("ad_gift_pending") end
        busy = false
        if not result or not result.ok then
            toast(failure(result))
            showReceipt()
            return
        end
        receipt = nil
        View.Reward(quote, { message = "奖励已到账", confirmText = "完成", cancelText = "查看礼包",
            onCancel = function() M.Open() end })
    end)
end
function M.Show(kind)
    if not available() then toast("完成序章后开放塔灵礼包"); return false end
    if busy or Video.IsBusy() or Dialogs.HasKey("ad_gift_dialog") then return false end
    if receipt then return showReceipt() end
    if not D.KINDS[kind] then return false end
    busy = true
    local current = generation
    if View.Pending then View.Pending("正在获取礼包，请稍候……") end
    Server.PrepareAdGift(kind, function(result)
        if current ~= generation then return end
        if Dialogs.CancelByKey then Dialogs.CancelByKey("ad_gift_pending") end
        busy = false
        local quote = result and result.ok and result.data and result.data.quote
        if not quote then toast(failure(result)); return end
        View.Reward(quote, { onConfirm = function()
            if Video.IsBusy() then toast("广告正在播放，请稍候"); return end
            Video.Play(function(ad)
                if current ~= generation then return end
                if ad.success ~= true then
                    toast(ad.msg == "embed manual close" and "未完整观看，不会发奖" or (ad.msg or "广告暂不可用"))
                    View.Reward(quote, { confirmText = "重新尝试", onConfirm = function() M.Show(kind) end })
                    return
                end
                receipt = quote
                claim(quote)
            end)
        end })
    end)
    return true
end
function M.Open()
    if not available() then toast("完成序章后开放塔灵礼包"); return false end
    if busy or Video.IsBusy() then toast("礼包正在处理中"); return false end
    if receipt then return showReceipt() end
    busy = true
    local current = generation
    if View.Pending then View.Pending("正在获取礼包列表，请稍候……") end
    Server.ListAdGifts(function(result)
        if current ~= generation then return end
        if Dialogs.CancelByKey then Dialogs.CancelByKey("ad_gift_pending") end
        busy = false
        if not result or not result.ok then toast(failure(result)); return end
        View.Menu(result.data.offers or {}, M.Show, result.data)
    end)
    return true
end
function M.HandleDelta(payload)
    if not available() then return end
    for _, event in ipairs(payload and payload.events or {}) do
        if (event.kind or event.type) == "ad_gift_available" and D.KINDS[event.giftKind] then
            -- 同批多个场景只提示一个，不堆积弹窗。其余礼包始终可从活动入口打开。
            hint = event.giftKind
        end
    end
end
function M.Update()
    local game = Adapter.GetViewState()
    local running = game and game.autoRun == true and game.page == "play"
    if running and not wasRunning then autoPromptUsed = false end
    wasRunning = running
    if running or autoPromptUsed or not hint or not available() or busy or receipt or Video.IsBusy() then return end
    if game.page ~= "home" and game.page ~= "play" then return end
    if game.page == "play" and (game.pendingEvent or game.pendingStoryGate) then return end
    if require("client.OfflineClaimController").IsLoginFlowPending() then return end
    if require("client.LoadingController").IsActive() or require("client.CampaignView").IsOpen()
        or require("client.IdleSettingsView").IsOpen() then return end
    local dialogs = Dialogs.GetState()
    if dialogs.active or dialogs.queued > 0 or (dialogs.reservations or 0) > 0 then return end
    autoPromptUsed = true
    local kind = hint
    hint = nil
    M.Show(kind)
end
function M.Recover()
    generation = generation + 1
    busy, hint, autoPromptUsed = false, nil, true
    -- A completed advertisement remains redeemable after emergency UI recovery.
end
function M.Reset()
    if require("client.RecoveryState").rebuilding then M.Recover(); return end
    generation = generation + 1
    busy, hint, receipt = false, nil, nil
    wasRunning, autoPromptUsed = false, false
    Video.Reset()
end
return M
