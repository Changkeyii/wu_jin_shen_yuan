local ServerClient = require("client.ServerClient")
local LargeNumber = require("shared.LargeNumber")
local UI = require("urhox-libs/UI")

local SECTION_BACKGROUND = "image/ui/generated/panel_940x320.png"

local AdminPanel = {}

-- 管理面板分页签：玩家管理 / 邮件管理 / 系统审计。
-- Build 重建时保留当前页签，切页签通过 onChanged 触发页面重刷。
local activeTab_ = "player"

-- Embedded page boundary contract (1080x1920 design space):
-- AdminRoot -> HeaderBand(标题 + 页签) -> ContentScroll(flex, clipped) -> StatusBand(100%).
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
    mailTitle = "",
    mailBody = "",
    mailType = "reward",
    mailGold = "0",
    mailId = "",
    broadcastExpireDays = "7",
    queryName = "",
}
local status_ = "管理员通道已就绪"
local statusKind_ = "info"
local audit_ = {}
local queriedPlayer_ = nil
local mailList_ = {}
local byNameMatches_ = {}

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

-- ============================================================================
-- 格式化
-- ============================================================================

local function PlaytimeText(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if days > 0 then return string.format("%d天%d小时", days, hours) end
    if hours > 0 then return string.format("%d小时%d分", hours, minutes) end
    return string.format("%d分钟", math.max(1, minutes))
end

local function ActiveText(timestamp)
    timestamp = math.max(0, math.floor(tonumber(timestamp) or 0))
    if timestamp <= 0 then return "未知" end
    local elapsed = math.max(0, os.time() - timestamp)
    local day = math.floor(elapsed / 86400)
    local hour = math.floor((elapsed % 86400) / 3600)
    local minute = math.floor((elapsed % 3600) / 60)
    if day > 0 then return string.format("%d天前", day) end
    if hour > 0 then return string.format("%d小时前", hour) end
    if minute > 0 then return string.format("%d分钟前", minute) end
    return "刚刚"
end

-- ============================================================================
-- 玩家详情卡（查询后结构化展示核心数据，便于作弊判定）
-- ============================================================================

local function StatCell(UI, label, value)
    return UI.Panel {
        flexGrow = 1,
        flexBasis = 0,
        gap = 2,
        children = {
            Label(UI, label, 9, {154, 177, 226, 255}),
            Label(UI, value, 11, {255, 255, 255, 255}),
        },
    }
end

local function PlayerDetailCard(UI, player)
    if not player then
        return UI.Panel {
            width = "100%",
            padding = 14,
            gap = 6,
            backgroundImage = SECTION_BACKGROUND,
            backgroundFit = "sliced",
            backgroundSlice = { 8, 8, 8, 8 },
            children = { Label(UI, "尚未查询玩家", 10, {154, 177, 226, 255}) },
        }
    end
    if player.missing then
        return UI.Panel {
            width = "100%",
            padding = 14,
            gap = 6,
            backgroundImage = SECTION_BACKGROUND,
            backgroundFit = "sliced",
            backgroundSlice = { 8, 8, 8, 8 },
            children = {
                Label(UI, string.format("玩家 %s 未建档", tostring(player.targetUid or "-")), 10, {255, 180, 120, 255}),
            },
        }
    end
    local statusColor = player.banned and {255, 110, 110, 255}
        or (player.online and {110, 231, 150, 255} or {200, 200, 210, 255})
    local statusText = player.banned
        and ("已封禁：" .. tostring(player.ban and player.ban.reason or "未填写原因"))
        or (player.online and "● 在线" or "○ 离线")
    local stats = player.stats or {}
    local rows = {
        { { label = "战力", value = LargeNumber.Format(player.power or 0) }, { label = "等级", value = tostring(player.level or "-") } },
        { { label = "VIP", value = tostring(player.vipLevel or 0) }, { label = "进度", value = string.format("%s层 第%s格", tostring(player.floor or "-"), tostring(player.position or "-")) } },
        { { label = "攻击", value = LargeNumber.Format(stats.atk or 0) }, { label = "防御", value = LargeNumber.Format(stats.def or 0) } },
        { { label = "生命", value = LargeNumber.Format(stats.hp or 0) }, { label = "暴击", value = string.format("%.1f%%", (stats.crit or 0) * 100) } },
        { { label = "攻速", value = string.format("%.1f", stats.atkSpeed or 0) }, { label = "金币", value = LargeNumber.Format(player.gold or 0) } },
        { { label = "深渊碎片", value = LargeNumber.Format(player.fragments or 0) }, { label = "装备", value = string.format("%d件 / 已穿%d", player.inventoryCount or 0, player.equippedCount or 0) } },
    }
    local cells = {}
    for _, row in ipairs(rows) do
        cells[#cells + 1] = UI.Panel {
            width = "100%",
            flexDirection = "row",
            gap = 10,
            children = {
                StatCell(UI, row[1].label, row[1].value),
                StatCell(UI, row[2].label, row[2].value),
            },
        }
    end
    return UI.Panel {
        width = "100%",
        padding = 14,
        gap = 8,
        backgroundImage = SECTION_BACKGROUND,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        children = {
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 8,
                children = {
                    Label(UI, "UID " .. tostring(player.targetUid or "-"), 11, {255, 220, 120, 255}),
                    Label(UI, tostring(player.nickname or ""), 11, {255, 255, 255, 255}),
                    Label(UI, statusText, 10, statusColor),
                },
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 8,
                children = {
                    Label(UI, "总游玩时长 " .. PlaytimeText(player.totalPlaySeconds), 10, {200, 230, 255, 255}),
                    Label(UI, "挂机 " .. (player.autoRun and "开" or "关"), 10, player.autoRun and {110, 231, 150, 255} or {200, 200, 210, 255}),
                    Label(UI, "最近活跃 " .. ActiveText(player.lastActiveAt), 10, {200, 200, 210, 255}),
                },
            },
            table.unpack(cells),
        },
    }
