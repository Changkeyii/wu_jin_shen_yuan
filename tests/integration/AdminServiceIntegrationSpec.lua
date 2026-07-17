local AdminPolicy = require("server.core.AdminPolicy")
local AdminService = require("server.services.AdminService")
local FakeGateway = require("integration.FakeGateway")
local OperationQueue = require("server.core.OperationQueue")
local PlayerProfileRepository = require("server.repositories.PlayerProfileRepository")
local PlayerProfileService = require("server.services.PlayerProfileService")
local StateFactory = require("server.domain.StateFactory")

local Spec = {}
local ADMIN_UID = 1379670410

local function AssertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function AssertTrue(value, message)
    if not value then error(message or "expected truthy value", 2) end
end

local function NewProfileStack(gateway, now)
    local clock = function() return now.value end
    local repository = PlayerProfileRepository.New({ gateway = gateway, clock = clock })
    local profiles = PlayerProfileService.New({ repository = repository, clock = clock })
    return repository, profiles
end

local function Attach(profiles, userId, generation, now, state)
    profiles:Attach(userId, { id = "connection-" .. tostring(userId) }, generation, {
        state = state or StateFactory.Create(now),
    })
    assert(profiles:MarkReady(userId, generation))
end

local function LoadAndAttach(profiles, userId, generation, now)
    local loaded = nil
    profiles:Load(userId, function(result) loaded = result end)
    assert(loaded and loaded.ok, "profile did not load")
    Attach(profiles, userId, generation, now, loaded.data.state)
    return loaded.data.state
end

