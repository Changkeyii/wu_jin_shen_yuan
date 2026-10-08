-- InventoryFullPrompt.lua
-- 背包已满统一提示：引导分解/出售，或看广告解锁格子。

local UI = require("urhox-libs/UI")
local CommonPromptDialog = require("client.CommonPromptDialog")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local InventoryCapacity = require("client.InventoryCapacity")
local NavigationController = require("client.NavigationController")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")

local ASSETS = ViewAssets.ASSETS
local InventoryFullPrompt = {}

local adInFlight_ = false
local requestPending_ = false
local sequence_ = 0
local adElapsed_ = 0
local adFinish_ = nil
local AD_WATCHDOG_SECONDS = 45

local function Toast(message, variant)
    if UI.Toast and UI.Toast.Show then
        UI.Toast.Show(message, {
            duration = 2.0,
            variant = variant or "info",
            position = "bottom",
        })
    end
end

local function ExpandByAd(onDone)
    if requestPending_ then
        Toast("扩容请求处理中，请稍候")
        return
    end
    if adInFlight_ then
        Toast("广告正在播放，请勿重复点击")
        return
    end
    local game = GameStateAdapter.GetViewState()
    if not InventoryCapacity.CanExpand(game) then
        Toast("背包扩容已达上限", "warning")
        return
    end
    local remain = InventoryCapacity.TodayAdRemaining(game)
    if remain <= 0 then
        Toast("今日广告扩容次数已用完", "warning")
        return
    end

    local sdk = _G["sdk"]
    if not sdk or type(sdk.ShowRewardVideoAd) ~= "function" then
        Toast("广告暂不可用，请稍后重试", "warning")
        if onDone then onDone(false) end
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
        adFinish_ = nil
        if not result or result.success ~= true then
            local message = result and result.msg == "embed manual close"
                and "需完整观看广告才能解锁格子"
                or "广告暂不可用，请稍后重试"
            Toast(message, "warning")
            if onDone then onDone(false) end
            return
        end
        requestPending_ = true
        ServerClient.ExpandInventoryByAd(function(response)
            if sequence ~= sequence_ then return end
            requestPending_ = false
            if response and response.ok then
                local gain = InventoryCapacity.PerAd()
                Toast("背包已扩容 +" .. tostring(gain) .. " 格", "success")
                if onDone then onDone(true, response) end
            else
                Toast((response and response.reason) or "扩容失败", "error")
                if onDone then onDone(false, response) end
            end
        end)
    end
    adFinish_ = finish

    local accepted = sdk:ShowRewardVideoAd(function(result)
        callbackFired = true
        finish(result)
    end)
    if accepted == false and not callbackFired then
        finish({ success = false, msg = "广告展示请求未受理" })
    end
end

function InventoryFullPrompt.Show(options)
    options = options or {}
    local game = GameStateAdapter.GetViewState()
    local capacity = InventoryCapacity.Capacity(game)
    local used = InventoryCapacity.Used(game)
    local remain, adUsed = InventoryCapacity.TodayAdRemaining(game)
    local canExpand = InventoryCapacity.CanExpand(game)
    local perAd = InventoryCapacity.PerAd()

    return CommonPromptDialog.Show {
        kind = "confirm",
        priority = options.priority or 420,
        queueKey = options.queueKey or "inventory-full-prompt",
        title = "背包已满",
        message = options.reason or "当前背包没有空位了。",
        lines = {
            string.format("当前占用：%d / %d", used, capacity),
            "请先分解或出售多余装备腾出空位。",
            canExpand
                and string.format("也可看广告解锁 +%d 格（今日剩余 %d/%d）", perAd, remain, InventoryCapacity.AdPerDay())
                or "背包扩容已达上限。",
        },
        cancelText = "去分解",
        confirmText = (canExpand and remain > 0) and ("看广告 +" .. tostring(perAd)) or "知道了",
        closeOnOverlay = true,
        showClose = true,
        zIndex = options.zIndex or 3920,
        onCancel = function()
            NavigationController.SwitchPage("bag")
        end,
        onConfirm = function()
            if canExpand and remain > 0 then
                ExpandByAd(function(ok)
                    if ok and options.onExpanded then options.onExpanded() end
                end)
                return true
            end
            return true
        end,
    }
end

function InventoryFullPrompt.Update(dt)
    if not adInFlight_ or not adFinish_ then return end
    adElapsed_ = adElapsed_ + math.max(0, tonumber(dt) or 0)
    if adElapsed_ >= AD_WATCHDOG_SECONDS then
        adFinish_({ success = false, msg = "广告响应超时，请稍后重试" })
    end
end

function InventoryFullPrompt.Reset()
    sequence_ = sequence_ + 1
    adInFlight_ = false
    requestPending_ = false
    adElapsed_ = 0
    adFinish_ = nil
end

function InventoryFullPrompt.ExpandByAd(onDone)
    ExpandByAd(onDone)
end

return InventoryFullPrompt
