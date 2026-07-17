local FakeGateway = require("integration.FakeGateway")
local GameEngine = require("server.domain.GameEngine")
local GameStateSchema = require("shared.GameStateSchema")
local PlayerProfileRepository = require("server.repositories.PlayerProfileRepository")
local PlayerProfileService = require("server.services.PlayerProfileService")
local StateFactory = require("server.domain.StateFactory")
local StateNormalizer = require("server.domain.StateNormalizer")
local TableUtils = require("server.domain.TableUtils")

local Spec = {}

local function AssertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function AssertTrue(value, message)
    if not value then error(message or "expected truthy value", 2) end
end

local function AssertDeepEqual(actual, expected, message)
    if not TableUtils.DeepEqual(actual, expected) then error(message or "tables differ", 2) end
end

local function NewStack(gateway, now)
    local clock = function() return now.value end
    local repository = PlayerProfileRepository.New({ gateway = gateway, clock = clock })
    local service = PlayerProfileService.New({ repository = repository, clock = clock })
    return repository, service
end

local function Load(service, userId)
    local result = nil
    service:Load(userId, function(value) result = value end)
    assert(result, "profile load did not complete")
    return result
end

local function Attach(service, userId, generation, state)
    service:Attach(userId, { id = "connection-" .. generation }, generation, { state = state })
    AssertTrue(service:MarkReady(userId, generation), "session did not become ready")
end

local function HasKind(operations, kind)
    for _, operation in ipairs(operations or {}) do
        if operation.kind == kind then return true end
    end
    return false
end

