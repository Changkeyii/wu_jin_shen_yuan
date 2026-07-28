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
    local maxPageReached = 1
    local dialogWidth = options.dialogWidth or 900
    local dialogHeight = options.dialogHeight or 760
    local buttonWidth = 300
    local buttonGap = 80
    local buttonTop = options.buttonTop or (dialogHeight - 96)

    local function Cancel()
        removeOverlay()
        if finish then finish("cancel") end
    end

    local RenderPage
    local function SetPage(nextPageIndex)
        if type(pages) ~= "table" or #pages == 0 then return end
        nextPageIndex = math.max(1, math.min(#pages, nextPageIndex))
        if nextPageIndex == pageIndex then return end
        local movingForward = nextPageIndex > pageIndex
        pageIndex = nextPageIndex
        if movingForward and pageIndex > maxPageReached then
            maxPageReached = pageIndex
            if options.onPageAdvance then
                local ok, reason = pcall(options.onPageAdvance, pageIndex, pages[pageIndex])
                if not ok then print("[CommonPromptDialog] page callback failed: " .. tostring(reason)) end
            end
        end
        RenderPage()
    end

    local function Confirm()
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

        local hasPages = type(pages) == "table" and #pages > 0
        local hasMultiplePages = hasPages and #pages > 1
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
        if type(options.contentBuilder) == "function" then
            local ok, content = pcall(options.contentBuilder, page, pageIndex)
            if ok and content then
                bodyChildren[#bodyChildren + 1] = content
            elseif not ok then
                print("[CommonPromptDialog] content builder failed: " .. tostring(content))
            end
        elseif options.content then
            bodyChildren[#bodyChildren + 1] = options.content
        end
        if type(pages) == "table" and #pages > 1 then
            bodyChildren[#bodyChildren + 1] = context_.txt(
                string.format("%d / %d", pageIndex, #pages), 18, C.textDim,
                { width = "100%", height = 28, textAlign = "center" }
            )
        end

        local showCancelButton = options.cancelText ~= nil or hasPages
        local showCloseButton = options.showClose ~= false
        local showConfirmButton = options.showConfirm ~= false
        local canConfirm = not hasPages or pageIndex == #pages
        local buttonGroupWidth = showCancelButton
            and (buttonWidth * 2 + buttonGap)
            or buttonWidth
        local buttonGroupLeft = math.floor((dialogWidth - buttonGroupWidth) * 0.5)
        local cancelButtonLeft = options.cancelButtonLeft or buttonGroupLeft
        local confirmButtonLeft = options.confirmButtonLeft or (showCancelButton
            and (buttonGroupLeft + buttonWidth + buttonGap)
            or buttonGroupLeft)
        local contentSideInset = hasMultiplePages and 104 or 60
        local contentWidth = dialogWidth - contentSideInset * 2
        local dialogChildren = {
            context_.txt(pageTitle, 32, C.text, {
                position = "absolute", left = 56, top = options.titleTop or 4,
                width = dialogWidth - 112, height = 72, textAlign = "center",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            }),
            UI.ScrollView {
                position = "absolute", left = contentSideInset, top = 104,
                width = contentWidth, height = dialogHeight - 248,
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
        }
        if hasMultiplePages then
            dialogChildren[#dialogChildren + 1] = UI.Panel {
                position = "absolute", left = 32, top = 316,
                width = 64, height = 96, clickable = pageIndex > 1,
                opacity = pageIndex > 1 and 1.0 or 0.28,
                alignItems = "center", justifyContent = "center",
                onClick = function() SetPage(pageIndex - 1) end,
                children = {
                    context_.txt("‹", 54, C.text, {
                        width = 64, height = 96, textAlign = "center",
                        textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                    }),
                },
            }
            dialogChildren[#dialogChildren + 1] = UI.Panel {
                position = "absolute", right = 32, top = 316,
                width = 64, height = 96, clickable = pageIndex < #pages,
                opacity = pageIndex < #pages and 1.0 or 0.28,
                alignItems = "center", justifyContent = "center",
                onClick = function() SetPage(pageIndex + 1) end,
                children = {
                    context_.txt("›", 54, C.text, {
                        width = 64, height = 96, textAlign = "center",
                        textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                    }),
                },
            }
        end
        if showConfirmButton then
            dialogChildren[#dialogChildren + 1] = UI.Panel {
                position = "absolute", left = confirmButtonLeft, top = buttonTop,
                width = buttonWidth, height = 82, clickable = canConfirm,
                opacity = canConfirm and 1.0 or 0.35,
                backgroundImage = options.confirmImage or (options.danger and ASSETS.danger) or ASSETS.confirm,
                backgroundFit = "contain", onClick = Confirm,
                children = {
                    context_.txt(options.confirmText or "知道了",
                        23, C.text,
                        { width = "100%", height = 82, textAlign = "center", textStroke = { width = 2, color = "#000000" }, pointerEvents = "none" }
                    ),
                },
            }
        end
        if showCloseButton then
            dialogChildren[#dialogChildren + 1] = UI.Panel {
                position = "absolute", right = options.closeRight or 24, top = options.closeTop or 28,
                width = 64, height = 64, clickable = true,
                backgroundImage = ASSETS.close, backgroundFit = "contain", onClick = Cancel,
            }
        end
        if showCancelButton then
            dialogChildren[#dialogChildren + 1] = UI.Panel {
                position = "absolute", left = cancelButtonLeft, top = buttonTop,
                width = buttonWidth, height = 82, clickable = true,
                backgroundImage = options.cancelImage or ASSETS.confirm,
                backgroundFit = "contain", onClick = Cancel,
                children = {
                    context_.txt(options.cancelText or "跳过", 23, C.text, {
                        left = options.cancelTextLeft,
                        top = options.cancelTextTop,
                        width = "100%", height = 82, textAlign = "center",
                        textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                    }),
                },
            }
        end

        local dialog = UI.Panel {
            position = "relative", width = dialogWidth, height = dialogHeight,
            clickable = true, overflow = "hidden",
            backgroundColor = { 14, 24, 48, 255 },
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
