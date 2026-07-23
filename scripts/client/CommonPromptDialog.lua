local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")

local CommonPromptDialog = {}
local C = GameTheme.Colors

local ASSETS = {
    overlay = "image/ui/generated/screen_overlay_1080x1920.png",
    frame = "image/ui/dialog/dialog_frame.png",
    close = "image/ui/dialog/close_button.png",
    confirm = "image/ui/dialog/confirm_button.png",
    danger = "image/ui/inventory/action_red.png",
}

local root_ = nil
local overlay_ = nil
local context_ = nil

local function removeOverlay()
    if overlay_ and root_ then
        root_:RemoveChild(overlay_)
    end
    overlay_ = nil
end

function CommonPromptDialog.Configure(context)
    context_ = context
end

function CommonPromptDialog.AttachRoot(root)
    removeOverlay()
    root_ = root
end

function CommonPromptDialog.Close()
    removeOverlay()
end

function CommonPromptDialog.Show(options)
    if not root_ or not context_ then return false end
    options = options or {}
    removeOverlay()

    local closeOnOverlay = options.closeOnOverlay ~= false
    local onConfirm = options.onConfirm
    local onCancel = options.onCancel
    local showCancelButton = options.cancelText ~= nil
    local function Close()
        CommonPromptDialog.Close()
    end
    local function Cancel()
        Close()
        if onCancel then onCancel() end
    end
    local function Confirm()
        Close()
        if onConfirm then onConfirm() end
    end

    local bodyChildren = {}
    if options.message and options.message ~= "" then
        bodyChildren[#bodyChildren + 1] = context_.multiTxt(options.message, 26, C.text, {
            width = "100%",
            flexShrink = 0,
            textAlign = options.textAlign or "center",
            textStroke = { width = 1, color = "#000000" },
        })
    end
    for _, line in ipairs(options.lines or {}) do
        bodyChildren[#bodyChildren + 1] = context_.multiTxt(line, 22, C.textSecondary, {
            width = "100%",
            flexShrink = 0,
            textAlign = options.textAlign or "center",
            textStroke = { width = 1, color = "#000000" },
        })
    end

    local dialogWidth = 900
    local dialogHeight = 760
    local buttonWidth = 256
    local buttonTop = 676
    local cancelButton = nil
    local confirmButtonLeft = 329
    if showCancelButton then
        confirmButtonLeft = 482
        cancelButton = UI.Panel {
            position = "absolute",
            left = 162,
            top = buttonTop,
            width = buttonWidth,
            height = 80,
            clickable = true,
            backgroundImage = options.cancelImage or ASSETS.confirm,
            backgroundFit = "contain",
            onClick = Cancel,
            children = {
                context_.txt(options.cancelText or "取消", 23, C.text, {
                    position = "absolute",
                    left = 2,
                    top = 17,
                    width = buttonWidth,
                    height = 42,
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        }
    end

    local dialogChildren = {
        context_.txt(options.title or "提示", 32, C.text, {
            position = "absolute",
            left = 112,
            top = 4,
            width = 676,
            height = 54,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        }),
        UI.Panel {
            position = "absolute",
            right = 18,
            top = 12,
            width = 64,
            height = 64,
            clickable = true,
            backgroundImage = ASSETS.close,
            backgroundFit = "contain",
            onClick = Cancel,
        },
        UI.ScrollView {
            position = "absolute",
            left = 74,
            top = 108,
            width = 752,
            height = 510,
            scrollX = false,
            scrollY = true,
            showScrollbar = false,
            children = {
                UI.Panel {
                    width = "100%",
                    flexShrink = 0,
                    gap = 20,
                    paddingLeft = 24,
                    paddingRight = 24,
                    paddingTop = 18,
                    paddingBottom = 18,
                    children = bodyChildren,
                },
            },
        },
        UI.Panel {
            position = "absolute",
            left = confirmButtonLeft,
            top = buttonTop,
            width = buttonWidth,
            height = 80,
            clickable = true,
            backgroundImage = options.confirmImage or (options.danger and ASSETS.danger) or ASSETS.confirm,
            backgroundFit = "contain",
            onClick = Confirm,
            children = {
                context_.txt(options.confirmText or "知道了", 23, C.text, {
                    position = "absolute",
                    left = 2,
                    top = 17,
                    width = buttonWidth,
                    height = 42,
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        },
    }
    if cancelButton then dialogChildren[#dialogChildren + 1] = cancelButton end

    local dialog = UI.Panel {
        position = "absolute",
        left = (1080 - dialogWidth) * 0.5,
        top = (1920 - dialogHeight) * 0.5,
        width = dialogWidth,
        height = dialogHeight,
        clickable = true,
        overflow = "hidden",
        backgroundImage = ASSETS.frame,
        backgroundFit = "sliced",
        backgroundSlice = { 72, 42, 92, 42 },
        children = dialogChildren,
    }

    overlay_ = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = 1080,
        height = 1920,
        zIndex = options.zIndex or 2000,
        pointerEvents = "box-none",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                width = 1080,
                height = 1920,
                clickable = true,
                backgroundImage = ASSETS.overlay,
                backgroundFit = "contain",
                onClick = function()
                    if closeOnOverlay then Cancel() end
                end,
            },
            dialog,
        },
    }
    root_:AddChild(overlay_)
    return true
end

return CommonPromptDialog
