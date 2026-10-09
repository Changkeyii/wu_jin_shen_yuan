local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local Downloads = require("client.ResourceDownloads")
local Stages = require("client.ResourceStages")

---@class LoadingController
local LoadingController = {}
local C = GameTheme.Colors
---@type table|nil
local context_
---@type Widget|nil
local root_
---@type Widget|nil
local overlay_
---@type Label|nil
local percentLabel_
---@type Label|nil
local messageLabel_
---@type Widget|nil
local progressFill_
---@type Label|nil
local retryLabel_
local dots_ = {}
local active_, progress_, timer_ = false, 0, 0
local message_ = "正在加载像素字体"
---@type number|nil
local hideDelay_
local snapshotReceived_, initialRequested_, initialReady_ = false, false, false
---@type table|nil
local foreground_
local background_ = {}
---@type function|nil
local initialCallback_
local generation_ = 0

local function setProgress(progress, message)
    local nextProgress = math.max(0, math.min(100, progress or progress_))
    progress_ = math.max(progress_, nextProgress)
    message_ = message or message_
    if percentLabel_ then percentLabel_:SetText(string.format("%d%%", math.floor(progress_))) end
    if messageLabel_ then messageLabel_:SetText(message_) end
    if context_ then context_.setImageProgress(progressFill_, 720, progress_, 100) end
end

local function createOverlay()
    if not context_ or not root_ then return end
    dots_ = {}
    percentLabel_ = context_.txt(string.format("%d%%", math.floor(progress_)), 36, C.primary, {
        width = "100%",
        textAlign = "center",
    })
    messageLabel_ = context_.multiTxt(message_, 28, C.textSecondary, {
        width = "100%",
        textAlign = "center",
        maxLines = 2,
    })
    local progressBar
    progressBar, progressFill_ = context_.imageProgress(
        720, 30, progress_, 100,
        context_.assets.ui.progressTrackLoad,
        context_.assets.ui.progressFillLoad
    )
    local dotLayer = UI.Panel { width = 240, height = 240, position = "relative" }
    for index = 1, 12 do
        local dot = UI.Panel {
            position = "absolute",
            left = 108,
            top = 108,
            width = 24,
            height = 24,
            backgroundImage = context_.assets.ui.loadingDot,
            backgroundFit = "contain",
        }
        dots_[index] = dot
        dotLayer:AddChild(dot)
    end
    overlay_ = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        zIndex = 1000,
        backgroundImage = context_.assets.ui.screenOverlay,
        backgroundFit = "cover",
        alignItems = "center",
        justifyContent = "center",
        paddingLeft = 80,
        paddingRight = 80,
        children = {
            context_.pixelPanel {
                width = 940,
                height = 760,
                alignItems = "center",
                justifyContent = "center",
                gap = 32,
                children = {
                    context_.txt(context_.title, 34, C.text, {
                        width = "100%",
                        textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                    }),
                    context_.txt("资源加载中", 24, C.textDim, {
                        width = "100%",
                        textAlign = "center",
                    }),
                    dotLayer,
                    percentLabel_,
                    messageLabel_,
                    progressBar,
                },
            },
        },
    }
    retryLabel_ = context_.txt("加载失败，点击重试", 24, C.primary, {
        id = "stageLoadingRetry", height = 56, width = "100%", textAlign = "center",
        clickable = true, onClick = function() LoadingController.Retry() end,
    })
    retryLabel_:Hide()
    overlay_:AddChild(retryLabel_)
    root_:AddChild(overlay_)
    if not active_ then overlay_:Hide() end
end

local function show(progress, message)
    active_ = true
    hideDelay_ = nil
    setProgress(progress or 0, message or "正在加载资源")
    if not overlay_ then createOverlay() end
    if overlay_ then overlay_:Show() end
end

local function cancelForeground()
    if foreground_ then Downloads.Cancel(foreground_.request) end
    foreground_ = nil
    if retryLabel_ then retryLabel_:Hide() end
end

