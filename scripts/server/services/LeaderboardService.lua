-- LeaderboardService.lua
-- 排行榜：绝对服务端权威，serverCloud 持久化，内存维护有界 Top 100（动态增删改查）。
-- 排行榜只保存权威装备数据（二进制 blob 供详情展示），静态配表由客户端凭 equipmentId 查表。

local Catalog = require("server.domain.Catalog")
local PlayerTransition = require("server.domain.PlayerTransition")
local LeaderboardCodec = require("shared.LeaderboardCodec")

local MAX_ENTRIES = 100
local MAX_BLOB_BYTES = 16384
local KEY_POWER = "lb_power"
local KEY_NICK = "lb_nick"
local KEY_BLOB = "lb_blob"

local LeaderboardService = {}
LeaderboardService.__index = LeaderboardService

function LeaderboardService.New(options)
    local instance = {
        gateway = options.gateway,
        log = options.log or print,
        clock = options.clock or os.time,
        entries = {},      -- [userId] = { userId, nickname, power, blobHex, blobHash, updatedAt }
        pendingWrites = {}, -- 串行化 serverCloud 写入队列
        flushing = false,
        loaded = false,
        loading = false,
        seasonSnapshots = {},
    }
    return setmetatable(instance, LeaderboardService)
end

-- ============================================================================
-- 装备权威数据收集 / blob 生成（服务端权威，不信任客户端）
-- ============================================================================

--- 从玩家 state 收集已装备部位，生成带权威评估属性的条目数组
---@param state table
---@return table[]
function LeaderboardService:CollectEquippedItems(state)
    state = state or {}
    local items = {}
    local equipped = state.equipped or {}
    for slotId, itemId in pairs(equipped) do
        local item = PlayerTransition.FindItem(state, itemId)
        if item and item.equipmentId then
            local stats = Catalog.GetItemEffectiveStats(item)
            items[#items + 1] = {
                slot = item.slot or slotId,
                equipmentId = item.equipmentId,
                rarity = item.rarity or "common",
                level = item.level or 1,
                enhance = item.enhance or 0,
                star = item.star or 0,
                quantity = item.quantity or 1,
                setId = item.setId,
                setEnabled = item.setEnabled ~= false,
                source = item.source,
                coreAffixes = item.coreAffixes,
                uniqueEffects = item.uniqueEffects,
                atkBig = stats.atkBig,
                defBig = stats.defBig,
                hpBig = stats.hpBig,
                crit = stats.crit,
                critDmg = stats.critDmg,
                atkSpeed = stats.atkSpeed,
                lifeSteal = stats.lifeSteal,
                damageReduction = stats.damageReduction,
                bossDamage = stats.bossDamage,
            }
        end
    end
    return items
end

--- 打包装备 + 个性签名 index 为二进制 blob，返回 (blob, blobHex)
function LeaderboardService:BuildBlob(items, trashTalkIndex)
    items = type(items) == "table" and items or {}
    local blob = LeaderboardCodec.Pack(items, trashTalkIndex) or ""
    if #blob > MAX_BLOB_BYTES then
        blob = ""
    end
    return blob, LeaderboardCodec.ToHex(blob)
end

-- ============================================================================
-- 有界 Top 100（内存权威）
-- ============================================================================