local function NewAdminService(options)
    local delivered = options.delivered or {}
    local service = AdminService.New({
        gateway = options.gateway,
        repository = options.repository,
        profileService = options.profiles,
        operationQueue = OperationQueue.New(),
        adminPolicy = options.policy,
        clock = function() return options.now.value end,
        onDelta = options.onDelta,
        instanceNonce = options.instanceNonce,
        commandIdFactory = options.commandIdFactory,
        onAdminResult = function(actorUserId, result)
            delivered[#delivered + 1] = { actorUserId = actorUserId, result = result }
        end,
    })
    return service, delivered
end

function Spec.NonAdminCannotExecuteGMCommand()
    local gateway = FakeGateway.New()
    local now = { value = 5000 }
    local repository, profiles = NewProfileStack(gateway, now)
    local policy = AdminPolicy.New({ adminUserIds = { ADMIN_UID } })
    local admin = NewAdminService({
        gateway = gateway,
        repository = repository,
        profiles = profiles,
        policy = policy,
        now = now,
    })

    local result = nil
    admin:Execute(999, "grant_currency", {
        targetUid = "123",
        currency = "gold",
        amount = 1,
        reason = "unauthorized test",
    }, function(value) result = value end)

    AssertTrue(result and not result.ok, "ordinary player GM request was accepted")
    AssertEqual(result.code, "FORBIDDEN")
    AssertEqual(#gateway.messages, 0, "forbidden request reached the message bus")
end

function Spec.OnlineTargetIsAppliedImmediately()
    local gateway = FakeGateway.New()
    local now = { value = 6000 }
    local repository, profiles = NewProfileStack(gateway, now)
    Attach(profiles, 606, 1, now.value)
    local policy = AdminPolicy.New({ adminUserIds = { ADMIN_UID } })
    local deltas = {}
    local admin = NewAdminService({
        gateway = gateway,
        repository = repository,
        profiles = profiles,
        policy = policy,
        now = now,
        onDelta = function(userId, delta) deltas[#deltas + 1] = { userId = userId, delta = delta } end,
    })
    local beforeGold = profiles:GetState(606).gold
    local result = nil
    admin:Execute(ADMIN_UID, "grant_currency", {
        targetUid = "606",
        currency = "gold",
        amount = 77,
        reason = "online integration test",
    }, function(value) result = value end)

    AssertTrue(result and result.ok, "online GM mutation failed")
    AssertEqual(result.data.status, "applied")
    AssertEqual(profiles:GetState(606).gold, beforeGold + 77)
    AssertEqual(#deltas, 1, "online mutation did not push a delta")
    AssertEqual(#gateway.messages, 0, "online mutation was unnecessarily queued")
end

function Spec.OfflineQueuedCommandReturnsAppliedResultToAdminInstance()
    local gateway = FakeGateway.New()
    local now = { value = 7000 }
    local policy = AdminPolicy.New({ adminUserIds = { ADMIN_UID } })

    local actorRepository, actorProfiles = NewProfileStack(gateway, now)
    Attach(actorProfiles, ADMIN_UID, 1, now.value)
    local actorAdmin, delivered = NewAdminService({
        gateway = gateway,
        repository = actorRepository,
        profiles = actorProfiles,
        policy = policy,
        now = now,
    })

    local queued = nil
    actorAdmin:Execute(ADMIN_UID, "grant_currency", {
        targetUid = "707",
        currency = "gold",
        amount = 88,
        reason = "cross instance integration test",
    }, function(value) queued = value end)
    AssertTrue(queued and queued.ok, "offline command was not queued")
    AssertEqual(queued.data.status, "queued")

    local targetRepository, targetProfiles = NewProfileStack(gateway, now)
    Attach(targetProfiles, 707, 3, now.value)
    local targetBefore = targetProfiles:GetState(707).gold
    local targetAdmin = NewAdminService({
        gateway = gateway,
        repository = targetRepository,
        profiles = targetProfiles,
        policy = policy,
        now = now,
    })

    targetAdmin:Update(5)
    AssertEqual(targetProfiles:GetState(707).gold, targetBefore + 88,
        "target authority did not apply queued command")

    actorAdmin:Update(5)
    AssertEqual(#delivered, 1, "administrator instance did not consume GM_RESULT")
    AssertEqual(delivered[1].actorUserId, ADMIN_UID)
    AssertEqual(delivered[1].result.commandId, queued.data.commandId)
    AssertEqual(delivered[1].result.status, "applied")
    AssertTrue(delivered[1].result.ok, "applied result was reported as rejected")

    local statuses = {}
    for _, row in ipairs(gateway.lists) do
        if row.key == actorRepository.Keys.ADMIN_AUDIT then statuses[row.value.status] = true end
    end
    AssertTrue(statuses.queued and statuses.applied, "queued/applied audit trail is incomplete")
end

function Spec.QueuedCommandReplayAfterCrashIsExactlyOnce()
    local gateway = FakeGateway.New()
    local now = { value = 8000 }
    local policy = AdminPolicy.New({ adminUserIds = { ADMIN_UID } })

    local targetRepository, targetProfiles = NewProfileStack(gateway, now)
    LoadAndAttach(targetProfiles, 808, 1, now.value)
    local initialGold = targetProfiles:GetState(808).gold

    local actorRepository, actorProfiles = NewProfileStack(gateway, now)
    local actorAdmin = NewAdminService({
        gateway = gateway,
        repository = actorRepository,
        profiles = actorProfiles,
        policy = policy,
        now = now,
    })
    local queued = nil
    actorAdmin:Execute(ADMIN_UID, "grant_currency", {
        targetUid = "808",
        currency = "gold",
        amount = 99,
        reason = "exactly once crash test",
    }, function(value) queued = value end)
    AssertTrue(queued and queued.ok, "GM command was not queued")

    local firstTargetAdmin = NewAdminService({
        gateway = gateway,
        repository = targetRepository,
        profiles = targetProfiles,
        policy = policy,
        now = now,
    })
    gateway:PersistNextCommitWithoutCallback()
    local firstAttempt = nil
    firstTargetAdmin:ProcessInbox(808, function(value) firstAttempt = value end)

    AssertEqual(firstAttempt, nil, "simulated crashed instance unexpectedly completed its callback")
    AssertEqual(targetProfiles:GetState(808).gold, initialGold,
        "crashed instance published memory without receiving the cloud callback")
    local commandMessage = nil
    for _, message in ipairs(gateway.messages) do
        if message.key == targetRepository.Keys.GM_COMMAND then commandMessage = message; break end
    end
    AssertTrue(commandMessage and not commandMessage.read, "failed result send acknowledged the command")
    local commitsAfterFirstApply = #gateway.commits
    local gmCommit = gateway.commits[commitsAfterFirstApply]
    local markerInProfile = false
    local moneyInCommit = false
    for _, operation in ipairs(gmCommit.operations) do
        if operation.kind == targetRepository.gateway.CommitOperation.SCORE_SET
            and operation.key == targetRepository.Keys.PROFILE
        then
            local ids = operation.value.appliedGmCommandIds or {}
            markerInProfile = ids[#ids] == queued.data.commandId
        elseif operation.kind == targetRepository.gateway.CommitOperation.MONEY_ADD
            and operation.key == targetRepository.Keys.GOLD
            and operation.amount == 99
        then
            moneyInCommit = true
        end
    end
    AssertTrue(markerInProfile and moneyInCommit,
        "GM command marker and currency mutation were not in the same BatchCommit")

    local recoveredRepository, recoveredProfiles = NewProfileStack(gateway, now)
    LoadAndAttach(recoveredProfiles, 808, 2, now.value)
    AssertEqual(recoveredProfiles:GetState(808).gold, initialGold + 99,
        "committed currency was not restored after instance recovery")

    local recoveredTargetAdmin = NewAdminService({
        gateway = gateway,
        repository = recoveredRepository,
        profiles = recoveredProfiles,
        policy = policy,
        now = now,
    })
    local replay = nil
    recoveredTargetAdmin:ProcessInbox(808, function(value) replay = value end)

    AssertTrue(replay and replay.ok, "replayed command did not complete")
    AssertEqual(replay.data.status, "alreadyApplied")
    AssertEqual(replay.data.alreadyApplied, 1)
    AssertEqual(recoveredProfiles:GetState(808).gold, initialGold + 99,
        "replayed command granted currency twice")
    AssertEqual(#gateway.commits, commitsAfterFirstApply,
        "already-applied command opened another player transaction")
    AssertTrue(commandMessage.read, "replayed command was not acknowledged")

    local appliedIds = recoveredProfiles:GetState(808).appliedGmCommandIds
    AssertEqual(appliedIds[#appliedIds], queued.data.commandId)
    local occurrences = 0
    for _, commandId in ipairs(appliedIds) do
        if commandId == queued.data.commandId then occurrences = occurrences + 1 end
    end
    AssertEqual(occurrences, 1, "command id was persisted more than once")

    local gmResult = nil
    for _, message in ipairs(gateway.messages) do
        if message.key == recoveredRepository.Keys.GM_RESULT then gmResult = message; break end
    end
    AssertTrue(gmResult ~= nil, "recovered instance did not return GM_RESULT")
    AssertEqual(gmResult.value.status, "alreadyApplied")
    AssertTrue(gmResult.value.alreadyApplied, "GM_RESULT did not identify the replay")
    AssertEqual(gmResult.value.commandId, queued.data.commandId)
end

function Spec.CommandIdsIncludePerInstanceNonce()
    local gateway = FakeGateway.New()
    local now = { value = 9000 }
    local policy = AdminPolicy.New({ adminUserIds = { ADMIN_UID } })
    local repository, profiles = NewProfileStack(gateway, now)
    local firstAdmin = NewAdminService({
        gateway = gateway,
        repository = repository,
        profiles = profiles,
        policy = policy,
        now = now,
        instanceNonce = "instance-a",
    })
    local secondAdmin = NewAdminService({
        gateway = gateway,
        repository = repository,
        profiles = profiles,
        policy = policy,
        now = now,
        instanceNonce = "instance-b",
    })
    local first, second = nil, nil
    local payload = {
        targetUid = "909",
        currency = "gold",
        amount = 1,
        reason = "command id uniqueness test",
    }
    firstAdmin:Execute(ADMIN_UID, "grant_currency", payload, function(value) first = value end)
    secondAdmin:Execute(ADMIN_UID, "grant_currency", payload, function(value) second = value end)

    AssertTrue(first and first.ok and second and second.ok, "commands were not queued")
    AssertTrue(first.data.commandId ~= second.data.commandId,
        "different server instances allocated the same command id")

    local targetRepository, targetProfiles = NewProfileStack(gateway, now)
    Attach(targetProfiles, 909, 1, now.value)
    local goldBefore = targetProfiles:GetState(909).gold
    local targetAdmin = NewAdminService({
        gateway = gateway,
        repository = targetRepository,
        profiles = targetProfiles,
        policy = policy,
        now = now,
        instanceNonce = "target-instance",
    })
    local processed = nil
    targetAdmin:ProcessInbox(909, function(value) processed = value end)
    AssertTrue(processed and processed.ok, "target did not process both instance commands")
    AssertEqual(processed.data.applied, 2)
    AssertEqual(targetProfiles:GetState(909).gold, goldBefore + 2,
        "distinct command ids incorrectly suppressed one another")

    local seen = {}
    for _, commandId in ipairs(targetProfiles:GetState(909).appliedGmCommandIds) do
        seen[commandId] = true
    end
    AssertTrue(seen[first.data.commandId] and seen[second.data.commandId],
        "both instance command ids were not persisted")
end

return Spec
