local ChangedOnly = require("client.UI.ChangedOnly")
-- Each scene owns its widgets and animation state; tower and trials share this implementation.
local function New()
local PlayEffects = {}
local BigNumber = require("shared.BigNumber")

local context_ = nil
local refs_ = {}
local pickup_ = nil
local pickupQueue_ = {}
local currencyBursts_ = {}
local enemyBursts_ = {}
local playerBursts_ = {}
local floating_ = nil
local lastLootText_ = "等待掉落"
local lastLootIcon_ = nil
local lastLootRarity_ = "gold_green"

local DAMAGE_LABEL_COUNT = 5
local PLAYER_FEEDBACK_COUNT = 5

local function Clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function Colors()
    return context_.colors
end

local function Assets()
    return context_.assets
end

local function DisplayText(text, maxChars)
    if context_.shortenText then return context_.shortenText(text, maxChars or 18) end
    return tostring(text or "")
end

local function StartPickup(options)
    options.text = DisplayText(options.text, 18)
    pickup_ = options
    lastLootText_ = options.text
    lastLootIcon_ = options.image
    lastLootRarity_ = options.rarity or lastLootRarity_
end

local function BeamProfile(rarity)
    local profiles = {
        gold_green = { width = 98, height = 250, glow = 12, pulse = 0.035 },
        common = { width = 94, height = 235, glow = 10, pulse = 0.03 },
        advanced = { width = 106, height = 270, glow = 15, pulse = 0.04 },
        rare = { width = 116, height = 300, glow = 20, pulse = 0.05 },
        artifact = { width = 124, height = 330, glow = 24, pulse = 0.06 },
        legendary = { width = 132, height = 355, glow = 28, pulse = 0.07 },
        epic = { width = 142, height = 390, glow = 34, pulse = 0.08 },
        myth = { width = 152, height = 420, glow = 40, pulse = 0.09 },
    }
    return profiles[rarity or "common"] or profiles.common
end

function PlayEffects.Configure(context)
    context_ = assert(context)
end

