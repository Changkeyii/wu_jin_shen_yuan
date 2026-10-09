local handlers, fps, resumes, saved = {}, 0, 0, nil
engine = { SetMaxFps = function(_, value) fps = value end }
function SubscribeToEvent(name, callback) assert(not handlers[name]); handlers[name] = callback end
function UnsubscribeFromEvent(name) handlers[name] = nil end
fileSystem = { CreateDir = function() end, FileExists = function() return saved ~= nil end }
FILE_READ, FILE_WRITE = 0, 1
cjson = { encode = function(v) return v.powerSaving and 'true' or 'false' end,
    decode = function(v) return { powerSaving = v == 'true' } end }
function File()
    return { IsOpen = function() return true end, Close = function() end,
        WriteString = function(_, value) saved = value end, ReadString = function() return saved end }
end
local P = require('client.PerformanceController')
P.Start(function() resumes = resumes + 1 end)
assert(fps == 60 and not P.IsPowerSaving())
P.SetPowerSaving(true); assert(fps == 30 and saved == 'true')
local function focus(focused, minimized)
    handlers.InputFocus(nil, {GetBool = function(_, name) return name == 'Focus' and focused or name == 'Minimized' and minimized end})
end
focus(false, true); assert(fps == 10 and not P.IsForeground())
focus(true, false); assert(fps == 30 and resumes == 1)
focus(true, false); assert(resumes == 1, 'only resume once per background visit')
P.Stop(); assert(not next(handlers))
package.loaded['client.PerformanceController'] = nil
P = require('client.PerformanceController')
P.Start(); assert(P.IsPowerSaving() and fps == 30, 'persisted preference survives restart')
P.SetPowerSaving(false); assert(fps == 60)
P.Stop()
print('performance_mode: PASS')
