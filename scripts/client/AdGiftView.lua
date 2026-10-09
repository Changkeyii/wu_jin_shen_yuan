local UI = require("urhox-libs/UI")
local Common = require("client.CommonPromptDialog")
local Rewards = require("client.RewardDialogView")
local Kit = require("client.ViewKit")
local Assets = require("client.ViewAssets").ASSETS
local Theme = require("client.Theme")
local LargeNumber = require("shared.LargeNumber")
local D = require("shared.AdGiftDefinitions")
local M = {}

-- 复用通用弹窗边界合同：766x386 素材外框(16,2)-(765,382)，内框(34,66)-(746,302)。
-- CommonPromptDialog sliced={72,42,92,42}；900x950 容器，正文 x=60,w=780，
-- 正文再内缩24，实际内容宽732；正文 y=104,h=702，底部按钮 y=854,h=82。
-- 层级：通用遮罩/外框 -> 标题/可滚动正文 -> 礼包行；奖励使用现有180x180物品卡。
function M.Menu(offers, onSelect, progress)
    progress = progress or {}
    local rows = {}
    for _, kind in ipairs(D.ORDER) do
        local id, spec = kind, D.KINDS[kind]
        local hint = offers[id] and (id == "forge" and "常驻补给 · 自愿观看" or "事件补给 · 每笔限领一次") or spec.hint
        if id == "wishSupply" then
            hint = string.format("今日已领 %d/4 次 · %s", progress.wishUsed or 0,
                offers[id] and ("本次 " .. offers[id].tickets .. " 张") or "今日已领完")
        elseif id == "lucky" then
            hint = string.format("可领 %d 次 · 每次广告 2 张", progress.luckyCount or 0)
        end
        rows[#rows + 1] = UI.Panel {
            width = "100%", height = 84, flexShrink = 0, flexDirection = "row", alignItems = "center", gap = 12,
            children = {
                UI.Panel { flexGrow = 1, flexBasis = 0, gap = 4, children = {
                    Kit.CompactTxt(spec.title, 23, Theme.Colors.text, { width = "100%", height = 30 }),
                    Kit.CompactTxt(hint, 16, Theme.Colors.textSecondary,
                        { width = "100%", height = 26 }),
                } },
                Kit.ImageButton(offers[id] and "查看礼包" or (id == "wishSupply" and "今日已领完" or "未解锁"), 180, 62,
                    Assets.ui.inventoryActionGold, function() Common.Close(); onSelect(id) end, not offers[id]),
            },
        }
    end
    return Common.Show { queueKey = "ad_gift_menu", title = "塔灵的馈赠", kind = "equipment",
        dialogWidth = 900, dialogHeight = 950, closeOnOverlay = false, showClose = true,
        confirmText = "关闭", content = UI.Panel { width = "100%", gap = 8, children = rows } }
end
function M.Pending(message)
    return Common.Show { queueKey = "ad_gift_pending", priority = 325,
        zIndex = require("client.UI.UILayout").Z.reward, title = "塔灵礼包",
        message = message, lines = { "可关闭窗口继续游戏，奖励由服务器确认后到账。" },
        showClose = true, showConfirm = false, closeOnOverlay = false }
end
function M.Reward(quote, options)
    options = options or {}
    local cards, reward = {}, quote.reward
    if not LargeNumber.IsZero(reward.gold) then
        Rewards.AddCard(cards, Assets.items.gold, "金币", "+" .. Kit.FormatInt(reward.gold), "epic")
    end
    if reward.fragments > 0 then
        Rewards.AddCard(cards, Assets.items.crystal, "装备碎片", "+" .. Kit.FormatInt(reward.fragments), "rare")
    end
    if reward.jars > 0 then
        Rewards.AddCard(cards, "image/wishpool_jar_random_20260812130256.png", "全随机罐", "+" .. reward.jars, "epic")
    end
    if reward.boosts > 0 then
        Rewards.AddCard(cards, Assets.items.crystal, "首领攻防助力", "+" .. reward.boosts .. "次", "epic")
    end
    if (reward.tickets or 0) > 0 then
        Rewards.AddCard(cards, require("shared.WishPoolDefinitions").ICONS.ticket, "许愿券", "+" .. reward.tickets, "legendary")
    end
    local lines = { D.KINDS[quote.kind].detail }
    if (quote.ruleVersion or 1) < D.REWARD_RULE_VERSION and quote.kind ~= "retry" then
        lines = { "此礼包包含更新前保留的奖励，按上方已锁定数量发放。" }
    end
    if quote.benefit and quote.benefit ~= "" then
        lines[#lines + 1] = quote.benefit
    elseif quote.kind == "recycle" then
        lines[#lines + 1] = "补回的碎片可继续强化、升星装备，强化投入返还不参与加成。"
    elseif quote.kind == "boss" or quote.kind == "offline" or quote.kind == "journey" then
        lines[#lines + 1] = "补给可用于装备强化、升星；多笔未领奖励会合并，上方卡片为本次实际到账数量。"
    end
    lines[#lines + 1] = "自愿观看，关闭不消耗领取机会；本礼包不参与五倍加成。"
    return Rewards.Show { queueKey = "ad_gift_dialog", title = D.KINDS[quote.kind].title,
        cards = cards, message = options.message or "完整观看后领取以下奖励",
        lines = options.lines or lines,
        confirmText = options.confirmText or "看广告领取", cancelText = options.cancelText or "暂时不用",
        showClose = true, onConfirm = options.onConfirm, onCancel = options.onCancel }
end
return M
