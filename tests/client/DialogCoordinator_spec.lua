local Spec = {}

local MODULE_NAME = "client.DialogCoordinator"

local function FreshCoordinator()
    package.loaded[MODULE_NAME] = nil
    local coordinator = require(MODULE_NAME)
    if coordinator._ResetForTests then coordinator._ResetForTests() end
    return coordinator
end

local function AssertOrder(actual, expected, message)
    assert(#actual == #expected, (message or "order length mismatch")
        .. ": expected " .. tostring(#expected) .. ", got " .. tostring(#actual))
    for index, value in ipairs(expected) do
        assert(actual[index] == value, (message or "order mismatch")
            .. " at " .. tostring(index)
            .. ": expected " .. tostring(value)
            .. ", got " .. tostring(actual[index]))
    end
end

local function TestPriorityAndFifo()
    local Coordinator = FreshCoordinator()
    local presented = {}
    local completions = {}
    local callbacks = {}
    local dismissCount = 0

    local function Options(id, kind)
        return {
            id = id,
            kind = kind,
            queueKey = id,
            onConfirm = function(result)
                callbacks[#callbacks + 1] = id .. ":" .. result
            end,
            onCancel = function(result)
                callbacks[#callbacks + 1] = id .. ":" .. result
            end,
        }
    end

    assert(Coordinator.Enqueue(Options("confirm", "confirm")))
    assert(Coordinator.Enqueue(Options("rules", "rules")))
    assert(Coordinator.Enqueue(Options("equipment-a", "equipment")))
    assert(Coordinator.Enqueue(Options("story", "story")))
    assert(Coordinator.Enqueue(Options("equipment-b", "equipment_swap")))

    local accepted, reason = Coordinator.Enqueue(Options("confirm", "story"))
    assert(accepted == false and reason == "duplicate", "queued keys must be unique")

    Coordinator.Configure({
        present = function(options, complete)
            presented[#presented + 1] = options.id
            completions[#completions + 1] = complete
        end,
        dismiss = function()
            dismissCount = dismissCount + 1
        end,
    })

    assert(Coordinator.GetState().active.id == "story")
    assert(Coordinator.GetState().queued == 4)

    completions[1]("confirm")
    assert(Coordinator.GetState().active.id == "equipment-a")

    completions[1]("cancel")
    assert(Coordinator.GetState().active.id == "equipment-a",
        "a stale presenter callback must not complete the next dialog")

    assert(Coordinator.CancelActive())
    assert(Coordinator.GetState().active.id == "equipment-b")
    assert(Coordinator.ConfirmActive())
    assert(Coordinator.GetState().active.id == "rules")
    assert(Coordinator.ConfirmActive())
    assert(Coordinator.GetState().active.id == "confirm")
    assert(Coordinator.CancelActive())

    local state = Coordinator.GetState()
    assert(state.active == nil and state.queued == 0)
    assert(dismissCount == 5, "each completed dialog must dismiss exactly once")
    AssertOrder(presented, {
        "story",
        "equipment-a",
        "equipment-b",
        "rules",
        "confirm",
    }, "priority/FIFO presentation")
    AssertOrder(callbacks, {
        "story:confirm",
        "equipment-a:cancel",
        "equipment-b:confirm",
        "rules:confirm",
        "confirm:cancel",
    }, "completion callback order")
end

local function TestActiveDialogIsNotPreempted()
    local Coordinator = FreshCoordinator()
    local presented = {}

    Coordinator.Configure({
        present = function(options)
            presented[#presented + 1] = options.id
        end,
        dismiss = function() end,
    })

    assert(Coordinator.Enqueue({ id = "active-confirm", kind = "confirm", key = "active" }))
    assert(Coordinator.Enqueue({ id = "queued-story", kind = "story", key = "story" }))
    assert(Coordinator.GetState().active.id == "active-confirm",
        "a higher-priority dialog must wait for the active dialog")
    assert(Coordinator.GetState().queued == 1)

    local accepted, reason = Coordinator.Enqueue({ id = "duplicate-active", key = "active" })
    assert(accepted == false and reason == "duplicate", "active keys must be unique")

    assert(Coordinator.CancelActive())
    assert(Coordinator.GetState().active.id == "queued-story")
    AssertOrder(presented, { "active-confirm", "queued-story" }, "non-preemptive presentation")

    assert(Coordinator.ConfirmActive())
    assert(Coordinator.Enqueue({ id = "reused-key", kind = "confirm", key = "active" }),
        "a key must be reusable after its dialog completes")
    assert(Coordinator.GetState().active.id == "reused-key")
end

local function TestClearAndRemountLifecycle()
    local Coordinator = FreshCoordinator()
    local firstPresenterCalls = 0
    local secondPresenterCalls = 0
    local dismissCount = 0
    local activeCancelCount = 0
    local queuedCancelCount = 0

    Coordinator.Configure({
        present = function()
            firstPresenterCalls = firstPresenterCalls + 1
        end,
        dismiss = function()
            dismissCount = dismissCount + 1
        end,
    })

    assert(Coordinator.Enqueue({
        id = "active",
        kind = "confirm",
        onCancel = function()
            activeCancelCount = activeCancelCount + 1
        end,
    }))
    assert(Coordinator.Enqueue({
        id = "queued",
        kind = "story",
        onCancel = function()
            queuedCancelCount = queuedCancelCount + 1
        end,
    }))

    Coordinator.Configure({
        present = function(options)
            assert(options.id == "active")
            secondPresenterCalls = secondPresenterCalls + 1
        end,
        dismiss = function()
            dismissCount = dismissCount + 1
        end,
    })

    assert(firstPresenterCalls == 1)
    assert(secondPresenterCalls == 1, "the active dialog must be presented again after remount")
    assert(dismissCount == 1, "remount must dismiss the old presentation")

    Coordinator.Clear(true)
    assert(activeCancelCount == 1, "Clear(true) must cancel the active dialog")
    assert(queuedCancelCount == 0, "Clear must discard queued dialogs without callbacks")
    assert(dismissCount == 2)
    assert(Coordinator.GetState().active == nil and Coordinator.GetState().queued == 0)

    Coordinator.Clear(true)
    assert(activeCancelCount == 1, "clearing an empty coordinator must be idempotent")
end

local function TestExplicitPriorityAndPresenterFailure()
    local Coordinator = FreshCoordinator()
    local cancelled = {}
    local presented = {}
    local logged = {}

    assert(Coordinator.Priorities.story > Coordinator.Priorities.equipment)
    assert(Coordinator.Priorities.equipment > Coordinator.Priorities.rules)
    assert(Coordinator.Priorities.rules > Coordinator.Priorities.confirm)

    assert(Coordinator.Enqueue({
        id = "normal-story",
        kind = "story",
        onCancel = function() cancelled[#cancelled + 1] = "normal-story" end,
    }))
    assert(Coordinator.Enqueue({
        id = "explicit",
        kind = "confirm",
        priority = 999,
        onCancel = function() cancelled[#cancelled + 1] = "explicit" end,
    }))

    local oldPrint = print
    _G.print = function(message)
        logged[#logged + 1] = tostring(message)
    end
    local configured, configureReason = pcall(function()
        Coordinator.Configure({
            present = function(options)
                presented[#presented + 1] = options.id
                if options.id == "explicit" then error("simulated presenter failure") end
            end,
            dismiss = function() end,
        })
    end)
    _G.print = oldPrint
    assert(configured, configureReason)

    AssertOrder(presented, { "explicit", "normal-story" }, "explicit priority/failure recovery")
    AssertOrder(cancelled, { "explicit" }, "presenter failure cancellation")
    assert(#logged == 1 and logged[1]:find("present failed", 1, true),
        "presenter failures must be logged")
    assert(Coordinator.GetState().active.id == "normal-story",
        "a presenter failure must not block the remaining queue")
end

local function TestCancelByKey()
    local Coordinator = FreshCoordinator()
    local callbacks = {}

    Coordinator.Configure({
        present = function() end,
        dismiss = function() end,
    })

    assert(Coordinator.Enqueue({
        id = "active",
        queueKey = "active-key",
        onCancel = function() callbacks[#callbacks + 1] = "active" end,
    }))
    assert(Coordinator.Enqueue({
        id = "queued",
        queueKey = "queued-key",
        onCancel = function() callbacks[#callbacks + 1] = "queued" end,
    }))

    assert(Coordinator.HasKey("active-key"))
    assert(Coordinator.HasKey("queued-key"))
    assert(Coordinator.HasKey("missing") == false)
    assert(Coordinator.CancelByKey("queued-key"), "queued dialog must be cancellable by key")
    assert(Coordinator.GetState().active.id == "active")
    assert(Coordinator.GetState().queued == 0)
    assert(callbacks[1] == "queued")
    assert(Coordinator.CancelByKey("active-key"), "active dialog must be cancellable by key")
    assert(Coordinator.GetState().active == nil)
    assert(callbacks[2] == "active")
    assert(Coordinator.CancelByKey("missing") == false)
end

function Spec.Run()
    local oldModule = package.loaded[MODULE_NAME]
    local ok, reason = pcall(function()
        TestPriorityAndFifo()
        TestActiveDialogIsNotPreempted()
        TestClearAndRemountLifecycle()
        TestExplicitPriorityAndPresenterFailure()
        TestCancelByKey()
    end)
    package.loaded[MODULE_NAME] = oldModule
    assert(ok, reason)
end

return Spec
