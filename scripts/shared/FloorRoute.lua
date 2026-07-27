local TowerRules = require("shared.TowerRules")

local FloorRoute = {}

FloorRoute.VERSION = 1
FloorRoute.FIRST_ENCOUNTER_DISTANCE = 580
FloorRoute.ENCOUNTER_SPACING = 420
FloorRoute.TRIGGER_DISTANCE = 120
FloorRoute.MOVE_SPEED = 96

local function NormalizeFloor(value)
    return math.max(1, math.floor(tonumber(value) or 1))
end

function FloorRoute.RouteId(floor)
    return string.format("route:v%d:floor:%d", FloorRoute.VERSION, NormalizeFloor(floor))
end

function FloorRoute.EncounterId(floor, room)
    return string.format("floor:%d:room:%d", NormalizeFloor(floor), room)
end

function FloorRoute.Build(floor)
    floor = NormalizeFloor(floor)
    local encounters = {}
    for room = 1, TowerRules.ENCOUNTERS_PER_FLOOR do
        local source = TowerRules.GetEncounter(room, floor)
        local kind = source and source.kind or "normal"
        encounters[room] = {
            encounterId = FloorRoute.EncounterId(floor, room),
            room = room,
            distance = FloorRoute.FIRST_ENCOUNTER_DISTANCE
                + (room - 1) * FloorRoute.ENCOUNTER_SPACING,
            kind = kind,
            eventType = kind == "normal" and "monster"
                or (kind == "chapterBoss" and "boss" or kind),
            isBoss = kind == "boss" or kind == "chapterBoss",
        }
    end
    return {
        version = FloorRoute.VERSION,
        routeId = FloorRoute.RouteId(floor),
        floor = floor,
        moveSpeed = FloorRoute.MOVE_SPEED,
        triggerDistance = FloorRoute.TRIGGER_DISTANCE,
        encounters = encounters,
    }
end

function FloorRoute.GetEncounter(floor, room)
    room = math.floor(tonumber(room) or 0)
    if room < 1 or room > TowerRules.ENCOUNTERS_PER_FLOOR then
        return nil
    end
    return FloorRoute.Build(floor).encounters[room]
end

return FloorRoute
