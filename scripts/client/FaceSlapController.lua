local DialogCoordinator = require("client.DialogCoordinator")
local FaceSlapConfig = require("client.FaceSlapConfig")
local ServerClock = require("client.ServerClock")

local FaceSlapController = {}

local FILE_NAME = "settings/face_slap_preferences.json"

local context_ = nil
local loaded_ = false
local localState_ = nil
local sessionShows_ = {}
local pending_ = {}
local lastDayKey_ = nil
local evaluationElapsed_ = 0

local function DayKey(now)
    return ServerClock.DayKey(now)
end

local function NormalizeEntry(value)
    value = type(value) == "table" and value or {}
    return {
        dayKey = math.max(0, math.floor(tonumber(value.dayKey) or 0)),
        shownToday = math.max(0, math.floor(tonumber(value.shownToday) or 0)),
        suppressedDayKey = math.max(0, math.floor(tonumber(value.suppressedDayKey) or 0)),
        lastShownAt = math.max(0, math.floor(tonumber(value.lastShownAt) or 0)),
        shownOnce = value.shownOnce == true,
    }
end

local function NormalizeState(value)
    value = type(value) == "table" and value or {}
    local campaigns = {}
    for id, entry in pairs(type(value.campaigns) == "table" and value.campaigns or {}) do
        if type(id) == "string" then campaigns[id] = NormalizeEntry(entry) end
    end
    return { version = 1, campaigns = campaigns }
end

local function Load()
    if loaded_ then return end
    loaded_ = true
    localState_ = NormalizeState(nil)
    if not fileSystem:FileExists(FILE_NAME) then return end

    local file = File(FILE_NAME, FILE_READ)
    if not file:IsOpen() then return end
    local encoded = file:ReadString()
    file:Close()
    local ok, decoded = pcall(cjson.decode, encoded)
    if ok then
        localState_ = NormalizeState(decoded)
    else
        print("[FaceSlap] failed to decode local preferences")
    end
end

local function Save()
    Load()
    fileSystem:CreateDir("settings")
    local file = File(FILE_NAME, FILE_WRITE)
    if not file:IsOpen() then
        print("[FaceSlap] failed to open local preferences for writing")
        return false
    end
    local ok, encoded = pcall(cjson.encode, localState_)
    if ok then file:WriteString(encoded) end
    file:Close()
    if not ok then print("[FaceSlap] failed to encode local preferences") end
    return ok
end

local function StorageKey(id)
    local scope = context_ and context_.getCacheScope and context_.getCacheScope() or "anonymous"
    return tostring(scope or "anonymous") .. "::" .. id
end

local function EntryFor(id, now)
    Load()
    local storageKey = StorageKey(id)
    local entry = localState_.campaigns[storageKey]
    if not entry then
        entry = NormalizeEntry(nil)
        localState_.campaigns[storageKey] = entry
    end
    local dayKey = DayKey(now)
    if entry.dayKey ~= dayKey then
        entry.dayKey = dayKey
        entry.shownToday = 0
    end
    return entry, dayKey
end

local function HasTrigger(config, trigger)
    for _, value in ipairs(config.triggers or {}) do
        if value == trigger then return true end
    end
    return false
end

local function CurrentGame()
    return context_ and context_.getGame and context_.getGame() or nil
end

local function MeetsRequirements(config, game)
    local required = config.requires or {}
    if required.connectionReady and (not game or game.connectionState ~= "ready") then return false end
    if required.page and (not game or game.page ~= required.page) then return false end
    if context_.isBlocked and context_.isBlocked(config, game) then return false end
    if context_.isEligible and context_.isEligible(config.eligibilityKey, game, config) ~= true then return false end
    return true
end

local function CanShow(config, now, game)
    local entry, dayKey = EntryFor(config.id, now)
    if config.oncePerAccount and entry.shownOnce then return false end
    if config.allowDoNotShowToday and entry.suppressedDayKey == dayKey then return false end
    if (config.maxShowsPerDay or 0) > 0 and entry.shownToday >= config.maxShowsPerDay then return false end
    if (config.maxShowsPerSession or 0) > 0
        and (sessionShows_[config.id] or 0) >= config.maxShowsPerSession
    then
        return false
    end
    if (config.cooldownSeconds or 0) > 0
        and now - entry.lastShownAt < config.cooldownSeconds
    then
        return false
    end
    if DialogCoordinator.HasKey(config.queueKey) then return false end
    return MeetsRequirements(config, game)
