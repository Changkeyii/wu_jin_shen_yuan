--- 市场集合页正式表现层。
---
--- 视觉规则：
---   * 仅使用 urhox-libs/UI 声明式组件，不包含任何 raw NanoVG 绘制。
---   * 背景/标题/主框/卡片/标签/按钮均使用图片素材。
---   * 按钮和标签用 contain 保持原比例；大型纯色中空面板使用九宫格 sliced。
---   * 装备展示复用 ItemSlotBase / EquipmentItemSlot，不重复实现装备格子。
---
--- 业务规则和服务器权威结算不在此文件实现。
local UI = require("urhox-libs/UI")
local MarketCatalog = require("shared.MarketCatalog")
local ItemSort = require("shared.ItemSort")
local LargeNumber = require("shared.LargeNumber")
local RarityCatalog = require("shared.RarityCatalog")
local ServerClient = require("client.ServerClient")
local ItemSlotBase = require("client.ItemSlotBase")
local EquipmentItemSlot = require("client.EquipmentItemSlot")
local BlackMarketView = require("client.BlackMarketView")

local MarketView = {}

local TABS = {
    { id = "black", name = "黑 市" },
    { id = "auction", name = "交 易 行" },
    { id = "soon", name = "待 续", locked = true },
}

local AUCTION_TABS = {
    { id = "browse", name = "浏览市场" },
    { id = "mine", name = "我的挂单" },
    { id = "mail", name = "交易信箱" },
}

local activeTab_ = "black"
local activeAuctionTab_ = "browse"
local rarityFilter_ = nil
local listDraft_ = { itemId = nil, price = "" }

local browseCache_ = {
    listings = {}, total = 0, levelCap = nil, nextSweepAt = 0,
    loadedAt = 0, loading = false,
}
local mailCache_ = { mails = {}, count = 0, loadedAt = 0, loading = false }

local context_ = nil

local SLOT_NAMES = {
    weapon = "武器", shoulder = "头肩", coat = "上衣", pants = "下装",
    belt = "腰带", shoes = "鞋", bracelet = "手镯", necklace = "项链",
    ring = "戒指", support = "辅助", magicstone = "魔法石", earring = "耳环",
}

local MAIL_LABELS = {
    sold = "成交收入",
    swept = "系统低价回收",
    returned = "挂单到期退回",
}

local function RarityName(rarityId)
    local rarity = RarityCatalog.Get(rarityId)
    return rarity and rarity.name or tostring(rarityId)
end

local function Refresh()
    if context_ and context_.onRefresh then context_.onRefresh() end
end

local function FormatGold(value)
    if context_ and context_.formatInt then return context_.formatInt(value) end
    return tostring(math.floor(tonumber(value) or 0))
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then return string.format("%d小时%d分", hours, minutes) end
    return string.format("%d分", minutes)
end

local function Toast(title, message)
    if not context_ or not context_.showPrompt then
        print("[MarketView] " .. tostring(title) .. ": " .. tostring(message))
        return
    end
    context_.showPrompt({ title = title, message = message, confirmText = "知道了" })
end

local function EquipmentContext()
    return {
        ASSETS = context_.ASSETS,
        C = context_.C,
        compactTxt = context_.compactTxt,
        itemImage = context_.itemImage,
        itemLevelText = context_.itemLevelText,
        isEquipped = context_.isEquipped,
        rarityColor = context_.rarityColor,
        shortenText = context_.shortenText,
        showItemTips = context_.showItemTips,
        registerItemTipsTrigger = context_.registerItemTipsTrigger,
        setEquipmentLock = context_.setEquipmentLock,
    }
end

-- 数据加载 -------------------------------------------------------------------

