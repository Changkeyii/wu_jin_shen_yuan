local PlayerRegistry = {}
PlayerRegistry.__index = PlayerRegistry

local function defaultClock()
    local timeObject = _G["time"]
    if timeObject and type(timeObject.GetElapsedTime) == "function" then
        local ok, value = pcall(timeObject.GetElapsedTime, timeObject)
        if ok and type(value) == "number" then
            return value
        end
    end
    return os.clock()
end

local function defaultConnectionKey(connection)
    return tostring(connection)
end

local function uidKey(uid)
    return tostring(uid)
end

---@param options table|nil
---@return table
function PlayerRegistry.New(options)
    options = options or {}
    return setmetatable({
        _clock = options.clock or defaultClock,
        _connectionKey = options.connectionKey or defaultConnectionKey,
        _byUid = {},
        _byConnection = {},
        _byConnectionKey = {},
        _generationByUid = {},
    }, PlayerRegistry)
end

---@param connection any
---@return table
function PlayerRegistry:OnConnected(connection)
    assert(connection ~= nil, "connection is required")
    local connectionKey = self._connectionKey(connection) or tostring(connection)
    local existing = self._byConnection[connection] or self._byConnectionKey[connectionKey]
    if existing ~= nil then
        self._byConnection[connection] = existing
        existing.connectionAliases[connection] = true
        return existing
    end
    local now = self._clock()
    local entry = {
        connection = connection,
        connectionKey = connectionKey,
        connectionAliases = { [connection] = true },
        uid = nil,
        generation = 0,
        connectedAt = now,
        authenticatedAt = nil,
        disconnectedAt = nil,
        authenticated = false,
        ready = false,
        superseded = false,
        isAdmin = false,
        metadata = {},
    }
    self._byConnection[connection] = entry
    self._byConnectionKey[connectionKey] = entry
    return entry
end

---@param connection any
---@param uid number|string
---@param nickname string|nil
---@param attributes table|nil
---@return table
---@return table|nil
---@return boolean
function PlayerRegistry:OnAuthenticated(connection, uid, nickname, attributes)
    assert(connection ~= nil, "connection is required")
    assert(uid ~= nil, "uid is required")

    local key = uidKey(uid)
    local entry = self:GetByConnection(connection) or self:OnConnected(connection)
    if entry.authenticated and entry.uid ~= nil and uidKey(entry.uid) == key and self._byUid[key] == entry then
        return entry, nil, false
    end

    if entry.uid ~= nil then
        local oldKey = uidKey(entry.uid)
        if self._byUid[oldKey] == entry then
            self._byUid[oldKey] = nil
        end
    end

    local replaced = self._byUid[key]
    if replaced ~= nil and replaced ~= entry then
        replaced.superseded = true
        replaced.authenticated = false
        replaced.ready = false
    else
        replaced = nil
    end

    local generation = (self._generationByUid[key] or 0) + 1
    self._generationByUid[key] = generation

    entry.uid = uid
    entry.generation = generation
    entry.nickname = nickname or ("player_" .. key)
    entry.authenticatedAt = self._clock()
    entry.authenticated = true
    entry.ready = false
    entry.superseded = false
    entry.metadata = entry.metadata or {}
    if type(attributes) == "table" then
        for name, value in pairs(attributes) do
            entry[name] = value
        end
    end

    self._byUid[key] = entry
    return entry, replaced, replaced ~= nil
end

---@param connection any
---@return table|nil
---@return boolean
function PlayerRegistry:OnDisconnected(connection)
    local entry = self:GetByConnection(connection)
    if entry == nil then
        return nil, false
    end

    for alias in pairs(entry.connectionAliases) do
        self._byConnection[alias] = nil
    end
    entry.connectionAliases = {}
    if self._byConnectionKey[entry.connectionKey] == entry then
        self._byConnectionKey[entry.connectionKey] = nil
    end
    entry.disconnectedAt = self._clock()
    entry.ready = false
    entry.authenticated = false

    local wasCurrent = false
    if entry.uid ~= nil then
        local key = uidKey(entry.uid)
        if self._byUid[key] == entry then
            self._byUid[key] = nil
            wasCurrent = true
        end
    end
    return entry, wasCurrent
end

