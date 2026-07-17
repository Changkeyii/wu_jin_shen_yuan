local PlayerRegistry = require("server.core.PlayerRegistry")

local Spec = {}

function Spec.Run()
    local now = 1
    local registry = PlayerRegistry.New({
        clock = function() return now end,
        connectionKey = function(connection) return connection.key end,
    })
    local oldConnection = { key = "old" }
    local oldConnectionAlias = { key = "old" }
    local newConnection = { key = "new" }

    registry:OnConnected(oldConnection)
    local oldEntry = registry:OnAuthenticated(oldConnection, 42, "old")
    assert(oldEntry.generation == 1)
    assert(registry:IsAuthenticated(oldConnection))
    assert(registry:OnConnected(oldConnectionAlias) == oldEntry)
    assert(registry:GetUid(oldConnectionAlias) == 42)

    now = 2
    registry:OnConnected(newConnection)
    local newEntry, replaced, wasReplacement = registry:OnAuthenticated(newConnection, 42, "new")
    assert(wasReplacement and replaced == oldEntry)
    assert(newEntry.generation == 2)
    assert(not registry:IsCurrent(oldEntry))
    assert(registry:IsCurrent(newEntry))
    assert(registry:Get(42) == newEntry)

    local disconnected, wasCurrent = registry:OnDisconnected(oldConnection)
    assert(disconnected == oldEntry and not wasCurrent)
    assert(registry:Get(42) == newEntry)

    assert(registry:MarkReady(newConnection))
    assert(newEntry.ready)
    local _, removedCurrent = registry:OnDisconnected(newConnection)
    assert(removedCurrent)
    assert(registry:Get(42) == nil)
end

return Spec