local function beginGroup(name, paths, onReady)
    if Downloads.IsReady(paths) then
        cancelForeground()
        if name == "startup" and not snapshotReceived_ then
            show(78, "资源加载完成，正在同步常驻服")
        else
            hideDelay_ = 0.2
        end
        if onReady then onReady() end
        return
    end
    if foreground_ and foreground_.name == name then
        if onReady then foreground_.callbacks[#foreground_.callbacks + 1] = onReady end
        return
    end
    cancelForeground()
    if background_[name] then Downloads.Cancel(background_[name]); background_[name] = nil end
    progress_ = 0
    show(8, "正在加载资源")
    local group = {name = name, paths = paths, callbacks = {}, failed = false}
    if onReady then group.callbacks[1] = onReady end
    foreground_ = group
    local generation = generation_
    group.request = Downloads.Request(paths, 100, function()
        if foreground_ ~= group or generation ~= generation_ then return end
        foreground_ = nil
        if retryLabel_ then retryLabel_:Hide() end
        setProgress(100, "资源加载完成")
        if name ~= "startup" or snapshotReceived_ then hideDelay_ = 0.2 end
        for _, callback in ipairs(group.callbacks) do
            if generation ~= generation_ then break end
            callback()
        end
    end, function(done, total, failed)
        if foreground_ ~= group then return end
        group.failed = failed > 0
        setProgress(8 + math.floor(done / math.max(1, total) * 90),
            failed > 0 and "部分资源加载失败，请点击重试" or string.format("正在加载资源 %d/%d", done, total))
        if retryLabel_ then
            if failed > 0 then retryLabel_:Show() else retryLabel_:Hide() end
        end
    end)
    Downloads.Retry(group.request) -- failed background work becomes retryable foreground work
end

function LoadingController.Configure(context) context_ = context end

function LoadingController.AttachRoot(root)
    root_ = root
    overlay_, percentLabel_, messageLabel_, progressFill_, retryLabel_ = nil, nil, nil, nil, nil
    dots_ = {}
    if active_ then createOverlay() end
end

function LoadingController.PrefetchPage(page)
    if background_[page] or Downloads.IsReady(Stages.Page(page)) then return end
    background_[page] = Downloads.Request(Stages.Page(page), 0, function() background_[page] = nil end)
end

function LoadingController.PrefetchMedia(key, paths)
    if background_[key] or Downloads.IsReady(paths) then return end
    background_[key] = Downloads.Request(paths, 0, function() background_[key] = nil end)
end

function LoadingController.CancelPrefetch(key)
    Downloads.Cancel(background_[key])
    background_[key] = nil
end

function LoadingController.PrefetchTutorial(step)
    if step <= 1 then
        LoadingController.PrefetchPage("play")
    elseif step == 2 then
        LoadingController.PrefetchPage("equip")
        LoadingController.PrefetchPage("bag")
    elseif step == 3 then
        LoadingController.PrefetchPage("equip")
    else
        LoadingController.PrefetchPage("home")
    end
end

function LoadingController.Start(root)
    generation_ = generation_ + 1
    Downloads.Reset()
    cancelForeground()
    background_ = {}
    snapshotReceived_, initialRequested_, initialReady_ = false, false, false
    initialCallback_ = nil
    timer_, hideDelay_ = 0, nil
    if root then LoadingController.AttachRoot(root) end
    -- Original loading visuals are attached before the first download is dispatched.
    beginGroup("startup", Stages.Merge(Stages.Boot(), Stages.Page("home")))
end

function LoadingController.MarkSnapshotReceived(game, onReady)
    snapshotReceived_ = true
    if initialReady_ then
        if not foreground_ then hideDelay_ = 0.35 end
        if onReady then onReady() end
        return
    end
    if onReady then initialCallback_ = onReady end
    if initialRequested_ then return end
    initialRequested_ = true
    local tutorial = game and game.tutorial
    local unfinished = tutorial and not tutorial.completed
    local paths = Stages.Page("home")
    if unfinished then paths = Stages.Merge(paths, Stages.Intro(tutorial.step)) end
    cancelForeground()
    beginGroup("startup", paths, function()
        initialReady_ = true
        local callback = initialCallback_
        initialCallback_ = nil
        if not unfinished then LoadingController.PrefetchPage("play") end
        if callback then callback() end
    end)
end

function LoadingController.MarkSnapshotProgress(received, total)
    if foreground_ and foreground_.failed then return end
    setProgress(progress_, string.format("正在同步背包 %d/%d", received or 0, total or 0))
end

function LoadingController.HandleStatus(state)
    if active_ and not foreground_ then
        setProgress(progress_, state == "ready" and "存档已同步" or "正在连接常驻服")
    end
end
function LoadingController.HandleDisconnected() show(progress_, "正在重连常驻服") end
function LoadingController.HandleError(reason) show(progress_, reason or "网络数据加载失败，请重试") end
function LoadingController.BeginFloorTransition(floor)
    progress_ = 0; show(20, "正在进入第" .. tostring(floor or "下一") .. "层")
end
function LoadingController.CompleteFloorTransition(floor)
    if foreground_ then return end
    setProgress(100, "第" .. tostring(floor or "新") .. "层路线已同步")
    hideDelay_ = 0.35
end
function LoadingController.EnsurePageAssetsReady(page, onReady)
    beginGroup(page, Stages.Page(page), onReady)
end
function LoadingController.EnsurePlayAssetsReady(onReady)
    LoadingController.EnsurePageAssetsReady("play", onReady)
end
function LoadingController.EnsureMediaReady(key, paths, onReady)
    beginGroup(key, paths, onReady)
end
function LoadingController.Retry()
    if foreground_ then
        foreground_.failed = false
        Downloads.Retry(foreground_.request)
        if retryLabel_ then retryLabel_:Hide() end
    end
end
function LoadingController.IsActive() return active_ end
function LoadingController.IsPlayAssetLoading() return foreground_ and foreground_.name == "play" or false end

function LoadingController.Update(dt)
    Downloads.Update(dt)
    if not active_ then return end
    timer_ = timer_ + (dt or 0)
    local radius = 84
    for index, dot in ipairs(dots_) do
        local angle = timer_ * 5.2 + (index - 1) * math.pi * 2 / 12
        dot:SetStyle({
            left = 108 + math.cos(angle) * radius,
            top = 108 + math.sin(angle) * radius,
            opacity = (80 + 175 * (index / 12)) / 255,
            scale = 0.7 + 0.3 * (index / 12),
        })
    end
    if hideDelay_ and not foreground_ then
        hideDelay_ = hideDelay_ - (dt or 0)
        if hideDelay_ <= 0 then
            active_, hideDelay_ = false, nil
            if overlay_ then overlay_:Hide() end
        end
    end
end

function LoadingController.DismissForRecovery()
    generation_ = generation_ + 1
    cancelForeground()
    Downloads.Reset()
    background_, initialCallback_ = {}, nil
    active_, hideDelay_ = false, nil
    if overlay_ then overlay_:Hide() end
end
function LoadingController.Stop()
    LoadingController.DismissForRecovery()
    snapshotReceived_, initialRequested_, initialReady_ = false, false, false
    root_, overlay_, percentLabel_, messageLabel_, progressFill_, retryLabel_ = nil, nil, nil, nil, nil, nil
    dots_ = {}
end

return LoadingController
