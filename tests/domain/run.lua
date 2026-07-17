local scriptPath = arg and arg[0] or "tests/domain/run.lua"
local projectRoot = scriptPath:gsub("[\\/]tests[\\/]domain[\\/]run%.lua$", "")
if projectRoot == scriptPath then
    projectRoot = "."
end

package.path = table.concat({
    projectRoot .. "/scripts/?.lua",
    projectRoot .. "/scripts/?/init.lua",
    projectRoot .. "/tests/?.lua",
    package.path,
}, ";")

local Spec = require("domain.GameEngineSpec")
local names = {}
for name, test in pairs(Spec) do
    if type(test) == "function" then
        names[#names + 1] = name
    end
end
table.sort(names)

local passed = 0
for _, name in ipairs(names) do
    local ok, reason = pcall(Spec[name])
    if ok then
        passed = passed + 1
        print("PASS " .. name)
    else
        print("FAIL " .. name .. ": " .. tostring(reason))
    end
end

print(string.format("%d/%d domain tests passed", passed, #names))
if passed ~= #names then
    error("domain test suite failed")
end
