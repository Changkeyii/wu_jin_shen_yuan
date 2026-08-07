local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")

local FrameEditorView = {}
local C = GameTheme.Colors

local refs_ = {}
local selected_ = "run"
local paused_ = false
local visible_ = { run = true, attackA = false, attackB = false, attackC = false }
local order_ = { "run", "attackA", "attackB", "attackC" }
local animationTime_ = 0
local context_ = nil
local params_ = {
    run = { x = 0, y = -5, w = 420, h = 210, fps = 10, scale = 1.1 },
    attackA = { x = 150, y = -45, w = 420, h = 210, fps = 16, scale = 1.7 },
    attackB = { x = 30, y = -45, w = 420, h = 210, fps = 16, scale = 1.4 },
    attackC = { x = 135, y = -20, w = 420, h = 210, fps = 16, scale = 1.7 },
}

local function frameConfig(id)
    local player = context_.currentPlayer()
    if id == "attackA" then return "攻击A", player.attackFrameSets[1], params_.attackA end
    if id == "attackB" then return "攻击B", player.attackFrameSets[2], params_.attackB end
    if id == "attackC" then return "攻击C", player.attackFrameSets[3], params_.attackC end
    return "跑步", player.run, params_.run
end

local function frameAt(frames, fps)
    if not frames or #frames == 0 then return context_.currentPlayer().icon end
    local index = math.floor(animationTime_ * (fps or 8)) % #frames + 1
    return frames[index]
end

local function adjust(params, key, step)
    if key == "x" then params.x = params.x + step
    elseif key == "y" then params.y = params.y + step
    elseif key == "w" then params.w = params.w + step
    elseif key == "h" then params.h = params.h + step
    elseif key == "fps" then params.fps = params.fps + step
    elseif key == "scale" then params.scale = math.max(0.2, params.scale + step) end
end

local function reset(params)
    params.x = 0
    params.y = 0
    params.w = context_.runWidth
    params.h = context_.runHeight
    params.fps = selected_ == "run" and context_.runFps or context_.attackFps
    params.scale = 1.0
end

local function editorButton(text, onClick, props)
    props = props or {}
    local image = context_.assets.ui.buttonBlue
    if props.variant == "secondary" then image = context_.assets.ui.buttonPurple
    elseif props.variant == "success" then image = context_.assets.ui.buttonGreen
    elseif props.variant == "danger" then image = context_.assets.ui.buttonRed end
    return context_.imageButton(text, props.width or 118, props.height or 58, image, onClick, props.disabled == true)
end

local function adjustRow(label, key, step)
    local params = params_[selected_]
    local valueLabel = context_.txt(label .. " " .. tostring(params[key]), 24, C.text, { width = 160 })
    return UI.Panel {
        width = "100%",
        flexDirection = "row",
        alignItems = "center",
        gap = 10,
        children = {
            valueLabel,
            editorButton("-" .. tostring(step), function()
                adjust(params, key, -step)
                valueLabel:SetText(label .. " " .. tostring(params[key]))
                FrameEditorView.Update(0)
            end, { variant = "secondary" }),
            editorButton("+" .. tostring(step), function()
                adjust(params, key, step)
                valueLabel:SetText(label .. " " .. tostring(params[key]))
                FrameEditorView.Update(0)
            end, { variant = "primary" }),
        },
    }
end

