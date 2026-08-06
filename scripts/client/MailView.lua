-- MailView.lua
-- 邮件面板：普通/收藏页签 + 邮件列表 + 详情（含领取/收藏/删除，一键领取/一键删除已读）。
-- 独立 overlay，不阻塞排行榜等其他弹窗。所有状态以服务端为准。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ServerClient = require("client.ServerClient")
local MailRules = require("shared.MailRules")
local CommonPromptDialog = require("client.CommonPromptDialog")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local MailView = {}

local LAYER_Z = 2500
local DIALOG_W = 1000
local DIALOG_H = 1660

---@type Widget|nil
local root_ = nil
---@type Widget|nil
local layer_ = nil
---@type Widget|nil
local detailLayer_ = nil

local scope_ = "all"
local list_ = {}
local rebuild_ = nil
local detailRebuild_ = nil

-- ============================================================================
-- 格式化
-- ============================================================================

local function FormatClock(timestamp)
    timestamp = math.max(0, math.floor(tonumber(timestamp) or 0))
    if timestamp <= 0 then return "—" end
    local day = math.floor(timestamp / 86400)
    local hour = math.floor((timestamp % 86400) / 3600)
    local minute = math.floor((timestamp % 3600) / 60)
    if day > 0 then
        return string.format("%d天前", day)
    end
    if hour > 0 then return string.format("%d小时前", hour) end
    if minute > 0 then return string.format("%d分钟前", minute) end
    return "刚刚"
end

local function RemainingText(expireAt, now)
    expireAt = math.max(0, math.floor(tonumber(expireAt) or 0))
    if expireAt <= 0 then return "永久" end
    local remain = expireAt - now
    if remain <= 0 then return "已过期" end
    local days = math.ceil(remain / 86400)
    if days >= 1 then return "剩" .. tostring(days) .. "天" end
    return "剩" .. tostring(math.max(1, math.ceil(remain / 3600))) .. "小时"
end

local function AttachLabel(state)
    if state == "none" then return nil end
    if state == "pending" then return { text = "未领", color = C.gold } end
    if state == "partial" then return { text = "部分", color = C.warning } end
    return { text = "已领", color = C.success }
end

-- ============================================================================
-- 通用 toast
-- ============================================================================

local function Toast(message, variant)
    UI.Toast.Show(tostring(message), { duration = 2.2, variant = variant or "error", position = "bottom" })
end

-- ============================================================================
-- 列表
-- ============================================================================

local function BuildListItem(item, onOpen)
    local attach = AttachLabel(item.attachState)
    local expired = item.expired == true
    return UI.Panel {
        width = "100%",
        height = 92,
        flexShrink = 0,
        clickable = true,
        flexDirection = "row",
        alignItems = "center",
        gap = 12,
        paddingLeft = 18,
        paddingRight = 18,
        borderWidth = 2,
        borderColor = item.favorite and C.gold or (expired and C.border or { 80, 173, 225, 120 }),
        borderRadius = 10,
        backgroundColor = expired and { 16, 30, 52, 210 } or (item.read and { 10, 26, 52, 200 } or { 24, 54, 100, 210 }),
        onClick = function() if onOpen then onOpen(item.mailId) end end,
        children = {
            UI.Panel {
                width = 10,
                height = 10,
                flexShrink = 0,
                shape = "circle",
                backgroundColor = item.read and { 0, 0, 0, 0 } or C.gold,
            },
            UI.Panel {
                flexGrow = 1,
                flexBasis = 0,
                gap = 4,
                justifyContent = "center",
                children = {
                    Kit.Txt(item.title or "", 24, expired and C.textDim or C.text, {
                        width = "100%",
                        textAlign = "left",
                        textStroke = { width = 1, color = "#000000" },
                        whiteSpace = "nowrap",
                    }),
                    Kit.CompactTxt((item.sender or "") .. "  ·  " .. FormatClock(item.sentAt), 18, C.textDim, {
                        width = "100%",
                        textAlign = "left",
                    }),
                },
            },
            attach and Kit.CompactTxt(attach.text, 18, attach.color, {
                width = 56,
                textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
            }) or nil,
            Kit.CompactTxt(item.favorite and "★" or "☆", 24, item.favorite and C.gold or C.textDim, {
                width = 40,
                textAlign = "center",
            }),
            Kit.CompactTxt(RemainingText(item.expireAt, os.time()), 17, expired and C.error or C.textDim, {
                width = 90,
                textAlign = "right",
                textStroke = { width = 1, color = "#000000" },
            }),
        },
    }