end

local function RecordShown(config, now)
    local entry = EntryFor(config.id, now)
    entry.shownToday = entry.shownToday + 1
    entry.lastShownAt = now
    entry.shownOnce = true
    sessionShows_[config.id] = (sessionShows_[config.id] or 0) + 1
    Save()
    print(string.format("[FaceSlap] shown id=%s day=%d count=%d",
        config.id, entry.dayKey, entry.shownToday))
end

local TryPending

local function TryShow(config, trigger)
    if not context_ or not context_.showCampaign then return false end
    local now = ServerClock.Now()
    local game = CurrentGame()
    if not CanShow(config, now, game) then return false end

    local presented = false
    local shown = context_.showCampaign(config, {
        trigger = trigger,
        manual = false,
        onPresented = function()
            if presented then return end
            presented = true
            pending_[config.id] = nil
            RecordShown(config, ServerClock.Now())
        end,
        onClosed = function()
            if context_ then TryPending() end
        end,
    })
    if shown then pending_[config.id] = nil end
    return shown == true
end

TryPending = function()
    local queued = false
    for _, config in ipairs(FaceSlapConfig.CAMPAIGNS) do
        local pendingTrigger = pending_[config.id]
        if pendingTrigger and TryShow(config, pendingTrigger) then queued = true end
    end
    return queued
end

function FaceSlapController.Configure(context)
    context_ = assert(context)
    Load()
    lastDayKey_ = DayKey(ServerClock.Now())
end

function FaceSlapController.Evaluate(trigger)
    if not context_ then return false end
    for _, config in ipairs(FaceSlapConfig.CAMPAIGNS) do
        if HasTrigger(config, trigger) then
            pending_[config.id] = trigger
        end
    end
    return TryPending()
end

function FaceSlapController.RetryPending()
    if not context_ then return false end
    return TryPending()
end

function FaceSlapController.Update(dt)
    if not context_ then return end
    local dayKey = DayKey(ServerClock.Now())
    if lastDayKey_ ~= dayKey then
        lastDayKey_ = dayKey
        FaceSlapController.Evaluate("day_changed")
        return
    end
    evaluationElapsed_ = evaluationElapsed_ + math.max(0, tonumber(dt) or 0)
    if evaluationElapsed_ >= 0.5 then
        evaluationElapsed_ = 0
        TryPending()
    end
end

function FaceSlapController.IsSuppressedToday(id)
    local entry, dayKey = EntryFor(id, ServerClock.Now())
    return entry.suppressedDayKey == dayKey
end

function FaceSlapController.SetSuppressedToday(id, suppressed)
    for _, config in ipairs(FaceSlapConfig.CAMPAIGNS) do
        if config.id == id and config.allowDoNotShowToday then
            local entry, dayKey = EntryFor(id, ServerClock.Now())
            entry.suppressedDayKey = suppressed and dayKey or 0
            if suppressed then pending_[id] = nil end
            Save()
            print(string.format("[FaceSlap] suppression id=%s enabled=%s",
                id, tostring(suppressed == true)))
            return true
        end
    end
    return false
end

function FaceSlapController.SuppressToday(id)
    return FaceSlapController.SetSuppressedToday(id, true)
end

function FaceSlapController.Cancel(id)
    for _, config in ipairs(FaceSlapConfig.CAMPAIGNS) do
        if config.id == id then
            pending_[id] = nil
            return DialogCoordinator.CancelByKey(config.queueKey)
        end
    end
    return false
end

function FaceSlapController.ResetConnection()
    for _, config in ipairs(FaceSlapConfig.CAMPAIGNS) do
        DialogCoordinator.CancelByKey(config.queueKey)
        sessionShows_[config.id] = nil
    end
    pending_ = {}
    evaluationElapsed_ = 0
end

function FaceSlapController.Reset()
    FaceSlapController.ResetConnection()
    sessionShows_ = {}
    lastDayKey_ = nil
    evaluationElapsed_ = 0
    context_ = nil
end

function FaceSlapController._ResetForTests()
    context_ = nil
    loaded_ = false
    localState_ = nil
    sessionShows_ = {}
    pending_ = {}
    lastDayKey_ = nil
    evaluationElapsed_ = 0
end

return FaceSlapController