local function copySettings()
    local lines = { "-- frame editor settings", "frameEditorParams = {" }
    for _, id in ipairs(order_) do
        local value = params_[id]
        lines[#lines + 1] = string.format(
            "    %s = { x = %d, y = %d, w = %d, h = %d, fps = %d, scale = %.2f },",
            id, value.x, value.y, value.w, value.h, value.fps, value.scale
        )
    end
    lines[#lines + 1] = "}"
    ui.useSystemClipboard = true
    ui:SetClipboardText(table.concat(lines, "\n"))
    UI.Toast.Show("已复制调帧参数", { duration = 1.6, variant = "success", position = "bottom" })
end

local function createToggle(item)
    local isVisible = visible_[item.id] == true
    return UI.Panel {
        width = 170,
        height = 58,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = isVisible and context_.assets.ui.editorToggleOn or context_.assets.ui.editorToggleOff,
        backgroundFit = "contain",
        onClick = function()
            visible_[item.id] = not visible_[item.id]
            local anyVisible = false
            for _, id in ipairs(order_) do
                if visible_[id] then anyVisible = true; break end
            end
            if not anyVisible then visible_[item.id] = true end
            context_.refresh()
        end,
        children = {
            context_.txt((isVisible and "显示 " or "隐藏 ") .. item.name, 23,
                isVisible and C.background or C.textSecondary,
                { width = "100%", textAlign = "center" }),
        },
    }
end

function FrameEditorView.Build(context)
    context_ = context
    refs_ = { previews = {} }
    local tabs = {}
    local toggles = {}
    local options = {
        { id = "run", name = "跑步" },
        { id = "attackA", name = "攻击A" },
        { id = "attackB", name = "攻击B" },
        { id = "attackC", name = "攻击C" },
    }
    for _, item in ipairs(options) do
        local active = selected_ == item.id
        tabs[#tabs + 1] = UI.Panel {
            width = 170,
            height = 62,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = active and context.assets.ui.editorTabOn or context.assets.ui.editorTabOff,
            backgroundFit = "contain",
            onClick = function()
                selected_ = item.id
                visible_[item.id] = true
                context_.refresh()
            end,
            children = {
                context.txt("编辑 " .. item.name, 24, active and C.background or C.text,
                    { width = "100%", textAlign = "center" }),
            },
        }
        toggles[#toggles + 1] = createToggle(item)
    end

    local title, _, selectedParams = frameConfig(selected_)
    for _, id in ipairs(order_) do
        local _, frames, value = frameConfig(id)
        local preview = UI.Panel {
            position = "absolute",
            left = 0,
            top = 0,
            width = value.w,
            height = value.h,
            backgroundImage = frames[1],
            backgroundFit = "contain",
            visible = visible_[id] == true,
            opacity = id == selected_ and 1.0 or 0.62,
        }
        refs_.previews[id] = preview
    end
    refs_.reference = UI.Panel {
        position = "absolute",
        left = 330,
        top = 390,
        width = context.runWidth,
        height = context.runHeight,
        backgroundImage = context.assets.ui.referenceFrame,
        backgroundFit = "contain",
    }
    refs_.info = context.txt("", 24, C.textSecondary, { width = "100%" })
    refs_.title = context.txt(title, 32, C.primary, {
        width = "100%",
        textStroke = { width = 2, color = "#000000" },
    })

    local controls = context.pixelPanel {
        width = "100%",
        gap = 12,
        children = {
            refs_.title,
            refs_.info,
            UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 10, children = tabs },
            UI.Panel { width = "100%", flexDirection = "row", flexWrap = "wrap", gap = 10, children = toggles },
            UI.Panel { width = "100%", flexDirection = "row", gap = 10, children = {
                editorButton(paused_ and "继续" or "暂停", function()
                    paused_ = not paused_
                    context_.refresh()
                end, { variant = paused_ and "success" or "secondary", width = 150 }),
                editorButton("复制参数", copySettings, { variant = "primary", width = 180 }),
            } },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                gap = 14,
                children = {
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 10, children = {
                        adjustRow("X偏移", "x", 5),
                        adjustRow("Y偏移", "y", 5),
                        adjustRow("宽度", "w", 10),
                    } },
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 10, children = {
                        adjustRow("高度", "h", 10),
                        adjustRow("缩放", "scale", 0.1),
                        adjustRow("帧率", "fps", 1),
                        UI.Panel { width = "100%", flexDirection = "row", gap = 10, children = {
                            editorButton("重置", function()
                                reset(selectedParams)
                                context_.refresh()
                            end, { variant = "danger", width = 150 }),
                            editorButton("去登塔看效果", function()
                                context_.switchPage("play")
                            end, { variant = "success", width = 220 }),
                        } },
                    } },
                },
            },
            context.multiTxt("提示：先点“编辑”选择要调整的动作，再点“显示/隐藏”同时叠加多套序列帧对比。暂停后画面冻结，方便看大小和位置。点“复制参数”会复制当前全部调帧参数，发给我即可固化到默认代码。", 24, C.textDim, { width = "100%" }),
        },
    }

    local sceneChildren = {
        UI.Panel {
            position = "absolute",
            left = 0,
            top = context.backgroundTop,
            width = context.backgroundWidth,
            bottom = -context.backgroundTop,
            backgroundImage = context.assets.bg,
            backgroundFit = "cover",
            opacity = 0.45,
        },
        refs_.reference,
    }
    for _, id in ipairs(order_) do
        sceneChildren[#sceneChildren + 1] = refs_.previews[id]
    end
    local scene = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        position = "relative",
        overflow = "hidden",
        backgroundImage = context.assets.bg,
        backgroundFit = "cover",
        children = sceneChildren,
    }

    FrameEditorView.Update(0)
    return UI.Panel {
        width = "100%",
        height = "100%",
        padding = 24,
        gap = 14,
        children = { controls, scene },
    }
end

function FrameEditorView.Update(dt)
    if not context_ or not refs_.previews then return end
    if not paused_ then animationTime_ = animationTime_ + (dt or 0) end
    local refLeft = 330
    local refTop = 390
    for _, id in ipairs(order_) do
        local _, frames, value = frameConfig(id)
        local preview = refs_.previews[id]
        if preview then
            preview:SetStyle({
                visible = visible_[id] == true,
                left = refLeft + value.x,
                top = refTop + value.y,
                width = math.max(20, value.w),
                height = math.max(20, value.h),
                scale = value.scale,
                opacity = id == selected_ and 1.0 or 0.62,
                backgroundImage = frameAt(frames, value.fps),
            })
        end
    end
    if refs_.reference then
        refs_.reference:SetStyle({
            left = refLeft,
            top = refTop,
            width = context_.runWidth,
            height = context_.runHeight,
        })
    end
    local title, _, value = frameConfig(selected_)
    if refs_.title then refs_.title:SetText(title .. (paused_ and " / 已暂停" or "")) end
    if refs_.info then
        refs_.info:SetText(string.format(
            "x=%d  y=%d  w=%d  h=%d  fps=%d  scale=%.1f",
            value.x, value.y, value.w, value.h, value.fps, value.scale
        ))
    end
end

function FrameEditorView.GetRunParams()
    return params_.run
end

function FrameEditorView.GetAttackParams(frames, player)
    if player and player.attackFrameSets then
        if frames == player.attackFrameSets[1] then return params_.attackA end
        if frames == player.attackFrameSets[2] then return params_.attackB end
        if frames == player.attackFrameSets[3] then return params_.attackC end
    end
    return params_.attackA
end

return FrameEditorView
