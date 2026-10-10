local GameEngine = require("server.domain.GameEngine")
local Catalog = require("server.domain.Catalog")
local TableUtils = require("server.domain.TableUtils")
local MailEngine = require("server.domain.MailEngine")
local PlayerTransition = require("server.domain.PlayerTransition")
local AdminMailDefinitions = require("shared.AdminMailDefinitions")

---@class AdminService
---@field gateway table<string, any>
---@field repository table<string, any>
---@field profileService table<string, any>
---@field operationQueue table<string, any>
---@field adminPolicy table<string, any>
---@field clock fun(): integer
---@field instanceNonce string
---@field commandIdFactory function?
---@field auditOwnerUserId integer
---@field onDelta function
---@field onBanned function
---@field onAdminResult function
---@field commandSequence integer
---@field pollElapsed number
---@field polling table<integer, boolean>
---@field resultPolling table<integer, boolean>
---@field legacyMailSessions table<integer, table>
---@field decodeJson function?
---@field mailService MailService?
---@field pollCursor integer?
local AdminService = {}
AdminService.__index = AdminService

local function Result(ok, data, code, reason)
    return { ok = ok == true, data = data or {}, code = code or (ok and 0 or -1), reason = tostring(reason or "") }
end

---@param value any
---@return integer?
local function UserId(value)
    local number = tonumber(value)
    if not number then return nil end
    number = math.tointeger(number)
    if not number or number <= 0 then return nil end
    return number
end

local function SafeReason(value)
    if type(value) ~= "string" then return nil end
    value = value:match("^%s*(.-)%s*$")
    if value == "" or #value > 120 then return nil end
    return value
end

local function DurableAction(action)
    return action == "send_mail" or action == "set_ad_free"
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

---@return AdminService
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
        legacyMailSessions = {},
        decodeJson = options.decodeJson or (_G.cjson and _G.cjson.decode),
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
            summary.vipLevel = state.vipLevel or 0
            summary.adFree = state.adFree == true
            summary.floor = state.floor
            summary.maxFloor = state.maxFloor
            summary.position = state.position
            summary.gold = state.gold
            summary.fragments = state.fragments
            summary.inventoryCount = #state.inventory
            summary.power = state.stats and state.stats.power or 0
            -- 作弊判定辅助数据
            summary.totalPlaySeconds = state.totalPlaySeconds or 0
            -- 在线会话时长并入累计：本次会话从 playSessionStart 起算，
            -- 断线前累计在 totalPlaySeconds 中（TouchAndDetach 持久化）。
            local activeSession = self.profileService:GetSession(targetUserId)
            if result.data.online == true and activeSession and activeSession.playSessionStart then
                local elapsed = math.max(0, self.clock() - (activeSession.playSessionStart or 0))
                summary.totalPlaySeconds = summary.totalPlaySeconds + elapsed
            end
            summary.autoRun = state.autoRun == true
            summary.pendingOfflineSeconds = state.pendingOfflineSeconds or 0
            summary.pendingEvent = state.pendingEvent ~= nil
            summary.lastActiveAt = state.lastActiveAt or 0
            local equippedCount = 0
            if type(state.equipped) == "table" then
                for _, slot in pairs(state.equipped) do
                    if slot then equippedCount = equippedCount + 1 end
                end
            end
            summary.equippedCount = equippedCount
            local stats = state.stats or {}
            summary.stats = {
                power = stats.power or 0,
                atk = stats.atk or 0,
                def = stats.def or 0,
                hp = stats.hp or 0,
                crit = stats.crit or 0,
                atkSpeed = stats.atkSpeed or 0,
            }
        end
        local function finish(nickname)
            summary.nickname = nickname or ""
            onComplete(Result(true, {
                player = summary,
                status = summary.online and "applied: online" or "applied: offline",
            }))
        end
        local query = _G.GetUserNickname
        if type(query) == "function" then
            query {
                userIds = { targetUserId },
                onSuccess = function(nicknames)
                    local row = type(nicknames) == "table" and nicknames[1] or nil
                    finish(row and row.nickname or "")
                end,
                onError = function() finish("") end,
            }
        else
            finish("")
        end
    end)
