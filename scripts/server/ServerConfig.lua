local ServerConfig = {}

ServerConfig.SCHEMA_VERSION = 1
ServerConfig.LOGICAL_MAX_PLAYERS = 1
ServerConfig.STEP_SECONDS = 3
ServerConfig.COMBAT_TICK_SECONDS = 0.10
ServerConfig.OFFLINE_MAX_SECONDS = 12 * 60 * 60
ServerConfig.INVENTORY_CAP = 300
ServerConfig.MAX_PAYLOAD_BYTES = 16 * 1024
ServerConfig.MAX_BATCH_OPERATIONS = 1000
ServerConfig.REQUEST_CACHE_SIZE = 128
ServerConfig.REQUEST_CACHE_TTL_SECONDS = 10 * 60
ServerConfig.ADMIN_AUDIT_LIMIT = 200

ServerConfig.ADMIN_UIDS = {
    [1379670410] = true,
    ["1379670410"] = true,
}

ServerConfig.RATES = {
    ClientReady = { refillRate = 0.2, burst = 2 },
    Snapshot = { refillRate = 0.2, burst = 2 },
    AutoRun = { refillRate = 1, burst = 3 },
    Encounter = { refillRate = 2, burst = 3 },
    Equipment = { refillRate = 2, burst = 4 },
    Progression = { refillRate = 1, burst = 3 },
    PreviewOffline = { refillRate = 1, burst = 2 },
    CollectOffline = { refillRate = 0.1, burst = 1 },
    AdminQuery = { refillRate = 1, burst = 3 },
    AdminMutation = { refillRate = 0.2, burst = 2 },
}

---@param uid number|string|nil
---@return boolean
function ServerConfig.IsAdmin(uid)
    if uid == nil then
        return false
    end
    return ServerConfig.ADMIN_UIDS[uid] == true or ServerConfig.ADMIN_UIDS[tostring(uid)] == true
end

---@return string
function ServerConfig.GetPersistentWorldKey()
    local key = _G["PERSISTENT_WORLD_KEY"]
    if type(key) ~= "string" then
        return ""
    end
    return key
end

---@return boolean
function ServerConfig.IsPreviewEnvironment()
    local key = ServerConfig.GetPersistentWorldKey()
    return key == "" or string.match(key, "^preview") ~= nil or string.match(key, "^dev") ~= nil
end

return ServerConfig
