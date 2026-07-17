local GameStateSchema = require("shared.GameStateSchema")

local Spec = {}

function Spec.Run()
    assert(#GameStateSchema.SLOTS == 12)

    local state = GameStateSchema.NewInitialState(100)
    local valid, err = GameStateSchema.ValidateState(state)
    assert(valid, err and err.reason)
    assert(state.level == 21 and state.exp == 464)
    assert(state.pendingOfflineSeconds <= GameStateSchema.OFFLINE_MAX_SECONDS)
    assert(#state.appliedGmCommandIds == 0)

    local item = {
        id = "eq-000001",
        name = "Test Weapon",
        slot = "weapon",
        category = "weapon",
        rarity = "epic",
        level = 21,
        atk = 10,
        def = 0,
        hp = 0,
        crit = 0,
        critDmg = 0,
        atkSpeed = 0,
        enhance = 0,
        star = 0,
        power = 999,
    }
    state.inventory = { item }
    state.equipped = { weapon = item.id }
    state.nextItemId = 2
    state.stats = { power = 999 }
    state.nextExp = GameStateSchema.NextExp(state.level)
    assert(GameStateSchema.ValidateState(state))

    local persisted = GameStateSchema.ToPersistedState(state)
    assert(persisted.stats == nil and persisted.nextExp == nil)
    assert(persisted.inventory[1].power == nil)
    assert(persisted.equipped.weapon == "eq-000001")
    assert(type(persisted.appliedGmCommandIds) == "table")

    local snapshot = GameStateSchema.BuildSnapshot(state, { serverTime = 101, isAdmin = true })
    assert(snapshot.kind == "GameSnapshot")
    assert(snapshot.isAdmin == true)
    assert(snapshot.stats.power == 999)
    assert(snapshot.inventory[1].power == 999)
    assert(snapshot.appliedGmCommandIds == nil)

    local delta = GameStateSchema.BuildDelta(2, { gold = 40000 }, {
        inventoryChanged = true,
        state = state,
        serverTime = 102,
    })
    assert(delta.kind == "GameDelta" and delta.revision == 2)
    assert(delta.inventoryChanged)
    assert(#delta.changes.inventory == 1)
    assert(GameStateSchema.ValidateDelta(delta))

    state.equipped.weapon = "missing"
    local mismatch = GameStateSchema.ValidateState(state)
    assert(not mismatch)
end

return Spec
