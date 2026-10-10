local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ServerClient = require("client.ServerClient")
local RarityCatalog = require("shared.RarityCatalog")
local LargeNumber = require("shared.LargeNumber")
local ItemTips = require("client.ItemTips")
local BackpackItemSlot = require("client.BackpackItemSlot")
local ItemSlotBase = require("client.ItemSlotBase")
local CommonPromptDialog = require("client.CommonPromptDialog")
local EquipmentRecycleFilter = require("client.EquipmentRecycleFilter")
local RewardDialogView = require("client.RewardDialogView")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local ItemView = require("client.ItemView")
local GridVirtualList = require("client.UI.GridVirtualList")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local EquipmentActionController = {}
---@type table?
local context_ = nil

local function CollectDecomposeCandidateItems(selection)
    local game = context_.getGame()
    selection = type(selection) == "table" and selection or {}
    local TutorialController = require("client.TutorialController")
    local tutorialDecompose = TutorialController.IsActive
        and TutorialController.IsActive()
        and TutorialController.GetStep
        and TutorialController.GetStep() == 3
    local items = {}
    for _, item in ipairs(game.inventory or {}) do
        local rarityId = RarityCatalog.NormalizeId(item.rarity)
        if item.equipmentId and item.id ~= nil
            and rarityId ~= "myth"
            and not item.locked and not item.aidLocked and not ItemView.IsEquipped(game, item)
            and (selection[rarityId] == true or tutorialDecompose)
        then
            items[#items + 1] = item
        end
    end
    return items
end

local function IsTutorialDecomposeStep()
    local TutorialController = require("client.TutorialController")
    if TutorialController.IsActive and TutorialController.IsActive()
        and TutorialController.GetStep and TutorialController.GetStep() == 3
    then
        return true
    end
    local game = context_ and context_.getGame and context_.getGame() or nil
    return game
        and game.tutorial
        and game.tutorial.completed ~= true
        and tonumber(game.tutorial.step) == 3
end

local function ShowDecomposeRewardDialog(gold, fragments, count)
    local cards = {}
    if not LargeNumber.IsZero(gold) then
        RewardDialogView.AddCard(cards, ASSETS.items.gold, "金币", "+" .. Kit.FormatInt(gold), "epic")
    end
    if fragments and fragments > 0 then
        RewardDialogView.AddCard(cards, ASSETS.items.crystal, "碎片", "+" .. Kit.FormatInt(fragments), "rare")
    end
    if #cards == 0 then return end
    RewardDialogView.Show {
        title = "分解成功",
        message = "已分解 " .. tostring(count) .. " 件装备",
        lines = { "返还资源已存入账户" },
        cards = cards,
        confirmText = "确认收取",
    }
end

-- 解析当前强化/升星目标部位：
-- 1) 优先使用当前选中的「已穿戴」装备所属部位
-- 2) 否则使用当前选中的部位槽
-- 3) 仅序章 step4 强制武器槽（教学需要）
local function ResolveUpgradeSlot(preferTutorialWeapon)
    local inventoryState = context_ and context_.inventoryState or {}
    local game = context_ and context_.getGame and context_.getGame() or nil
    local slotId = inventoryState.selectedSlot
    local selectedId = inventoryState.selectedInventoryId

    if game and selectedId ~= nil then
        local selectedItem = ItemView.GetItemById(game, selectedId)
        if selectedItem and selectedItem.slot and ItemView.IsEquipped(game, selectedItem) then
            slotId = selectedItem.slot
        end
    end

    if preferTutorialWeapon then
        local TutorialController = require("client.TutorialController")
        if TutorialController.IsActive
            and TutorialController.IsActive()
            and TutorialController.GetStep
            and TutorialController.GetStep() == 4
        then
            if game and game.equipped and game.equipped.weapon then
                slotId = "weapon"
            end
        end
    end

    if slotId and inventoryState then
        inventoryState.selectedSlot = slotId
    end
    return slotId
end

