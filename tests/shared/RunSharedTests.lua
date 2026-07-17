local specs = {
    require("tests.shared.ErrorCodes_spec"),
    require("tests.shared.NetworkProtocol_spec"),
    require("tests.shared.GameStateSchema_spec"),
}

for _, spec in ipairs(specs) do
    spec.Run()
end

print("shared tests passed: " .. #specs)
