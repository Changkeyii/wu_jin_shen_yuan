local RarityCatalog = {}

RarityCatalog.VERSION = 1
RarityCatalog.ORDER = {
    "common", "advanced", "rare", "artifact", "legendary", "epic", "myth",
}

local ENTRIES = {
    common = {
        id = "common", name = "普通", rank = 1, unlockFloor = 1,
        multiplier = 0.90, beam = "white", color = "#F3F4F6", fragments = 1,
    },
    advanced = {
        id = "advanced", name = "高级", rank = 2, unlockFloor = 1,
        multiplier = 0.95, beam = "blue", color = "#38BDF8", fragments = 2,
    },
    rare = {
        id = "rare", name = "稀有", rank = 3, unlockFloor = 1,
        multiplier = 1.00, beam = "purple", color = "#A855F7", fragments = 5,
    },
    artifact = {
        id = "artifact", name = "神器", rank = 4, unlockFloor = 10,
        multiplier = 1.07, beam = "pink", color = "#F472B6", fragments = 10,
        coreAffixCount = 1,
    },
    legendary = {
        id = "legendary", name = "传说", rank = 5, unlockFloor = 30,
        multiplier = 1.15, beam = "crimson", color = "#EF4444", fragments = 18,
        coreAffixCount = 2,
    },
    epic = {
        id = "epic", name = "史诗", rank = 6, unlockFloor = 50,
        multiplier = 1.25, beam = "orange_gold", color = "#F59E0B", fragments = 36,
        enablesSets = true,
    },
    myth = {
        id = "myth", name = "神话", rank = 7, unlockFloor = 100,
        multiplier = 1.40, beam = "rainbow", color = "#F8FAFC", fragments = 100,
        enablesSets = true, uniqueEffect = true, dynamicBeam = true,
    },
}

local LEGACY_IDS = {
    blue = "advanced",
    purple = "rare",
    legend = "legendary",
    mythic = "myth",
}

function RarityCatalog.NormalizeId(rarityId)
    if type(rarityId) ~= "string" then return "common" end
    rarityId = LEGACY_IDS[rarityId] or rarityId
    return ENTRIES[rarityId] and rarityId or "common"
end

function RarityCatalog.Get(rarityId)
    return ENTRIES[RarityCatalog.NormalizeId(rarityId)]
end

function RarityCatalog.Rank(rarityId)
    return RarityCatalog.Get(rarityId).rank
end

function RarityCatalog.IsUnlocked(rarityId, floor)
    return RarityCatalog.Get(rarityId).unlockFloor <= math.max(1, math.floor(floor or 1))
end

function RarityCatalog.HighestUnlocked(floor)
    floor = math.max(1, math.floor(floor or 1))
    local result = ENTRIES.common
    for _, rarityId in ipairs(RarityCatalog.ORDER) do
        local entry = ENTRIES[rarityId]
        if entry.unlockFloor <= floor then result = entry else break end
    end
    return result
end

function RarityCatalog.GetAll()
    local result = {}
    for _, rarityId in ipairs(RarityCatalog.ORDER) do result[#result + 1] = ENTRIES[rarityId] end
    return result
end

RarityCatalog.ENTRIES = ENTRIES
return RarityCatalog