function PlayEffects.BuildNodes()
    local UI = context_.UI
    local assets = Assets()
    local lootSize = context_.lootSize
    refs_ = {}
    refs_.lootBeam = UI.Panel {
        position = "absolute", left = 0, top = 0, width = 112, height = 300,
        visible = false, pointerEvents = "none",
        backgroundGradient = { type = "linear", direction = "to-top", from = {255,255,255,230}, to = {255,255,255,0} },
        borderLeftWidth = 2, borderRightWidth = 2,
    }
    refs_.lootGlow = UI.Panel {
        position = "absolute", left = 0, top = 0, width = 132, height = 132,
        visible = false, pointerEvents = "none", borderRadius = 66,
        backgroundColor = {255,255,255,38},
    }
    refs_.pickup = UI.Panel {
        position = "absolute", left = 0, top = 0, width = lootSize, height = lootSize,
        backgroundImage = assets.items.crystal, backgroundFit = "contain", visible = false,
    }
    refs_.currencyBurst = {}
    for index = 1, 12 do
        refs_.currencyBurst[index] = UI.Panel {
            position = "absolute", left = 0, top = 0,
            width = lootSize, height = lootSize,
            backgroundImage = assets.items.gold, backgroundFit = "contain",
            visible = false, pointerEvents = "none",
        }
    end
    refs_.pickupSpark = UI.Panel {
        position = "absolute", left = 0, top = 0, width = 82, height = 82,
        backgroundImage = assets.ui.pickupSpark, backgroundFit = "contain", visible = false,
    }
    refs_.floatLabel = context_.txt("", 30, Colors().gold, {
        position = "absolute", left = 0, top = 0, width = 360,
        textAlign = "center", visible = false,
        textStroke = {width = 2, color = "#000000"},
    })
    refs_.enemyDamageLabels = {}
    for index = 1, DAMAGE_LABEL_COUNT do
        refs_.enemyDamageLabels[index] = context_.txt("", 34, Colors().hp, {
            position = "absolute", left = 0, top = 0, width = 360,
            textAlign = "center", visible = false,
            textStroke = {width = 3, color = "#000000"},
        })
    end
    refs_.playerFeedbackLabels = {}
    for index = 1, PLAYER_FEEDBACK_COUNT do
        refs_.playerFeedbackLabels[index] = context_.txt("", 32, Colors().hp, {
            position = "absolute", left = 0, top = 0, width = 360,
            textAlign = "center", visible = false,
            textStroke = {width = 3, color = "#000000"},
        })
    end
    local nodes = { refs_.lootBeam, refs_.lootGlow, refs_.pickup }
    for _, node in ipairs(refs_.currencyBurst) do nodes[#nodes + 1] = node end
    nodes[#nodes + 1] = refs_.pickupSpark
    nodes[#nodes + 1] = refs_.floatLabel
    for _, node in ipairs(refs_.enemyDamageLabels) do nodes[#nodes + 1] = node end
    for _, node in ipairs(refs_.playerFeedbackLabels) do nodes[#nodes + 1] = node end
    return nodes
end

function PlayEffects.ShouldRender(seen, group, value)
    local key
    if value.eventId ~= nil then
        key = group .. ":event:" .. tostring(value.eventId)
    else
        local serial = value.attackSerial or value.sequenceSerial or value.monsterAttackSerial
        local hitIndex = value.hitIndex or value.sequenceHitIndex
        local amount = value.amountBig or value.damageBig or value.amount or value.damage
        local remainingHp = value.targetHpBig or value.monsterHpBig or value.hpBig
            or value.playerHpBig or value.targetHp or value.monsterHp or value.hp or value.playerHp
        if serial ~= nil or hitIndex ~= nil or amount ~= nil or remainingHp ~= nil then
            local function MagnitudeKey(magnitude)
                if type(magnitude) == "table"
                    and (magnitude.mantissa ~= nil or magnitude.exponent ~= nil)
                then
                    return BigNumber.ToScientificString(magnitude, 12)
                end
                return tostring(magnitude or "")
            end
            key = table.concat({
                group,
                tostring(serial or ""),
                tostring(hitIndex or ""),
                MagnitudeKey(amount),
                MagnitudeKey(remainingHp),
                tostring(value.source or ""),
            }, ":")
        end
    end
    if key == nil then return true end
    if seen[key] then return false end
    seen[key] = true
    return true
end

function PlayEffects.TriggerPickup(options)
    options = options or {}
    options.age = 0
    options.duration = options.duration or 1.35
    options.image = options.image or Assets().items.crystal
    options.text = options.text or "获得道具"
    options.rarity = options.rarity or "common"
    if pickup_ then
        if #pickupQueue_ < 32 then pickupQueue_[#pickupQueue_ + 1] = options end
    else StartPickup(options) end
end

function PlayEffects.SettleLoot(sourceId, outcome)
    sourceId = tostring(sourceId or "")
    if pickup_ and pickup_.sourceId == sourceId then
        pickup_.outcome = outcome
    else
        for _, queued in ipairs(pickupQueue_) do
            if queued.sourceId == sourceId then queued.outcome = outcome; break end
        end
    end
    if outcome == "temporary_box" or outcome == "temporary_loot" then
        lastLootText_ = "已进入临时战利品箱"
    end
end

function PlayEffects.SetCurrencyBursts(bursts)
    currencyBursts_ = bursts or {}
end

function PlayEffects.AddPlayerFeedback(text, color, source)
    if #playerBursts_ >= PLAYER_FEEDBACK_COUNT then table.remove(playerBursts_, 1) end
    playerBursts_[#playerBursts_ + 1] = {
        age = 0, text = text, color = color, source = source,
        lane = (#playerBursts_ % PLAYER_FEEDBACK_COUNT),
    }
end

function PlayEffects.AddEnemyDamage(text, baseX, baseY, delay, variant)
    if #enemyBursts_ >= DAMAGE_LABEL_COUNT then table.remove(enemyBursts_, 1) end
    enemyBursts_[#enemyBursts_ + 1] = {
        age = -(delay or 0), text = text or "命中", baseX = baseX,
        baseY = baseY, variant = variant or 1,
    }
end

function PlayEffects.ShowFloating(text, baseX, baseY, burst)
    floating_ = {
        age = 0, text = burst and (text or "暴击") or "命中",
        baseX = baseX, baseY = baseY,
    }
end

function PlayEffects.SetLootDisplay(text, icon, rarity)
    if text ~= nil then lastLootText_ = DisplayText(text, 18) end
    if icon ~= nil then lastLootIcon_ = icon end
    if rarity ~= nil then lastLootRarity_ = rarity end
end

function PlayEffects.GetLootDisplay()
    return lastLootText_, lastLootIcon_, lastLootRarity_
end

--- 是否仍在播放掉落/拾取表现（含队列与金币散射）。
--- 仅统计“还在飞”的对象，过期残留不计入，避免引导永久等待。
function PlayEffects.IsLootPresentationActive()
    if pickup_ ~= nil then return true end
    if #pickupQueue_ > 0 then return true end
    for _, burst in pairs(currencyBursts_ or {}) do
        if type(burst) == "table" then
            local age = tonumber(burst.age) or 0
            -- 金币散射完整动画约 1.18s；超过则视为已结束。
            if age < 1.25 then
                return true
            end
        end
    end
    return false
end

function PlayEffects.Update(dt, frame)
    if not refs_.pickup then return end
    local assets = Assets()
    local lootSize = context_.lootSize
    local metrics = frame.metrics

    for index, node in ipairs(refs_.currencyBurst) do
        local burst = currencyBursts_[index]
        if burst then
            burst.age = burst.age + dt
            if burst.age >= 0 and not burst.soundPlayed then
                burst.soundPlayed = true
                if context_.playFeedback then context_.playFeedback("lootDrop") end
            end
            if burst.age < 0 then
                ChangedOnly.Style(node, { visible = false })
            elseif burst.age < 0.38 then
                local t = Clamp(burst.age / 0.38, 0, 1)
                local ease = 1 - (1 - t) * (1 - t)
                ChangedOnly.Style(node, {
                    visible = true,
                    left = burst.startX + (burst.scatterX - burst.startX) * ease,
                    top = burst.startY + (burst.scatterY - burst.startY) * ease - math.sin(t * math.pi) * 72,
                    opacity = 1, scale = 0.72 + t * 0.38, backgroundImage = assets.items.gold,
                })
            elseif burst.age < 1.18 then
                local hover = math.sin((burst.age - 0.38) * 10 + index) * 4
                ChangedOnly.Style(node, {
                    visible = true, left = burst.scatterX, top = burst.scatterY + hover,
                    opacity = 1, scale = 1.05 + math.sin(burst.age * 8 + index) * 0.05,
                    backgroundImage = assets.items.gold,
                    boxShadow = { { x = 0, y = 0, blur = 18, color = {255, 220, 70, 165} } },
                })
            elseif burst.age < 1.68 then
                local t = Clamp((burst.age - 1.18) / 0.50, 0, 1)
                local ease = t * t
                local targetX = frame.playerScreenX + frame.playerSize * 0.45
                local targetY = frame.roadY - frame.playerSize * 0.50
                ChangedOnly.Style(node, {
                    visible = t < 1,
                    left = burst.scatterX + (targetX - burst.scatterX) * ease,
                    top = burst.scatterY + (targetY - burst.scatterY) * ease - math.sin(t * math.pi) * 54,
                    opacity = 1 - t * 0.3, scale = 1.0 - t * 0.55,
                    backgroundImage = assets.items.gold,
                })
            else
                ChangedOnly.Style(node, { visible = false })
                currencyBursts_[index] = nil
            end
        else
            ChangedOnly.Style(node, { visible = false })
        end
    end

    if pickup_ then
        pickup_.age = pickup_.age + dt
        local rarityInfo = context_.rarities and (context_.rarities[pickup_.rarity] or context_.rarities.common) or nil
        local beamColor = rarityInfo and (rarityInfo.beam or rarityInfo.color) or {220, 235, 255, 240}
        if rarityInfo and rarityInfo.dynamic then
            local phase = pickup_.age * 5.5
            beamColor = {
                math.floor(128 + 127 * math.sin(phase)),
                math.floor(128 + 127 * math.sin(phase + 2.094)),
                math.floor(128 + 127 * math.sin(phase + 4.188)), 250,
            }
        end
        local profile = BeamProfile(pickup_.rarity)
        local beamEnd, hoverEnd = 0.52, 0.82
        local temporary = pickup_.outcome == "temporary_box" or pickup_.outcome == "temporary_loot"
        local endX = temporary and 62 or 58
        local endY = temporary and (metrics.height - 56) or (metrics.height - 50)
        if pickup_.age <= hoverEnd then
            local hover = math.sin(pickup_.age * 15) * 5
            ChangedOnly.Style(refs_.pickup, {
                visible = true, left = pickup_.startX, top = pickup_.startY + hover,
                width = lootSize, height = lootSize, backgroundImage = pickup_.image,
                opacity = 1, scale = 1.04 + math.sin(pickup_.age * 10) * profile.pulse,
            })
            local opacity = pickup_.age <= beamEnd and (0.68 + math.sin(pickup_.age * 18) * 0.12)
                or Clamp(1 - (pickup_.age - beamEnd) / (hoverEnd - beamEnd), 0, 1)
            local beamLeft = pickup_.startX + lootSize * 0.5 - profile.width * 0.5
            local glowSize = lootSize + profile.glow * 2
            ChangedOnly.Style(refs_.lootBeam, {
                visible = opacity > 0, left = beamLeft,
                top = pickup_.startY + lootSize - profile.height,
                width = profile.width, height = profile.height, opacity = opacity,
                scale = 0.98 + math.sin(pickup_.age * 14) * profile.pulse,
                borderLeftColor = {beamColor[1], beamColor[2], beamColor[3], 150},
                borderRightColor = {beamColor[1], beamColor[2], beamColor[3], 150},
                backgroundGradient = {
                    type = "linear", direction = "to-top",
                    from = {beamColor[1], beamColor[2], beamColor[3], 235},
                    to = {beamColor[1], beamColor[2], beamColor[3], 0},
                },
            })
            ChangedOnly.Style(refs_.lootGlow, {
                visible = opacity > 0, left = pickup_.startX - profile.glow,
                top = pickup_.startY - profile.glow + hover, width = glowSize, height = glowSize,
                borderRadius = glowSize * 0.5, opacity = opacity * 0.82,
                backgroundColor = {beamColor[1], beamColor[2], beamColor[3], 62},
                boxShadow = { { x = 0, y = 0, blur = profile.glow, color = {beamColor[1], beamColor[2], beamColor[3], 135} } },
            })
            ChangedOnly.Style(refs_.pickupSpark, {visible = false})
        else
            local t = Clamp((pickup_.age - hoverEnd) / math.max(0.01, pickup_.duration - hoverEnd), 0, 1)
            local ease = 1 - (1 - t) * (1 - t)
            local x = pickup_.startX + (endX - pickup_.startX) * ease
            local y = pickup_.startY + (endY - pickup_.startY) * ease - math.sin(t * math.pi) * 76
            local size = lootSize * (1.0 - 0.62 * ease)
            ChangedOnly.Style(refs_.lootBeam, {visible = false})
            ChangedOnly.Style(refs_.lootGlow, {visible = false})
            ChangedOnly.Style(refs_.pickup, {
                visible = t < 1, left = x, top = y, width = size, height = size,
                backgroundImage = pickup_.image, opacity = 1.0 - t * 0.12,
                scale = 1.0 + math.sin(t * math.pi) * 0.22,
            })
            ChangedOnly.Style(refs_.pickupSpark, {
                visible = t > 0.72 and t < 1 and endY < metrics.height,
                left = endX - 10, top = endY - 10,
                opacity = (1 - t) * 2.0, scale = 0.7 + t * 0.8,
            })
            if t >= 1 then
                pickup_ = nil
                if #pickupQueue_ > 0 then StartPickup(table.remove(pickupQueue_, 1)) end
            end
        end
    else
        ChangedOnly.Style(refs_.lootBeam, {visible = false})
        ChangedOnly.Style(refs_.lootGlow, {visible = false})
        ChangedOnly.Style(refs_.pickup, {visible = false})
        ChangedOnly.Style(refs_.pickupSpark, {visible = false})
    end

    for index = #enemyBursts_, 1, -1 do
        local burst = enemyBursts_[index]
        burst.age = burst.age + dt
        if burst.age >= 1.05 then table.remove(enemyBursts_, index) end
    end
    for index, label in ipairs(refs_.enemyDamageLabels) do
        local burst = enemyBursts_[index]
        if burst and burst.age >= 0 then
            local age = burst.age
            ChangedOnly.Text(label, burst.text)
            ChangedOnly.Style(label, {
                visible = age < 0.95,
                left = burst.baseX + math.sin(age * 22.0 + (burst.variant or 1)) * 7,
                top = burst.baseY - age * (78 + (burst.variant or 1) * 4),
                fontColor = {255, 83, 93, math.floor(255 * math.max(0, 1 - age / 0.95))},
                scale = 1.0 + math.max(0, 1 - age * 4.0) * 0.42,
            })
        else ChangedOnly.Style(label, {visible = false}) end
    end

    for index = #playerBursts_, 1, -1 do
        local burst = playerBursts_[index]
        burst.age = burst.age + dt
        if burst.age >= 1.25 then table.remove(playerBursts_, index) end
    end
    for index, label in ipairs(refs_.playerFeedbackLabels) do
        local burst = playerBursts_[index]
        if burst then
            local age = burst.age
            local color = burst.color or Colors().hp
            ChangedOnly.Text(label, burst.text)
            ChangedOnly.Style(label, {
                visible = age < 1.15,
                left = metrics.playerAnchorX - 180 + (burst.lane or 0) * 8,
                top = frame.platformPlayerY - 42 - age * 82 - (burst.lane or 0) * 13,
                fontColor = {color[1], color[2], color[3], math.floor(255 * math.max(0, 1 - age / 1.15))},
                scale = burst.source == "revive" and (1.18 + math.sin(age * 9) * 0.08)
                    or (1.0 + math.max(0, 1 - age * 5) * 0.25),
            })
        else ChangedOnly.Style(label, {visible = false}) end
    end

    if floating_ then
        floating_.age = floating_.age + dt
        ChangedOnly.Text(refs_.floatLabel, floating_.text)
        ChangedOnly.Style(refs_.floatLabel, {
            visible = floating_.age < 1.0, left = floating_.baseX,
            top = floating_.baseY - floating_.age * 70,
            fontColor = {255, 217, 61, math.floor(255 * math.max(0, 1 - floating_.age))},
        })
        if floating_.age >= 1.0 then floating_ = nil end
    else ChangedOnly.Style(refs_.floatLabel, {visible = false}) end
end

function PlayEffects.ResetCombatFeedback()
    enemyBursts_ = {}
    playerBursts_ = {}
    floating_ = nil
end

function PlayEffects.Reset()
    refs_ = {}
    pickup_ = nil
    pickupQueue_ = {}
    currencyBursts_ = {}
    enemyBursts_ = {}
    playerBursts_ = {}
    floating_ = nil
    lastLootText_ = "等待掉落"
    lastLootIcon_ = nil
    lastLootRarity_ = "gold_green"
end

return PlayEffects
end

local default = New()
default.New = New
return default
