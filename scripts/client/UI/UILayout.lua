local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")

local UILayout = {}

UILayout.Z = {
    background = 0,
    middle = 50,
    topBar = 100,
    bottomNav = 150,
    loading = 1000,
    nonBlocking = 1800,
    modal = 2200,
    blocking = 3300,
    tooltip = 3500,
    reward = 3700,
    tutorial = 4000,
}

-- TapTap 胶囊体下方额外留白（设计像素）。SafeAreaView 已合并 nativeMenuInset，
-- 这里再垫一层，避免标题/返回按钮顶到胶囊体。
UILayout.CAPSULE_EXTRA = 18

UILayout.Type = GameTheme.TypeScale or {
    pageTitle = 32,
    chapterTitle = 26,
    body = 20,
    bodySecondary = 17,
    status = 15,
    badge = 15,
}

UILayout.Radius = GameTheme.Radius or {
    panel = 0,
    button = 0,
    tab = 0,
    badge = 8,
    avatar = 999,
    toast = 8,
}

function UILayout.ContentHeight()
    local CONFIG = GameTheme.CONFIG
    local ViewAssets = require("client.ViewAssets")
    local layout = ViewAssets.LAYOUT
    local designH = CONFIG.DynamicDesignHeight and CONFIG.DynamicDesignHeight() or CONFIG.DesignH
    return math.max(720, designH - (layout.TOP_ZONE_HEIGHT or 310) - (layout.BOTTOM_ZONE_HEIGHT or 170))
end

function UILayout.SafeContent(children, options)
    options = options or {}
    local extraTop = options.extraTop
    if extraTop == nil then extraTop = UILayout.CAPSULE_EXTRA end
    local inner = type(children) == "table" and children or { children }
    if extraTop and extraTop > 0 then
        local padded = {
            UI.Panel {
                width = "100%",
                height = extraTop,
                flexShrink = 0,
                pointerEvents = "none",
            },
        }
        for index = 1, #inner do
            padded[#padded + 1] = inner[index]
        end
        inner = padded
    end
    return UI.SafeAreaView {
        position = options.position or "absolute",
        left = options.left or 0,
        top = options.top or 0,
        right = options.right or 0,
        bottom = options.bottom or 0,
        edges = options.edges or { "top", "bottom" },
        mode = options.mode or "padding",
        nativeMenuInset = options.nativeMenuInset ~= false,
        pointerEvents = options.pointerEvents or "box-none",
        alignItems = options.alignItems or "center",
        children = inner,
    }
end

function UILayout.FullScreenLayer(children, zIndex, options)
    options = options or {}
    return UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        zIndex = zIndex or UILayout.Z.modal,
        clickable = options.clickable == true,
        pointerEvents = options.pointerEvents or "box-none",
        backgroundColor = options.backgroundColor,
        children = children,
    }
end

-- 页面壳：顶部标题固定，中间可滚动，底部操作条固定。
function UILayout.PageShell(options)
    options = options or {}
    local header = options.header
    local body = options.body
    local footer = options.footer
    local children = {}
    if header then children[#children + 1] = header end
    children[#children + 1] = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        overflow = "hidden",
        children = {
            body or UI.Panel { width = "100%", height = "100%" },
        },
    }
    if footer then children[#children + 1] = footer end
    return UI.Panel {
        width = "100%",
        height = "100%",
        flexDirection = "column",
        overflow = "hidden",
        backgroundImage = options.backgroundImage,
        backgroundFit = options.backgroundFit or "cover",
        backgroundColor = options.backgroundColor,
        children = children,
    }
end

return UILayout
