-- Run with scripts/?.lua on package.path (plain Lua, no engine required).
local Schema = require("shared.GameStateSchema")
local Catalog = require("server.domain.Catalog")
local StateFactory = require("server.domain.StateFactory")

local state = StateFactory.Create(1791445000)
for _, item in ipairs(state.inventory) do
    item._powerCacheKey = nil
    item._powerCacheValue = nil
end

local function verifySnapshot()
    local snapshot = Schema.BuildSnapshot(state, {
        serverTime = 1791445000,
        playerNickname = "Snapshot regression",
        itemPower = Catalog.GetItemPower,
    })
    -- These presentation fields are appended by ServerMain.SendSnapshot.
    snapshot.logs = {}
    snapshot.recentDamage = "Waiting for combat"
    for index, item in ipairs(snapshot.inventory) do
        assert(item._powerCacheKey == nil, "power cache key leaked into snapshot")
        assert(item._powerCacheValue == nil, "power cache value leaked into snapshot")
        assert(item.power == state.inventory[index]._powerCacheValue,
            "snapshot must retain authoritative item power")
    end
    local valid, err = Schema.ValidateSnapshot(snapshot)
    assert(valid, err and (tostring(err.reason) .. ": " .. tostring(err.details and err.details.path)))
end

verifySnapshot() -- Cold cache: computing power mutates the domain item.
verifySnapshot() -- Warm cache: repeated snapshots remain valid.
print("snapshot_item_power: PASS")
