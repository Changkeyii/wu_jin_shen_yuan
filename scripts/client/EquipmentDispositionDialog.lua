local UI = require("urhox-libs/UI")
local CommonPromptDialog = require("client.CommonPromptDialog")
local ServerClient = require("client.ServerClient")
local BackpackItemSlot = require("client.BackpackItemSlot")
local GridVirtualList = require("client.UI.GridVirtualList")
local RarityCatalog = require("shared.RarityCatalog")
local ItemSort = require("shared.ItemSort")
local LargeNumber = require("shared.LargeNumber")

local EquipmentDispositionDialog = {}

local MODE = {
    sell = {
        title = "出售预览",
        verb = "出售",
        execute = ServerClient.Sell,
    },
    decompose = {
        title = "分解预览",
        verb = "分解",
        execute = ServerClient.Decompose,
    },
}

local function ItemContext(context)
    return {
        UI = UI,
        C = context.C,
        ASSETS = context.ASSETS,
        compactTxt = context.compactTxt,
        shortenText = context.shortenText,
        rarityColor = context.rarityColor,
        itemImage = context.itemImage,
        itemLevelText = context.itemLevelText,
        isEquipped = context.isEquipped,
    }
end

local function MaxRank(items)
    local maximumRank = 0
    for _, item in ipairs(items) do
        maximumRank = math.max(maximumRank, RarityCatalog.Rank(item.rarity))
    end
    return maximumRank
end

