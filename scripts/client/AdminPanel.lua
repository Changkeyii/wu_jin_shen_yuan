local ServerClient = require("client.ServerClient")
local LargeNumber = require("shared.LargeNumber")
local UI = require("urhox-libs/UI")

local SECTION_BACKGROUND = "image/ui/generated/panel_940x320.png"

local AdminPanel = {}

-- Embedded page boundary contract (1080x1920 design space):
-- AdminRoot -> HeaderBand(100%) -> FormScroll(flex, clipped) -> StatusBand(100%).
-- Each FormSection is an unframed sibling region with a 2px divider; no card nesting.
-- The ScrollView always has flexBasis=0 so the footer cannot be pushed off-screen.
local form_ = {
    targetUid = "",
    reason = "",
    currency = "gold",
    amount = "1000",
    slot = "weapon",
    rarity = "epic",
    floor = "1",
    position = "1",
}
local status_ = "管理员通道已就绪"
local statusKind_ = "info"
local audit_ = {}
local queriedPlayer_ = nil

local function ToInteger(value)
    local number = tonumber(value)
    if not number then return nil end
    return math.floor(number)
end

local function SetStatus(response, onChanged)
    if response and response.ok then
        statusKind_ = "success"
        status_ = response.status or (response.data and response.data.status) or "操作已提交"
        if response.data and response.data.audit then audit_ = response.data.audit end
        if response.data and response.data.player then queriedPlayer_ = response.data.player end
    else
        statusKind_ = "error"
        status_ = (response and (response.reason or response.code)) or "请求失败"
    end
    UI.Toast.Show(status_, {
        duration = 2.4,
        variant = statusKind_,
        position = "bottom",
    })
    if onChanged then onChanged() end
end

function AdminPanel.HandleResult(result, onChanged)
    if type(result) ~= "table" then return false end
    SetStatus({
        ok = result.ok == true,
        status = result.status,
        reason = result.reason,
        code = result.code,
        data = result,
    }, onChanged)
    return true
end

local function ValidateCommon()
    if form_.targetUid == "" then return false, "目标玩家编号不能为空" end
    if form_.reason == "" then return false, "操作原因不能为空" end
    return true
end

local function Submit(action, onChanged)
    local ok, reason = ValidateCommon()
    if not ok then
        SetStatus({ ok = false, reason = reason }, onChanged)
        return
    end
    action(function(response) SetStatus(response, onChanged) end)
end

local MIN_FONT_SIZE = 24

local function FontSize(size)
    return math.max(MIN_FONT_SIZE, size or MIN_FONT_SIZE)
end

local function Label(UI, text, size, color)
    return UI.Label {
        text = text,
        fontSize = FontSize(size),
        fontWeight = "bold",
        fontColor = color,
        width = "100%",
        whiteSpace = "normal",
        wordBreak = "break-word",
    }
end

local function Field(UI, label, key, placeholder)
    return UI.Panel {
        width = "100%",
        gap = 5,
        children = {
            Label(UI, label, 10, {154, 177, 226, 255}),
            UI.TextField {
                width = "100%",
                height = 54,
                value = form_[key],
                placeholder = placeholder or "",
                maxLength = key == "reason" and 120 or 32,
                onChange = function(self, value) form_[key] = value end,
            },
        },
    }
end

