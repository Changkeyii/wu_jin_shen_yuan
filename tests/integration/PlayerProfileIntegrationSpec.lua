local FakeGateway = require("integration.FakeGateway")
local GameEngine = require("server.domain.GameEngine")
local GameStateSchema = require("shared.GameStateSchema")
local LargeNumber = require("shared.LargeNumber")
local Catalog = require("server.domain.Catalog")
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

local function AssertLargeEqual(actual, expected, message)
    if LargeNumber.Compare(actual, expected) ~= 0 then
        error((message or "large numbers differ")
            .. ": expected " .. LargeNumber.ToString(expected)
            .. ", got " .. LargeNumber.ToString(actual), 2)
    end
end

local function EquipmentDefinition(slot)
    for _, definition in ipairs(Catalog.EQUIPMENT_DEFINITIONS) do
        if definition.slot == slot then return definition end
    end
    error("missing equipment definition for slot " .. tostring(slot), 2)
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

local function HasScoreInt(operations, kind, key, value)
    for _, operation in ipairs(operations or {}) do
        if operation.kind == kind and operation.key == key and operation.value == value then
            return true
        end
    end
    return false
end

function Spec.FirstLoadCreatesV5ProfileAndStarterLoadoutProjection()
    local gateway = FakeGateway.New()
    local now = { value = 1000 }
    local repository, service = NewStack(gateway, now)
    local loaded = Load(service, 101)

    AssertTrue(loaded.ok and loaded.data.created, "first load should create a profile")
    AssertEqual(loaded.data.state.schemaVersion, 5)
    AssertEqual(loaded.data.state.level, 1)
    AssertEqual(loaded.data.state.exp, 0)
    AssertEqual(loaded.data.state.floor, 1)
    AssertEqual(#loaded.data.state.inventory, 12)
    AssertEqual(loaded.data.state.consumables.healthPotion, 0)
    for _, slot in ipairs(GameStateSchema.SLOTS) do
        AssertTrue(loaded.data.state.equipped[slot] ~= nil, "starter slot is not equipped: " .. slot)
    end
    for _, item in ipairs(loaded.data.state.inventory) do
        AssertEqual(item.rarity, "rare", "starter equipment must use the V5 rare baseline")
        AssertEqual(item.statVersion, 5, "starter equipment must preserve rolled V5 stats")
    end
    AssertTrue(GameStateSchema.ValidateState(loaded.data.state), "created V5 state is invalid")

    local initialCommit = gateway.commits[1]
    AssertTrue(initialCommit ~= nil, "initial profile did not use BatchCommit")
    local op = repository.gateway.CommitOperation
    AssertTrue(HasKind(initialCommit.operations, op.SCORE_SET), "initial transaction is missing Score")
    for _, key in ipairs({
        repository.Keys.GOLD_HIGH, repository.Keys.GOLD_MID, repository.Keys.GOLD_LOW,
        repository.Keys.FRAGMENTS_HIGH, repository.Keys.FRAGMENTS_MID, repository.Keys.FRAGMENTS_LOW,
        repository.Keys.MYTH_SHARDS_HIGH, repository.Keys.MYTH_SHARDS_MID, repository.Keys.MYTH_SHARDS_LOW,
    }) do
        AssertTrue(HasScoreInt(initialCommit.operations, op.SCORE_SET_INT, key, 0),
            "initial transaction is missing zeroed currency segment: " .. key)
    end
    AssertTrue(HasKind(initialCommit.operations, op.LIST_ADD), "initial transaction is missing List")
    AssertEqual(#gateway.lists, 12, "starter loadout was not projected to the cloud list")
    AssertEqual(#gateway.items, 0, "zero-count consumables should not create cloud items")

    local _, reloadedService = NewStack(gateway, now)
    local reloaded = Load(reloadedService, 101)
    AssertTrue(reloaded.ok and not reloaded.data.created, "second load should use persisted data")
    AssertEqual(reloaded.data.state.consumables.healthPotion, 0, "Item count was not restored")
    AssertEqual(#reloaded.data.state.inventory, 12, "starter inventory was not restored")
    AssertDeepEqual(reloaded.data.state.equipped, loaded.data.state.equipped,
        "starter equipment mapping was not restored")
    AssertTrue(GameStateSchema.ValidateState(reloaded.data.state), "reloaded V5 state is invalid")
end

function Spec.CorruptV5BigNumbersAreRejectedBeforeNormalization()
    local gateway = FakeGateway.New()
    local now = { value = 1500 }
    local _, service = NewStack(gateway, now)
    local created = Load(service, 151)
    AssertTrue(created.ok and created.data.created)

    local commitsBeforeReload = #gateway.commits
    gateway.lists[1].value.atkBig = nil
    local _, reloadedService = NewStack(gateway, now)
    local corrupted = Load(reloadedService, 151)
    AssertTrue(not corrupted.ok)
    AssertEqual(corrupted.code, "CORRUPT_INVENTORY")
    AssertTrue(string.find(corrupted.reason, "inventory%[1%]%.atkBig") ~= nil)
    AssertEqual(#gateway.commits, commitsBeforeReload,
        "corrupt V5 data must be rejected without a normalization writeback")
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
    AssertLargeEqual(service:GetState(202).gold, initial.gold)

    gateway:ResolveNextCommit(true)
    AssertTrue(completed and completed.ok, "successful cloud commit was not published")
    AssertLargeEqual(service:GetState(202).gold, LargeNumber.Add(initial.gold, 25))
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
    local definition = EquipmentDefinition("weapon")
    service:Apply(303, "grant equipment", function(state, timestamp)
        return GameEngine.GrantEquipment(state, {
            equipmentId = definition.id,
            rarity = "epic",
        }, timestamp)
    end, function(result) completed = result end)

    AssertTrue(completed and not completed.ok, "injected commit failure was not surfaced")
    AssertEqual(completed.code, "WRITE_FAILED")
    AssertDeepEqual(service:GetState(303), before, "session memory changed after cloud failure")
    AssertEqual(#service:GetState(303).inventory, #before.inventory)
    AssertTrue(repository.listIds[303] == nil or next(repository.listIds[303]) == nil,
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
    AssertLargeEqual(service:GetState(353).gold, initial.gold)

    local retried = nil
    service:ApplyOnce(353, commandId, "GM retry test", function(state, timestamp)
        return GameEngine.GrantCurrency(state, "gold", 31, timestamp)
    end, function(result) retried = result end)
    AssertTrue(retried and retried.ok and not retried.data.alreadyApplied,
        "retry after failed transaction did not apply")
    AssertLargeEqual(service:GetState(353).gold, LargeNumber.Add(initial.gold, 31))
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
    local definition = EquipmentDefinition("weapon")
    local function grant(state, timestamp)
        mutatorCalls = mutatorCalls + 1
        return GameEngine.GrantEquipment(state, {
            equipmentId = definition.id,
            rarity = "epic",
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

function Spec.OfflineQuoteClaimIsStableAndIdempotent()
    local gateway = FakeGateway.New()
    local now = { value = 6000 }
    local _, service = NewStack(gateway, now)
    local initial = StateFactory.Create(now.value)
    initial.pendingStoryGate = nil
    initial.pendingOfflineSeconds = Catalog.OFFLINE_STEP_SECONDS * 4
    Attach(service, 606, 1, initial)

    local preview = nil
    service:PreviewOffline(606, function(result) preview = result end)
    AssertTrue(preview and preview.ok, "offline preview failed")
    AssertTrue(type(preview.data.quoteToken) == "string")
    AssertTrue(type(preview.data.preview) == "table")
    AssertEqual(service:GetState(606).revision, initial.revision,
        "offline preview must not mutate session revision")

    local first = nil
    service:ClaimOffline(606, preview.data.quoteToken, function(result) first = result end)
    AssertTrue(first and first.ok, "offline quote claim failed")
    local committedRevision = service:GetState(606).revision
    local commitCount = #gateway.commits

    local replay = nil
    service:ClaimOffline(606, preview.data.quoteToken, function(result) replay = result end)
    AssertTrue(replay and replay.ok, "offline quote replay should return the success receipt")
    AssertEqual(service:GetState(606).revision, committedRevision,
        "offline quote replay advanced revision")
    AssertEqual(#gateway.commits, commitCount,
        "offline quote replay opened another transaction")
end

function Spec.OfflineQuoteExpiresAndBecomesStale()
    local gateway = FakeGateway.New()
    local now = { value = 7000 }
    local _, service = NewStack(gateway, now)
    local initial = StateFactory.Create(now.value)
    initial.pendingStoryGate = nil
    initial.pendingOfflineSeconds = Catalog.OFFLINE_STEP_SECONDS * 3
    Attach(service, 707, 1, initial)

    local preview = nil
    service:PreviewOffline(707, function(result) preview = result end)
    AssertTrue(preview and preview.ok)
    now.value = preview.data.expiresAt
    local expired = nil
    service:ClaimOffline(707, preview.data.quoteToken, function(result) expired = result end)
    AssertTrue(expired and not expired.ok)
    AssertEqual(expired.code, "OFFLINE_QUOTE_EXPIRED")

    now.value = 7100
    local freshPreview = nil
    service:PreviewOffline(707, function(result) freshPreview = result end)
    AssertTrue(freshPreview and freshPreview.ok)
    service:GetState(707).revision = service:GetState(707).revision + 1
    local stale = nil
    service:ClaimOffline(707, freshPreview.data.quoteToken, function(result) stale = result end)
    AssertTrue(stale and not stale.ok)
    AssertEqual(stale.code, "STALE_OFFLINE_QUOTE")
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
