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

function QuestController.Claim(questId, onDone)
    ServerClient.Send("Quest.Claim", { questId = questId }, function(response)
        if onDone then onDone(response) end
        QuestController.Refresh()
    end)
end

function QuestController.ClaimAll(onDone)
    ServerClient.Send("Quest.ClaimAll", {}, function(response)
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
    for _, questType in ipairs({ "newbie", "daily", "achievement" }) do
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
