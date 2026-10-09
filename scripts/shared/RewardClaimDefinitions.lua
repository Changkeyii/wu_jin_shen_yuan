local RewardClaimDefinitions = {}

RewardClaimDefinitions.VERSION = 2
-- Reserve one entitlement per campaign stage without merging it with old offers.
RewardClaimDefinitions.MAX_OTHER_PENDING = 50
RewardClaimDefinitions.MAX_PENDING = 170 -- 120 campaign stages + the existing 50 other offers
RewardClaimDefinitions.MAX_REWARD_AMOUNT = 1000000000000
RewardClaimDefinitions.AD_MULTIPLIER = 5
RewardClaimDefinitions.AD_EXTRA_MULTIPLIER = 4
RewardClaimDefinitions.SOURCES = {
    signin = true,
    level_milestone = true,
    floor_milestone = true,
    abyss_settlement = true,
    task = true,
    campaign = true,
}

RewardClaimDefinitions.LEVEL_MILESTONES = {
    [5] = { abyssTickets = 30, fragments = 20 },
    [10] = { abyssTickets = 40, fragments = 40 },
    [20] = { abyssTickets = 60, fragments = 80 },
    [30] = { abyssTickets = 80, fragments = 120 },
    [40] = { abyssTickets = 100, fragments = 160 },
    [50] = { abyssTickets = 120, fragments = 200 },
    [60] = { abyssTickets = 140, fragments = 240 },
    [70] = { abyssTickets = 160, fragments = 280 },
    [80] = { abyssTickets = 180, fragments = 320 },
    [90] = { abyssTickets = 200, fragments = 360 },
    [100] = { abyssTickets = 220, fragments = 400 },
}

function RewardClaimDefinitions.LevelMilestoneReward(level)
    level = math.max(1, math.floor(tonumber(level) or 1))
    if level == 5 then
        return RewardClaimDefinitions.LEVEL_MILESTONES[5]
    end
    if level % 10 ~= 0 then return nil end
    return RewardClaimDefinitions.LEVEL_MILESTONES[level] or {
        abyssTickets = 20 + level * 2,
        fragments = level * 4,
    }
end

RewardClaimDefinitions.EXCLUSIVE_LEVEL_GIFTS = {
    [20] = { abyssTickets = 60, fragments = 60 },
    [40] = { abyssTickets = 80, fragments = 100 },
    [60] = { abyssTickets = 100, fragments = 160 },
    [80] = { abyssTickets = 120, fragments = 240 },
}

function RewardClaimDefinitions.FloorMilestoneReward(floor)
    floor = math.max(0, math.floor(tonumber(floor) or 0))
    if floor <= 0 or floor % 10 ~= 0 then return nil end
    return {
        abyssTickets = 30 + floor,
        fragments = floor * 2,
    }
end

function RewardClaimDefinitions.NewState()
    return {
        nextId = 1,
        pending = {},
        receipts = {},
        gifts = require("shared.AdGiftDefinitions").Normalize(nil),
        exclusive = {
            dailyDayKey = 0,
            dailyClaimed = 0,
            weeklyWeekKey = 0,
            weeklyClaimed = false,
            levelClaimed = {},
        },
    }
end

function RewardClaimDefinitions.IsKnownSource(source)
    return RewardClaimDefinitions.SOURCES[source] == true
end

return RewardClaimDefinitions
