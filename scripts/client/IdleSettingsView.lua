-- IdleSettingsView.lua
-- 挂机自动处理设置面板。
-- 从 GameView.lua 抽出：装备处理策略、自动分解/出售品质、音量设置。
-- 面板 overlay 状态完全内聚在本模块，GameView 只通过 Show() 打开。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local AudioController = require("client.AudioController")
local CommonPromptDialog = require("client.CommonPromptDialog")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ItemView = require("client.ItemView")

local C = GameTheme.Colors
local CONFIG = GameTheme.CONFIG
local ASSETS = ViewAssets.ASSETS

local IdleSettingsView = {}

---@type table|nil
local idleSettingsOverlay_ = nil
---@type table|nil
local uiRoot_ = nil
-- 由 GameView 注入：应用背包策略 / 请求页面刷新 / 统一的操作结果提示
local setInventoryPolicy_ = nil
local requestPageRefresh_ = nil
local actionResult_ = nil
local recover_ --[[@type function?]]

local function ActionResult(response, successMessage)
    if actionResult_ then return actionResult_(response, successMessage) end
    return response ~= nil and response.ok == true
end

local function RequestPageRefresh()
    if requestPageRefresh_ then requestPageRefresh_() end
end

-- Text actions keep a 64px touch target without any button image or panel background.
local function TextAction(text, onClick)
    return UI.Panel { width = 720, height = 64, flexShrink = 0, clickable = true, onClick = onClick,
        children = { Kit.CompactTxt(text, 23, C.focus, {
            width = "100%", height = 64, textAlign = "center", pointerEvents = "none",
        }) } }
end

local actionFns_ = {
    SetInventoryPolicy = function(policy)
        if setInventoryPolicy_ then setInventoryPolicy_(policy) end
    end,
}

local game = GameStateAdapter.GetViewState()

local function ShowIdleSettingTip(title, description)
    CommonPromptDialog.Show {
        kind = "rules",
        queueKey = "rule:" .. tostring(title),
        zIndex = 52000,
        title = title,
        message = description,
        confirmText = "知道了",
    }
end

-- uid + 复制按钮，样式与复制逻辑与排行榜详情弹窗保持一致。
local function CreateUidRow()
    local function CopyUid()
        -- 官方编辑器复制逻辑：引擎全局 ui（原生 UI 实例，userdata）useSystemClipboard + SetClipboardText
        local ok, reason = pcall(function()
            ui.useSystemClipboard = true
            ui:SetClipboardText(tostring(game.playerUid or ""))
        end)
        if ok then
            UI.Toast.Show("已复制 uid", { duration = 1.5, variant = "success", position = "bottom" })
        else
            UI.Toast.Show("复制失败", { duration = 1.5, variant = "error", position = "bottom" })
            print("[CopyUid] failed: " .. tostring(reason))
        end
    end

    return UI.Panel {
        width = "100%",
        height = 72,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "center",
        children = {
            Kit.CompactTxt("uid:" .. tostring(game.playerUid or "?"), 20, C.textDim, {
                maxWidth = "100%",
                height = 36,
                minHeight = 36,
                textAlign = "left",
                textStroke = { width = 1, color = "#000000" },
            }),
            UI.Panel {
                width = 101,
                height = 46,
                marginLeft = 12,
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
                        textAlign = "center",
                        textStroke = { width = 1, color = "#000000" },
                        pointerEvents = "none",
                    }),
                },
            },
        },
    }
end