end

--- Query online players by nickname (fuzzy), returns [{uid, nickname, online}]
function AdminService:QueryByName(actorUserId, name, onComplete)
    if not self.adminPolicy:IsAdmin(actorUserId) then
        onComplete(Result(false, {}, "FORBIDDEN", "administrator permission required"))
        return
    end
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" or #name > 32 then
        onComplete(Result(false, {}, "INVALID_NAME", "nickname is invalid"))
        return
    end
    local onlineIds = self.profileService:OnlineUserIds() or {}
    if #onlineIds == 0 then
        onComplete(Result(true, { matches = {}, status = "applied" }))
        return
    end
    local lowerName = string.lower(name)
    local query = _G.GetUserNickname
    if type(query) ~= "function" then
        onComplete(Result(false, {}, "NICKNAME_QUERY_FAILED", "nickname query unavailable"))
        return
    end
    query {
        userIds = onlineIds,
        onSuccess = function(nicknames)
            local matches = {}
            for _, row in ipairs(type(nicknames) == "table" and nicknames or {}) do
                local nickname = tostring(row.nickname or "")
                if nickname ~= "" and string.find(string.lower(nickname), lowerName, 1, true) then
                    matches[#matches + 1] = { uid = row.userId, nickname = nickname, online = true }
                    if #matches >= 20 then break end
                end
            end
            onComplete(Result(true, { matches = matches, status = "applied" }))
        end,
        onError = function()
            onComplete(Result(false, {}, "NICKNAME_QUERY_FAILED", "nickname query failed"))
        end,
    }
end

function AdminService:_equipmentSpec(state, payload)
    if type(payload) ~= "table" then return nil end
    local definitions = Catalog.EQUIPMENT_DEFINITIONS
    for _, definition in ipairs(definitions) do
        if definition.slot == payload.slot and definition.rarity == payload.rarity then
            return { equipmentId = definition.id, level = state.floor }
        end
    end
    return nil
end

function AdminService:_applyMutation(command, onComplete)
    local targetUserId = command.targetUid
    ---@type string?
    local operationName = nil
    ---@type function?
    local mutator = nil
    if command.action == "set_ad_free" then
        operationName = "GM set ad-free"
        mutator = function(state, now)
            if type(command.payload.enabled) ~= "boolean" then
                return PlayerTransition.Failure(state, now, "INVALID_ENTITLEMENT", "免广告状态必须为开启或关闭")
            end
            local working = PlayerTransition.Copy(state, now)
            working.adFree = command.payload.enabled
            return PlayerTransition.Finalize(state, working, now, "ad_free_changed", {}, false, false)
        end
    elseif command.action == "send_mail" then
        if self.mailService and self.mailService.sharedDelivery then
            self.mailService.sharedDelivery:DeliverLegacy(command, onComplete); return
        end
        operationName = "GM send mail"
        mutator = function(state, now)
            local working = PlayerTransition.Copy(state, now)
            local spec = TableUtils.DeepCopy(command.payload.spec)
            spec.bizOrderId = "gm-mail:" .. command.commandId
            local mail = MailEngine.Create(working, spec, now)
            if not mail then
                return PlayerTransition.Failure(state, now, "MAIL_CAPACITY_FULL", "邮箱已满，邮件将自动重试投递")
            end
            return PlayerTransition.Finalize(state, working, now, "mail_sent", {}, false, false)
        end
    elseif command.action == "grant_currency" then
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
            if result.ok and result.data.delta then
                local sent, reason = pcall(self.onDelta, command.targetUid, result.data.delta)
                if not sent then print("[AdminService] committed delta notification failed: " .. tostring(reason)) end
            end
            local auditStatus = result.ok
                and (result.data.alreadyApplied and "alreadyApplied" or "applied")
                or (DurableAction(command.action) and "pending" or "rejected")
            self:_audit(command, auditStatus, result.reason, function() end)
            local callbackOk, callbackError = pcall(onComplete, result)
            if not callbackOk then print("[AdminService] delivery callback failed: " .. tostring(callbackError)) end
            done()
        end)
    end)
