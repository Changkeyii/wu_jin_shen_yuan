local UI = require("urhox-libs/UI")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DialogCoordinator = require("client.DialogCoordinator")
local DailyVipView = require("client.DailyVipView")
local FaceSlapController = require("client.FaceSlapController")
local GameStateAdapter = require("client.GameStateAdapter")
local ServerClient = require("client.ServerClient")
local ServerClock = require("client.ServerClock")

local DailyVipController = {}

local CAMPAIGN_ID = "daily_vip_reminder"
local MANUAL_QUEUE_KEY = "daily_vip:manual"
local AD_WATCHDOG_SECONDS = 45

local context_ = nil
local sequence_ = 0
local requestPending_ = false
local adInFlight_ = false
local adElapsed_ = 0
local adFinish_ = nil
local rewardReservation_ = nil

local function ReleaseRewardReservation()
    if rewardReservation_ then
        DialogCoordinator.ReleaseReservation(rewardReservation_)
        rewardReservation_ = nil
    end
end

local function CloseDailyDialog()
    DialogCoordinator.CancelByKey(MANUAL_QUEUE_KEY)
    DialogCoordinator.CancelByKey("face_slap:" .. CAMPAIGN_ID)
end

local function CurrentGame()
    return GameStateAdapter.GetViewState()
end

local function CurrentDayKey()
    return DailyVipView.DayKey(ServerClock.Now())
end

local function ClaimStatus(game)
    game = game or CurrentGame()
    local dailyVip = type(game.dailyVip) == "table" and game.dailyVip or {}
    local atCap = (game.vipLevel or 0) >= DailyVipView.MAX_VIP_LEVEL
    local dayKey = CurrentDayKey()
    return {
        atCap = atCap,
        signInClaimed = atCap or dailyVip.signInDay == dayKey,
        adClaimed = atCap or dailyVip.adDay == dayKey,
    }
end

function DailyVipController.IsRewardAvailable(game)
    local status = ClaimStatus(game)
    return not status.atCap and (not status.signInClaimed or not status.adClaimed)
end

local function Toast(message, variant)
    UI.Toast.Show(message, {
        duration = 2.4,
        variant = variant or "info",
        position = "bottom",
    })
end

local function CompleteClaim(response, source, beforeLevel, sequence, rewardReservation)
    if sequence ~= sequence_ then
        if rewardReservation_ == rewardReservation then rewardReservation_ = nil end
        DialogCoordinator.ReleaseReservation(rewardReservation)
        return
    end
    if rewardReservation_ == rewardReservation then rewardReservation_ = nil end
    requestPending_ = false
    if not response or not response.ok then
        DialogCoordinator.ReleaseReservation(rewardReservation)
        if context_ and context_.showActionResult then context_.showActionResult(response) end
        return
    end
    local game = CurrentGame()
    local vipLevel = math.max(beforeLevel + 1, tonumber(game.vipLevel) or 0)
    print(string.format("[DailyVip] claim completed source=%s level=%d", source, vipLevel))
    CloseDailyDialog()
    local shown = DialogCoordinator.EnqueueReserved(
        rewardReservation,
        DailyVipView.BuildRewardOptions(vipLevel, source, function()
            ServerClient.RequestSnapshot()
        end)
    )
    if not shown then
        DialogCoordinator.ReleaseReservation(rewardReservation)
        ServerClient.RequestSnapshot()
    end
    if context_ and context_.requestPageRefresh then context_.requestPageRefresh() end
end

local function ClaimSignIn()
    local game = CurrentGame()
    local status = ClaimStatus(game)
    if requestPending_ then Toast("VIP 奖励正在领取，请稍候") return end
    if status.atCap then Toast("VIP 已达到 V10", "success") return end
    if status.signInClaimed then Toast("今日已签到", "info") return end
    if game.readOnly then Toast("正在连接服务器，请稍后再试") return end

    requestPending_ = true
    sequence_ = sequence_ + 1
    local sequence = sequence_
    local beforeLevel = game.vipLevel or 0
    local rewardReservation = DialogCoordinator.ReserveNext()
    rewardReservation_ = rewardReservation
    print("[DailyVip] sign-in claim requested")
    local requestId = ServerClient.ClaimDailyVip(function(response)
        CompleteClaim(response, "signIn", beforeLevel, sequence, rewardReservation)
    end)
    if not requestId and requestPending_ and sequence == sequence_ then
        requestPending_ = false
        if rewardReservation_ == rewardReservation then rewardReservation_ = nil end
        DialogCoordinator.ReleaseReservation(rewardReservation)
    end
end

