-- LeaderboardController.lua
-- 排行榜入口：打开弹窗（Top100 列表）与玩家详情。

local UI = require("urhox-libs/UI")
local ServerClient = require("client.ServerClient")
local LeaderboardView = require("client.LeaderboardView")
local LeaderboardDetailView = require("client.LeaderboardDetailView")

local LeaderboardController = {}

local inFlight_ = false

local function Toast(message, variant)
    UI.Toast.Show(message, {
        duration = 2.2,
        variant = variant or "error",
        position = "bottom",
    })
end

function LeaderboardController.Open()
    if inFlight_ then return end
    inFlight_ = true
    ServerClient.GetLeaderboard(function(response)
        inFlight_ = false
        if not response or not response.ok then
            Toast((response and response.reason) or "排行榜加载失败")
            return
        end
        local data = response.data or {}
        LeaderboardView.Show(
            data.list or {},
            data.selfRank or 0,
            data.total or 0,
            function(userId)
                LeaderboardController.ShowDetail(userId)
            end
        )
    end)
end

function LeaderboardController.ShowDetail(userId)
    if inFlight_ then return end
    inFlight_ = true
    ServerClient.GetLeaderboardDetail(userId, function(response)
        inFlight_ = false
        if not response or not response.ok then
            Toast((response and response.reason) or "玩家详情加载失败")
            return
        end
        LeaderboardDetailView.Show(response.data or {})
    end)
end

function LeaderboardController.Reset()
    inFlight_ = false
end

return LeaderboardController
