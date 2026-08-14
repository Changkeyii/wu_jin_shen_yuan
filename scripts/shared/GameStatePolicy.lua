local GameStatePolicy = {
    -- 基础背包格数（不含广告扩容）。
    INVENTORY_CAP = 300,
    -- 校验/数组硬上限：基础 + 广告扩容最大值
    INVENTORY_HARD_CAP = 1000,
    -- 看广告扩容：每次 +50，最多再扩 700（总上限 1000）。
    -- 50/次比 100/次更稳：单日 5 次广告最多 +250，避免一次广告给过多，也利于广告节奏。
    INVENTORY_EXPAND_PER_AD = 50,
    INVENTORY_EXPAND_MAX_BONUS = 700,
    INVENTORY_EXPAND_AD_PER_DAY = 5,
    TEMPORARY_LOOT_CAP = 120,
    LOOT_STASH_CAP = 120,
    OFFLINE_MIN_SECONDS = 15 * 60,      -- 离线不足 15 分钟不产生可领离线收益
    OFFLINE_MAX_SECONDS = 12 * 60 * 60,
    MAX_LOGS = 40,
    MAX_APPLIED_GM_COMMANDS = 64,
    MAX_GM_COMMAND_ID_LENGTH = 96,
}

return GameStatePolicy