local function CreateIdlePolicySwitchRow(title, value, disabled, onChange, switchRegistry, switchId, tipTitle, tipDescription)
    local switch = UI.Toggle {
        width = 78,
        height = 42,
        trackWidth = 64,
        trackHeight = 32,
        thumbSize = 26,
        value = value == true,
        disabled = disabled,
        trackBg = { 28, 42, 65, 255 },
        trackCheckedBgColor = C.success,
        trackBorderColor = C.border,
        thumbCheckedColor = C.text,
        onChange = function(_, checked)
            if onChange then onChange(checked) end
        end,
    }
    if switchRegistry and switchId then
        switchRegistry[switchId] = switch
    end
    return UI.Panel {
        width = "100%",
        height = 86,
        flexShrink = 0,
        position = "relative",
        backgroundImage = ASSETS.ui.infoBarBlue,
        backgroundFit = "sliced",
        backgroundSlice = { 10, 10, 10, 10 },
        opacity = disabled and 0.5 or 1.0,
        children = {
            Kit.Txt(title, 22, C.text, {
                position = "absolute",
                left = 24,
                top = 17,
                width = 610,
                height = 36,
                textStroke = { width = 1, color = "#000000" },
            }),
            UI.Panel {
                position = "absolute",
                right = 118,
                top = 13,
                width = 44,
                height = 44,
                clickable = true,
                backgroundImage = "image/ui/dialog/help_button.png",
                backgroundFit = "contain",
                onClick = function()
                    ShowIdleSettingTip(tipTitle or title, tipDescription or "暂无详细说明。")
                end,
            },
            UI.Panel {
                position = "absolute",
                right = 24,
                top = 14,
                width = 78,
                height = 42,
                children = { switch },
            },
        },
    }
end

local function CloseIdleSettings()
    if idleSettingsOverlay_ and uiRoot_ then
        if idleSettingsOverlay_.Destroy then idleSettingsOverlay_:Destroy()
        else uiRoot_:RemoveChild(idleSettingsOverlay_) end
    end
    idleSettingsOverlay_ = nil
end

