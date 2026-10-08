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
                assert(type(mutator) == "function")
                if operationName == "decompose equipment" then
                    callback({
                        ok = true,
                        data = {
                            committed = true,
                            state = { revision = 43 },
                            delta = {
                                revision = 43,
                                changes = {},
                                events = {{
                                    kind = "equipment_decomposed",
                                    gold = 12345,
                                    fragments = 678,
                                    count = 9,
                                }},
                            },
                        },
                    })
                    return
                end
                if operationName == "claim daily VIP ad" then
                    local proposal = mutator({
                        schemaVersion = 6,
                        revision = 1,
                        updatedAt = 0,
                        vipLevel = 0,
                        dailyVip = { signInDay = 0, adDay = 0 },
                    }, 1720000000)
                    assert(proposal.ok == true)
                    assert(proposal.state.vipLevel == 1)
                    assert(proposal.delta.events[1].source == "ad")
                    callback({
                        ok = true,
                        data = {
                            committed = true,
                            state = proposal.state,
                            delta = proposal.delta,
                        },
                    })
                    return
                end
                assert(operationName == "set auto run")
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

    local dailyAdDefinition = assert(definitions["Game.ClaimDailyAdVip"])
    assert(dailyAdDefinition.async == true)
    local dailyAdResponse = nil
    local dailyAdResult = dailyAdDefinition.handler({ uid = 7 }, {}, function(okValue, value)
        assert(okValue == true)
        dailyAdResponse = value
    end)
    assert(dailyAdResult == CommandRouter.PENDING)
    assert(dailyAdResponse.data.revision == 2)
    assert(dailyAdResponse.data.state == nil)
    assert(dailyAdResponse.data.delta == nil)

    local decomposeDefinition = assert(definitions["Game.Decompose"])
    local decomposeResponse = nil
    local decomposeResult = decomposeDefinition.handler(
        { uid = 7 },
        { maxRank = 3, candidateIds = { "00000000-0000-4000-8000-000000000001" } },
        function(okValue, value)
            assert(okValue == true)
            decomposeResponse = value
        end
    )
    assert(decomposeResult == CommandRouter.PENDING)
    assert(decomposeResponse.data.revision == 43)
    assert(decomposeResponse.data.reward.gold == 12345)
    assert(decomposeResponse.data.reward.fragments == 678)
    assert(decomposeResponse.data.reward.count == 9)
    assert(decomposeResponse.data.state == nil)
    assert(decomposeResponse.data.delta == nil)

    local ok, cjson = pcall(require, "cjson")
    if ok and cjson then
        local encoded = cjson.encode(response)
        assert(#encoded < NetworkProtocol.MAX_SERVER_PAYLOAD_BYTES)
    end
end

return Spec
