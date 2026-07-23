local StateNormalizer = require("server.domain.StateNormalizer")

local StateFactory = {}

function StateFactory.Create(now)
    now = math.max(0, math.floor(now or os.time()))
    return StateNormalizer.Normalize({
        revision = 0,
        updatedAt = now,
        lastActiveAt = now,
        pendingOfflineSeconds = 0,
        level = 1,
        exp = 0,
        floor = 1,
        maxFloor = 1,
        position = 0,
        autoRun = false,
        floorKillBonus = 0,
        permanentBonus = 0,
        nextItemId = 1,
        inventory = {},
        equipped = {},
        consumables = { healthPotion = 0 },
        appliedGmCommandIds = {},
    }, now)
end

StateFactory.CreateInitialState = StateFactory.Create

return StateFactory