local function RequestAdReward()
    local game = CurrentGame()
    local status = ClaimStatus(game)
    if requestPending_ then Toast("VIP 奖励正在领取，请稍候") return end
    if status.atCap then Toast("VIP 已达到 V10", "success") return end
    if status.adClaimed then Toast("今日广告奖励已领取") return end
    if game.readOnly then Toast("正在连接服务器，请稍后再试") return end
    if adInFlight_ then Toast("广告正在播放，请勿重复点击") return end

    adInFlight_ = true
    adElapsed_ = 0
    sequence_ = sequence_ + 1
    local sequence = sequence_
    local beforeLevel = game.vipLevel or 0
    local completed = false
    local callbackFired = false

    local function Finish(result)
        if completed or sequence ~= sequence_ then return end
        completed = true
        adInFlight_ = false
        adElapsed_ = 0
        adFinish_ = nil
        if not result or result.success ~= true then
            local message = result and result.msg == "embed manual close"
                and "需完整观看广告才能领取奖励"
                or "广告暂不可用，请稍后重试"
            print("[DailyVip] ad failed: " .. tostring(result and result.msg))
            Toast(message, "warning")
            return
        end

        requestPending_ = true
        local rewardReservation = DialogCoordinator.ReserveNext()
        rewardReservation_ = rewardReservation
        print("[DailyVip] ad completed; requesting authoritative reward")
        local requestId = ServerClient.ClaimDailyAdVip(function(response)
            CompleteClaim(response, "ad", beforeLevel, sequence, rewardReservation)
        end)
        if not requestId and requestPending_ and sequence == sequence_ then
            requestPending_ = false
            if rewardReservation_ == rewardReservation then rewardReservation_ = nil end
            DialogCoordinator.ReleaseReservation(rewardReservation)
        end
    end
    adFinish_ = Finish

    local accepted = _G["sdk"]:ShowRewardVideoAd(function(result)
        callbackFired = true
        Finish(result)
    end)
    if accepted == false and not callbackFired then
        Finish({ success = false, msg = "广告展示请求未受理" })
    end
end

local function BuildContent(config)
    return DailyVipView.BuildContent(CurrentGame(), {
        allowDoNotShowToday = config and config.allowDoNotShowToday == true,
        doNotShowToday = config and FaceSlapController.IsSuppressedToday(config.id) or false,
        requestPending = requestPending_,
        adInFlight = adInFlight_,
        onClaimSignIn = ClaimSignIn,
        onWatchAd = RequestAdReward,
        onDoNotShowTodayChanged = function(checked)
            if config then FaceSlapController.SetSuppressedToday(config.id, checked) end
        end,
    })
end

function DailyVipController.Show(options)
    options = options or {}
    local game = CurrentGame()
    local status = ClaimStatus(game)
    if not options.queueKey and DialogCoordinator.HasKey("face_slap:" .. CAMPAIGN_ID) then
        return true
    end
    if context_ and context_.hideItemTips then context_.hideItemTips("daily-vip-open") end
    local queueKey = options.queueKey or MANUAL_QUEUE_KEY
    local config = options.config
    local shown = CommonPromptDialog.Show {
        kind = "daily_vip",
        priority = options.priority or 250,
        queueKey = queueKey,
        title = "每日签到 · VIP 权益",
        message = status.atCap and "VIP 已满级，所有权益已解锁"
            or "签到与激励视频每天各可提升 1 级 VIP",
        bodyTop = 88,
        bodyHeight = 720,
        dialogHeight = 1010,
        closeOnOverlay = true,
        showClose = true,
        showConfirm = false,
        contentBuilder = function() return BuildContent(config) end,
        onPresented = options.onPresented,
        onCancel = options.onClosed,
    }
    return shown
end

function DailyVipController.ShowCampaign(config, runtime)
    runtime = runtime or {}
    return DailyVipController.Show {
        config = config,
        queueKey = config.queueKey,
        priority = config.priority,
        onPresented = runtime.onPresented,
        onClosed = runtime.onClosed,
    }
end

function DailyVipController.Open()
    if DialogCoordinator.HasKey("face_slap:" .. CAMPAIGN_ID) then return true end
    return DailyVipController.Show { queueKey = MANUAL_QUEUE_KEY, priority = 260 }
end

function DailyVipController.Configure(context)
    context_ = assert(context)
end

function DailyVipController.Update(dt)
    if not adInFlight_ then return end
    adElapsed_ = adElapsed_ + math.max(0, tonumber(dt) or 0)
    if adElapsed_ >= AD_WATCHDOG_SECONDS and adFinish_ then
        adFinish_({ success = false, msg = "广告响应超时" })
    end
end

function DailyVipController.ResetConnection()
    ReleaseRewardReservation()
    sequence_ = sequence_ + 1
    requestPending_ = false
    adInFlight_ = false
    adElapsed_ = 0
    adFinish_ = nil
    DialogCoordinator.CancelByKey(MANUAL_QUEUE_KEY)
    DialogCoordinator.CancelByKey("face_slap:" .. CAMPAIGN_ID)
end

function DailyVipController.Reset()
    DailyVipController.ResetConnection()
    context_ = nil
end

return DailyVipController
