local Balance = require("shared.GameBalance")
---@class DungeonCatalog
local Dungeon = {}
Dungeon.ORDER = { "gold", "fragments", "tickets" }
---@type string[]
Dungeon.DIFFICULTIES = { "普通", "困难", "噩梦" }
---@type table<string, table>
Dungeon.TYPES = {
    gold = { title = "遗落金库", desc = "三波守卫 · 输出与破甲 · 金币", activityId = "act_daily_gold",
        waves = 3, hp = 700, atk = 55, def = 70, limit = 60, gold = { 25, 60, 110 } },
    fragments = { title = "试炼熔炉", desc = "五波消耗战 · 防御与续航 · 强化碎片", activityId = "act_daily_fragments",
        waves = 5, hp = 520, atk = 105, def = 20, limit = 90, fragments = { 120, 320, 650 } },
    tickets = { title = "裂隙守卫", desc = "限时首领 · 暴击与首领伤害 · 深渊票", activityId = "act_daily_exp",
        waves = 1, hp = 1450, atk = 75, def = 30, limit = 30, tickets = { 120, 360, 720 } },
}

function Dungeon.GetStage(id)
    local kind, tierText = tostring(id or ""):match("^dungeon:([%a]+):([123])$")
    local def = Dungeon.TYPES[kind]
    if not def then return nil end
    local tier = tonumber(tierText) or 1
    ---@type number[]
    local levels = { 5, 50, 100 }
    local level = levels[tier]
    local growth = Balance.TrialGrowth(level)
    ---@type number[]
    local multipliers = { 0.85, 1.05, 1.35 }
    local multiplier = multipliers[tier]
    local gold = def.gold --[[@as number[]?]]
    local fragments = def.fragments --[[@as number[]?]]
    local tickets = def.tickets --[[@as number[]?]]
    ---@type number[]
    local expScenes = { 15, 30, 50 }
    return { id = id, dungeon = kind, difficulty = tier, activityId = def.activityId,
        title = def.title .. " · " .. Dungeon.DIFFICULTIES[tier], desc = def.desc,
        recommendedLevel = level, minLevel = tier == 1 and 1 or level,
        kind = "boss", mechanic = "dungeon", waves = def.waves, timeLimit = def.limit,
        enemy = { name = def.title .. "守卫", hp = def.hp * growth * multiplier,
            atk = def.atk * growth * multiplier, def = def.def * growth },
        reward = { expScenes = expScenes[tier],
            goldScenes = gold and gold[tier] or 0,
            fragments = fragments and fragments[tier] or 0,
            abyssTickets = tickets and tickets[tier] or 0 },
    }
end

---@return table[]
function Dungeon.ForActivity(activityId)
    for _, kind in ipairs(Dungeon.ORDER) do
        if Dungeon.TYPES[kind].activityId == activityId then
            local stages = {}
            for tier = 1, 3 do stages[#stages + 1] = Dungeon.GetStage("dungeon:" .. kind .. ":" .. tier) end
            return stages
        end
    end
    return {}
end

return Dungeon
