-- EquipmentQuickFilter.lua
-- 背包 / 装备页的快速筛选。
-- 与出售/分解筛选同风格的复选行，额外提供「只看可交易」「只看已锁定」条件；
-- 筛选仅影响展示列表，不参与一键分解、出售等批量操作。

local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local CommonPromptDialog = require("client.CommonPromptDialog")
local RarityCatalog = require("shared.RarityCatalog")

local EquipmentQuickFilter = {}

local C = GameTheme.Colors
local FILE_NAME = "settings/equipment_quick_filters.json"
local MODES = { "bag", "equip" }
local MODE_SET = { bag = true, equip = true }
local CHECKBOX_OFF = "image/ui/recycle_filter/checkbox_off.png"
local CHECKBOX_ON = "image/ui/recycle_filter/checkbox_on.png"

local loaded_ = false
local settings_ = nil

local function DefaultRarities()
    local selection = {}
    for _, rarityId in ipairs(RarityCatalog.ORDER) do
        selection[rarityId] = true
    end
    return selection
end

local function CopyRarities(source)
    local result = {}
    source = type(source) == "table" and source or {}
    for _, rarityId in ipairs(RarityCatalog.ORDER) do
        result[rarityId] = source[rarityId] ~= false
    end
    return result
end

local function NormalizeMode(value)
    value = type(value) == "table" and value or {}
    return {
        rarities = CopyRarities(value.rarities),
        tradeableOnly = value.tradeableOnly == true,
        lockedOnly = value.lockedOnly == true,
    }
end

local function NormalizeSettings(value)
    value = type(value) == "table" and value or {}
    local result = { version = 1 }
    for _, mode in ipairs(MODES) do
        result[mode] = NormalizeMode(value[mode])
    end
    return result
end

local function Load()
    if loaded_ then return end
    loaded_ = true
    settings_ = NormalizeSettings(nil)
    if not fileSystem:FileExists(FILE_NAME) then return end

    local file = File(FILE_NAME, FILE_READ)
    if not file:IsOpen() then return end
    local encoded = file:ReadString()
    file:Close()
    local ok, decoded = pcall(cjson.decode, encoded)
    if ok then
        settings_ = NormalizeSettings(decoded)
    else
        print("[EquipmentQuickFilter] failed to decode local settings")
    end
end

local function Save()
    fileSystem:CreateDir("settings")
    local file = File(FILE_NAME, FILE_WRITE)
    if not file:IsOpen() then
        print("[EquipmentQuickFilter] failed to open local settings for writing")
        return false
    end
    local ok, encoded = pcall(cjson.encode, settings_)
    if ok then file:WriteString(encoded) end
    file:Close()
    if not ok then
        print("[EquipmentQuickFilter] failed to encode local settings")
    end
    return ok
end

local function Mode(mode)
    assert(MODE_SET[mode], "unsupported equipment quick filter mode: " .. tostring(mode))
    Load()
    return settings_[mode]
end

function EquipmentQuickFilter.Get(mode)
    local current = Mode(mode)
    return {
        rarities = CopyRarities(current.rarities),
        tradeableOnly = current.tradeableOnly,
        lockedOnly = current.lockedOnly,
    }
end

function EquipmentQuickFilter.Matches(mode, item)
    item = item or {}
    local filter = EquipmentQuickFilter.Get(mode)
    local rarityId = RarityCatalog.NormalizeId(item.rarity)
    if filter.rarities[rarityId] ~= true then return false end
    if filter.tradeableOnly and item.tradeable ~= true then return false end
    if filter.lockedOnly and not (item.locked == true or item.aidLocked == true) then return false end
    return true
end

local function CheckImage(checked)
    return UI.Panel {
        width = 76,
        height = 76,
        flexShrink = 0,
        backgroundImage = checked and CHECKBOX_ON or CHECKBOX_OFF,
        backgroundFit = "contain",
        pointerEvents = "none",
    }
end

local function FilterRow(checkImage, labelWidget, onClick)
    return UI.Panel {
        width = 390,
        height = 118,
        flexShrink = 0,
        clickable = true,
        flexDirection = "row",
        alignItems = "center",
        gap = 18,
        paddingLeft = 20,
        paddingRight = 16,
        borderWidth = 2,
        borderColor = { 65, 112, 168, 220 },
        borderRadius = 12,
        backgroundColor = { 12, 28, 56, 210 },
        onClick = onClick,
        children = {
            checkImage,
            UI.Panel {
                width = 250,
                height = 76,
                flexShrink = 0,
                justifyContent = "center",
                children = { labelWidget },
            },
        },
    }
end

function EquipmentQuickFilter.Show(mode, options)
    options = options or {}
    local draft = EquipmentQuickFilter.Get(mode)
    local rows = {}

    for _, rarityId in ipairs(RarityCatalog.ORDER) do
        local currentRarityId = rarityId
        local entry = RarityCatalog.Get(currentRarityId)
        local checkImage = CheckImage(draft.rarities[currentRarityId])
        rows[#rows + 1] = FilterRow(checkImage, UI.Label {
            text = entry.name .. " 品质",
            width = "100%",
            height = 58,
            fontSize = 26,
            fontColor = entry.color,
            textAlign = "left",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        }, function()
            draft.rarities[currentRarityId] = not draft.rarities[currentRarityId]
            checkImage:SetProp("backgroundImage",
                draft.rarities[currentRarityId] and CHECKBOX_ON or CHECKBOX_OFF)
        end)
    end

    local function ToggleRow(text, color, checked, onChange)
        local checkImage = CheckImage(checked)
        local row = FilterRow(checkImage, UI.Label {
            text = text,
            width = "100%",
            height = 58,
            fontSize = 26,
            fontColor = color,
            textAlign = "left",
            textStroke = { width = 2, color = "#000000" },
            pointerEvents = "none",
        }, function()
            checked = not checked
            checkImage:SetProp("backgroundImage", checked and CHECKBOX_ON or CHECKBOX_OFF)
            onChange(checked)
        end)
        return row
    end

    rows[#rows + 1] = ToggleRow("只看可交易", C.gold, draft.tradeableOnly, function(value)
        draft.tradeableOnly = value
    end)
    rows[#rows + 1] = ToggleRow("只看已锁定", C.focus, draft.lockedOnly, function(value)
        draft.lockedOnly = value
    end)

    return CommonPromptDialog.Show {
        kind = "confirm",
        queueKey = "equipment-quick-filter:" .. mode,
        title = "快速筛选",
        message = mode == "bag"
            and "勾选要在背包中展示的装备品质与状态"
            or "勾选要在可穿戴列表中展示的装备品质与状态",
        lines = {
            "默认全部勾选即展示全部；筛选只影响展示列表，不影响一键分解与出售。",
        },
        dialogWidth = 980,
        dialogHeight = 1120,
        bodyTop = 116,
        bodyHeight = 830,
        buttonTop = 1052,
        closeOnOverlay = false,
        cancelText = "取消",
        confirmText = "应用筛选",
        content = UI.Panel {
            width = "100%",
            flexShrink = 0,
            flexDirection = "row",
            flexWrap = "wrap",
            justifyContent = "center",
            alignItems = "flex-start",
            gap = 18,
            children = rows,
        },
        onConfirm = function()
            settings_[mode] = {
                rarities = CopyRarities(draft.rarities),
                tradeableOnly = draft.tradeableOnly,
                lockedOnly = draft.lockedOnly,
            }
            Save()
            if options.onApplied then options.onApplied(EquipmentQuickFilter.Get(mode)) end
        end,
    }
end

EquipmentQuickFilter.MODES = MODES

return EquipmentQuickFilter