local function Section(UI, title, children)
    local content = {
        Label(UI, title, 15, {255, 255, 255, 255}),
    }
    for _, child in ipairs(children) do content[#content + 1] = child end
    return UI.Panel {
        width = "100%",
        padding = 16,
        gap = 10,
        backgroundImage = SECTION_BACKGROUND,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        children = content,
    }
end

local function ButtonRow(UI, children)
    return UI.Panel {
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        gap = 10,
        children = children,
    }
end

local function PlayerSummary()
    local player = queriedPlayer_
    if not player then return "尚未查询玩家" end
    if player.missing then
        return string.format("玩家 %s | 未建档%s", tostring(player.targetUid), player.banned and " | 已封禁" or "")
    end
    local presence = player.online and "在线" or "离线"
    local ban = player.banned and ("已封禁：" .. tostring(player.ban and player.ban.reason or "未填写原因")) or "正常"
    return string.format(
        "玩家 %s | %s | %s\n等级%s  第%s层 %s格  战力%s\n金币%s  碎片%s  装备%s件  版本%s",
        tostring(player.targetUid), presence, ban,
        tostring(player.level or "-"), tostring(player.floor or "-"), tostring(player.position or "-"), tostring(player.power or "-"),
        LargeNumber.Format(player.gold or 0), LargeNumber.Format(player.fragments or 0), tostring(player.inventoryCount or "-"), tostring(player.revision or "-")
    )
end

function AdminPanel.Build(UI, options)
    options = options or {}
    local onChanged = options.onChanged
    local readOnly = options.readOnly == true

    local querySection = Section(UI, "玩家查询", {
        Field(UI, "目标玩家编号", "targetUid", "玩家编号"),
        ButtonRow(UI, {
            UI.Button {
                text = "查询玩家",
                variant = "primary",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    if form_.targetUid == "" then
                        SetStatus({ ok = false, reason = "目标玩家编号不能为空" }, onChanged)
                        return
                    end
                    ServerClient.AdminQuery(form_.targetUid, function(response) SetStatus(response, onChanged) end)
                end,
            },
            UI.Button {
                text = "刷新审计",
                variant = "secondary",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    ServerClient.AdminAudit(function(response)
                        if response and response.ok and response.data then audit_ = response.data.audit or {} end
                        SetStatus(response, onChanged)
                    end)
                end,
            },
        }),
        Label(UI, PlayerSummary(), 10, {213, 226, 255, 255}),
    })

    local currencySection = Section(UI, "资源发放", {
        UI.Panel {
            width = "100%",
            flexDirection = "row",
            gap = 10,
            children = {
                UI.Panel {
                    flexGrow = 1,
                    flexBasis = 0,
                    gap = 5,
                    children = {
                        Label(UI, "货币", 10, {154, 177, 226, 255}),
                        UI.Dropdown {
                            width = "100%",
                            value = form_.currency,
                            options = {
                                { value = "gold", label = "金币" },
                                { value = "fragments", label = "深渊碎片" },
                            },
                            onChange = function(self, value) form_.currency = value end,
                        },
                    },
                },
                UI.Panel { flexGrow = 1, flexBasis = 0, children = { Field(UI, "数量", "amount", "1-1000000") } },
            },
        },
        UI.Button {
            text = "发放货币",
            variant = "success",
            width = 210,
            disabled = readOnly,
            onClick = function()
                local amount = ToInteger(form_.amount)
                if not amount then SetStatus({ ok = false, reason = "数量必须是整数" }, onChanged); return end
                Submit(function(done)
                    ServerClient.AdminGrantCurrency(form_.targetUid, form_.currency, amount, form_.reason, done)
                end, onChanged)
            end,
        },
    })

    local equipmentSection = Section(UI, "装备发放", {
        UI.Panel {
            width = "100%",
            flexDirection = "row",
            gap = 10,
            children = {
                UI.Dropdown {
                    flexGrow = 1,
                    flexBasis = 0,
                    value = form_.slot,
                    options = {
                        { value = "weapon", label = "武器" }, { value = "shoulder", label = "头肩" },
                        { value = "coat", label = "上衣" }, { value = "pants", label = "下装" },
                        { value = "belt", label = "腰带" }, { value = "shoes", label = "鞋" },
                        { value = "bracelet", label = "手镯" }, { value = "necklace", label = "项链" },
                        { value = "ring", label = "戒指" }, { value = "support", label = "辅助装备" },
                        { value = "magicstone", label = "魔法石" }, { value = "earring", label = "耳环" },
                    },
                    onChange = function(self, value) form_.slot = value end,
                },
                UI.Dropdown {
                    flexGrow = 1,
                    flexBasis = 0,
                    value = form_.rarity,
                    options = {
                        { value = "common", label = "普通" }, { value = "blue", label = "高级" },
                        { value = "purple", label = "稀有" }, { value = "epic", label = "史诗" },
                        { value = "myth", label = "神话" },
                    },
                    onChange = function(self, value) form_.rarity = value end,
                },
            },
        },
        UI.Button {
            text = "发放装备",
            variant = "success",
            width = 210,
            disabled = readOnly,
            onClick = function()
                Submit(function(done)
                    ServerClient.AdminGrantEquipment(form_.targetUid, form_.slot, form_.rarity, form_.reason, done)
                end, onChanged)
            end,
        },
    })

    local progressSection = Section(UI, "进度调整", {
        UI.Panel {
            width = "100%",
            flexDirection = "row",
            gap = 10,
            children = {
                UI.Panel { flexGrow = 1, flexBasis = 0, children = { Field(UI, "层数", "floor", "1-100000") } },
                UI.Panel { flexGrow = 1, flexBasis = 0, children = { Field(UI, "格子", "position", "0-100") } },
            },
        },
        UI.Button {
            text = "调整进度",
            variant = "primary",
            width = 210,
            disabled = readOnly,
            onClick = function()
                local floor, position = ToInteger(form_.floor), ToInteger(form_.position)
                if not floor or not position then SetStatus({ ok = false, reason = "层数和格子必须是整数" }, onChanged); return end
                Submit(function(done)
                    ServerClient.AdminAdjustProgress(form_.targetUid, floor, position, form_.reason, done)
                end, onChanged)
            end,
        },
    })

    local banSection = Section(UI, "封禁管理", {
        Field(UI, "操作原因", "reason", "必填，最多 120 字"),
        ButtonRow(UI, {
            UI.Button {
                text = "封禁玩家",
                variant = "danger",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    Submit(function(done) ServerClient.AdminBan(form_.targetUid, form_.reason, done) end, onChanged)
                end,
            },
            UI.Button {
                text = "解除封禁",
                variant = "secondary",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    Submit(function(done) ServerClient.AdminUnban(form_.targetUid, form_.reason, done) end, onChanged)
                end,
            },
        }),
    })

    local auditRows = {}
    for index = math.max(1, #audit_ - 9), #audit_ do
        local row = audit_[index]
        if row then
            auditRows[#auditRows + 1] = Label(UI,
                string.format("%s | %s | %s", tostring(row.action or "-"), tostring(row.targetUid or "-"), tostring(row.status or "-")),
                10, {213, 226, 255, 255})
        end
    end
    if #auditRows == 0 then auditRows[1] = Label(UI, "暂无审计记录", 10, {154, 177, 226, 255}) end

    return UI.Panel {
        width = "100%",
        height = "100%",
        padding = 22,
        gap = 12,
        children = {
            UI.Panel {
                width = "100%",
                height = 72,
                flexShrink = 0,
                justifyContent = "center",
                children = { Label(UI, "管理后台", 18, {111, 231, 255, 255}) },
            },
            UI.ScrollView {
                width = "100%",
                flexGrow = 1,
                flexBasis = 0,
                scrollY = true,
                showScrollbar = true,
                children = {
                    UI.Panel {
                        width = "100%",
                        gap = 12,
                        paddingBottom = 24,
                        children = {
                            querySection,
                            currencySection,
                            equipmentSection,
                            progressSection,
                            banSection,
                            Section(UI, "最近审计", auditRows),
                        },
                    },
                },
            },
            UI.Alert {
                width = "100%",
                title = statusKind_ == "error" and "请求失败" or "操作状态",
                message = tostring(status_),
                severity = statusKind_,
                closable = false,
            },
        },
    }
end

return AdminPanel
