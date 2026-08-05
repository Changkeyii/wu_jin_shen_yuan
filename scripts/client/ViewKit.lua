-- ViewKit.lua
-- 客户端通用控件与格式化工具。
-- 从 GameView.lua 抽出：文本、数值格式化、进度条、按钮、面板等无业务状态的构件。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local LargeNumber = require("shared.LargeNumber")
local BigNumber = require("shared.BigNumber")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS
local MIN_FONT_SIZE = ViewAssets.LAYOUT.MIN_FONT_SIZE

local ViewKit = {}

local function CopyProps(base, extra)
    local t = {}
    if base then for k, v in pairs(base) do t[k] = v end end
    if extra then for k, v in pairs(extra) do t[k] = v end end
    return t
end

local function Clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function ShortenText(text, maxChars)
    text = tostring(text or "")
    maxChars = maxChars or 8
    local count = 0
    local pos = 1
    while pos <= #text do
        local b = string.byte(text, pos)
        local step = 1
        if b >= 240 then step = 4
        elseif b >= 224 then step = 3
        elseif b >= 192 then step = 2 end
        if count + 1 > maxChars then break end
        count = count + 1
        pos = pos + step
    end
    if pos <= #text then
        return string.sub(text, 1, pos - 1) .. "…"
    end
    return text
end

local function FontSize(size)
    return math.max(MIN_FONT_SIZE, size or MIN_FONT_SIZE)
end

local function Txt(text, size, color, props)
    return UI.Label(CopyProps({
        text = text,
        fontSize = FontSize(size),
        fontWeight = "bold",
        fontColor = color or C.text,
        whiteSpace = "nowrap",
    }, props))
end

local function CompactTxt(text, size, color, props)
    return UI.Label(CopyProps({
        text = text,
        fontSize = size or 16,
        fontWeight = "bold",
        fontColor = color or C.text,
        whiteSpace = "nowrap",
    }, props))
end

local function MultiTxt(text, size, color, props)
    return UI.Label(CopyProps({
        text = text,
        fontSize = FontSize(size),
        fontWeight = "bold",
        fontColor = color or C.textSecondary,
        width = "100%",
        whiteSpace = "normal",
        wordBreak = "break-word",
        lineHeight = 1.25,
    }, props))
end

local function FormatInt(v)
    if type(v) == "table" and (v.mantissa ~= nil or v.exponent ~= nil) then
        return BigNumber.Format(v, 4)
    end
    return LargeNumber.Format(v)
end

