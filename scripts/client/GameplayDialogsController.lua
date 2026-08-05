local ServerClient = require("client.ServerClient")
local CommonPromptDialog = require("client.CommonPromptDialog")
local StoryCatalog = require("shared.StoryCatalog")
local LargeNumber = require("shared.LargeNumber")

local GameplayDialogsController = {}

local actionResult_ = nil

local EVENT_LABELS = {
    chest = { title = "发现宝箱", confirm = "开启宝箱" },
    merchant = { title = "神秘商人", confirm = "确认购买" },
    randomEvent = { title = "奇遇事件", confirm = "接受" },
}

local function SendStoryDecision(story, action, lineIndex)
    if not story or not story.storyId then return end
    ServerClient.AdvanceStory(action, story.storyId, lineIndex, function(response)
        if not response or not response.ok then actionResult_(response) end
    end)
end

local function SendEventDecision(pendingEvent, action)
    if not pendingEvent or not pendingEvent.eventId then return end
    ServerClient.ResolveEvent(pendingEvent.eventId, action, function(response)
        if not response or not response.ok then actionResult_(response) end
    end)
end

function GameplayDialogsController.Configure(context)
    actionResult_ = assert(context).actionResult
end

function GameplayDialogsController.ShowStoryGate(story)
    if type(story) ~= "table" or type(story.lines) ~= "table" or #story.lines == 0 then return false end
    return CommonPromptDialog.Show {
        kind = "story",
        queueKey = "story:" .. tostring(story.storyId or story.chapter or "unknown") .. ":" .. tostring(story.phase or "gate"),
        title = story.title or story.speaker or (story.chapter and ("第" .. tostring(story.chapter) .. "章") or "万灵塔记忆"),
        pages = story.lines,
        cancelText = "跳过",
        confirmText = "进入下一幕",
        closeOnOverlay = false,
        onPageAdvance = function(index) SendStoryDecision(story, "next", index) end,
        onConfirm = function() SendStoryDecision(story, "complete", #story.lines) end,
        onCancel = function() SendStoryDecision(story, "skip") end,
    }
end

-- 玩家必须主动选择；服务端超时会按 skip 结算。
function GameplayDialogsController.ShowPendingEvent(pendingEvent)
    if type(pendingEvent) ~= "table" or not pendingEvent.eventId then return false end
    local label = EVENT_LABELS[pendingEvent.eventType] or { title = "遭遇事件", confirm = "确认" }
    local lines = {}
    if pendingEvent.description then lines[#lines + 1] = tostring(pendingEvent.description) end
    if pendingEvent.goldCost then
        lines[#lines + 1] = "花费金币：" .. LargeNumber.ToString(pendingEvent.goldCost)
    end
    if pendingEvent.fragmentsReward then
        lines[#lines + 1] = "获得碎片：" .. tostring(pendingEvent.fragmentsReward)
    end
    local remaining = math.max(0, (tonumber(pendingEvent.expiresAt) or 0) - os.time())
    lines[#lines + 1] = "未选择将在 " .. tostring(remaining) .. " 秒后自动跳过"

    return CommonPromptDialog.Show {
        kind = "event",
        queueKey = "event:" .. tostring(pendingEvent.eventId),
        title = pendingEvent.title or label.title,
        lines = lines,
        confirmText = label.confirm,
        cancelText = "跳过",
        closeOnOverlay = false,
        showClose = false,
        onConfirm = function() SendEventDecision(pendingEvent, "accept") end,
        onCancel = function() SendEventDecision(pendingEvent, "skip") end,
    }
end

function GameplayDialogsController.ShowTowerRules()
    local function AcknowledgeTowerRules()
        ServerClient.AcknowledgeRules(StoryCatalog.RULE_ID, function(response)
            if not response or not response.ok then actionResult_(response) end
        end)
    end
    return CommonPromptDialog.Show {
        kind = "rules",
        queueKey = "rules:" .. StoryCatalog.RULE_ID,
        title = "无尽万灵塔规则",
        message = "在线战斗收益100%，离线固定奖励与最终掉落概率均为20%，只折算一次。",
        lines = {
            "每层10场：7普通、2精英、1 Boss；每10层为章节 Boss。",
            "死亡后回到本层第1场，双方满血，已获得奖励保留。",
            "连续失败两次会准备塔灵援助，第三次挑战前可领取定向装备。",
            "挂机开关只负责运行/暂停，不改变在线收益倍率。",
        },
        confirmText = "知道了",
        onConfirm = AcknowledgeTowerRules,
        onCancel = AcknowledgeTowerRules,
    }
end

function GameplayDialogsController.ShowAidPrompt(value)
    return CommonPromptDialog.Show {
        kind = "equipment",
        priority = 500,
        queueKey = "aid:" .. tostring(value and (value.aidId or value.floor) or "pending"),
        title = "塔灵援助",
        message = "连续失败后必须领取最低限度援助，领取后会自动继续挑战。",
        lines = {
            "援助只补到当前层可挑战线，不会提供碾压强度。",
            "援助装备通关前不可出售或分解。",
        },
        closeOnOverlay = false,
        showClose = false,
        confirmText = "领取并继续",
        onConfirm = function()
            ServerClient.ClaimAid(function(response)
                if not actionResult_(response, response and response.ok and "援助已领取" or nil) then
                    GameplayDialogsController.ShowAidPrompt(value)
                    return
                end
                ServerClient.AutoRun(true, function(autoRunResponse)
                    actionResult_(autoRunResponse, autoRunResponse and autoRunResponse.ok and "已继续刷宝" or nil)
                end)
            end)
        end,
    }
end

return GameplayDialogsController
