package.path = "scripts/?.lua;scripts/?/init.lua;?.lua;" .. package.path

local specs = {
    (require("tests.client.ServerClient_spec")),
    (require("tests.client.DialogCoordinator_spec")),
    (require("tests.client.InventoryView_spec")),
}

for _, spec in ipairs(specs) do
    spec.Run()
end

print("client tests passed: " .. #specs)
