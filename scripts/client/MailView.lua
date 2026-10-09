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
local RewardDialogView = require("client.RewardDialogView")
local EquipmentCatalog = require("shared.EquipmentCatalog")
local WishPoolDefinitions = require("shared.WishPoolDefinitions")
local AbyssDefinitions = require("shared.AbyssDefinitions")
local ServerClock = require("client.ServerClock")
local GridVirtualList = require("client.UI.GridVirtualList")

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
-- 当前邮件列表的 VirtualList 实例与操作栏容器。
-- 数据刷新（Refresh）时只对列表 UpdateData、重绘操作栏，不重建整个层，
-- 保证玩家滚动位置不受影响（数据与表现解耦）。
local listWidget_ = nil
local actionBarHost_ = nil

-- ============================================================================
-- 格式化
-- ============================================================================

local function FormatClock(timestamp, now)
    now = now or ServerClock.Now()
    timestamp = math.max(0, math.floor(tonumber(timestamp) or 0))
    if timestamp <= 0 then return "—" end
    local elapsed = math.max(0, now - timestamp)
    local day = math.floor(elapsed / 86400)
    local hour = math.floor((elapsed % 86400) / 3600)
    local minute = math.floor((elapsed % 3600) / 60)
    if day > 0 then
        return string.format("%d天前", day)
    end
    if hour > 0 then return string.format("%d小时前", hour) end
    if minute > 0 then return string.format("%d分钟前", minute) end
    return "刚刚"
end

local function RemainingText(expireAt, now)
    expireAt = math.max(0, math.floor(tonumber(expireAt) or 0))
    now = math.max(0, math.floor(tonumber(now) or ServerClock.Now()))
    if expireAt <= 0 then return "永久" end
    local remain = expireAt - now
    if remain <= 0 then return "已过期" end
    local days = math.floor(remain / 86400)
    local hours = math.floor((remain % 86400) / 3600)
    if days > 0 then
        if hours > 0 then return string.format("剩%d天%d小时", days, hours) end
        return string.format("剩%d天", days)
    end
    local minutes = math.max(1, math.floor((remain % 3600) / 60))
    if hours > 0 then
        if minutes > 0 then return string.format("剩%d小时%d分", hours, minutes) end
        return string.format("剩%d小时", hours)
    end
    if minutes > 0 then return string.format("剩%d分钟", minutes) end
    return "即将过期"
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
-- 附件解析（图标 / 名称）
-- ============================================================================

-- 附件图标：金币/碎片/装备/许愿券/罐子，统一解析为通用道具图标。
local function AttachmentIcon(attachment)
    if attachment.kind == "currency" then
        return attachment.currency == "gold" and ASSETS.items.gold or ASSETS.items.crystal
    end
    if attachment.kind == "equipment" then
        local definition = attachment.equipmentId and EquipmentCatalog.Get(attachment.equipmentId)
        if definition and definition.icon then return definition.icon end
        return ASSETS.items.chest
    end
    if attachment.kind == "item" then
        local itemId = attachment.itemId or ""
        if itemId == "wish_ticket" then return WishPoolDefinitions.ICONS.ticket end
        if itemId == "abyss_ticket" then return AbyssDefinitions.ICON end
        if itemId:match("^jar%.") then
            local jar = WishPoolDefinitions.ResolveJar(itemId)
            if jar and jar.icon then return jar.icon end
        end
    end
    return ASSETS.items.chest
end

local function AttachmentName(attachment)
    if attachment.name and attachment.name ~= "" then return attachment.name end
    if attachment.kind == "currency" then
        return attachment.currency == "gold" and "金币" or "深渊碎片"
    end
    if attachment.kind == "equipment" then
        local definition = attachment.equipmentId and EquipmentCatalog.Get(attachment.equipmentId)
        if definition and definition.name then return definition.name end
        return "装备"
    end
    if attachment.kind == "item" then
        local itemId = attachment.itemId or ""
        if itemId == "wish_ticket" then return "许愿券" end
        if itemId == "abyss_ticket" then return "深渊票" end
        local jar = WishPoolDefinitions.ResolveJar(itemId)
        if jar and jar.name then return jar.name end
        return "道具"
    end
    return "附件"
end

