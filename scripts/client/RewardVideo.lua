-- 所有激励广告共享一个在途锁。只使用项目 @runtime.ad，由 SDK 选择激励广告位。
local M = {}
M.WATCHDOG_SECONDS = 180
local serial = 0
local elapsed = 0
local startedAt = 0
local pending --[[@type function?]]
function M.IsBusy() return pending ~= nil end
function M.Play(callback)
    if pending then callback({ success = false, msg = "广告正在播放" }); return false end
    local sdk = _G.sdk
    if not sdk or type(sdk.ShowRewardVideoAd) ~= "function" then
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
