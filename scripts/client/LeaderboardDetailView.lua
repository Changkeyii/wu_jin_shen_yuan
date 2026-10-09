-- LeaderboardDetailView.lua
-- 排行榜玩家详情弹窗（独立高优先级弹窗，直接盖在排行榜之上）：
--   · 复用通用 EquipmentLoadoutPanel（12 部位全展示），点击装备仅弹只读 ItemTips（无分解/出售）
--   · 顶部战力条 → 装备展示 → 底部「个性展示」：看自己可下拉切换垃圾话，看别人展示其设置的垃圾话
-- 不走 CommonPromptDialog 的排队机制，自己作为 overlay 挂到 root，保证立即显示在排行榜上层。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local TrashTalk = require("shared.TrashTalk")
local EquipmentLoadoutPanel = require("client.EquipmentLoadoutPanel")
local ItemTips = require("client.ItemTips")
local ServerClient = require("client.ServerClient")

local C = GameTheme.Colors
local SETS = GameTheme.Sets
local ASSETS = ViewAssets.ASSETS

-- 高于 CommonPromptDialog overlay(2000)、低于 ItemTips layer(3500)
local LAYER_Z = 2500

local DIALOG_W = 1080
local DIALOG_H = 1420
local BODY_TOP = 100
local BODY_HEIGHT = 1180
local BUTTON_TOP = 1336

---@type Widget|nil
local root_ = nil
---@type Widget|nil
local layer_ = nil

local LeaderboardDetailView = {}

-- 用静态配表补齐展示字段（排行榜只存权威实例数据，静态数据本地查表）
local function EnrichItem(item)
    item = item or {}
    local definition = item.equipmentId and EquipmentCatalog.Get(item.equipmentId) or nil
    if definition then
        item.name = definition.name
        item.slot = item.slot or definition.slot
        item.category = definition.category
    end
    if item.setId and SETS[item.setId] then
        item.setName = SETS[item.setId].name
    end
    return item
end

--- 底部「个性展示」模块
--- 看自己：大字号下拉选择 20 条垃圾话之一并上传；看别人：大字号展示对方设置的垃圾话。
--- 下拉自建（UI.Dropdown 字号受主题限制改不了），选项为纯文本（序号仅用于传输，不展示）。
---@param isSelf boolean
---@param trashTalkIndex number|nil
---@param onChange function|nil 切换时回调（仅自己可见）
local function BuildPersonalitySection(isSelf, trashTalkIndex, onChange)
    local phrase = TrashTalk.Get(trashTalkIndex) or "暂无"

    local body
    if isSelf then
        local currentIndex = math.floor(tonumber(trashTalkIndex) or 0)
        local expanded = false
        -- 当前垃圾话大字展示（可点开切换）
        local phraseLabel = Kit.Txt(phrase, 36, C.gold, {
            flexGrow = 1,
            flexBasis = 0,
            textAlign = "center",
            textStroke = { width = 2, color = "#000000" },
        })
        local arrowLabel = Kit.Txt("▼", 26, C.textSecondary, {
            width = 44,
            height = 44,
            textAlign = "center",
            textStroke = { width = 1, color = "#000000" },
            pointerEvents = "none",
        })

        -- 选项列表（隐藏，展开时显示；内部可滚动，避免撑爆整个弹窗）
        local optionsContent = UI.Panel {
            width = "100%",
            flexShrink = 0,
            gap = 8,
            paddingTop = 6,
            paddingBottom = 8,
        }
        ---@type Widget
        local optionsPanel -- 先声明，选项行回调里引用（回调仅在赋值后触发）
        for index, text in ipairs(TrashTalk.Phrases) do
            local selected = (index - 1) == currentIndex
            local row = UI.Panel {
                width = "100%",
                height = 54,
                flexShrink = 0,
                clickable = true,
                alignItems = "center",
                justifyContent = "center",
                borderWidth = selected and 2 or 1,
                borderColor = selected and C.gold or { 69, 137, 181, 120 },
                borderRadius = 10,
                backgroundColor = selected and { 30, 66, 118, 220 } or { 12, 30, 58, 190 },
                onClick = function()
                    phraseLabel:SetText(text)
                    arrowLabel:SetText("▼")
                    optionsPanel:SetVisible(false)
                    expanded = false
                    if onChange then onChange(index - 1) end
                end,
                children = {
                    Kit.MultiTxt(text, 28, selected and C.gold or C.text, {
                        width = "100%",
                        textAlign = "center",
                        textStroke = { width = 1, color = "#000000" },
                    }),
                },
            }
            optionsContent:AddChild(row)
        end
        optionsPanel = UI.Panel {
            id = "trashTalkOptions",
            width = "100%",
            flexShrink = 0,
            visible = false,
            children = {
                UI.ScrollView {
                    width = "100%",
                    height = 400,
                    scrollX = false,
                    scrollY = true,
                    showScrollbar = true,
                    children = { optionsContent },
                },
            },
        }

        local trigger = UI.Panel {
            width = "100%",
            height = 96,
            flexShrink = 0,
            clickable = true,
            flexDirection = "row",
            alignItems = "center",
            paddingLeft = 24,
            paddingRight = 18,
            borderWidth = 2,
            borderColor = { 69, 137, 181, 230 },
            borderRadius = 12,
            backgroundColor = { 10, 26, 52, 210 },
            onClick = function()
                expanded = not expanded
                optionsPanel:SetVisible(expanded)
                arrowLabel:SetText(expanded and "▲" or "▼")
            end,
            children = { phraseLabel, arrowLabel },
        }

        body = UI.Panel {
            width = "100%",
            flexShrink = 0,
            gap = 8,
            children = { trigger, optionsPanel },
        }
    else
        body = UI.Panel {
            width = "100%",
            height = 200,
            flexShrink = 0,
            alignItems = "center",
            justifyContent = "center",
            borderWidth = 2,
            borderColor = { 69, 137, 181, 150 },
            borderRadius = 12,
            backgroundColor = { 10, 26, 52, 150 },
            children = {
                Kit.MultiTxt(phrase, 46, C.gold, {
                    width = "100%",
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                }),
            },
        }
    end

    return UI.Panel {
        width = 860,
        flexShrink = 0,
        gap = 24,
        paddingTop = 30,
        paddingBottom = 30,
        paddingLeft = 24,
        paddingRight = 24,
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        children = {
            UI.Panel {
                width = "100%",
                flexShrink = 0,
                flexDirection = "row",
                alignItems = "center",
                gap = 14,
                children = {
                    UI.Panel {
                        width = 10,
                        height = 44,
                        flexShrink = 0,
                        borderRadius = 5,
                        backgroundColor = C.gold,
                    },
                    Kit.Txt("个性展示", 36, C.gold, {
                        height = 52,
                        textAlign = "left",
                        textStroke = { width = 2, color = "#000000" },
                    }),
                },
            },
            body,
        },
    }
