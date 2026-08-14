local WishPoolDefinitions = require("shared.WishPoolDefinitions")
local PlayerTransition = require("server.domain.PlayerTransition")
local RewardEngine = require("server.domain.RewardEngine")
local DomainMath = require("server.domain.DomainMath")
local TableUtils = require("server.domain.TableUtils")

local WishPoolEngine = {}

-- 许愿/开罐操作冷却（秒）：动画结算期间服务端拒绝重复操作，防止连点双发。
-- 动画整体约 3.7s，但客户端全屏遮罩已拦截动画期间点击；冷却只需兜底“请求在途/跨页”双发，取 2s。
local WISH_COOLDOWN_SECONDS = 2

-- 返回剩余冷却秒数；冷却中返回 nil。
local function wishCooldownRemaining(wishPool, now)
    local lastActionAt = tonumber(wishPool.lastWishAt) or 0
    if lastActionAt <= 0 then return nil end
    local remaining = lastActionAt + WISH_COOLDOWN_SECONDS - now
    if remaining > 0 then return remaining end
    return nil
end

local function touchWishAction(wishPool, now)
    wishPool.lastWishAt = now
end

local function randomInt(rng, minimum, maximum)
    return DomainMath.RandomInt(rng, minimum, maximum)
end

local function weightedPick(entries, rng)
    local total = 0
    for _, entry in ipairs(entries) do total = total + math.max(0, entry.weight or 0) end
    if total <= 0 then return nil end
    local roll = randomInt(rng, 1, total)
    local accumulated = 0
    for _, entry in ipairs(entries) do
        accumulated = accumulated + math.max(0, entry.weight or 0)
        if roll <= accumulated then return entry end
    end
    return entries[#entries]
end

local function pickCharacter(wishPool, rng)
    local locked = {}
    for _, characterId in ipairs(WishPoolDefinitions.CHARACTER_ORDER) do
        if wishPool.ownedCharacters[characterId] ~= true then locked[#locked + 1] = characterId end
    end
    local pool = #locked > 0 and locked or WishPoolDefinitions.CHARACTER_ORDER
    return pool[randomInt(rng, 1, #pool)]
end

local function makeDrawReward(wishPool, rng)
    local forcedCharacter = wishPool.characterPity + 1 >= WishPoolDefinitions.CHARACTER_HARD_PITY
    local forcedMyth = wishPool.mythPity + 1 >= WishPoolDefinitions.MYTH_HARD_PITY
    local entry
    if forcedCharacter then
        entry = { kind = "character" }
    elseif forcedMyth then
        local nextGuarantee = wishPool.mythGuarantees + 1
        entry = nextGuarantee % 3 == 0
            and { kind = "combo", rarity = "myth" }
            or { kind = "rarity", rarity = "myth" }
    else
        entry = weightedPick(WishPoolDefinitions.DRAW_WEIGHTS, rng)
    end

    if entry.kind == "character" then
        return {
            kind = "character",
            characterId = pickCharacter(wishPool, rng),
            forced = forcedCharacter,
        }
    end

    local rarity = entry.rarity
    local slot = nil
    if entry.kind == "slot" or entry.kind == "combo" then
        slot = WishPoolDefinitions.RandomSlot(function(minimum, maximum)
            return randomInt(rng, minimum, maximum)
        end)
    end
    local jarId = WishPoolDefinitions.MakeJarId(entry.kind, rarity, slot)
    return {
        kind = "jar",
        jarKind = entry.kind,
        jarId = jarId,
        rarity = rarity,
        slot = slot,
        forced = forcedMyth,
    }
end

local function updatePity(wishPool, reward)
    wishPool.totalWishes = wishPool.totalWishes + 1
    if reward.kind == "character" then
        wishPool.characterPity = 0
    else
        wishPool.characterPity = math.min(
            WishPoolDefinitions.CHARACTER_HARD_PITY - 1,
            wishPool.characterPity + 1
        )
    end

    local explicitMyth = reward.kind == "jar" and reward.rarity == "myth"
    if explicitMyth then
        wishPool.mythPity = 0
        wishPool.mythGuarantees = wishPool.mythGuarantees + 1
    else
        wishPool.mythPity = math.min(
            WishPoolDefinitions.MYTH_HARD_PITY - 1,
            wishPool.mythPity + 1
        )
    end
end

local function grantReward(wishPool, reward, events)
    if reward.kind == "jar" then
        wishPool.jars[reward.jarId] = (wishPool.jars[reward.jarId] or 0) + 1
        local jar = WishPoolDefinitions.ResolveJar(reward.jarId)
        events[#events + 1] = PlayerTransition.Event("wish_jar_granted", {
            jarId = reward.jarId,
            jarKind = reward.jarKind,
            jarName = jar and jar.name or "装备罐",
            rarity = reward.rarity,
            slot = reward.slot,
            quantity = 1,
        })
        return
    end

    local characterId = reward.characterId
    local character = WishPoolDefinitions.CHARACTERS[characterId]
    if wishPool.ownedCharacters[characterId] == true then
        local marks = WishPoolDefinitions.CHARACTER_MARKS_PER_DUPLICATE
        wishPool.characterMarks[characterId] = (wishPool.characterMarks[characterId] or 0) + marks
        events[#events + 1] = PlayerTransition.Event("wish_character_duplicate", {
            characterId = characterId,
            characterName = character and character.name or characterId,
            marks = marks,
        })
    else
        wishPool.ownedCharacters[characterId] = true
        events[#events + 1] = PlayerTransition.Event("wish_character_unlocked", {
            characterId = characterId,
            characterName = character and character.name or characterId,
        })
    end
end

-- payment 仅支持 ticket；count=1 扣 1 券，count=10 扣 8 券。
function WishPoolEngine.Wish(inputState, payment, now, rng, count)
    if payment ~= "ticket" then
        return PlayerTransition.Failure(inputState, now, "INVALID_ARGUMENT", "仅支持许愿券许愿")
    end
    local drawCount, ticketCost = WishPoolDefinitions.ResolveDrawPlan(count)
    local working = PlayerTransition.Copy(inputState, now)
    local wishPool = working.wishPool
    local cooldown = wishCooldownRemaining(wishPool, now)
    if cooldown then
        return PlayerTransition.Failure(inputState, now, "WISH_COOLDOWN", "许愿结算中，请稍候")
    end

    if (wishPool.tickets or 0) < ticketCost then
        return PlayerTransition.Failure(inputState, now, "WISH_TICKET_REQUIRED", "许愿券不足")
    end
    wishPool.tickets = wishPool.tickets - ticketCost

    local events = {}
    local draws = {}
    local showcase = nil
    for drawIndex = 1, drawCount do
        local reward = makeDrawReward(wishPool, rng)
        updatePity(wishPool, reward)
        grantReward(wishPool, reward, events)

        local candidates = WishPoolDefinitions.CellCandidates(
            reward.kind == "character" and "character" or reward.jarKind,
            reward.rarity
        )
        local stopCell = candidates[randomInt(rng, 1, #candidates)]
        local draw = {
            index = drawIndex,
            rewardKind = reward.kind,
            jarId = reward.jarId,
            jarKind = reward.jarKind,
            rarity = reward.rarity,
            slot = reward.slot,
            characterId = reward.characterId,
            stopCell = stopCell,
            forced = reward.forced == true,
        }
        draws[#draws + 1] = draw

        -- 十连展示优先：角色 > 神话 > 史诗 > 传说 > 其他；同级取最后一次。
        local rank = 1
        if reward.kind == "character" then
            rank = 5
        elseif reward.rarity == "myth" then
            rank = 4
        elseif reward.rarity == "epic" then
            rank = 3
        elseif reward.rarity == "legendary" then
            rank = 2
        end
        if not showcase or rank >= (showcase.rank or 0) then
            showcase = {
                rank = rank,
                rewardKind = reward.kind,
                jarId = reward.jarId,
                jarKind = reward.jarKind,
                rarity = reward.rarity,
                slot = reward.slot,
                characterId = reward.characterId,
                stopCell = stopCell,
                forced = reward.forced == true,
            }
        end
    end

    showcase = showcase or draws[#draws]
    events[#events + 1] = PlayerTransition.Event("wish_drawn", {
        payment = "ticket",
        count = drawCount,
        ticketCost = ticketCost,
        tickets = wishPool.tickets,
        totalWishes = wishPool.totalWishes,
        mythPity = wishPool.mythPity,
        characterPity = wishPool.characterPity,
        -- 兼容旧客户端单抽字段：取十连中的展示奖励。
        rewardKind = showcase.rewardKind,
        jarId = showcase.jarId,
        jarKind = showcase.jarKind,
        rarity = showcase.rarity,
        slot = showcase.slot,
        characterId = showcase.characterId,
        stopCell = showcase.stopCell,
        forced = showcase.forced == true,
        draws = draws,
    })

    print(string.format(
        "[WishPool] payment=ticket count=%d cost=%d total=%d showcase=%s stop=%d",
        drawCount,
        ticketCost,
        wishPool.totalWishes,
        tostring(showcase.jarId or showcase.characterId),
        showcase.stopCell or 0
    ))
    touchWishAction(wishPool, now)
    return PlayerTransition.Finalize(inputState, working, now, "wish_drawn", events, false, false)
end

local function rollOpenRarity(jar, rng)
    if jar.rarity then return jar.rarity end
    local result = weightedPick(WishPoolDefinitions.OPEN_RARITY_WEIGHTS, rng)
    return result and result.rarity or "legendary"
end

function WishPoolEngine.OpenJar(inputState, jarId, now, rng, openCount)
    local jar = WishPoolDefinitions.ResolveJar(jarId)
    if not jar then
        return PlayerTransition.Failure(inputState, now, "INVALID_WISH_JAR", "未知装备罐")
    end
    openCount = math.max(1, math.min(6, math.floor(tonumber(openCount) or 1)))
    local working = PlayerTransition.Copy(inputState, now)
    local cooldown = wishCooldownRemaining(working.wishPool, now)
    if cooldown then
        return PlayerTransition.Failure(inputState, now, "WISH_COOLDOWN", "结算中，请稍候")
    end
    local count = working.wishPool.jars[jarId] or 0
    if count < openCount then
        return PlayerTransition.Failure(inputState, now, "WISH_JAR_REQUIRED", "该装备罐数量不足")
    end

    working.wishPool.jars[jarId] = count - openCount
    if working.wishPool.jars[jarId] <= 0 then working.wishPool.jars[jarId] = nil end

    -- 批量开罐：每只罐子一行，最多同时开 6 只；任意一只失败则整批原子回滚。
    local lanes = {}
    local events = {}
    local floor = math.max(1, TableUtils.ToInteger(working.maxFloor, working.floor))
    for lane = 1, openCount do
        local rarity = rollOpenRarity(jar, rng)
        local slot = jar.slot or WishPoolDefinitions.RandomSlot(function(minimum, maximum)
            return randomInt(rng, minimum, maximum)
        end)
        local added, item = RewardEngine.AddGeneratedDrop(
            working,
            rarity,
            false,
            rng,
            now,
            "wish_jar",
            events,
            {
                slot = slot,
                floor = floor,
                trackInLootStash = false,
                requireInventory = true,
                rollTradeable = false,
            }
        )
        if not added or not item then
            return PlayerTransition.Failure(inputState, now, "INVENTORY_FULL", "背包已满，请先清理装备")
        end
        lanes[lane] = {
            lane = lane,
            itemId = item.id,
            equipmentId = item.equipmentId,
            itemName = item.name,
            rarity = item.rarity,
            slot = item.slot,
            level = item.level,
        }
    end

    events[#events + 1] = PlayerTransition.Event("wish_jar_opened", {
        jarId = jarId,
        jarName = jar.name,
        laneCount = openCount,
        lanes = lanes,
    })
    print(string.format(
        "[WishPool] jars opened=%d id=%s",
        openCount,
        jarId
    ))
    touchWishAction(working.wishPool, now)
    return PlayerTransition.Finalize(inputState, working, now, "wish_jar_opened", events, true, false)
end

return WishPoolEngine
