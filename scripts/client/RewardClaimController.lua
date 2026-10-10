local UI = require("urhox-libs/UI")
local CommonPromptDialog = require("client.CommonPromptDialog")
local DialogCoordinator = require("client.DialogCoordinator")
local RewardDialogView = require("client.RewardDialogView")
local ServerClient = require("client.ServerClient")
local ViewAssets = require("client.ViewAssets")
local AbyssDefinitions = require("shared.AbyssDefinitions")
local Kit = require("client.ViewKit")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")
local RewardVideo = require("client.RewardVideo")
local RewardClaimController = {}
local ASSETS = ViewAssets.ASSETS
local adInFlight_, requestPending_ = false, false
local exclusiveInFlight_ = false
local sequence_, adElapsed_ = 0, 0
local adTimeoutFinish_
local AD_WATCHDOG_SECONDS = RewardVideo.WATCHDOG_SECONDS
local shown_, contexts_, claimed_ = {}, {}, {}
local presented_ = {}
local function BoundedSet(limit)
    local values, order = {}, {}
    return setmetatable({}, {
        __index = values,
        __newindex = function(_, key, value)
            if value == nil and values[key] ~= nil then
                for i, entry in ipairs(order) do
                    if entry == key then table.remove(order, i); break end
                end
            end
            if value ~= nil and values[key] == nil then
                order[#order + 1] = key
                if #order > limit then values[table.remove(order, 1)] = nil end
            end
            values[key] = value
        end,
    })
end
shown_, claimed_, presented_ = BoundedSet(512), BoundedSet(512), BoundedSet(512)
local offlineEvents_

local function Copy(value)
    local out = {}; for k, v in pairs(value or {}) do out[k] = v end; return out
end
local function Add(target, reward)
    for _, key in ipairs({ "gold", "exp", "fragments", "abyssTickets" }) do
        local value = reward and reward[key] or 0
        if LargeNumber.IsLargeNumber(value) then value = LargeNumber.ToBigNumber(value) end
        target[key] = BigNumber.Add(target[key] or 0, value)
    end
end
local function Cards(reward)
    local cards = {}
    for _, spec in ipairs({
        { "gold", "金币", ASSETS.items.gold, "epic" },
        { "exp", "经验", ASSETS.items.crystal, "advanced" },
        { "fragments", "碎片", ASSETS.items.crystal, "rare" },
        { "abyssTickets", "深渊票", AbyssDefinitions.ICON, "epic" },
    }) do
        if not BigNumber.IsZero(reward[spec[1]] or 0) then
            RewardDialogView.AddCard(cards, spec[3], spec[2], "+" .. Kit.FormatInt(reward[spec[1]]), spec[4])
        end
    end
    return cards
end
local function FinishContext(context)
    if context.closed then return end
    context.closed = true
    for _, id in ipairs(context.ids) do contexts_[id] = nil end
    if context.options.onConfirm then context.options.onConfirm() end
end
local Present, Watch
Present = function(context, final)
    local options = Copy(context.options)
    local extra = {}
    if final then
        for _, receipt in pairs(context.receipts) do Add(extra, receipt.reward) end
    end
    -- Widgets are recreated after dismissal; never reuse destroyed card nodes.
    options.cards = context.options.buildCards(extra)
    options.buildCards = nil
    options.queueKey = context.options.queueKey .. (final and ":fivefold" or ":choice")
    if final then
        options.title = "五倍奖励结算"
        options.message = "本次奖励合计（含已领取的基础奖励）"
        options.lines = { "可加成资源已达 5 倍，本次补发额外 4 倍。", "装备及其他不可加成奖励保持不变。" }
        options.cancelText = nil
        options.onConfirm = function() FinishContext(context) end
        options.onCancel = options.onConfirm
    else
        local lines = {}; for _, line in ipairs(options.lines or {}) do lines[#lines + 1] = line end
        lines[#lines + 1] = RewardVideo.ActionText("可选择广告五倍加成；基础奖励已经到账。", "免广告领取五倍加成；基础奖励已经到账。")
        -- Some settlements also contain non-eligible rewards. State exactly what gets boosted.
        local eligible = {}; for _, offer in ipairs(context.offers) do Add(eligible, offer.baseReward) end
        local amounts = {}
        for _, field in ipairs({ { "gold", "金币" }, { "exp", "经验" }, { "fragments", "碎片" }, { "abyssTickets", "深渊票" } }) do
            if not BigNumber.IsZero(eligible[field[1]] or 0) then
                amounts[#amounts + 1] = field[2] .. " " .. Kit.FormatInt(eligible[field[1]])
            end
        end
        for _, amount in ipairs(amounts) do lines[#lines + 1] = "可加成：" .. amount .. " ×5" end
        options.lines = lines
        options.cancelText = context.options.confirmText or "直接领取"
        options.confirmText = context.adWatched and "重试领取五倍" or RewardVideo.ActionText("看广告 · 五倍", "免广告 · 五倍")
        options.onCancel = function() FinishContext(context) end
        options.onConfirm = function() Watch(context) end
    end
    local built = RewardDialogView.BuildOptions(options)
    if not built then
        if context.reservation then DialogCoordinator.ReleaseReservation(context.reservation); context.reservation = nil end
        FinishContext(context)
        return false
    end
    if context.buildOnly then context.buildOnly = false; return built end
    local reservation = context.reservation
    context.reservation = nil
    if reservation then return DialogCoordinator.EnqueueReserved(reservation, built) end
    return CommonPromptDialog.Show(built)
end
Watch = function(context)
    if context.closed then return end
    if adInFlight_ or requestPending_ or exclusiveInFlight_ then
        UI.Toast.Show("激励奖励正在处理中", { position = "bottom", variant = "info" })
        Present(context, false); return
    end
    sequence_ = sequence_ + 1
    local generation = sequence_
    context.reservation = DialogCoordinator.ReserveNext()
    local function RequestReward()
        requestPending_ = true
        ServerClient.ClaimRewardAdExtras(context.ids, function(response)
            if generation ~= sequence_ or context.closed then return end
            requestPending_ = false
            for _, receipt in ipairs(response and response.data and response.data.rewards or {}) do
                if contexts_[receipt.rewardId] == context then
                    context.receipts[receipt.rewardId] = receipt
                    claimed_[receipt.rewardId] = true
                end
            end
            local complete = true
            for _, id in ipairs(context.ids) do if not context.receipts[id] then complete = false end end
            if complete then
                Present(context, true)
            else
                UI.Toast.Show(response and response.reason or "奖励结算未完成，可重试领取", { position = "bottom", variant = "warning" })
                Present(context, false)
            end
        end)
    end
    if context.adWatched then RequestReward(); return end
    adInFlight_, adElapsed_ = true, 0
    local finished = false
    local function FinishAd(result)
        if finished or generation ~= sequence_ then return end
        finished = true
        adInFlight_, adElapsed_, adTimeoutFinish_ = false, 0, nil
        if result and result.success == true then
            context.adWatched = true
            RequestReward()
        else
            UI.Toast.Show("广告未完成，基础奖励已保留，可直接领取或重试", { position = "bottom", variant = "warning" })
            Present(context, false)
        end
    end
    adTimeoutFinish_ = FinishAd
    local accepted = RewardVideo.Play(FinishAd)
    if accepted == false then FinishAd({ success = false }) end
end

function RewardClaimController.ShowReward(options, events, buildOnly)
    if presented_[options.queueKey] then return false end
    local offers, ids, seen = {}, {}, {}
    for _, event in ipairs(events or {}) do
        if (event.kind or event.type) == "reward_offer_pending" and event.source ~= "offline"
            and event.rewardId and not seen[event.rewardId] and not shown_[event.rewardId] then
            seen[event.rewardId] = true
            ids[#ids + 1] = event.rewardId
            offers[#offers + 1] = { id = event.rewardId, baseReward = event.baseReward or {} }
        end
    end
    if #ids == 0 then
        options.cards = options.buildCards({})
        local accepted = buildOnly and RewardDialogView.BuildOptions(options) or RewardDialogView.Show(options)
        if accepted then presented_[options.queueKey] = true end
        return accepted
    end
    local context = { ids = ids, offers = offers, options = options, receipts = {}, buildOnly = buildOnly }
    for _, id in ipairs(ids) do shown_[id], contexts_[id] = true, context end
    local accepted = Present(context, false)
    if accepted then presented_[options.queueKey] = true end
    if not accepted then
        for _, id in ipairs(ids) do shown_[id], contexts_[id] = nil, nil end
    end
    return accepted
end

function RewardClaimController.CaptureOffline(events) offlineEvents_ = events end
function RewardClaimController.TakeOfflineEvents()
    local events = offlineEvents_; offlineEvents_ = nil; return events or {}
end

function RewardClaimController.ClaimExclusiveGift(giftId)
    if adInFlight_ or requestPending_ or exclusiveInFlight_ then
        UI.Toast.Show("激励奖励正在处理中", {
            duration = 1.8,
            variant = "info",
            position = "bottom",
        })
        return false
    end
    if not RewardVideo.IsAvailable() then
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
    local accepted = require("client.RewardVideo").Play(function(result)
        callbackFired = true
        finish(result)
    end)
    if accepted == false and not callbackFired then
        finish({ success = false, msg = "广告展示请求未受理" })
    end
    return accepted ~= false
end

-- Snapshots synchronize state only. They must not resurrect a second advertisement
-- prompt for a reward already presented by a delta or explicitly declined.
function RewardClaimController.ShowPending() return false end

function RewardClaimController.HandleDelta(payload)
    local totals, hasResult = {}, false
    for _, value in ipairs(payload and payload.events or {}) do
        if (value.kind or value.type) == "reward_ad_extra_claimed" then
            local context = contexts_[value.rewardId]
            if not context then
                for _, saved in pairs(require("client.RecoveryState").confirmed) do
                    for _, id in ipairs(saved.ids) do if id == value.rewardId then context = saved; break end end
                    if context then break end
                end
            end
            if context then context.receipts[value.rewardId] = value end
            if not context and not claimed_[value.rewardId] then
                Add(totals, value.totalReward or value.reward)
                hasResult = true
            end
            claimed_[value.rewardId] = true
        end
    end
    if hasResult then
        RewardDialogView.Show { queueKey = RewardDialogView.NextKey("fivefold_receipt"),
            title = "五倍奖励结算", message = "可加成奖励合计（含基础奖励）",
            lines = { "基础奖励已到账，本次仅补发额外部分。" }, cards = Cards(totals) }
    end
end
function RewardClaimController.Update(dt)
    if not adInFlight_ or not adTimeoutFinish_ then return end
    adElapsed_ = adElapsed_ + math.max(0, tonumber(dt) or 0)
    if adElapsed_ >= AD_WATCHDOG_SECONDS then adTimeoutFinish_({ success = false, msg = "广告响应超时" }) end
end
function RewardClaimController.ResumeConfirmed()
    local recovery = require("client.RecoveryState")
    for key, context in pairs(recovery.confirmed) do
        context.closed = false
        for _, id in ipairs(context.ids) do contexts_[id] = context end
        if Present(context, false) then recovery.confirmed[key] = nil; return true end
    end
    return false
end
function RewardClaimController.Reset()
    local recovery = require("client.RecoveryState")
    if recovery.rebuilding then
        for id, context in pairs(contexts_) do
            if context.adWatched and not context.closed then recovery.confirmed[context.ids[1]] = context end
        end
    end
    sequence_ = sequence_ + 1
    for _, context in pairs(contexts_) do
        if context.reservation then DialogCoordinator.ReleaseReservation(context.reservation); context.reservation = nil end
    end
    adInFlight_, requestPending_, exclusiveInFlight_ = false, false, false
    adElapsed_, adTimeoutFinish_ = 0, nil
    shown_, contexts_, claimed_, presented_ = BoundedSet(512), {}, BoundedSet(512), BoundedSet(512)
    offlineEvents_ = nil
end
return RewardClaimController