function Spec.FirstLoadCreatesScoreMoneyListAndItemProjection()
    local gateway = FakeGateway.New()
    local now = { value = 1000 }
    local repository, service = NewStack(gateway, now)
    local loaded = Load(service, 101)

    AssertTrue(loaded.ok and loaded.data.created, "first load should create a profile")
    AssertEqual(loaded.data.state.level, 21)
    AssertEqual(loaded.data.state.exp, 464)
    AssertEqual(loaded.data.state.equipped.pants, "eq-000010")
    AssertEqual(#loaded.data.state.inventory, 17)
    AssertEqual(loaded.data.state.consumables.healthPotion, 12)

    local initialCommit = gateway.commits[1]
    AssertTrue(initialCommit ~= nil, "initial profile did not use BatchCommit")
    local op = repository.gateway.CommitOperation
    AssertTrue(HasKind(initialCommit.operations, op.SCORE_SET), "initial transaction is missing Score")
    AssertTrue(HasKind(initialCommit.operations, op.MONEY_ADD), "initial transaction is missing Money")
    AssertTrue(HasKind(initialCommit.operations, op.LIST_ADD), "initial transaction is missing List")
    AssertEqual(#gateway.items, 1, "health potion Item projection was not created")
    AssertEqual(gateway.items[1].count, 12)

    local _, reloadedService = NewStack(gateway, now)
    local reloaded = Load(reloadedService, 101)
    AssertTrue(reloaded.ok and not reloaded.data.created, "second load should use persisted data")
    AssertEqual(reloaded.data.state.consumables.healthPotion, 12, "Item count was not restored")
    AssertEqual(#reloaded.data.state.inventory, 17, "List inventory was not restored")
end

function Spec.ApplyDoesNotPublishMemoryUntilCommitSucceeds()
    local gateway = FakeGateway.New()
    local now = { value = 2000 }
    local _, service = NewStack(gateway, now)
    local initial = StateFactory.Create(now.value)
    Attach(service, 202, 1, initial)

    gateway:DelayNextCommit()
    local completed = nil
    service:Apply(202, "grant currency", function(state, timestamp)
        return GameEngine.GrantCurrency(state, "gold", 25, timestamp)
    end, function(result) completed = result end)

    AssertEqual(completed, nil, "Apply completed before the cloud callback")
    AssertTrue(service:GetState(202) == initial, "session state changed before commit success")
    AssertEqual(service:GetState(202).gold, initial.gold)

    gateway:ResolveNextCommit(true)
    AssertTrue(completed and completed.ok, "successful cloud commit was not published")
    AssertEqual(service:GetState(202).gold, initial.gold + 25)
    AssertEqual(service:GetState(202).revision, initial.revision + 1)
end

function Spec.FailedCommitRollsBackMemoryInventoryAndListMapping()
    local gateway = FakeGateway.New()
    local now = { value = 3000 }
    local repository, service = NewStack(gateway, now)
    local initial = StateFactory.Create(now.value)
    Attach(service, 303, 1, initial)
    local before = TableUtils.DeepCopy(initial)

    gateway:FailNextCommit("WRITE_FAILED", "injected atomic failure")
    local completed = nil
    service:Apply(303, "grant equipment", function(state, timestamp)
        return GameEngine.GrantEquipment(state, {
            name = "rollback test weapon",
            slot = "weapon",
            rarity = "epic",
            atk = 999,
        }, timestamp)
    end, function(result) completed = result end)

    AssertTrue(completed and not completed.ok, "injected commit failure was not surfaced")
    AssertEqual(completed.code, "WRITE_FAILED")
    AssertDeepEqual(service:GetState(303), before, "session memory changed after cloud failure")
    AssertEqual(#service:GetState(303).inventory, #before.inventory)
    AssertEqual(repository.listIds[303] and repository.listIds[303]["eq-000018"], nil,
        "failed ListAdd leaked into repository mapping")
    AssertEqual(#gateway.lists, 0, "failed transaction changed fake cloud inventory")
end

function Spec.FailedApplyOnceDoesNotConsumeCommandId()
    local gateway = FakeGateway.New()
    local now = { value = 3500 }
    local _, service = NewStack(gateway, now)
    local initial = StateFactory.Create(now.value)
    Attach(service, 353, 1, initial)
    local commandId = "gm-apply-once-retry"

    gateway:FailNextCommit("WRITE_FAILED", "injected idempotent failure")
    local failed = nil
    service:ApplyOnce(353, commandId, "GM retry test", function(state, timestamp)
        return GameEngine.GrantCurrency(state, "gold", 31, timestamp)
    end, function(result) failed = result end)
    AssertTrue(failed and not failed.ok, "first idempotent commit should fail")
    AssertEqual(#service:GetState(353).appliedGmCommandIds, 0)
    AssertEqual(service:GetState(353).gold, initial.gold)

    local retried = nil
    service:ApplyOnce(353, commandId, "GM retry test", function(state, timestamp)
        return GameEngine.GrantCurrency(state, "gold", 31, timestamp)
    end, function(result) retried = result end)
    AssertTrue(retried and retried.ok and not retried.data.alreadyApplied,
        "retry after failed transaction did not apply")
    AssertEqual(service:GetState(353).gold, initial.gold + 31)
    AssertEqual(service:GetState(353).appliedGmCommandIds[1], commandId)
end

function Spec.ApplyOnceEquipmentReplayDoesNotDuplicateCloudList()
    local gateway = FakeGateway.New()
    local now = { value = 3600 }
    local repository, service = NewStack(gateway, now)
    local initial = StateFactory.Create(now.value)
    Attach(service, 363, 1, initial)
    local commandId = "gm-equipment-once"
    local mutatorCalls = 0
    local function grant(state, timestamp)
        mutatorCalls = mutatorCalls + 1
        return GameEngine.GrantEquipment(state, {
            name = "idempotent equipment",
            slot = "weapon",
            rarity = "epic",
            atk = 777,
        }, timestamp)
    end

    local first = nil
    service:ApplyOnce(363, commandId, "GM equipment once", grant, function(result) first = result end)
    AssertTrue(first and first.ok and not first.data.alreadyApplied, "equipment grant did not apply")
    AssertEqual(#service:GetState(363).inventory, #initial.inventory + 1)
    AssertEqual(#gateway.lists, 1)

    local operations = gateway.commits[#gateway.commits].operations
    local markerInProfile, listAddInCommit = false, false
    for _, operation in ipairs(operations) do
        if operation.kind == repository.gateway.CommitOperation.SCORE_SET
            and operation.key == repository.Keys.PROFILE
        then
            local ids = operation.value.appliedGmCommandIds or {}
            markerInProfile = ids[#ids] == commandId
        elseif operation.kind == repository.gateway.CommitOperation.LIST_ADD then
            listAddInCommit = true
        end
    end
    AssertTrue(markerInProfile and listAddInCommit,
        "equipment marker and ListAdd were not committed atomically")

    local commitCount = #gateway.commits
    local replay = nil
    service:ApplyOnce(363, commandId, "GM equipment once", grant, function(result) replay = result end)
    AssertTrue(replay and replay.ok and replay.data.alreadyApplied, "equipment replay was not deduplicated")
    AssertEqual(mutatorCalls, 1, "equipment mutator ran during replay")
    AssertEqual(#service:GetState(363).inventory, #initial.inventory + 1)
    AssertEqual(#gateway.lists, 1, "equipment replay added a second cloud row")
    AssertEqual(#gateway.commits, commitCount, "equipment replay opened another transaction")
end

function Spec.TouchDetachPersistsOnlyCurrentGeneration()
    local gateway = FakeGateway.New()
    local now = { value = 4000 }
    local _, service = NewStack(gateway, now)
    local initial = StateFactory.Create(now.value)
    Attach(service, 404, 7, initial)

    now.value = 4015
    gateway:DelayNextCommit()
    local completed = nil
    service:TouchAndDetach(404, 7, function(result) completed = result end)
    AssertTrue(service:GetSession(404) ~= nil, "session detached before checkpoint callback")
    gateway:ResolveNextCommit(true)

    AssertTrue(completed and completed.ok and completed.data.persisted, "disconnect checkpoint failed")
    AssertEqual(service:GetSession(404), nil, "current generation was not detached")
    AssertEqual(gateway.scores["404"].abyss_profile.lastActiveAt, 4015)

    local replacement = StateFactory.Create(4020)
    Attach(service, 404, 8, replacement)
    local stale = nil
    service:TouchAndDetach(404, 7, function(result) stale = result end)
    AssertTrue(stale and stale.ok and stale.data.stale, "old disconnect was not classified as stale")
    AssertTrue(service:GetSession(404) ~= nil, "old generation detached the replacement session")
end

function Spec.AppliedGmCommandHistoryIsBoundedAndNotInSnapshot()
    local state = StateFactory.Create(5000)
    state.appliedGmCommandIds = {}
    for index = 1, 70 do
        state.appliedGmCommandIds[#state.appliedGmCommandIds + 1] = "gm-history-" .. index
    end
    state.appliedGmCommandIds[#state.appliedGmCommandIds + 1] = "gm-history-70"

    local normalized = StateNormalizer.Normalize(state, 5000)
    AssertEqual(#normalized.appliedGmCommandIds, GameStateSchema.MAX_APPLIED_GM_COMMANDS)
    AssertEqual(normalized.appliedGmCommandIds[1], "gm-history-7")
    AssertEqual(normalized.appliedGmCommandIds[#normalized.appliedGmCommandIds], "gm-history-70")
    AssertTrue(GameStateSchema.ValidateState(normalized), "bounded command history is invalid")

    local snapshot = GameStateSchema.BuildSnapshot(normalized, { serverTime = 5000 })
    AssertEqual(snapshot.appliedGmCommandIds, nil, "server idempotency history leaked into snapshot")
end

return Spec