end

local function MailListSummary()
    if #mailList_ == 0 then return "暂无邮件查询结果" end
    local lines = {}
    for _, item in ipairs(mailList_) do
        if #lines < 8 then
            lines[#lines + 1] = string.format("%s | %s | %s | %s",
                tostring(item.mailId or "-"),
                tostring(item.title or "-"),
                item.read and "已读" or "未读",
                item.hasUnclaimed and "有未领附件" or (item.attachState == "none" and "无附件" or "已处理"))
        end
    end
    if #mailList_ > 8 then lines[#lines + 1] = "... 共 " .. tostring(#mailList_) .. " 封" end
    return table.concat(lines, "\n")
end

local function QueryByNameSummary()
    if #byNameMatches_ == 0 then return "无匹配玩家（仅查在线玩家）" end
    local lines = {}
    for _, match in ipairs(byNameMatches_) do
        lines[#lines + 1] = string.format("uid=%s | %s | 在线",
            tostring(match.uid or "-"), tostring(match.nickname or "-"))
    end
    return table.concat(lines, "\n")
end

-- ============================================================================
-- 页签栏
-- ============================================================================

local function TabBar(UI, onChanged)
    local tabs = {
        { id = "player", name = "玩家管理" },
        { id = "mail", name = "邮件管理" },
        { id = "audit", name = "系统审计" },
    }
    local children = {}
    for _, tab in ipairs(tabs) do
        local active = activeTab_ == tab.id
        local tabId = tab.id
        children[#children + 1] = UI.Panel {
            flexGrow = 1,
            flexBasis = 0,
            height = 56,
            alignItems = "center",
            justifyContent = "center",
            onClick = function()
                if activeTab_ == tabId then return end
                activeTab_ = tabId
                if onChanged then onChanged() end
            end,
            children = {
                Label(UI, tab.name, 13, active and {111, 231, 255, 255} or {154, 177, 226, 255}),
            },
        }
    end
    return UI.Panel {
        width = "100%",
        flexDirection = "row",
        gap = 10,
        children = children,
    }
end

-- ============================================================================
-- 面板构建
-- ============================================================================

