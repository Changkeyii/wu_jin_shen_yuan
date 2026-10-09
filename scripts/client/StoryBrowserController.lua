-- StoryBrowserController.lua
-- 剧情入口：首页「万灵记忆」打开的全屏剧情浏览层。
-- 展示序章（新手剧情，可重播）+ 已解锁章节（StoryCatalog），点击播放插画对话。
-- 台词权威文本见 docs/story/，修改需同步。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local GameStateAdapter = require("client.GameStateAdapter")
local StoryCatalog = require("shared.StoryCatalog")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local StoryBrowserController = {}

local LAYER_Z = 3100

local root_ = nil
local layer_ = nil
local dialogLayer_ = nil

-- 序章剧情（docs/story/01-新手序章剧情.md）：5 段塔灵台词，重播用
local PROLOGUE_PAGES = {
    {
        title = "塔灵的低语",
        lines = {
            "欢迎来到万灵塔，后来者。",
            "我叫不出你的名字——不是不愿，是你自己把它弄丢了。",
            "如果你想知道自己是谁，就向上走。塔会把你失去的，一层一层还给你。",
        },
    },
    {
        title = "战斗的馈赠",
        lines = {
            "很好。你听见了——那是力量落进掌心时的声音。",
            "看看你的行囊：一件武器，一件护具。",
            "先去装备页，把武器握进手里。",
        },
    },
    {
        title = "物尽其用",
        lines = {
            "武器已经就位。但行囊里那件多余的白装，留着只会蒙尘。",
            "深渊不会因为你的慷慨而手下留情——每一分资源都要变成力量。",
            "去分解它。碎片会化作强化与升星的基石。",
        },
    },
    {
        title = "百炼成钢",
        lines = {
            "碎片已经在手。强化你身上的武器，让它真正属于这场战斗。",
            "记住：你的名字可以被忘记，但你的锋芒不会。",
            "每一次强化，都是通往更高层的一步。",
        },
    },
    {
        title = "初试锋芒",
        lines = {
            "你已经学会了塔的生存之道：战斗、拾取、取舍、打磨。",
            "现在，凭自己的力量，登上一整层楼。",
            "我在这里等你归来——更高处，有人在等你。",
        },
    },
}

local function Toast(message, variant)
    UI.Toast.Show(tostring(message), { duration = 2.4, variant = variant or "info", position = "bottom" })
end

local function RemoveLayer()
    if layer_ and root_ then root_:RemoveChild(layer_) end
    layer_ = nil
end

local function RemoveDialog()
    if dialogLayer_ then
        local parent = dialogLayer_.parent
        if parent then parent:RemoveChild(dialogLayer_) end
    end
    dialogLayer_ = nil
end

--- 播放一段剧情对话（立绘 + 逐页台词）。
--- entry: { title, portrait, pages = { {title, lines[]} } }
local function PlayChapter(entry)
    if not root_ or not entry then return end
    RemoveDialog()
    local pages = entry.pages or {}
    if #pages == 0 then return end
    local pageIndex = 1

    local function RenderPage()
        RemoveDialog()
        local page = pages[pageIndex]
        local lastPage = pageIndex >= #pages
        dialogLayer_ = UI.Panel {
            position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
            zIndex = LAYER_Z + 200,
            clickable = true,
            backgroundColor = { 4, 10, 22, 220 },
            children = {
                -- 背景插画（登塔背景）
                UI.Panel {
                    position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
                    backgroundImage = ASSETS.bg,
                    backgroundFit = "cover",
                    opacity = 0.28,
                    pointerEvents = "none",
                },
                -- 中央对话卡
                UI.Panel {
                    position = "absolute",
                    left = 120, right = 120,
                    top = 240, height = 1180,
                    alignItems = "center",
                    justifyContent = "flex-start",
                    gap = 22,
                    paddingTop = 44,
                    paddingLeft = 44,
                    paddingRight = 44,
                    backgroundImage = ASSETS.ui.panelLarge,
                    backgroundFit = "sliced",
                    backgroundSlice = { 12, 12, 12, 12 },
                    borderWidth = 3,
                    borderColor = C.border,
                    borderRadius = 16,
                    boxShadow = { color = { 0, 0, 0, 200 }, offsetX = 0, offsetY = 12, blurRadius = 26 },
                    children = {
                        UI.Panel {
                            width = 200, height = 400, flexShrink = 0,
                            backgroundImage = entry.portrait,
                            backgroundFit = "contain",
                        },
                        Kit.Txt(page.title or entry.title or "万灵记忆", 30, C.gold, {
                            width = "100%", height = 44, textAlign = "center",
                            textStroke = { width = 2, color = "#000000" },
                        }),
                        UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 12, children = (function()
                            ---@type any[]
                            local lineWidgets = {}
                            for _, line in ipairs(page.lines or {}) do
                                lineWidgets[#lineWidgets + 1] = Kit.MultiTxt(line, 23, C.text, {
                                    width = "100%", textAlign = "center",
                                    maxLines = 3, textStroke = { width = 1, color = "#000000" },
                                })
                            end
                            return lineWidgets
                        end)() },
                        Kit.ImageButton(
                            lastPage and "结束" or "继续",
                            240, 72,
                            ASSETS.ui.dialogConfirm,
                            function()
                                if lastPage then
                                    RemoveDialog()
                                    return
                                end
                                pageIndex = pageIndex + 1
                                RenderPage()
                            end,
                            false
                        ),
                    },
                },
            },
        }
        require("client.UI.DialogSettingsAccess").Attach(dialogLayer_, false, { right = 40, top = 782, marginTop = 0 })
        root_:AddChild(dialogLayer_)
    end

    RenderPage()
