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

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local EquipmentActionController = {}
local context_ = nil

local function CollectDecomposeCandidateItems(selection)
    local game = context_.getGame()
    selection = type(selection) == "table" and selection or {}
    local items = {}
    for _, item in ipairs(game.inventory or {}) do
        local rarityId = RarityCatalog.NormalizeId(item.rarity)
        if item.equipmentId and item.id ~= nil
            and selection[rarityId] == true
            and rarityId ~= "myth"
            and not item.locked and not item.aidLocked and not ItemView.IsEquipped(game, item) then
            items[#items + 1] = item
        end
    end
    return items
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
actionFns_.AutoEquipBest = function() ServerClient.AutoEquip(context_.actionResult) end
actionFns_.DecomposeByFilter = function()
    local filter = EquipmentRecycleFilter.Get("decompose")
    local maximumRank = EquipmentRecycleFilter.MaxSelectedRank("decompose")
    local items = CollectDecomposeCandidateItems(filter)
    if #items == 0 then
        UI.Toast.Show("没有符合条件的未锁定、未穿戴装备", { duration = 1.8, variant = "info", position = "bottom" })
        return
    end
    local selected = {}
    for _, item in ipairs(items) do selected[item.id] = true end
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
        if not ref then return end
        local on = selected[itemId]
        ref.cell:SetBackgroundColor(on and { 30, 90, 150, 120 } or { 12, 22, 40, 120 })
        ref.cell:SetBorderColor(on and C.focus or C.border)
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

    local gridChildren = {}
    for _, item in ipairs(items) do
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
            borderWidth = 2,
            borderColor = selected[item.id] and C.focus or C.border,
            borderRadius = 10,
            onClick = function()
                selected[item.id] = not selected[item.id]
                UpdateCellInPlace(item.id)
                UpdateTotalsInPlace()
            end,
            children = {
                card,
                label,
            },
        }
        cellRefs[item.id] = { cell = cell, label = label }
        gridChildren[#gridChildren + 1] = cell
    end

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
            UI.ScrollView {
                width = "100%",
                flexGrow = 1,
                flexBasis = 0,
                scrollX = false,
                scrollY = true,
                showScrollbar = false,
                children = {
                    UI.Panel {
                        width = "100%",
                        flexShrink = 0,
                        alignItems = "center",
                        paddingBottom = 12,
                        children = {
                            UI.Panel {
                                width = 582,
                                flexShrink = 0,
                                flexDirection = "row",
                                flexWrap = "wrap",
                                gap = 12,
                                justifyContent = "flex-start",
                                alignItems = "flex-start",
                                alignContent = "flex-start",
                                children = gridChildren,
                            },
                        },
                    },
                },
            },
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
        zIndex = 2500,
        bodyScrollY = false,
        content = content,
        onConfirm = DoDecompose,
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
    local slotId = context_.inventoryState.selectedSlot
    ServerClient.StrengthenPreview(slotId, function(response)
        if not response or not response.ok or type(response.data) ~= "table" then
            context_.actionResult(response)
            return
        end
        local preview = response.data
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
                    preview.atMax and "已达到当前强化上限" or "强化所需材料",
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
        CommonPromptDialog.Show {
            kind = "confirm",
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
            onConfirm = function()
                ServerClient.Strengthen(slotId, function(result)
                    context_.actionResult(result, "强化成功")
                    if result and result.ok then context_.requestPageRefresh() end
                end)
            end,
        }
    end)
end
actionFns_.StarSelected = function()
    local slotId = context_.inventoryState.selectedSlot
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
