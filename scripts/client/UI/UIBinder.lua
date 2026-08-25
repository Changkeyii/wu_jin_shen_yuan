local UIBinder = {}

local listeners_ = {}

local function NormalizeDomains(domains)
    if type(domains) == "string" then return { [domains] = true } end
    if type(domains) ~= "table" then return { all = true } end
    local result = {}
    for key, value in pairs(domains) do
        if type(key) == "number" then result[tostring(value)] = true
        elseif value == true then result[tostring(key)] = true end
    end
    return next(result) and result or { all = true }
end

function UIBinder.Subscribe(domains, callback)
    assert(type(callback) == "function", "UIBinder callback must be a function")
    local token = {}
    listeners_[token] = {
        domains = NormalizeDomains(domains),
        callback = callback,
    }
    return token
end

function UIBinder.Unsubscribe(token)
    listeners_[token] = nil
end

function UIBinder.Notify(domains, state, payload)
    local changed = NormalizeDomains(domains)
    for _, listener in pairs(listeners_) do
        local interested = listener.domains.all or changed.all
        if not interested then
            for domain in pairs(changed) do
                if listener.domains[domain] then
                    interested = true
                    break
                end
            end
        end
        if interested then listener.callback(changed, state, payload) end
    end
end

function UIBinder.Reset()
    listeners_ = {}
end

return UIBinder
