local UI = require("urhox-libs/UI")

local CONFIG = {
    Title = "无尽深渊挂机录",
    designWidth = 1080,
    designHeight = 1920,
    DesignW = 1080,
    DesignH = 1920,
    StepSeconds = 3.0,
    OfflineMaxSeconds = 12 * 60 * 60,
}

-- 设计基准 1080×1920。取「宽/高两个方向缩放比例中更紧的」作为全局 UI 缩放：
-- 标准竖屏手机（高宽比 ≥ 1.78）以宽度为基准、高度动态扩展，与之前一致；
-- 矮屏（如 iPad，高宽比 < 1.78）时按高度缩放整个根界面，保证内容完整一屏、不超屏。
-- 全局 scale 参与命中测试（事件坐标同步换算），不会出现局部缩放导致的点击错位。
function CONFIG.ViewportScale()
    local physicalWidth = graphics and graphics.GetWidth and graphics:GetWidth() or CONFIG.DesignW
    local physicalHeight = graphics and graphics.GetHeight and graphics:GetHeight() or CONFIG.DesignH
    local widthScale = physicalWidth / CONFIG.DesignW
    local heightScale = physicalHeight / CONFIG.DesignH
    return math.max(0.01, math.min(widthScale, heightScale))
end

function CONFIG.DynamicDesignHeight()
    local physicalHeight = graphics and graphics.GetHeight and graphics:GetHeight() or CONFIG.DesignH
    return physicalHeight / CONFIG.ViewportScale()
end

local C = {
    primary = {31, 162, 255, 255},
    primaryHover = {70, 183, 255, 255},
    primaryPressed = {13, 126, 230, 255},
    secondary = {214, 53, 255, 255},
    secondaryHover = {224, 97, 255, 255},
    secondaryPressed = {181, 35, 232, 255},
    background = {34, 89, 183, 255},
    background2 = {22, 49, 122, 255},
    surface = {33, 69, 138, 244},
    surfaceDark = {10, 16, 32, 248},
    surfaceHover = {45, 102, 200, 255},
    text = {255, 255, 255, 255},
    textSecondary = {213, 226, 255, 255},
    textDim = {139, 150, 184, 255},
    border = {10, 16, 32, 255},
    focus = {111, 231, 255, 255},
    gold = {255, 198, 26, 255},
    orange = {255, 163, 24, 255},
    hp = {245, 50, 45, 255},
    mp = {52, 185, 255, 255},
    xp = {73, 217, 75, 255},
    success = {67, 213, 44, 255},
    warning = {255, 198, 26, 255},
    error = {245, 50, 45, 255},
}

local HUD_SHADOW = {
    { x = 6, y = 6, blur = 0, color = {0, 0, 0, 64} },
}

local BTN_SHADOW = {
    { x = 6, y = 6, blur = 0, color = {0, 0, 0, 51} },
}

