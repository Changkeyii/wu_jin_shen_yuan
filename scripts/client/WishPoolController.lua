local UI = require("urhox-libs/UI")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local WishPoolDefinitions = require("shared.WishPoolDefinitions")

local WishPoolController = {}

local context_ = nil
local requestPending_ = false
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

local function sendWish(count, onDone)
    if requestPending_ then toast("许愿正在结算，请稍候") return false end
    if animating_ then toast("许愿动画播放中，请稍候") return false end
    local game = GameStateAdapter.GetViewState()
    if game.readOnly then toast("正在连接服务器，请稍后再试") return false end

    local drawCount, ticketCost = WishPoolDefinitions.ResolveDrawPlan(count)
    local wishPool = game.wishPool or {}
    if (wishPool.tickets or 0) < ticketCost then
        toast(string.format("许愿券不足（需要 %d 张）", ticketCost), "warning")
        return false
    end

    requestPending_ = true
    sequence_ = sequence_ + 1
    local sequence = sequence_
    -- 请求发出立即启动动画，服务端结果到达后由 wish_drawn 事件修正停靠点
    if onWishStart_ then onWishStart_() end
    local requestId = ServerClient.WishWithTicket(drawCount, function(response)
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
    return sendWish(WishPoolDefinitions.SINGLE_DRAW_COUNT, onDone)
end

function WishPoolController.WishTen(onDone)
    return sendWish(WishPoolDefinitions.MULTI_DRAW_COUNT, onDone)
end

-- 广告许愿已下线。
function WishPoolController.WishWithAd()
    toast("广告许愿已下线，请使用许愿券", "warning")
    return false
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
    return requestPending_ or animating_
end

function WishPoolController.IsAnimating()
    return animating_
end

function WishPoolController.IsAdInFlight()
    return false
end

function WishPoolController.Update(_dt)
end

function WishPoolController.ResetConnection()
    sequence_ = sequence_ + 1
    requestPending_ = false
    animating_ = false
end

function WishPoolController.Reset()
    WishPoolController.ResetConnection()
    context_ = nil
    onWishStart_ = nil
    onWishError_ = nil
end

return WishPoolController
