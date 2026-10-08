local scriptPath = arg and arg[0] or "tests/simulation/run.lua"
local projectRoot = scriptPath:gsub("[\\/]tests[\\/]simulation[\\/]run%.lua$", "")
if projectRoot == scriptPath or projectRoot == "" then projectRoot = "." end

package.path = table.concat({
    projectRoot .. "/scripts/?.lua",
    projectRoot .. "/scripts/?/init.lua",
    projectRoot .. "/tests/?.lua",
    projectRoot .. "/?.lua",
    package.path,
}, ";")

pcall(os.setlocale, "C", "numeric")

local Simulator = require("tests.simulation.TowerBalanceSimulator")
local Progression = require("tests.simulation.LongitudinalProgressionSimulator")

local OUTPUT_NAMES = {
    "key_floor_matrix.csv",
    "thresholds.csv",
    "failure_seeds.csv",
    "progression_cohorts.csv",
    "progression_checkpoints.csv",
    "progression_chapters.csv",
    "progression_failure_seeds.csv",
    "report.md",
}

local function usage()
    print([[
Tower balance simulation (Lua 5.4)

Usage:
  lua tests/simulation/run.lua [options]
  lua tests/simulation/run.lua --replay <scenario-id> --trial-seed <seed> [options]
  lua tests/simulation/run.lua --replay-progression <cohort-seed> [options]

Options:
  --seed <integer>              Base seed (default: 20260723)
  --samples <integer>           Combat samples per independent cohort (default: 100000)
  --progression-samples <n>     Longitudinal seed pairs (default: 10)
  --progression-max-floor <n>   Longitudinal target floor (default: 1000)
  --model <name>                aggregate or hits (default: aggregate)
  --out <directory>             Output directory (default: tests/simulation/results)
  --quick                       Combat 2000; progression 1 pair through floor 100
  --replay <scenario>           Replay one named combat scenario
  --trial-seed <integer>        Trial seed required by --replay
  --replay-progression <seed>   Replay one auto/control longitudinal seed pair
  --help                        Show this help
]])
end

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function requireValue(argv, index, option)
    local value = argv[index + 1]
    if value == nil or value:sub(1, 2) == "--" then
        error(option .. " requires a value")
    end
    return value
end

local function parseInteger(raw, option)
    local value = tonumber(raw)
    if not finite(value) or value ~= math.floor(value) then
        error(option .. " must be a finite integer")
    end
    return value
end

local function parseArguments(argv)
    local options = {
        seed = Simulator.DEFAULT_SEED,
        samples = Simulator.DEFAULT_SAMPLES,
        progressionSamples = Progression.DEFAULT_SAMPLES,
        progressionMaxFloor = Progression.DEFAULT_MAX_FLOOR,
        model = "aggregate",
        out = projectRoot .. "/tests/simulation/results",
    }
    local samplesExplicit = false
    local progressionSamplesExplicit = false
    local progressionMaxFloorExplicit = false
    local quick = false
    local index = 1
    while argv[index] ~= nil do
        local token = argv[index]
        if token == "--seed" then
            options.seed = parseInteger(requireValue(argv, index, token), token)
            index = index + 2
        elseif token == "--samples" then
            options.samples = parseInteger(requireValue(argv, index, token), token)
            samplesExplicit = true
            index = index + 2
        elseif token == "--progression-samples" then
            options.progressionSamples = parseInteger(requireValue(argv, index, token), token)
            progressionSamplesExplicit = true
            index = index + 2
        elseif token == "--progression-max-floor" then
            options.progressionMaxFloor = parseInteger(requireValue(argv, index, token), token)
            progressionMaxFloorExplicit = true
            index = index + 2
        elseif token == "--model" then
            options.model = requireValue(argv, index, token)
            index = index + 2
        elseif token == "--out" then
            options.out = requireValue(argv, index, token)
            index = index + 2
        elseif token == "--quick" then
            quick = true
            index = index + 1
        elseif token == "--replay" then
            options.replay = requireValue(argv, index, token)
            index = index + 2
        elseif token == "--trial-seed" then
            options.trialSeed = parseInteger(requireValue(argv, index, token), token)
            index = index + 2
        elseif token == "--replay-progression" or token == "--replay-progression-seed" then
            options.replayProgression = parseInteger(requireValue(argv, index, token), token)
            index = index + 2
        elseif token == "--help" or token == "-h" then
            options.help = true
            index = index + 1
        else
            error("unknown option: " .. tostring(token))
        end
    end

    if quick and not samplesExplicit then options.samples = Simulator.QUICK_SAMPLES end
    if quick and not progressionSamplesExplicit then
        options.progressionSamples = Progression.QUICK_SAMPLES
    end
    if quick and not progressionMaxFloorExplicit then options.progressionMaxFloor = 100 end
    if options.samples < 1 or options.samples > 10000000 then
        error("--samples must be between 1 and 10000000")
    end
    if options.progressionSamples < 1 or options.progressionSamples > 100000 then
        error("--progression-samples must be between 1 and 100000")
    end
    if options.progressionMaxFloor < 100 or options.progressionMaxFloor > 100000 then
        error("--progression-max-floor must be between 100 and 100000")
    end
    if options.model ~= "aggregate" and options.model ~= "hits" then
        error("--model must be aggregate or hits")
    end
    if type(options.out) ~= "string" or options.out == "" then
        error("--out must not be empty")
    end
    if options.replay and options.trialSeed == nil then
        error("--trial-seed is required with --replay")
    end
    if options.replay and options.replayProgression then
        error("--replay and --replay-progression cannot be combined")
    end
    options.quick = quick
    return options
end

local function pathJoin(left, right)
    return left:gsub("[\\/]+$", "") .. "/" .. right
end

local function directoryExists(path)
    local ok, _, code = os.rename(path, path)
    return ok == true or code == 13
end