local BrawlForgeTheme = UI.Theme.ExtendTheme(UI.Theme.defaultTheme, {
    fonts = {
        { family = "sans", weights = {
            normal = "Fonts/NotoSansSC-Black.ttf",
            bold = "Fonts/NotoSansSC-Black.ttf",
        }},
    },
    colors = {
        primary = C.primary,
        primaryHover = C.primaryHover,
        primaryPressed = C.primaryPressed,
        secondary = C.secondary,
        secondaryHover = C.secondaryHover,
        secondaryPressed = C.secondaryPressed,
        background = C.background,
        surface = C.surface,
        surfaceHover = C.surfaceHover,
        text = C.text,
        textSecondary = C.textSecondary,
        textDisabled = {157, 166, 198, 255},
        border = C.border,
        borderFocus = C.focus,
        disabled = {57, 71, 107, 255},
        disabledText = {139, 150, 184, 255},
        success = C.success,
        successHover = {98, 232, 78, 255},
        warning = C.warning,
        warningHover = {255, 215, 85, 255},
        error = C.error,
        errorHover = {255, 90, 71, 255},
        info = C.mp,
        overlay = {7, 16, 28, 187},
        hover = {255, 255, 255, 25},
    },
    radius = {
        none = 0,
        sm = 0,
        md = 0,
        lg = 0,
        xl = 0,
        full = 0,
    },
    spacing = {
        xs = 4,
        sm = 8,
        md = 12,
        lg = 16,
        xl = 24,
        xxl = 32,
    },
    typography = {
        fontFamily = "sans",
        h1 = { fontSize = 32 },
        h2 = { fontSize = 26 },
        h3 = { fontSize = 22 },
        body = { fontSize = 20 },
        bodySmall = { fontSize = 17 },
        caption = { fontSize = 15 },
    },
    componentDefaults = {
        borderRadius = 0,
        fontWeight = "bold",
    },
    components = {
        Button = {
            borderWidth = {2, 4, 4, 2},
            borderRadius = 0,
            height = 64,
            fontSize = 20,
            fontWeight = "bold",
            padding = {4, 6, 10, 4},
            boxShadow = BTN_SHADOW,
        },
        Card = {
            borderWidth = 3,
            borderRadius = 0,
            borderColor = C.border,
            boxShadow = HUD_SHADOW,
        },
        ProgressBar = {
            borderRadius = 0,
            height = 18,
            borderWidth = 3,
            borderColor = C.border,
        },
        Badge = { borderWidth = 2, borderRadius = 8 },
        Chip = { borderWidth = 3, borderRadius = 0 },
        Alert = { borderWidth = 3, borderRadius = 0 },
        Tabs = {
            borderWidth = 3,
            borderRadius = 0,
            activeBorderColor = C.focus,
            activeBgColor = C.primary,
            inactiveTextColor = C.textSecondary,
            variantTabHeight = { line = 70, pills = 70, enclosed = 76 },
            variantTabGap = { pills = 8 },
            variantBorderRadius = { pills = 0, enclosed = 0 },
        },
        Modal = {
            borderWidth = 3,
            borderRadius = 0,
            boxShadow = HUD_SHADOW,
            headerBgColor = {14, 137, 255, 255},
            contentBgColor = C.surface,
            headerBorderWidth = 5,
        },
        Toast = {
            borderWidth = 2,
            borderRadius = 8,
            boxShadow = HUD_SHADOW,
        },
    },
})

local RARITIES = {
    gold_green = { id = "gold_green", name = "金币", short = "绿", rank = 0, color = {90, 255, 145, 255}, beam = {65, 238, 118, 245}, mult = 1.0, fragment = 0 },
    common = { id = "common", name = "普通", short = "白", rank = 1, color = {232, 239, 255, 255}, beam = {220, 235, 255, 235}, mult = 0.90, fragment = 1 },
    advanced = { id = "advanced", name = "高级", short = "蓝", rank = 2, color = {38, 182, 255, 255}, beam = {25, 170, 255, 245}, mult = 0.95, fragment = 2 },
    rare = { id = "rare", name = "稀有", short = "紫", rank = 3, color = {193, 60, 255, 255}, beam = {179, 54, 255, 245}, mult = 1.00, fragment = 5 },
    artifact = { id = "artifact", name = "神器", short = "粉", rank = 4, color = {255, 91, 193, 255}, beam = {255, 74, 188, 245}, mult = 1.07, fragment = 10 },
    legendary = { id = "legendary", name = "传说", short = "赤", rank = 5, color = {255, 140, 0, 255}, beam = {255, 130, 0, 245}, mult = 1.15, fragment = 18 },
    epic = { id = "epic", name = "史诗", short = "橙金", rank = 6, color = {255, 177, 34, 255}, beam = {255, 156, 24, 250}, mult = 1.25, fragment = 36 },
    myth = { id = "myth", name = "神话", short = "七彩", rank = 7, color = {255, 45, 45, 255}, beam = {255, 40, 40, 250}, mult = 1.40, fragment = 80, dynamic = true },
}