end

--- 顶部战力展示条
local function BuildPowerBar(power)
    return UI.Panel {
        width = 520,
        height = 76,
        flexShrink = 0,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = ASSETS.ui.infoBarGold,
        backgroundFit = "contain",
        pointerEvents = "none",
        children = {
            Kit.Txt("战力  " .. Kit.FormatInt(power or 0), 30, C.gold, {
                width = "100%",
                height = 44,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            }),
        },
    }
end

function LeaderboardDetailView.AttachRoot(root)
    LeaderboardDetailView.Hide()
    root_ = root
end

function LeaderboardDetailView.Hide()
    if layer_ and root_ then
        root_:RemoveChild(layer_)
    end
    layer_ = nil
    -- 详情弹窗关闭时一并收起其上层可能的装备信息浮层
    if ItemTips.IsVisible() then
        ItemTips.Hide("leaderboard-detail-close")
    end
end

function LeaderboardDetailView.Show(data)
    if not root_ then return end
    data = data or {}

    local equipped = {}
    for _, item in ipairs(data.equipment or {}) do
        local enriched = EnrichItem(item)
        if enriched.slot then
            equipped[enriched.slot] = enriched
        end
    end

    local panel = EquipmentLoadoutPanel.Build({
        nickname = data.nickname or "玩家",
        portrait = ViewAssets.CurrentPlayer().icon,
        equipped = equipped,
        onSlotClick = function(item, slot, widget)
            local bounds = widget and widget.GetAbsoluteLayoutForHitTest
                and widget:GetAbsoluteLayoutForHitTest()
                or nil
            ItemTips.Show(item, bounds, {
                source = "leaderboard",
                allowCompare = false,
                allowActions = false,
            })
        end,
    })

    local function Close()
        LeaderboardDetailView.Hide()
    end

    local function CopyUid()
        -- 官方编辑器复制逻辑：引擎全局 ui（原生 UI 实例，userdata）useSystemClipboard + SetClipboardText
        local ok, reason = pcall(function()
            ui.useSystemClipboard = true
            ui:SetClipboardText(tostring(data.userId or ""))
        end)
        if ok then
            UI.Toast.Show("已复制 uid", { duration = 1.5, variant = "success", position = "bottom" })
        else
            UI.Toast.Show("复制失败", { duration = 1.5, variant = "error", position = "bottom" })
            print("[CopyUid] failed: " .. tostring(reason))
        end
    end

    local function UpdateTrashTalk(index)
        ServerClient.SetTrashTalk(index, function(response)
            if response and response.ok then
                UI.Toast.Show("个性签名已更新", { duration = 1.5, variant = "info", position = "bottom" })
            else
                UI.Toast.Show((response and response.reason) or "设置失败", { duration = 1.5, variant = "error", position = "bottom" })
            end
        end)
    end

    local dialog = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = DIALOG_W,
        height = DIALOG_H,
        clickable = true,
        overflow = "hidden",
        backgroundColor = { 14, 24, 48, 255 },
        backgroundImage = ASSETS.ui.dialogFrame,
        backgroundFit = "sliced",
        backgroundSlice = { 72, 42, 92, 42 },
        children = {
            Kit.Txt((data.nickname or "玩家") .. " 的装备", 32, C.text, {
                position = "absolute", left = 56, top = 4,
                width = DIALOG_W - 112, height = 72, textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
            -- 左下方 uid + 复制按钮（对齐底部按钮区上沿）
            UI.Panel {
                position = "absolute",
                left = 41,
                top = 1288,
                flexDirection = "row",
                alignItems = "center",
                gap = 12,
                children = {
                    Kit.CompactTxt("uid:" .. tostring(data.userId or "?"), 20, C.textDim, {
                        maxWidth = "100%",
                        height = 36,
                        minHeight = 36,
                        left = -2,
                        top = 2,
                        textAlign = "left",
                        textStroke = { width = 1, color = "#000000" },
                    }),
                    UI.Panel {
                        width = 101,
                        height = 46,
                        left = 4,
                        top = 9,
                        clickable = true,
                        alignItems = "center",
                        justifyContent = "center",
                        backgroundImage = ASSETS.ui.buttonBlue,
                        backgroundFit = "sliced",
                        backgroundSlice = { 8, 8, 8, 8 },
                        onClick = CopyUid,
                        children = {
                            Kit.CompactTxt("复制", 18, C.text, {
                                width = "100%",
                                height = 36,
                                minHeight = 34,
                                left = -2,
                                top = -6,
                                textAlign = "center",
                                textStroke = { width = 1, color = "#000000" },
                                pointerEvents = "none",
                            }),
                        },
                    },
                },
            },
            UI.ScrollView {
                position = "absolute",
                left = 60,
                top = BODY_TOP,
                width = DIALOG_W - 120,
                height = BODY_HEIGHT,
                scrollX = false,
                scrollY = true,
                showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%",
                        flexShrink = 0,
                        alignItems = "center",
                        gap = 46,
                        paddingTop = 18,
                        paddingBottom = 18,
                        children = {
                            BuildPowerBar(data.power or 0),
                            panel,
                            BuildPersonalitySection(
                                data.isSelf == true,
                                data.trashTalkIndex or 0,
                                UpdateTrashTalk
                            ),
                        },
                    },
                },
            },
            UI.Panel {
                position = "absolute",
                left = 397,
                top = BUTTON_TOP,
                width = 300,
                height = 82,
                clickable = true,
                backgroundImage = ASSETS.ui.dialogConfirm,
                backgroundFit = "contain",
                onClick = Close,
                children = {
                    Kit.Txt("关闭", 24, C.text, {
                        width = "100%",
                        height = 82,
                        minHeight = 45,
                        top = -2,
                        textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                        pointerEvents = "none",
                    }),
                },
            },
            UI.Panel {
                position = "absolute",
                right = 24,
                top = 48,
                width = 64,
                height = 64,
                clickable = true,
                backgroundImage = ASSETS.ui.dialogClose,
                backgroundFit = "contain",
                onClick = Close,
            },
        },
    }

    local stage = UI.Panel {
        position = "relative",
        width = DIALOG_W,
        height = DIALOG_H,
        pointerEvents = "box-none",
        alignItems = "center",
        justifyContent = "center",
        children = { dialog },
    }

    LeaderboardDetailView.Hide()
    require("client.UI.DialogSettingsAccess").Attach(stage, true)
    layer_ = UI.Panel {
        position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        zIndex = LAYER_Z,
        pointerEvents = "box-none",
        alignItems = "center",
        justifyContent = "center",
        children = {
            UI.Panel {
                position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
                clickable = true,
                backgroundImage = ASSETS.ui.screenOverlay,
                backgroundFit = "cover",
                onClick = Close,
            },
            stage,
        },
    }
    root_:AddChild(layer_)
    dialog:Animate {
        keyframes = {
            [0] = { opacity = 0, scale = 0.72, translateY = 48 },
            [0.58] = { opacity = 1, scale = 1.04, translateY = -8 },
            [1] = { opacity = 1, scale = 1.0, translateY = 0 },
        },
        duration = 0.46,
        easing = "easeOut",
    }
end

function LeaderboardDetailView.Reset()
    LeaderboardDetailView.Hide()
    root_ = nil
end

return LeaderboardDetailView