---@param connection any
---@param ready boolean|nil
---@return boolean
function PlayerRegistry:MarkReady(connection, ready)
    local entry = self:GetByConnection(connection)
    if entry == nil or not self:IsCurrent(entry) or not entry.authenticated then
        return false
    end
    entry.ready = ready ~= false
    entry.readyAt = entry.ready and self._clock() or nil
    return true
end

---@param uid number|string
---@return table|nil
function PlayerRegistry:Get(uid)
    if uid == nil then
        return nil
    end
    return self._byUid[uidKey(uid)]
end

---@param connection any
---@return table|nil
function PlayerRegistry:GetByConnection(connection)
    if connection == nil then
        return nil
    end
    local direct = self._byConnection[connection]
    if direct ~= nil then
        return direct
    end
    local ok, connectionKey = pcall(self._connectionKey, connection)
    if not ok or connectionKey == nil then
        return nil
    end
    return self._byConnectionKey[connectionKey]
end

---@param connection any
---@return number|string|nil
function PlayerRegistry:GetUid(connection)
    local entry = self:GetByConnection(connection)
    if entry == nil or not self:IsCurrent(entry) then
        return nil
    end
    return entry.uid
end

---@param entryOrConnection any
---@return boolean
function PlayerRegistry:IsCurrent(entryOrConnection)
    local entry = entryOrConnection
    if type(entryOrConnection) ~= "table"
        or entryOrConnection.connection == nil
        or entryOrConnection.generation == nil
    then
        local connectionEntry = self:GetByConnection(entryOrConnection)
        if connectionEntry ~= nil then
            entry = connectionEntry
        end
    end
    if type(entry) ~= "table" or entry.uid == nil then
        return false
    end
    return self._byUid[uidKey(entry.uid)] == entry
        and self._generationByUid[uidKey(entry.uid)] == entry.generation
        and not entry.superseded
end

---@param connection any
---@return boolean
function PlayerRegistry:IsAuthenticated(connection)
    local entry = self:GetByConnection(connection)
    return entry ~= nil and entry.authenticated == true and self:IsCurrent(entry)
end

---@param uid number|string
---@return number
function PlayerRegistry:GetGeneration(uid)
    return self._generationByUid[uidKey(uid)] or 0
end

---@return table[]
function PlayerRegistry:All()
    local result = {}
    for _, entry in pairs(self._byUid) do
        if entry.authenticated and self:IsCurrent(entry) then
            result[#result + 1] = entry
        end
    end
    table.sort(result, function(left, right)
        return uidKey(left.uid) < uidKey(right.uid)
    end)
    return result
end

---@param predicate function|nil
---@return number
function PlayerRegistry:Count(predicate)
    local count = 0
    for _, entry in ipairs(self:All()) do
        if predicate == nil or predicate(entry) then
            count = count + 1
        end
    end
    return count
end

---@param uid number|string
---@param eventName string
---@param eventData any
---@return boolean
function PlayerRegistry:Send(uid, eventName, eventData)
    local entry = self:Get(uid)
    if entry == nil or not entry.ready or not self:IsCurrent(entry) then
        return false
    end
    local ok = pcall(function()
        entry.connection:SendRemoteEvent(eventName, true, eventData)
    end)
    return ok
end

---@param uid number|string
---@param name string
---@param value any
---@return boolean
function PlayerRegistry:SetMetadata(uid, name, value)
    local entry = self:Get(uid)
    if entry == nil then
        return false
    end
    entry.metadata[name] = value
    return true
end

---@param uid number|string
---@param name string
---@return any
function PlayerRegistry:GetMetadata(uid, name)
    local entry = self:Get(uid)
    return entry and entry.metadata[name] or nil
end

function PlayerRegistry:Reset()
    self._byUid = {}
    self._byConnection = {}
    self._byConnectionKey = {}
    self._generationByUid = {}
end

local defaultRegistry = PlayerRegistry.New()
local Module = {
    New = PlayerRegistry.New,
    Class = PlayerRegistry,
    Default = defaultRegistry,
}

for _, methodName in ipairs({
    "OnConnected",
    "OnAuthenticated",
    "OnDisconnected",
    "MarkReady",
    "Get",
    "GetByConnection",
    "GetUid",
    "IsCurrent",
    "IsAuthenticated",
    "GetGeneration",
    "All",
    "Count",
    "Send",
    "SetMetadata",
    "GetMetadata",
    "Reset",
}) do
    Module[methodName] = function(...)
        return defaultRegistry[methodName](defaultRegistry, ...)
    end
end

return Module
