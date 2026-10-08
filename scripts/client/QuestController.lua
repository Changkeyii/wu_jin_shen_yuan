-- QuestController.lua
-- 任务系统客户端控制：打开任务页 / 领取 / 一键领取 / 可领红点判定。

local ServerClient = require("client.ServerClient")

local QuestController = {}

local requestPageRefresh_ = nil
local activeTab_ = "newbie"

function QuestController.Configure(context)
    context = context or {}
    requestPageRefresh_ = context.requestPageRefresh
end

function QuestController.Refresh()
    if requestPageRefresh_ then requestPageRefresh_() end
end

function QuestController.Open()
    require("client.NavigationController").SwitchPage("quest")
end

-- 请求在途锁：同一任务/一键领取在回包前忽略连点（框架保证无论成败都会回包）。
local pending_ = {}

function QuestController.Claim(questId, onDone)
    local key = "Quest.Claim:" .. tostring(questId)
    if pending_[key] then
        if onDone then onDone({ ok = false, reason = "处理中，请稍候" }) end
        return
    end
    pending_[key] = true
    ServerClient.Send("Quest.Claim", { questId = questId }, function(response)
        pending_[key] = nil
        if onDone then onDone(response) end
        QuestController.Refresh()
    end)
end

function QuestController.ClaimAll(onDone)
    if pending_["all"] then
        if onDone then onDone({ ok = false, reason = "处理中，请稍候" }) end
        return
    end
    pending_["all"] = true
    ServerClient.Send("Quest.ClaimAll", {}, function(response)
        pending_["all"] = nil
        if onDone then onDone(response) end
        QuestController.Refresh()
    end)
end

function QuestController.GetTab()
    return activeTab_
end

function QuestController.SetTab(questType)
    if activeTab_ == questType then return end
    activeTab_ = questType
    QuestController.Refresh()
end

function QuestController.HasClaimable(game)
    local view = game and game.questsView
    if not view then return false end
    for _, questType in ipairs({ "newbie", "daily", "weekly", "achievement" }) do
        for _, quest in ipairs(view[questType] or {}) do
            if quest.state == "claimable" then return true end
        end
    end
    return false
end

function QuestController.CountClaimable(game, questType)
    local view = game and game.questsView
    if not view or not view[questType] then return 0 end
    local count = 0
    for _, quest in ipairs(view[questType]) do
        if quest.state == "claimable" then count = count + 1 end
    end
    return count
end

return QuestController