end

function AdminService:_queueRemote(command, onComplete)
    -- Older persistent instances consume GM_COMMAND and acknowledge unsupported
    -- actions. Keep personal deliveries invisible to those consumers.
    local key = self.repository.Keys.GM_COMMAND
    if command.action == "send_mail" then key = self.repository.Keys.PERSONAL_MAIL
    elseif command.action == "set_ad_free" then key = self.repository.Keys.PLAYER_ENTITLEMENT end
    self.gateway:MessageSend(
        command.actorUid,
        key,
        command.targetUid,
        command,
        function(result)
            if not result.ok then onComplete(result); return end
            if command.action == "send_mail" then
                print("[PersonalMail] stage=queued uid=" .. tostring(command.targetUid)
                    .. " command=" .. command.commandId .. " key=" .. tostring(key))
            elseif command.action == "set_ad_free" then
                print("[PlayerEntitlement] stage=queued uid=" .. tostring(command.targetUid)
                    .. " command=" .. command.commandId .. " enabled=" .. tostring(command.payload.enabled))
            end
            self:_audit(command, "queued", "waiting for target authority", function(auditResult)
                if not auditResult.ok then
                    if DurableAction(command.action) then
                        -- The mail is already durable. Reporting failure invites a
                        -- second send although the first one will still arrive.
                        onComplete(Result(true, { status = "queued", commandId = command.commandId,
                            action = command.action, auditWarning = true }))
                        return
                    end
                    onComplete(Result(false, { queued = true }, auditResult.code, auditResult.reason))
                    return
                end
                onComplete(Result(true, { status = "queued", commandId = command.commandId, action = command.action }))
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
    if action == "query_by_name" then self:QueryByName(actorUserId, payload.name, onComplete); return end
if action == "audit" then self:GetAudit(actorUserId, onComplete); return end

    local targetUserId = UserId(payload.targetUid)
    local reason = action == "send_mail" and "GM邮件发送" or SafeReason(payload.reason)
    if not targetUserId then onComplete(Result(false, {}, "INVALID_UID", "target UID is invalid")); return end
    if not reason then onComplete(Result(false, {}, "INVALID_REASON", "a non-empty reason up to 120 bytes is required")); return end
    local allowed, targetReason = self.adminPolicy:CanTarget(actorUserId, targetUserId, action)
    if not allowed then onComplete(Result(false, {}, "FORBIDDEN", targetReason)); return end

    local sanitized = {}
    if action == "set_ad_free" then
        if type(payload.enabled) ~= "boolean" then
            onComplete(Result(false, {}, "INVALID_ENTITLEMENT", "免广告状态必须为开启或关闭"))
            return
        end
        sanitized = { enabled = payload.enabled }
    elseif action == "send_mail" then
        local spec, err = AdminMailDefinitions.BuildSpec(payload, self.clock())
        if not spec then
            onComplete(Result(false, {}, err.code, err.reason))
            return
        end
        sanitized = { spec = spec }
    elseif action == "grant_currency" then
        local amount = tonumber(payload.amount)
        if (payload.currency ~= "gold" and payload.currency ~= "fragments")
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
            or not position or position ~= math.floor(position) or position < 0 or position > 10 then
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
    if action == "send_mail" and self.mailService and self.mailService.sharedStore then
        self.mailService.sharedStore:QueuePersonal(targetUserId, "gm-mail:" .. command.commandId,
            sanitized.spec, function(result)
                onComplete(result)
                if result.ok and self.profileService:IsOnline(targetUserId) then
                    self.mailService.sharedDelivery:Sync(targetUserId, function() end, true)
                end
            end)
        return
    end
    if DurableAction(action) then
        -- Always persist first, including local online targets. A disconnect or
        -- instance restart between acceptance and delivery cannot lose the mail.
        self:_queueRemote(command, function(result)
            onComplete(result)
            if result.ok and self.profileService:IsOnline(targetUserId) then
                self:ProcessInbox(targetUserId, function() end)
            end
        end)
        return
    end
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

function AdminService:_messageValue(message)
    local value = type(message) == "table" and message.value or nil
    if type(value) == "string" and type(self.decodeJson) == "function" then
        local ok, decoded = pcall(self.decodeJson, value)
        if ok then value = decoded end
    end
    if type(value) ~= "table" then return nil end
    value = TableUtils.DeepCopy(value)
    value.targetUid = UserId(value.targetUid)
    if value.actorUid ~= nil then value.actorUid = UserId(value.actorUid) end
    return value
end

-- A production administrator can inspect delivery from the running game even
-- when development tools have no access to production logs or cloud data.
function AdminService:InspectMailDelivery(actorUserId, targetUserId, mailService, onComplete, mailId)
    if not self.adminPolicy:IsAdmin(actorUserId) then
        onComplete(Result(false, {}, "FORBIDDEN", "administrator permission required")); return
    end
    targetUserId = UserId(targetUserId)
    if not targetUserId then onComplete(Result(false, {}, "INVALID_UID", "target UID is invalid")); return end
    if mailService.sharedDelivery then mailService.sharedDelivery:Inspect(targetUserId, mailId, onComplete); return end
    self.profileService:Inspect(targetUserId, function(profile)
        if not profile.ok then onComplete(profile); return end
        self:_loadInbox(targetUserId, function(inbox)
            local waiting, invalid = 0, 0
            for _, message in ipairs(inbox.data.messages or {}) do
                local command = self:_messageValue(message)
                if message.personalMail or (command and command.action == "send_mail") then
                    if command and command.targetUid == targetUserId and command.action == "send_mail" then
                        if not message.legacyComplete then waiting = waiting + 1 end
                    else invalid = invalid + 1 end
                end
            end
            mailService:_loadBroadcasts(function(broadcast)
                local state = profile.data.state or {}
                local mailed = #(state.mails or {}) + #(state.mailCache or {})
                local broadcastWaiting = 0
                for _, entry in ipairs(broadcast.data.entries or {}) do
                    if not (state.receivedBroadcasts or {})[entry.batchId] then broadcastWaiting = broadcastWaiting + 1 end
                end
                local failed = inbox.data.cloudPending == true or not broadcast.ok
                local status = string.format("UID %s｜%s｜邮箱 %d 封｜个人待投递 %d｜全服待投递 %d｜异常记录 %d%s｜投递版本 cloud-v1",
                    tostring(targetUserId), profile.data.online and "本实例在线" or "本实例未在线", mailed,
                    waiting, broadcastWaiting, invalid, failed and "｜云读取失败，请重试" or "")
                onComplete(Result(true, { status = status, delivery = { version = "cloud-v1", targetUid = targetUserId,
                    mailboxCount = mailed, personalPending = waiting, broadcastPending = broadcastWaiting,
                    invalid = invalid, cloudPending = failed } }))
            end)
        end)
    end)
end

function AdminService:_loadInbox(targetUserId, onComplete)
    local messages, cloudPending = {}, false
    local session = self.profileService:GetSession(targetUserId)
    local function failed(stage, result)
        cloudPending = true
        print("[PersonalMail] stage=" .. stage .. " uid=" .. tostring(targetUserId)
            .. " code=" .. tostring(result.code))
    end
    local function finish()
        onComplete(Result(true, {messages = messages, cloudPending = cloudPending}))
    end
    local function recoverLegacy()
        if not session or self.legacyMailSessions[targetUserId] == session then finish(); return end
        local function inspectHistory(history)
            if not history.ok then failed("legacy_fetch", history); finish(); return end
            local candidates, actors, actorSeen, rejected, succeeded, receiptReadable = {}, {}, {}, {}, {}, {}
            for _, message in ipairs(history.data.messages or {}) do
                local command = self:_messageValue(message)
                if command and command.action == "send_mail" and command.targetUid == targetUserId
                    and type(command.commandId) == "string" and self.adminPolicy:IsAdmin(command.actorUid) then
                    candidates[#candidates + 1] = message
                    if not actorSeen[command.actorUid] then
                        actorSeen[command.actorUid] = true
                        actors[#actors + 1] = command.actorUid
                    end
                end
            end
            local actorIndex, read = 1, false
            local function nextReceipts()
                local actor = actors[actorIndex]
                if not actor then
                    -- Only recover a proven unsupported-action rejection. An
                    -- arbitrary read task may have been claimed/deleted already.
                    for _, message in ipairs(candidates) do
                        local command = self:_messageValue(message)
                        if receiptReadable[command.actorUid] ~= false
                            and (rejected[command.commandId] or succeeded[command.commandId]) then
                            message.legacyMail = true
                            message.legacyComplete = succeeded[command.commandId] == true
                            messages[#messages + 1] = message
                            if not message.legacyComplete then
                                print("[PersonalMail] stage=legacy_recovery uid=" .. tostring(targetUserId)
                                    .. " command=" .. command.commandId)
                            end
                        end
                    end
                    if not cloudPending then self.legacyMailSessions[targetUserId] = session end
                    finish()
                    return
                end
                self.gateway:MessageGet(actor, self.repository.Keys.GM_RESULT, read, function(receipts)
                    if not receipts.ok then
                        receiptReadable[actor] = false
                        failed("legacy_receipts", receipts)
                    else
                        for _, message in ipairs(receipts.data.messages or {}) do
                            local receipt = self:_messageValue(message)
                            if receipt and receipt.targetUid == targetUserId and receipt.action == "send_mail"
                                and type(receipt.commandId) == "string" then
                                if receipt.ok == true and (receipt.status == "applied" or receipt.status == "alreadyApplied") then
                                    succeeded[receipt.commandId] = true
                                elseif receipt.ok == false and receipt.code == "UNKNOWN_ADMIN_ACTION" then
                                    rejected[receipt.commandId] = true
                                end
                            end
                        end
                    end
                    if read then actorIndex = actorIndex + 1; read = false else read = true end
                    nextReceipts()
                end)
            end
            nextReceipts()
        end
        self.gateway:MessageGet(targetUserId, self.repository.Keys.GM_COMMAND, true, function(history)
            if not history.ok or not (self.mailService and self.mailService.sharedStore) then inspectHistory(history); return end
            self.gateway:MessageGet(targetUserId, self.repository.Keys.PERSONAL_MAIL, true, function(personalHistory)
                if not personalHistory.ok then failed("personal_history", personalHistory); inspectHistory(history); return end
                for _, message in ipairs(personalHistory.data.messages or {}) do
                    message.personalMail = true
                    history.data.messages[#history.data.messages + 1] = message
                end
                inspectHistory(history)
            end)
        end)
    end
    self.gateway:MessageGet(targetUserId, self.repository.Keys.GM_COMMAND, false, function(legacy)
        if not legacy.ok then failed("gm_fetch", legacy)
        else
            for _, message in ipairs(legacy.data.messages or {}) do
                local command = self:_messageValue(message)
                message.legacyMail = command and command.action == "send_mail" or false
                messages[#messages + 1] = message
            end
        end
        self.gateway:MessageGet(targetUserId, self.repository.Keys.PERSONAL_MAIL, false, function(personal)
            if not personal.ok then failed("mail_fetch", personal)
            else
                for _, message in ipairs(personal.data.messages or {}) do
                    message.personalMail = true
                    messages[#messages + 1] = message
                end
            end
            self.gateway:MessageGet(targetUserId, self.repository.Keys.PLAYER_ENTITLEMENT, false, function(entitlements)
                if not entitlements.ok then failed("entitlement_fetch", entitlements)
                else
                    local rows = entitlements.data.messages or {}
                    table.sort(rows, function(left, right)
                        local leftCommand, rightCommand = self:_messageValue(left), self:_messageValue(right)
                        local leftTime = tonumber(leftCommand and leftCommand.createdAt) or 0
                        local rightTime = tonumber(rightCommand and rightCommand.createdAt) or 0
                        if leftTime ~= rightTime then return leftTime < rightTime end
                        return (UserId(left.message_id or left.messageId) or 0)
                            < (UserId(right.message_id or right.messageId) or 0)
                    end)
                    for _, message in ipairs(rows) do
                        message.playerEntitlement = true
                        messages[#messages + 1] = message
                    end
                end
                recoverLegacy()
            end)
        end)
    end)
end

function AdminService:ProcessInbox(targetUserId, onComplete)
    if self.polling[targetUserId] then onComplete(Result(true, { status = "busy" })); return end
    local session = self.profileService:GetSession(targetUserId)
    local generation = session and session.generation
    local token = {}; self.polling[targetUserId] = token
    self:_loadInbox(targetUserId, function(result)
        if self.polling[targetUserId] ~= token then return end
        if self.profileService:GetSession(targetUserId) ~= session or (session and session.generation ~= generation) then
            self.polling[targetUserId] = nil; onComplete(Result(false, {}, "STALE_SESSION", "玩家连接已变化")); return
        end
        if not result.ok then self.polling[targetUserId] = nil; onComplete(result); return end
        local messages = result.data.messages or {}
        local index = 0
        local applied = 0
        local alreadyApplied = 0
        local pending = result.data.cloudPending and 1 or 0
        local entitlementBlocked = false
        local finished = false

        local function finish(resultValue)
            if finished then return end
            finished = true
            if self.polling[targetUserId] == token then self.polling[targetUserId] = nil end
            onComplete(resultValue)
        end

        local function nextMessage()
            if finished then return end
            if self.profileService:GetSession(targetUserId) ~= session or (session and session.generation ~= generation) then
                finish(Result(false, {}, "STALE_SESSION", "玩家连接已变化")); return
            end
            index = index + 1
            local message = messages[index]
            if not message then
                finish(Result(true, {
                    status = applied > 0 and "applied" or (alreadyApplied > 0 and "alreadyApplied" or "applied"),
                    applied = applied,
                    alreadyApplied = alreadyApplied,
                    pending = pending,
                }))
                return
            end
            local command = self:_messageValue(message)
            local messageId = UserId(message.message_id or message.messageId)
            if message.playerEntitlement and entitlementBlocked then
                pending = pending + 1
                nextMessage()
                return
            end
            local valid = type(command) == "table"
                and messageId ~= nil
                and type(command.commandId) == "string"
                and command.targetUid == targetUserId
                and self.adminPolicy:IsAdmin(command.actorUid)
                and (command.action ~= "send_mail" or (type(command.payload) == "table" and type(command.payload.spec) == "table"))
                and (not message.personalMail or command.action == "send_mail")
                and (not message.playerEntitlement or command.action == "set_ad_free")
            if not valid then
                -- Parsing/format mismatches must not permanently acknowledge a
                -- reward. Retain the source for diagnosis or a later compatible build.
                pending = pending + 1
                print("[PersonalMail] stage=invalid_envelope uid=" .. tostring(targetUserId)
                    .. " message=" .. tostring(messageId))
                nextMessage()
                return
            end
            command.messageId = messageId
            command.messageKey = message.personalMail and self.repository.Keys.PERSONAL_MAIL or self.repository.Keys.GM_COMMAND
            command.legacyComplete = message.legacyComplete
            if message.legacyComplete and not (self.mailService and self.mailService.sharedDelivery) then
                -- A durable success receipt remains proof after the player
                -- claims/deletes a mail and the bounded ApplyOnce history rolls.
                alreadyApplied = alreadyApplied + 1
                self.gateway:MessageDelete(messageId, function(deleteResult)
                    if not deleteResult.ok then
                        pending = pending + 1
                        self.legacyMailSessions[targetUserId] = nil
                    end
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
                if DurableAction(command.action) and not applyResult.ok then
                    -- Keep the durable message unread on capacity/storage/session
                    -- failure. Continue login and retry on the next inbox poll.
                    pending = pending + 1
                    if message.playerEntitlement then entitlementBlocked = true end
                    self.legacyMailSessions[targetUserId] = nil
                    print("[PersonalMail] stage=apply_pending uid=" .. tostring(targetUserId)
                        .. " command=" .. command.commandId .. " code=" .. tostring(applyResult.code))
                    nextMessage()
                    return
                end
                if applyResult.ok then
                    if applyResult.data.alreadyApplied then
                        alreadyApplied = alreadyApplied + 1
                    else
                        applied = applied + 1
                    end
                end
                if command.action == "send_mail" and self.mailService and self.mailService.sharedDelivery then
                    -- The transaction already stored an untrimmed handoff proof.
                    -- Delete directly; do not hide it behind a failed MarkRead.
                    self.gateway:MessageDelete(messageId, function(deleted)
                        if not deleted.ok then pending = pending + 1; self.legacyMailSessions[targetUserId] = nil end
                        if deleted.ok then
                            local row = applyResult.data.handoff or { list_id = applyResult.data.listIds and applyResult.data.listIds.mailHandoff }
                            if row.list_id or row.listId then
                                self.mailService.sharedDelivery:_ack(targetUserId, row, function(acked)
                                    if not acked.ok then pending = pending + 1 end
                                    nextMessage()
                                end)
                                return
                            end
                        end
                        nextMessage()
                    end)
                    return
                end
                self:_sendResult(command, applyResult, function(sendResult)
                    if not sendResult.ok then
                        if DurableAction(command.action) then
                            pending = pending + 1
                            if message.playerEntitlement then entitlementBlocked = true end
                            self.legacyMailSessions[targetUserId] = nil
                            nextMessage()
                            return
                        end
                        finish(Result(false, {
                            applied = applied,
                            alreadyApplied = alreadyApplied,
                            commandId = command.commandId,
                        }, sendResult.code, sendResult.reason))
                        return
                    end
                    self.gateway:MessageMarkRead(messageId, function(markResult)
                        if not markResult.ok then
                            if DurableAction(command.action) then
                                pending = pending + 1
                                if message.playerEntitlement then entitlementBlocked = true end
                                self.legacyMailSessions[targetUserId] = nil
                                nextMessage()
                                return
                            end
                            finish(markResult); return
                        end
                        if message.legacyMail then
                            -- Remove migrated source tasks only after profile
                            -- commit and receipt; retries still use the same ID.
                            self.gateway:MessageDelete(messageId, function(deleteResult)
                                if not deleteResult.ok then
                                    pending = pending + 1
                                    self.legacyMailSessions[targetUserId] = nil
                                end
                                nextMessage()
                            end)
                        else
                            nextMessage()
                        end
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
            local value = self:_messageValue(message)
            local messageId = UserId(message.message_id or message.messageId)
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
    if self.pollElapsed < (self.mailService and self.mailService.sharedStore and 30 or 5) then return end
    self.pollElapsed = 0
    for userId, session in pairs(self.legacyMailSessions) do
        if self.profileService:GetSession(userId) ~= session then
            self.legacyMailSessions[userId] = nil
        end
    end
    local online = self.profileService:OnlineUserIds()
    if self.mailService and self.mailService.sharedStore and #online > 0 then
        table.sort(online)
        local offset, rotated = self.pollCursor or 0, {}
        for i = 1, #online do rotated[i] = online[(offset + i - 1) % #online + 1] end
        self.pollCursor = (offset + 1) % #online
        online = rotated
    end
    for _, userId in ipairs(online) do
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
