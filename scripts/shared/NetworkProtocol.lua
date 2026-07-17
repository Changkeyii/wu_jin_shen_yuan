local ErrorCodes = require("shared.ErrorCodes")

local NetworkProtocol = {}

NetworkProtocol.VERSION = 1
NetworkProtocol.MAX_PAYLOAD_BYTES = 16 * 1024
NetworkProtocol.MAX_REQUEST_ID_LENGTH = 96
NetworkProtocol.MAX_COMMAND_LENGTH = 64

NetworkProtocol.EVENTS = {
    CLIENT_READY = "AbyssClientReady",
    COMMAND = "AbyssCommand",
    RESPONSE = "AbyssResponse",
    SNAPSHOT = "AbyssSnapshot",
    DELTA = "AbyssDelta",
    STATUS = "AbyssStatus",
}

NetworkProtocol.FIELDS = {
    VERSION = "Version",
    REQUEST_ID = "RequestId",
    COMMAND = "Command",
    PAYLOAD_JSON = "PayloadJson",
}

NetworkProtocol.SERVER_EVENTS = {
    NetworkProtocol.EVENTS.CLIENT_READY,
    NetworkProtocol.EVENTS.COMMAND,
}

NetworkProtocol.CLIENT_EVENTS = {
    NetworkProtocol.EVENTS.RESPONSE,
    NetworkProtocol.EVENTS.SNAPSHOT,
    NetworkProtocol.EVENTS.DELTA,
    NetworkProtocol.EVENTS.STATUS,
}

local function makeError(code, reason, path)
    local details = nil
    if path ~= nil then
        details = { path = path }
    end
    return ErrorCodes.Make(code, reason, details)
end

local function resolveJsonFunction(explicit, name)
    if explicit then
        return explicit
    end

    local json = _G["cjson"]
    if json and type(json[name]) == "function" then
        return json[name]
    end

    local ok, required = pcall(require, "cjson")
    if ok and required and type(required[name]) == "function" then
        return required[name]
    end
    return nil
end

local function readRawField(eventData, fieldName)
    if eventData == nil then
        return nil
    end

    local okDirect, direct = pcall(function()
        return eventData[fieldName]
    end)
    if okDirect and (type(direct) == "string" or type(direct) == "number") then
        return direct
    end

    local okGetter, getterValue = pcall(function()
        if type(eventData.GetString) == "function" then
            return eventData:GetString(fieldName)
        end
        return nil
    end)
    if okGetter and getterValue ~= nil and getterValue ~= "" then
        return getterValue
    end

    if okDirect and direct ~= nil then
        local okVariant, variantValue = pcall(function()
            if type(direct.GetString) == "function" then
                return direct:GetString()
            end
            if type(direct.GetInt) == "function" then
                return direct:GetInt()
            end
            return nil
        end)
        if okVariant then
            return variantValue
        end
    end
    return nil
end

local function canonicalRequestField(request, lowerName, upperName)
    if type(request) ~= "table" then
        return nil
    end
    local value = request[lowerName]
    if value == nil then
        value = request[upperName]
    end
    return value
end