end

--- 打开剧情浏览层。
function StoryBrowserController.Show()
    if not root_ then return false end
    RemoveLayer()
    RemoveDialog()
    local game = GameStateAdapter.GetViewState()
    local maxFloor = math.max(1, math.floor(game.maxFloor or game.floor or 1))

    ---@type any[]
    local entries = {}
    -- 序章（始终可播）
    entries[#entries + 1] = {
        title = "序章·残刃与第一座塔",
        subtitle = "塔灵的低语 · 可重播",
        unlocked = true,
        portrait = ASSETS.ui.towerSpirit,
        pages = PROLOGUE_PAGES,
    }
    -- 章节（StoryCatalog 1~5 章实装，按 maxFloor 解锁）
    for _, chapter in ipairs(StoryCatalog.GetAllChapters() or {}) do
        local floor = math.floor(chapter.floor or 10)
        local pages = {}
        if chapter.opening and #chapter.opening > 0 then
            pages[#pages + 1] = { title = "序", lines = chapter.opening }
        end
        if chapter.boss and #chapter.boss > 0 then
            pages[#pages + 1] = { title = "对决", lines = chapter.boss }
        end
        if chapter.memory and #chapter.memory > 0 then
            pages[#pages + 1] = { title = "记忆", lines = chapter.memory }
        end
        entries[#entries + 1] = {
            title = chapter.title,
            subtitle = "登顶第 " .. tostring(floor) .. " 层解锁",
            unlocked = maxFloor >= floor,
            portrait = ASSETS.ui.towerKeeper,
            pages = pages,
        }
    end

    ---@type any[]
    local rows = {}
    for _, entry in ipairs(entries) do
        local unlocked = entry.unlocked
        rows[#rows + 1] = UI.Panel {
            width = "100%",
            flexShrink = 0,
            padding = 18,
            gap = 8,
            clickable = unlocked,
            backgroundImage = ASSETS.ui.panelLarge,
            backgroundFit = "sliced",
            backgroundSlice = { 12, 12, 12, 12 },
            backgroundColor = { 10, 31, 72, 242 },
            borderWidth = 2,
            borderColor = unlocked and C.focus or C.border,
            borderRadius = 14,
            opacity = unlocked and 1.0 or 0.6,
            onClick = function()
                if not unlocked then
                    Toast(entry.subtitle, "info")
                    return
                end
                PlayChapter(entry)
            end,
            children = {
                Kit.Txt(entry.title, 26, unlocked and C.text or C.textDim, {
                    width = "100%", height = 40, textAlign = "left",
                    textStroke = { width = 2, color = "#000000" },
                }),
                Kit.CompactTxt(entry.subtitle, 16, unlocked and C.textSecondary or C.textDim, {
                    width = "100%", height = 26, textAlign = "left",
                }),
            },
        }
    end

    layer_ = UI.Panel {
        position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        zIndex = LAYER_Z,
        clickable = true,
        -- 与其他界面一致的正式背景板
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        backgroundColor = { 10, 26, 52, 255 },
        children = {
            UI.Panel {
                width = "100%", height = "100%", flexShrink = 0,
                paddingLeft = 40, paddingRight = 40, paddingTop = 20, paddingBottom = 28,
                gap = 14,
                children = {
                    UI.Panel {
                        width = "100%", flexShrink = 0, height = 76, position = "relative",
                        children = {
                            Kit.Txt("万灵记忆", 34, C.gold, {
                                position = "absolute", left = 0, top = 8, width = 1000, height = 56,
                                textAlign = "center", textStroke = { width = 3, color = "#000000" },
                            }),
                            Kit.BackButton {
                                onClick = function() StoryBrowserController.Close() end,
                            },
                        },
                    },
                    Kit.CompactTxt("塔灵记录着登塔者的故事。登得越高，记忆越完整。", 16, C.textSecondary, {
                        width = "100%", height = 28, textAlign = "center",
                    }),
                    UI.ScrollView {
                        width = "100%", flexGrow = 1, flexBasis = 0,
                        scrollY = true, scrollX = false, showScrollbar = false,
                        children = {
                            UI.Panel {
                                width = "100%", flexShrink = 0, gap = 14, paddingBottom = 24,
                                children = rows,
                            },
                        },
                    },
                },
            },
        },
    }
    root_:AddChild(layer_)
    return true
end

function StoryBrowserController.Close()
    RemoveDialog()
    RemoveLayer()
end

function StoryBrowserController.IsOpen()
    return layer_ ~= nil
end

function StoryBrowserController.AttachRoot(root)
    root_ = root
end

function StoryBrowserController.Reset()
    RemoveDialog()
    RemoveLayer()
end

return StoryBrowserController
