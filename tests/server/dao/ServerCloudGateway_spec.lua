local ServerCloudGateway = require("server.dao.ServerCloudGateway")

local function newFakeCloud()
    local fake = {
        calls = {},
        failNext = nil,
        embeddedNext = nil,
    }

    local function record(name, ...)
        fake.calls[#fake.calls + 1] = { name = name, args = { ... } }
    end

    local function respond(events, ...)
        if fake.failNext then
            local failure = fake.failNext
            fake.failNext = nil
            events.error(failure.code, failure.reason)
            return
        end
        events.ok(...)
    end

    local function embedded(events, data)
        if fake.failNext then
            local failure = fake.failNext
            fake.failNext = nil
            events.error(failure.code, failure.reason)
            return
        end
        if fake.embeddedNext then
            local failure = fake.embeddedNext
            fake.embeddedNext = nil
            data(failure.code, failure.reason)
            return
        end
        data(0, "")
    end

    function fake:Get(userId, key, events)
        record("ScoreGet", userId, key)
        respond(events, { [key] = { value = 1 } }, { [key] = 2 }, {})
    end

    function fake:Set(userId, key, value, events)
        record("ScoreSet", userId, key, value)
        respond(events)
    end

    function fake:SetInt(userId, key, value, events)
        record("ScoreSetInt", userId, key, value)
        respond(events)
    end

    function fake:Add(userId, key, delta, events)
        record("ScoreAdd", userId, key, delta)
        respond(events)
    end

    function fake:Delete(userId, key, events)
        record("ScoreDelete", userId, key)
        respond(events)
    end

    function fake:GetRankList(key, start, count, orderAsc, events)
        if type(orderAsc) == "table" then
            events = orderAsc
            orderAsc = nil
        end
        record("RankGetList", key, start, count, orderAsc)
        respond(events, { { userId = 77, iscore = { [key] = 9 }, score = {} } })
    end

    function fake:GetUserRank(userId, key, events)
        record("RankGetUser", userId, key)
        respond(events, 3, 9)
    end

    function fake:GetRankTotal(key, events)
        record("RankGetTotal", key)
        respond(events, 12)
    end

    function fake:BatchGet(userId)
        local batch = { userId = userId, players = {}, keys = {} }
        function batch:Player(playerId)
            self.players[#self.players + 1] = playerId
            return self
        end
        function batch:Key(key)
            self.keys[#self.keys + 1] = key
            return self
        end
        function batch:Fetch(events)
            record("BatchGet", self.userId, self.players, self.keys)
            if self.userId ~= nil then
                respond(events, { value = "score" }, { value = 4 }, {})
            else
                respond(events, { { userId = self.players[1], score = {}, iscore = { value = 4 } } })
            end
        end
        return batch
    end

    function fake:BatchSet(userId)
        local batch = { userId = userId, operations = {} }
        local function add(self, kind, key, value)
            self.operations[#self.operations + 1] = { kind = kind, key = key, value = value }
            return self
        end
        function batch:Set(key, value) return add(self, "set", key, value) end
        function batch:SetInt(key, value) return add(self, "set_int", key, value) end
        function batch:Add(key, value) return add(self, "add", key, value) end
        function batch:Delete(key) return add(self, "delete", key) end
        function batch:Save(description, events)
            record("BatchSet", self.userId, self.operations, description)
            respond(events)
        end
        return batch
    end

    function fake:BatchCommit(description)
        local commit = { description = description, operations = {} }
        local function add(self, kind, ...)
            self.operations[#self.operations + 1] = { kind = kind, args = { ... } }
            return self
        end
        function commit:ScoreSet(...) return add(self, "score_set", ...) end
        function commit:ScoreSetInt(...) return add(self, "score_set_int", ...) end
        function commit:ScoreAddInt(...) return add(self, "score_add_int", ...) end
        function commit:ScoreDelete(...) return add(self, "score_delete", ...) end
        function commit:ScoreDeleteInt(...) return add(self, "score_delete_int", ...) end
        function commit:MoneyAdd(...) return add(self, "money_add", ...) end
        function commit:MoneyCost(...) return add(self, "money_cost", ...) end
        function commit:ListAdd(...)
            add(self, "list_add", ...)
            return self, 303
        end
        function commit:ListModify(...) return add(self, "list_modify", ...) end
        function commit:ListModifyKey(...) return add(self, "list_modify_key", ...) end
        function commit:ListDelete(...) return add(self, "list_delete", ...) end
        function commit:QuotaAdd(...) return add(self, "quota_add", ...) end
        function commit:QuotaReset(...) return add(self, "quota_reset", ...) end
        function commit:Commit(events)
            record("BatchCommit", self.description, self.operations)
            respond(events)
        end
        return commit
    end

    fake.money = {}
    function fake.money:Get(userId, events)
        record("MoneyGet", userId)
        respond(events, { gold = 10 })
    end
    function fake.money:Add(userId, key, amount, events)
        record("MoneyAdd", userId, key, amount)
        respond(events)
    end
    function fake.money:Cost(userId, key, amount, events)
        record("MoneyCost", userId, key, amount)
        respond(events)
    end

    fake.list = {}
    function fake.list:Get(userId, key, events)
        record("ListGet", userId, key)
        respond(events, { { list_id = 101, key = key, value = {} } })
    end
    function fake.list:GetById(listId, events)
        record("ListGetById", listId)
        respond(events, { { list_id = listId, value = {} } })
    end
    function fake.list:Add(userId, key, value, events)
        record("ListAdd", userId, key, value)
        respond(events)
        return 101
    end
    function fake.list:Modify(listId, value, events)
        record("ListModify", listId, value)
        respond(events)
    end
    function fake.list:ModifyKey(listId, key, events)
        record("ListModifyKey", listId, key)
        respond(events)
    end
    function fake.list:Delete(listId, events)
        record("ListDelete", listId)
        respond(events)
    end

    fake.item = {}
    function fake.item:Get(userId, key, events)
        record("ItemGet", userId, key)
        respond(events, { { item_id = 202, key = key, count = 1 } })
    end
    function fake.item:Add(userId, key, name, count, value, expireType, expireTime, events)
        record("ItemAdd", userId, key, name, count, value, expireType, expireTime)
        respond(events)
        return 202
    end
    function fake.item:Use(userId, itemId, count, events)
        record("ItemUse", userId, itemId, count)
        respond(events)
    end

    fake.message = {}
    function fake.message:Send(userId, key, targetUserId, value, events)
        record("MessageSend", userId, key, targetUserId, value)
        embedded(events, function(code, reason) events.ok(code, reason) end)
    end
    function fake.message:Get(userId, key, read, events)
        record("MessageGet", userId, key, read)
        respond(events, { { message_id = 404, key = key, value = {} } })
    end
    function fake.message:MarkRead(messageId, events)
        record("MessageMarkRead", messageId)
        embedded(events, function(code, reason) events.ok(code, reason) end)
    end
    function fake.message:Delete(messageId, events)
        record("MessageDelete", messageId)
        embedded(events, function(code, reason) events.ok(true, code, reason) end)
    end

    fake.quota = {}
    function fake.quota:Get(userId, key, events)
        record("QuotaGet", userId, key)
        respond(events, { { key = key, value = 1, limit = 2 } })
    end
    function fake.quota:Add(userId, key, value, limit, refreshType, refreshCount, events)
        record("QuotaAdd", userId, key, value, limit, refreshType, refreshCount)
        respond(events)
    end
    function fake.quota:Reset(userId, key, events)
        record("QuotaReset", userId, key)
        respond(events)
    end

    return fake
end

local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
    end
end

local function assertResult(result, expectedOk, label)
    if type(result) ~= "table" then error(label .. ": missing result", 2) end
    assertEqual(type(result.ok), "boolean", label .. ".ok type")
    assertEqual(type(result.data), "table", label .. ".data type")
    assertEqual(type(result.code), "number", label .. ".code type")
    assertEqual(type(result.reason), "string", label .. ".reason type")
    assertEqual(result.ok, expectedOk, label .. ".ok")
end

local function invoke(label, call, inspect)
    local result = nil
    local callbackCount = 0
    call(function(value)
        callbackCount = callbackCount + 1
        result = value
    end)
    assertEqual(callbackCount, 1, label .. " callback count")
    assertResult(result, true, label)
    if inspect then inspect(result) end
end

local function run()
    local fake = newFakeCloud()
    local gateway = ServerCloudGateway.new(fake)
    local uid = 77

    invoke("ScoreGet", function(done) gateway:ScoreGet(uid, "score", done) end, function(result)
        assertEqual(result.data.iscores.score, 2, "ScoreGet integer data")
    end)
    invoke("ScoreSet", function(done) gateway:ScoreSet(uid, "score", {}, done) end)
    invoke("ScoreSetInt", function(done) gateway:ScoreSetInt(uid, "score_i", 1, done) end)
    invoke("ScoreAdd", function(done) gateway:ScoreAdd(uid, "score_i", 2, done) end)
    invoke("ScoreDelete", function(done) gateway:ScoreDelete(uid, "score", done) end)

    invoke("MoneyGet", function(done) gateway:MoneyGet(uid, done) end)
    invoke("MoneyAdd", function(done) gateway:MoneyAdd(uid, "gold", 2, done) end)
    invoke("MoneyCost", function(done) gateway:MoneyCost(uid, "gold", 1, done) end)

    invoke("ListGet", function(done) gateway:ListGet(uid, "inventory", done) end)
    invoke("ListGetById", function(done) gateway:ListGetById(101, done) end)
    invoke("ListAdd", function(done) gateway:ListAdd(uid, "inventory", {}, done) end, function(result)
        assertEqual(result.data.listId, 101, "ListAdd listId")
    end)
    invoke("ListModify", function(done) gateway:ListModify(101, {}, done) end)
    invoke("ListModifyKey", function(done) gateway:ListModifyKey(101, "inventory_2", done) end)
    invoke("ListDelete", function(done) gateway:ListDelete(101, done) end)

    invoke("ItemGet", function(done) gateway:ItemGet(uid, "weapon", done) end)
    invoke("ItemAdd", function(done)
        gateway:ItemAdd(uid, "weapon", "test", 1, {}, nil, nil, done)
    end, function(result)
        assertEqual(result.data.itemId, 202, "ItemAdd itemId")
    end)
    invoke("ItemUse", function(done) gateway:ItemUse(uid, 202, 1, done) end)

    invoke("MessageSend", function(done) gateway:MessageSend(uid, "mail", uid, {}, done) end)
    invoke("MessageGet", function(done) gateway:MessageGet(uid, "mail", false, done) end)
    invoke("MessageMarkRead", function(done) gateway:MessageMarkRead(404, done) end)
    invoke("MessageDelete", function(done) gateway:MessageDelete(404, done) end)

    invoke("QuotaGet", function(done) gateway:QuotaGet(uid, "daily", done) end)
    invoke("QuotaAdd", function(done) gateway:QuotaAdd(uid, "daily", 1, 2, "day", 1, done) end)
    invoke("QuotaReset", function(done) gateway:QuotaReset(uid, "daily", done) end)

    invoke("RankGetList default order", function(done)
        gateway:RankGetList("score_i", 1, 10, nil, done)
    end)
    invoke("RankGetList explicit order", function(done)
        gateway:RankGetList("score_i", 1, 10, true, done)
    end)
    invoke("RankGetUser", function(done) gateway:RankGetUser(uid, "score_i", done) end)
    invoke("RankGetTotal", function(done) gateway:RankGetTotal("score_i", done) end)

    invoke("BatchGet single", function(done)
        gateway:BatchGet(uid, { "score", "score_i" }, done)
    end)
    invoke("BatchGet multi", function(done)
        gateway:BatchGet({ uid, uid + 1 }, { "score_i" }, done)
    end)

    local BatchSetOp = gateway.BatchSetOperation
    invoke("BatchSet", function(done)
        gateway:BatchSet(uid, {
            { kind = BatchSetOp.SET, key = "a", value = {} },
            { kind = BatchSetOp.SET_INT, key = "b", value = 1 },
            { kind = BatchSetOp.ADD, key = "b", delta = 1 },
            { kind = BatchSetOp.DELETE, key = "a" },
        }, "test batch", done)
    end)

    local CommitOp = gateway.CommitOperation
    invoke("BatchCommit", function(done)
        gateway:BatchCommit("test atomic commit", {
            { kind = CommitOp.SCORE_SET, userId = uid, key = "a", value = {} },
            { kind = CommitOp.SCORE_SET_INT, userId = uid, key = "b", value = 1 },
            { kind = CommitOp.SCORE_ADD_INT, userId = uid, key = "b", delta = 1 },
            { kind = CommitOp.SCORE_DELETE, userId = uid, key = "a" },
            { kind = CommitOp.SCORE_DELETE_INT, userId = uid, key = "b" },
            { kind = CommitOp.MONEY_ADD, userId = uid, key = "gold", amount = 1 },
            { kind = CommitOp.MONEY_COST, userId = uid, key = "gold", amount = 1 },
            { kind = CommitOp.LIST_ADD, userId = uid, key = "list", value = {}, resultKey = "newList" },
            { kind = CommitOp.LIST_MODIFY, listId = 303, value = {} },
            { kind = CommitOp.LIST_MODIFY_KEY, listId = 303, key = "list_2" },
            { kind = CommitOp.LIST_DELETE, listId = 303 },
            {
                kind = CommitOp.QUOTA_ADD,
                userId = uid,
                key = "daily",
                value = 1,
                limit = 2,
                refreshType = "day",
                refreshCount = 1,
            },
            { kind = CommitOp.QUOTA_RESET, userId = uid, key = "daily" },
        }, done)
    end, function(result)
        assertEqual(result.data.listIds.newList, 303, "BatchCommit listId")
    end)

    fake.failNext = { code = -429, reason = "send failed" }
    local transportError = nil
    gateway:ScoreGet(uid, "score", function(result) transportError = result end)
    assertResult(transportError, false, "transport error")
    assertEqual(transportError.code, -429, "transport error code")
    assertEqual(transportError.reason, "send failed", "transport error reason")

    fake.embeddedNext = { code = 17, reason = "message rejected" }
    local embeddedError = nil
    gateway:MessageSend(uid, "mail", uid, {}, function(result) embeddedError = result end)
    assertResult(embeddedError, false, "embedded message error")
    assertEqual(embeddedError.code, 17, "embedded message error code")
    assertEqual(embeddedError.reason, "message rejected", "embedded message error reason")

    local unsupportedBatch = nil
    gateway:BatchSet(uid, { { kind = "unknown", key = "x" } }, "bad", function(result)
        unsupportedBatch = result
    end)
    assertResult(unsupportedBatch, false, "unsupported batch")
    assertEqual(unsupportedBatch.code, ServerCloudGateway.ErrorCode.UNSUPPORTED_OPERATION, "unsupported batch code")

    local unsupportedCommit = nil
    gateway:BatchCommit("bad", { { kind = "unknown" } }, function(result)
        unsupportedCommit = result
    end)
    assertResult(unsupportedCommit, false, "unsupported commit")

    local invalidRank = nil
    gateway:RankGetList("score", 0, 10, nil, function(result) invalidRank = result end)
    assertResult(invalidRank, false, "invalid rank")
    assertEqual(invalidRank.code, ServerCloudGateway.ErrorCode.INVALID_ARGUMENT, "invalid rank code")

    local unavailable = nil
    local noCloudGateway = ServerCloudGateway.new(false)
    noCloudGateway.cloud = nil
    noCloudGateway:ScoreGet(uid, "score", function(result) unavailable = result end)
    assertResult(unavailable, false, "unavailable cloud")
    assertEqual(unavailable.code, ServerCloudGateway.ErrorCode.UNAVAILABLE, "unavailable cloud code")

    return { passed = true, callCount = #fake.calls }
end

return {
    run = run,
    newFakeCloud = newFakeCloud,
}
