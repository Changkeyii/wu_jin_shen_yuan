local RarityCatalog = require("shared.RarityCatalog")

local GameStateContracts = {}

GameStateContracts.VERSION = 6
GameStateContracts.SLOTS = {
    "weapon", "shoulder", "coat", "pants", "belt", "shoes",
    "bracelet", "necklace", "ring", "support", "magicstone", "earring",
}
GameStateContracts.RARITIES = RarityCatalog.ORDER
GameStateContracts.SET_IDS = { "nightmare", "lucky", "voyage", "abyss", "prophecy" }
GameStateContracts.EVENT_TYPES = {
    "monster", "elite", "chest", "merchant", "random", "boss", "chapter_boss",
}

GameStateContracts.PERSISTED_FIELDS = {
    "schemaVersion",
    "revision",
    "updatedAt",
    "lastActiveAt",
    "pendingOfflineSeconds",
    "level",
    "vipLevel",
    "dailyVip",
    "exp",
    "floor",
    "maxFloor",
    "position",
    "transitionRemaining",
    "attemptId",
    "floorDefeats",
    "aidPending",
    "aidGrantedFloors",
    "gold",
    "fragments",
    "autoRun",
    "pauseReason",
    "nextItemId",
    "inventory",
    "overflowLoot",
    "lootStash",
    "equipped",
    "consumables",
    "hp",
    "hpBig",
    "floorKillBonus",
    "permanentBonus",
    "inventoryPolicy",
    "automationPolicy",
    "interactionMode",
    "rewardPity",
    "storyProgress",
    "pendingStoryGate",
    "pendingEvent",
    "ruleAcknowledgements",
    "pendingEquipDecision",
    "previousLoadout",
    "currentMonster",
    "equipmentCollection",
    "marketListings",
    "appliedGmCommandIds",
}

GameStateContracts.SNAPSHOT_FIELDS = {
    "level",
    "vipLevel",
    "dailyVip",
    "exp",
    "floor",
    "maxFloor",
    "position",
    "transitionRemaining",
    "attemptId",
    "floorDefeats",
    "aidPending",
    "gold",
    "fragments",
    "autoRun",
    "pauseReason",
    "pendingOfflineSeconds",
    "inventory",
    "overflowLoot",
    "lootStash",
    "equipped",
    "consumables",
    "hp",
    "hpBig",
    "floorKillBonus",
    "permanentBonus",
    "inventoryPolicy",
    "automationPolicy",
    "interactionMode",
    "rewardPity",
    "storyProgress",
    "pendingStoryGate",
    "pendingEvent",
    "ruleAcknowledgements",
    "pendingEquipDecision",
    "previousLoadout",
    "currentMonster",
    "equipmentCollection",
    "marketListings",
    "floorRoute",
    "setProgress",
    "logs",
    "currentEvent",
    "recentDamage",
    "stats",
    "nextExp",
    "displayedPower",
    "recommendedPower",
    "nextChapterRecommendedPower",
    "powerRatio",
    "headroomFloors",
    "difficultyLabel",
    "bossScore",
    "eliteScore",
    "estimatedEasyFloor",
}

GameStateContracts.DELTA_FIELD_SET = {}
for _, fieldName in ipairs(GameStateContracts.SNAPSHOT_FIELDS) do
    GameStateContracts.DELTA_FIELD_SET[fieldName] = true
end

GameStateContracts.SNAPSHOT_FIELD_SET = {
    kind = true,
    schemaVersion = true,
    revision = true,
    updatedAt = true,
    serverTime = true,
    status = true,
    isAdmin = true,
    playerNickname = true,
    inventoryCapacity = true,
}
for _, fieldName in ipairs(GameStateContracts.SNAPSHOT_FIELDS) do
    GameStateContracts.SNAPSHOT_FIELD_SET[fieldName] = true
end

GameStateContracts.DELTA_ENVELOPE_FIELD_SET = {
    kind = true,
    schemaVersion = true,
    revision = true,
    serverTime = true,
    updatedAt = true,
    inventoryChanged = true,
    changes = true,
    events = true,
    eventKind = true,
}


return GameStateContracts
