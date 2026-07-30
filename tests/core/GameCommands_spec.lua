local CommandRouter = require("server.core.CommandRouter")
local GameCommands = require("server.commands.GameCommands")
local NetworkProtocol = require("shared.NetworkProtocol")

local Spec = {}

function Spec.Run()
    local definitions = {}
    local router = {
        Register = function(_, definition)
            definitions[definition.name] = definition
        end,
    }
    local hugeInventory = {}
    for index = 1, 400 do
        hugeInventory[index] = {
            id = "item-" .. tostring(index),
            name = string.rep("大型装备数据", 30),
        }
    end
    local delta = {
        revision = 42,
        changes = { lootStash = { "item-1", "item-2" } },
        events = {},
    }
    local sentDelta = nil
    local services = {
        profileService = {
            Apply = function(_, uid, operationName, mutator, callback)
                assert(uid == 7)
                assert(operationName == "set auto run")
                assert(type(mutator) == "function")
                callback({
                    ok = true,
                    data = {
                        committed = true,
                        state = { revision = 42, inventory = hugeInventory },
                        delta = delta,
                    },
                })
            end,
        },
        sendDelta = function(uid, value)
            assert(uid == 7)
            sentDelta = value
        end,
    }

    GameCommands.Register(router, services)
    local definition = assert(definitions["Game.SetAutoRun"])
    local responseOk = nil
    local response = nil
    local result = definition.handler({ uid = 7 }, { enabled = true }, function(ok, value)
        responseOk = ok
        response = value
    end)

    assert(result == CommandRouter.PENDING)
    assert(responseOk == true and response.ok == true)
    assert(sentDelta == delta, "authoritative delta must use the separate delta event")
    assert(response.data.revision == 42)
    assert(response.data.committed == true)
    assert(response.data.state == nil, "mutation responses must never include the full profile state")
    assert(response.data.delta == nil, "mutation responses must never duplicate the delta payload")

    local ok, cjson = pcall(require, "cjson")
    if ok and cjson then
        local encoded = cjson.encode(response)
        assert(#encoded < NetworkProtocol.MAX_SERVER_PAYLOAD_BYTES)
    end
end

return Spec
