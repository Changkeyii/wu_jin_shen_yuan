local M = {}
local powerSaving, foreground = false, true
local loaded = false
local path = "settings/performance.json"
function M.IsPowerSaving() return powerSaving end
function M.IsForeground() return foreground end
local function apply()
    if engine and engine.SetMaxFps then engine:SetMaxFps(not foreground and 10 or (powerSaving and 30 or 60)) end
end
function M.SetPowerSaving(value)
    powerSaving = value == true
    apply()
    if fileSystem and File and cjson then
        fileSystem:CreateDir("settings")
        local f = File(path, FILE_WRITE)
        if f:IsOpen() then f:WriteString(cjson.encode({ powerSaving = powerSaving })); f:Close() end
    end
end
function M.Start(onResume)
    if not loaded then
        loaded = true
        if fileSystem and fileSystem:FileExists(path) then
            local f = File(path, FILE_READ)
            if f:IsOpen() then
                local ok, value = pcall(cjson.decode, f:ReadString()); f:Close()
                powerSaving = ok and type(value) == "table" and value.powerSaving == true
            end
        end
    end
    apply()
    SubscribeToEvent("InputFocus", function(_, data)
        local previous = foreground
        foreground = data:GetBool("Focus") and not data:GetBool("Minimized")
        apply()
        if foreground and not previous and onResume then onResume() end
    end)
end
function M.Stop() UnsubscribeFromEvent("InputFocus") end
return M