local function ShowIdleSettings()
    if not uiRoot_ then return end
    CloseIdleSettings()
    game = GameStateAdapter.GetViewState()
    local policy = game.inventoryPolicy or {
        pauseOnFull = true,
        autoDecompose = false,
        autoSell = false,
        decomposeRarities = {},
        sellRarities = {},
    }
    local pauseOnFull = policy.pauseOnFull ~= false
    local autoDecompose = policy.autoDecompose == true
    local autoSell = policy.autoSell == true
    local sourceDecompose = policy.decomposeRarities or {}
    local sourceSell = policy.sellRarities or {}
    local decomposeRarities = {
        common = sourceDecompose.common == true,
        advanced = sourceDecompose.advanced == true or sourceDecompose.blue == true,
        rare = sourceDecompose.rare == true or sourceDecompose.purple == true,
        artifact = sourceDecompose.artifact == true,
        legendary = sourceDecompose.legendary == true or sourceDecompose.legend == true,
        epic = sourceDecompose.epic == true,
        myth = false,
    }
    local sellRarities = {
        common = sourceSell.common == true,
        advanced = sourceSell.advanced == true or sourceSell.blue == true,
        rare = sourceSell.rare == true or sourceSell.purple == true,
        artifact = sourceSell.artifact == true,
        legendary = sourceSell.legendary == true or sourceSell.legend == true,
        epic = sourceSell.epic == true,
        myth = false,
    }
    local readOnly = game.readOnly == true
    local automationPolicy = game.automationPolicy or {}
    local lootAutoEquip = automationPolicy.lootAutoEquip == true
    local switches = {}
    local settingsHeight = Kit.Clamp(CONFIG.DynamicDesignHeight() - 96, 760, 1660)

    local function BuildPolicy()
        return {
            pauseOnFull = pauseOnFull,
            autoDecompose = autoDecompose,
            autoSell = autoSell,
            decomposeRarities = decomposeRarities,
            sellRarities = sellRarities,
        }
    end

    local function ApplyPolicy()
        actionFns_.SetInventoryPolicy(BuildPolicy())
        RequestPageRefresh()
    end

    local function ConfirmPolicyEnable(options)
        local switch = switches[options.switchId]
        if switch then switch.props.value = false end
        CommonPromptDialog.Show {
            kind = "confirm",
            title = options.title,
            message = options.message,
            lines = options.lines,
            cancelText = "取消",
            confirmText = "确认启用",
            danger = true,
            closeOnOverlay = false,
            zIndex = 52000,
            onCancel = function()
                if switch then switch.props.value = false end
            end,
            onConfirm = function()
                if switch then switch.props.value = true end
                options.apply()
            end,
        }
    end

    local function SetRarity(kind, rarityId, enabled)
        local target = kind == "decompose" and decomposeRarities or sellRarities
        local other = kind == "decompose" and sellRarities or decomposeRarities
        if not enabled then
            target[rarityId] = false
            ApplyPolicy()
            return
        end
        local actionName = kind == "decompose" and "自动分解" or "自动出售"
        ConfirmPolicyEnable {
            switchId = kind .. "_" .. rarityId,
            title = "确认开启" .. actionName,
            message = "开启后，符合条件的" .. ItemView.RarityName(rarityId) .. "装备会被" .. actionName .. "。",
            lines = { "该设置会影响后续挂机掉落；神话、已穿戴和已锁定装备仍受保护。" },
            apply = function()
                target[rarityId] = true
                other[rarityId] = false
                local otherSwitch = switches[kind == "decompose" and ("sell_" .. rarityId) or ("decompose_" .. rarityId)]
                if otherSwitch then otherSwitch.props.value = false end
                ApplyPolicy()
            end,
        }
    end

    local function AddSwitch(id, title, description, value, onChange)
        return CreateIdlePolicySwitchRow(title, value, readOnly, onChange, switches, id, title, description)
    end

    local function CreateAudioVolumeRow(title, value, onChange)
        local valueLabel = Kit.CompactTxt(string.format("%d%%", math.floor(value * 100 + 0.5)), 20, C.focus, {
            position = "absolute",
            right = 24,
            top = 24,
            width = 92,
            height = 38,
            textAlign = "right",
            textStroke = { width = 1, color = "#000000" },
        })
        local slider = UI.Slider {
            width = 520,
            height = 42,
            value = math.floor(value * 100 + 0.5),
            min = 0,
            max = 100,
            step = 1,
            trackHeight = 10,
            thumbSize = 30,
            trackBgColor = { 22, 35, 56, 255 },
            trackFillColor = C.focus,
            thumbColor = C.text,
            thumbBorderColor = C.focus,
            thumbBorderWidth = 2,
            onChange = function(_, sliderValue)
                local normalized = sliderValue / 100
                valueLabel:SetText(string.format("%d%%", math.floor(sliderValue + 0.5)))
                if onChange then onChange(normalized) end
            end,
        }
        return UI.Panel {
            width = "100%",
            height = 86,
            flexShrink = 0,
            position = "relative",
            backgroundImage = ASSETS.ui.infoBarBlue,
            backgroundFit = "sliced",
            backgroundSlice = { 10, 10, 10, 10 },
            children = {
                Kit.Txt(title, 22, C.text, {
                    position = "absolute",
                    left = 24,
                    top = 17,
                    width = 220,
                    height = 36,
                    textStroke = { width = 1, color = "#000000" },
                }),
                UI.Panel {
                    position = "absolute",
                    left = 250,
                    top = 22,
                    width = 560,
                    height = 42,
                    children = { slider },
                },
                valueLabel,
            },
        }
    end

    local body = UI.ScrollView {
        position = "absolute",
        left = 58,
        top = 144,
        width = 872,
        height = math.max(500, settingsHeight - 260),
        scrollY = true,
        scrollX = false,
        showScrollbar = false,
        children = {
            UI.Panel {
                width = "100%",
                flexShrink = 0,
                gap = 16,
                paddingBottom = 32,
                children = {
                    Kit.Txt("性能与恢复", 25, C.focus, { width = "100%", height = 42 }),
                    CreateIdlePolicySwitchRow("省电模式（30帧 / 减少特效）", require("client.PerformanceController").IsPowerSaving(), false,
                        require("client.PerformanceController").SetPowerSaving),
                    Kit.ImageButton("解除卡住并返回首页", 720, 72, ASSETS.ui.inventoryActionRed, function()
                        if recover_ then recover_() end
                    end),
                    Kit.CompactTxt("保留装备、资源和进度；停止挂机并重新同步。", 19, C.textSecondary, { width = "100%", height = 32 }),
                    TextAction("重新连接 / 同步状态", function()
                        if ServerClient.IsReady() then
                            require("client.GameView").TryRecoverServer()
                            ServerClient.RequestSnapshot()
                        elseif not ServerClient.RetryConnection() then
                            UI.Toast.Show("网络连接尚未恢复，请检查网络后重试", { position = "bottom", variant = "warning" })
                        end
                    end),
                    TextAction("继续领取已完成广告奖励", function()
                        CloseIdleSettings()
                        if not require("client.RewardClaimController").ResumeConfirmed() then
                            require("client.AdGiftController").Open()
                        end
                    end),
                    CreateUidRow(),
                    Kit.Txt("装备处理", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    AddSwitch("loot_auto_equip", "刷宝掉落自动装备", "默认关闭。关闭时装备先进入暂存箱；发现更强同部位装备仍会显示非阻塞对比提示，由玩家决定是否穿戴。", lootAutoEquip, function(value)
                        lootAutoEquip = value
                        ServerClient.SetAutomationPolicy({
                            autoEquip = value,
                            lootAutoEquip = value,
                            autoSkipStory = automationPolicy.autoSkipStory == true,
                        }, ActionResult)
                    end),
                    Kit.Txt("背包满时的处理规则", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    AddSwitch("pause", "背包满后暂停挂机", "开启后，背包满且没有可自动处理的装备时，挂机会暂停。关闭后将跳过无法处理的掉落并继续挂机。", pauseOnFull, function(value)
                        pauseOnFull = value
                        ApplyPolicy()
                    end),
                    AddSwitch("decompose", "启用自动分解", "开启后，分解列表中打开的品质。自动分解与自动出售互斥，开启本项会自动关闭自动出售。", autoDecompose, function(value)
                        if not value then
                            autoDecompose = false
                            ApplyPolicy()
                            return
                        end
                        ConfirmPolicyEnable {
                            switchId = "decompose",
                            title = "确认启用自动分解",
                            message = "启用后，挂机过程中符合品质规则的装备会被自动分解。",
                            lines = { "自动分解与自动出售互斥；已穿戴、已锁定和神话装备仍受保护。" },
                            apply = function()
                                autoDecompose = true
                                autoSell = false
                                if switches.sell then switches.sell.props.value = false end
                                ApplyPolicy()
                            end,
                        }
                    end),
                    AddSwitch("sell", "启用自动出售", "开启后，出售列表中打开的品质并获得金币。自动出售与自动分解互斥，开启本项会自动关闭自动分解。", autoSell, function(value)
                        if not value then
                            autoSell = false
                            ApplyPolicy()
                            return
                        end
                        ConfirmPolicyEnable {
                            switchId = "sell",
                            title = "确认启用自动出售",
                            message = "启用后，挂机过程中符合品质规则的装备会被自动出售。",
                            lines = { "自动出售与自动分解互斥；已穿戴、已锁定和神话装备仍受保护。" },
                            apply = function()
                                autoSell = true
                                autoDecompose = false
                                if switches.decompose then switches.decompose.props.value = false end
                                ApplyPolicy()
                            end,
                        }
                    end),
                    Kit.Txt("声音设置", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    CreateAudioVolumeRow("背景音乐", AudioController.GetMusicVolume(), AudioController.SetMusicVolume),
                    CreateAudioVolumeRow("音效", AudioController.GetSfxVolume(), AudioController.SetSfxVolume),
                    Kit.Txt("自动分解品质", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    AddSwitch("decompose_common", "分解：普通 / 白色", "价值最低，适合作为第一优先级的自动分解对象。", decomposeRarities.common, function(value) SetRarity("decompose", "common", value) end),
                    AddSwitch("decompose_advanced", "分解：高级 / 蓝色", "高级装备将按当前规则自动分解。", decomposeRarities.advanced, function(value) SetRarity("decompose", "advanced", value) end),
                    AddSwitch("decompose_rare", "分解：稀有 / 紫色", "稀有装备价值较高，开启前请确认。", decomposeRarities.rare, function(value) SetRarity("decompose", "rare", value) end),
                    AddSwitch("decompose_artifact", "分解：神器 / 粉色", "神器装备带有核心词条，开启前请确认。", decomposeRarities.artifact, function(value) SetRarity("decompose", "artifact", value) end),
                    AddSwitch("decompose_legendary", "分解：传说 / 赤红", "传说装备默认关闭，避免误分解。", decomposeRarities.legendary, function(value) SetRarity("decompose", "legendary", value) end),
                    AddSwitch("decompose_epic", "分解：史诗 / 橙金", "史诗装备属于套装体系，开启前请确认。", decomposeRarities.epic, function(value) SetRarity("decompose", "epic", value) end),
                    Kit.Txt("自动出售品质", 25, C.focus, { width = "100%", height = 42, textStroke = { width = 2, color = "#000000" } }),
                    AddSwitch("sell_common", "出售：普通 / 白色", "价值最低，适合作为第一优先级的自动出售对象。", sellRarities.common, function(value) SetRarity("sell", "common", value) end),
                    AddSwitch("sell_advanced", "出售：高级 / 蓝色", "高级装备将按当前规则自动出售并获得金币。", sellRarities.advanced, function(value) SetRarity("sell", "advanced", value) end),
                    AddSwitch("sell_rare", "出售：稀有 / 紫色", "稀有装备价值较高，开启前请确认。", sellRarities.rare, function(value) SetRarity("sell", "rare", value) end),
                    AddSwitch("sell_artifact", "出售：神器 / 粉色", "神器装备带有核心词条，开启前请确认。", sellRarities.artifact, function(value) SetRarity("sell", "artifact", value) end),
                    AddSwitch("sell_legendary", "出售：传说 / 赤红", "传说装备默认关闭，避免误出售。", sellRarities.legendary, function(value) SetRarity("sell", "legendary", value) end),
                    AddSwitch("sell_epic", "出售：史诗 / 橙金", "史诗装备属于套装体系，开启前请确认。", sellRarities.epic, function(value) SetRarity("sell", "epic", value) end),
                    CreateIdlePolicySwitchRow("神话品质保护", true, true, nil, switches, "myth", "神话品质保护", "神话品质永久保护，不会被自动分解或出售。需要处理时，请到背包中手动操作。"),
                },
            },
        },
    }
    -- panel_940x320: visual=(0,0,940,320), content=(14,14,912,292).
    -- Existing sliced 14px border; body remains inside the established 996px settings frame.
    local panel = UI.Panel { id = "recoverySettingsPanel",
        position = "relative",
        width = 996,
        height = settingsHeight,
        zIndex = 2100,
        clickable = true,
        overflow = "hidden",
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 14, 14, 14, 14 },
        children = {
            Kit.Txt("游戏设置", 32, C.text, { position = "absolute", left = 90, top = 34, width = 760, height = 48, textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
            UI.Panel {
                position = "absolute",
                right = 22,
                top = 24,
                width = 64,
                height = 64,
                clickable = true,
                backgroundImage = "image/ui/dialog/close_button.png",
                backgroundFit = "contain",
                onClick = CloseIdleSettings,
            },
            body,
        },
    }
    idleSettingsOverlay_ = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        right = 0,
        bottom = 0,
        zIndex = 51000,
        pointerEvents = "box-none",
        alignItems = "center",
        justifyContent = "center",
        children = {
            UI.Panel {
                position = "absolute",
                left = 0,
                top = 0,
                right = 0,
                bottom = 0,
                clickable = true,
                backgroundImage = ASSETS.ui.screenOverlay,
                backgroundFit = "cover",
                onClick = CloseIdleSettings,
            },
            require("client.UI.DialogSettingsAccess").Wrap(panel),
        },
    }
    uiRoot_:AddChild(idleSettingsOverlay_)
end

--- 打开挂机设置面板。
--- @param context table 需包含 uiRoot / setInventoryPolicy / requestPageRefresh / actionResult
function IdleSettingsView.Show(context)
    context = context or {}
    uiRoot_ = context.uiRoot
    setInventoryPolicy_ = context.setInventoryPolicy
    requestPageRefresh_ = context.requestPageRefresh
    actionResult_ = context.actionResult
    recover_ = context.recover
    ShowIdleSettings()
end

--- 关闭面板（供 GameView 在重建 UI 根节点前调用）。
function IdleSettingsView.IsOpen() return idleSettingsOverlay_ ~= nil end

function IdleSettingsView.Close()
    CloseIdleSettings()
end

return IdleSettingsView
