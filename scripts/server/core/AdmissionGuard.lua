local ErrorCodes = require("shared.ErrorCodes")
local PlayerRegistryModule = require("server.core.PlayerRegistry")

local AdmissionGuard = {}
AdmissionGuard.__index = AdmissionGuard

---@param options table|nil
---@return table
function AdmissionGuard.New(options)
    options = options or {}
    return setmetatable({
        _registry = options.registry or PlayerRegistryModule.Default,
        _maxPlayers = math.max(1, math.floor(options.maxPlayers or 1)),
        _isAdmin = options.isAdmin or function() return false end,
        _isBanned = options.isBanned or function() return false end,
        _bypassAdmins = options.bypassAdmins ~= false,
    }, AdmissionGuard)
end

---@param uid number|string
---@param options table|nil
---@return boolean
---@return table|nil
---@return table|nil
function AdmissionGuard:CanAdmit(uid, options)
    options = options or {}
    if uid == nil then
        return false, ErrorCodes.Make(ErrorCodes.UNAUTHENTICATED), nil
    end

    local banned, banReason = self._isBanned(uid)
    if banned then
        return false, ErrorCodes.Make(ErrorCodes.BANNED, banReason), nil
    end

    local existing = self._registry:Get(uid)
    if existing ~= nil then
        return true, nil, existing
    end

    local isAdmin = options.isAdmin == true or self._isAdmin(uid) == true
    if isAdmin and self._bypassAdmins then
        return true, nil, nil
    end

    local ordinaryCount = self._registry:Count(function(entry)
        return entry.isAdmin ~= true
    end)
    if ordinaryCount >= self._maxPlayers then
        return false, ErrorCodes.Make(ErrorCodes.CAPACITY_REACHED), nil
    end
    return true, nil, nil
end

---@param connection any
---@param uid number|string
---@param nickname string|nil
---@param options table|nil
---@return table|nil
---@return table|nil
---@return table|nil
function AdmissionGuard:Admit(connection, uid, nickname, options)
    options = options or {}
    local allowed, err = self:CanAdmit(uid, options)
    if not allowed then
        return nil, nil, err
    end

    local isAdmin = options.isAdmin == true or self._isAdmin(uid) == true
    local attributes = {}
    if type(options.attributes) == "table" then
        for name, value in pairs(options.attributes) do
            attributes[name] = value
        end
    end
    attributes.isAdmin = isAdmin

    local entry, replaced = self._registry:OnAuthenticated(connection, uid, nickname, attributes)
    return entry, replaced, nil
end

---@param connection any
---@return table|nil
---@return boolean
function AdmissionGuard:Release(connection)
    return self._registry:OnDisconnected(connection)
end

---@return table
function AdmissionGuard:GetOccupancy()
    local ordinary = self._registry:Count(function(entry)
        return entry.isAdmin ~= true
    end)
    local admins = self._registry:Count(function(entry)
        return entry.isAdmin == true
    end)
    return {
        ordinary = ordinary,
        admins = admins,
        maxOrdinary = self._maxPlayers,
    }
end

local defaultGuard = AdmissionGuard.New()
local Module = {
    New = AdmissionGuard.New,
    Class = AdmissionGuard,
    Default = defaultGuard,
}

for _, methodName in ipairs({ "CanAdmit", "Admit", "Release", "GetOccupancy" }) do
    Module[methodName] = function(...)
        return defaultGuard[methodName](defaultGuard, ...)
    end
end

return Module
