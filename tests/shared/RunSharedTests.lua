package.path = "scripts/?.lua;scripts/?/init.lua;?.lua;" .. package.path

local specs = {
    (require("tests.shared.ErrorCodes_spec")),
    (require("tests.shared.NetworkProtocol_spec")),
    (require("tests.shared.GameStateSchema_spec")),
    (require("tests.shared.TowerRules_spec")),
    (require("tests.shared.PowerEvaluator_spec")),
    (require("tests.shared.RewardPolicy_spec")),
    (require("tests.shared.LeaderboardCodec_spec")),
}

for _, spec in ipairs(specs) do
    spec.Run()
end

print("shared tests passed: " .. #specs)