-- 领取结果弹出通用奖励弹窗（装备 / 货币 / 许愿券 / 罐子统一走通用卡片）。
local function ShowClaimRewards(claimed)
    local cards = {}
    for _, att in ipairs(claimed or {}) do
        local icon = AttachmentIcon(att)
        local name = AttachmentName(att)
        if att.kind == "equipment" then
            RewardDialogView.AddCard(cards, icon, name, nil, att.rarity or "common", {
                id = att.id,
                equipmentId = att.equipmentId,
                name = name,
                rarity = att.rarity or "common",
                level = att.level or 1,
            })
        else
            RewardDialogView.AddCard(cards, icon, name, att.count or 1, "common", nil)
        end
    end
    if #cards == 0 then return false end
    RewardDialogView.Show({
        title = "邮件奖励",
        message = "奖励已领取",
        cards = cards,
        confirmText = "确认",
        zIndex = 3200,
    })
    return true
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
            Kit.CompactTxt(RemainingText(item.expireAt, ServerClock.Now()), 16, expired and C.error or C.textDim, {
                width = 132,
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
                -- 页签切换 = 换了一个列表，重置滚动位置；数据刷新才保留位置
                if listWidget_ then
                    listWidget_.scrollOffset_ = 0
                    listWidget_.scrollView_:SetScrollDirect(0, 0)
                end
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
    local content = GridVirtualList.Build {
        columns = 1,
        cardWidth = 880,
        cardHeight = 92,
        cardGap = 10,
        viewportHeight = 1250,
        data = list_,
        showScrollbar = true,
        widgetProps = {
            width = "100%",
            height = 1250,
        },
        createCard = function(row, slotIndex, item)
            if not item then return nil end
            return BuildListItem(item, function(mailId)
                MailView.ShowDetail(mailId)
            end)
        end,
        emptyState = function()
            return UI.Panel {
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
        end,
    }
    -- 记录列表实例：数据刷新时用它 UpdateData 就地更新（保留滚动位置），避免重建跳顶
    listWidget_ = content and content.scrollView_ and content or nil
    return content
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
                                local claimed = (response.data and response.data.claimed) or {}
                                if #claimed == 0 or not ShowClaimRewards(claimed) then
                                    Toast("领取完成", "success")
                                end
                                -- 若部分附件因背包满失败，给出统一处理入口。
                                local failedFull = false
                                for _, mail in ipairs(claimed) do
                                    for _, attachment in ipairs((mail and mail.attachments) or {}) do
                                        if attachment and attachment.failReason == "INVENTORY_FULL" then
                                            failedFull = true
                                            break
                                        end
                                    end
                                    if failedFull then break end
                                end
                                if failedFull then
                                    local ok, InventoryFullPrompt = pcall(require, "client.InventoryFullPrompt")
                                    if ok and InventoryFullPrompt and InventoryFullPrompt.Show then
                                        InventoryFullPrompt.Show({
                                            reason = "部分邮件附件因背包已满未能入包",
                                        })
                                    end
                                end
                                MailView.Refresh()
                            else
                                local reason = (response and response.reason) or "领取失败"
                                Toast(reason)
                                if response and (response.code == "INVENTORY_FULL"
                                    or (type(reason) == "string" and reason:find("背包", 1, true)))
                                then
                                    local ok, InventoryFullPrompt = pcall(require, "client.InventoryFullPrompt")
                                    if ok and InventoryFullPrompt and InventoryFullPrompt.Show then
                                        InventoryFullPrompt.Show({ reason = reason })
                                    end
                                end
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

-- 操作栏容器：数据刷新后只重绘操作栏（按钮可见性依赖 list_），不触碰列表本身。
local function BuildActionBarHost()
    actionBarHost_ = ActionBar()
    return actionBarHost_
end

local function RefreshActionBar()
    if not actionBarHost_ then return end
    for i = #actionBarHost_.children, 1, -1 do
        local child = actionBarHost_.children[i]
        actionBarHost_:RemoveChild(child)
        child:Destroy()
    end
    local fresh = ActionBar()
    if fresh then
        for _, child in ipairs(fresh.children or {}) do
            actionBarHost_:AddChild(child)
        end
        fresh:Destroy()
    end
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
            BuildListContent(),
            BuildActionBarHost(),
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
end

function MailView.Refresh()
    if not root_ or not layer_ then return end
    ServerClient.MailList(scope_, function(response)
        if response and response.ok then
            list_ = (response.data and response.data.items) or {}
            if listWidget_ and #list_ > 0 then
                -- 数据更新：保留当前滚动位置，只刷新当前显示区域的邮件行，不重建列表
                GridVirtualList.UpdateData(listWidget_, list_, { columns = 1 })
                RefreshActionBar()
            elseif layer_ then
                -- 列表尚未构建 / 空态与列表态切换：需要整层重建
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
    listWidget_ = nil
    actionBarHost_ = nil
end

-- ============================================================================
-- 详情
-- ============================================================================

-- 附件展示：通用道具 icon 格子 + 名称 + 数量 + 领取状态。
local function BuildAttachmentRow(attachment)
    local claimed = (attachment.claimedCount or 0) >= (attachment.count or 1)
    local name = AttachmentName(attachment)
    local levelText = attachment.level and attachment.level > 1
        and string.format("Lv.%d", attachment.level)
        or nil
    local statusText = "未领取"
    if claimed then
        statusText = "已领取"
    elseif attachment.failReason then
        statusText = MailRules.CLAIM_ERRORS[attachment.failReason] or attachment.failReason
    end
    return UI.Panel {
        width = 128,
        height = 158,
        flexShrink = 0,
        alignItems = "center",
        justifyContent = "flex-start",
        gap = 2,
        paddingTop = 8,
        children = {
            UI.Panel {
                width = 88,
                height = 88,
                flexShrink = 0,
                backgroundImage = AttachmentIcon(attachment),
                backgroundFit = "contain",
                borderWidth = 1,
                borderColor = claimed and C.border or C.focus,
                borderRadius = 10,
            },
            Kit.CompactTxt(Kit.ShortenText(name, 6), 16, claimed and C.textSecondary or C.text, {
                width = 118,
                textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
                pointerEvents = "none",
            }),
            levelText and Kit.CompactTxt(levelText, 15, C.gold, {
                width = 118,
                textAlign = "center",
                pointerEvents = "none",
            }) or Kit.CompactTxt("×" .. Kit.FormatInt(attachment.count or 1), 16, C.gold, {
                width = 118,
                textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
                pointerEvents = "none",
            }),
            Kit.CompactTxt(statusText, 15, claimed and C.success or (attachment.failReason and C.error or C.warning), {
                width = 118,
                textAlign = "center",
                pointerEvents = "none",
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
    local isPermanent = (mail.expireAt or 0) <= 0
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
                        local claimed = (response.data and response.data.claimed) or {}
                        if #claimed == 0 or not ShowClaimRewards(claimed) then
                            Toast("领取成功", "success")
                        end
                        local failedFull = false
                        for _, entry in ipairs(claimed) do
                            for _, attachment in ipairs((entry and entry.attachments) or {}) do
                                if attachment and attachment.failReason == "INVENTORY_FULL" then
                                    failedFull = true
                                    break
                                end
                            end
                            if failedFull then break end
                        end
                        if failedFull then
                            local ok, InventoryFullPrompt = pcall(require, "client.InventoryFullPrompt")
                            if ok and InventoryFullPrompt and InventoryFullPrompt.Show then
                                InventoryFullPrompt.Show({
                                    reason = "邮件附件因背包已满未能入包",
                                })
                            end
                        end
                        MailView.ShowDetail(mail.mailId)
                    else
                        local reason = (response and response.reason) or "领取失败"
                        Toast(reason)
                        if response and (response.code == "INVENTORY_FULL"
                            or (type(reason) == "string" and reason:find("背包", 1, true)))
                        then
                            local ok, InventoryFullPrompt = pcall(require, "client.InventoryFullPrompt")
                            if ok and InventoryFullPrompt and InventoryFullPrompt.Show then
                                InventoryFullPrompt.Show({ reason = reason })
                            end
                        end
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
                            -- 发件人 + 发送时间
                            UI.Panel {
                                width = "100%",
                                flexDirection = "row",
                                alignItems = "center",
                                gap = 12,
                                children = {
                                    Kit.CompactTxt(mail.sender or "系统", 20, C.focus, {
                                        flexGrow = 1, flexBasis = 0, textAlign = "left",
                                    }),
                                    Kit.CompactTxt("发送于 " .. FormatClock(mail.sentAt), 18, C.textDim, {
                                        width = 220, textAlign = "right",
                                    }),
                                },
                            },
                            -- 时效信息（醒目色块标签 + 剩余时间）
                            UI.Panel {
                                width = "100%",
                                height = 54,
                                flexDirection = "row",
                                alignItems = "center",
                                gap = 12,
                                paddingLeft = 14,
                                paddingRight = 14,
                                borderRadius = 10,
                                backgroundColor = expired and { 70, 22, 26, 150 } or { 18, 40, 76, 180 },
                                children = {
                                    UI.Panel {
                                        width = 96,
                                        height = 36,
                                        flexShrink = 0,
                                        alignItems = "center",
                                        justifyContent = "center",
                                        borderRadius = 8,
                                        backgroundColor = expired and C.error or (isPermanent and C.textDim or C.gold),
                                        children = {
                                            Kit.CompactTxt(expired and "已过期" or (isPermanent and "永久有效" or "剩余时间"), 17, C.text, {
                                                width = "100%",
                                                textAlign = "center",
                                                textStroke = { width = 2, color = "#000000" },
                                                pointerEvents = "none",
                                            }),
                                        },
                                    },
                                    Kit.CompactTxt(
                                        expired and "该邮件已过期，附件无法领取"
                                            or (isPermanent and "本邮件长期有效" or RemainingText(mail.expireAt, ServerClock.Now())),
                                        18,
                                        expired and C.error or (isPermanent and C.textSecondary or C.gold),
                                        {
                                            flexGrow = 1,
                                            flexBasis = 0,
                                            textAlign = "left",
                                            textStroke = { width = 1, color = "#000000" },
                                        }
                                    ),
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
                                flexDirection = "row",
                                flexWrap = "wrap",
                                gap = 8,
                                padding = 10,
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
    require("client.UI.DialogSettingsAccess").Attach(stage, true)
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
