-- run_shared_tests.lua
-- 用 UrhoXRuntime 以 tool_mode 运行共享模块测试（纯 Lua，无引擎渲染依赖）。
-- 用法：
--   <根>/.cli/UrhoXRuntime _proc/run_shared_tests.lua -tapcode_dir=<根> -tool_mode
--
-- 引擎的 require 仅按 scripts/ 根解析；tests/ 在项目根（scripts/ 的兄弟目录），
-- 因此这里用 dofile 绝对路径加载各 spec 文件，spec 内部 require shared.* 走 scripts/ 可正常解析。

function Start()
    local ok, err = pcall(function()
        local files = {
            "/workspace/tests/shared/ErrorCodes_spec.lua",
            "/workspace/tests/shared/NetworkProtocol_spec.lua",
            "/workspace/tests/shared/GameStateSchema_spec.lua",
            "/workspace/tests/shared/TowerRules_spec.lua",
            "/workspace/tests/shared/PowerEvaluator_spec.lua",
            "/workspace/tests/shared/RewardPolicy_spec.lua",
            "/workspace/tests/shared/LeaderboardCodec_spec.lua",
        }
        local ran = 0
        for _, file in ipairs(files) do
            local spec = dofile(file)
            if type(spec) == "table" and type(spec.Run) == "function" then
                spec.Run()
                ran = ran + 1
            else
                error("spec missing Run(): " .. tostring(file))
            end
        end
        print("[shared-tests] passed: " .. ran .. "/" .. #files)
    end)
    if not ok then
        print("[shared-tests] FAILED: " .. tostring(err))
    end
    engine:Exit()
end
