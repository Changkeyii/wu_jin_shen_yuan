local FaceSlapConfig = {}

FaceSlapConfig.CAMPAIGNS = {
    {
        id = "offline_claim_login",
        queueKey = "offline_login_guide",
        kind = "offline_claim",
        triggers = { "snapshot" },
        priority = 1200,
        maxShowsPerDay = 0,
        maxShowsPerSession = 1,
        cooldownSeconds = 0,
        oncePerAccount = false,
        allowDoNotShowToday = false,
        eligibilityKey = "offline_claim_available",
        requires = {
            connectionReady = true,
            page = "home",
        },
    },
    {
        id = "loot_stash_login",
        queueKey = "loot_stash_login_guide",
        kind = "loot_stash",
        triggers = { "snapshot" },
        priority = 1000,
        maxShowsPerDay = 0,
        maxShowsPerSession = 1,
        cooldownSeconds = 0,
        oncePerAccount = false,
        allowDoNotShowToday = false,
        eligibilityKey = "loot_stash_available",
        requires = {
            connectionReady = true,
            page = "home",
        },
    },
    {
        id = "daily_vip_reminder",
        queueKey = "face_slap:daily_vip_reminder",
        kind = "daily_vip",
        triggers = { "snapshot", "day_changed" },
        priority = 250,
        maxShowsPerDay = 1,
        maxShowsPerSession = 1,
        cooldownSeconds = 0,
        oncePerAccount = false,
        allowDoNotShowToday = true,
        eligibilityKey = "daily_vip_available",
        requires = {
            connectionReady = true,
            page = "home",
        },
    },
}

return FaceSlapConfig
