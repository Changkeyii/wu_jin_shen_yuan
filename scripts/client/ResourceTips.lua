local Common = require("client.CommonPromptDialog")
local Kit = require("client.ViewKit")
local D = require("shared.AdGiftDefinitions")
local M = {}

-- Reuse CommonPromptDialog: overlay -> frame/title -> scrolling text -> footer/settings.
-- dialog_frame.png: canvas 766x386, outer (16,2)-(765,382), body (34,66)-(746,302).
-- Nine-slice {72,42,92,42}; 900x760 dialog; body x60/y104/w780/h512,
-- inner horizontal padding 24. Text wraps inside the existing scroll viewport.
local specs = {
    gold = { title = "金币", use = "用途：装备强化等养成操作。", source = "获取：登塔战斗、离线收益、任务、签到及补给礼包。" },
    fragments = { title = "装备碎片", use = "用途：装备强化与升星等养成操作。", source = "获取：分解装备、离线收益、任务及补给礼包。" },
    floor = { title = "登塔层数", use = "击败本层守层首领后进入下一层；楼层越高，敌人与基础掉落越强。", source = "首次通关每10层可解锁一次幸运礼包，重复挑战旧层不重复解锁。" },
    level = { title = "角色等级", use = "经验达到升级要求后自动提升等级，增强角色基础能力。", source = "获取经验：战斗、离线收益及任务奖励。" },
    wish_ticket = { title = "许愿券", use = "用途：许愿池单抽消耗1张，十连消耗8张；可获得装备罐或角色。", source = D.WISH_SOURCES },
}
function M.Show(kind, game)
    local spec = specs[kind]
    if not spec then return false end
    game = game or require("client.GameStateAdapter").GetViewState() or {}
    local amount = kind == "wish_ticket" and (game.wishPool and game.wishPool.tickets or 0) or game[kind] or 0
    return Common.Show {
        queueKey = "resource_tip", title = spec.title, dialogWidth = 900, dialogHeight = 760,
        message = (kind == "floor" or kind == "level") and ("当前：" .. Kit.FormatInt(amount)) or ("持有：" .. Kit.FormatInt(amount)),
        lines = { spec.use, spec.source }, textAlign = "left", showClose = true,
        confirmText = kind == "wish_ticket" and "前往获取" or "知道了",
        cancelText = kind == "wish_ticket" and "关闭" or nil,
        onConfirm = kind == "wish_ticket" and function() require("client.AdGiftController").Open() end or nil,
    }
end
return M