local actionFns_ = {}
actionFns_.CollectOffline = function(...) return context_.collectOffline(...) end
actionFns_.EquipItem = function(item)
    if not (item and item.id) then return end

    local function EquipConfirmed()
        context_.inventoryState.selectedSlot = item.slot or context_.inventoryState.selectedSlot
        ServerClient.Equip(item.id, function(response)
            if not context_.actionResult(response, "装备已穿戴") then return end
            context_.requestPageRefresh()
            -- Delta is authoritative; this snapshot only covers a dropped
            -- delta so the equipment page cannot remain visually stale.
            ServerClient.RequestSnapshot()
        end)
    end

    if item.tradeable ~= true then
        EquipConfirmed()
        return
    end

    print("[EquipmentTrade] showing bind confirmation itemId=" .. tostring(item.id))
    CommonPromptDialog.Show {
        kind = "equipment",
        priority = 420,
        queueKey = "equip_tradeable:" .. tostring(item.id),
        title = "确认装配可交易装备",
        message = tostring(item.name or "该装备") .. "装配后将永久变为不可交易装备。",
        lines = {
            "该变化不可撤销。",
            "卸下或撤销换装后也不会恢复可交易状态。",
        },
        closeOnOverlay = false,
        showClose = true,
        cancelText = "取消",
        confirmText = "确认装配",
        onConfirm = EquipConfirmed,
    }
end
actionFns_.UnequipSlot = function(slotId)
    if slotId then
        context_.inventoryState.selectedSlot = slotId
        ServerClient.Unequip(slotId, context_.actionResult)
    end
end
actionFns_.AutoEquipBest = function()
    print("[Equip] AutoEquipBest clicked")
    ServerClient.AutoEquip(function(response)
        print(string.format(
            "[Equip] AutoEquip response ok=%s committed=%s code=%s",
            tostring(response and response.ok),
            tostring(response and response.data and response.data.committed),
            tostring(response and response.code)
        ))
        if response and response.ok then
            -- NoCommit 时 committed=false：当前已是最优搭配。
            local committed = response.data and response.data.committed == true
            if not committed then
                UI.Toast.Show("当前已是最高战力搭配", {
                    duration = 2.0,
                    variant = "info",
                    position = "bottom",
                })
                if context_.requestPageRefresh then context_.requestPageRefresh() end
                return
            end
            if not context_.actionResult(response, "已自动穿戴最高战力装备") then return end
            if context_.requestPageRefresh then context_.requestPageRefresh() end
            ServerClient.RequestSnapshot()
            return
        end
        context_.actionResult(response)
    end)
