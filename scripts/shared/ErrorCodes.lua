local ErrorCodes = {
    OK = "OK",
    INVALID_REQUEST = "INVALID_REQUEST",
    INVALID_REQUEST_ID = "INVALID_REQUEST_ID",
    REQUEST_ID_REUSED = "REQUEST_ID_REUSED",
    REQUEST_IN_PROGRESS = "REQUEST_IN_PROGRESS",
    REQUEST_TIMEOUT = "REQUEST_TIMEOUT",
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
    SERVER_BUSY = "SERVER_BUSY",
    NOT_FOUND = "NOT_FOUND",
    INVENTORY_FULL = "INVENTORY_FULL",
    REVISION_CONFLICT = "REVISION_CONFLICT",
    INVALID_STATE = "INVALID_STATE",
    CLOUD_UNAVAILABLE = "CLOUD_UNAVAILABLE",
    CLOUD_ERROR = "CLOUD_ERROR",
    OPERATION_FAILED = "OPERATION_FAILED",
    INTERNAL_ERROR = "INTERNAL_ERROR",
    LISTING_NOT_FOUND = "LISTING_NOT_FOUND",
    LISTING_GONE = "LISTING_GONE",
    LISTING_CONTESTED = "LISTING_CONTESTED",
    LISTING_SLOTS_FULL = "LISTING_SLOTS_FULL",
    RARITY_NOT_LISTABLE = "RARITY_NOT_LISTABLE",
    ITEM_NOT_TRADABLE = "ITEM_NOT_TRADABLE",
    INVALID_PRICE = "INVALID_PRICE",
    PRICE_BELOW_MINIMUM = "PRICE_BELOW_MINIMUM",
    EVENT_DECISION_PENDING = "EVENT_DECISION_PENDING",
    INVALID_EVENT_ACTION = "INVALID_EVENT_ACTION",
    STALE_EVENT = "STALE_EVENT",
    LEVEL_GATE_BLOCKED = "LEVEL_GATE_BLOCKED",
    INSUFFICIENT_GOLD = "INSUFFICIENT_GOLD",
    SELF_PURCHASE = "SELF_PURCHASE",
    MAILBOX_FULL = "MAILBOX_FULL",
}

local DESCRIPTIONS = {
    [ErrorCodes.OK] = "Success",
    [ErrorCodes.INVALID_REQUEST] = "The request envelope is invalid",
    [ErrorCodes.INVALID_REQUEST_ID] = "The request id is invalid",
    [ErrorCodes.REQUEST_ID_REUSED] = "The request id was already used for different content",
    [ErrorCodes.REQUEST_IN_PROGRESS] = "The request is already being processed",
    [ErrorCodes.REQUEST_TIMEOUT] = "The server did not respond before the request deadline",
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
    [ErrorCodes.SERVER_BUSY] = "The server is busy",
    [ErrorCodes.NOT_FOUND] = "The requested resource was not found",
    [ErrorCodes.INVENTORY_FULL] = "The inventory is full",
    [ErrorCodes.REVISION_CONFLICT] = "The state revision is stale",
    [ErrorCodes.INVALID_STATE] = "The authoritative state is invalid",
    [ErrorCodes.CLOUD_UNAVAILABLE] = "The cloud service is unavailable",
    [ErrorCodes.CLOUD_ERROR] = "The cloud operation failed",
    [ErrorCodes.OPERATION_FAILED] = "The operation failed",
    [ErrorCodes.INTERNAL_ERROR] = "An internal server error occurred",
    [ErrorCodes.LISTING_NOT_FOUND] = "挂单不存在",
    [ErrorCodes.LISTING_GONE] = "挂单已被买走或已下架",
    [ErrorCodes.LISTING_CONTESTED] = "已有其他玩家抢先购买",
    [ErrorCodes.LISTING_SLOTS_FULL] = "挂单数量已达上限",
    [ErrorCodes.RARITY_NOT_LISTABLE] = "仅神器及以上装备可以上架",
    [ErrorCodes.ITEM_NOT_TRADABLE] = "该装备不可交易或当前无法上架",
    [ErrorCodes.INVALID_PRICE] = "价格不合法",
    [ErrorCodes.PRICE_BELOW_MINIMUM] = "价格低于该装备的最低上架价",
    [ErrorCodes.EVENT_DECISION_PENDING] = "请先处理当前事件",
    [ErrorCodes.INVALID_EVENT_ACTION] = "该事件不支持此操作",
    [ErrorCodes.STALE_EVENT] = "事件已失效，请刷新",
    [ErrorCodes.LEVEL_GATE_BLOCKED] = "装备等级超出当前层数可购买范围",
    [ErrorCodes.INSUFFICIENT_GOLD] = "金币不足",
    [ErrorCodes.SELF_PURCHASE] = "不能购买自己的挂单",
    [ErrorCodes.MAILBOX_FULL] = "信箱已满，请先领取",
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