local function BuildCostItemCard(name, icon, owned, required, enough, options)
    options = options or {}
    local width = options.width or 176
    local height = options.height or 176
    local slotSize = options.slotSize or 106
    local slotLeft = math.floor((width - slotSize) * 0.5)
    local children = {
        UI.Panel {
            position = "absolute",
            left = slotLeft,
            top = 2,
            width = slotSize,
            height = slotSize,
            children = options.itemSlot and { options.itemSlot } or {
                UI.Panel {
                    position = "absolute",
                    left = 0,
                    top = 0,
                    width = slotSize,
                    height = slotSize,
                    backgroundImage = ASSETS.ui.inventorySlotCommon,
                    backgroundFit = "contain",
                    pointerEvents = "none",
                },
                UI.Panel {
                    position = "absolute",
                    left = 18,
                    top = 18,
                    width = slotSize - 36,
                    height = slotSize - 36,
                    backgroundImage = icon,
                    backgroundFit = "contain",
                    opacity = enough and 1.0 or 0.5,
                    pointerEvents = "none",
                },
            },
        },
        CompactTxt(name, 18, C.text, {
            position = "absolute",
            left = 8,
            top = 108,
            width = width - 16,
            height = 28,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        }),
        CompactTxt(FormatInt(owned or 0) .. "/" .. FormatInt(required or 0), 20,
            enough and C.success or C.error, {
                position = "absolute",
                left = 8,
                top = 138,
                width = width - 16,
                height = 30,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
    }
    if not enough then
        children[#children + 1] = UI.Panel {
            position = "absolute",
            left = slotLeft,
            top = 2,
            width = slotSize,
            height = slotSize,
            backgroundImage = ASSETS.ui.selectionFrame,
            backgroundFit = "contain",
            imageTint = C.error,
            opacity = 0.7,
            pointerEvents = "none",
        }
        children[#children + 1] = CompactTxt("不足", 18, C.error, {
            position = "absolute",
            left = slotLeft,
            top = 42,
            width = slotSize,
            height = 30,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        })
    end
    return UI.Panel {
        width = width,
        height = height,
        flexShrink = 0,
        position = "relative",
        overflow = "visible",
        backgroundImage = ASSETS.ui.inventoryItemCard,
        backgroundFit = "contain",
        children = children,
    }
end

local function FormatPercent(v)
    return string.format("%.1f%%", (v or 0) * 100)
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remainingSeconds = seconds % 60
    if hours > 0 then
        return string.format("%d小时%02d分", hours, minutes)
    end
    if minutes > 0 then
        return string.format("%d分%02d秒", minutes, remainingSeconds)
    end
    return string.format("%d秒", remainingSeconds)
end

local function MagnitudeRatio(value, maxValue)
    if type(value) == "table" or type(maxValue) == "table" then
        return Clamp(BigNumber.Ratio(value or 0, maxValue or 1) or 0, 0, 1)
    end
    return Clamp((value or 0) / math.max(1, maxValue or 1), 0, 1)
end

local function ImageProgress(width, height, value, maxValue, trackImage, fillImage)
    local ratio = MagnitudeRatio(value, maxValue)
    local fillClip = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = math.floor(width * ratio),
        height = height,
        overflow = "hidden",
        pointerEvents = "none",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                width = width,
                height = height,
                backgroundImage = fillImage,
                backgroundFit = "contain",
                pointerEvents = "none",
            }
        }
    }
    local root = UI.Panel {
        width = width,
        height = height,
        position = "relative",
        flexShrink = 0,
        backgroundImage = trackImage,
        backgroundFit = "contain",
        children = { fillClip },
    }
    return root, fillClip
end

local function SetImageProgress(fillClip, width, value, maxValue)
    if not fillClip then return end
    local ratio = MagnitudeRatio(value, maxValue)
    fillClip:SetStyle({ width = math.floor(width * ratio) })
end

local function ImageButton(text, width, height, image, onClick, disabled)
    return UI.Panel {
        width = width,
        height = height,
        clickable = not disabled,
        opacity = disabled and 0.45 or 1.0,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = image,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        onClick = function()
            if not disabled and onClick then onClick() end
        end,
        children = {
            CompactTxt(text, 20, C.text, {
                width = "100%",
                height = height,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            })
        }
    }
end

local function PixelPanel(props)
    return UI.Panel(CopyProps({
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        padding = 20,
        gap = 12,
        overflow = "hidden",
    }, props))
end

local function SectionTitle(title, sub)
    return UI.Panel {
        width = "100%",
        gap = 4,
        children = {
            Txt(title, 28, C.text, { width = "100%", textStroke = { width = 2, color = "#000000" } }),
            sub and Txt(sub, 24, C.textSecondary, { width = "100%" }) or nil,
        }
    }
end

ViewKit.CopyProps = CopyProps
ViewKit.Clamp = Clamp
ViewKit.ShortenText = ShortenText
ViewKit.FontSize = FontSize
ViewKit.Txt = Txt
ViewKit.CompactTxt = CompactTxt
ViewKit.MultiTxt = MultiTxt
ViewKit.FormatInt = FormatInt
ViewKit.BuildCostItemCard = BuildCostItemCard
ViewKit.FormatPercent = FormatPercent
ViewKit.FormatDuration = FormatDuration
ViewKit.MagnitudeRatio = MagnitudeRatio
ViewKit.ImageProgress = ImageProgress
ViewKit.SetImageProgress = SetImageProgress
ViewKit.ImageButton = ImageButton
ViewKit.PixelPanel = PixelPanel
ViewKit.SectionTitle = SectionTitle

return ViewKit
