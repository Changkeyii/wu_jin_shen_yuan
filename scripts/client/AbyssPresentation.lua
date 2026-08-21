local UI = require("urhox-libs/UI")
local AbyssDefinitions = require("shared.AbyssDefinitions")

local AbyssPresentation = {}

local function withAlpha(color, alpha)
    return { color[1], color[2], color[3], alpha }
end

function AbyssPresentation.BuildPillar(gradeId, options)
    options = options or {}
    local grade = AbyssDefinitions.Get(gradeId) or AbyssDefinitions.Get("rift")
    local width = options.width or 120
    local height = options.height or 200
    local color = grade.color
    return UI.Panel {
        width = width,
        height = height,
        flexShrink = 0,
        position = "relative",
        alignItems = "center",
        justifyContent = "center",
        pointerEvents = "none",
        children = {
            UI.Panel {
                position = "absolute",
                left = math.floor(width * 0.13),
                top = math.floor(height * 0.08),
                width = math.floor(width * 0.74),
                height = math.floor(height * 0.84),
                backgroundColor = withAlpha(color, 38),
                borderWidth = 6,
                borderColor = withAlpha(color, 90),
                boxShadow = {
                    color = withAlpha(color, 85),
                    offsetX = 0,
                    offsetY = 0,
                    blurRadius = 16,
                },
            },
            UI.Panel {
                position = "absolute",
                left = math.floor(width * 0.24),
                top = math.floor(height * 0.04),
                width = math.floor(width * 0.52),
                height = math.floor(height * 0.92),
                backgroundGradient = {
                    type = "linear",
                    direction = "to-bottom",
                    from = withAlpha(color, 55),
                    to = withAlpha(color, 230),
                },
                borderWidth = 3,
                borderColor = color,
                boxShadow = {
                    color = withAlpha(color, 170),
                    offsetX = 0,
                    offsetY = 0,
                    blurRadius = 8,
                },
            },
            UI.Panel {
                position = "absolute",
                left = math.floor(width * 0.40),
                top = math.floor(height * 0.12),
                width = math.max(4, math.floor(width * 0.08)),
                height = math.floor(height * 0.68),
                backgroundColor = { 255, 255, 255, 150 },
            },
            UI.Label {
                position = "absolute",
                left = 0,
                bottom = 0,
                width = width,
                height = 32,
                text = grade.shortName,
                fontSize = options.fontSize or 16,
                fontWeight = "bold",
                fontColor = color,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
            },
        },
    }
end

return AbyssPresentation
