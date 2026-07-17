local AdmissionGuard = require("server.core.AdmissionGuard")
local ErrorCodes = require("shared.ErrorCodes")
local PlayerRegistry = require("server.core.PlayerRegistry")

local Spec = {}

function Spec.Run()
    local registry = PlayerRegistry.New()
    local guard = AdmissionGuard.New({
        registry = registry,
        maxPlayers = 1,
        isAdmin = function(uid) return uid == 99 end,
        isBanned = function(uid) return uid == 666, "test ban" end,
    })

    local firstConnection = {}
    registry:OnConnected(firstConnection)
    local first = guard:Admit(firstConnection, 1, "first")
    assert(first and not first.isAdmin)

    local secondConnection = {}
    registry:OnConnected(secondConnection)
    local _, _, fullError = guard:Admit(secondConnection, 2, "second")
    assert(fullError.code == ErrorCodes.CAPACITY_REACHED)

    local replacementConnection = {}
    registry:OnConnected(replacementConnection)
    local replacement, replaced = guard:Admit(replacementConnection, 1, "replacement")
    assert(replacement and replaced == first)

    local adminConnection = {}
    registry:OnConnected(adminConnection)
    local admin = guard:Admit(adminConnection, 99, "admin")
    assert(admin and admin.isAdmin)

    local bannedConnection = {}
    registry:OnConnected(bannedConnection)
    local _, _, bannedError = guard:Admit(bannedConnection, 666, "banned")
    assert(bannedError.code == ErrorCodes.BANNED)

    local occupancy = guard:GetOccupancy()
    assert(occupancy.ordinary == 1 and occupancy.admins == 1)

    local _, oldWasCurrent = guard:Release(firstConnection)
    assert(not oldWasCurrent)
    assert(registry:Get(1) == replacement)
end

return Spec