end
actionFns_.DecomposeByFilter = function()
    local filter = EquipmentRecycleFilter.Get("decompose")
    local maximumRank = EquipmentRecycleFilter.MaxSelectedRank("decompose")
    local items = CollectDecomposeCandidateItems(filter)
    if #items == 0 then
        UI.Toast.Show("没有符合条件的未锁定、未穿戴装备", { duration = 1.8, variant = "info", position = "bottom" })
        return
    end
    local tutorialSelection = IsTutorialDecomposeStep()
    local selected = {}
    for _, item in ipairs(items) do selected[item.id] = not tutorialSelection end
    local refunds = {}
    local totalGoldText, totalFragText, headerCountText
    local cellRefs = {}

    local function RecomputeTotals()
        local gold = LargeNumber.Zero()
        local frag = 0
        for _, item in ipairs(items) do
            if selected[item.id] then
                local r = refunds[item.id]
                if r then
                    gold = LargeNumber.Add(gold, r.gold or 0)
                    frag = frag + (r.fragments or 0)
                end
            end
        end
        return gold, frag
    end

    local function SelectedCount()
        local n = 0
        for _, item in ipairs(items) do
            if selected[item.id] then n = n + 1 end
        end
        return n
    end

    local function UpdateTotalsInPlace()
        local gold, frag = RecomputeTotals()
        if totalGoldText then totalGoldText:SetText("+" .. Kit.FormatInt(gold)) end
        if totalFragText then totalFragText:SetText("+" .. Kit.FormatInt(frag)) end
        if headerCountText then
            headerCountText:SetText("即将分解 " .. tostring(SelectedCount()) .. " / "
                .. tostring(#items) .. " 件装备（筛选："
                .. EquipmentRecycleFilter.Summary("decompose") .. "）")
        end
    end

    local function UpdateCellInPlace(itemId)
        local ref = cellRefs[itemId]
        -- 虚拟网格行池化复用：不在当前绑定行中的卡片可能已被销毁，跳过并清理引用。
        if not ref or ref.cell.parent == nil then
            cellRefs[itemId] = nil
            return
        end
        local on = selected[itemId]
        ref.cell:SetBackgroundColor(on and { 30, 90, 150, 120 } or { 12, 22, 40, 120 })
        if tutorialSelection then
            ref.cell:SetBorderColor(C.focus)
        else
            ref.cell:SetBorderColor(on and C.focus or C.border)
        end
        ref.label:SetText(on and "✓ 已选择" or "○ 未选择")
        ref.label:SetFontColor(on and C.success or C.textDim)
    end

    local function DoDecompose()
        local ids = {}
        for _, item in ipairs(items) do
            if selected[item.id] then ids[#ids + 1] = item.id end
        end
        if #ids == 0 then
            UI.Toast.Show("请至少选择一件装备", { duration = 1.6, variant = "info", position = "bottom" })
            return false
        end
        ServerClient.Decompose(maximumRank, ids, function(response)
            if not (response and response.ok) then
                context_.actionResult(response)
                return
            end
            local reward = response.data and response.data.reward or {}
            local gold = reward.gold or 0
            local frag = reward.fragments or 0
            local count = reward.count or #ids
            context_.requestPageRefresh()
            UI.Toast.Show("分解成功", { duration = 2.0, variant = "success", position = "bottom" })
            ShowDecomposeRewardDialog(gold, frag, count)
        end)
    end

    -- 分解候选虚拟网格：行池化复用，替代全量 gridChildren + flexWrap ScrollView。
    -- 弹窗每次打开重建，无需保存滚动位置。
    local decomposeGrid = GridVirtualList.Build {
        columns = 3,
        cardWidth = 186,
        cardHeight = 216,
        cardGap = 12,
        rowGap = 12,
        -- content 高度 660 - headerCountText 36 - 底部结算条 64 - 两个 gap 24 = 536。
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
            local label = Kit.CompactTxt(selected[item.id] and "✓ 已选择" or "○ 未选择", 15,
                selected[item.id] and C.success or C.textDim, {
                    width = "100%", height = 22, textAlign = "center",
                    textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                })
            local card = RewardDialogView.BuildItemCard(
                ItemView.ItemImage(item),
                item.name or "装备",
                nil,
                item.rarity or "common",
                item
            )
            card:SetProp("pointerEvents", "none")
            local cell = UI.Panel {
                -- 构造时写入 id，确保引导层能立刻按 id 命中（后写 props.id 不更新 instance.id）
                id = tutorialSelection
                    and ("tutorialDispositionCandidate:" .. tostring(item.id))
                    or nil,
                width = 186,
                height = 216,
                flexShrink = 0,
                clickable = true,
                alignItems = "center",
                justifyContent = "center",
                gap = 4,
                paddingTop = 6,
                paddingBottom = 6,
                backgroundColor = selected[item.id] and { 30, 90, 150, 120 } or { 12, 22, 40, 120 },
                borderWidth = tutorialSelection and 4 or 2,
                borderColor = tutorialSelection
                    and C.focus
                    or (selected[item.id] and C.focus or C.border),
                borderRadius = 10,
                onClick = function()
                    -- 行会被池化复用：点击时从当前绑定读取 item，禁止闭包捕获 bind 参数。
                    local currentItem = row._boundItems[slotIndex]
                    if not currentItem then return end
                    selected[currentItem.id] = not selected[currentItem.id]
                    UpdateCellInPlace(currentItem.id)
                    UpdateTotalsInPlace()
                    if tutorialSelection then
                        require("client.TutorialController").SetDispositionSelected(
                            selected[currentItem.id] == true
                        )
                    end
                end,
                children = {
                    card,
                    label,
                },
            }
            cellRefs[item.id] = { cell = cell, label = label }
            return cell
        end,
    }

    local gold0, frag0 = RecomputeTotals()
    totalGoldText = Kit.CompactTxt("+" .. Kit.FormatInt(gold0), 24, C.gold, {
        width = 200, height = 34, textAlign = "right",
        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
    })
    totalFragText = Kit.CompactTxt("+" .. Kit.FormatInt(frag0), 24, C.secondary, {
        width = 200, height = 34, textAlign = "right",
        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
    })
    headerCountText = Kit.CompactTxt(
        "即将分解 " .. tostring(SelectedCount()) .. " / " .. tostring(#items)
            .. " 件装备（筛选：" .. EquipmentRecycleFilter.Summary("decompose") .. "）",
        24, C.text, {
            width = "100%", height = 36, textAlign = "center",
            textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
        })

    local content = UI.Panel {
        width = "100%",
        height = 660,
        flexShrink = 0,
        gap = 12,
        children = {
            headerCountText,
            decomposeGrid,
            UI.Panel {
                width = "100%",
                height = 64,
                flexShrink = 0,
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "center",
                gap = 32,
                paddingTop = 10,
                borderTopWidth = 2,
                borderColor = C.border,
                children = {
                    Kit.CompactTxt("分解总获得", 21, C.text, {
                        width = 150, height = 34, textAlign = "left",
                        textStroke = { width = 1, color = "#000000" }, pointerEvents = "none",
                    }),
                    UI.Panel {
                        width = 200, height = 44, flexShrink = 0,
                        flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 8,
                        children = {
                            UI.Panel { width = 36, height = 36, flexShrink = 0, backgroundImage = ASSETS.items.gold, backgroundFit = "contain" },
                            totalGoldText,
                        },
                    },
                    UI.Panel {
                        width = 200, height = 44, flexShrink = 0,
                        flexDirection = "row", alignItems = "center", justifyContent = "center", gap = 8,
                        children = {
                            UI.Panel { width = 36, height = 36, flexShrink = 0, backgroundImage = ASSETS.items.crystal, backgroundFit = "contain" },
                            totalFragText,
                        },
                    },
                },
            },
        },
    }

    if tutorialSelection then
        local ok, TutorialController = pcall(require, "client.TutorialController")
        if ok and TutorialController and TutorialController.NotifyAction then
            TutorialController.NotifyAction("decompose_open")
        end
    end
    CommonPromptDialog.Show {
        kind = "confirm",
        priority = 150,
        queueKey = "decompose-preview",
        title = "分解预览",
        dialogWidth = 900,
        dialogHeight = 1040,
        message = nil,
        lines = { "点击卡片可取消选择；分解完成后无法撤销。" },
        cancelText = "取消",
        confirmText = "确认分解",
        danger = true,
        closeOnOverlay = false,
        -- 引导层 3900；弹窗 3850。可点性由输入白名单控制。
        zIndex = 3850,
        tutorialConfirmId = tutorialSelection and "tutorialDispositionConfirm" or nil,
        bodyScrollY = false,
        content = content,
        onConfirm = DoDecompose,
        onPresented = function()
            if not tutorialSelection then return end
            local ok, TutorialController = pcall(require, "client.TutorialController")
            if ok and TutorialController and TutorialController.NotifyAction then
                TutorialController.NotifyAction("decompose_dialog_ready")
            end
        end,
    }

    for _, item in ipairs(items) do
        ServerClient.DecomposePreview(item.id, function(response)
            if response and response.ok and type(response.data) == "table" then
                refunds[item.id] = {
                    gold = response.data.gold or 0,
                    fragments = response.data.fragments or 0,
                    rate = response.data.rate or 0,
                }
                UpdateTotalsInPlace()
            end
        end)
    end
end
actionFns_.SetEquipmentLock = function(item)
    ServerClient.SetEquipmentLock(item.id, not item.locked, function(response)
        if not context_.actionResult(response, item.locked and "装备已解锁" or "装备已锁定") then return end
        context_.requestPageRefresh()
    end)
end
actionFns_.SetInventoryPolicy = function(policy) ServerClient.SetInventoryPolicy(policy, context_.actionResult) end
actionFns_.StrengthenSelected = function()
    local slotId = ResolveUpgradeSlot(true)
    if not slotId then
        UI.Toast.Show("请先选择一个已穿戴的装备部位", {
            duration = 2.0,
            variant = "warning",
            position = "bottom",
        })
        return
    end
    local game = context_.getGame()
    if not (game and game.equipped and game.equipped[slotId]) then
        UI.Toast.Show("该部位没有已穿戴装备，无法强化", {
            duration = 2.0,
            variant = "warning",
            position = "bottom",
        })
        return
    end
    ServerClient.StrengthenPreview(slotId, function(response)
        if not response or not response.ok or type(response.data) ~= "table" then
            context_.actionResult(response)
            return
        end
        local preview = response.data
        if preview.canStrengthen == false and not preview.atMax
            and game.tutorial and game.tutorial.completed == true then
            require("client.AdGiftController").Show("forge")
            return
        end
        local content = UI.Panel {
            width = "100%",
            height = 300,
            flexShrink = 0,
            alignItems = "center",
            gap = 10,
            children = {
                Kit.CompactTxt(
                    "+" .. tostring(preview.currentEnhance or 0)
                        .. "  →  +" .. tostring(preview.nextEnhance or 0),
                    28,
                    preview.atMax and C.error or C.gold,
                    {
                        width = "100%",
                        height = 42,
                        textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                    }
                ),
                Kit.CompactTxt(
                    preview.atMax and ("已达到强化上限 +" .. tostring(preview.enhanceLimit))
                        or (preview.tutorialFree and "塔灵助力：本次教学强化免费" or "强化所需材料"),
                    20,
                    preview.atMax and C.error or C.textSecondary,
                    { width = "100%", height = 30, textAlign = "center" }
                ),
                UI.Panel {
                    width = "100%",
                    height = 176,
                    flexDirection = "row",
                    justifyContent = "center",
                    gap = 28,
                    children = {
                        Kit.BuildCostItemCard(
                            "金币",
                            ASSETS.items.gold,
                            preview.goldOwned,
                            preview.gold,
                            preview.goldEnough == true
                        ),
                        Kit.BuildCostItemCard(
                            "装备碎片",
                            ASSETS.items.crystal,
                            preview.fragmentsOwned,
                            preview.fragments,
                            preview.fragmentsEnough == true
                        ),
                    },
                },
            },
        }
        local tutorialStrengthen = (function()
            local TutorialController = require("client.TutorialController")
            if TutorialController.IsActive
                and TutorialController.IsActive()
                and TutorialController.GetStep
                and TutorialController.GetStep() == 4
            then
                return true
            end
            local currentGame = context_.getGame()
            return currentGame.tutorial and currentGame.tutorial.completed ~= true
                and tonumber(currentGame.tutorial.step) == 4
        end)()
        if tutorialStrengthen then
            local TutorialController = require("client.TutorialController")
            if TutorialController.NotifyAction then
                -- 预览回调返回时强制进入确认子步骤，避免异步窗口挂载后仍停在第 1 子步。
                TutorialController.NotifyAction("strengthen_open")
            end
        end
        CommonPromptDialog.Show {
            kind = "confirm",
            queueKey = "equipment-strengthen",
            title = "确认强化",
            content = content,
            dialogWidth = 900,
            dialogHeight = 640,
            bodyTop = 86,
            bodyHeight = 380,
            bodyScrollY = false,
            buttonTop = 532,
            cancelText = "取消",
            confirmText = "确认强化",
            confirmEnabled = preview.canStrengthen == true,
            closeOnOverlay = false,
            -- 引导层 3900；弹窗 3850。可点性由输入白名单控制。
            zIndex = 3850,
            tutorialConfirmId = tutorialStrengthen and "tutorialStrengthenConfirm" or nil,
            onConfirm = function()
                ServerClient.Strengthen(slotId, function(result)
                    context_.actionResult(result, "强化成功")
                    if result and result.ok then context_.requestPageRefresh() end
                end)
            end,
            onPresented = function()
                if not tutorialStrengthen then return end
                local TutorialController = require("client.TutorialController")
                if TutorialController.NotifyAction then
                    TutorialController.NotifyAction("strengthen_dialog_ready")
                end
            end,
        }
    end)
end
actionFns_.StarSelected = function()
    local slotId = ResolveUpgradeSlot(false)
    if not slotId then
        UI.Toast.Show("请先选择一个已穿戴的装备部位", {
            duration = 2.0,
            variant = "warning",
            position = "bottom",
        })
        return
    end
    local game = context_.getGame()
    if not (game and game.equipped and game.equipped[slotId]) then
        UI.Toast.Show("该部位没有已穿戴装备，无法升星", {
            duration = 2.0,
            variant = "warning",
            position = "bottom",
        })
        return
    end
    ServerClient.StarPreview(slotId, function(response)
        if not response or not response.ok or type(response.data) ~= "table" then
            context_.actionResult(response)
            return
        end
        local preview = response.data
        local materials = type(preview.materials) == "table" and preview.materials or {}
        local selectedMaterialId = materials[1] and materials[1].itemId or nil
        local materialContext = {
            C = C,
            ASSETS = ASSETS,
            itemImage = ItemView.ItemImage,
            itemLevelText = ItemView.ItemLevelText,
            compactTxt = Kit.CompactTxt,
            rarityColor = ItemView.RarityColor,
            shortenText = Kit.ShortenText,
            isEquipped = function() return false end,
            showItemTips = ItemTips.Show,
            registerItemTipsTrigger = ItemTips.RegisterTrigger,
        }
        local starContent = UI.Panel {
            width = "100%",
            height = 562,
            flexShrink = 0,
            alignItems = "center",
            gap = 8,
        }

        local function RebuildStarContent()
            starContent:ClearChildren()
            local selectedMaterial = nil
            for _, candidate in ipairs(materials) do
                if tostring(candidate.itemId) == tostring(selectedMaterialId) then
                    selectedMaterial = candidate
                    break
                end
            end
            local duplicateCount = preview.duplicateCount or 1
            local materialOwned = preview.materialOwned or #materials
            local materialEnough = materialOwned >= duplicateCount
            local materialSlot = ItemSlotBase.Build(materialContext, selectedMaterial, {
                size = 106,
                selected = selectedMaterial ~= nil,
                showEquipped = false,
            })

            starContent:AddChild(Kit.CompactTxt(
                tostring(preview.currentStar or 0)
                    .. " 星  →  " .. tostring(preview.nextStar or 0) .. " 星",
                28,
                preview.atMax and C.error or C.gold,
                {
                    width = "100%",
                    height = 40,
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                }
            ))
            starContent:AddChild(Kit.CompactTxt(
                preview.atMax and "已达到最高星级" or "升星所需材料",
                20,
                preview.atMax and C.error or C.textSecondary,
                { width = "100%", height = 28, textAlign = "center" }
            ))
            starContent:AddChild(UI.Panel {
                width = "100%",
                height = 176,
                flexDirection = "row",
                justifyContent = "center",
                gap = 18,
                children = {
                    Kit.BuildCostItemCard(
                        "金币",
                        ASSETS.items.gold,
                        preview.goldOwned,
                        preview.gold,
                        preview.goldEnough == true,
                        { width = 170 }
                    ),
                    Kit.BuildCostItemCard(
                        "装备碎片",
                        ASSETS.items.crystal,
                        preview.fragmentsOwned,
                        preview.fragments,
                        preview.fragmentsEnough == true,
                        { width = 170 }
                    ),
                    Kit.BuildCostItemCard(
                        "同款装备",
                        nil,
                        materialOwned,
                        duplicateCount,
                        materialEnough,
                        { width = 170, itemSlot = materialSlot }
                    ),
                },
            })
            starContent:AddChild(Kit.CompactTxt(
                #materials > 1 and "选择要消耗的同款、同星级、同品阶装备" or "升星装备材料",
                19,
                #materials > 0 and C.textSecondary or C.error,
                { width = "100%", height = 28, textAlign = "center" }
            ))

            if #materials == 0 then
                starContent:AddChild(UI.Panel {
                    width = 128,
                    height = 128,
                    position = "relative",
                    children = {
                        ItemSlotBase.Build(materialContext, nil, { size = 124 }),
                        Kit.CompactTxt("缺少", 20, C.error, {
                            position = "absolute",
                            left = 0,
                            top = 45,
                            width = 124,
                            height = 34,
                            textAlign = "center",
                            textStroke = { width = 2, color = "#000000" },
                        }),
                    },
                })
            else
                local cards = {}
                for _, candidate in ipairs(materials) do
                    local material = candidate
                    local selected = tostring(material.itemId) == tostring(selectedMaterialId)
                    cards[#cards + 1] = BackpackItemSlot.Build(materialContext, material, {
                        width = 132,
                        height = 146,
                        selected = selected,
                        clickable = true,
                        showEquipped = false,
                        amountText = selected and "已选择" or "点击选择",
                        onClick = function()
                            selectedMaterialId = material.itemId
                            RebuildStarContent()
                        end,
                    })
                end
                starContent:AddChild(UI.ScrollView {
                    width = "100%",
                    height = 150,
                    scrollX = true,
                    scrollY = false,
                    showScrollbar = false,
                    children = {
                        UI.Panel {
                            height = 146,
                            flexDirection = "row",
                            gap = 10,
                            justifyContent = #cards <= 5 and "center" or "flex-start",
                            children = cards,
                        },
                    },
                })
            end
        end
        RebuildStarContent()

        CommonPromptDialog.Show {
            kind = "confirm",
            title = "确认升星",
            content = starContent,
            dialogWidth = 900,
            dialogHeight = 860,
            bodyTop = 82,
            bodyHeight = 638,
            bodyScrollY = false,
            buttonTop = 752,
            cancelText = "取消",
            confirmText = "确认升星",
            confirmEnabled = preview.canStar == true and selectedMaterialId ~= nil,
            danger = true,
            closeOnOverlay = false,
            onConfirm = function()
                ServerClient.Star(slotId, selectedMaterialId, function(result)
                    context_.actionResult(result, "升星成功")
                    if result and result.ok then context_.requestPageRefresh() end
                end)
            end,
        }
    end)
end

function EquipmentActionController.Configure(context)
    context_ = assert(context)
    return actionFns_
end

return EquipmentActionController
