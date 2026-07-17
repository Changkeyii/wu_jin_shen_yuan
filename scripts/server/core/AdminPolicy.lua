local AdminPolicy = {}
AdminPolicy.__index = AdminPolicy

function AdminPolicy.New(options)
    options = options or {}
    local admins = {}
    for _, userId in ipairs(options.adminUserIds or { 1379670410 }) do
        admins[tonumber(userId)] = true
    end
    return setmetatable({ admins = admins }, AdminPolicy)
end

AdminPolicy.new = AdminPolicy.New

function AdminPolicy:IsAdmin(userId)
    return self.admins[tonumber(userId)] == true
end

function AdminPolicy:Authorize(userId, requirement)
    if requirement == nil or requirement == false or requirement == "player" then
        return true
    end
    if requirement == true or requirement == "admin" then
        return self:IsAdmin(userId)
    end
    return false
end

function AdminPolicy:CanTarget(actorUserId, targetUserId, action)
    if not self:IsAdmin(actorUserId) then return false, "actor is not an administrator" end
    if action == "ban" and self:IsAdmin(targetUserId) then
        return false, "administrator accounts cannot be banned"
    end
    return true
end

return AdminPolicy