function AdminPanel.Build(UI, options)
    options = options or {}
    local onChanged = options.onChanged
    local readOnly = options.readOnly == true

    -- 玩家管理页
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
        }),
        Field(UI, "按昵称查询（在线玩家）", "queryName", "输入昵称"),
        ButtonRow(UI, {
            UI.Button {
                text = "按昵称查询",
                variant = "secondary",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    if form_.queryName == "" then
                        SetStatus({ ok = false, reason = "昵称不能为空" }, onChanged)
                        return
                    end
                    ServerClient.AdminQueryByName(form_.queryName, function(response)
                        if response and response.ok and response.data then
                            byNameMatches_ = response.data.matches or {}
                        end
                        SetStatus(response, onChanged)
                    end)
                end,
            },
        }),
        Label(UI, QueryByNameSummary(), 10, {213, 226, 255, 255}),
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

    -- 邮件管理页
    local mailSection = Section(UI, "GM 邮件", {
        Field(UI, "标题", "mailTitle", "邮件标题"),
        Field(UI, "正文", "mailBody", "邮件正文"),
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
                        Label(UI, "邮件类型", 10, {154, 177, 226, 255}),
                        UI.Dropdown {
                            width = "100%",
                            value = form_.mailType,
                            options = {
                                { value = "reward", label = "奖励邮件" },
                                { value = "notice", label = "系统通知" },
                                { value = "task", label = "任务结果" },
                                { value = "ops", label = "运营定向" },
                                { value = "special", label = "系统特殊" },
                            },
                            onChange = function(self, value) form_.mailType = value end,
                        },
                    },
                },
                UI.Panel { flexGrow = 1, flexBasis = 0, children = { Field(UI, "金币附件", "mailGold", "0 = 无") } },
                UI.Panel { flexGrow = 1, flexBasis = 0, children = { Field(UI, "有效期(天)", "broadcastExpireDays", "默认7天") } },
            },
        },
        Field(UI, "邮件ID（强制过期用）", "mailId", "查询后复制"),
        ButtonRow(UI, {
            UI.Button {
                text = "发送测试邮件",
                variant = "success",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    local title = form_.mailTitle
                    local body = form_.mailBody
                    if title == "" or body == "" then
                        SetStatus({ ok = false, reason = "标题和正文不能为空" }, onChanged)
                        return
                    end
                    local gold = ToInteger(form_.mailGold) or 0
                    local attachments = {}
                    if gold > 0 then
                        attachments[#attachments + 1] = { kind = "currency", currency = "gold", count = gold }
                    end
                    ServerClient.AdminSendMail({
                        targetUid = form_.targetUid,
                        title = title,
                        body = body,
                        mailType = form_.mailType,
                        batchId = "gm_test",
                        attachments = attachments,
                    }, function(response) SetStatus(response, onChanged) end)
                end,
            },
            UI.Button {
                text = "发送全服邮件",
                variant = "warning",
                width = 220,
                disabled = readOnly,
                onClick = function()
                    local title = form_.mailTitle
                    local body = form_.mailBody
                    if title == "" or body == "" then
                        SetStatus({ ok = false, reason = "标题和正文不能为空" }, onChanged)
                        return
                    end
                    local gold = ToInteger(form_.mailGold) or 0
                    local attachments = {}
                    if gold > 0 then
                        attachments[#attachments + 1] = { kind = "currency", currency = "gold", count = gold }
                    end
                    local expireDays = ToInteger(form_.broadcastExpireDays) or 7
                    ServerClient.AdminSendBroadcastMail({
                        title = title,
                        body = body,
                        mailType = form_.mailType,
                        expireDays = expireDays,
                        attachments = attachments,
                    }, function(response) SetStatus(response, onChanged) end)
                end,
            },
            UI.Button {
                text = "查询邮件",
                variant = "primary",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    if form_.targetUid == "" then
                        SetStatus({ ok = false, reason = "目标玩家编号不能为空" }, onChanged)
                        return
                    end
                    ServerClient.AdminMailList(form_.targetUid, function(response)
                        if response and response.ok and response.data then
                            mailList_ = response.data.items or {}
                        end
                        SetStatus(response, onChanged)
                    end)
                end,
            },
            UI.Button {
                text = "强制过期",
                variant = "warning",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    if form_.targetUid == "" or form_.mailId == "" then
                        SetStatus({ ok = false, reason = "需要目标编号和邮件ID" }, onChanged)
                        return
                    end
                    ServerClient.AdminMailForceExpire(form_.targetUid, form_.mailId, function(response)
                        SetStatus(response, onChanged)
                    end)
                end,
            },
            UI.Button {
                text = "清理测试邮件",
                variant = "danger",
                width = 210,
                disabled = readOnly,
                onClick = function()
                    if form_.targetUid == "" then
                        SetStatus({ ok = false, reason = "目标玩家编号不能为空" }, onChanged)
                        return
                    end
                    ServerClient.AdminMailCleanTest(form_.targetUid, function(response)
                        SetStatus(response, onChanged)
                    end)
                end,
            },
        }),
        Label(UI, MailListSummary(), 10, {213, 226, 255, 255}),
    })

    -- 系统审计页
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

    local contentChildren
    if activeTab_ == "player" then
        contentChildren = {
            querySection,
            PlayerDetailCard(UI, queriedPlayer_),
            currencySection,
            equipmentSection,
            progressSection,
            banSection,
        }
    elseif activeTab_ == "mail" then
        contentChildren = { mailSection }
    else
        contentChildren = {
            Section(UI, "最近审计", {
                ButtonRow(UI, {
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
                table.unpack(auditRows),
            }),
        }
    end

    return UI.Panel {
        width = "100%",
        height = "100%",
        padding = 22,
        gap = 12,
        children = {
            UI.Panel {
                width = "100%",
                flexShrink = 0,
                gap = 8,
                children = {
                    UI.Panel {
                        width = "100%",
                        height = 56,
                        justifyContent = "center",
                        children = { Label(UI, "管理后台", 18, {111, 231, 255, 255}) },
                    },
                    TabBar(UI, onChanged),
                },
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
                        children = contentChildren,
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
