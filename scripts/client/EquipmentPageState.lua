local Tables = require("shared.TableUtils")
local ItemView = require("client.ItemView")
local M = {}

-- Take a value snapshot: adapter updates may mutate existing item tables.
function M.Detail(game, selectedId)
    game = game or {}
    local selected
    for _, item in ipairs(game.inventory or {}) do
        if item.id == selectedId then selected = item; break end
    end
    local equipped = selected and (game.equipped or {})[selected.slot]
    local equippedId = type(equipped) == "table" and equipped.id or equipped
    return Tables.DeepCopy { item = selected, equippedId = equippedId, level = game.level }
end

function M.Loadout(game, selectedId)
    game = game or {}
    return Tables.DeepCopy {
        detail = M.Detail(game, selectedId), equipped = game.equipped,
        stats = game.stats, displayedPower = game.displayedPower,
        betterSlots = ItemView.BetterUnequippedSlots(game),
        seasonTitle = game.seasonTitle, seasonFrame = game.seasonFrame,
    }
end

M.Equal = Tables.DeepEqual
return M
