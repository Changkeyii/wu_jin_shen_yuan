local ServerClock = require("client.ServerClock")

local UITimer = {}

local entries_ = {}

function UITimer.Bind(owner, update)
    assert(type(update) == "function", "UITimer update must be a function")
    local token = {}
    entries_[token] = { owner = owner, update = update }
    return token
end

function UITimer.Unbind(token)
    entries_[token] = nil
end

function UITimer.Update()
    local now = ServerClock.Now()
    for token, entry in pairs(entries_) do
        local owner = entry.owner
        if owner and owner.IsVisible and not owner:IsVisible() then
            goto continue
        end
        entry.update(now)
        ::continue::
    end
end

function UITimer.Reset()
    entries_ = {}
end

return UITimer