local function LoadBrowse(force)
    if browseCache_.loading then return end
    local now = os.time()
    if not force and browseCache_.loadedAt > 0 and (now - browseCache_.loadedAt) < 15 then return end
    browseCache_.loading = true
    ServerClient.MarketBrowse({ rarity = rarityFilter_, limit = 60 }, function(result)
        browseCache_.loading = false
        browseCache_.loadedAt = os.time()
        if result and result.ok then
            local data = result.data or {}
            browseCache_.listings = ItemSort.SortListings(data.listings or {})
            browseCache_.total = data.total or 0
            browseCache_.levelCap = data.levelCap
            browseCache_.nextSweepAt = data.nextSweepAt or 0
            browseCache_.serverTime = data.serverTime or os.time()
        else
            browseCache_.listings = {}
            browseCache_.total = 0
        end
        Refresh()
    end)
end

local function LoadMailbox(force)
    if mailCache_.loading then return end
    local now = os.time()
    if not force and mailCache_.loadedAt > 0 and (now - mailCache_.loadedAt) < 15 then return end
    mailCache_.loading = true
    ServerClient.MarketMailbox(function(result)
        mailCache_.loading = false
        mailCache_.loadedAt = os.time()
        if result and result.ok then
            local data = result.data or {}
            mailCache_.mails = data.mails or {}
            mailCache_.count = data.count or 0
        else
            mailCache_.mails = {}
            mailCache_.count = 0
        end
        Refresh()
    end)
end

-- 图片化通用控件 -------------------------------------------------------------