---@param value any
---@param schema table|nil
---@param path string|nil
---@return boolean
---@return table|nil
function NetworkProtocol.ValidateValue(value, schema, path)
    if schema == nil then
        return true, nil
    end
    path = path or "$"

    if value == nil then
        if schema.required then
            return false, makeError(ErrorCodes.INVALID_PAYLOAD, "Required value is missing", path)
        end
        return true, nil
    end

    local expectedType = schema.type
    if expectedType ~= nil then
        local actualType = type(value)
        local typeMatches = false
        if expectedType == "any" then
            typeMatches = true
        elseif expectedType == "integer" then
            typeMatches = actualType == "number" and value == math.floor(value)
        elseif expectedType == "number" then
            typeMatches = actualType == "number" and value == value
        elseif expectedType == "object" or expectedType == "table" then
            typeMatches = actualType == "table"
        elseif expectedType == "array" then
            typeMatches = actualType == "table"
        else
            typeMatches = actualType == expectedType
        end
        if not typeMatches then
            return false, makeError(
                ErrorCodes.INVALID_PAYLOAD,
                "Expected " .. tostring(expectedType) .. ", got " .. actualType,
                path
            )
        end
    end

    if schema.enum ~= nil then
        local found = false
        for _, allowed in ipairs(schema.enum) do
            if value == allowed then
                found = true
                break
            end
        end
        if not found then
            return false, makeError(ErrorCodes.INVALID_PAYLOAD, "Value is not in the allowed enum", path)
        end
    end

    if type(value) == "number" then
        if schema.min ~= nil and value < schema.min then
            return false, makeError(ErrorCodes.INVALID_PAYLOAD, "Value is below the minimum", path)
        end
        if schema.max ~= nil and value > schema.max then
            return false, makeError(ErrorCodes.INVALID_PAYLOAD, "Value exceeds the maximum", path)
        end
    end

    if type(value) == "string" then
        if schema.minLength ~= nil and #value < schema.minLength then
            return false, makeError(ErrorCodes.INVALID_PAYLOAD, "String is shorter than the minimum", path)
        end
        if schema.maxLength ~= nil and #value > schema.maxLength then
            return false, makeError(ErrorCodes.INVALID_PAYLOAD, "String exceeds the maximum length", path)
        end
        if schema.pattern ~= nil and string.match(value, schema.pattern) == nil then
            return false, makeError(ErrorCodes.INVALID_PAYLOAD, "String does not match the required pattern", path)
        end
    end

    if type(value) == "table" then
        local isArray = expectedType == "array"
        if isArray then
            local length = #value
            if schema.minLength ~= nil and length < schema.minLength then
                return false, makeError(ErrorCodes.INVALID_PAYLOAD, "Array is shorter than the minimum", path)
            end
            if schema.maxLength ~= nil and length > schema.maxLength then
                return false, makeError(ErrorCodes.INVALID_PAYLOAD, "Array exceeds the maximum length", path)
            end
            for index, item in ipairs(value) do
                local ok, err = NetworkProtocol.ValidateValue(item, schema.items, path .. "[" .. index .. "]")
                if not ok then
                    return false, err
                end
            end
            for key in pairs(value) do
                if type(key) ~= "number" or key < 1 or key > length or key ~= math.floor(key) then
                    return false, makeError(ErrorCodes.INVALID_PAYLOAD, "Array contains a non-sequential key", path)
                end
            end
        else
            local fields = schema.fields or schema.properties
            local required = {}
            if type(schema.required) == "table" then
                for _, fieldName in ipairs(schema.required) do
                    required[fieldName] = true
                end
            end
            if fields ~= nil then
                for fieldName, fieldSchema in pairs(fields) do
                    if required[fieldName] or fieldSchema.required then
                        if value[fieldName] == nil then
                            return false, makeError(
                                ErrorCodes.INVALID_PAYLOAD,
                                "Required field is missing",
                                path .. "." .. fieldName
                            )
                        end
                    end
                    local ok, err = NetworkProtocol.ValidateValue(
                        value[fieldName],
                        fieldSchema,
                        path .. "." .. fieldName
                    )
                    if not ok then
                        return false, err
                    end
                end
                if schema.allowUnknown == false then
                    for fieldName in pairs(value) do
                        if fields[fieldName] == nil then
                            return false, makeError(
                                ErrorCodes.INVALID_PAYLOAD,
                                "Unknown field",
                                path .. "." .. tostring(fieldName)
                            )
                        end
                    end
                end
            end
        end
    end

    if schema.validate ~= nil then
        local ok, valid, reason = pcall(schema.validate, value)
        if not ok then
            return false, makeError(ErrorCodes.INTERNAL_ERROR, "Schema validator failed", path)
        end
        if valid == false then
            return false, makeError(ErrorCodes.INVALID_PAYLOAD, reason or "Custom validation failed", path)
        end
    end

    return true, nil
end

---@param payload any
---@param schema table|nil
---@return boolean
---@return table|nil
function NetworkProtocol.ValidatePayload(payload, schema)
    if schema == nil then
        return true, nil
    end
    if schema.type == nil and (schema.fields ~= nil or schema.properties ~= nil) then
        local copy = {}
        for key, value in pairs(schema) do
            copy[key] = value
        end
        copy.type = "object"
        schema = copy
    end
    return NetworkProtocol.ValidateValue(payload, schema, "$payload")
end

---@param request table
---@return boolean
---@return table|nil
---@return table|nil
function NetworkProtocol.ValidateRequest(request)
    if type(request) ~= "table" then
        return false, nil, makeError(ErrorCodes.INVALID_REQUEST)
    end

    local requestId = canonicalRequestField(request, "requestId", NetworkProtocol.FIELDS.REQUEST_ID)
    local command = canonicalRequestField(request, "command", NetworkProtocol.FIELDS.COMMAND)
    local payloadJson = canonicalRequestField(request, "payloadJson", NetworkProtocol.FIELDS.PAYLOAD_JSON)

    if type(requestId) ~= "string"
        or #requestId < 1
        or #requestId > NetworkProtocol.MAX_REQUEST_ID_LENGTH
        or string.match(requestId, "^[%w%._:%-]+$") == nil
    then
        return false, nil, makeError(ErrorCodes.INVALID_REQUEST_ID)
    end

    if type(command) ~= "string"
        or #command < 1
        or #command > NetworkProtocol.MAX_COMMAND_LENGTH
        or string.match(command, "^[%a][%w%._:%-]*$") == nil
    then
        return false, nil, makeError(ErrorCodes.INVALID_REQUEST, "Command is invalid")
    end

    if payloadJson == nil or payloadJson == "" then
        payloadJson = "{}"
    end
    if type(payloadJson) ~= "string" then
        return false, nil, makeError(ErrorCodes.INVALID_REQUEST, "PayloadJson must be a string")
    end
    if #payloadJson > NetworkProtocol.MAX_PAYLOAD_BYTES then
        return false, nil, makeError(ErrorCodes.PAYLOAD_TOO_LARGE)
    end

    return true, {
        requestId = requestId,
        command = command,
        payloadJson = payloadJson,
    }, nil
