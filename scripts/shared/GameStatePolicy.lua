local GameStatePolicy = {
    INVENTORY_CAP = 300,
    TEMPORARY_LOOT_CAP = 60,
    LOOT_STASH_CAP = 60,
    OFFLINE_MIN_SECONDS = 15 * 60,      -- 离线不足 15 分钟不产生可领离线收益
    OFFLINE_MAX_SECONDS = 12 * 60 * 60,
    MAX_LOGS = 40,
    MAX_APPLIED_GM_COMMANDS = 64,
    MAX_GM_COMMAND_ID_LENGTH = 96,
}

return GameStatePolicy
