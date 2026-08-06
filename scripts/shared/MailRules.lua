-- MailRules.lua
-- 邮件系统共享常量与规则（服务端权威，客户端只读展示）。
-- 邮件系统 = 系统通知/活动奖励/运营补偿/任务补发的统一“通知留痕 + 奖励补领”渠道。

local MailRules = {}

MailRules.CAPACITY = 100          -- 普通邮箱容量
MailRules.CACHE_CAPACITY = 200    -- 缓存队列容量
MailRules.MAX_BODY = 600          -- 正文最大长度
MailRules.MAX_TITLE = 40          -- 标题最大长度
MailRules.MAX_ATTACHMENTS = 6     -- 单封邮件附件上限
MailRules.MAX_MAIL_ID_LEN = 64

-- 建议有效期（天），按邮件类型
MailRules.EXPIRY_DAYS = {
    notice = 7,    -- 系统通知
    reward = 30,   -- 奖励邮件
    task = 30,     -- 任务结果
    ops = 30,      -- 运营定向
    special = 365, -- 系统特殊
}

MailRules.TYPES = {
    notice = true,
    reward = true,
    task = true,
    ops = true,
    special = true,
}

-- 未领取附件过期后的处理策略
MailRules.OVERDUE_POLICIES = {
    Discard = true,       -- 直接回收（普通活动奖励默认）
    AutoSettle = true,    -- 自动入账（必须到账的补偿）
    Reissue = true,       -- 生成补发邮件
    ManualReview = true,  -- 进入异常记录
}

-- 过期后保留时长（天），供玩家查看过期结果
MailRules.RETENTION_DAYS = 3
-- 收藏邮件过期后额外保留
MailRules.FAVORITE_RETENTION_DAYS = 7

MailRules.SENDER_DEFAULT = "无尽深渊"

-- 附件领取失败原因（服务端返回，客户端展示）
MailRules.CLAIM_ERRORS = {
    INVENTORY_FULL = "背包空间不足",
    HOLD_LIMIT = "道具已达持有上限",
    REWARD_INVALID = "奖励配置失效",
    MAIL_EXPIRED = "邮件已过期",
    ALREADY_CLAIMED = "邮件已领取",
    NETWORK_ERROR = "网络或服务异常",
    ACCOUNT_BLOCKED = "账号状态不允许领取",
}

MailRules.ATTACH_KINDS = {
    currency = true,
    equipment = true,
}

-- 补位优先级：高价值补偿 > 限时奖励 > 任务补发 > 普通奖励 > 系统通知
MailRules.REFILL_PRIORITY = {
    special = 0,
    reward = 1,
    task = 2,
    ops = 3,
    notice = 4,
}

--- 默认有效期（秒），special 使用最大可配置值
function MailRules.DefaultExpireSeconds(mailType, now)
    local days = MailRules.EXPIRY_DAYS[mailType] or 30
    return (now or os.time()) + days * 24 * 3600
end

--- 过期保留时长（秒）
function MailRules.RetentionSeconds(now)
    return MailRules.RETENTION_DAYS * 24 * 3600
end

--- 校验邮件类型
function MailRules.NormalizeType(value)
    if MailRules.TYPES[value] then return value end
    return "notice"
end

--- 校验过期策略
function MailRules.NormalizePolicy(value)
    if MailRules.OVERDUE_POLICIES[value] then return value end
    return "Discard"
end

return MailRules