end

---@param eventData any
---@return boolean
---@return table|nil
---@return table|nil
function NetworkProtocol.ReadCommandEvent(eventData)
    return NetworkProtocol.ValidateRequest({
        requestId = readRawField(eventData, NetworkProtocol.FIELDS.REQUEST_ID),
        command = readRawField(eventData, NetworkProtocol.FIELDS.COMMAND),
        payloadJson = readRawField(eventData, NetworkProtocol.FIELDS.PAYLOAD_JSON),
    })
end

---@param payloadJson string
---@param decoder function|nil
---@return boolean
---@return table|nil
---@return table|nil
function NetworkProtocol.DecodePayload(payloadJson, decoder)
    if type(payloadJson) ~= "string" then
        return false, nil, makeError(ErrorCodes.INVALID_JSON, "PayloadJson must be a string")
    end
    if #payloadJson > NetworkProtocol.MAX_PAYLOAD_BYTES then
        return false, nil, makeError(ErrorCodes.PAYLOAD_TOO_LARGE)
    end

    decoder = resolveJsonFunction(decoder, "decode")
    if decoder == nil then
        return false, nil, makeError(ErrorCodes.INTERNAL_ERROR, "JSON decoder is unavailable")
    end

    local ok, payload = pcall(decoder, payloadJson == "" and "{}" or payloadJson)
    if not ok or type(payload) ~= "table" then
        return false, nil, makeError(ErrorCodes.INVALID_JSON)
    end
    return true, payload, nil
end

---@param payload any
---@param encoder function|nil
---@return boolean
---@return string|nil
---@return table|nil
function NetworkProtocol.EncodePayload(payload, encoder)
    encoder = resolveJsonFunction(encoder, "encode")
    if encoder == nil then
        return false, nil, makeError(ErrorCodes.INTERNAL_ERROR, "JSON encoder is unavailable")
    end
    local ok, encoded = pcall(encoder, payload == nil and {} or payload)
    if not ok or type(encoded) ~= "string" then
        return false, nil, makeError(ErrorCodes.INTERNAL_ERROR, "JSON encoding failed")
    end
    return true, encoded, nil
end

---@param requestId string|nil
---@param command string|nil
---@param payload any
---@param encoder function|nil
---@return table|nil
---@return table|nil
function NetworkProtocol.MakeEnvelope(requestId, command, payload, encoder)
    local ok, payloadJson, err = NetworkProtocol.EncodePayload(payload, encoder)
    if not ok then
        return nil, err
    end
    return {
        version = NetworkProtocol.VERSION,
        requestId = requestId,
        command = command,
        payloadJson = payloadJson,
    }, nil
end

---@param envelope table
---@return any
function NetworkProtocol.ToVariantMap(envelope)
    local values = {
        [NetworkProtocol.FIELDS.VERSION] = envelope.version or NetworkProtocol.VERSION,
        [NetworkProtocol.FIELDS.REQUEST_ID] = envelope.requestId or "",
        [NetworkProtocol.FIELDS.COMMAND] = envelope.command or "",
        [NetworkProtocol.FIELDS.PAYLOAD_JSON] = envelope.payloadJson or "{}",
    }

    local variantMapConstructor = _G["VariantMap"]
    local variantConstructor = _G["Variant"]
    if variantMapConstructor == nil or variantConstructor == nil then
        return values
    end

    local created, eventData = pcall(function()
        return variantMapConstructor()
    end)
    if not created or eventData == nil then
        return values
    end
    for fieldName, value in pairs(values) do
        eventData[fieldName] = variantConstructor(value)
    end
    return eventData
end

---@param command string
---@param requestId string
---@param payload any
---@param encoder function|nil
---@return any|nil
---@return table|nil
function NetworkProtocol.MakeCommandEvent(command, requestId, payload, encoder)
    local envelope, err = NetworkProtocol.MakeEnvelope(requestId, command, payload, encoder)
    if envelope == nil then
        return nil, err
    end
    return NetworkProtocol.ToVariantMap(envelope), nil
end

---@param networkObject any|nil
function NetworkProtocol.RegisterServerEvents(networkObject)
    networkObject = networkObject or _G["network"]
    assert(networkObject ~= nil, "Network subsystem is unavailable")
    for _, eventName in ipairs(NetworkProtocol.SERVER_EVENTS) do
        networkObject:RegisterRemoteEvent(eventName)
    end
end

---@param networkObject any|nil
function NetworkProtocol.RegisterClientEvents(networkObject)
    networkObject = networkObject or _G["network"]
    assert(networkObject ~= nil, "Network subsystem is unavailable")
    for _, eventName in ipairs(NetworkProtocol.CLIENT_EVENTS) do
        networkObject:RegisterRemoteEvent(eventName)
    end
end

return NetworkProtocol
