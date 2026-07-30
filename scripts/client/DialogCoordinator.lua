local DialogCoordinator = {}

local PRIORITIES = {
    story = 400,
    equipment = 300,
    equipment_swap = 300,
    rules = 200,
    confirm = 100,
    confirmation = 100,
}

local queue_ = {}
local active_ = nil
local sequence_ = 0
local presenter_ = nil
local dismisser_ = nil

local function PriorityOf(options)
    if type(options.priority) == "number" then return options.priority end
    return PRIORITIES[options.kind or options.dialogType or "confirm"] or PRIORITIES.confirm
end

local function HasKey(key)
    if key == nil then return false end
    if active_ and active_.key == key then return true end
    for _, item in ipairs(queue_) do
        if item.key == key then return true end
    end
    return false
end

local function SortQueue()
    table.sort(queue_, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.sequence < b.sequence
    end)
end

local Pump

local function CompleteActive(result)
    local item = active_
    if not item or item.completed then return false end
    item.completed = true

    if dismisser_ then
        local ok, reason = pcall(dismisser_)
        if not ok then print("[DialogCoordinator] dismiss failed: " .. tostring(reason)) end
    end

    active_ = nil
    local callback = result == "confirm" and item.options.onConfirm or item.options.onCancel
    if callback then
        local ok, reason = pcall(callback, result, item.options)
        if not ok then print("[DialogCoordinator] callback failed: " .. tostring(reason)) end
    end
    Pump()
    return true
end

local function PresentActive()
    if not active_ or not presenter_ then return end
    local item = active_
    item.completed = false
    local ok, reason = pcall(presenter_, item.options, function(result)
        if active_ == item then CompleteActive(result or "cancel") end
    end)
    if not ok then
        print("[DialogCoordinator] present failed: " .. tostring(reason))
        if active_ == item then CompleteActive("cancel") end
    end
end

Pump = function()
    if active_ or not presenter_ or #queue_ == 0 then return end
    SortQueue()
    active_ = table.remove(queue_, 1)
    PresentActive()
end

function DialogCoordinator.Configure(options)
    options = options or {}
    if active_ and dismisser_ then pcall(dismisser_) end
    presenter_ = options.present or presenter_
    dismisser_ = options.dismiss or dismisser_
    if active_ then
        PresentActive()
    else
        Pump()
    end
end

function DialogCoordinator.HasKey(key)
    return HasKey(key)
end

function DialogCoordinator.Enqueue(options)
    options = options or {}
    local key = options.queueKey or options.key
    if HasKey(key) then return false, "duplicate" end

    sequence_ = sequence_ + 1
    queue_[#queue_ + 1] = {
        options = options,
        priority = PriorityOf(options),
        sequence = sequence_,
        key = key,
        completed = false,
    }
    Pump()
    return true
end

function DialogCoordinator.CancelActive()
    return CompleteActive("cancel")
end

function DialogCoordinator.CancelByKey(key)
    if key == nil then return false end
    if active_ and active_.key == key then
        return CompleteActive("cancel")
    end
    for index, item in ipairs(queue_) do
        if item.key == key then
            table.remove(queue_, index)
            if item.options.onCancel then
                local ok, reason = pcall(item.options.onCancel, "cancel", item.options)
                if not ok then print("[DialogCoordinator] callback failed: " .. tostring(reason)) end
            end
            return true
        end
    end
    return false
end

function DialogCoordinator.ConfirmActive()
    return CompleteActive("confirm")
end

function DialogCoordinator.Clear(invokeCancel)
    local active = active_
    if dismisser_ then pcall(dismisser_) end
    active_ = nil
    queue_ = {}
    if invokeCancel and active and active.options.onCancel then
        pcall(active.options.onCancel, "cancel", active.options)
    end
end

function DialogCoordinator.GetState()
    return {
        active = active_ and active_.options or nil,
        activePriority = active_ and active_.priority or nil,
        queued = #queue_,
    }
end

function DialogCoordinator._ResetForTests()
    queue_ = {}
    active_ = nil
    sequence_ = 0
    presenter_ = nil
    dismisser_ = nil
end

DialogCoordinator.Priorities = PRIORITIES

return DialogCoordinator
