package.path = "scripts/?.lua;scripts/?/init.lua;?.lua;" .. package.path

local specs = {
    (require("tests.core.RateLimiter_spec")),
    (require("tests.core.PlayerRegistry_spec")),
    (require("tests.core.OperationQueue_spec")),
    (require("tests.core.CommandRouter_spec")),
    (require("tests.core.GameCommands_spec")),
}

for _, spec in ipairs(specs) do
    spec.Run()
end

print("core tests passed: " .. #specs)