local function ensureDirectory(path)
    if directoryExists(path) then return end
    if path:find('"', 1, true) or path:find("\n", 1, true) or path:find("\r", 1, true) then
        error("output directory contains an unsupported character")
    end
    local windows = package.config:sub(1, 1) == "\\"
    local command = windows
        and ('mkdir "' .. path .. '" >NUL 2>NUL')
        or ('mkdir -p "' .. path .. '" >/dev/null 2>&1')
    os.execute(command)
    if not directoryExists(path) then error("could not create output directory: " .. path) end
end

local function writeFile(path, content)
    local file, reason = io.open(path, "wb")
    if not file then error("could not open " .. path .. ": " .. tostring(reason)) end
    local ok, writeReason = file:write(content)
    file:close()
    if not ok then error("could not write " .. path .. ": " .. tostring(writeReason)) end
end

local function stableScalar(value)
    if value == nil then return "" end
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "number" then
        if value ~= value then return "nan" end
        if value == math.huge then return "inf" end
        if value == -math.huge then return "-inf" end
        if value == math.floor(value) and math.abs(value) < 9007199254740992 then
            return string.format("%.0f", value)
        end
        return string.format("%.12g", value)
    end
    return tostring(value)
end

local function csvCell(value)
    local text = stableScalar(value)
    if text:find('[,"\r\n]') then return '"' .. text:gsub('"', '""') .. '"' end
    return text
end

local function column(header, key)
    return { header = header, value = type(key) == "function" and key or function(row)
        return row[key]
    end }
end

local function writeCsv(path, columns, rows)
    local lines = {}
    local headers = {}
    for index, descriptor in ipairs(columns) do headers[index] = csvCell(descriptor.header) end
    lines[1] = table.concat(headers, ",")
    for rowIndex, row in ipairs(rows) do
        local cells = {}
        for columnIndex, descriptor in ipairs(columns) do
            cells[columnIndex] = csvCell(descriptor.value(row))
        end
        lines[rowIndex + 1] = table.concat(cells, ",")
    end
    writeFile(path, table.concat(lines, "\n") .. "\n")
end

local VERSION_COLUMNS = {
    column("simulator_version", "simulatorVersion"),
    column("power_evaluator_version", "powerEvaluatorVersion"),
    column("reward_policy_version", "rewardPolicyVersion"),
    column("rarity_catalog_version", "rarityCatalogVersion"),
    column("tower_rules_version", "towerRulesVersion"),
    column("rng_algorithm", "rngAlgorithm"),
}

