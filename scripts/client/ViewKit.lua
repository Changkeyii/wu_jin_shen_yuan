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

local BUTTON_VARIANTS = {
    primary = { image = ASSETS.ui.dialogConfirm, fontSize = 20, height = 72 },
    secondary = { image = ASSETS.ui.buttonBlue, fontSize = 20, height = 68 },
    danger = { image = ASSETS.ui.inventoryActionRed, fontSize = 20, height = 68 },
    reward = { image = ASSETS.ui.inventoryActionGold, fontSize = 20, height = 68 },
    close = { image = ASSETS.ui.dialogClose, fontSize = 18, height = 64 },
    tab = { image = ASSETS.ui.inventoryTabOff, fontSize = 20, height = 64 },
    nav = { image = ASSETS.ui.navSelected, fontSize = 22, height = 72 },
}

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
        borderRadius = 0,
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

local function ActionButton(options)
    options = options or {}
    local variant = BUTTON_VARIANTS[options.variant or "primary"] or BUTTON_VARIANTS.primary
    local height = options.height or variant.height
    local image = options.image or variant.image
    local disabled = options.disabled == true or options.state == "disabled"
    local root = ImageButton(
        options.text or "",
        options.width or 240,
        height,
        image,
        options.onClick,
        disabled
    )
    if options.id then
        root.id = options.id
        root.props.id = options.id
    end
    return root
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

-- 通用返回按钮：绝对定位，默认左上角，文字「‹ 返回」。
-- @param props table { left, top, width, height, fontSize, text, onClick }
local function BackButton(props)
    props = props or {}
    local width = props.width or 84
    local height = props.height or 64
    local left = props.left or 0
    local top = props.top or 4
    local fontSize = props.fontSize or 22
    return UI.Panel {
        position = "absolute",
        left = left,
        top = top,
        width = width,
        height = height,
        clickable = true,
        onClick = props.onClick,
        children = {
            CompactTxt(props.text or "‹ 返回", fontSize, C.text, {
                width = width, height = height, textAlign = "center",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            }),
        },
    }
end

-- 通用奖励道具小格子：slot 底框 + 道具图标 + 数量（正式格子视觉）。
-- @param props table { icon, name, amount, rarity, size, frame }
local function RewardCell(props)
    props = props or {}
    local size = props.size or 96
    local frame = props.frame or ASSETS.ui.inventorySlotCommon
    -- slot_common 是 180×180，按 size 等比缩放显示
    local iconSize = math.floor(size * 0.58)
    local iconLeft = math.floor((size - iconSize) * 0.5)
    local amountTop = size - 30
    return UI.Panel {
        width = size,
        height = size,
        flexShrink = 0,
        position = "relative",
        backgroundImage = frame,
        backgroundFit = "contain",
        children = {
            UI.Panel {
                position = "absolute", left = iconLeft, top = iconLeft - 2,
                width = iconSize, height = iconSize,
                backgroundImage = props.icon, backgroundFit = "contain",
                pointerEvents = "none",
            },
            CompactTxt(props.amount or "", 15, C.text, {
                position = "absolute", left = 0, top = amountTop,
                width = size, height = 24, textAlign = "center",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            }),
        },
    }
end

-- 通用奖励长格子：顶部标题 + 状态，中间一行道具格子，整体可点击领取。
-- @param props table
--   title string 标题（如「第1天」）
--   rewards table[] { icon, amount } 道具格子数据
--   state string "claimable" | "claimed" | "unclaimed"
--   onClick function 领取回调（仅 claimable 触发）
--   width string|number 宽度（默认 "100%"）
local function RewardStrip(props)
    props = props or {}
    local claimable = props.state == "claimable"
    local claimed = props.state == "claimed"
    local borderColor = claimable and { 255, 214, 110, 255 }
        or (claimed and { 70, 150, 255, 220 } or { 60, 90, 140, 160 })
    local bgColor = claimable and { 40, 52, 18, 235 }
        or (claimed and { 16, 32, 62, 235 } or { 14, 24, 48, 235 })
    local cells = {}
    for _, rw in ipairs(props.rewards or {}) do
        cells[#cells + 1] = RewardCell(rw)
    end
    return UI.Panel {
        width = props.width or "100%",
        flexShrink = 0,
        borderRadius = 0,
        borderWidth = 2,
        borderColor = borderColor,
        backgroundColor = bgColor,
        padding = 12,
        gap = 8,
        clickable = claimable and props.onClick ~= nil,
        onClick = claimable and props.onClick or nil,
        children = {
            UI.Panel {
                width = "100%", flexShrink = 0,
                flexDirection = "row", alignItems = "center", justifyContent = "space-between",
                children = {
                    CompactTxt(props.title or "", 22, claimable and C.gold or C.text, {
                        textAlign = "left", textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                    }),
                    CompactTxt(claimable and "点击领取" or (claimed and "已领取" or "未领取"), 17,
                        claimable and C.gold or (claimed and C.textSecondary or C.textDim), {
                        textAlign = "right", textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                    }),
                },
            },
            UI.Panel {
                width = "100%", flexShrink = 0,
                flexDirection = "row", justifyContent = "center", gap = 12,
                children = cells,
            },
        },
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
ViewKit.ActionButton = ActionButton
ViewKit.BUTTON_VARIANTS = BUTTON_VARIANTS
ViewKit.PixelPanel = PixelPanel
ViewKit.SectionTitle = SectionTitle
ViewKit.BackButton = BackButton
ViewKit.RewardCell = RewardCell
ViewKit.RewardStrip = RewardStrip

return ViewKit