local function SortEntries(entries)
    table.sort(entries, function(a, b)
        if a.power ~= b.power then return a.power > b.power end
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

--- 是否比另一条目更优（战力更高；同分则更新时间更早）
local function Better(a, b)
    if a.power ~= b.power then return a.power > b.power end
    return a.updatedAt < b.updatedAt
end

---@param userId integer
---@param nickname string
---@param power integer
---@param blobHex string
---@param blobHash string
function LeaderboardService:Insert(userId, nickname, power, blobHex, blobHash)
    self.entries[userId] = {
        userId = userId,
        nickname = nickname,
        power = power,
        blobHex = blobHex,
        blobHash = blobHash,
        updatedAt = self.clock(),
    }
    self:EnqueueWrite({
        type = "set",
        userId = userId,
        power = power,
        nickname = nickname,
        blobHex = blobHex,
    })
end

---@param userId integer
function LeaderboardService:Evict(userId)
    local entry = self.entries[userId]
    if not entry then return end
    self.entries[userId] = nil
    self.log("[Leaderboard] evict uid=" .. tostring(userId))
    self:EnqueueWrite({ type = "delete", userId = userId })
end

--- 统一的增/改/查入口。服务端在玩家快照/战力/装备/个性签名变化后调用。
---@param userId integer
---@param nickname string
---@param power integer
---@param items table[] 装备权威数据（已收集）
---@param trashTalkIndex number|nil 个性签名 index（写入二进制 blob）
function LeaderboardService:Upsert(userId, nickname, power, items, trashTalkIndex)
    power = math.max(0, math.floor(tonumber(power) or 0))
    nickname = tostring(nickname or "")
    local blob, blobHex = self:BuildBlob(items, trashTalkIndex)

    local entry = self.entries[userId]
    if entry then
        -- 改：仅在战力/昵称/装备实际变化时落库
        if entry.power == power and entry.blobHex == blobHex and entry.nickname == nickname then
            return
        end
        entry.power = power
        entry.nickname = nickname
        entry.blobHex = blobHex
        entry.blobHash = blobHex
        entry.updatedAt = self.clock()
        -- 榜满且本次更新后跌为最弱 → 下榜（删）
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
            power = power,
            nickname = nickname,
            blobHex = blobHex,
        })
        return
    end

    -- 增
    local count = 0
    for _ in pairs(self.entries) do count = count + 1 end
    if count < MAX_ENTRIES then
        self:Insert(userId, nickname, power, blobHex, blobHex)
        return
    end
    local list = SortedList(self)
    local weakest = list[#list]
    if weakest and Better({ power = power, updatedAt = self.clock() }, weakest) then
        self:Evict(weakest.userId)
        self:Insert(userId, nickname, power, blobHex, blobHex)
    end
end

---@param userId integer|nil 请求者本人（用于返回 selfRank）
---@return table[], integer
function LeaderboardService:GetTop(userId)
    local list = SortedList(self)
    local result = {}
    local selfRank = 0
    for index, entry in ipairs(list) do
        result[#result + 1] = {
            rank = index,
            userId = entry.userId,
            nickname = entry.nickname,
            power = entry.power,
        }
        if entry.userId == userId then selfRank = index end
    end
    return result, selfRank
end

---@param userId integer
---@return table|nil
function LeaderboardService:GetDetail(userId)
    local entry = self.entries[userId]
    if not entry then return nil end
    local items = {}
    local trashTalkIndex = 0
    if entry.blobHex and entry.blobHex ~= "" then
        local decoded, decodeError, decodedIndex = LeaderboardCodec.Unpack(LeaderboardCodec.FromHex(entry.blobHex))
        if decoded then items = decoded end
        trashTalkIndex = decodedIndex or 0
        if decodeError then
            self.log("[Leaderboard] decode detail failed uid=" .. tostring(userId))
        end
    end
    return {
        userId = entry.userId,
        nickname = entry.nickname,
        power = entry.power,
        equipment = items,
        trashTalkIndex = trashTalkIndex,
    }
end

function LeaderboardService:Count()
    local count = 0
    for _ in pairs(self.entries) do count = count + 1 end
    return count
end

-- ============================================================================
-- serverCloud 持久化镜像（串行写队列）
-- ============================================================================

function LeaderboardService:EnqueueWrite(operation)
    self.pendingWrites[#self.pendingWrites + 1] = operation
    self:FlushPendingWrites()
end

function LeaderboardService:FlushPendingWrites()
    if self.flushing or #self.pendingWrites == 0 then return end
    if not self.gateway or not self.gateway:IsAvailable() then
        -- serverCloud 不可用：仅内存，记录一次即可
        self.pendingWrites = {}
        return
    end
    self.flushing = true
    local operation = table.remove(self.pendingWrites, 1)
    local description = "leaderboard " .. operation.type
    local function Finished(result)
        self.flushing = false
        if not result.ok then
            self.log("[Leaderboard] " .. operation.type .. " failed uid="
                .. tostring(operation.userId) .. " code=" .. tostring(result.code))
        end
        self:FlushPendingWrites()
    end

    if operation.type == "set" then
        self.gateway:BatchSet(operation.userId, {
            { key = KEY_POWER, kind = "set_int", value = operation.power },
            { key = KEY_NICK, kind = "set", value = operation.nickname },
            { key = KEY_BLOB, kind = "set", value = operation.blobHex },
        }, description, Finished)
    else
        self.gateway:BatchSet(operation.userId, {
            { key = KEY_POWER, kind = "delete" },
            { key = KEY_NICK, kind = "delete" },
            { key = KEY_BLOB, kind = "delete" },
        }, description, Finished)
    end
end

-- ============================================================================
-- 启动恢复
-- ============================================================================

function LeaderboardService:Load()
    if self.loaded or self.loading then return end
    if not self.gateway or not self.gateway:IsAvailable() then
        self.loaded = true
        return
    end
    self.loading = true
    self.gateway:RankGetList(KEY_POWER, 1, MAX_ENTRIES, false, function(listResult)
        if not listResult.ok then
            self.loading = false
            self.log("[Leaderboard] load rank failed code=" .. tostring(listResult.code))
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
        self.gateway:BatchGet(userIds, { KEY_POWER, KEY_NICK, KEY_BLOB }, function(batchResult)
            self.loading = false
            self.loaded = true
            if not batchResult.ok then
                self.log("[Leaderboard] load detail failed code=" .. tostring(batchResult.code))
                return
            end
            local results = batchResult.data.results or {}
            for _, result in ipairs(results) do
                local rowUserId = result.userId or result.player
                if rowUserId and order[rowUserId] then
                    local iscores = result.iscore or result.iscores or {}
                    local scores = result.score or result.scores or {}
                    local power = math.max(0, math.floor(tonumber(iscores[KEY_POWER] or scores[KEY_POWER]) or 0))
                    local nickname = tostring(scores[KEY_NICK] or "")
                    local blobHex = tostring(scores[KEY_BLOB] or "")
                    self.entries[rowUserId] = {
                        userId = rowUserId,
                        nickname = nickname,
                        power = power,
                        blobHex = blobHex,
                        blobHash = blobHex,
                        updatedAt = self.clock(),
                    }
                end
            end
            self.log("[Leaderboard] loaded entries=" .. tostring(self:Count()))
        end)
    end)
end

function LeaderboardService.WeekKey(now)
    local dayKey = math.floor(((tonumber(now) or os.time()) + 8 * 3600) / 86400)
    return math.floor((dayKey + 3) / 7)
end

local SEASON_REWARD_CAP = MAX_ENTRIES

local function SeasonRewardForRank(rank, weekKey)
    local title
    local frame
    local honor
    if rank == 1 then
        title, frame, honor = "深渊霸主", "黄金头像框", 300
    elseif rank <= 3 then
        title, frame, honor = "深渊三杰", "紫晶头像框", 180
    elseif rank <= 10 then
        title, frame, honor = "深渊十强", "蓝钢头像框", 80
    elseif rank <= 50 then
        title, frame, honor = "深渊五十强", "青钢头像框", 40
    else
        title, frame, honor = "深渊百强", "灰钢头像框", 20
    end
    return {
        weekKey = weekKey,
        rank = rank,
        title = title,
        frame = frame,
        honor = honor,
    }
end

function LeaderboardService:EnsureSeasonSnapshot(now)
    local weekKey = LeaderboardService.WeekKey(now)
    local lastWeek = weekKey - 1
    if lastWeek < 1 then return {}, weekKey, lastWeek end
    self.seasonSnapshots = self.seasonSnapshots or {}
    if not self.seasonSnapshots[lastWeek] then
        local list = SortedList(self)
        local snapshot = {}
        for rank, entry in ipairs(list) do
            if rank > SEASON_REWARD_CAP then break end
            snapshot[entry.userId] = SeasonRewardForRank(rank, lastWeek)
        end
        self.seasonSnapshots[lastWeek] = snapshot
        self.log("[Leaderboard] froze season snapshot week=" .. tostring(lastWeek))
        for key in pairs(self.seasonSnapshots) do
            if key < lastWeek - 1 then self.seasonSnapshots[key] = nil end
        end
    end
    return self.seasonSnapshots[lastWeek], weekKey, lastWeek
end

function LeaderboardService:SeasonRewards(now)
    return self:EnsureSeasonSnapshot(now)
end

function LeaderboardService:Reset()
    self.entries = {}
    self.pendingWrites = {}
    self.flushing = false
    self.loaded = false
    self.loading = false
    self.seasonSnapshots = {}
end

LeaderboardService.MAX_ENTRIES = MAX_ENTRIES
LeaderboardService.SEASON_REWARD_CAP = SEASON_REWARD_CAP
LeaderboardService.KEY_POWER = KEY_POWER
LeaderboardService.KEY_NICK = KEY_NICK
LeaderboardService.KEY_BLOB = KEY_BLOB

return LeaderboardService