end

local function BuildTabBar()
    local tabs = {
        { id = "all", name = "普通" },
        { id = "favorite", name = "收藏" },
    }
    local children = {}
    for _, tab in ipairs(tabs) do
        local active = scope_ == tab.id
        children[#children + 1] = UI.Panel {
            width = 180,
            height = 60,
            flexShrink = 0,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = active and ASSETS.ui.marketTabOn or ASSETS.ui.marketTabOff,
            backgroundFit = "sliced",
            backgroundSlice = { 10, 10, 10, 10 },
            onClick = function()
                if scope_ == tab.id then return end
                scope_ = tab.id
                MailView.Refresh()
            end,
            children = {
                Kit.Txt(tab.name, 24, active and C.text or C.textDim, {
                    width = "100%",
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        }
    end
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        flexDirection = "row",
        justifyContent = "center",
        alignItems = "center",
        gap = 24,
        children = children,
    }
end

local function BuildListContent()
    local now = os.time()
    local rows = {}
    for _, item in ipairs(list_) do
        rows[#rows + 1] = BuildListItem(item, function(mailId)
            MailView.ShowDetail(mailId)
        end)
    end
    if #rows == 0 then
        rows[1] = UI.Panel {
            width = "100%",
            height = 220,
            alignItems = "center",
            justifyContent = "center",
            children = {
                Kit.Txt(scope_ == "favorite" and "暂无收藏邮件" or "邮箱空空如也", 26, C.textSecondary, {
                    width = "100%",
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                }),
            },
        }
    end

    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        gap = 10,
        paddingBottom = 12,
        children = rows,
    }
end

local function ActionBar()
    local hasClaimable = false
    local hasDeletable = false
    for _, item in ipairs(list_) do
        if item.hasUnclaimed and not item.expired then hasClaimable = true end
        if item.read and not item.favorite and not item.hasUnclaimed then hasDeletable = true end
    end
    local children = {}
    if hasClaimable then
        children[#children + 1] = UI.Panel {
            width = 300,
            height = 76,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = ASSETS.ui.dialogConfirm,
            backgroundFit = "contain",
            onClick = function()
                CommonPromptDialog.Show {
                    kind = "confirm",
                    queueKey = "mail:claim-all",
                    zIndex = 2700,
                    title = "一键领取",
                    message = "确定一键领取所有可领取附件吗？",
                    confirmText = "领取",
                    cancelText = "取消",
                    onConfirm = function()
                        ServerClient.MailClaimAll(function(response)
                            if response and response.ok then
                                Toast("领取完成", "success")
                                MailView.Refresh()
                            else
                                Toast((response and response.reason) or "领取失败")
                                MailView.Refresh()
                            end
                        end)
                    end,
                }
            end,
            children = {
                Kit.Txt("一键领取", 22, C.text, {
                    width = "100%", height = 76, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    end
    if hasDeletable then
        children[#children + 1] = UI.Panel {
            width = 300,
            height = 76,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = ASSETS.ui.inventoryActionGold,
            backgroundFit = "contain",
            onClick = function()
                CommonPromptDialog.Show {
                    kind = "confirm",
                    queueKey = "mail:delete-read",
                    zIndex = 2700,
                    title = "一键删除",
                    message = "确定删除所有已读且已处理（无未领附件）的邮件吗？",
                    confirmText = "删除",
                    cancelText = "取消",
                    onConfirm = function()
                        ServerClient.MailDeleteRead(function(response)
                            if response and response.ok then
                                Toast("已删除", "success")
                                MailView.Refresh()
                            else
                                Toast((response and response.reason) or "删除失败")
                            end
                        end)
                    end,
                }
            end,
            children = {
                Kit.Txt("一键删除已读", 22, C.text, {
                    width = "100%", height = 76, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    end
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        flexDirection = "row",
        justifyContent = "center",
        alignItems = "center",
        gap = 30,
        children = children,
    }
end

local function BuildPanelContent()
    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        gap = 16,
        paddingTop = 10,
        paddingBottom = 12,
        children = {
            BuildTabBar(),
            UI.ScrollView {
                width = "100%",
                height = 1250,
                scrollX = false,
                scrollY = true,
                showScrollbar = true,
                children = { BuildListContent() },
            },
            ActionBar(),
        },
    }
end

function MailView.Show()
    if not root_ then return end
    scope_ = scope_ or "all"
    ServerClient.MailList(scope_, function(response)
        if not response or not response.ok then
            Toast((response and response.reason) or "邮件加载失败")
            return
        end
        list_ = (response.data and response.data.items) or {}
        MailView.Present()
    end)
end

function MailView.Present()
    if not root_ then return end
    MailView.Hide()
    local function Close()
        MailView.Hide()
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
            Kit.Txt("邮件", 32, C.text, {
                position = "absolute", left = 56, top = 4,
                width = DIALOG_W - 112, height = 72, textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
            UI.Panel {
                position = "absolute",
                left = 60,
                top = 100,
                width = DIALOG_W - 120,
                height = DIALOG_H - 220,
                children = {
                    UI.Panel {
                        width = "100%",
                        flexShrink = 0,
                        children = { BuildPanelContent() },
                    },
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
end

function MailView.Refresh()
    if not root_ or not layer_ then return end
    ServerClient.MailList(scope_, function(response)
        if response and response.ok then
            list_ = (response.data and response.data.items) or {}
            -- 重建列表内容
            if layer_ then
                MailView.Present()
            end
        end
    end)
end

function MailView.AttachRoot(root)
    MailView.Hide()
    root_ = root
end

function MailView.Hide()
    if detailLayer_ and root_ then root_:RemoveChild(detailLayer_) end
    detailLayer_ = nil
    detailRebuild_ = nil
    if layer_ and root_ then root_:RemoveChild(layer_) end
    layer_ = nil
    rebuild_ = nil
end

-- ============================================================================
-- 详情
-- ============================================================================

local function BuildAttachmentRow(attachment)
    local label
    if attachment.kind == "currency" then
        label = (attachment.currency == "gold" and "金币" or "深渊碎片")
            .. " × " .. Kit.FormatInt(attachment.count or 1)
    else
        label = (attachment.name or attachment.equipmentId or "装备")
            .. " × " .. Kit.FormatInt(attachment.count or 1)
    end
    local claimed = (attachment.claimedCount or 0) >= (attachment.count or 1)
    return UI.Panel {
        width = "100%",
        height = 52,
        flexShrink = 0,
        flexDirection = "row",
        alignItems = "center",
        paddingLeft = 16,
        paddingRight = 16,
        borderBottomWidth = 1,
        borderBottomColor = C.border,
        children = {
            Kit.CompactTxt(label, 20, claimed and C.textSecondary or C.text, {
                flexGrow = 1,
                flexBasis = 0,
                textAlign = "left",
                textStroke = { width = 1, color = "#000000" },
            }),
            attachment.failReason
                and Kit.CompactTxt(MailRules.CLAIM_ERRORS[attachment.failReason] or attachment.failReason, 17, C.error, {
                    width = 220,
                    textAlign = "right",
                })
                or Kit.CompactTxt(claimed and "已领取" or "未领取", 18, claimed and C.success or C.gold, {
                    width = 120,
                    textAlign = "right",
                }),
        },
    }
end

function MailView.ShowDetail(mailId)
    if not root_ then return end
    ServerClient.MailDetail(mailId, function(response)
        if not response or not response.ok then
            Toast((response and response.reason) or "邮件详情加载失败")
            return
        end
        local detail = response.data or {}
        MailView.PresentDetail(detail)
        -- 阅读规则：无未领附件的邮件打开详情后自动标记已读
        if not detail.hasUnclaimed and not detail.read then
            ServerClient.MailRead(mailId, function(readResponse)
                if readResponse and readResponse.ok then
                    MailView.Refresh()
                end
            end)
        end
    end)
end

function MailView.PresentDetail(mail)
    if not root_ then return end
    if detailLayer_ and root_ then root_:RemoveChild(detailLayer_) end
    detailLayer_ = nil

    local expired = mail.expired == true
    local hasUnclaimed = mail.hasUnclaimed == true
    local attachRows = {}
    for _, attachment in ipairs(mail.attachments or {}) do
        attachRows[#attachRows + 1] = BuildAttachmentRow(attachment)
    end

    local function CloseDetail()
        if detailLayer_ and root_ then root_:RemoveChild(detailLayer_) end
        detailLayer_ = nil
        MailView.Refresh()
    end

    local function DeleteMail(force)
        local function request(callback)
            if force then
                ServerClient.MailDeleteFavorited(mail.mailId, callback)
            else
                ServerClient.MailDelete(mail.mailId, callback)
            end
        end
        request(function(response)
            if response and response.ok then
                CloseDetail()
                Toast("已删除", "success")
            else
                if response and response.code == "MAIL_FAVORITED" then
                    CommonPromptDialog.Show {
                        kind = "confirm",
                        queueKey = "mail:delete-favorited",
                        zIndex = 2700,
                        title = "删除收藏邮件",
                        message = "该邮件已收藏，是否取消收藏并删除？",
                        confirmText = "删除",
                        cancelText = "取消",
                        onConfirm = function()
                            ServerClient.MailDeleteFavorited(mail.mailId, function(resp2)
                                if resp2 and resp2.ok then
                                    CloseDetail()
                                    Toast("已删除", "success")
                                else
                                    Toast((resp2 and resp2.reason) or "删除失败")
                                end
                            end)
                        end,
                    }
                else
                    Toast((response and response.reason) or "删除失败")
                end
            end
        end)
    end

    local actionButtons = {}
    if hasUnclaimed and not expired then
        actionButtons[#actionButtons + 1] = UI.Panel {
            width = 260,
            height = 74,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = ASSETS.ui.dialogConfirm,
            backgroundFit = "contain",
            onClick = function()
                ServerClient.MailClaim(mail.mailId, function(response)
                    if response and response.ok then
                        Toast("领取成功", "success")
                        MailView.ShowDetail(mail.mailId)
                    else
                        Toast((response and response.reason) or "领取失败")
                    end
                end)
            end,
            children = {
                Kit.Txt("领取", 22, C.text, {
                    width = "100%", height = 74, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    elseif hasUnclaimed and expired then
        actionButtons[#actionButtons + 1] = UI.Panel {
            width = 260,
            height = 74,
            alignItems = "center",
            justifyContent = "center",
            opacity = 0.4,
            backgroundImage = ASSETS.ui.dialogConfirm,
            backgroundFit = "contain",
            children = {
                Kit.Txt("已过期", 22, C.text, {
                    width = "100%", height = 74, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    end
    actionButtons[#actionButtons + 1] = UI.Panel {
        width = 200,
        height = 74,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = ASSETS.ui.inventoryActionGold,
        backgroundFit = "contain",
        onClick = function()
            ServerClient.MailFavorite(mail.mailId, not mail.favorite, function(response)
                if response and response.ok then
                    mail.favorite = not mail.favorite
                    Toast(mail.favorite and "已收藏" or "已取消收藏", "success")
                    MailView.PresentDetail(mail)
                else
                    Toast((response and response.reason) or "操作失败")
                end
            end)
        end,
        children = {
            Kit.Txt(mail.favorite and "取消收藏" or "收藏", 21, C.text, {
                width = "100%", height = 74, textAlign = "center",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            }),
        },
    }
    if not hasUnclaimed then
        actionButtons[#actionButtons + 1] = UI.Panel {
            width = 200,
            height = 74,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = ASSETS.ui.inventoryActionRed,
            backgroundFit = "contain",
            onClick = function() DeleteMail(false) end,
            children = {
                Kit.Txt("删除", 21, C.text, {
                    width = "100%", height = 74, textAlign = "center",
                    textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
                }),
            },
        }
    end

    local dialog = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = 860,
        height = 1320,
        clickable = true,
        overflow = "hidden",
        backgroundColor = { 12, 22, 44, 255 },
        backgroundImage = ASSETS.ui.dialogFrame,
        backgroundFit = "sliced",
        backgroundSlice = { 72, 42, 92, 42 },
        children = {
            Kit.Txt(mail.title or "邮件详情", 30, C.text, {
                position = "absolute", left = 48, top = 2,
                width = 764, height = 68, textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
            UI.ScrollView {
                position = "absolute",
                left = 48,
                top = 92,
                width = 764,
                height = 1060,
                scrollX = false,
                scrollY = true,
                showScrollbar = true,
                children = {
                    UI.Panel {
                        width = "100%",
                        flexShrink = 0,
                        gap = 16,
                        paddingTop = 8,
                        paddingBottom = 16,
                        children = {
                            UI.Panel {
                                width = "100%",
                                flexDirection = "row",
                                alignItems = "center",
                                gap = 12,
                                children = {
                                    Kit.CompactTxt(mail.sender or "系统", 20, C.focus, {
                                        flexGrow = 1, flexBasis = 0, textAlign = "left",
                                    }),
                                    Kit.CompactTxt(FormatClock(mail.sentAt), 18, C.textDim, {
                                        width = 160, textAlign = "right",
                                    }),
                                    Kit.CompactTxt(RemainingText(mail.expireAt, os.time()), 18,
                                        expired and C.error or C.textSecondary, {
                                            width = 150, textAlign = "right",
                                        }),
                                },
                            },
                            UI.Panel {
                                width = "100%",
                                minHeight = 140,
                                padding = 16,
                                borderRadius = 10,
                                backgroundColor = { 10, 26, 52, 160 },
                                children = {
                                    Kit.MultiTxt(mail.body or "", 24, C.text, {
                                        width = "100%",
                                        textAlign = "left",
                                        textStroke = { width = 1, color = "#000000" },
                                    }),
                                },
                            },
                            Kit.Txt("附件", 24, C.gold, { width = "100%", textAlign = "left", textStroke = { width = 2, color = "#000000" } }),
                            UI.Panel {
                                width = "100%",
                                borderRadius = 10,
                                overflow = "hidden",
                                backgroundColor = { 10, 26, 52, 160 },
                                children = #attachRows > 0 and attachRows or {
                                    Kit.CompactTxt("无附件", 20, C.textDim, {
                                        width = "100%", height = 52, textAlign = "center",
                                    }),
                                },
                            },
                        },
                    },
                },
            },
            UI.Panel {
                position = "absolute",
                left = 0,
                bottom = 0,
                width = 860,
                height = 110,
                flexDirection = "row",
                justifyContent = "center",
                alignItems = "center",
                gap = 24,
                children = actionButtons,
            },
            UI.Panel {
                position = "absolute",
                right = 20,
                top = 40,
                width = 60,
                height = 60,
                clickable = true,
                backgroundImage = ASSETS.ui.dialogClose,
                backgroundFit = "contain",
                onClick = CloseDetail,
            },
        },
    }

    local stage = UI.Panel {
        position = "relative",
        width = 860,
        height = 1320,
        pointerEvents = "box-none",
        alignItems = "center",
        justifyContent = "center",
        children = { dialog },
    }
    detailLayer_ = UI.Panel {
        position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        zIndex = LAYER_Z + 100,
        pointerEvents = "box-none",
        alignItems = "center",
        justifyContent = "center",
        children = {
            UI.Panel {
                position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
                clickable = true,
                backgroundImage = ASSETS.ui.screenOverlay,
                backgroundFit = "cover",
                onClick = CloseDetail,
            },
            stage,
        },
    }
    root_:AddChild(detailLayer_)
end

function MailView.Reset()
    MailView.Hide()
    root_ = nil
    list_ = {}
    scope_ = "all"
end

return MailView
