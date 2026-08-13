local UI = require("urhox-libs/UI")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")

local WishPoolController = {}

local AD_WATCHDOG_SECONDS = 45
local context_ = nil
local requestPending_ = false
local adInFlight_ = false
local adElapsed_ = 0
local adFinish_ = nil
local animating_ = false
local sequence_ = 0
-- 请求发出时立即启动动画（消除点击到动画启动的延迟）；失败时取消动画。
local onWishStart_ = nil
local onWishError_ = nil

local function toast(message, variant)
    UI.Toast.Show(message, {
        duration = 2.4,
        variant = variant or "info",
        position = "bottom",
    })
end

local function notifyChanged()
    if context_ and context_.requestPageRefresh then context_.requestPageRefresh() end
end

local function sendWish(method, onDone)
    if requestPending_ then toast("许愿正在结算，请稍候") return false end
    if animating_ then toast("许愿动画播放中，请稍候") return false end
    local game = GameStateAdapter.GetViewState()
    if game.readOnly then toast("正在连接服务器，请稍后再试") return false end
    requestPending_ = true
    sequence_ = sequence_ + 1
    local sequence = sequence_
    -- 请求发出立即启动动画，服务端结果到达后由 wish_drawn 事件修正停靠点
    if onWishStart_ then onWishStart_() end
    local requestId = method(function(response)
        if sequence ~= sequence_ then return end
        requestPending_ = false
        if not response or not response.ok then
            toast((response and response.reason) or "许愿失败，请稍后重试", "warning")
            if onWishError_ then onWishError_(response) end
            notifyChanged()
        end
        if onDone then onDone(response) end
    end)
    if not requestId and sequence == sequence_ then
        requestPending_ = false
        if onWishError_ then onWishError_({ ok = false, reason = "请求发送失败" }) end
        return false
    end
    return true
end

function WishPoolController.WishWithTicket(onDone)
    local wishPool = GameStateAdapter.GetViewState().wishPool or {}
    if (wishPool.tickets or 0) <= 0 then
        toast("许愿券不足", "warning")
        return false
    end
    return sendWish(ServerClient.WishWithTicket, onDone)
end

function WishPoolController.WishWithAd(onDone)
    local wishPool = GameStateAdapter.GetViewState().wishPool or {}
    if requestPending_ then toast("许愿正在结算，请稍候") return false end
    if animating_ then toast("许愿动画播放中，请稍候") return false end
    if adInFlight_ then toast("广告正在播放，请勿重复点击") return false end
    if (wishPool.displayAdUsed or wishPool.adUsed or 0) >= 20 then toast("今日广告许愿次数已用完", "warning") return false end

    adInFlight_ = true
    adElapsed_ = 0
    sequence_ = sequence_ + 1
    local adSequence = sequence_
    local completed = false
    local callbackFired = false

    local function finish(result)
        if completed or adSequence ~= sequence_ then return end
        completed = true
        adInFlight_ = false
        adElapsed_ = 0
        adFinish_ = nil
        if not result or result.success ~= true then
            local message = result and result.msg == "embed manual close"
                and "需完整观看广告才能许愿"
                or "广告暂不可用，请稍后重试"
            toast(message, "warning")
            notifyChanged()
            return
        end

        requestPending_ = true
        if onWishStart_ then onWishStart_() end
        local requestId = ServerClient.WishWithAd(function(response)
            if adSequence ~= sequence_ then return end
            requestPending_ = false
            if not response or not response.ok then
                toast((response and response.reason) or "广告许愿失败", "warning")
                if onWishError_ then onWishError_(response) end
                notifyChanged()
            end
            if onDone then onDone(response) end
        end)
        if not requestId and adSequence == sequence_ then
            requestPending_ = false
            if onWishError_ then onWishError_({ ok = false, reason = "广告许愿请求发送失败" }) end
        end
    end
    adFinish_ = finish

    local accepted = _G["sdk"]:ShowRewardVideoAd(function(result)
        callbackFired = true
        finish(result)
    end)
    if accepted == false and not callbackFired then
        finish({ success = false, msg = "广告展示请求未受理" })
    end
    return true
end

function WishPoolController.OpenJar(jarId, count, onDone)
    if requestPending_ then toast("装备罐正在开启，请稍候") return false end
    if animating_ then toast("开罐动画播放中，请稍候") return false end
    requestPending_ = true
    sequence_ = sequence_ + 1
    local sequence = sequence_
    local requestId = ServerClient.OpenWishJar(jarId, count, function(response)
        if sequence ~= sequence_ then return end
        requestPending_ = false
        if not response or not response.ok then
            toast((response and response.reason) or "装备罐开启失败", "warning")
            notifyChanged()
        end
        if onDone then onDone(response) end
    end)
    if not requestId and sequence == sequence_ then requestPending_ = false return false end
    return true
end

function WishPoolController.Configure(context)
    context_ = assert(context)
    onWishStart_ = context.onWishStart
    onWishError_ = context.onWishError
end

-- 动画播放状态：许愿/开罐动画期间禁止重复操作，由视图层设置。
function WishPoolController.SetAnimating(value)
    animating_ = value == true
end

function WishPoolController.IsBusy()
    return requestPending_ or adInFlight_ or animating_
end

function WishPoolController.IsAnimating()
    return animating_
end

function WishPoolController.IsAdInFlight()
    return adInFlight_
end

function WishPoolController.Update(dt)
    if not adInFlight_ then return end
    adElapsed_ = adElapsed_ + math.max(0, tonumber(dt) or 0)
    if adElapsed_ >= AD_WATCHDOG_SECONDS and adFinish_ then
        adFinish_({ success = false, msg = "广告响应超时" })
    end
end

function WishPoolController.ResetConnection()
    sequence_ = sequence_ + 1
    requestPending_ = false
    adInFlight_ = false
    adElapsed_ = 0
    adFinish_ = nil
    animating_ = false
end

function WishPoolController.Reset()
    WishPoolController.ResetConnection()
    context_ = nil
    onWishStart_ = nil
    onWishError_ = nil
end

return WishPoolController
