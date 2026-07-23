local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")

local LoadingController = {}
local C = GameTheme.Colors

local context_ = nil
local root_ = nil
local dots_ = {}
local percentLabel_ = nil
local messageLabel_ = nil
local progressFill_ = nil
local overlay_ = nil
local active_ = false
local progress_ = 0
local message_ = "正在加载像素字体"
local timer_ = 0
local hideDelay_ = nil
local snapshotReceived_ = false
local dwpFinished_ = false
local observerId_ = nil
local playAssetsReady_ = false
local playAssetLoading_ = false
local textureCache_ = {}
local playAssetWaiters_ = {}

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

local function scheduleHide(delay)
    if snapshotReceived_ and dwpFinished_ then
        hideDelay_ = delay or 0.35
    end
end

local function finishPlayAssetLoading()
    playAssetsReady_ = true
    playAssetLoading_ = false
    setProgress(100, "战斗资源已就绪")
    scheduleHide(0.2)
    local waiters = playAssetWaiters_
    playAssetWaiters_ = {}
    for _, callback in ipairs(waiters) do callback() end
end

local function collectPlayAssetPaths()
    local assets = context_.assets
    local paths = { assets.bg, assets.bgMirror }
    local player = context_.currentPlayer()
    local function add(path)
        if type(path) == "string" then
            paths[#paths + 1] = path
        elseif type(path) == "table" then
            for _, nestedPath in pairs(path) do add(nestedPath) end
        end
    end
    add(player.icon)
    add(player.sprite)
    add(player.attack)
    add(player.idle)
    add(player.run)
    add(player.attackFrameSets)
    add(assets.ui)
    add(assets.enemies)
    add(assets.items)
    local unique = {}
    local result = {}
    for _, path in ipairs(paths) do
        if path and not unique[path] then
            unique[path] = true
            result[#result + 1] = path
        end
    end
    return result
end

function LoadingController.Configure(context)
    context_ = context
end

function LoadingController.AttachRoot(root)
    root_ = root
    overlay_ = nil
    percentLabel_ = nil
    messageLabel_ = nil
    progressFill_ = nil
    dots_ = {}
    if active_ then createOverlay() end
end

function LoadingController.Start(root)
    if root then LoadingController.AttachRoot(root) end
    progress_ = 0
    message_ = "正在进入游戏，后台加载资源"
    timer_ = 0
    hideDelay_ = nil
    snapshotReceived_ = false
    dwpFinished_ = false
    show(5, message_)
    print("[DWP] media resources use download-while-playing; startup will not block on textures or frames.")
    if observerId_ then
        cache:StopObservingDownloads(observerId_)
        observerId_ = nil
    end
    observerId_ = cache:ObserveDownloads(
        function(completedCount, totalCount, completedBytes)
            local nextProgress = 20
            if totalCount and totalCount > 0 then
                nextProgress = 20 + math.floor((completedCount / totalCount) * 55)
            end
            setProgress(nextProgress, string.format(
                "正在加载资源 %d/%d",
                completedCount or 0,
                totalCount or 0
            ))
        end,
        function(completedBytes)
            dwpFinished_ = true
            setProgress(snapshotReceived_ and 100 or 78, snapshotReceived_ and "资源和存档已同步" or "资源加载完成，正在同步常驻服")
            scheduleHide(0.35)
            if observerId_ then
                cache:StopObservingDownloads(observerId_)
                observerId_ = nil
            end
        end
    )
end

function LoadingController.MarkSnapshotReceived()
    snapshotReceived_ = true
    setProgress(dwpFinished_ and 100 or 82, dwpFinished_ and "资源和存档已同步" or "常驻服状态已同步，继续加载资源")
    scheduleHide(0.35)
end

function LoadingController.MarkSnapshotProgress(received, total)
    total = math.max(1, total or 1)
    received = math.max(0, math.min(total, received or 0))
    local ratio = received / total
    setProgress(58 + math.floor(ratio * 24), string.format("正在同步背包 %d/%d", received, total))
end

function LoadingController.HandleStatus(state)
    if not active_ then return end
    if state == "ready" then
        setProgress(88, "已完成加载常驻服状态")
    elseif state == "syncing" then
        setProgress(55, "正在加载常驻服状态")
    else
        setProgress(42, "正在连接常驻服")
    end
end

function LoadingController.HandleDisconnected()
    show(42, "正在重连常驻服")
end

function LoadingController.HandleError()
    show(42, "正在重试加载网络数据")
end

function LoadingController.EnsurePlayAssetsReady(onReady)
    if onReady then playAssetWaiters_[#playAssetWaiters_ + 1] = onReady end
    if playAssetsReady_ then
        local waiters = playAssetWaiters_
        playAssetWaiters_ = {}
        for _, callback in ipairs(waiters) do callback() end
        return
    end
    if playAssetLoading_ then return end
    playAssetLoading_ = true
    local paths = collectPlayAssetPaths()
    local total = #paths
    local completed = 0
    show(8, "正在预热战斗序列帧")
    if total == 0 then finishPlayAssetLoading(); return end

    local function complete(path, resource)
        if resource then textureCache_[path] = resource end
        completed = completed + 1
        setProgress(8 + math.floor(completed / total * 88), string.format(
            "正在预热战斗资源 %d/%d",
            completed,
            total
        ))
        if completed >= total then finishPlayAssetLoading() end
    end

    for _, path in ipairs(paths) do
        if textureCache_[path] then
            complete(path, textureCache_[path])
        else
            cache:GetResourceAsync("Texture2D", path, function(resource)
                complete(path, resource)
            end)
        end
    end
end

function LoadingController.IsActive()
    return active_
end

function LoadingController.IsPlayAssetLoading()
    return playAssetLoading_
end

function LoadingController.Update(dt)
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
    if hideDelay_ then
        hideDelay_ = hideDelay_ - (dt or 0)
        if hideDelay_ <= 0 then
            active_ = false
            hideDelay_ = nil
            if overlay_ then overlay_:Hide() end
        end
    end
end

function LoadingController.Stop()
    if observerId_ then
        cache:StopObservingDownloads(observerId_)
        observerId_ = nil
    end
    active_ = false
    hideDelay_ = nil
    snapshotReceived_ = false
    dwpFinished_ = false
    playAssetWaiters_ = {}
    root_ = nil
    overlay_ = nil
    dots_ = {}
end

return LoadingController
