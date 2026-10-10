local UI = require("urhox-libs/UI")
local Video = require("urhox-libs/Video")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local GameStateAdapter = require("client.GameStateAdapter")
local ServerClient = require("client.ServerClient")
local NavigationController = require("client.NavigationController")
local UILayout = require("client.UI.UILayout")
local CampaignCatalog = require("shared.CampaignCatalog")
local LoadingController = require("client.LoadingController")

local CampaignView = {}
local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS
local LAYER_Z = UILayout.Z.blocking

local root_ = nil
local detailLayer_ = nil
local detailStageId_ = nil
local videoLayer_ = nil
local videoPlayer_ = nil
local requestPending_ = false
local generation_ = 0
local pageRoot_ = nil
local battleLayer_ = nil
local battleView_ = nil
local refreshChapters_ = nil

-- 边界合同（设计宽 1080）：背景 1080x1920 为无边框场景，cover。
-- panelLarge assetRect/visualOuterRect=940x320，contentRect=(24,24,892,272)；
-- panelCompact=940x180，contentRect=(24,24,892,132)。12px 九宫格保留边线，
-- 内容统一内缩 24px；章节容器→标题/摘要/关卡，详情→固定标题/裁剪正文/固定双行操作。
local PAGE = { inset = 30, gap = 16, headerHeight = 180, chapterHeight = 308, cardHeight = 146 }
local DETAIL = { padding = 28, headerHeight = 100, footerHeight = 168 }


local function Toast(message, variant)
    UI.Toast.Show(tostring(message), { duration = 2.5, variant = variant or "info", position = "bottom" })
end

local function RemoveNode(node)
    if node and node.parent then node.parent:RemoveChild(node) end
end

local function ClearVideo()
    generation_ = generation_ + 1
    if videoPlayer_ and videoPlayer_.Destroy then pcall(videoPlayer_.Destroy, videoPlayer_) end
    videoPlayer_ = nil
    if videoLayer_ then videoLayer_:Destroy() end
    videoLayer_ = nil
end

local function ClearBattle()
    if battleView_ then battleView_:Destroy() end
    battleView_ = nil
    RemoveNode(battleLayer_)
    battleLayer_ = nil
end

local function ClearDetail()
    if detailStageId_ then LoadingController.CancelPrefetch("chapter:" .. detailStageId_) end
    ClearBattle()
    RemoveNode(detailLayer_)
    detailLayer_ = nil
    detailStageId_ = nil
    ClearVideo()
end

local function IsComplete(game, stageId)
    local campaign = game and game.campaign
    return type(campaign) == "table"
        and type(campaign.completedStages) == "table"
        and campaign.completedStages[stageId] ~= nil
end

local function IsAvailable(game, stage)
    if not stage then return false end
    local campaign = game.campaign or {}
    return (tonumber(game.level) or 1) >= stage.recommendedLevel
end

local function PlayVideo(stage, onDone)
    if not stage.video or not stage.video.src or not root_ then
        if onDone then onDone() end
        return
    end
    ClearVideo()
    local token = generation_
    local finished = false
    local function Finish()
        if finished or token ~= generation_ then return end
        finished = true
        ClearVideo()
        if onDone then onDone() end
    end
    if detailLayer_ then detailLayer_:Hide() end
    LoadingController.EnsureMediaReady("chapter:" .. stage.id, {stage.video.src}, function()
        if token ~= generation_ or not root_ then return end
        if detailLayer_ then detailLayer_:Show() end
        videoLayer_ = UI.Panel {
            position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
            zIndex = LAYER_Z + 200,
            clickable = true,
            backgroundColor = { 4, 8, 18, 250 },
            children = {
                Video.VideoPlayer {
                    id = "campaignVideo",
                    width = "100%", height = "100%",
                    src = stage.video.src,
                    autoPlay = true, loop = false, muted = false, volume = 1.0,
                    objectFit = "cover",
                    backgroundColor = { 4, 8, 18, 255 },
                    clickable = false, pointerEvents = "none",
                    onReady = function(self) videoPlayer_ = self end,
                    onEnded = Finish,
                },
                UILayout.SafeContent {
                    UI.Panel {
                        position = "absolute", right = 36, top = 48,
                        width = 180, height = 72,
                        clickable = true,
                        backgroundImage = ASSETS.ui.buttonBlue,
                        backgroundFit = "contain",
                        onClick = Finish,
                        children = { Kit.CompactTxt("跳过", 20, C.text, { width = "100%", height = 72, textAlign = "center", pointerEvents = "none" }) },
                    },
                },
            },
        }
        root_:AddChild(videoLayer_)
    end)
