local ServerConfig = {}

ServerConfig.SCHEMA_VERSION = 1
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
    [162525390] = true,
    ["162525390"] = true,
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
    DailyClaim = { refillRate = 0.1, burst = 1 },
    -- 许愿池：动画结算 + 服务端冷却兜底，限流需宽松，避免“跳过领取后立即再许愿”被误限
    Wish = { refillRate = 1, burst = 4 },
    AdminQuery = { refillRate = 1, burst = 3 },
    AdminMutation = { refillRate = 0.2, burst = 2 },
    -- 市场：浏览走分片内缓存所以可以稍宽松；写操作会触发云事务，必须收紧。
    MarketBrowse = { refillRate = 2, burst = 5 },
    MarketQuery = { refillRate = 1, burst = 3 },
    MarketMutation = { refillRate = 0.5, burst = 3 },
    -- 排行榜为只读浏览，放宽限流避免正常点选详情被误限
    Leaderboard = { refillRate = 2, burst = 8 },
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
