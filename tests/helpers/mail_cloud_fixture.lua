-- Engine-shaped cloud fixture: transactions stage all writes and validate every
-- operation before publishing. Exercise the REAL gateway, repository and service.
local Copy = require("server.domain.TableUtils").DeepCopy
local Fixture = {}
function Fixture.Json(value)
    local kind = type(value)
    if kind == "nil" then return "null" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then
        return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
            if c == '"' then return '\\"' end
            if c == '\\' then return '\\\\' end
            return string.format('\\u%04x', c:byte())
        end) .. '"'
    end
    assert(kind == "table")
    local entries, count, array = {}, 0, true
    for k in pairs(value) do count = count + 1; if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then array = false end end
    array = array and count == #value
    if array then
        for _, v in ipairs(value) do entries[#entries + 1] = Fixture.Json(v) end
        return "[" .. table.concat(entries, ",") .. "]"
    end
    for k, v in pairs(value) do entries[#entries + 1] = Fixture.Json(k) .. ":" .. Fixture.Json(v) end
    table.sort(entries)
    return "{" .. table.concat(entries, ",") .. "}"
end
function Fixture.New()
    local env = { now = 1791700000, db = { scores = {}, iscores = {}, lists = {}, quotas = {}, messages = {} },
        nextId = 1, pending = {}, calls = {}, lost = {}, pause = false }
    local function field(uid, key) return tostring(uid) .. ":" .. key end
    env.field = field
    local function score(uid, key, ints) return Copy(env.db[ints and "iscores" or "scores"][field(uid,key)]) end
    local function rows(uid, key)
        local out = {}
        for id, row in pairs(env.db.lists) do
            if row.uid == uid and row.key == key then out[#out + 1] = { list_id = id, value = Copy(row.value) } end
        end
        table.sort(out,function(a,b) return a.list_id < b.list_id end)
        return out
    end
    env.rows, env.score = rows, score
    function env:addRow(uid, key, value)
        local id = self.nextId; self.nextId = id + 1
        self.db.lists[id] = { uid = uid, key = key, value = Copy(value) }
        return id
    end
    local function respond(name, fn)
        env.calls[name] = (env.calls[name] or 0) + 1
        if env.dropRead == name then env.dropRead = nil; env.lost[#env.lost + 1] = fn; return end
        if env.rateRead == name then env.rateRead = nil; return false end
        fn(); return true
    end
    local cloud = { list = {}, item = {}, message = {} }
    function cloud:Get(uid, key, events)
        if respond("Get:" .. key, function() events.ok({ [key] = score(uid,key) }, { [key] = score(uid,key,true) }) end) == false then events.error(-429,"limited") end
    end
    function cloud:BatchGet(uid)
        local keys, builder = {}, {}
        function builder:Key(key) keys[#keys+1] = key; return self end
        function builder:Fetch(events)
            respond("BatchGet", function()
                local scores, ints = {}, {}
                for _, key in ipairs(keys) do scores[key] = score(uid,key); ints[key] = score(uid,key,true) end
                events.ok(scores, ints)
            end)
        end
        return builder
    end
    function cloud.list:Get(uid,key,events)
        if respond("ListGet:" .. key, function() events.ok(rows(uid,key)) end) == false then events.error(-429,"limited") end
    end
    function cloud.item:Get(_,_,events) events.ok({}) end
    function cloud.item:Add(_,_,_,_,_,_,_,events) events.ok(1); return 1 end
    function cloud.message:Get(uid,key,read,events)
        respond("MessageGet:" .. key, function()
            local list = {}
            for id, m in pairs(env.db.messages) do
                if m.uid == uid and m.key == key and m.read == read then list[#list+1] = { message_id = id, value = Copy(m.value) } end
            end
            events.ok(list)
        end)
    end
    function cloud.message:Delete(id,events)
        if env.failAck then events.ok(false,-503,"ack failed"); return end
        if not env.db.messages[id] then events.ok(false,-404,"missing"); return end
        env.db.messages[id] = nil
        if env.loseAck then env.loseAck=false; env.lost[#env.lost+1]=function() events.ok(true,0,"") end
        else events.ok(true,0,"") end
    end
    function cloud.message:MarkRead(id,events)
        if env.db.messages[id] then env.db.messages[id].read = true end
        events.ok(0,"")
    end
    function cloud.message:Send(sender,key,uid,value,events)
        env.nextId=env.nextId+1
        env.db.messages[env.nextId] = { uid=uid,key=key,value=Copy(value),read=false,sender=sender }
        events.ok(0,"")
    end
    function cloud.list:Add(uid,key,value,events)
        local id=env:addRow(uid,key,value); events.ok(id); return id
    end
    function cloud.list:Delete(id,events) env.db.lists[id]=nil; events.ok() end
    function cloud:BatchCommit(description)
        local ops, builder = {}, {}
        function builder:ScoreSet(uid,key,value) ops[#ops+1]={kind="score",uid=uid,key=key,value=Copy(value)}; return self end
        function builder:ScoreSetInt(uid,key,value) ops[#ops+1]={kind="int",uid=uid,key=key,value=value}; return self end
        function builder:QuotaAdd(uid,key,value,limit,refresh,refreshCount)
            assert(refresh==nil and refreshCount==nil,"guard must never reset/refresh")
            ops[#ops+1]={kind="quota",uid=uid,key=key,value=value,limit=limit}; return self
        end
        function builder:ListAdd(uid,key,value)
            local id=env.nextId; env.nextId=id+1
            ops[#ops+1]={kind="add",uid=uid,key=key,value=Copy(value),id=id}; return self,id
        end
        function builder:ListModify(id,value) ops[#ops+1]={kind="modify",id=id,value=Copy(value)}; return self end
        function builder:ListDelete(id) ops[#ops+1]={kind="delete",id=id}; return self end
        function builder:Commit(events)
            env.calls.Commit=(env.calls.Commit or 0)+1
            local function apply()
                local db, failure = Copy(env.db), nil
                for _, op in ipairs(ops) do
                    if op.kind == "quota" then
                        local k=field(op.uid,op.key); local nextValue=(db.quotas[k] or 0)+op.value
                        if nextValue>op.limit then failure="quota conflict"; break end
                        db.quotas[k]=nextValue
                    elseif op.kind=="score" or op.kind=="int" then
                        if env.failProfile and op.key=="abyss_profile" then env.failProfile=false; failure="profile failure"; break end
                        db[op.kind=="score" and "scores" or "iscores"][field(op.uid,op.key)]=Copy(op.value)
                    elseif op.kind=="add" then db.lists[op.id]={uid=op.uid,key=op.key,value=Copy(op.value)}
                    elseif op.kind=="modify" then
                        if not db.lists[op.id] then failure="missing row"; break end
                        db.lists[op.id].value=Copy(op.value)
                    elseif op.kind=="delete" then
                        if env.failDelete and db.lists[op.id] and db.lists[op.id].key=="mail_v3_pending" then env.failDelete=false; failure="source delete failure"; break end
                        if not db.lists[op.id] then failure="missing row"; break end
                        db.lists[op.id]=nil
                    else error("unsupported test operation") end
                end
                local callback
                if failure then callback=function() events.error(-409,failure) end
                else env.db=db; callback=function() events.ok() end end
                if env.dropCommit then env.dropCommit=false; env.lost[#env.lost+1]=callback
                else callback() end
            end
            if env.pause then env.pending[#env.pending+1]=apply else apply() end
        end
        return builder
    end
    env.cloud=cloud
    function env:advance(seconds) self.now=self.now+seconds end
    function env:flush()
        self.pause=false; local pending=self.pending; self.pending={}
        for _, fn in ipairs(pending) do fn() end
    end
    return env
end
return Fixture