local function ImageButton(label, image, onClick, disabled, width)
    local C = context_.C
    width = width or 160
    return UI.Panel {
        width = width,
        height = 58,
        flexShrink = 0,
        clickable = not disabled,
        opacity = disabled and 0.42 or 1.0,
        backgroundImage = image,
        backgroundFit = "contain",
        onClick = disabled and nil or onClick,
        children = {
            context_.txt(label, 19, disabled and C.textDim or C.text, {
                width = "100%", height = 58, textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
        },
    }
end

local function RulesButton(title, message, queueKey)
    return UI.Panel {
        width = 64,
        height = 64,
        flexShrink = 0,
        clickable = true,
        backgroundImage = "image/ui/dialog/help_button.png",
        backgroundFit = "contain",
        onClick = function()
            context_.showPrompt({
                kind = "rules",
                queueKey = queueKey,
                title = title,
                message = message,
                confirmText = "知道了",
            })
        end,
    }
end

local function PrimaryTab(tab)
    local active = activeTab_ == tab.id
    return UI.Panel {
        width = 220, height = 72, flexShrink = 0,
        backgroundImage = active and context_.ASSETS.ui.marketTabOn or context_.ASSETS.ui.marketTabOff,
        backgroundFit = "contain",
        opacity = tab.locked and 0.65 or 1.0,
        clickable = true,
        onClick = function()
            if tab.locked then
                Toast("敬请期待", "该市场分区尚未开放")
                return
            end
            activeTab_ = tab.id
            Refresh()
        end,
        children = {
            context_.txt(tab.name, 23, active and context_.C.gold or context_.C.textSecondary, {
                width = "100%", height = 72, textAlign = "center",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            }),
        },
    }
end

local function SubTab(tab)
    local active = activeAuctionTab_ == tab.id
    return UI.Panel {
        width = 160, height = 58, flexShrink = 0,
        backgroundImage = active and context_.ASSETS.ui.inventoryTabOn
            or context_.ASSETS.ui.inventoryTabOff,
        backgroundFit = "contain",
        clickable = true,
        onClick = function()
            activeAuctionTab_ = tab.id
            if tab.id == "browse" then LoadBrowse(false) end
            if tab.id == "mail" then LoadMailbox(false) end
            Refresh()
        end,
        children = {
            context_.compactTxt(tab.name, 19, active and context_.C.gold or context_.C.textSecondary, {
                width = "100%", height = 58, textAlign = "center",
                textStroke = { width = 2, color = "#000000" }, pointerEvents = "none",
            }),
        },
    }
end

local function EmptyMessage(text)
    return UI.Panel {
        width = "100%", height = 170, flexShrink = 0,
        justifyContent = "center", alignItems = "center",
        children = {
            context_.compactTxt(text, 21, context_.C.textSecondary, {
                width = "100%", height = 44, textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
            }),
        },
    }
end

-- 黑市已拆分至 client.BlackMarketView。

-- 交易行卡片 -----------------------------------------------------------------

local function ListingItem(listing)
    local item = listing.item
    if type(item) == "table" then return item end
    return {
        id = listing.itemId,
        name = listing.name or "已上架装备",
        rarity = listing.rarity,
        slot = listing.slot,
        level = listing.level,
        enhance = listing.enhance or 0,
        star = listing.star or 0,
    }
end

local function ListingCard(listing, buttonLabel, buttonImage, onClick, disabled, extraText)
    local C = context_.C
    local item = ListingItem(listing)
    return UI.Panel {
        width = 900, height = 249, flexShrink = 0,
        position = "relative", overflow = "hidden",
        backgroundImage = context_.ASSETS.ui.inventoryDetailCompact,
        backgroundFit = "contain",
        children = {
            UI.Panel {
                position = "absolute", left = 32, top = 55,
                width = 138, height = 138,
                children = {
                    ItemSlotBase.Build(EquipmentContext(), item, {
                        size = 138, showEquipped = false,
                    }),
                },
            },
            context_.txt(context_.shortenText(item.name or "未知装备", 14), 22,
                context_.rarityColor(item.rarity), {
                    position = "absolute", left = 196, top = 35,
                    width = 420, height = 38, textAlign = "left",
                    textStroke = { width = 2, color = "#000000" },
                }),
            context_.compactTxt(string.format("%s · %s · Lv.%d",
                RarityName(item.rarity), SLOT_NAMES[item.slot] or item.slot,
                math.floor(tonumber(item.level) or 1)), 18, C.textSecondary, {
                    position = "absolute", left = 196, top = 79,
                    width = 420, height = 32,
                }),
            context_.compactTxt(extraText or "", 16, C.warning, {
                position = "absolute", left = 196, top = 124,
                width = 420, height = 64, whiteSpace = "normal", lineHeight = 1.35,
            }),
            context_.txt(FormatGold(listing.price or 0), 22, C.gold, {
                position = "absolute", left = 658, top = 51,
                width = 190, height = 40, textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            }),
            context_.compactTxt("金币", 15, C.textSecondary, {
                position = "absolute", left = 658, top = 92,
                width = 190, height = 25, textAlign = "center",
            }),
            UI.Panel {
                position = "absolute", left = 673, top = 139,
                width = 160, height = 58,
                children = { ImageButton(buttonLabel, buttonImage, onClick, disabled) },
            },
        },
    }
end

local function BuildBrowse(game)
    local C = context_.C
    LoadBrowse(false)

    local rows = {}
    for _, listing in ipairs(browseCache_.listings) do
        local blocked = listing.affordableLevel == false
        local swept = MarketCatalog.WillBeSwept(listing.price, listing.standardValue)
        local note = string.format("黑市标准值 %s", FormatGold(listing.standardValue))
        if blocked then
            note = note .. "\n装备等级超出当前购买范围"
        elseif swept then
            note = note .. "\n该价格将在固定时点被系统扫货"
        end
        rows[#rows + 1] = ListingCard(
            listing,
            blocked and "等级不足" or "购买",
            context_.ASSETS.ui.inventoryActionGold,
            function()
                local item = ListingItem(listing)
                context_.showPrompt({
                    title = "确认购买",
                    message = string.format("花费 %s 金币购买 %s？",
                        FormatGold(listing.price), tostring(item.name)),
                    confirmText = "购买", cancelText = "取消",
                    onConfirm = function()
                        ServerClient.MarketBuy(listing, function(result)
                            if result and result.ok then Toast("购买成功", "装备已放入背包")
                            else Toast("购买失败", (result and result.reason) or "请稍后再试") end
                            LoadBrowse(true)
                        end)
                    end,
                })
            end,
            blocked or game.readOnly,
            note
        )
    end
    if #rows == 0 then
        rows[1] = EmptyMessage(browseCache_.loading and "正在读取交易行..." or "当前没有符合条件的挂单")
    end

    local filterButtons = {
        ImageButton("全部", rarityFilter_ == nil and context_.ASSETS.ui.inventoryActionGold
            or context_.ASSETS.ui.inventoryActionBlue, function()
                rarityFilter_ = nil; LoadBrowse(true)
            end),
    }
    for _, rarityId in ipairs({ "myth", "epic", "legendary" }) do
        filterButtons[#filterButtons + 1] = ImageButton(RarityName(rarityId),
            rarityFilter_ == rarityId and context_.ASSETS.ui.inventoryActionGold
                or context_.ASSETS.ui.inventoryActionBlue,
            function() rarityFilter_ = rarityId; LoadBrowse(true) end)
    end
    filterButtons[#filterButtons + 1] = ImageButton("刷新", context_.ASSETS.ui.inventoryActionBlue,
        function() LoadBrowse(true) end)

    local sweepIn = math.max(0,
        (browseCache_.nextSweepAt or 0) - (browseCache_.serverTime or os.time()))

    return UI.Panel {
        width = "100%", height = "100%", position = "relative",
        children = {
            UI.Panel {
                position = "absolute", left = 16, top = 0, right = 16, height = 72,
                flexDirection = "row", gap = 12, alignItems = "center",
                children = filterButtons,
            },
            context_.compactTxt(string.format(
                "共 %d 件 · 可购买至 Lv.%d · 下次低价扫货 %s后",
                browseCache_.total or 0, browseCache_.levelCap or 0, FormatDuration(sweepIn)),
                17, C.textSecondary, {
                    position = "absolute", left = 24, top = 72,
                    width = 850, height = 34, textAlign = "center",
                }),
            UI.ScrollView {
                position = "absolute", left = 0, top = 112, right = 0, bottom = 0,
                scrollX = false, scrollY = true, showScrollbar = true,
                children = {
                    UI.Panel {
                        width = 900, flexShrink = 0, gap = 12,
                        marginLeft = 20,
                        paddingBottom = 24, children = rows,
                    },
                },
            },
        },
    }
end

-- 我的挂单 -------------------------------------------------------------------

local function BuildListingComposer(game)
    local C = context_.C
    local listings = game.marketListings or {}
    local listingSlots = MarketCatalog.GetListingSlots(game.vipLevel)

    local equipped = {}
    for _, itemId in pairs(game.equippedSlots or {}) do equipped[itemId] = true end
    local listed = {}
    for _, listing in ipairs(listings) do listed[listing.itemId] = true end

    local candidates = {}
    for _, item in ipairs(game.inventory or {}) do
        if MarketCatalog.IsListableItem(item) and not equipped[item.id]
            and not listed[item.id] and not item.locked and not item.aidLocked then
            candidates[#candidates + 1] = item
        end
    end

    ItemSort.Sort(candidates)

    local candidateCards = {}
    for index = 1, math.min(#candidates, 20) do
        local item = candidates[index]
        candidateCards[#candidateCards + 1] = EquipmentItemSlot.Build(EquipmentContext(), item, {
            width = 180, height = 182, slotSize = 128,
            clickable = true,
            active = listDraft_.itemId == item.id,
            detailText = listDraft_.itemId == item.id and "已选择" or "点击选择",
            onClick = function()
                listDraft_.itemId = listDraft_.itemId == item.id and nil or item.id
                Refresh()
            end,
        })
    end
    if #candidateCards == 0 then
        candidateCards[1] = EmptyMessage("背包中没有可交易的传说及以上装备")
    end

    local validPrice, _, price = MarketCatalog.ValidatePrice(listDraft_.price)
    price = price or LargeNumber.Zero()
    local feeBreakdown = MarketCatalog.GetFeeBreakdown(price, game.vipLevel)
    local canSubmit = listDraft_.itemId ~= nil and validPrice
        and #listings < listingSlots and not game.readOnly

    return UI.Panel {
        width = 900, height = 370, flexShrink = 0, position = "relative",
        backgroundImage = context_.ASSETS.ui.panelLarge,
        backgroundFit = "sliced", backgroundSlice = { 36, 36, 36, 36 },
        children = {
            context_.txt("选择上架装备", 23, C.gold, {
                position = "absolute", left = 36, top = 20,
                width = 300, height = 38, textAlign = "left",
            }),
            context_.compactTxt(string.format("挂单 %d / %d · 当前手续费 %.1f%%",
                #listings, listingSlots, feeBreakdown.rate * 100), 17, C.textSecondary, {
                    position = "absolute", left = 510, top = 24,
                    width = 340, height = 32, textAlign = "right",
                }),
            UI.ScrollView {
                position = "absolute", left = 32, top = 68,
                width = 836, height = 196,
                scrollX = true, scrollY = false, showScrollbar = false, bounces = false,
                children = {
                    UI.Panel {
                        height = 190, flexDirection = "row", gap = 10,
                        paddingLeft = 8, paddingRight = 8, children = candidateCards,
                    },
                },
            },
            UI.Panel {
                position = "absolute", left = 36, top = 280,
                width = 500, height = 64,
                backgroundImage = context_.ASSETS.ui.infoBarBlue,
                backgroundFit = "sliced", backgroundSlice = { 22, 22, 22, 22 },
                paddingLeft = 20, paddingTop = 9,
                children = {
                    UI.TextField {
                        width = 460, height = 46,
                        value = listDraft_.price,
                        placeholder = "输入任意上架价格（金币）",
                        borderColor = C.focus,
                        borderWidth = 1,
                        onChange = function(_, value)
                            listDraft_.price = tostring(value or ""):gsub("[^%d]", "")
                        end,
                    },
                },
            },
            context_.compactTxt(validPrice
                and string.format("成交实得 %s", FormatGold(feeBreakdown.proceeds))
                or "价格不限；异常低价会被扫货",
                16, C.textSecondary, {
                    position = "absolute", left = 548, top = 284,
                    width = 170, height = 58, textAlign = "center",
                }),
            UI.Panel {
                position = "absolute", left = 724, top = 280,
                width = 160, height = 58,
                children = {
                    ImageButton("确认上架", context_.ASSETS.ui.inventoryActionGold, function()
                        ServerClient.MarketList(listDraft_.itemId, price, function(result)
                            if result and result.ok then
                                listDraft_ = { itemId = nil, price = "" }
                                Toast("上架成功", "挂单有效期 48 小时")
                            else
                                Toast("上架失败", (result and result.reason) or "请稍后再试")
                            end
                            Refresh()
                        end)
                    end, not canSubmit),
                },
            },
        },
    }
end

local function BuildMyListings(game)
    local rows = { BuildListingComposer(game) }
    for _, listing in ipairs(game.marketListings or {}) do
        local remaining = math.max(0, (listing.expiresAt or 0) - os.time())
        local feeUnits = listing.feeUnits
            or math.floor((listing.feeRate or 0)
                * MarketCatalog.FEE_RATE_SCALE + 0.5)
        local proceeds = MarketCatalog.GetFeeBreakdownFromUnits(
            listing.price,
            feeUnits
        ).proceeds
        local note = string.format("剩余 %s\n成交实得 %s（手续费 %.1f%%）",
            FormatDuration(remaining),
            FormatGold(proceeds),
            (listing.feeRate or 0) * 100)
        rows[#rows + 1] = ListingCard(
            listing, "下架", context_.ASSETS.ui.inventoryActionRed,
            function()
                ServerClient.MarketCancel(listing.itemId, function(result)
                    if result and result.ok then Toast("已下架", "装备已退回背包")
                    else Toast("下架失败", (result and result.reason) or "请稍后再试") end
                    Refresh()
                end)
            end,
            game.readOnly,
            note
        )
    end
    if #(game.marketListings or {}) == 0 then
        rows[#rows + 1] = EmptyMessage("当前没有挂单")
    end

    return UI.ScrollView {
        width = "100%", height = "100%",
        scrollX = false, scrollY = true, showScrollbar = true,
        children = {
            UI.Panel {
                width = 900, flexShrink = 0, gap = 14,
                marginLeft = 20,
                paddingBottom = 24, children = rows,
            },
        },
    }
end

-- 交易信箱 -------------------------------------------------------------------

local function MailCard(mail)
    local C = context_.C
    local value = mail.value or {}
    local label = MAIL_LABELS[value.kind] or "市场邮件"
    local detail
    if not LargeNumber.IsZero(value.gold) then
        detail = string.format("到账 %s 金币 · 售价 %s · 手续费 %s",
            FormatGold(value.gold), FormatGold(value.price or 0), FormatGold(value.fee or 0))
    else
        detail = "挂单装备已退回，领取后进入背包"
    end
    return UI.Panel {
        width = 900, height = 142, flexShrink = 0,
        position = "relative", overflow = "hidden",
        backgroundImage = context_.ASSETS.ui.inventoryDetailCompact,
        backgroundFit = "sliced", backgroundSlice = { 32, 32, 32, 32 },
        children = {
            context_.txt(label, 22, value.kind == "swept" and C.warning or C.gold, {
                position = "absolute", left = 60, top = 28,
                width = 360, height = 38,
                textStroke = { width = 2, color = "#000000" },
            }),
            context_.compactTxt(detail, 17, C.textSecondary, {
                position = "absolute", left = 60, top = 74,
                width = 650, height = 34,
            }),
            context_.compactTxt(os.date("%m-%d %H:%M", math.floor(value.at or os.time())), 15, C.textDim, {
                position = "absolute", left = 720, top = 50,
                width = 130, height = 30, textAlign = "center",
            }),
        },
    }
end

local function BuildMailbox(game)
    local C = context_.C
    LoadMailbox(false)
    local rows = {}
    for _, mail in ipairs(mailCache_.mails) do rows[#rows + 1] = MailCard(mail) end
    if #rows == 0 then
        rows[1] = EmptyMessage(mailCache_.loading and "正在读取交易信箱..." or "交易信箱为空")
    end

    return UI.Panel {
        width = "100%", height = "100%", position = "relative",
        children = {
            context_.compactTxt(string.format("市场邮件 %d / %d", mailCache_.count, MarketCatalog.MAILBOX_CAP),
                18, C.textSecondary, {
                    position = "absolute", left = 24, top = 14,
                    width = 300, height = 34,
                }),
            UI.Panel {
                position = "absolute", right = 16, top = 0,
                width = 348, height = 58, flexDirection = "row", gap = 12,
                children = {
                    ImageButton("刷新", context_.ASSETS.ui.inventoryActionBlue,
                        function() LoadMailbox(true) end),
                    ImageButton("一键领取", context_.ASSETS.ui.inventoryActionGold, function()
                        ServerClient.MarketCollect(function(result)
                            if result and result.ok then
                                local summary = result.data and result.data.market
                                    and result.data.market.mailSummary
                                Toast("领取成功", summary
                                    and string.format("金币 +%s，装备 %d 件",
                                        FormatGold(summary.gold), summary.items)
                                    or "已领取")
                            else
                                Toast("领取失败", (result and result.reason) or "请稍后再试")
                            end
                            LoadMailbox(true)
                            Refresh()
                        end)
                    end, game.readOnly or mailCache_.count == 0),
                },
            },
            UI.ScrollView {
                position = "absolute", left = 0, top = 74, right = 0, bottom = 0,
                scrollX = false, scrollY = true, showScrollbar = true,
                children = {
                    UI.Panel {
                        width = 900, flexShrink = 0, gap = 12,
                        marginLeft = 20,
                        paddingBottom = 24, children = rows,
                    },
                },
            },
        },
    }
end

local function BuildAuction(game)
    local subTabs = {}
    for _, tab in ipairs(AUCTION_TABS) do subTabs[#subTabs + 1] = SubTab(tab) end

    local body
    if activeAuctionTab_ == "mine" then body = BuildMyListings(game)
    elseif activeAuctionTab_ == "mail" then body = BuildMailbox(game)
    else body = BuildBrowse(game) end

    return UI.Panel {
        width = "100%", height = "100%", position = "relative",
        children = {
            UI.Panel {
                position = "absolute", left = 190, top = 0,
                width = 520, height = 58,
                flexDirection = "row", gap = 18,
                children = subTabs,
            },
            UI.Panel {
                position = "absolute", right = 16, top = 0,
                width = 64, height = 64,
                children = {
                    RulesButton("交易行规则", "交易行仅允许上架传说及以上、且掉落时获得可交易资格的装备。每件真实掉落装备有2.5%概率获得该资格；锁定、穿戴或援助占用的装备仍无法上架。挂单价格不设上下限。成交时按VIP等级减免手续费，基础手续费为8%，VIP40及以上为0%。购买装备受当前层数+10的等级范围限制。\n\n价格不高于装备标准值10%的挂单，会在每日07:00与20:00（UTC+8）由系统低价扫货；到期挂单会退回交易信箱。", "rules:auction-house"),
                },
            },
            UI.Panel {
                position = "absolute", left = 0, top = 74, right = 0, bottom = 0,
                children = { body },
            },
        },
    }
end

-- 页面根 ---------------------------------------------------------------------

function MarketView.Build(context)
    context_ = context
    local game = context.game
    local tabButtons = {}
    for _, tab in ipairs(TABS) do tabButtons[#tabButtons + 1] = PrimaryTab(tab) end

    local body
    if activeTab_ == "auction" then body = BuildAuction(game)
    elseif activeTab_ == "soon" then body = EmptyMessage("更多市场玩法开发中")
    else body = BlackMarketView.Build(context_) end

    return UI.Panel {
        width = "100%", height = "100%", position = "relative", overflow = "hidden",
        backgroundImage = context.ASSETS.ui.marketBackground,
        backgroundFit = "cover",
        children = {
            UI.Panel {
                position = "absolute", left = 70, top = 8,
                width = 940, height = 158,
                backgroundImage = context.ASSETS.ui.marketTitlePanel,
                backgroundFit = "contain",
                pointerEvents = "none",
                children = {
                    context.txt("深 渊 市 场", 34, context.C.text, {
                        position = "absolute", left = 230, top = 42,
                        width = 480, height = 50, textAlign = "center",
                        textStroke = { width = 3, color = "#000000" },
                    }),
                    context.compactTxt(string.format("VIP%d · 交易手续费 %.1f%%",
                        game.vipLevel or 0, MarketCatalog.GetFeeRate(game.vipLevel) * 100),
                        17, context.C.gold, {
                            position = "absolute", left = 230, top = 94,
                            width = 480, height = 30, textAlign = "center",
                        }),
                },
            },
            UI.Panel {
                position = "absolute", left = 190, top = 130,
                width = 700, height = 72,
                flexDirection = "row", gap = 20,
                justifyContent = "center", children = tabButtons,
            },
            UI.Panel {
                position = "absolute", left = 20, top = 208,
                right = 20, bottom = 18,
                backgroundImage = context.ASSETS.ui.marketMainFrame,
                backgroundFit = "sliced",
                backgroundSlice = { 90, 96, 90, 96 },
                children = {
                    UI.Panel {
                        position = "absolute", left = 50, top = 88,
                        width = 940, bottom = 72,
                        overflow = "hidden",
                        children = { body },
                    },
                },
            },
        },
    }
end

function MarketView.Reset()
    browseCache_ = {
        listings = {}, total = 0, levelCap = nil, nextSweepAt = 0,
        loadedAt = 0, loading = false,
    }
    mailCache_ = { mails = {}, count = 0, loadedAt = 0, loading = false }
end

return MarketView
