local GameEngine = require("server.domain.GameEngine")
local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")

local AdminService = {}
AdminService.__index = AdminService

local function Result(ok, data, code, reason)
    return { ok = ok == true, data = data or {}, code = code or (ok and 0 or -1), reason = tostring(reason or "") }
end

local function UserId(value)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) or number <= 0 then return nil end
    return number
end

local function SafeReason(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if value == "" or #value > 120 then return nil end
    return value
end

local function NormalizeInstanceNonce(value, clock)
    if value ~= nil then
        local supplied = tostring(value):gsub("[^%w]", "")
        if supplied ~= "" then return supplied:sub(-24) end
    end
    local cpu = type(os.clock) == "function" and math.floor(os.clock() * 1000000) or 0
    local randomValue = 0
    local randomOk, generated = pcall(math.random, 0, 999999999)
    if randomOk then randomValue = generated end
    local address = tostring({}):gsub("[^%w]", "")
    local nonce = string.format("%s%d%d%d", address, clock(), cpu, randomValue)
    return nonce:sub(-24)
end

function AdminService.New(options)
    options = options or {}
    assert(options.gateway and options.repository and options.profileService, "AdminService requires cloud and profile services")
    assert(options.operationQueue and options.adminPolicy, "AdminService requires queue and admin policy")
    local clock = options.clock or os.time
    return setmetatable({
        gateway = options.gateway,
        repository = options.repository,
        profileService = options.profileService,
        operationQueue = options.operationQueue,
        adminPolicy = options.adminPolicy,
        clock = clock,
        instanceNonce = NormalizeInstanceNonce(options.instanceNonce, clock),
        commandIdFactory = options.commandIdFactory,
        auditOwnerUserId = options.auditOwnerUserId or 1379670410,
        onDelta = options.onDelta or function() end,
        onBanned = options.onBanned or function() end,
        onAdminResult = options.onAdminResult or function() end,
        commandSequence = 0,
        pollElapsed = 0,
        polling = {},
        resultPolling = {},
    }, AdminService)
end

AdminService.new = AdminService.New

function AdminService:_nextCommandId(actorUserId)
    self.commandSequence = self.commandSequence + 1
    local commandId = nil
    if type(self.commandIdFactory) == "function" then
        local ok, generated = pcall(
            self.commandIdFactory,
            actorUserId,
            self.clock(),
            self.commandSequence,
            self.instanceNonce
        )
        if ok then commandId = generated end
    else
        commandId = string.format(
            "gm-%s-%d-%s-%d",
            tostring(actorUserId),
            self.clock(),
            self.instanceNonce,
            self.commandSequence
        )
    end
    if type(commandId) ~= "string"
        or #commandId < 1
        or #commandId > 96
        or string.match(commandId, "^[%w%._:%-]+$") == nil
    then
        return nil
    end
    return commandId
end

function AdminService:_appendAudit(record, onComplete)
    record = TableUtils.DeepCopy(record)
    record.createdAt = record.createdAt or self.clock()
    self.gateway:ListAdd(self.auditOwnerUserId, self.repository.Keys.ADMIN_AUDIT, record, function(addResult)
        if not addResult.ok then onComplete(addResult); return end
        self.gateway:ListGet(self.auditOwnerUserId, self.repository.Keys.ADMIN_AUDIT, function(listResult)
            if not listResult.ok then onComplete(listResult); return end
            local rows = listResult.data.items or {}
            if #rows <= 200 then onComplete(Result(true, { auditId = addResult.data.listId })); return end
            table.sort(rows, function(left, right)
                local leftTime = type(left.value) == "table" and left.value.createdAt or 0
                local rightTime = type(right.value) == "table" and right.value.createdAt or 0
                if leftTime == rightTime then return (left.list_id or 0) < (right.list_id or 0) end
                return leftTime < rightTime
            end)
            local operations = {}
            for index = 1, #rows - 200 do
                operations[#operations + 1] = {
                    kind = self.gateway.CommitOperation.LIST_DELETE,
                    listId = rows[index].list_id or rows[index].listId,
                }
            end
            self.gateway:BatchCommit("abyss trim admin audit", operations, function(trimResult)
                if trimResult.ok then trimResult.data.auditId = addResult.data.listId end
                onComplete(trimResult)
            end)
        end)
    end)
end

function AdminService:_audit(command, status, detail, onComplete)
    self:_appendAudit({
        commandId = command.commandId,
        actorUid = command.actorUid,
        targetUid = command.targetUid,
        action = command.action,
        reason = command.reason,
        status = status,
        detail = detail,
    }, onComplete or function() end)
end

function AdminService:GetAudit(actorUserId, onComplete)
    if not self.adminPolicy:IsAdmin(actorUserId) then
        onComplete(Result(false, {}, "FORBIDDEN", "administrator permission required"))
        return
    end
    self.gateway:ListGet(self.auditOwnerUserId, self.repository.Keys.ADMIN_AUDIT, function(result)
        if not result.ok then onComplete(result); return end
        local audit = {}
        for _, row in ipairs(result.data.items or {}) do
            if type(row.value) == "table" then audit[#audit + 1] = row.value end
        end
        table.sort(audit, function(left, right) return (left.createdAt or 0) < (right.createdAt or 0) end)
        while #audit > 200 do table.remove(audit, 1) end
        onComplete(Result(true, { audit = audit, status = "applied" }))
    end)
end

function AdminService:Query(actorUserId, targetUserId, onComplete)
    if not self.adminPolicy:IsAdmin(actorUserId) then
        onComplete(Result(false, {}, "FORBIDDEN", "administrator permission required"))
        return
    end
    targetUserId = UserId(targetUserId)
    if not targetUserId then onComplete(Result(false, {}, "INVALID_UID", "target UID is invalid")); return end
    self.profileService:Inspect(targetUserId, function(result)
        if not result.ok then onComplete(result); return end
        local state = result.data.state
        local summary = {
            targetUid = targetUserId,
            online = result.data.online == true,
            missing = result.data.missing == true,
            banned = result.data.ban ~= nil,
            ban = result.data.ban,
        }
        if state then
            summary.revision = state.revision
            summary.level = state.level
            summary.floor = state.floor
            summary.position = state.position
            summary.gold = state.gold
            summary.fragments = state.fragments
            summary.mythShards = state.mythShards
            summary.inventoryCount = #state.inventory
            summary.power = state.stats and state.stats.power or 0
        end
        onComplete(Result(true, { player = summary, status = summary.online and "applied: online" or "applied: offline" }))
    end)
end

function AdminService:_equipmentSpec(state, payload)
    local slot = Catalog.SLOT_BY_ID[payload.slot]
    local rarity = Catalog.RARITIES[payload.rarity]
    if not slot or not rarity then return nil end
    local base = math.max(1, state.floor) * rarity.multiplier
    return {
        slot = slot.id,
        rarity = payload.rarity,
        level = state.floor,
        atk = math.floor((slot.category == "weapon" and 20 or 6) + base * 3.4),
        def = math.floor((slot.category == "armor" and 18 or 5) + base * 2.4),
        hp = math.floor(60 + base * 18),
        crit = slot.category == "jewelry" and 0.02 or 0,
        critDmg = slot.category == "special" and 0.08 or 0,
        atkSpeed = 0,
    }
end

function AdminService:_applyMutation(command, onComplete)
    local targetUserId = command.targetUid
    local operationName = nil
    local mutator = nil
    if command.action == "grant_currency" then
        operationName = "GM grant currency"
        mutator = function(state, now)
            return GameEngine.GrantCurrency(state, command.payload.currency, command.payload.amount, now)
        end
    elseif command.action == "grant_equipment" then
        operationName = "GM grant equipment"
        mutator = function(state, now)
            local specification = self:_equipmentSpec(state, command.payload)
            if not specification then
                return { ok = false, error = { code = "INVALID_EQUIPMENT", reason = "slot or rarity is invalid" } }
            end
            return GameEngine.GrantEquipment(state, specification, now)
        end
    elseif command.action == "adjust_progress" then
        operationName = "GM adjust progress"
        mutator = function(state, now)
            return GameEngine.AdjustProgress(state, {
                floor = command.payload.floor,
                position = command.payload.position,
            }, now)
        end
    else
        onComplete(Result(false, {}, "UNKNOWN_ADMIN_ACTION", "unsupported queued administrator action"))
        return
    end
    self.profileService:ApplyOnce(
        targetUserId,
        command.commandId,
        operationName,
        mutator,
        onComplete
    )
end

function AdminService:_applyOnline(command, onComplete)
    if not self.profileService:GetSession(command.targetUid) then
        onComplete(Result(false, {}, "TARGET_NOT_LOCAL", "target profile is not authoritative in this instance"))
        return
    end
    self.operationQueue:Enqueue(command.targetUid, function(done)
        self:_applyMutation(command, function(result)
            if result.ok and result.data.delta then self.onDelta(command.targetUid, result.data.delta) end
            local auditStatus = result.ok
                and (result.data.alreadyApplied and "alreadyApplied" or "applied")
                or "rejected"
            self:_audit(command, auditStatus, result.reason, function() end)
            onComplete(result)
            done()
        end)
    end)
end

function AdminService:_queueRemote(command, onComplete)
    self.gateway:MessageSend(
        command.actorUid,
        self.repository.Keys.GM_COMMAND,
        command.targetUid,
        command,
        function(result)
            if not result.ok then onComplete(result); return end
            self:_audit(command, "queued", "waiting for target authority", function(auditResult)
                if not auditResult.ok then
                    onComplete(Result(false, { queued = true }, auditResult.code, auditResult.reason))
                    return
                end
                onComplete(Result(true, { status = "queued", commandId = command.commandId }))
            end)
        end
    )
end

function AdminService:_directBan(command, banned, onComplete)
    local record = banned and {
        banned = true,
        actorUid = command.actorUid,
        reason = command.reason,
        createdAt = self.clock(),
    } or nil
    self.repository:SetBan(command.targetUid, record, function(result)
        if not result.ok then onComplete(result); return end
        local session = self.profileService:GetSession(command.targetUid)
        if session then session.ban = record end
        if banned then self.onBanned(command.targetUid, record) end

        local function finish()
            self:_audit(command, "applied", banned and "banned" or "unbanned", function(auditResult)
                if auditResult.ok then
                    onComplete(Result(true, { status = "applied", commandId = command.commandId }))
                else
                    onComplete(Result(false, { applied = true }, auditResult.code, auditResult.reason))
                end
            end)
        end

        if banned and not session then
            self.gateway:MessageSend(
                command.actorUid,
                self.repository.Keys.GM_COMMAND,
                command.targetUid,
                { commandId = command.commandId, actorUid = command.actorUid, targetUid = command.targetUid, action = "ban_notice", reason = command.reason, payload = {} },
                function() finish() end
            )
        else
            finish()
        end
    end)
end

function AdminService:Execute(actorUserId, action, payload, onComplete)
    if not self.adminPolicy:IsAdmin(actorUserId) then
        onComplete(Result(false, {}, "FORBIDDEN", "administrator permission required"))
        return
    end
    payload = type(payload) == "table" and payload or {}
    if action == "query" then self:Query(actorUserId, payload.targetUid, onComplete); return end
    if action == "audit" then self:GetAudit(actorUserId, onComplete); return end

    local targetUserId = UserId(payload.targetUid)
    local reason = SafeReason(payload.reason)
    if not targetUserId then onComplete(Result(false, {}, "INVALID_UID", "target UID is invalid")); return end
    if not reason then onComplete(Result(false, {}, "INVALID_REASON", "a non-empty reason up to 120 bytes is required")); return end
    local allowed, targetReason = self.adminPolicy:CanTarget(actorUserId, targetUserId, action)
    if not allowed then onComplete(Result(false, {}, "FORBIDDEN", targetReason)); return end

    local sanitized = {}
    if action == "grant_currency" then
        local amount = tonumber(payload.amount)
        if (payload.currency ~= "gold" and payload.currency ~= "fragments" and payload.currency ~= "mythShards")
            or not amount or amount ~= math.floor(amount) or amount < 1 or amount > 1000000 then
            onComplete(Result(false, {}, "INVALID_GRANT", "currency or amount is outside the grant boundary"))
            return
        end
        sanitized = { currency = payload.currency, amount = amount }
    elseif action == "grant_equipment" then
        if not Catalog.SLOT_BY_ID[payload.slot] or not Catalog.RARITIES[payload.rarity] then
            onComplete(Result(false, {}, "INVALID_EQUIPMENT", "slot or rarity is invalid"))
            return
        end
        sanitized = { slot = payload.slot, rarity = payload.rarity }
    elseif action == "adjust_progress" then
        local floor, position = tonumber(payload.floor), tonumber(payload.position)
        if not floor or floor ~= math.floor(floor) or floor < 1 or floor > 100000
            or not position or position ~= math.floor(position) or position < 0 or position > 100 then
            onComplete(Result(false, {}, "INVALID_PROGRESS", "floor or position is outside the allowed range"))
            return
        end
        sanitized = { floor = floor, position = position }
    elseif action ~= "ban" and action ~= "unban" then
        onComplete(Result(false, {}, "UNKNOWN_ADMIN_ACTION", "unsupported administrator action"))
        return
    end

    local commandId = self:_nextCommandId(actorUserId)
    if not commandId then
        onComplete(Result(false, {}, "COMMAND_ID_UNAVAILABLE", "could not allocate a unique GM command id"))
        return
    end
    local command = {
        commandId = commandId,
        actorUid = actorUserId,
        targetUid = targetUserId,
        action = action,
        reason = reason,
        payload = sanitized,
        createdAt = self.clock(),
    }
    if action == "ban" then self:_directBan(command, true, onComplete); return end
    if action == "unban" then self:_directBan(command, false, onComplete); return end
    if self.profileService:IsOnline(targetUserId) then
        self:_applyOnline(command, function(result)
            if result.ok then
                result.data.status = result.data.alreadyApplied and "alreadyApplied" or "applied"
                result.data.commandId = command.commandId
            end
            onComplete(result)
        end)
    else
        self:_queueRemote(command, onComplete)
    end
end

function AdminService:_sendResult(command, result, onComplete)
    local status = result.ok
        and (result.data.alreadyApplied and "alreadyApplied" or "applied")
        or "rejected"
    self.gateway:MessageSend(
        command.targetUid,
        self.repository.Keys.GM_RESULT,
        command.actorUid,
        {
            commandId = command.commandId,
            targetUid = command.targetUid,
            action = command.action,
            ok = result.ok,
            code = result.code,
            reason = result.reason,
            status = status,
            alreadyApplied = result.data.alreadyApplied == true,
            appliedAt = self.clock(),
        },
        onComplete or function() end
    )
end

function AdminService:ProcessInbox(targetUserId, onComplete)
    if self.polling[targetUserId] then onComplete(Result(true, { status = "busy" })); return end
    self.polling[targetUserId] = true
    self.gateway:MessageGet(targetUserId, self.repository.Keys.GM_COMMAND, false, function(result)
        if not result.ok then self.polling[targetUserId] = nil; onComplete(result); return end
        local messages = result.data.messages or {}
        local index = 0
        local applied = 0
        local alreadyApplied = 0
        local finished = false

        local function finish(resultValue)
            if finished then return end
            finished = true
            self.polling[targetUserId] = nil
            onComplete(resultValue)
        end

        local function nextMessage()
            index = index + 1
            local message = messages[index]
            if not message then
                finish(Result(true, {
                    status = applied > 0 and "applied" or (alreadyApplied > 0 and "alreadyApplied" or "applied"),
                    applied = applied,
                    alreadyApplied = alreadyApplied,
                }))
                return
            end
            local command = message.value
            local messageId = message.message_id or message.messageId
            local valid = type(command) == "table"
                and type(command.commandId) == "string"
                and command.targetUid == targetUserId
                and self.adminPolicy:IsAdmin(command.actorUid)
            if not valid then
                self.gateway:MessageMarkRead(messageId, function(markResult)
                    if not markResult.ok then finish(markResult); return end
                    nextMessage()
                end)
                return
            end
            if command.action == "ban_notice" then
                self.onBanned(targetUserId, { reason = command.reason, actorUid = command.actorUid })
                self.gateway:MessageMarkRead(messageId, function(markResult)
                    if not markResult.ok then finish(markResult); return end
                    nextMessage()
                end)
                return
            end
            self:_applyOnline(command, function(applyResult)
                if applyResult.ok then
                    if applyResult.data.alreadyApplied then
                        alreadyApplied = alreadyApplied + 1
                    else
                        applied = applied + 1
                    end
                end
                self:_sendResult(command, applyResult, function(sendResult)
                    if not sendResult.ok then
                        finish(Result(false, {
                            applied = applied,
                            alreadyApplied = alreadyApplied,
                            commandId = command.commandId,
                        }, sendResult.code, sendResult.reason))
                        return
                    end
                    self.gateway:MessageMarkRead(messageId, function(markResult)
                        if not markResult.ok then finish(markResult); return end
                        nextMessage()
                    end)
                end)
            end)
        end
        nextMessage()
    end)
end

function AdminService:ProcessResults(actorUserId, onComplete)
    if not self.adminPolicy:IsAdmin(actorUserId) then
        onComplete(Result(false, {}, "FORBIDDEN", "administrator permission required"))
        return
    end
    if self.resultPolling[actorUserId] then
        onComplete(Result(true, { status = "busy" }))
        return
    end
    self.resultPolling[actorUserId] = true
    self.gateway:MessageGet(actorUserId, self.repository.Keys.GM_RESULT, false, function(result)
        if not result.ok then
            self.resultPolling[actorUserId] = nil
            onComplete(result)
            return
        end
        local messages = result.data.messages or {}
        local index = 0
        local delivered = 0

        local function finish(resultValue)
            self.resultPolling[actorUserId] = nil
            onComplete(resultValue)
        end

        local function nextMessage()
            index = index + 1
            local message = messages[index]
            if not message then
                finish(Result(true, { status = "applied", delivered = delivered }))
                return
            end
            local value = message.value
            local messageId = message.message_id or message.messageId
            local valid = type(value) == "table"
                and type(value.commandId) == "string"
                and UserId(value.targetUid) ~= nil
                and type(value.ok) == "boolean"
                and (value.status == "applied" or value.status == "alreadyApplied" or value.status == "rejected")
            if not valid then
                self.gateway:MessageMarkRead(messageId, function() nextMessage() end)
                return
            end

            local callbackOk, callbackResult = pcall(
                self.onAdminResult,
                actorUserId,
                TableUtils.DeepCopy(value)
            )
            if not callbackOk or callbackResult == false then
                finish(Result(
                    false,
                    { delivered = delivered },
                    "ADMIN_RESULT_DELIVERY_FAILED",
                    callbackOk and "administrator result consumer rejected delivery" or callbackResult
                ))
                return
            end
            delivered = delivered + 1
            self.gateway:MessageMarkRead(messageId, function(markResult)
                if not markResult.ok then
                    finish(markResult)
                    return
                end
                nextMessage()
            end)
        end
        nextMessage()
    end)
end

function AdminService:Update(timeStep)
    self.pollElapsed = self.pollElapsed + (timeStep or 0)
    if self.pollElapsed < 5 then return end
    self.pollElapsed = 0
    for _, userId in ipairs(self.profileService:OnlineUserIds()) do
        self:ProcessInbox(userId, function(result)
            if not result.ok then print("[AdminService] inbox poll failed: " .. tostring(result.reason)) end
        end)
        if self.adminPolicy:IsAdmin(userId) then
            self:ProcessResults(userId, function(result)
                if not result.ok then print("[AdminService] result poll failed: " .. tostring(result.reason)) end
            end)
        end
    end
end

return AdminService
