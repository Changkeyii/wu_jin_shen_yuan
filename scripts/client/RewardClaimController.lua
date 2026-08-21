local UI = require("urhox-libs/UI")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DialogCoordinator = require("client.DialogCoordinator")
local GameStateAdapter = require("client.GameStateAdapter")
local RewardDialogView = require("client.RewardDialogView")
local ServerClient = require("client.ServerClient")
local ViewAssets = require("client.ViewAssets")
local AbyssDefinitions = require("shared.AbyssDefinitions")
local Kit = require("client.ViewKit")
local LargeNumber = require("shared.LargeNumber")

local RewardClaimController = {}

local ASSETS = ViewAssets.ASSETS
local adInFlight_ = false
local requestPending_ = false
local sequence_ = 0
local adElapsed_ = 0
local adTimeoutFinish_ = nil
local AD_WATCHDOG_SECONDS = 45
local shown_ = {}

local SOURCE_TITLES = {
    signin = "签到激励奖励",
    level_milestone = "等级里程碑激励",
    floor_milestone = "章节突破激励",
    abyss_settlement = "深渊结算激励",
    task = "任务激励奖励",
}

local function findOffer(rewardId)
    local claims = GameStateAdapter.GetViewState().rewardClaims
    for _, offer in ipairs(claims and claims.pending or {}) do
        if offer.id == rewardId then return offer end
    end
    return nil
end

local function cardsFor(reward)
    reward = reward or {}
    local cards = {}
    if not LargeNumber.IsZero(reward.gold) then
        RewardDialogView.AddCard(
            cards,
            ASSETS.items.gold,
            "额外金币",
            "+" .. Kit.FormatInt(reward.gold),
            "epic"
        )
    end
    if (reward.exp or 0) > 0 then
        RewardDialogView.AddCard(
            cards,
            ASSETS.items.crystal,
            "额外经验",
            "+" .. Kit.FormatInt(reward.exp),
            "advanced"
        )
    end
    if (reward.fragments or 0) > 0 then
        RewardDialogView.AddCard(
            cards,
            ASSETS.items.crystal,
            "额外碎片",
            "+" .. Kit.FormatInt(reward.fragments),
            "rare"
        )
    end
    if (reward.abyssTickets or 0) > 0 then
        RewardDialogView.AddCard(
            cards,
            AbyssDefinitions.ICON,
            "额外深渊票",
            "+" .. tostring(reward.abyssTickets),
            "epic"
        )
    end
    return cards
end

local function watchAd(offer)
    if adInFlight_ or requestPending_ then
        UI.Toast.Show("激励奖励正在处理中", {
            duration = 1.8,
            variant = "info",
            position = "bottom",
        })
        return
    end
    local sdk = _G["sdk"]
    if not sdk or type(sdk.ShowRewardVideoAd) ~= "function" then
        UI.Toast.Show("广告暂不可用，请稍后重试", {
            duration = 2.0,
            variant = "warning",
            position = "bottom",
        })
        return
    end
    adInFlight_ = true
    adElapsed_ = 0
    sequence_ = sequence_ + 1
    local sequence = sequence_
    local completed = false
    local callbackFired = false
    local function finish(result)
        if completed or sequence ~= sequence_ then return end
        completed = true
        adInFlight_ = false
        adElapsed_ = 0
        adTimeoutFinish_ = nil
        if not result or result.success ~= true then
            shown_[offer.id] = nil
            UI.Toast.Show(
                result and result.msg == "embed manual close"
                    and "需完整观看广告才能获得五倍收益"
                    or "广告暂不可用，请稍后重试",
                { duration = 2.2, variant = "warning", position = "bottom" }
            )
            return
        end
        requestPending_ = true
        ServerClient.ClaimRewardAdExtra(
            offer.id,
            function(response)
                if sequence ~= sequence_ then return end
                requestPending_ = false
                if response and response.ok then
                    UI.Toast.Show("激励完成，金币/经验/碎片/深渊票已达 5 倍", {
                        duration = 2.4,
                        variant = "success",
                        position = "bottom",
                    })
                else
                    shown_[offer.id] = nil
                    UI.Toast.Show(
                        response and (response.reason or response.code)
                            or "激励奖励领取失败",
                        { duration = 2.2, variant = "warning", position = "bottom" }
                    )
                end
            end
        )
    end
    adTimeoutFinish_ = finish
    local accepted = sdk:ShowRewardVideoAd(function(result)
        callbackFired = true
        finish(result)
    end)
    if accepted == false and not callbackFired then
        finish({ success = false, msg = "广告展示请求未受理" })
    end
end

