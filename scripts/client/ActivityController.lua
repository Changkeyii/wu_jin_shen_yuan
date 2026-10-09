-- ActivityController.lua
-- 活动系统客户端控制：打开活动页 / 签到 / 木桩打桩 / 广告解锁 / 红点。

local ServerClient = require("client.ServerClient")

local ActivityController = {}

local requestPageRefresh_ = nil

function ActivityController.Configure(context)
    context = context or {}
    requestPageRefresh_ = context.requestPageRefresh
end

function ActivityController.Refresh()
    if requestPageRefresh_ then requestPageRefresh_() end
end

function ActivityController.Open()
    require("client.NavigationController").SwitchPage("activity")
end

-- 请求在途锁：同一命令 + 活动在回包前忽略连点（框架保证无论成败都会回包）。
-- debounce 为 false 的命令（如打桩高频攻击）不做防抖。
local pendingCommands_ = {}
local generation_ = 0

local function Send(command, payload, onDone, debounce)
    local key = command .. ":" .. tostring(payload and payload.activityId or "")
    if debounce and pendingCommands_[key] then
        if onDone then onDone({ ok = false, reason = "处理中，请稍候" }) end
        return false
    end
    if debounce then pendingCommands_[key] = true end
    local generation = generation_
    ServerClient.Send(command, payload, function(response)
        if generation ~= generation_ then return end
        if debounce then pendingCommands_[key] = nil end
        if onDone then onDone(response) end
        ActivityController.Refresh()
    end)
    return true
end

function ActivityController.Recover() generation_ = generation_ + 1; pendingCommands_ = {} end

function ActivityController.SignIn(activityId, onDone)
    Send("Activity.SignIn", { activityId = activityId }, onDone, true)
end

function ActivityController.BeginStrike(activityId, onDone)
    Send("Activity.BeginStrike", { activityId = activityId }, onDone, true)
end

function ActivityController.Strike(activityId, onDone)
    Send("Activity.Strike", { activityId = activityId }, onDone, false)
end

function ActivityController.FinishStrike(activityId, onDone)
    Send("Activity.FinishStrike", { activityId = activityId }, onDone, true)
end

function ActivityController.UnlockExtraStrike(activityId, onDone)
    Send("Activity.UnlockExtraStrike", { activityId = activityId }, onDone, true)
end

function ActivityController.EnterAbyss(gradeId, onDone)
    Send("Activity.EnterAbyss", { gradeId = gradeId }, onDone, true)
end

function ActivityController.BeginAbyssBoss(gradeId, onDone)
    Send("Activity.BeginAbyssBoss", { gradeId = gradeId }, onDone, true)
end

function ActivityController.StrikeAbyssBoss(onDone)
    Send("Activity.StrikeAbyssBoss", {}, onDone, false)
end

function ActivityController.FinishAbyssBoss(onDone)
    Send("Activity.FinishAbyssBoss", {}, onDone, true)
end

function ActivityController.HasRedDot(game)
    local view = game and game.activitiesView
    return view ~= nil and view.redDot > 0
end

return ActivityController
