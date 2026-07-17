local ErrorCodes = {
    OK = "OK",
    INVALID_REQUEST = "INVALID_REQUEST",
    INVALID_REQUEST_ID = "INVALID_REQUEST_ID",
    REQUEST_ID_REUSED = "REQUEST_ID_REUSED",
    REQUEST_IN_PROGRESS = "REQUEST_IN_PROGRESS",
    PAYLOAD_TOO_LARGE = "PAYLOAD_TOO_LARGE",
    INVALID_JSON = "INVALID_JSON",
    INVALID_PAYLOAD = "INVALID_PAYLOAD",
    UNKNOWN_COMMAND = "UNKNOWN_COMMAND",
    RATE_LIMITED = "RATE_LIMITED",
    UNAUTHENTICATED = "UNAUTHENTICATED",
    STALE_SESSION = "STALE_SESSION",
    NOT_READY = "NOT_READY",
    FORBIDDEN = "FORBIDDEN",
    BANNED = "BANNED",
    CAPACITY_REACHED = "CAPACITY_REACHED",
    SERVER_BUSY = "SERVER_BUSY",
    NOT_FOUND = "NOT_FOUND",
    INVENTORY_FULL = "INVENTORY_FULL",
    REVISION_CONFLICT = "REVISION_CONFLICT",
    INVALID_STATE = "INVALID_STATE",
    CLOUD_UNAVAILABLE = "CLOUD_UNAVAILABLE",
    CLOUD_ERROR = "CLOUD_ERROR",
    OPERATION_FAILED = "OPERATION_FAILED",
    INTERNAL_ERROR = "INTERNAL_ERROR",
}

local DESCRIPTIONS = {
    [ErrorCodes.OK] = "Success",
    [ErrorCodes.INVALID_REQUEST] = "The request envelope is invalid",
    [ErrorCodes.INVALID_REQUEST_ID] = "The request id is invalid",
    [ErrorCodes.REQUEST_ID_REUSED] = "The request id was already used for different content",
    [ErrorCodes.REQUEST_IN_PROGRESS] = "The request is already being processed",
    [ErrorCodes.PAYLOAD_TOO_LARGE] = "The request payload exceeds the size limit",
    [ErrorCodes.INVALID_JSON] = "The request payload is not valid JSON",
    [ErrorCodes.INVALID_PAYLOAD] = "The request payload does not match the command schema",
    [ErrorCodes.UNKNOWN_COMMAND] = "The command is not registered",
    [ErrorCodes.RATE_LIMITED] = "Too many requests",
    [ErrorCodes.UNAUTHENTICATED] = "The connection is not authenticated",
    [ErrorCodes.STALE_SESSION] = "The connection was replaced by a newer session",
    [ErrorCodes.NOT_READY] = "The player session is not ready",
    [ErrorCodes.FORBIDDEN] = "The operation is not permitted",
    [ErrorCodes.BANNED] = "The player is banned",
    [ErrorCodes.CAPACITY_REACHED] = "The logical player capacity has been reached",
    [ErrorCodes.SERVER_BUSY] = "The server is busy",
    [ErrorCodes.NOT_FOUND] = "The requested resource was not found",
    [ErrorCodes.INVENTORY_FULL] = "The inventory is full",
    [ErrorCodes.REVISION_CONFLICT] = "The state revision is stale",
    [ErrorCodes.INVALID_STATE] = "The authoritative state is invalid",
    [ErrorCodes.CLOUD_UNAVAILABLE] = "The cloud service is unavailable",
    [ErrorCodes.CLOUD_ERROR] = "The cloud operation failed",
    [ErrorCodes.OPERATION_FAILED] = "The operation failed",
    [ErrorCodes.INTERNAL_ERROR] = "An internal server error occurred",
}

---@param code string|nil
---@return string
function ErrorCodes.Describe(code)
    return DESCRIPTIONS[code] or DESCRIPTIONS[ErrorCodes.INTERNAL_ERROR]
end

---@param code string
---@param reason string|nil
---@param details table|nil
---@return table
function ErrorCodes.Make(code, reason, details)
    local result = {
        ok = code == ErrorCodes.OK,
        code = code,
        reason = reason or ErrorCodes.Describe(code),
    }
    if details ~= nil then
        result.details = details
    end
    return result
end

---@param data any
---@return table
function ErrorCodes.Success(data)
    return {
        ok = true,
        code = ErrorCodes.OK,
        data = data,
    }
end

---@param value any
---@return boolean
function ErrorCodes.IsError(value)
    return type(value) == "table" and value.ok == false and type(value.code) == "string"
end

return ErrorCodes
