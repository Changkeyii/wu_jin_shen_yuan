local P = require('shared.NetworkProtocol')
local C = require('client.ServerClient')
local events, decoded = {}, {}
LOCAL = 0
function Scene() return { CreateComponent = function() end, Dispose = function() end } end
function SubscribeToEvent(name, callback) events[name] = callback end
function UnsubscribeFromEvent(name) events[name] = nil end
function VariantMap() return {} end
function Variant(value) return { GetString = function() return value end } end
cjson = { encode = function() return '{}' end, decode = function() return decoded end }
network = { GetServerConnection = function() return nil end, RegisterRemoteEvent = function() end }
local function setLocal(fn, name, value)
    for i = 1, 100 do
        local key = debug.getupvalue(fn, i)
        if not key then break end
        if key == name then debug.setupvalue(fn, i, value); return end
    end
    error('missing test seam: ' .. name)
end
assert(C.Start())
local transport = { SendRemoteEvent = function() end }
setLocal(C.Send, 'connection_', transport)
setLocal(C.Send, 'ready_', true)
local calls, last = 0, nil
local function done(result) calls = calls + 1; last = result end
local id = C.Send('test', {}, done)
C.Update(29); assert(calls == 0)
C.Update(1); assert(calls == 1 and not last.ok, 'timeout must release request')
local function respond(requestId)
    decoded = {requestId = requestId, ok = true}
    events[P.EVENTS.RESPONSE](nil, {[P.FIELDS.PAYLOAD_JSON] = Variant('{}')})
end
respond(id); assert(calls == 1, 'late response after timeout is ignored')
id = C.Send('test', {}, done)
respond(id); respond(id)
assert(calls == 2 and last.ok, 'duplicate response completes once')
C.Send('test', {}, done)
events.ServerDisconnected(nil, {})
assert(calls == 3 and not last.ok, 'disconnect completes every pending request')
setLocal(C.Send, 'connection_', transport); setLocal(C.Send, 'ready_', true)
transport.SendRemoteEvent = function() error('transport failure') end
assert(not C.Send('test', {}, done))
assert(calls == 4 and not last.ok, 'send failure releases immediately')
C.Update(30); assert(calls == 4)
transport.SendRemoteEvent = function() end
id = C.Send('test', {}, done)
C.ClearPresentationRequests()
respond(id); assert(calls == 4, 'emergency recovery ignores callbacks from old presentation')
C.Stop()
print('request_lifecycle: PASS')
