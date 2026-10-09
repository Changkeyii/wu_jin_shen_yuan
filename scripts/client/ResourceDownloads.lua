-- Download-only scheduler. UI/NanoVG remains responsible for on-demand decoding.
local Downloads = {}
local records, requests = {}, {}
local clock, sequence = 0, 0
local LIMIT, TIMEOUT = 2, 30

function Downloads.IsReady(paths)
    for _, path in ipairs(paths) do
        if not records[path] or records[path].state ~= "ready" then return false end
    end
    return true
end

function Downloads.Request(paths, priority, onReady, onProgress)
    sequence = sequence + 1
    local request = {id = sequence, paths = paths, priority = priority or 0,
        onReady = onReady, onProgress = onProgress}
    requests[request.id] = request
    for _, path in ipairs(paths) do
        if not records[path] then records[path] = {state = "queued"} end
    end
    return request
end

function Downloads.Cancel(request)
    if request then requests[request.id] = nil end
end

function Downloads.Retry(request)
    if not request or requests[request.id] ~= request then return end
    for _, path in ipairs(request.paths) do
        if records[path].state == "failed" then records[path].state = "queued" end
    end
end

function Downloads.Update(dt)
    clock = clock + math.max(0, dt or 0)
    for path, record in pairs(records) do
        local timeout = path:match("%.mp4$") and 180 or TIMEOUT
        if record.state == "loading" and clock - record.started >= timeout then
            record.state = "failed" -- invalidate callbacks before cancelling the request
            record.token = (record.token or 0) + 1
            pcall(function() cache:CancelDownload(path) end)
        end
    end
    -- Snapshot iteration: ready callbacks may cancel or create requests.
    local ordered = {}
    for _, request in pairs(requests) do ordered[#ordered + 1] = request end
    table.sort(ordered, function(a, b)
        if a.priority == b.priority then return a.id < b.id end
        return a.priority > b.priority
    end)
    for _, request in ipairs(ordered) do
        if requests[request.id] == request then
            local done, failed = 0, 0
            for _, path in ipairs(request.paths) do
                local state = records[path].state
                if state == "ready" then done = done + 1 end
                if state == "failed" then failed = failed + 1 end
            end
            if request.onProgress then request.onProgress(done, #request.paths, failed) end
            if done == #request.paths and requests[request.id] == request then
                requests[request.id] = nil
                if request.onReady then request.onReady() end
            end
        end
    end
    local inFlight = 0
    for _, record in pairs(records) do if record.state == "loading" then inFlight = inFlight + 1 end end
    ordered = {}
    for _, request in pairs(requests) do ordered[#ordered + 1] = request end
    table.sort(ordered, function(a, b)
        if a.priority == b.priority then return a.id < b.id end
        return a.priority > b.priority
    end)
    -- At most two new downloads per update, even for synchronous cache hits.
    local started = 0
    for _, request in ipairs(ordered) do
        if requests[request.id] == request then
            for _, path in ipairs(request.paths) do
                local record = records[path]
                if record.state == "queued" and inFlight < LIMIT and started < LIMIT then
                    started, inFlight = started + 1, inFlight + 1
                    record.state, record.started = "loading", clock
                    record.token = (record.token or 0) + 1
                    local token = record.token
                    local function finish(success)
                        if records[path] ~= record or record.token ~= token or record.state ~= "loading" then return end
                        record.state = success == true and "ready" or "failed"
                    end
                    local ok = pcall(function() cache:DownloadResource(path, finish) end)
                    if not ok then finish(false) end
                end
            end
        end
    end
end

function Downloads.Reset()
    requests = {}
    -- Keep at most the existing two in-flight operations. No callback can navigate;
    -- their files may still be reused after reconnect without re-decoding any image.
end

return Downloads