local function showOffer(offer)
    if not offer or shown_[offer.id] then return false end
    if offer.source == "offline"
        or not SOURCE_TITLES[offer.source]
    then
        shown_[offer.id] = true
        return false
    end
    shown_[offer.id] = true
    local cards = cardsFor(offer.extraReward)
    local options = RewardDialogView.BuildOptions {
        priority = 440,
        queueKey = "reward_offer:" .. offer.id,
        title = SOURCE_TITLES[offer.source] or "激励奖励",
        message = "普通收益已到账",
        lines = {
            "完整观看激励视频后，金币、经验、碎片和深渊票提升至普通收益的 5 倍。",
            "装备、品质、掉落件数和保底进度不会翻倍。",
        },
        confirmText = "看广告 · 资源×5",
        cancelText = "下次再看",
        cards = cards,
        onConfirm = function() watchAd(offer) end,
        onCancel = function() end,
    }
    if not options then return false end
    local shown = CommonPromptDialog.Show(options)
    if not shown then shown_[offer.id] = nil end
    return shown
end

local exclusiveInFlight_ = false

function RewardClaimController.ClaimExclusiveGift(giftId)
    if adInFlight_ or requestPending_ or exclusiveInFlight_ then
        UI.Toast.Show("激励奖励正在处理中", {
            duration = 1.8,
            variant = "info",
            position = "bottom",
        })
        return false
    end
    local sdk = _G["sdk"]
    if not sdk or type(sdk.ShowRewardVideoAd) ~= "function" then
        UI.Toast.Show("广告暂不可用，请稍后重试", {
            duration = 2.0,
            variant = "warning",
            position = "bottom",
        })
        return false
    end
    exclusiveInFlight_ = true
    adInFlight_ = true
    adElapsed_ = 0
    sequence_ = sequence_ + 1
    local sequence = sequence_
    local completed = false
    local callbackFired = false
    local function finish(result)
        if completed or sequence ~= sequence_ then return end
        completed = true
        adInFlight_ = false
        adElapsed_ = 0
        adTimeoutFinish_ = nil
        if not result or result.success ~= true then
            exclusiveInFlight_ = false
            UI.Toast.Show(
                result and result.msg == "embed manual close"
                    and "需完整观看广告才能领取补给"
                    or "广告暂不可用，请稍后重试",
                { duration = 2.2, variant = "warning", position = "bottom" }
            )
            return
        end
        ServerClient.ClaimExclusiveAdGift(giftId, function(response)
            if sequence ~= sequence_ then return end
            exclusiveInFlight_ = false
            if response and response.ok then
                UI.Toast.Show("深渊票补给已领取", {
                    duration = 2.2,
                    variant = "success",
                    position = "bottom",
                })
            else
                UI.Toast.Show(
                    response and (response.reason or response.code)
                        or "补给领取失败",
                    { duration = 2.2, variant = "warning", position = "bottom" }
                )
            end
        end)
    end
    adTimeoutFinish_ = finish
    local accepted = sdk:ShowRewardVideoAd(function(result)
        callbackFired = true
        finish(result)
    end)
    if accepted == false and not callbackFired then
        finish({ success = false, msg = "广告展示请求未受理" })
    end
    return accepted ~= false
end

function RewardClaimController.ShowPending()
    local claims = GameStateAdapter.GetViewState().rewardClaims
    for _, offer in ipairs(claims and claims.pending or {}) do
        if not shown_[offer.id] then
            showOffer(offer)
            return true
        end
    end
    return false
end

function RewardClaimController.HandleDelta(payload)
    local events = payload and payload.events or {}
    for _, value in ipairs(events) do
        if (value.kind or value.type) == "reward_offer_pending" then
            if value.source == "offline" then
                shown_[value.rewardId] = true
            else
                local offer = findOffer(value.rewardId) or {
                    id = value.rewardId,
                    source = value.source,
                    baseReward = value.baseReward,
                    extraReward = value.extraReward,
                }
                showOffer(offer)
            end
        elseif (value.kind or value.type) == "reward_ad_extra_claimed" then
            shown_[value.rewardId] = true
        end
    end
end

function RewardClaimController.Update(dt)
    if not adInFlight_ or not adTimeoutFinish_ then return end
    adElapsed_ = adElapsed_ + math.max(0, tonumber(dt) or 0)
    if adElapsed_ >= AD_WATCHDOG_SECONDS then
        adTimeoutFinish_({
            success = false,
            msg = "广告响应超时，请稍后重试",
        })
    end
end

function RewardClaimController.Reset()
    sequence_ = sequence_ + 1
    adInFlight_ = false
    adElapsed_ = 0
    adTimeoutFinish_ = nil
    requestPending_ = false
    exclusiveInFlight_ = false
    shown_ = {}
end

return RewardClaimController
