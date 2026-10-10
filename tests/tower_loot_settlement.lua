local Factory = require('server.domain.StateFactory')
local Combat = require('server.domain.CombatEngine')
local Engine = require('server.domain.GameEngine')
local Schema = require('shared.GameStateSchema')
local Big = require('shared.BigNumber')
local Tables = require('shared.TableUtils')
local now = 1791455000
math.randomseed(20261009)
local battles, drops, floorAdvances = 0, 0, 0
for _, floor in ipairs({ 1, 9, 10, 49, 50, 100 }) do
    for _, room in ipairs({ 9, 10 }) do
        for _, inventoryCount in ipairs({ 12, 181, 299, 300 }) do
            for seed = 1, 12 do
                local state = Factory.Create(now)
                state.tutorial.completed = true
                state.floor, state.maxFloor, state.position, state.autoRun = floor, floor, room, true
                state.automationPolicy.autoEquip = true
                state.automationPolicy.autoSkipStory = true
                local original = state.inventory[1]
                while #state.inventory < inventoryCount do
                    local item = Tables.DeepCopy(original)
                    item.id = string.format('00000000-0000-4000-8000-%012d', #state.inventory)
                    state.inventory[#state.inventory + 1] = item
                end
                local rng = function() return (seed - 0.5) / 12 end
                Combat.BeginBattle(state, room == 9 and 'elite' or 'boss', rng, {})
                state.stats.atkBig = Big.New(1, 100)
                state.stats.atk = 1e100
                state.stats.hpBig = Big.New(1, 100)
                state.stats.hp = 1e100
                state.hpBig, state.hp = Big.New(1, 100), 1e100
                local result = Engine.AdvanceCombatTick(state, rng, now + 1, 60)
                assert(result.ok)
                local valid, err = Schema.ValidateState(result.state)
                assert(valid, tostring(err and err.reason) .. ' path=' .. tostring(err and err.details and err.details.path) .. ' floor=' .. floor .. ' room=' .. room)
                assert(not result.state.currentMonster or result.state.pauseReason == 'inventory_full', 'dead monster did not settle')
                local events, eventError = Schema.CanonicalizeGameEvents(result.delta.events)
                assert(events, eventError)
                local snapshot = Schema.BuildSnapshot(result.state, { serverTime = now + 1, playerNickname = 'Stress test' })
                snapshot.logs, snapshot.recentDamage = {}, 'Waiting'
                valid, err = Schema.ValidateSnapshot(snapshot)
                assert(valid, err and err.reason)
                for _, event in ipairs(events) do
                    if event.type == 'equipment_drop' or event.type == 'loot_dropped' then drops = drops + 1 end
                    if event.type == 'floor_advanced' then floorAdvances = floorAdvances + 1 end
                end
                battles = battles + 1
            end
        end
    end
end
print('tower settlement stress: PASS battles=' .. battles .. ' dropEvents=' .. drops .. ' floorAdvances=' .. floorAdvances)
