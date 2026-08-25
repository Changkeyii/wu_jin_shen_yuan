local ClientViewCache = {}

local namespaces_ = {}

local function Namespace(name)
    local value = namespaces_[name]
    if value then return value end
    value = {}
    namespaces_[name] = value
    return value
end

function ClientViewCache.Get(namespace, key)
    return Namespace(namespace)[tostring(key)]
end

function ClientViewCache.Set(namespace, key, value)
    Namespace(namespace)[tostring(key)] = value
    return value
end

function ClientViewCache.Delete(namespace, key)
    Namespace(namespace)[tostring(key)] = nil
end

function ClientViewCache.ClearNamespace(namespace)
    namespaces_[namespace] = {}
end

function ClientViewCache.ClearAll()
    namespaces_ = {}
end

local REFUND_NAMESPACE = "decomposeRefund"

function ClientViewCache.GetDecomposeRefund(itemId, revision)
    if itemId == nil then return nil end
    local entry = ClientViewCache.Get(REFUND_NAMESPACE, itemId)
    if type(entry) ~= "table" or entry.revision ~= revision then return nil end
    return entry.value
end

function ClientViewCache.IsDecomposeRefundPending(itemId, revision)
    local entry = itemId and ClientViewCache.Get(REFUND_NAMESPACE, itemId) or nil
    return type(entry) == "table"
        and entry.revision == revision
        and entry.pending == true
end

function ClientViewCache.BeginDecomposeRefund(itemId, revision)
    if itemId == nil then return false end
    local entry = ClientViewCache.Get(REFUND_NAMESPACE, itemId)
    if type(entry) == "table" and entry.revision == revision then
        if entry.pending or entry.value ~= nil then return false end
    end
    ClientViewCache.Set(REFUND_NAMESPACE, itemId, {
        pending = true,
        value = nil,
        revision = revision,
    })
    return true
end

function ClientViewCache.ResolveDecomposeRefund(itemId, revision, value)
    if itemId == nil then return false end
    local entry = ClientViewCache.Get(REFUND_NAMESPACE, itemId)
    if type(entry) ~= "table" or entry.revision ~= revision then return false end
    entry.pending = false
    entry.value = value
    return true
end

function ClientViewCache.FailDecomposeRefund(itemId, revision)
    local entry = ClientViewCache.Get(REFUND_NAMESPACE, itemId)
    if type(entry) == "table" and entry.revision == revision then
        entry.pending = false
        entry.value = nil
    end
end

return ClientViewCache
