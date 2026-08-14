local UI = require("urhox-libs/UI")
local CommonPromptDialog = require("client.CommonPromptDialog")
local RarityCatalog = require("shared.RarityCatalog")

local EquipmentRecycleFilter = {}

local FILE_NAME = "settings/equipment_recycle_filters.json"
local FILTER_RARITIES = {
    "common", "advanced", "rare", "artifact", "legendary", "epic",
}
local SHORT_NAMES = {
    common = "普通 / 白色",
    advanced = "高级 / 蓝色",
    rare = "稀有 / 紫色",
    artifact = "神器 / 粉色",
    legendary = "传说 / 赤红",
    epic = "史诗 / 橙金",
}
local MODE_TITLES = {
    sell = "出售筛选",
    decompose = "分解筛选",
}
local CHECKBOX_OFF = "image/ui/recycle_filter/checkbox_off.png"
local CHECKBOX_ON = "image/ui/recycle_filter/checkbox_on.png"

local loaded_ = false
local settings_ = nil

local function DefaultSelection()
    return {
        common = true,
        advanced = false,
        rare = false,
        artifact = false,
        legendary = false,
        epic = false,
    }
end

local function CopySelection(source)
    local result = {}
    source = type(source) == "table" and source or {}
    for _, rarityId in ipairs(FILTER_RARITIES) do
        result[rarityId] = source[rarityId] == true
    end
    return result
end

local function NormalizeSettings(value)
    value = type(value) == "table" and value or {}
    return {
        version = 1,
        sell = value.sell and CopySelection(value.sell) or DefaultSelection(),
        decompose = value.decompose and CopySelection(value.decompose) or DefaultSelection(),
    }
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
        print("[EquipmentRecycleFilter] failed to decode local settings")
    end
end

local function Save()
    fileSystem:CreateDir("settings")
    local file = File(FILE_NAME, FILE_WRITE)
    if not file:IsOpen() then
        print("[EquipmentRecycleFilter] failed to open local settings for writing")
        return false
    end
    local ok, encoded = pcall(cjson.encode, settings_)
    if ok then file:WriteString(encoded) end
    file:Close()
    if not ok then
        print("[EquipmentRecycleFilter] failed to encode local settings")
    end
    return ok
end

local function IsSupportedMode(mode)
    return mode == "sell" or mode == "decompose"
end

function EquipmentRecycleFilter.Get(mode)
    assert(IsSupportedMode(mode), "unsupported equipment recycle filter mode")
    Load()
    return CopySelection(settings_[mode])
end

function EquipmentRecycleFilter.IsSelected(mode, rarityId)
    local selection = EquipmentRecycleFilter.Get(mode)
    return selection[RarityCatalog.NormalizeId(rarityId)] == true
end

function EquipmentRecycleFilter.MaxSelectedRank(mode)
    local selection = EquipmentRecycleFilter.Get(mode)
    local maximumRank = 0
    for _, rarityId in ipairs(FILTER_RARITIES) do
        if selection[rarityId] then
            maximumRank = math.max(maximumRank, RarityCatalog.Rank(rarityId))
        end
    end
    return maximumRank
end

