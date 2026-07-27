package.path = "scripts/?.lua;scripts/?/init.lua;?.lua;" .. package.path

local specs = {
    (require("tests.simulation.LongitudinalProgressionSimulator_spec")),
}

for _, spec in ipairs(specs) do
    spec.Run()
end

print("simulation tests passed: " .. #specs)
