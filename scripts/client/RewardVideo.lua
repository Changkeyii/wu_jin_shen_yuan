-- 所有激励广告共享一个在途锁。只使用项目 @runtime.ad，由 SDK 选择激励广告位。
---@class RewardVideo
local M = {}
local Adapter = require("client.GameStateAdapter")
local ServerClient = require("client.ServerClient")
M.WATCHDOG_SECONDS = 180
local serial = 0
local elapsed = 0
local startedAt = 0
local pending --[[@type function?]]
function M.IsBusy() return pending ~= nil end
function M.IsAdFree()
    local game = Adapter.GetViewState()
    return game and game.adFree == true and game.readOnly ~= true or false
end
function M.IsAvailable()
    local sdk = _G.sdk --[[@as {ShowRewardVideoAd: fun(self: any, callback: function): boolean?}?]]
    return M.IsAdFree() or (sdk ~= nil and type(sdk.ShowRewardVideoAd) == "function")
end
function M.ActionText(normal, exempt) return M.IsAdFree() and exempt or normal end
function M.Play(callback)
    if pending then callback({ success = false, msg = "广告正在播放" }); return false end
    local sdk = _G.sdk --[[@as {ShowRewardVideoAd: fun(self: any, callback: function): boolean?}?]]
    local exempt = M.IsAdFree()
    if not exempt and (not sdk or type(sdk.ShowRewardVideoAd) ~= "function") then
        callback({ success = false, msg = "广告暂不可用" }); return false
    end
    serial = serial + 1
    local generation, completed = serial, false
    local function finish(result)
        if completed or generation ~= serial then return end
        completed = true
        pending, elapsed = nil, 0
        callback(type(result) == "table" and result or { success = false, msg = "广告响应无效" })
    end
    pending, elapsed, startedAt = finish, 0, os.time()
    if exempt then
        -- A local display flag is not proof. Confirm the current authoritative
        -- identity before continuing the existing server reward transaction.
        local ok, request = pcall(ServerClient.VerifyAdFree, function(response)
            local verified = response and response.ok == true and response.data and response.data.adFree == true
            finish({ success = verified == true, adFree = verified == true,
                msg = verified and "免广告身份已确认" or (response and response.reason or "免广告身份确认失败，请重试") })
        end)
        if not ok or not request then finish({ success = false, msg = "免广告身份确认请求未受理" }) end
        return ok and request ~= nil and request ~= false
    end
    local ok, accepted = pcall(function() return sdk:ShowRewardVideoAd(finish) end)
    if not ok or accepted == false then finish({ success = false, msg = "广告暂不可用，请稍后重试" }) end
    return ok and accepted ~= false
end
function M.Update(dt)
    if not pending then return end
    elapsed = elapsed + math.max(0, tonumber(dt) or 0)
    -- 故障恢复超时，不是广告冷却或领取限制。
    if math.max(elapsed, os.time() - startedAt) >= M.WATCHDOG_SECONDS then pending({ success = false, msg = "广告响应超时，请重新尝试" }) end
end
function M.Cancel()
    if pending then pending({ success = false, msg = "已结束等待，可重新尝试" }) end
end
function M.Reset()
    serial = serial + 1
    pending, elapsed = nil, 0
end
return M