end

local ShowStage

local function MechanicText(stage)
    local mechanic = stage.mechanic
    if mechanic == "clear_minions" then return "目标：击破 3 个无名影卒" end
    if mechanic == "gatekeeper" then
        return "目标：击破 3 个无名影卒，再击败守门人"
    end
    if mechanic == "mirror" then return "机制：镜像会复制你的攻击节奏，更换节奏可打破镜像" end
    if mechanic == "lamps" then return "机制：保护 3 盏灯，失去灯火会强化 Boss" end
    if mechanic == "true_voice" then return "机制：识别真实声音，错误攻击会恢复 Boss 护盾" end
    if mechanic == "oathbreak" then return "机制：旧约会记录你的攻击，连续同节奏会被反制" end
    return stage.kind == "story" and "剧情独立于登塔，完成章节可获得经验与成长奖励" or "独立剧情战斗，三星条件计入周常"
end

local function StartBattle(stage)
    ClearBattle()
    local openedDetail = detailLayer_
    local replay = IsComplete(GameStateAdapter.GetViewState(), stage.id)
    local token = generation_
    if detailLayer_ then detailLayer_:Hide() end
    LoadingController.EnsurePlayAssetsReady(function()
        if token ~= generation_ or detailLayer_ ~= openedDetail or not root_ then return end
        if detailLayer_ then detailLayer_:Show() end
        battleLayer_ = UI.Panel {
            position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
            zIndex = LAYER_Z + 160, clickable = true,
            backgroundImage = ASSETS.ui.bg, backgroundFit = "cover",
        }
        root_:AddChild(battleLayer_)
        battleView_ = require("client.CampaignBattleView").Create(stage, function()
            ClearDetail()
        end, function(result)
            if refreshChapters_ then refreshChapters_() end
            if result and result.won and replay and detailLayer_ == openedDetail then ClearDetail() end
        end)
        battleLayer_:AddChild(UILayout.SafeContent({
            UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, minHeight = 0, children = { battleView_.root } },
        }, { extraTop = 0 }))
    end)
end

