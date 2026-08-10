local UI = require("urhox-libs/UI")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DialogCoordinator = require("client.DialogCoordinator")
local GameStatePolicy = require("shared.GameStatePolicy")
local OfflineClaimView = require("client.OfflineClaimView")

local OfflineClaimController = {}

local IDLE = "idle"
local PREVIEWING = "previewing"
local CONFIRMING = "confirming"
local CLAIMING = "claiming"

local state_ = IDLE
local sequence_ = 0
local dialogKey_ = nil
local loginGuideShown_ = false
local loginFlowPending_ = false
local showActionResult_ = nil
local onLoginFlowCompleted_ = nil
local onLoginGuideClosed_ = nil

local function ActionResult(response, successMessage)
    if showActionResult_ then return showActionResult_(response, successMessage) end
    return response ~= nil and response.ok == true
end

local function ExtractReward(response)
    local data = response and response.data
    if type(data and data.reward) == "table" then return data.reward end
    local delta = data and data.delta
    for _, value in ipairs((delta and delta.events) or {}) do
        if value.kind == "offline_collected" then return value end
    end
    return nil
end

local function CompleteLoginFlow()
    if not loginFlowPending_ then return end
    loginFlowPending_ = false
    if onLoginFlowCompleted_ then onLoginFlowCompleted_() end
    if onLoginGuideClosed_ then onLoginGuideClosed_() end
end

function OfflineClaimController.Configure(context)
    context = context or {}
    showActionResult_ = context.showActionResult
    onLoginFlowCompleted_ = context.onLoginFlowCompleted
    onLoginGuideClosed_ = context.onLoginGuideClosed
end

function OfflineClaimController.Collect(onCompleted)
    if not onCompleted and loginFlowPending_ then
        onCompleted = CompleteLoginFlow
    end
    if state_ == PREVIEWING then
        UI.Toast.Show("正在获取离线收益预览，请稍候", { duration = 1.5, variant = "info", position = "bottom" })
        return
    end
    if state_ == CONFIRMING then
        if dialogKey_ and DialogCoordinator.HasKey(dialogKey_) then
            UI.Toast.Show("离线收益确认弹窗正在等待显示", { duration = 1.5, variant = "info", position = "bottom" })
            return
        end
        dialogKey_ = nil
        state_ = IDLE
    end
    if state_ == CLAIMING then
        UI.Toast.Show("离线收益正在领取，请稍候", { duration = 1.5, variant = "info", position = "bottom" })
        return
    end

    sequence_ = sequence_ + 1
    local sequence = sequence_
    local loadingDialogKey = "offline_preview_loading:" .. tostring(sequence)
    dialogKey_ = loadingDialogKey
    state_ = PREVIEWING
    print("[OfflineClaim] preview requested sequence=" .. tostring(sequence))
    if not OfflineClaimView.ShowLoading(loadingDialogKey) then
        dialogKey_ = nil
        state_ = IDLE
        print("[OfflineClaim] loading dialog rejected sequence=" .. tostring(sequence))
        UI.Toast.Show("当前有其他弹窗，请稍后重试", { duration = 1.8, variant = "info", position = "bottom" })
        CompleteLoginFlow()
        return
    end

    ServerClient.PreviewOffline(function(response)
        if sequence ~= sequence_ then return end
        DialogCoordinator.CancelByKey(loadingDialogKey)
        dialogKey_ = nil
        if not response or not response.ok then
            state_ = IDLE
            print("[OfflineClaim] preview failed sequence=" .. tostring(sequence)
                .. " code=" .. tostring(response and response.code))
            ActionResult(response)
            CompleteLoginFlow()
            return
        end
        local data = response.data or {}
        local quoteToken = data.quoteToken
        local preview = data.preview
        if type(quoteToken) ~= "string" or type(preview) ~= "table" then
            state_ = IDLE
            print("[OfflineClaim] invalid preview response sequence=" .. tostring(sequence))
            ActionResult({ ok = false, reason = "服务器返回的离线预览无效" })
            CompleteLoginFlow()
            return
        end

        state_ = CONFIRMING
        local rewardFloor = GameStateAdapter.GetViewState().floor
        local shown, previewDialogKey = OfflineClaimView.ShowPreview(
            quoteToken,
            preview,
            rewardFloor,
            function()
                if sequence ~= sequence_ then return end
                dialogKey_ = nil
                state_ = CLAIMING
                local rewardReservation = DialogCoordinator.ReserveNext()
                print("[OfflineClaim] claim confirmed sequence=" .. tostring(sequence))
                ServerClient.CollectOffline(quoteToken, function(claimResponse)
                    if sequence ~= sequence_ then
                        DialogCoordinator.ReleaseReservation(rewardReservation)
                        return
                    end
                    state_ = IDLE
                    if not ActionResult(claimResponse) then
                        DialogCoordinator.ReleaseReservation(rewardReservation)
                        print("[OfflineClaim] claim failed sequence=" .. tostring(sequence)
                            .. " code=" .. tostring(claimResponse and claimResponse.code))
                        CompleteLoginFlow()
                        return
                    end
                    print("[OfflineClaim] claim completed sequence=" .. tostring(sequence))
                    local reward = ExtractReward(claimResponse)
                    if reward then
                        local rewardOptions = OfflineClaimView.BuildRewardOptions(
                            reward,
                            rewardFloor,
                            onCompleted
                        )
                        local shown = rewardOptions
                            and DialogCoordinator.EnqueueReserved(rewardReservation, rewardOptions)
                            or false
                        if not shown then
                            DialogCoordinator.ReleaseReservation(rewardReservation)
                            if onCompleted then onCompleted() end
                        end
                    else
                        DialogCoordinator.ReleaseReservation(rewardReservation)
                        UI.Toast.Show("离线收益已领取", { duration = 2.0, variant = "success", position = "bottom" })
                        if onCompleted then onCompleted() end
                    end
                    ServerClient.RequestSnapshot()
                end)
            end,
            function()
                if sequence ~= sequence_ then return end
                dialogKey_ = nil
                state_ = IDLE
                print("[OfflineClaim] preview closed sequence=" .. tostring(sequence))
            end,
            loginFlowPending_
        )
        dialogKey_ = previewDialogKey
        if not shown then
            dialogKey_ = nil
            state_ = IDLE
            print("[OfflineClaim] preview dialog rejected sequence=" .. tostring(sequence))
            UI.Toast.Show("当前有其他弹窗，请稍后重试", { duration = 1.8, variant = "info", position = "bottom" })
            CompleteLoginFlow()
            return
        end
        print("[OfflineClaim] preview dialog queued sequence=" .. tostring(sequence))
    end)
