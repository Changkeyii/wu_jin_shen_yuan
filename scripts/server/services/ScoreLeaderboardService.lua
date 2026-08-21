-- ScoreLeaderboardService.lua
-- 独立整数分排行榜（伤害榜 / Boss 榜）。
-- 与战力榜 LeaderboardService 完全隔离：不同 cloud key、不同内存表，互不改写。

local ChallengeDefinitions = require("shared.ChallengeDefinitions")

local MAX_ENTRIES = 100

local ScoreLeaderboardService = {}
ScoreLeaderboardService.__index = ScoreLeaderboardService

function ScoreLeaderboardService.New(options)
    options = options or {}
    local instance = {
        gateway = options.gateway,
        log = options.log or print,
        clock = options.clock or os.time,
        boardId = tostring(options.boardId or "score"),
        keyScore = tostring(options.keyScore or "lb_score"),
        keyNick = tostring(options.keyNick or "lb_score_nick"),
        entries = {},
        pendingWrites = {},
        flushing = false,
        loaded = false,
        loading = false,
    }
    return setmetatable(instance, ScoreLeaderboardService)
end

local function SortEntries(entries)
    table.sort(entries, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.updatedAt < b.updatedAt
    end)
    return entries
end

local function SortedList(self)
    local list = {}
    for _, entry in pairs(self.entries) do
        list[#list + 1] = entry
    end
    return SortEntries(list)
end

local function Better(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.updatedAt < b.updatedAt
end

function ScoreLeaderboardService:Insert(userId, nickname, score)
    self.entries[userId] = {
        userId = userId,
        nickname = nickname,
        score = score,
        updatedAt = self.clock(),
    }
    self:EnqueueWrite({
        type = "set",
        userId = userId,
        score = score,
        nickname = nickname,
    })
end

function ScoreLeaderboardService:Evict(userId)
    local entry = self.entries[userId]
    if not entry then return end
    self.entries[userId] = nil
    self.log("[ScoreLB:" .. self.boardId .. "] evict uid=" .. tostring(userId))
    self:EnqueueWrite({ type = "delete", userId = userId })
end

function ScoreLeaderboardService:Upsert(userId, nickname, score)
    score = ChallengeDefinitions.ClampScore(score)
    if score <= 0 then return end
    nickname = tostring(nickname or "")
    local entry = self.entries[userId]
    if entry then
        if entry.score == score and entry.nickname == nickname then
            return
        end
        -- 只升不降：更低分不覆盖已上榜的个人最佳
        if score < entry.score then
            if entry.nickname ~= nickname then
                entry.nickname = nickname
                self:EnqueueWrite({
                    type = "set",
                    userId = userId,
                    score = entry.score,
                    nickname = nickname,
                })
            end
            return
        end
        entry.score = score
        entry.nickname = nickname
        entry.updatedAt = self.clock()
        local count = 0
        for _ in pairs(self.entries) do count = count + 1 end
        if count >= MAX_ENTRIES then
            local list = SortedList(self)
            local weakest = list[#list]
            if weakest and weakest.userId == userId then
                self:Evict(userId)
                return
            end
        end
        self:EnqueueWrite({
            type = "set",
            userId = userId,
            score = score,
            nickname = nickname,
        })
        return
    end

    local count = 0
    for _ in pairs(self.entries) do count = count + 1 end
    if count < MAX_ENTRIES then
        self:Insert(userId, nickname, score)
        return
    end
    local list = SortedList(self)
    local weakest = list[#list]
    if weakest and Better({ score = score, updatedAt = self.clock() }, weakest) then
        self:Evict(weakest.userId)
        self:Insert(userId, nickname, score)
    end
end

function ScoreLeaderboardService:GetTop(userId)
    local list = SortedList(self)
    local result = {}
    local selfRank = 0
    for index, entry in ipairs(list) do
        result[#result + 1] = {
            rank = index,
            userId = entry.userId,
            nickname = entry.nickname,
            score = entry.score,
            power = entry.score,
        }
        if entry.userId == userId then selfRank = index end
    end
    return result, selfRank
end

function ScoreLeaderboardService:Count()
    local count = 0
    for _ in pairs(self.entries) do count = count + 1 end
    return count
end

function ScoreLeaderboardService:EnqueueWrite(operation)
    self.pendingWrites[#self.pendingWrites + 1] = operation
    self:FlushPendingWrites()
end

function ScoreLeaderboardService:FlushPendingWrites()
    if self.flushing or #self.pendingWrites == 0 then return end
    if not self.gateway or not self.gateway:IsAvailable() then
        self.pendingWrites = {}
        return
    end
    self.flushing = true
    local operation = table.remove(self.pendingWrites, 1)
    local description = self.boardId .. " leaderboard " .. operation.type
    local function Finished(result)
        self.flushing = false
        if not result.ok then
            self.log("[ScoreLB:" .. self.boardId .. "] " .. operation.type
                .. " failed uid=" .. tostring(operation.userId)
                .. " code=" .. tostring(result.code))
        end
        self:FlushPendingWrites()
    end

    if operation.type == "set" then
        self.gateway:BatchSet(operation.userId, {
            { key = self.keyScore, kind = "set_int", value = operation.score },
            { key = self.keyNick, kind = "set", value = operation.nickname },
        }, description, Finished)
    else
        self.gateway:BatchSet(operation.userId, {
            { key = self.keyScore, kind = "delete" },
            { key = self.keyNick, kind = "delete" },
        }, description, Finished)
    end
end

function ScoreLeaderboardService:Load()
    if self.loaded or self.loading then return end
    if not self.gateway or not self.gateway:IsAvailable() then
        self.loaded = true
        return
    end
    self.loading = true
    self.gateway:RankGetList(self.keyScore, 1, MAX_ENTRIES, false, function(listResult)
        if not listResult.ok then
            self.loading = false
            self.log("[ScoreLB:" .. self.boardId .. "] load rank failed code="
                .. tostring(listResult.code))
            self.loaded = true
            return
        end
        local rankList = listResult.data.rankList or {}
        local userIds = {}
        local order = {}
        for _, row in ipairs(rankList) do
            local rowUserId = row.userId or row.player
            if rowUserId then
                userIds[#userIds + 1] = rowUserId
                order[rowUserId] = true
            end
        end
        if #userIds == 0 then
            self.loading = false
            self.loaded = true
            return
        end
        self.gateway:BatchGet(userIds, { self.keyScore, self.keyNick }, function(batchResult)
            self.loading = false
            self.loaded = true
            if not batchResult.ok then
                self.log("[ScoreLB:" .. self.boardId .. "] load detail failed code="
                    .. tostring(batchResult.code))
                return
            end
            local results = batchResult.data.results or {}
            for _, result in ipairs(results) do
                local rowUserId = result.userId or result.player
                if rowUserId and order[rowUserId] then
                    local iscores = result.iscore or result.iscores or {}
                    local scores = result.score or result.scores or {}
                    local score = ChallengeDefinitions.ClampScore(
                        iscores[self.keyScore] or scores[self.keyScore]
                    )
                    local nickname = tostring(scores[self.keyNick] or "")
                    self.entries[rowUserId] = {
                        userId = rowUserId,
                        nickname = nickname,
                        score = score,
                        updatedAt = self.clock(),
                    }
                end
            end
            self.log("[ScoreLB:" .. self.boardId .. "] loaded entries="
                .. tostring(self:Count()))
        end)
    end)
end

function ScoreLeaderboardService:Reset()
    self.entries = {}
    self.pendingWrites = {}
    self.flushing = false
    self.loaded = false
    self.loading = false
end

ScoreLeaderboardService.MAX_ENTRIES = MAX_ENTRIES
return ScoreLeaderboardService