ShowStage = function(stage)
    if not root_ or not stage then return end
    ClearDetail()
    local media = {}
    if stage.illustration and stage.illustration.src then media[#media + 1] = stage.illustration.src end
    if stage.video and stage.video.src then media[#media + 1] = stage.video.src end
    LoadingController.PrefetchMedia("chapter:" .. stage.id, media)
    local game = GameStateAdapter.GetViewState()
    local available = IsAvailable(game, stage)
    local complete = IsComplete(game, stage.id)
    local record = game.campaign and game.campaign.completedStages and game.campaign.completedStages[stage.id]
    local bestStars = record and record.bestStars or 0
    local body = {}
    if stage.illustration then
        body[#body + 1] = UI.Panel {
            width = "100%", height = 340, flexShrink = 0,
            backgroundImage = stage.illustration.src, backgroundFit = "contain",
        }
        body[#body + 1] = Kit.MultiTxt(stage.illustration.narration or "", 20, C.textSecondary, { textAlign = "center" })
    end
    body[#body + 1] = Kit.MultiTxt(table.concat(stage.lines or {}, "\n\n"), 24, C.text, { lineHeight = 1.5 })
    for _, line in ipairs(stage.dialogue or {}) do
        body[#body + 1] = UI.Panel {
            width = "100%", flexShrink = 0, gap = 8, padding = 24,
            backgroundImage = ASSETS.ui.panelCompact, backgroundFit = "sliced", backgroundSlice = { 12, 12, 12, 12 },
            children = {
                Kit.CompactTxt(tostring(line.speaker or ""), 20, line.speaker == "你" and C.focus or C.gold, { height = 30 }),
                Kit.MultiTxt(tostring(line.text or ""), 23, C.text, { lineHeight = 1.4 }),
            },
        }
    end
    if stage.kind ~= "story" then
        body[#body + 1] = Kit.MultiTxt(MechanicText(stage), 20, C.focus)
        local conditions = {}
        for _, star in ipairs(stage.stars or {}) do conditions[#conditions + 1] = "· " .. star.desc end
        body[#body + 1] = Kit.MultiTxt("三星目标\n" .. table.concat(conditions, "\n"), 20, C.textSecondary)
    end
    body[#body + 1] = Kit.MultiTxt("首通奖励  ·  经验 " .. tostring(stage.exp) .. "  /  金币 " .. tostring(stage.gold) .. "  /  碎片 " .. tostring(stage.fragments), 20, C.gold)
    if not available then
        body[#body + 1] = Kit.MultiTxt("达到推荐等级即可挑战，本关没有剧情前置。", 20, C.textDim)
    end
    body[#body + 1] = Kit.MultiTxt("每日回响 · 已通关关卡的每日补给\n每日从已完成小节中选出最多 3 节，每节可领取一次约首通 20% 的金币、经验和碎片，无需战斗，不含装备。每日 0 点（北京时间）刷新；未入选关卡不能领取。", 18, C.textSecondary, { lineHeight = 1.4 })
    local actionText = complete and "再次挑战" or "开始挑战"
    local function RequestReward(mode)
        if requestPending_ then return end
        requestPending_ = true
        local openedDetail = detailLayer_
        ServerClient.CampaignPlayStage(stage.id, mode, function(response)
            requestPending_ = false
            if response and response.ok then
                Toast(mode == "sweep" and "扫荡完成，基础材料已发放" or "每日回响奖励已领取", "success")
                if refreshChapters_ then refreshChapters_() end
                if detailLayer_ == openedDetail then ShowStage(stage) end
            else
                Toast((response and response.reason) or "暂时无法领取", "warning")
            end
        end)
    end
    local secondaryActions = {}
    if complete then
        secondaryActions[#secondaryActions + 1] = Kit.ActionButton {
            variant = "reward", text = "扫荡", width = 240, onClick = function() RequestReward("sweep") end,
        }
    end
    -- 显式追加，避免未通关时 children 中间的 nil 吞掉后面的回响按钮。
    secondaryActions[#secondaryActions + 1] = Kit.ActionButton {
        variant = "secondary", text = "每日回响", width = 240, onClick = function() RequestReward("echo") end,
    }
    local header = UI.Panel {
        id = "campaignDetailHeader", width = "100%", height = DETAIL.headerHeight, flexShrink = 0, gap = 8,
        children = {
            Kit.Txt(stage.title, 32, C.gold, { width = "100%", height = 48, textAlign = "center" }),
            Kit.CompactTxt("第 " .. tostring(stage.chapter) .. " 章  ·  " .. (stage.kind == "story" and "剧情记忆" or "回响战斗")
                .. "  ·  " .. (complete and ("已完成 / 最佳 " .. tostring(bestStars) .. " 星") or (available and "待完成" or "未解锁")),
                18, C.textSecondary, { width = "100%", height = 30, textAlign = "center" }),
        },
    }
    local footer = UI.Panel {
        id = "campaignDetailFooter", width = "100%", height = DETAIL.footerHeight, flexShrink = 0, gap = 12, paddingTop = 8,
        children = {
            UI.Panel { width = "100%", height = 72, flexShrink = 0, flexDirection = "row", justifyContent = "center", gap = 24, children = {
                Kit.ActionButton {
                    variant = "primary", text = actionText, width = 300,
                    disabled = not available,
                    onClick = function()
                        if requestPending_ or not available then return end
                        local openedDetail = detailLayer_
                        local afterVideo = function()
                            if detailLayer_ ~= openedDetail then return end
                            StartBattle(stage)
                        end
                        if stage.video then PlayVideo(stage, afterVideo) else afterVideo() end
                    end,
                },
                Kit.ActionButton { variant = "secondary", text = "返回章节", width = 240, onClick = ClearDetail },
            } },
            UI.Panel { width = "100%", height = 68, flexShrink = 0, flexDirection = "row", justifyContent = "center", gap = 24, children = secondaryActions },
        },
    }
    detailLayer_ = UI.Panel {
        position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        zIndex = LAYER_Z + 100, clickable = true,
        backgroundImage = ASSETS.ui.bg, backgroundFit = "cover", backgroundColor = { 5, 12, 28, 255 },
        children = {
            UILayout.SafeContent({
                UI.Panel {
                    id = "campaignDetailFrame", width = "92%", maxWidth = 980,
                    flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 0,
                    marginBottom = 24, padding = DETAIL.padding, gap = 12, overflow = "hidden",
                    backgroundImage = ASSETS.ui.panelLarge, backgroundFit = "sliced", backgroundSlice = { 12, 12, 12, 12 },
                    children = {
                        header,
                        UI.ScrollView {
                            id = "campaignDetailBody", width = "100%", flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 0,
                            overflow = "hidden", scrollY = true, scrollX = false, showScrollbar = true,
                            children = { UI.Panel { width = "100%", gap = 24, padding = 16, children = body } },
                        },
                        footer,
                    },
                },
            }, { extraTop = 12 }),
        },
    }
    require("client.UI.DialogSettingsAccess").Attach(detailLayer_)
    root_:AddChild(detailLayer_)
    detailStageId_ = stage.id
end

local function StageCard(game, stage)
    local complete = IsComplete(game, stage.id)
    local available = IsAvailable(game, stage)
    local color = complete and C.success or (available and C.focus or C.textDim)
    return UI.Panel {
        flexGrow = 1, flexBasis = 0, flexShrink = 1, minWidth = 0, height = PAGE.cardHeight,
        padding = 24, gap = 8, clickable = true, overflow = "hidden",
        backgroundImage = ASSETS.ui.panelCompact, backgroundFit = "sliced", backgroundSlice = { 12, 12, 12, 12 },
        opacity = available and 1 or 0.65,
        onClick = function() ShowStage(stage) end,
        children = {
            Kit.CompactTxt(stage.title, 22, color, { width = "100%", height = 30 }),
            Kit.CompactTxt((stage.kind == "story" and "剧情" or (stage.kind == "boss" and "首领" or "战斗"))
                .. "  ·  " .. (complete and "已完成" or (available and "可进入" or "未解锁")), 18, color, { width = "100%", height = 26 }),
            Kit.CompactTxt("推荐 Lv." .. tostring(stage.recommendedLevel) .. "  ·  经验 " .. tostring(stage.exp), 16, C.textSecondary, { width = "100%", height = 24 }),
        },
    }
end

local function ChapterRows(game)
    local highest = math.max(1, math.floor(tonumber(game.campaign and game.campaign.highestUnlockedChapter) or 1))
    local rows, nextStage = {}, nil
    for index, chapter in ipairs(CampaignCatalog.GetAllChapters()) do
        local unlocked = (tonumber(game.level) or 1) >= chapter.recommendedLevel
        local cards, completed = {}, 0
        for _, stage in ipairs(chapter.stages) do
            cards[#cards + 1] = StageCard(game, stage)
            if IsComplete(game, stage.id) then completed = completed + 1
            elseif not nextStage and IsAvailable(game, stage) then nextStage = stage end
        end
        rows[#rows + 1] = UI.Panel {
            width = "100%", height = PAGE.chapterHeight, flexShrink = 0, padding = 24, gap = 12, overflow = "hidden",
            backgroundImage = ASSETS.ui.panelLarge, backgroundFit = "sliced", backgroundSlice = { 12, 12, 12, 12 },
            opacity = unlocked and 1 or 0.68,
            children = {
                UI.Panel { width = "100%", height = 38, flexShrink = 0, flexDirection = "row", gap = 16, children = {
                    Kit.Txt(string.format("第 %02d 章 · %s", index, chapter.title), 26, unlocked and C.gold or C.textDim,
                        { flexGrow = 1, flexBasis = 0, minWidth = 0, height = 38 }),
                    Kit.CompactTxt(unlocked and (tostring(completed) .. " / " .. tostring(#cards) .. " 完成") or "未解锁", 18,
                        unlocked and C.success or C.textDim, { width = 150, height = 38, textAlign = "right" }),
                } },
                Kit.MultiTxt(chapter.summary, 20, C.textSecondary, { width = "100%", height = 52, overflow = "hidden" }),
                UI.Panel { width = "100%", height = PAGE.cardHeight, flexShrink = 0, flexDirection = "row", gap = 12, children = cards },
            },
        }
    end
    return rows, nextStage, highest
end

function CampaignView.UpdateBattle(dt)
    if battleView_ then battleView_:Update(dt) end
end

function CampaignView.BuildPage()
    local game = GameStateAdapter.GetViewState()
    local rows, nextStage, highest = ChapterRows(game)
    local chapterContent = UI.Panel { width = "100%", gap = PAGE.gap, paddingBottom = 24, children = rows }
    local progressLabel = Kit.CompactTxt("", 20, C.focus, { width = "100%", height = 32 })
    local function UpdateProgress()
        progressLabel:SetText(nextStage and ("下一段记忆  ·  " .. nextStage.title) or "全部记忆已归档，可重温已完成章节")
    end
    UpdateProgress()
    local function ProgressKey(state)
        local parts = { tostring(state.level or 1), tostring(state.campaign and state.campaign.highestUnlockedChapter or 1) }
        for _, chapter in ipairs(CampaignCatalog.GetAllChapters()) do
            for _, stage in ipairs(chapter.stages) do
                parts[#parts + 1] = IsComplete(state, stage.id) and "1" or "0"
            end
        end
        return table.concat(parts, ":")
    end
    local progressKey = ProgressKey(game)
    local function Refresh()
        local latest = GameStateAdapter.GetViewState()
        local key = ProgressKey(latest)
        if key == progressKey then return true end
        progressKey = key
        local updatedRows
        updatedRows, nextStage, highest = ChapterRows(latest)
        local oldRows = {}
        for _, row in ipairs(chapterContent.children) do oldRows[#oldRows + 1] = row end
        chapterContent:ClearChildren()
        for _, row in ipairs(oldRows) do row:Destroy() end
        for _, row in ipairs(updatedRows) do chapterContent:AddChild(row) end
        UpdateProgress()
        return true
    end
    refreshChapters_ = Refresh
    pageRoot_ = UI.Panel {
        width = "100%", height = "100%", overflow = "hidden",
        backgroundImage = ASSETS.ui.bg, backgroundFit = "cover",
        children = { UI.Panel { width = "100%", height = "100%", padding = PAGE.inset, gap = PAGE.gap, overflow = "hidden", children = {
            UI.Panel { id = "campaignHeader", width = "100%", height = PAGE.headerHeight, flexShrink = 0, gap = 12, children = {
                UI.Panel { width = "100%", height = 64, position = "relative", flexShrink = 0, children = {
                    Kit.BackButton { onClick = function() NavigationController.SwitchPage("home") end },
                    Kit.Txt("记忆闯关", 34, C.gold, { position = "absolute", left = 110, right = 0, top = 8, height = 48 }),
                } },
                UI.Panel { width = "100%", height = 80, flexShrink = 0, flexDirection = "row", gap = 24, alignItems = "center", children = {
                    UI.Panel { flexGrow = 1, flexBasis = 0, minWidth = 0, gap = 8, children = {
                        progressLabel,
                        Kit.CompactTxt("自由选关 · 叙事可选 · 首通奖励仅领取一次", 18, C.textSecondary, { width = "100%", height = 28 }),
                    } },
                    Kit.ActionButton { text = "推荐关卡", width = 240, onClick = function()
                        if nextStage then ShowStage(nextStage) else Toast("全部记忆已归档，可选择章节重温") end
                    end },
                } },
            } },
            UI.ScrollView {
                id = "campaignChapters", width = "100%", flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 0,
                overflow = "hidden", scrollY = true, scrollX = false, showScrollbar = true, children = { chapterContent },
            },
        } } },
    }
    local page = pageRoot_
    return {
        GetRoot = function() return page end,
        Update = Refresh,
        OnShow = Refresh,
        Destroy = function()
            ClearDetail()
            if refreshChapters_ == Refresh then refreshChapters_ = nil end
            if pageRoot_ == page then pageRoot_ = nil end
        end,
    }
end

function CampaignView.Show()
    NavigationController.SwitchPage("campaign")
    return true
end

function CampaignView.Close()
    ClearDetail()
end

-- Bind the reward to the exact detail instance: an old queued popup must not
-- close a different stage opened while its network response was in flight.
function CampaignView.GetRewardReturnHandler(stageId)
    if not detailLayer_ or detailStageId_ ~= stageId then return nil end
    local openedDetail = detailLayer_
    return function()
        if detailLayer_ ~= openedDetail then return end
        ClearDetail()
        if refreshChapters_ then refreshChapters_() end
    end
end

function CampaignView.IsOpen() return detailLayer_ ~= nil or GameStateAdapter.GetViewState().page == "campaign" end
function CampaignView.AttachRoot(root) root_ = root end
function CampaignView.Reset() ClearDetail(); root_ = nil; pageRoot_ = nil; refreshChapters_ = nil; requestPending_ = false end

return CampaignView