local function appendColumns(target, source)
    for _, value in ipairs(source) do target[#target + 1] = value end
    return target
end

local function commonResultColumns()
    local result = {}
    appendColumns(result, VERSION_COLUMNS)
    appendColumns(result, {
        column("requested_base_seed", "requestedBaseSeed"),
        column("effective_base_seed", "effectiveBaseSeed"),
        column("cohort_seed", "effectiveSeed"),
        column("model", "model"),
        column("samples", "samples"),
        column("success_count", "successCount"),
        column("failure_count", "failureCount"),
        column("pass_rate", "passRate"),
        column("soft_stuck_rate", "softStuckRate"),
        column("combat_seconds_mean", "combatSecondsMean"),
        column("combat_seconds_p50", "combatSecondsP50"),
        column("combat_seconds_p90", "combatSecondsP90"),
        column("combat_seconds_p99", "combatSecondsP99"),
        column("success_combat_seconds_mean", "successCombatSecondsMean"),
        column("success_combat_seconds_p50", "successCombatSecondsP50"),
        column("success_combat_seconds_p90", "successCombatSecondsP90"),
        column("success_combat_seconds_p99", "successCombatSecondsP99"),
        column("failure_combat_seconds_mean", "failureCombatSecondsMean"),
        column("failure_combat_seconds_p50", "failureCombatSecondsP50"),
        column("failure_combat_seconds_p90", "failureCombatSecondsP90"),
        column("failure_combat_seconds_p99", "failureCombatSecondsP99"),
        column("remaining_hp_ratio_mean", "remainingHpRatioMean"),
        column("remaining_hp_ratio_p10", "remainingHpRatioP10"),
        column("remaining_hp_ratio_p50", "remainingHpRatioP50"),
    })
    for room = 1, 10 do
        result[#result + 1] = column("death_room_" .. room .. "_count", function(row)
            return row.deathRoomCounts and row.deathRoomCounts[room] or 0
        end)
    end
    appendColumns(result, {
        column("tower_score", "towerScore"),
        column("boss_score", "bossScore"),
        column("elite_score", "eliteScore"),
        column("route_survives_analytic", "routeSurvivesAnalytic"),
        column("boss_ttk_safe", "bossTtkSafe"),
        column("boss_ttk_mean", "bossTtkMean"),
        column("failure_seed_limit", "failureSeedLimit"),
        column("retained_failure_seed_count", "retainedFailureSeedCount"),
    })
    return result
end

local function matrixColumns()
    local result = {
        column("scenario_id", "id"),
        column("scenario_kind", "scenarioKind"),
        column("profile_id", "profileId"),
        column("profile_label", "profileLabel"),
        column("floor", "floor"),
        column("representative_floor", "representativeFloor"),
        column("boss_kind", "bossKind"),
        column("scope", "scope"),
        column("simulation_group", "simulationGroup"),
        column("independent_cohort", "independentCohort"),
        column("scale_invariant_reuse", "scaleInvariantReuse"),
    }
    appendColumns(result, commonResultColumns())
    appendColumns(result, {
        column("recommended_power", "recommendedPower"),
        column("displayed_power_ratio", "displayedPowerRatio"),
        column("equivalent_floor", "equivalentFloor"),
        column("headroom_floors", "headroomFloors"),
    })
    return result
end

local function thresholdColumns()
    local result = {
        column("scenario_id", "id"),
        column("scenario_kind", "scenarioKind"),
        column("measurement_role", "measurementRole"),
        column("floor", "floor"),
        column("boss_kind", "bossKind"),
        column("scope", "scope"),
        column("attribute_ratio", "attributeRatio"),
        column("gate", "gate"),
        column("diagnostic_only", "diagnosticOnly"),
        column("target_pass_rate", "targetPassRate"),
        column("meets_target", "meetsTarget"),
    }
    appendColumns(result, commonResultColumns())
    return result
end

local function failureColumns()
    local result = {}
    appendColumns(result, VERSION_COLUMNS)
    appendColumns(result, {
        column("requested_base_seed", "requestedBaseSeed"),
        column("effective_base_seed", "effectiveBaseSeed"),
        column("scenario_id", "scenarioId"),
        column("scenario_kind", "scenarioKind"),
        column("measurement_role", "measurementRole"),
        column("profile_id", "profileId"),
        column("profile_label", "profileLabel"),
        column("floor", "floor"),
        column("representative_floor", "representativeFloor"),
        column("boss_kind", "bossKind"),
        column("scope", "scope"),
        column("model", "model"),
        column("simulation_group", "simulationGroup"),
        column("attribute_ratio", "attributeRatio"),
        column("target_pass_rate", "targetPassRate"),
        column("gate", "gate"),
        column("cohort_seed", "cohortSeed"),
        column("trial_index", "trialIndex"),
        column("trial_seed", "trialSeed"),
        column("death_room", "deathRoom"),
        column("combat_seconds", "combatSeconds"),
        column("total_failure_count", "totalFailureCount"),
        column("retained_failure_seed_count", "retainedFailureSeedCount"),
        column("failure_seed_limit", "failureSeedLimit"),
        column("replay_command", "replayCommand"),
    })
    return result
end

local function decorateProgressionRows(rows, options, progression)
    local metadata = Simulator.Metadata()
    for _, row in ipairs(rows) do
        row.progressionVersion = progression.version
        row.method = progression.method
        row.simulatorVersion = metadata.simulatorVersion
        row.powerEvaluatorVersion = metadata.powerEvaluatorVersion
        row.rewardPolicyVersion = metadata.rewardPolicyVersion
        row.rarityCatalogVersion = metadata.rarityCatalogVersion
        row.towerRulesVersion = metadata.towerRulesVersion
        row.catalogSchemaVersion = progression.catalogVersion
        row.storyCatalogVersion = progression.storyCatalogVersion
        row.rngAlgorithm = metadata.rngAlgorithm
        row.requestedBaseSeed = options.seed
        row.effectiveBaseSeed = progression.seed
        row.progressionSamples = progression.samples
        row.progressionMaxFloor = progression.maxFloor
        row.model = progression.model
        row.branchComparisonDesign = progression.branchComparisonDesign
        row.branchPairedRandomStream = progression.branchPairedRandomStream
        row.autoEquipGateDesign = progression.autoEquipGateDesign
        row.autoEquipGatePairedRandomStream = progression.autoEquipGatePairedRandomStream
    end
    return rows
end

local function progressionCohortRows(options, progression)
    local rows = {}
    for index = 1, progression.samples do
        rows[#rows + 1] = progression.autoCohorts[index]
        rows[#rows + 1] = progression.controlCohorts[index]
    end
    return decorateProgressionRows(rows, options, progression)
end

local function progressionCohortColumns()
    return {
        column("progression_version", "progressionVersion"),
        column("method", "method"),
        column("simulator_version", "simulatorVersion"),
        column("power_evaluator_version", "powerEvaluatorVersion"),
        column("reward_policy_version", "rewardPolicyVersion"),
        column("rarity_catalog_version", "rarityCatalogVersion"),
        column("tower_rules_version", "towerRulesVersion"),
        column("catalog_schema_version", "catalogSchemaVersion"),
        column("story_catalog_version", "storyCatalogVersion"),
        column("rng_algorithm", "rngAlgorithm"),
        column("requested_base_seed", "requestedBaseSeed"),
        column("effective_base_seed", "effectiveBaseSeed"),
        column("progression_samples", "progressionSamples"),
        column("cohort_seed", "cohortSeed"),
        column("mode", "mode"),
        column("model", "model"),
        column("branch_comparison_design", "branchComparisonDesign"),
        column("branch_paired_random_stream", "branchPairedRandomStream"),
        column("max_floor_target", "maxFloorTarget"),
        column("completed_floor", "completedFloor"),
        column("hard_stuck_floor", "hardStuckFloor"),
        column("time_to_100_hours", "timeTo100Hours"),
        column("total_hours", "totalHours"),
        column("combat_seconds", "combatSeconds"),
        column("transition_seconds", "transitionSeconds"),
        column("story_seconds", "storySeconds"),
        column("interaction_seconds", "interactionSeconds"),
        column("total_attempts", "totalAttempts"),
        column("successful_attempts", "successfulAttempts"),
        column("attempt_success_rate", "attemptSuccessRate"),
        column("soft_stuck_floors", "softStuckFloors"),
        column("soft_stuck_per_100_mean", "softStuckPer100Mean"),
        column("max_failures_on_floor", "maxFailuresOnFloor"),
        column("failures_before_clear_p99", "failuresBeforeClearP99"),
        column("aid_claims", "aidClaims"),
        column("aid_items", "aidItems"),
        column("aid_target_pass_rate", "aidTargetPassRate"),
        column("aid_third_attempts", "aidThirdAttempts"),
        column("aid_third_passes", "aidThirdPasses"),
        column("aid_third_attempt_pass_rate", "aidThirdAttemptPassRate"),
        column("drops", "drops"),
        column("disposed_drops", "disposedDrops"),
        column("inventory_maintenance_events", "inventoryMaintenanceEvents"),
        column("inventory_items_removed", "inventoryItemsRemoved"),
        column("common_drops", function(row) return row.rarityDrops.common or 0 end),
        column("advanced_drops", function(row) return row.rarityDrops.advanced or 0 end),
        column("rare_drops", function(row) return row.rarityDrops.rare or 0 end),
        column("artifact_drops", function(row) return row.rarityDrops.artifact or 0 end),
        column("legendary_drops", function(row) return row.rarityDrops.legendary or 0 end),
        column("epic_drops", function(row) return row.rarityDrops.epic or 0 end),
        column("myth_drops", function(row) return row.rarityDrops.myth or 0 end),
        column("epic_pity_misses", "epicPityMisses"),
        column("myth_pity_misses", "mythPityMisses"),
        column("inventory_capacity_blocks", "inventoryCapacityBlocks"),
        column("inventory_blocked_floor", "inventoryBlockedFloor"),
        column("wearable_upgrades", "wearableUpgrades"),
        column("auto_equip_events", "autoEquipEvents"),
        column("auto_equip_comparisons", "autoEquipComparisons"),
        column("upgrades_per_10_p50", "upgradesPer10P50"),
        column("power_ratio_p10", "powerRatioP10"),
        column("power_ratio_p50", "powerRatioP50"),
        column("power_ratio_p90", "powerRatioP90"),
        column("floor_only_displayed_power_delta_maximum",
            "maximumFloorOnlyDisplayedPowerDelta"),
    }
end

local function progressionCheckpointColumns()
    return {
        column("progression_version", "progressionVersion"),
        column("method", "method"),
        column("catalog_schema_version", "catalogSchemaVersion"),
        column("story_catalog_version", "storyCatalogVersion"),
        column("requested_base_seed", "requestedBaseSeed"),
        column("effective_base_seed", "effectiveBaseSeed"),
        column("progression_samples", "progressionSamples"),
        column("max_floor_target", "progressionMaxFloor"),
        column("model", "model"),
        column("checkpoint_floor", "checkpointFloor"),
        column("soft_stuck_sample_count", "softStuckSampleCount"),
        column("soft_stuck_per_100_mean", "softStuckPer100Mean"),
        column("soft_stuck_per_100_p50", "softStuckPer100P50"),
        column("soft_stuck_per_100_p90", "softStuckPer100P90"),
        column("power_ratio_sample_count", "powerRatioSampleCount"),
        column("power_ratio_p10", "powerRatioP10"),
        column("power_ratio_p50", "powerRatioP50"),
        column("power_ratio_p90", "powerRatioP90"),
        column("cumulative_hours_sample_count", "cumulativeHoursSampleCount"),
        column("cumulative_hours_p50", "cumulativeHoursP50"),
        column("cumulative_hours_p90", "cumulativeHoursP90"),
    }
end

local function progressionChapterColumns()
    return {
        column("progression_version", "progressionVersion"),
        column("method", "method"),
        column("catalog_schema_version", "catalogSchemaVersion"),
        column("story_catalog_version", "storyCatalogVersion"),
        column("requested_base_seed", "requestedBaseSeed"),
        column("effective_base_seed", "effectiveBaseSeed"),
        column("progression_samples", "progressionSamples"),
        column("max_floor_target", "progressionMaxFloor"),
        column("model", "model"),
        column("chapter", "chapter"),
        column("floor_start", "floorStart"),
        column("floor_end", "floorEnd"),
        column("auto_cohort_samples", "autoCohortSamples"),
        column("auto_attempts", "autoAttempts"),
        column("auto_successes", "autoSuccesses"),
        column("auto_success_rate", "autoSuccessRate"),
        column("control_cohort_samples", "controlCohortSamples"),
        column("control_attempts", "controlAttempts"),
        column("control_successes", "controlSuccesses"),
        column("control_success_rate", "controlSuccessRate"),
        column("unpaired_auto_control_delta", "unpairedAutoControlDelta"),
        column("upgrades_sample_count", "upgradesSampleCount"),
        column("upgrades_p50", "upgradesP50"),
        column("common_drops", function(row) return row.rarityDrops.common or 0 end),
        column("advanced_drops", function(row) return row.rarityDrops.advanced or 0 end),
        column("rare_drops", function(row) return row.rarityDrops.rare or 0 end),
        column("artifact_drops", function(row) return row.rarityDrops.artifact or 0 end),
        column("legendary_drops", function(row) return row.rarityDrops.legendary or 0 end),
        column("epic_drops", function(row) return row.rarityDrops.epic or 0 end),
        column("myth_drops", function(row) return row.rarityDrops.myth or 0 end),
        column("auto_equip_accepted", "autoEquipAccepted"),
        column("auto_equip_paired_trials", "autoEquipPairedTrials"),
        column("auto_equip_before_successes", "autoEquipBeforeSuccesses"),
        column("auto_equip_before_success_rate", "autoEquipBeforeSuccessRate"),
        column("auto_equip_after_successes", "autoEquipAfterSuccesses"),
        column("auto_equip_after_success_rate", "autoEquipAfterSuccessRate"),
        column("auto_equip_delta", "autoEquipDelta"),
        column("auto_equip_gate_design", "autoEquipGateDesign"),
        column("auto_equip_gate_paired_random_stream", "autoEquipGatePairedRandomStream"),
    }
end

local function progressionFailureColumns()
    return {
        column("progression_version", "progressionVersion"),
        column("method", "method"),
        column("simulator_version", "simulatorVersion"),
        column("power_evaluator_version", "powerEvaluatorVersion"),
        column("reward_policy_version", "rewardPolicyVersion"),
        column("rarity_catalog_version", "rarityCatalogVersion"),
        column("tower_rules_version", "towerRulesVersion"),
        column("catalog_schema_version", "catalogSchemaVersion"),
        column("story_catalog_version", "storyCatalogVersion"),
        column("rng_algorithm", "rngAlgorithm"),
        column("requested_base_seed", "requestedBaseSeed"),
        column("effective_base_seed", "effectiveBaseSeed"),
        column("progression_samples", "progressionSamples"),
        column("max_floor_target", "progressionMaxFloor"),
        column("model", "model"),
        column("cohort_seed", "cohortSeed"),
        column("mode", "mode"),
        column("reasons", "reasons"),
        column("completed_floor", "completedFloor"),
        column("hard_stuck_floor", "hardStuckFloor"),
        column("inventory_capacity_blocks", "inventoryCapacityBlocks"),
        column("inventory_blocked_floor", "inventoryBlockedFloor"),
        column("time_to_100_hours", "timeTo100Hours"),
        column("soft_stuck_per_100_mean", "softStuckPer100Mean"),
        column("failures_before_clear_p99", "failuresBeforeClearP99"),
        column("upgrades_per_10_p50", "upgradesPer10P50"),
        column("power_ratio_p50", "powerRatioP50"),
        column("floor_only_displayed_power_delta_maximum",
            "maximumFloorOnlyDisplayedPowerDelta"),
        column("replay_command", "replayCommand"),
    }
end

local function percent(value)
    return string.format("%.4f%%", (tonumber(value) or 0) * 100)
end

local function decimal(value, digits)
    return string.format("%." .. (digits or 4) .. "f", tonumber(value) or 0)
end

local function markdownRow(values)
    local escaped = {}
    for index, value in ipairs(values) do
        escaped[index] = tostring(value == nil and "" or value):gsub("|", "\\|")
    end
    return "| " .. table.concat(escaped, " | ") .. " |"
end

local function sumFailures(rows)
    local total = 0
    for _, row in ipairs(rows) do total = total + (row.failureCount or 0) end
    return total
end

local function gateTarget(row)
    local function bound(value)
        if row.id:find("rate", 1, true) or row.id:find("delta", 1, true) then
            return percent(value)
        end
        return stableScalar(value)
    end
    if row.minimum ~= nil and row.maximum ~= nil then
        return "[" .. bound(row.minimum) .. ", " .. bound(row.maximum) .. "]"
    end
    if row.minimum ~= nil then return ">= " .. bound(row.minimum) end
    return "<= " .. bound(row.maximum)
end

local function gateValue(row)
    if row.id:find("rate", 1, true) or row.id:find("delta", 1, true) then
        return percent(row.value)
    end
    return stableScalar(row.value)
end

local function findGate(progression, id)
    for _, row in ipairs(progression.gates) do
        if row.id == id then return row end
    end
    return nil
end

local function buildReport(
    options,
    matrix,
    thresholds,
    failures,
    floorInvariant,
    scaleInvariant,
    progression)
    local hardGateFailures = {}
    for _, row in ipairs(thresholds) do
        if row.gate and not row.meetsTarget then hardGateFailures[#hardGateFailures + 1] = row end
    end
    local progressionGateFailures = {}
    for _, row in ipairs(progression.gates) do
        if not row.pass then progressionGateFailures[#progressionGateFailures + 1] = row end
    end
    local combatPassed = #hardGateFailures == 0
        and floorInvariant.meetsTarget
        and scaleInvariant.meetsTarget
    local passed = combatPassed and progression.passed
    local reportCommandPassed = passed or (options.quick and combatPassed)
    local aidProgressionGate = findGate(progression, "aid_third_attempt_pass_rate")
    local upgradeProgressionGate = findGate(progression, "wearable_upgrades_per_10_p50")
    local powerProgressionGate = findGate(progression, "power_ratio_within_1000_p50")
    local autoEquipProgressionGate = findGate(progression, "auto_equip_minimum_chapter_delta")
    local independent = {}
    for _, row in ipairs(matrix) do
        if row.independentCohort then independent[#independent + 1] = row end
    end
    local effectiveSeed = Simulator.NormalizeSeed(options.seed)
    local physicalMatrixTrials = #independent * options.samples
    local logicalMatrixCoverage = #matrix * options.samples
    local thresholdTrials = #thresholds * options.samples

    local lines = {
        "# Tower Balance Simulation Report",
        "",
        "Gate status: **" .. (passed and "PASS" or "FAIL") .. "**"
            .. (options.quick and " (quick smoke; progression gates are reported but not enforced)" or ""),
        "",
        "Command status: **" .. (reportCommandPassed and "PASS" or "FAIL") .. "**",
        "",
        "## Reproducibility",
        "",
        markdownRow({ "Field", "Value" }),
        markdownRow({ "---", "---" }),
        markdownRow({ "Canonical command", "`lua tests/simulation/run.lua --seed "
            .. stableScalar(options.seed) .. " --samples " .. options.samples
            .. " --progression-samples " .. options.progressionSamples
            .. " --progression-max-floor " .. options.progressionMaxFloor
            .. " --model " .. options.model
            .. (options.quick and " --quick" or "")
            .. " --out <out>`" }),
        markdownRow({ "Requested base seed", stableScalar(options.seed) }),
        markdownRow({ "Effective base seed", effectiveSeed }),
        markdownRow({ "Execution mode", options.quick and "quick smoke (progression gates not enforced)"
            or "formal (all gates enforced)" }),
        markdownRow({ "Samples per independent cohort", options.samples }),
        markdownRow({ "Longitudinal seed pairs", progression.samples }),
        markdownRow({ "Longitudinal target floor", progression.maxFloor }),
        markdownRow({ "Longitudinal version", progression.version }),
        markdownRow({ "Longitudinal method", progression.method }),
        markdownRow({ "Model", options.model }),
        markdownRow({ "Simulator version", Simulator.VERSION }),
        markdownRow({ "PowerEvaluator version", matrix[1].powerEvaluatorVersion }),
        markdownRow({ "TowerRules version", matrix[1].towerRulesVersion }),
        markdownRow({ "RewardPolicy version", matrix[1].rewardPolicyVersion }),
        markdownRow({ "RarityCatalog version", matrix[1].rarityCatalogVersion }),
        markdownRow({ "Catalog schema version", progression.catalogVersion }),
        markdownRow({ "StoryCatalog version", progression.storyCatalogVersion }),
        markdownRow({ "RNG", Simulator.RNG_ALGORITHM }),
        "",
        "The report intentionally omits timestamps, host paths, and wall-clock runtime so identical inputs produce byte-identical artifacts.",
        "",
        "## Sampling Contract",
        "",
        "The key-floor matrix contains **" .. #matrix .. " logical rows** (8 floors x 6 profiles), but only **"
            .. #independent .. " independent stochastic cohorts**. The normalized combat formulas are scale invariant within the regular/chapter groups, so floors 50-5000 reuse the floor-10 chapter cohort. This run therefore executed "
            .. physicalMatrixTrials .. " matrix trials and represents " .. logicalMatrixCoverage
            .. " logical row-samples; it does **not** claim " .. logicalMatrixCoverage .. " independent trials.",
        "",
        "The analytic reuse check covered " .. #scaleInvariant.checks .. " profile/floor comparisons. Maximum relative difference was `"
            .. stableScalar(scaleInvariant.maximumRelativeDifference) .. "` against a `"
            .. stableScalar(scaleInvariant.targetMaximum) .. "` limit ("
            .. (scaleInvariant.meetsTarget and "PASS" or "FAIL") .. ").",
        "",
        "Threshold scenarios executed " .. thresholdTrials
            .. " additional fixed-combat trials. Total fixed-combat physical trials: **"
            .. (physicalMatrixTrials + thresholdTrials) .. "**.",
        "",
        "Longitudinal work executed **" .. progression.samples .. " seed pairs** as **"
            .. (progression.samples * 2) .. " stateful branch histories** through target floor **"
            .. progression.maxFloor .. "**, plus **" .. progression.totalAutoEquipPairedTrials
            .. " common-seed before/after pairs on the next chapter's complete 10-room route** from **"
            .. progression.totalAutoEquipAccepted
            .. " accepted auto-equip events**. This work is reported separately and is not included in the fixed-combat physical-trial total.",
        "",
        "## Hard Gates",
        "",
        "Only the original boss-scope acceptance targets are gates. Route rows are diagnostics and cannot fail this section.",
        "",
        markdownRow({ "Scenario", "Scope", "Pass rate", "Target", "Gate" }),
        markdownRow({ "---", "---", "---:", "---:", "---" }),
    }
    for _, row in ipairs(thresholds) do
        if row.gate then
            lines[#lines + 1] = markdownRow({
                row.id, row.scope, percent(row.passRate), percent(row.targetPassRate),
                row.meetsTarget and "PASS" or "FAIL",
            })
        end
    end

    appendColumns(lines, {
        "",
        "Displayed-power floor independence: **" .. (floorInvariant.meetsTarget and "PASS" or "FAIL")
            .. "** (`relativeDifference=" .. stableScalar(floorInvariant.relativeDifference) .. "`).",
        "",
        "## Longitudinal Progression Gates",
        "",
        "Longitudinal status: **" .. (progression.passed and "PASS" or "FAIL") .. "**. "
            .. progression.samples .. " independent starting seeds produced "
            .. (progression.samples * 2) .. " branch histories (auto and control) through target floor "
            .. progression.maxFloor .. ". Each gate reports its actual effective sample count `n`; "
            .. "a row below its declared `min n` is `INCONCLUSIVE` and fails the run.",
        "",
        markdownRow({ "Metric", "Value", "Target", "n", "min n", "Status" }),
        markdownRow({ "---", "---:", "---:", "---:", "---:", "---" }),
    })
    for _, row in ipairs(progression.gates) do
        lines[#lines + 1] = markdownRow({
            row.id,
            gateValue(row),
            gateTarget(row),
            row.sampleCount,
            row.minimumSampleCount,
            row.status,
        })
    end

    appendColumns(lines, {
        "",
        "### Longitudinal Checkpoints",
        "",
        markdownRow({ "Floor", "Soft-stuck/100 mean", "Power ratio P50", "Hours P50", "Hours P90" }),
        markdownRow({ "---:", "---:", "---:", "---:", "---:" }),
    })
    for _, row in ipairs(progression.checkpoints) do
        lines[#lines + 1] = markdownRow({
            row.checkpointFloor,
            decimal(row.softStuckPer100Mean),
            decimal(row.powerRatioP50),
            decimal(row.cumulativeHoursP50),
            decimal(row.cumulativeHoursP90),
        })
    end

    appendColumns(lines, {
        "",
        "### Longitudinal Method",
        "",
        "The V3 longitudinal cohort calls production `Catalog`, `RewardPolicy`, `PowerEvaluator`, `TowerRules`, and the real `GameEngine.ClaimAid` path. It does not call `GameEngine.AdvanceOneCell`; instead, every room follows production order: simulate the encounter, settle its drop, apply automatic equipment changes, refresh player stats, and then enter the next room while carrying remaining HP forward.",
        "",
        "Equipment budgets and character-core growth retain the base 50-floor doubling curve. Enemy stats, recommended power, and power evaluation use `TowerRules.DifficultyGrowth`: no offset through floor 10, a smoothstep ramp to +10 effective floors at floor 50, and a fixed +10 offset thereafter.",
        "",
        "Auto and control branches share a starting seed, but their RNG streams diverge conditionally as their routes and drops diverge; their raw chapter-rate delta is diagnostic only. The auto-equip gate instead evaluates every accepted before/after loadout with common trial seeds on the next chapter's complete 10-room route and reports the worst paired chapter delta.",
        "",
        "Elapsed progression time combines combat, the production `Catalog.STEP_SECONDS` transition for each completed encounter, modeled story reading ("
            .. Progression.STORY_SECONDS_PER_LINE .. " seconds per line plus "
            .. Progression.STORY_GATE_OVERHEAD_SECONDS .. " seconds per gate), and "
            .. Progression.INVENTORY_MAINTENANCE_SECONDS
            .. " seconds per inventory-maintenance event. Story and maintenance interaction time are exported separately as `story_seconds` and `interaction_seconds`. Aid coverage comes only from naturally observed two-failure triggers; insufficient third-attempt events remain `INCONCLUSIVE`.",
        "",
        "At each cleared chapter, the simulator models a 30-second manual inventory cleanup: equipped, locked, and aid items are retained together with the six highest raw-power candidates per slot; other candidates are removed regardless of rarity. This is an explicit player-behavior assumption, not production auto-decomposition and not an unattended-play equivalence. Between cleanups, a full inventory follows the simulated automatic-disposition/capacity-block path.",
        "",
        "## Route Diagnostics",
        "",
        markdownRow({ "Scenario", "Pass rate", "Soft-stuck proxy", "Mean sec", "P90 sec", "P99 sec" }),
        markdownRow({ "---", "---:", "---:", "---:", "---:", "---:" }),
    })
    for _, row in ipairs(thresholds) do
        if row.diagnosticOnly then
            lines[#lines + 1] = markdownRow({
                row.id, percent(row.passRate), percent(row.softStuckRate),
                decimal(row.combatSecondsMean), decimal(row.combatSecondsP90),
                decimal(row.combatSecondsP99),
            })
        end
    end

    appendColumns(lines, {
        "",
        "`soft-stuck proxy` means failure probability for one fixed-stat route attempt. It is not a longitudinal estimate of retries or time spent blocked on a floor.",
        "",
        "## Independent Matrix Cohorts",
        "",
        markdownRow({ "Profile", "Group floor", "Pass rate", "Soft-stuck proxy", "P50 sec", "P90 sec", "P99 sec", "HP P10" }),
        markdownRow({ "---", "---:", "---:", "---:", "---:", "---:", "---:", "---:" }),
    })
    for _, row in ipairs(independent) do
        lines[#lines + 1] = markdownRow({
            row.profileId, row.representativeFloor, percent(row.passRate),
            percent(row.softStuckRate), decimal(row.combatSecondsP50),
            decimal(row.combatSecondsP90), decimal(row.combatSecondsP99),
            percent(row.remainingHpRatioP10),
        })
    end

    appendColumns(lines, {
        "",
        "## Measurement Coverage",
        "",
        markdownRow({ "Metric", "Status", "Meaning" }),
        markdownRow({ "---", "---", "---" }),
        markdownRow({ "Combat pass rate and duration", "MEASURED", "Fixed-stat boss and 10-room route Monte Carlo; all/success/failure duration distributions are in CSV." }),
        markdownRow({ "Soft-stuck proxy and death room", "MEASURED", "One-attempt route failure rate plus full death-room counts; not a progression timeline." }),
        markdownRow({ "Post-aid combat safety proxy", "MEASURED", "The `aid_attributes_102` scenario tests fixed 1.02x attributes after aid." }),
        markdownRow({ "Actual aid trigger/claim/retry lifecycle",
            aidProgressionGate.measured and "MEASURED" or "INCONCLUSIVE",
            "Natural longitudinal failures execute `GameEngine.ClaimAid`; observed third attempts n="
                .. aidProgressionGate.sampleCount .. ", required n="
                .. aidProgressionGate.minimumSampleCount .. "." }),
        markdownRow({ "Static power/headroom at key floors", "MEASURED", "Displayed ratio, equivalent floor, headroom, and tower/boss/elite scores are exported." }),
        markdownRow({ "Upgrade item count and rarity over time",
            upgradeProgressionGate.measured and "MEASURED" or "INCONCLUSIVE",
            "V3 persistent cohorts execute production-ordered drop, rarity, pity, slot-bias, inventory, and wearable-upgrade rules; chapter observations n="
                .. upgradeProgressionGate.sampleCount .. "." }),
        markdownRow({ "Long-term power trajectory",
            powerProgressionGate.measured and "MEASURED" or "INCONCLUSIVE",
            "Persistent auto cohorts export 100-floor checkpoints and chapter power ratios through floor "
                .. progression.maxFloor .. "; within-1000 observations n="
                .. powerProgressionGate.sampleCount .. "." }),
        markdownRow({ "Automatic equipment replacement",
            autoEquipProgressionGate.measured and "MEASURED" or "INCONCLUSIVE",
            "Accepted upgrades use production acceptance criteria; "
                .. progression.totalAutoEquipAccepted .. " accepted events produced "
                .. progression.totalAutoEquipPairedTrials
                .. " paired before/after trials on the next chapter's complete 10-room route." }),
        "",
        "## Failure Seeds",
        "",
        "Observed failures: **" .. (sumFailures(independent) + sumFailures(thresholds))
            .. "**. Retained replay seeds: **" .. #failures
            .. "**. Seeds are intentionally capped per cohort (8 for matrix, 12 for thresholds); `failure_seeds.csv` is a deterministic replay sample, not an exhaustive failure log.",
        "",
        "Replay any retained row with its `replay_command`. The command reconstructs the named scenario and uses the recorded RNG state at the start of that trial.",
        "",
        "Longitudinal failing cohort seeds retained: **" .. #progression.failureSeeds
            .. "** (cap " .. Progression.FAILURE_SEED_LIMIT
            .. "). Replay a row with `lua tests/simulation/run.lua --replay-progression <cohort_seed> --progression-max-floor "
            .. progression.maxFloor .. " --model " .. progression.model .. "`.",
        "",
        "## Artifacts",
        "",
    })
    for _, name in ipairs(OUTPUT_NAMES) do lines[#lines + 1] = "- `" .. name .. "`" end
    lines[#lines + 1] = ""
    return table.concat(lines, "\n"), passed, hardGateFailures, progressionGateFailures
end

local options = parseArguments(arg or {})
if options.help then
    usage()
    return
end

if options.replay then
    local summary, reason = Simulator.ReplayScenario(options.replay, options.trialSeed, {
        model = options.model,
    })
    if not summary then error(reason) end
    print("scenario=" .. summary.id)
    print("trial_seed=" .. summary.effectiveSeed)
    print("model=" .. summary.model)
    print("success=" .. tostring(summary.successCount == 1))
    print("death_room=" .. stableScalar(summary.deathRoomCounts and next(summary.deathRoomCounts)))
    print("combat_seconds=" .. stableScalar(summary.combatSecondsMean))
    return
end

if options.replayProgression then
    local replay = Progression.Replay(options.replayProgression, {
        maxFloor = options.progressionMaxFloor,
        model = options.model,
    })
    print("cohort_seed=" .. Simulator.NormalizeSeed(options.replayProgression))
    print("model=" .. options.model)
    print("max_floor_target=" .. options.progressionMaxFloor)
    for _, branch in ipairs({ replay.auto, replay.control }) do
        print(branch.mode .. "_completed_floor=" .. stableScalar(branch.completedFloor))
        print(branch.mode .. "_hard_stuck_floor=" .. stableScalar(branch.hardStuckFloor))
        print(branch.mode .. "_time_to_100_hours=" .. stableScalar(branch.timeTo100Hours))
        print(branch.mode .. "_soft_stuck_per_100_mean="
            .. stableScalar(branch.softStuckPer100Mean))
        print(branch.mode .. "_failures_before_clear_p99="
            .. stableScalar(branch.failuresBeforeClearP99))
        print(branch.mode .. "_upgrades_per_10_p50="
            .. stableScalar(branch.upgradesPer10P50))
        print(branch.mode .. "_power_ratio_p50=" .. stableScalar(branch.powerRatioP50))
    end
    return
end

ensureDirectory(options.out)

local matrix, matrixFailures = Simulator.RunKeyFloorMatrix(options)
local thresholds, thresholdFailures = Simulator.RunThresholdScenarios(options)
local floorInvariant = Simulator.CheckFloorInvariant()
local scaleInvariant = Simulator.CheckMatrixScaleInvariant()
local progression = Progression.Run({
    seed = options.seed,
    samples = options.progressionSamples,
    maxFloor = options.progressionMaxFloor,
    model = options.model,
})
local failures = {}
for _, failure in ipairs(matrixFailures) do failures[#failures + 1] = failure end
for _, failure in ipairs(thresholdFailures) do failures[#failures + 1] = failure end
for _, failure in ipairs(failures) do
    failure.powerEvaluatorVersion = matrix[1].powerEvaluatorVersion
    failure.rewardPolicyVersion = matrix[1].rewardPolicyVersion
    failure.rarityCatalogVersion = matrix[1].rarityCatalogVersion
    failure.towerRulesVersion = matrix[1].towerRulesVersion
    failure.rngAlgorithm = Simulator.RNG_ALGORITHM
    failure.replayCommand = "lua tests/simulation/run.lua --replay "
        .. failure.scenarioId .. " --trial-seed " .. failure.trialSeed
        .. " --model " .. failure.model
end

local progressionCohorts = progressionCohortRows(options, progression)
local progressionCheckpoints = decorateProgressionRows(
    progression.checkpoints, options, progression)
local progressionChapters = decorateProgressionRows(
    progression.chapters, options, progression)
local progressionFailures = decorateProgressionRows(
    progression.failureSeeds, options, progression)
for _, failure in ipairs(progressionFailures) do
    failure.replayCommand = "lua tests/simulation/run.lua --replay-progression "
        .. failure.cohortSeed .. " --progression-max-floor "
        .. progression.maxFloor .. " --model " .. progression.model
end

local report, passed, hardGateFailures, progressionGateFailures = buildReport(
    options, matrix, thresholds, failures, floorInvariant, scaleInvariant, progression)
writeCsv(pathJoin(options.out, OUTPUT_NAMES[1]), matrixColumns(), matrix)
writeCsv(pathJoin(options.out, OUTPUT_NAMES[2]), thresholdColumns(), thresholds)
writeCsv(pathJoin(options.out, OUTPUT_NAMES[3]), failureColumns(), failures)
writeCsv(pathJoin(options.out, OUTPUT_NAMES[4]),
    progressionCohortColumns(), progressionCohorts)
writeCsv(pathJoin(options.out, OUTPUT_NAMES[5]),
    progressionCheckpointColumns(), progressionCheckpoints)
writeCsv(pathJoin(options.out, OUTPUT_NAMES[6]),
    progressionChapterColumns(), progressionChapters)
writeCsv(pathJoin(options.out, OUTPUT_NAMES[7]),
    progressionFailureColumns(), progressionFailures)
writeFile(pathJoin(options.out, OUTPUT_NAMES[8]), report .. "\n")

print("tower balance simulation artifacts written")
print("effective_seed=" .. Simulator.NormalizeSeed(options.seed))
print("samples_per_cohort=" .. options.samples)
local independentCohortCount = 0
for _, row in ipairs(matrix) do
    if row.independentCohort then independentCohortCount = independentCohortCount + 1 end
end
print("matrix_rows=" .. #matrix .. " independent_cohorts=" .. independentCohortCount)
print("threshold_rows=" .. #thresholds)
print("retained_failure_seeds=" .. #failures)
print("progression_seed_pairs=" .. progression.samples)
print("progression_target_floor=" .. progression.maxFloor)
print("progression_cohort_rows=" .. #progressionCohorts)
print("progression_retained_failure_seeds=" .. #progressionFailures)
print("gate=" .. (passed and "PASS" or "FAIL"))

local commandPassed = passed
if options.quick then
    commandPassed = #hardGateFailures == 0
        and floorInvariant.meetsTarget
        and scaleInvariant.meetsTarget
end
print("command=" .. (commandPassed and "PASS" or "FAIL"))

if not commandPassed then
    local reasons = {}
    for _, row in ipairs(hardGateFailures) do
        reasons[#reasons + 1] = row.id .. "=" .. stableScalar(row.passRate)
            .. "<" .. stableScalar(row.targetPassRate)
    end
    if not floorInvariant.meetsTarget then reasons[#reasons + 1] = "displayed-power floor invariant" end
    if not scaleInvariant.meetsTarget then reasons[#reasons + 1] = "matrix scale invariant" end
    for _, row in ipairs(progressionGateFailures) do
        reasons[#reasons + 1] = row.id .. "=" .. row.status
            .. "(" .. stableScalar(row.value) .. ",n=" .. row.sampleCount
            .. "/" .. row.minimumSampleCount .. ")"
    end
    error("tower balance hard gate failed: " .. table.concat(reasons, ", "))
end