end

function OfflineClaimController.ShowLoginGuide(options)
    options = options or {}
    local game = GameStateAdapter.GetViewState()
    if (game.pendingOfflineSeconds or 0) < GameStatePolicy.OFFLINE_MIN_SECONDS then return false end
    loginGuideShown_ = true
    onLoginGuideClosed_ = options.onClosed
    local shown = CommonPromptDialog.Show {
        kind = "confirm",
        priority = options.priority or 1200,
        queueKey = options.queueKey or "offline_login_guide",
        title = "离线收益待领取",
        message = "本次离线收益已由服务器结算完成，请先领取。",
        lines = {
            "离线奖励在上线时已锁定，不会受本次在线挂机影响。",
            "领取后金币与装备会直接并入当前角色。",
        },
        closeOnOverlay = false,
        showClose = false,
        confirmText = "领取离线收益",
        onPresented = options.onPresented,
        onConfirm = function()
            OfflineClaimController.Collect(CompleteLoginFlow)
        end,
    }
    if shown then
        loginFlowPending_ = true
    else
        loginGuideShown_ = false
        onLoginGuideClosed_ = nil
    end
    return shown
end

function OfflineClaimController.MaybeShowLoginGuide()
    if loginGuideShown_ then return false end
    return OfflineClaimController.ShowLoginGuide()
end

function OfflineClaimController.IsLoginFlowPending()
    return loginFlowPending_
end

function OfflineClaimController.Reset()
    sequence_ = sequence_ + 1
    if dialogKey_ then DialogCoordinator.CancelByKey(dialogKey_) end
    state_ = IDLE
    dialogKey_ = nil
    loginGuideShown_ = false
    loginFlowPending_ = false
    onLoginGuideClosed_ = nil
end

return OfflineClaimController
