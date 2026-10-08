-- LeaderboardController.lua
-- 排行榜入口：打开弹窗（Top100 列表）与玩家详情。
-- 战力榜保持原接口；伤害榜 / Boss 榜走独立 board 查询。

local UI = require("urhox-libs/UI")
local ServerClient = require("client.ServerClient")
local LeaderboardView = require("client.LeaderboardView")
local LeaderboardDetailView = require("client.LeaderboardDetailView")

local LeaderboardController = {}

local inFlight_ = false
local currentBoard_ = "power"

local function Toast(message, variant)
    UI.Toast.Show(message, {
        duration = 2.2,
        variant = variant or "error",
        position = "bottom",
    })
end

local function OpenBoard(board)
    board = board == "damage" and "damage" or (board == "boss" and "boss" or (board == "season" and "season" or "power"))
    if inFlight_ then return end
    inFlight_ = true
    currentBoard_ = board
    local queryBoard = board == "season" and "power" or board
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
            end,
            {
                board = board,
                onSelectTab = function(nextBoard)
                    if nextBoard == currentBoard_ then return end
                    OpenBoard(nextBoard)
                end,
            }
        )
    end, queryBoard)
end

function LeaderboardController.Open()
    OpenBoard("power")
end

function LeaderboardController.ShowDetail(userId)
    if currentBoard_ ~= "power" then
        Toast("伤害榜与 Boss 榜仅展示成绩，装备详情请看战力榜", "info")
        return
    end
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
    currentBoard_ = "power"
end

return LeaderboardController
