-- Damage and Boss ranks share the cloud authority, with independent score keys.
local ChallengeDefinitions = require("shared.ChallengeDefinitions")
local CloudStore = require("server.services.CloudLeaderboardStore")
---@class ScoreLeaderboardService
---@field store CloudLeaderboardStore
local ScoreLeaderboardService = {}
ScoreLeaderboardService.__index = ScoreLeaderboardService
---@return ScoreLeaderboardService
function ScoreLeaderboardService.New(options)
    options.onlyIncrease = true
    local instance = {store=CloudStore.New(options)}
    return setmetatable(instance, ScoreLeaderboardService)
end
function ScoreLeaderboardService:Upsert(userId, nickname, score)
    score = ChallengeDefinitions.ClampScore(score)
    if score > 0 then self.store:Upsert(userId, nickname, score) end
end
function ScoreLeaderboardService:GetTop(userId, onComplete)
    self.store:GetTop(userId, onComplete)
end
function ScoreLeaderboardService:Update() self.store:Update() end
function ScoreLeaderboardService:Reset() self.store:Reset() end
ScoreLeaderboardService.MAX_ENTRIES = 100
return ScoreLeaderboardService
