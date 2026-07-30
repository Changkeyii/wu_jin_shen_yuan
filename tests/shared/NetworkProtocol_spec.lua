local ErrorCodes = require("shared.ErrorCodes")
local Protocol = require("shared.NetworkProtocol")

local Spec = {}

local function contains(values, expected)
    for _, value in ipairs(values) do
        if value == expected then return true end
    end
    return false
end

function Spec.Run()
    local serverEvents = {}
    Protocol.RegisterServerEvents({
        RegisterRemoteEvent = function(_, name)
            serverEvents[#serverEvents + 1] = name
        end,
    })
    assert(#serverEvents == 2)
    assert(contains(serverEvents, Protocol.EVENTS.CLIENT_READY))
    assert(contains(serverEvents, Protocol.EVENTS.COMMAND))
    assert(not contains(serverEvents, Protocol.EVENTS.RESPONSE))

    local clientEvents = {}
    Protocol.RegisterClientEvents({
        RegisterRemoteEvent = function(_, name)
            clientEvents[#clientEvents + 1] = name
        end,
    })
    assert(#clientEvents == 4)
    assert(contains(clientEvents, Protocol.EVENTS.RESPONSE))
    assert(not contains(clientEvents, Protocol.EVENTS.COMMAND))

    local valid, request = Protocol.ValidateRequest({
        RequestId = "req-1",
        Command = "Equip",
        PayloadJson = "{}",
    })
    assert(valid and request.requestId == "req-1" and request.command == "Equip")

    local tooLarge, _, tooLargeError = Protocol.ValidateRequest({
        RequestId = "req-2",
        Command = "Equip",
        PayloadJson = string.rep("x", Protocol.MAX_PAYLOAD_BYTES + 1),
    })
    assert(not tooLarge)
    assert(tooLargeError.code == ErrorCodes.PAYLOAD_TOO_LARGE)

    local schema = {
        type = "object",
        allowUnknown = false,
        required = { "mode", "amount", "reason" },
        fields = {
            mode = { type = "string", enum = { "gold", "equipment" } },
            amount = { type = "integer", min = 1, max = 10 },
            reason = { type = "string", maxLength = 8 },
        },
    }
    assert(Protocol.ValidatePayload({ mode = "gold", amount = 5, reason = "test" }, schema))
    assert(not Protocol.ValidatePayload({ mode = "gold", amount = 11, reason = "test" }, schema))
    assert(not Protocol.ValidatePayload({ mode = "other", amount = 1, reason = "test" }, schema))
    assert(not Protocol.ValidatePayload({ mode = "gold", amount = 1, reason = "too-long!" }, schema))
    assert(not Protocol.ValidatePayload({ mode = "gold", amount = 1, reason = "test", uid = 9 }, schema))

    local envelope = assert(Protocol.MakeEnvelope("req-3", "Equip", { ok = true }, function()
        return "{encoded}"
    end))
    local oldVariantMap = _G.VariantMap
    local oldVariant = _G.Variant
    _G.VariantMap = nil
    _G.Variant = nil
    local eventData = Protocol.ToVariantMap(envelope)
    assert(eventData[Protocol.FIELDS.REQUEST_ID] == "req-3")
    assert(eventData[Protocol.FIELDS.COMMAND] == "Equip")
    assert(eventData[Protocol.FIELDS.PAYLOAD_JSON] == "{encoded}")

    _G.VariantMap = setmetatable({}, { __call = function() return {} end })
    _G.Variant = setmetatable({}, { __call = function(_, value) return { value = value } end })
    local engineEventData = Protocol.ToVariantMap(envelope)
    assert(engineEventData[Protocol.FIELDS.REQUEST_ID].value == "req-3")
    assert(engineEventData[Protocol.FIELDS.PAYLOAD_JSON].value == "{encoded}")
    _G.VariantMap = oldVariantMap
    _G.Variant = oldVariant
end

return Spec
