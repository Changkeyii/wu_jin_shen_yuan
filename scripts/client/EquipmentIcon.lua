local Widget = require("urhox-libs/UI/Core/Widget")
local ImageCache = require("urhox-libs/UI/Core/ImageCache")

local EquipmentIcon = Widget:Extend("EquipmentIcon")

function EquipmentIcon:Init(props)
    ---@cast self Widget
    props = props or {}
    props.atlas = props.atlas or "image/equipment/equipment_atlas.png"
    props.atlasColumns = props.atlasColumns or 8
    props.atlasCellSize = props.atlasCellSize or 128
    self.props = props
    Widget.Init(self, props)
end

function EquipmentIcon:Render(nvg)
    local props = self.props
    local atlasIndex = math.max(0, math.floor(props.atlasIndex or 0))
    local imageHandle = ImageCache.Get(props.atlas)
    if not imageHandle or imageHandle <= 0 then return end

    local atlasWidth, atlasHeight = ImageCache.GetSize(props.atlas)
    if atlasWidth <= 0 or atlasHeight <= 0 then return end

    local layout = self:GetAbsoluteLayout()
    local cellSize = props.atlasCellSize
    local column = atlasIndex % props.atlasColumns
    local row = math.floor(atlasIndex / props.atlasColumns)
    local scaleX = layout.w / cellSize
    local scaleY = layout.h / cellSize
    local patternX = layout.x - column * cellSize * scaleX
    local patternY = layout.y - row * cellSize * scaleY
    local patternWidth = atlasWidth * scaleX
    local patternHeight = atlasHeight * scaleY

    nvgBeginPath(nvg)
    nvgRect(nvg, layout.x, layout.y, layout.w, layout.h)
    nvgFillPaint(nvg, nvgImagePattern(
        nvg,
        patternX,
        patternY,
        patternWidth,
        patternHeight,
        0,
        imageHandle,
        props.opacity or 1
    ))
    nvgFill(nvg)
end

function EquipmentIcon:IsStateful()
    return false
end

return EquipmentIcon