-- Legacy IDs are presentation aliases only. Authoritative V5 snapshots use
-- common/advanced/rare/artifact/legendary/epic/myth.
RARITIES.blue = RARITIES.advanced
RARITIES.purple = RARITIES.rare
RARITIES.legend = RARITIES.legendary

local RARITY_ORDER = { "common", "advanced", "rare", "artifact", "legendary", "epic", "myth" }

local CATEGORIES = {
    { id = "weapon", name = "武器" },
    { id = "armor", name = "防具" },
    { id = "jewelry", name = "首饰" },
    { id = "special", name = "特殊" },
    { id = "consumable", name = "消耗品" },
    { id = "material", name = "材料" },
}

local SLOTS = {
    { id = "weapon", name = "武器", category = "weapon", short = "武" },
    { id = "shoulder", name = "头肩", category = "armor", short = "肩" },
    { id = "coat", name = "上衣", category = "armor", short = "衣" },
    { id = "pants", name = "下装", category = "armor", short = "裤" },
    { id = "belt", name = "腰带", category = "armor", short = "带" },
    { id = "shoes", name = "鞋", category = "armor", short = "鞋" },
    { id = "bracelet", name = "手镯", category = "jewelry", short = "镯" },
    { id = "necklace", name = "项链", category = "jewelry", short = "链" },
    { id = "ring", name = "戒指", category = "jewelry", short = "戒" },
    { id = "support", name = "辅助装备", category = "special", short = "辅" },
    { id = "magicstone", name = "魔法石", category = "special", short = "石" },
    { id = "earring", name = "耳环", category = "special", short = "耳" },
}

local SET_ORDER = { "nightmare", "lucky", "voyage", "abyss", "prophecy" }
local SETS = {
    nightmare = { name = "绝望的噩梦·地狱之路", short = "噩梦", style = "血量换伤", mythSlot = "earring", mythName = "终末的宿命", color = C.error },
    lucky = { name = "幸运三角·命运的骰子", short = "幸运", style = "摸奖爆发", mythSlot = "bracelet", mythName = "幸运的第七只手", color = C.gold },
    voyage = { name = "永恒之旅·军神的隐秘", short = "军神", style = "速度压制", mythSlot = "support", mythName = "军神的远古地图", color = C.mp },
    abyss = { name = "深渊窥视者·黑暗祭祀", short = "深渊", style = "吸血永动", mythSlot = "coat", mythName = "吞噬深渊的祭袍", color = C.secondary },
    prophecy = { name = "古代祭祀·神圣预言", short = "预言", style = "越战越强", mythSlot = "ring", mythName = "千魂祭的预言戒指", color = C.success },
}

local EVENT_INFO = {
    monster = { name = "普通怪物", short = "怪", color = C.primary },
    elite = { name = "精英怪物", short = "精", color = C.secondary },
    chest = { name = "宝箱", short = "箱", color = C.gold },
    merchant = { name = "商人", short = "商", color = C.success },
    random = { name = "随机事件", short = "事", color = C.mp },
    boss = { name = "首领", short = "王", color = C.error },
}

local TypeScale = {
    pageTitle = 32,
    chapterTitle = 26,
    body = 20,
    bodySecondary = 17,
    status = 15,
    badge = 15,
}

local Radius = {
    panel = 0,
    button = 0,
    tab = 0,
    badge = 8,
    avatar = 999,
    toast = 8,
}

return {
    CONFIG = CONFIG,
    Colors = C,
    Theme = BrawlForgeTheme,
    Rarities = RARITIES,
    RarityOrder = RARITY_ORDER,
    Categories = CATEGORIES,
    Slots = SLOTS,
    SetOrder = SET_ORDER,
    Sets = SETS,
    EventInfo = EVENT_INFO,
    TypeScale = TypeScale,
    Radius = Radius,
}
