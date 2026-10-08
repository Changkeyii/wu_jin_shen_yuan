local OperationQueue = require("server.core.OperationQueue")

local Spec = {}

function Spec.Run()
    local queue = OperationQueue.New()
    local order = {}
    local releaseFirst = nil
    local firstResult = nil
    local secondResult = nil

    queue:Enqueue(1, {
        async = true,
        run = function(done)
            order[#order + 1] = "first"
            releaseFirst = done
            return OperationQueue.PENDING
        end,
        onComplete = function(ok, result)
            assert(ok)
            firstResult = result
        end,
    })
    queue:Enqueue(1, {
        async = false,
        run = function()
            order[#order + 1] = "second"
            return "second-result"
        end,
        onComplete = function(ok, result)
            assert(ok)
            secondResult = result
        end,
    })
    queue:Enqueue(2, {
        async = false,
        run = function()
            order[#order + 1] = "other-user"
            return true
        end,
    })

    assert(#order == 2)
    assert(order[1] == "first" and order[2] == "other-user")
    assert(queue:PendingCount(1) == 2)
    releaseFirst(true, "first-result")
    assert(order[3] == "second")
    assert(firstResult == "first-result")
    assert(secondResult == "second-result")
    assert(queue:PendingCount(1) == 0)

    local reportedError = nil
    local recoveryRan = false
    local failureQueue = OperationQueue.New({
        onError = function(reason) reportedError = reason end,
    })
    failureQueue:Enqueue(3, {
        async = false,
        run = function() error("expected failure") end,
    })
    failureQueue:Enqueue(3, {
        async = false,
        run = function() recoveryRan = true; return true end,
    })
    assert(reportedError and string.match(reportedError, "expected failure"))
    assert(recoveryRan)
end

return Spec
