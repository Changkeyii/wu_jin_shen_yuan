local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local DialogCoordinator = require("client.DialogCoordinator")

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
    DialogCoordinator.Configure {
        present = CommonPromptDialog.Present,
        dismiss = removeOverlay,
    }
end

function CommonPromptDialog.Close()
    return DialogCoordinator.CancelActive()
end

function CommonPromptDialog.Present(options, finish)
    if not root_ or not context_ then
        if finish then finish("cancel") end
        return false
    end
    options = options or {}
    removeOverlay()

    local closeOnOverlay = options.closeOnOverlay ~= false
    local pages = options.pages or options.storyLines
    local pageIndex = 1
    local dialogWidth = 900
    local dialogHeight = 760
    local buttonWidth = 300
    local buttonTop = dialogHeight - 126

    local function Cancel()
        removeOverlay()
        if finish then finish("cancel") end
    end

    local RenderPage
    local function Confirm()
        if type(pages) == "table" and pageIndex < #pages then
            pageIndex = pageIndex + 1
            if options.onPageAdvance then
                local ok, reason = pcall(options.onPageAdvance, pageIndex, pages[pageIndex])
                if not ok then print("[CommonPromptDialog] page callback failed: " .. tostring(reason)) end
            end
            RenderPage()
            return
        end
        removeOverlay()
        if finish then finish("confirm") end
    end

    RenderPage = function()
        removeOverlay()
        local page = type(pages) == "table" and pages[pageIndex] or nil
        local pageMessage = options.message
        local pageLines = options.lines or {}
        local pageTitle = options.title or "提示"
        if type(page) == "string" then
            pageMessage = page
            pageLines = {}
        elseif type(page) == "table" then
            pageMessage = page.message or page.text or page.line or ""
            pageLines = page.lines or {}
            pageTitle = page.title or page.speaker or pageTitle
        end

        local bodyChildren = {}
        if pageMessage and pageMessage ~= "" then
            bodyChildren[#bodyChildren + 1] = context_.multiTxt(pageMessage, 26, C.text, {
                width = "100%", flexShrink = 0,
                textAlign = options.textAlign or "center",
                textStroke = { width = 1, color = "#000000" },
            })
        end
        for _, line in ipairs(pageLines) do
            bodyChildren[#bodyChildren + 1] = context_.multiTxt(line, 22, C.textSecondary, {
                width = "100%", flexShrink = 0,
                textAlign = options.textAlign or "center",
                textStroke = { width = 1, color = "#000000" },
            })
        end
        if type(pages) == "table" and #pages > 1 then
            bodyChildren[#bodyChildren + 1] = context_.txt(
                string.format("%d / %d", pageIndex, #pages), 18, C.textDim,
                { width = "100%", height = 28, textAlign = "center" }
            )
        end

        local showCancelButton = options.cancelText ~= nil or (type(pages) == "table" and #pages > 0)
        local confirmButtonLeft = showCancelButton and 490 or 300
        local dialogChildren = {
            context_.txt(pageTitle, 32, C.text, {
                position = "absolute", left = 56, top = 34,
                width = dialogWidth - 112, height = 72, textAlign = "center",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            }),
            UI.Panel {
                position = "absolute", right = 24, top = 28,
                width = 64, height = 64, clickable = true,
                backgroundImage = ASSETS.close, backgroundFit = "contain", onClick = Cancel,
            },
            UI.ScrollView {
                position = "absolute", left = 60, top = 118,
                width = dialogWidth - 120, height = dialogHeight - 266,
                scrollX = false, scrollY = true, showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%", flexShrink = 0, gap = 20,
                        paddingLeft = 24, paddingRight = 24,
                        paddingTop = 18, paddingBottom = 18,
                        children = bodyChildren,
                    },
                },
            },
            UI.Panel {
                position = "absolute", left = confirmButtonLeft, top = buttonTop,
                width = buttonWidth, height = 82, clickable = true,
                backgroundImage = options.confirmImage or (options.danger and ASSETS.danger) or ASSETS.confirm,
                backgroundFit = "contain", onClick = Confirm,
                children = {
                    context_.txt(
                        (type(pages) == "table" and pageIndex < #pages) and "下一句" or (options.confirmText or "知道了"),
                        23, C.text,
                        { width = "100%", height = 82, textAlign = "center", textStroke = { width = 2, color = "#000000" }, pointerEvents = "none" }
                    ),
                },
            },
        }
        if showCancelButton then
            dialogChildren[#dialogChildren + 1] = UI.Panel {
                position = "absolute", left = 110, top = buttonTop,
                width = buttonWidth, height = 82, clickable = true,
                backgroundImage = options.cancelImage or ASSETS.confirm,
                backgroundFit = "contain", onClick = Cancel,
                children = {
                    context_.txt(options.cancelText or "跳过", 23, C.text, {
                        width = "100%", height = 82, textAlign = "center",
                        textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                    }),
                },
            }
        end

        local dialog = UI.Panel {
            position = "relative", width = dialogWidth, height = dialogHeight,
            clickable = true, overflow = "hidden",
            backgroundImage = ASSETS.frame, backgroundFit = "sliced",
            backgroundSlice = { 72, 42, 92, 42 }, children = dialogChildren,
        }
        overlay_ = UI.Panel {
            position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
            zIndex = options.zIndex or 2000, pointerEvents = "box-none",
            alignItems = "center", justifyContent = "center",
            children = {
                UI.Panel {
                    position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
                    clickable = true, backgroundImage = ASSETS.overlay, backgroundFit = "cover",
                    onClick = function() if closeOnOverlay then Cancel() end end,
                },
                dialog,
            },
        }
        root_:AddChild(overlay_)
    end

    RenderPage()
    return true
end

function CommonPromptDialog.Show(options)
    return DialogCoordinator.Enqueue(options or {})
end

function CommonPromptDialog.Reset()
    DialogCoordinator.Clear(false)
    removeOverlay()
    root_ = nil
end

return CommonPromptDialog
