local scriptPath = arg and arg[0] or "tests/integration/run.lua"
local projectRoot = scriptPath:gsub("[\\/]tests[\\/]integration[\\/]run%.lua$", "")
if projectRoot == scriptPath then projectRoot = "." end

package.path = table.concat({
    projectRoot .. "/scripts/?.lua",
    projectRoot .. "/scripts/?/init.lua",
    projectRoot .. "/tests/?.lua",
    package.path,
}, ";")

local specs = {
    (require("integration.PlayerProfileIntegrationSpec")),
    (require("integration.AdminServiceIntegrationSpec")),
}

local tests = {}
for _, spec in ipairs(specs) do
    for name, test in pairs(spec) do
        if type(test) == "function" then
            tests[#tests + 1] = { name = name, run = test }
        end
    end
end
table.sort(tests, function(left, right) return left.name < right.name end)

local passed = 0
for _, test in ipairs(tests) do
    local ok, reason = pcall(test.run)
    if ok then
        passed = passed + 1
        print("PASS " .. test.name)
    else
        print("FAIL " .. test.name .. ": " .. tostring(reason))
    end
end

print(string.format("%d/%d integration tests passed", passed, #tests))
if passed ~= #tests then error("integration test suite failed") end