function EquipmentDispositionDialog.Show(context, options)
    options = options or {}
    local mode = MODE[options.mode]
    assert(mode, "unsupported equipment disposition mode")
    local items = ItemSort.Sort(options.items or {})
    if #items == 0 then return false end

    local tutorialSelection = options.tutorial == true and options.mode == "decompose"
    local selected = {}
    local previews = {}
    local cells = {}
    local previewReady = false
    local previewFailed = false
    for _, item in ipairs(items) do selected[item.id] = not tutorialSelection end

    local countText = nil
    local goldText = nil
    local fragmentText = nil

    local function SelectedCount()
        local count = 0
        for _, item in ipairs(items) do
            if selected[item.id] then count = count + 1 end
        end
        return count
    end

    local function Totals()
        local gold = LargeNumber.Zero()
        local fragments = LargeNumber.Zero()
        for _, item in ipairs(items) do
            if selected[item.id] then
                local preview = previews[item.id]
                if preview then
                    gold = LargeNumber.Add(gold, preview.gold or 0)
                    fragments = LargeNumber.Add(
                        fragments,
                        preview.fragments or 0
                    )
                end
            end
        end
        return gold, fragments
    end

    local function RefreshTotals()
        local gold, fragments = Totals()
        if countText then
            countText:SetText(string.format("即将%s %d / %d 件装备", mode.verb, SelectedCount(), #items))
        end
        if goldText then goldText:SetText("+" .. context.formatInt(gold)) end
        if fragmentText then fragmentText:SetText("+" .. context.formatInt(fragments)) end
    end

    local guideBlue = context.C.focus or { 111, 231, 255, 255 }
    local function RefreshCell(itemId)
        local cell = cells[itemId]
        -- 虚拟网格行池化复用：不在当前绑定行中的卡片可能已被销毁，跳过并清理引用。
        if not cell or cell.panel.parent == nil then
            cells[itemId] = nil
            return
        end
        local isSelected = selected[itemId] == true
        cell.panel:SetBackgroundColor(isSelected and { 30, 90, 150, 120 } or { 12, 22, 40, 120 })
        -- 教学态用蓝色描边；选中时同样保持 focus 蓝。
        if tutorialSelection then
            cell.panel:SetBorderColor(guideBlue)
        else
            cell.panel:SetBorderColor(isSelected and context.C.focus or context.C.border)
        end
        cell.label:SetText(isSelected and "✓ 已选择" or "○ 未选择")
        cell.label:SetFontColor(isSelected and context.C.success or context.C.textDim)
    end

    local itemContext = ItemContext(context)
    -- 分解候选虚拟网格：行池化复用，替代全量 cards + flexWrap ScrollView。
    -- 弹窗每次打开重建，无需保存滚动位置。
    local candidateGrid = GridVirtualList.Build {
        columns = 3,
        cardWidth = 186,
        cardHeight = 216,
        cardGap = 12,
        rowGap = 12,
        -- content 高度 584 - countText 36 - gap 12 = 536。
        viewportHeight = 536,
        widgetProps = {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
        },
        showScrollbar = false,
        data = items,
        createCard = function(row, slotIndex, item)
            if not item then return nil end
            local label = context.compactTxt(
                selected[item.id] and "✓ 已选择" or "○ 未选择",
                15,
                selected[item.id] and context.C.success or context.C.textDim,
                {
                    width = "100%", height = 22, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                }
            )
            local itemCard = BackpackItemSlot.Build(itemContext, item, {
                width = 174,
                height = 174,
                selected = false,
                clickable = false,
                showLockButton = false,
                -- 预览格子由外层整卡接管点击，内部图标/文案不得截获命中。
                itemTips = false,
            })
            -- 整棵子树不参与命中：点击任意位置都落到外层 panel.onClick。
            if itemCard and itemCard.SetProp then
                itemCard:SetProp("pointerEvents", "none")
            elseif itemCard and itemCard.props then
                itemCard.props.pointerEvents = "none"
            end
            local panel = UI.Panel {
                id = tutorialSelection and ("tutorialDispositionCandidate:" .. tostring(item.id)) or nil,
                width = 186,
                height = 216,
                flexShrink = 0,
                clickable = true,
                alignItems = "center",
                justifyContent = "center",
                gap = 4,
                paddingTop = 6,
                paddingBottom = 6,
                backgroundColor = selected[item.id]
                    and { 30, 90, 150, 120 }
                    or { 12, 22, 40, 120 },
                -- 教学态：候选卡片自带蓝色描边，不依赖覆盖层几何高亮。
                borderWidth = tutorialSelection and 4 or 2,
                borderColor = tutorialSelection
                    and guideBlue
                    or (selected[item.id] and context.C.focus or context.C.border),
                borderRadius = 10,
                onClick = function()
                    -- 行会被池化复用：点击时从当前绑定读取 item，禁止闭包捕获 bind 参数。
                    local currentItem = row._boundItems[slotIndex]
                    if not currentItem then return end
                    selected[currentItem.id] = not selected[currentItem.id]
                    RefreshCell(currentItem.id)
                    RefreshTotals()
                    if tutorialSelection and options.onTutorialSelectionChanged then
                        options.onTutorialSelectionChanged(
                            currentItem.id,
                            selected[currentItem.id] == true
                        )
                    end
                end,
                children = { itemCard, label },
            }
            cells[item.id] = { panel = panel, label = label }
            return panel
        end,
    }

    countText = context.compactTxt(
        string.format("即将%s %d / %d 件装备", mode.verb, SelectedCount(), #items),
        24, context.C.text, {
            width = "100%", height = 36, textAlign = "center",
            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
        }
    )
    goldText = context.compactTxt("+0", 24, context.C.gold, {
        width = 200, height = 34, textAlign = "right",
        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
    })
    if options.mode == "decompose" then
        fragmentText = context.compactTxt("+0", 24, context.C.secondary, {
            width = 200, height = 34, textAlign = "right",
            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
        })
    end

    local rewardChildren = {
        context.compactTxt(mode.verb .. "总获得", 21, context.C.text, {
            width = 150, height = 34, textAlign = "left",
            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
        }),
        UI.Panel {
            width = 200, height = 44, flexShrink = 0,
            flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 8,
            children = {
                UI.Panel { width = 36, height = 36, flexShrink = 0,
                    backgroundImage = context.ASSETS.items.gold, backgroundFit = "contain" },
                goldText,
            },
        },
    }
    if fragmentText then
        rewardChildren[#rewardChildren + 1] = UI.Panel {
            width = 200, height = 44, flexShrink = 0,
            flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 8,
            children = {
                UI.Panel { width = 36, height = 36, flexShrink = 0,
                    backgroundImage = context.ASSETS.items.crystal, backgroundFit = "contain" },
                fragmentText,
            },
        }
    end

    local rewardPanel = UI.Panel {
        width = "100%", height = 90, flexShrink = 0,
        left = -22, top = 19, zIndex = 1,
        flexDirection = "row", alignItems = "center", justifyContent = "center",
        gap = 32, paddingTop = 10, borderTopWidth = 2, borderColor = context.C.border,
        children = rewardChildren,
    }

    local content = UI.Panel {
        width = "100%", height = 584, flexShrink = 0, gap = 12,
        children = {
            countText,
            candidateGrid,
        },
    }

    local function Execute()
        if previewFailed then
            if context.toast then context.toast("报价失败，请关闭后重试", "error") end
            return false
        end
        if not previewReady then
            if context.toast then context.toast("正在获取服务器权威报价", "info") end
            return false
        end
        local ids = {}
        local executeItems = {}
        for _, item in ipairs(items) do
            if selected[item.id] then
                ids[#ids + 1] = item.id
                executeItems[#executeItems + 1] = item
            end
        end
        if #ids == 0 then
            if context.toast then context.toast("请至少选择一件装备", "info") end
            return false
        end
        mode.execute(MaxRank(executeItems), ids, function(response)
            if not (response and response.ok) then
                if context.onError then context.onError(response) end
                return
            end
            local reward = response.data and response.data.reward or {}
            if context.onRefresh then context.onRefresh() end
            if context.showReward then context.showReward(options.mode, reward) end
            if options.onComplete then options.onComplete(response) end
        end)
        return true
    end

    local function ShowDialog()
        CommonPromptDialog.Show {
            kind = "confirm",
            priority = 150,
            queueKey = "equipment-disposition:" .. options.mode,
            title = mode.title,
            dialogWidth = 900,
            dialogHeight = 1040,
            lines = { "以下为服务器实时结算预览；操作完成后无法撤销。" },
            cancelText = "取消",
            confirmText = "确认" .. mode.verb,
            danger = true,
            closeOnOverlay = false,
            -- 引导层已提到 3900，弹窗保持 3850；真正可点由输入白名单控制。
            zIndex = 3850,
            tutorialConfirmId = tutorialSelection and "tutorialDispositionConfirm" or nil,
            bodyScrollY = false,
            content = content,
            foregroundContent = rewardPanel,
            foregroundLeft = 84,
            foregroundTop = 788,
            foregroundWidth = 732,
            foregroundHeight = 109,
            onConfirm = Execute,
            onPresented = function()
                if not tutorialSelection then return end
                local ok, TutorialController = pcall(require, "client.TutorialController")
                if ok and TutorialController and TutorialController.NotifyAction then
                    TutorialController.NotifyAction("decompose_dialog_ready")
                end
            end,
        }
    end

    local candidateIds = {}
    for _, item in ipairs(items) do candidateIds[#candidateIds + 1] = item.id end
    ServerClient.DispositionPreview(options.mode, candidateIds, function(response)
        if not (response and response.ok and type(response.data) == "table") then
            previewFailed = true
            if context.onError then context.onError(response) end
            for _, item in ipairs(items) do
                selected[item.id] = false
                RefreshCell(item.id)
            end
            RefreshTotals()
            return
        end

        local quoted = {}
        for _, quote in ipairs(response.data.items or {}) do
            if quote.itemId then
                previews[quote.itemId] = quote
                quoted[quote.itemId] = true
            end
        end
        for _, item in ipairs(items) do
            if not quoted[item.id] then
                selected[item.id] = false
                RefreshCell(item.id)
            end
        end
        previewReady = true
        RefreshTotals()
        ShowDialog()
    end)
    return true
end

return EquipmentDispositionDialog