function EquipmentRecycleFilter.Summary(mode)
    local selection = EquipmentRecycleFilter.Get(mode)
    local names = {}
    for _, rarityId in ipairs(FILTER_RARITIES) do
        if selection[rarityId] then
            names[#names + 1] = RarityCatalog.Get(rarityId).name
        end
    end
    return #names > 0 and table.concat(names, "、") or "未选择品质"
end

function EquipmentRecycleFilter.FilterItems(mode, items, predicate)
    local selection = EquipmentRecycleFilter.Get(mode)
    local result = {}
    for _, item in ipairs(items or {}) do
        local rarityId = RarityCatalog.NormalizeId(item.rarity)
        if selection[rarityId] and (not predicate or predicate(item)) then
            result[#result + 1] = item
        end
    end
    return result
end

function EquipmentRecycleFilter.Show(mode, options)
    assert(IsSupportedMode(mode), "unsupported equipment recycle filter mode")
    options = options or {}
    local draft = EquipmentRecycleFilter.Get(mode)
    local tutorialMode = false
    if mode == "decompose" then
        local ok, TutorialController = pcall(require, "client.TutorialController")
        tutorialMode = ok
            and TutorialController
            and TutorialController.IsActive
            and TutorialController.IsActive()
            and TutorialController.GetStep
            and TutorialController.GetStep() == 3
        -- 序章分解筛选：强制默认勾选普通/白色，避免点一下反选导致后续无候选。
        if tutorialMode then draft.common = true end
    end
    local rows = {}
    for _, rarityId in ipairs(FILTER_RARITIES) do
        local currentRarityId = rarityId
        local entry = RarityCatalog.Get(currentRarityId)
        local checkImage = UI.Panel {
            width = 84,
            height = 84,
            flexShrink = 0,
            backgroundImage = draft[currentRarityId] and CHECKBOX_ON or CHECKBOX_OFF,
            backgroundFit = "contain",
            pointerEvents = "none",
        }
        rows[#rows + 1] = UI.Panel {
            id = "tutorialRecycleFilterRarity:" .. currentRarityId,
            width = 390,
            height = 128,
            flexShrink = 0,
            clickable = true,
            flexDirection = "row",
            alignItems = "center",
            gap = 22,
            paddingLeft = 24,
            paddingRight = 20,
            borderWidth = 2,
            borderColor = { 65, 112, 168, 220 },
            borderRadius = 12,
            backgroundColor = { 12, 28, 56, 210 },
            onClick = function()
                if tutorialMode and currentRarityId == "common" then
                    draft.common = true
                else
                    draft[currentRarityId] = not draft[currentRarityId]
                end
                checkImage:SetProp("backgroundImage",
                    draft[currentRarityId] and CHECKBOX_ON or CHECKBOX_OFF)
            end,
            children = {
                checkImage,
                UI.Panel {
                    width = 250,
                    height = 88,
                    flexShrink = 0,
                    justifyContent = "center",
                    children = {
                        UI.Label {
                            text = SHORT_NAMES[currentRarityId],
                            width = "100%",
                            height = 58,
                            fontSize = 28,
                            fontColor = entry.color,
                            textAlign = "left",
                            textStroke = { width = 2, color = "#000000" },
                            pointerEvents = "none",
                        },
                    },
                },
            },
        }
    end

    return CommonPromptDialog.Show {
        kind = "confirm",
        queueKey = "equipment-filter:" .. mode,
        title = MODE_TITLES[mode],
        message = mode == "sell"
            and "勾选一键出售时处理的装备品质"
            or "勾选一键分解时处理的装备品质",
        lines = { "已穿戴、锁定、援助锁定及神话装备始终受到保护。" },
        dialogWidth = 980,
        dialogHeight = 1060,
        bodyTop = 116,
        bodyHeight = 790,
        buttonTop = 948,
        closeOnOverlay = false,
        cancelText = "取消",
        confirmText = "保存筛选",
        -- 序章强制引导：只允许确认保存；取消/关闭不进白名单。
        tutorialConfirmId = mode == "decompose" and "tutorialDecomposeFilterConfirm" or nil,
        zIndex = mode == "decompose" and 3850 or nil,
        content = UI.Panel {
            width = "100%",
            height = 414,
            flexShrink = 0,
            flexDirection = "row",
            flexWrap = "wrap",
            justifyContent = "center",
            alignItems = "flex-start",
            gap = 18,
            children = rows,
        },
        onConfirm = function()
            if tutorialMode then draft.common = true end
            settings_[mode] = CopySelection(draft)
            Save()
            if options.onSaved then options.onSaved(EquipmentRecycleFilter.Get(mode)) end
        end,
    }
end

EquipmentRecycleFilter.RARITIES = FILTER_RARITIES

return EquipmentRecycleFilter
