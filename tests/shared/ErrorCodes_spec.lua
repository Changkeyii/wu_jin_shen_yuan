local ErrorCodes = require("shared.ErrorCodes")

local Spec = {}

function Spec.Run()
    local err = ErrorCodes.Make(ErrorCodes.INVALID_PAYLOAD, nil, { path = "$.value" })
    assert(err.ok == false)
    assert(err.code == ErrorCodes.INVALID_PAYLOAD)
    assert(err.details.path == "$.value")
    assert(ErrorCodes.IsError(err))

    local success = ErrorCodes.Success({ value = 7 })
    assert(success.ok == true)
    assert(success.code == ErrorCodes.OK)
    assert(success.data.value == 7)
end

return Spec
