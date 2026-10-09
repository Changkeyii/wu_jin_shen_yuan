-- Power ranks and details are read from the shared cloud on every request.
local Catalog = require("server.domain.Catalog")
local PlayerTransition = require("server.domain.PlayerTransition")
local LeaderboardCodec = require("shared.LeaderboardCodec")
local CloudStore = require("server.services.CloudLeaderboardStore")
local BigNumber = require("shared.BigNumber")
local MAX_ENTRIES, MAX_BLOB_BYTES = 100, 16384
local KEY_POWER, KEY_NICK, KEY_BLOB = "lb_power", "lb_nick", "lb_blob"
---@class LeaderboardService
---@field store CloudLeaderboardStore
---@field clock fun(): number
---@field log fun(message: string)
---@field entries table
---@field seasonSnapshots table
---@field loaded boolean
---@field loading boolean
---@field nextLoadAt number
local LeaderboardService = {}
LeaderboardService.__index = LeaderboardService
---@return LeaderboardService
function LeaderboardService.New(options)
    local instance = {
        store = CloudStore.New({gateway=options.gateway, clock=options.clock, log=options.log,
            boardId="power",keyScore=KEY_POWER,keyNick=KEY_NICK,keyBlob=KEY_BLOB}),
        log=options.log or print, clock=options.clock or os.time,
        entries={}, seasonSnapshots={}, loaded=false, loading=false, nextLoadAt=0,
    }
    return setmetatable(instance, LeaderboardService)
end

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


function LeaderboardService:Upsert(userId, nickname, power, items, trashTalkIndex)
    local _, hex = self:BuildBlob(items, trashTalkIndex)
    self.store:Upsert(userId, nickname, BigNumber.Normalize(power), hex)
end

function LeaderboardService:GetTop(userId, onComplete)
    self.store:GetTop(userId, onComplete)
end

function LeaderboardService:GetDetail(userId, onComplete)
    self.store:GetDetail(userId, function(result)
        if result.ok then
            local data = result.data
            local items, decodeError, index = LeaderboardCodec.Unpack(LeaderboardCodec.FromHex(data.blobHex))
            if decodeError then
                onComplete({ok=false, code="LEADERBOARD_DETAIL_UNAVAILABLE", reason="玩家装备详情暂不可用，请稍后重试"})
                return
            end
            data.blobHex, data.equipment, data.trashTalkIndex = nil, items or {}, index or 0
        end
        onComplete(result)
    end)
end

-- The existing season reward cache is populated only by a successful shared-cloud
-- read, never by the set of players connected to this server instance.
function LeaderboardService:Load()
    if self.loaded or self.loading or self.clock() < self.nextLoadAt then return end
    self.loading = true
    self:GetTop(nil, function(result)
        self.loading = false
        if not result.ok then self.nextLoadAt=self.clock()+5; return end
        self.entries = result.data.list
        self.loaded = true
    end)
end

function LeaderboardService:Update()
    self.store:Update()
    if not self.loaded then self:Load() end
end

local function SortedList(self) return self.entries end

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
    if not self.loaded then return nil, weekKey, lastWeek end
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
    self.store:Reset()
    self.entries, self.seasonSnapshots = {}, {}
    self.loaded, self.loading, self.nextLoadAt = false, false, 0
end
LeaderboardService.MAX_ENTRIES = MAX_ENTRIES
LeaderboardService.SEASON_REWARD_CAP = SEASON_REWARD_CAP
LeaderboardService.KEY_POWER = KEY_POWER
LeaderboardService.KEY_NICK = KEY_NICK
LeaderboardService.KEY_BLOB = KEY_BLOB
return LeaderboardService
