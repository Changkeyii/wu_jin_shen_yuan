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

local CampaignView = {}
local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS
local LAYER_Z = UILayout.Z.blocking

local root_ = nil
local detailLayer_ = nil
local videoLayer_ = nil
local videoPlayer_ = nil
local requestPending_ = false
local generation_ = 0
local pageRoot_ = nil
local battleLayer_ = nil
local battleTimer_ = nil
local battleState_ = nil

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
    RemoveNode(videoLayer_)
    videoLayer_ = nil
end

local function ClearBattle()
    battleTimer_ = nil
    battleState_ = nil
    RemoveNode(battleLayer_)
    battleLayer_ = nil
end

local function ClearDetail()
    ClearBattle()
    RemoveNode(detailLayer_)
    detailLayer_ = nil
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
    local highest = math.max(1, math.floor(tonumber(campaign.highestUnlockedChapter) or 1))
    if stage.chapter > highest then return false end
    if stage.stage == "a" then return true end
    local previous = stage.stage == "b" and "a" or "b"
    return IsComplete(game, string.format("main:c%02d:%s", stage.chapter, previous))
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
    videoLayer_ = UI.Panel {
        position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        zIndex = UILayout.Z.blocking,
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
end

local function FinishStage(stage, callback)
    if requestPending_ then return end
    requestPending_ = true
    ServerClient.CampaignPlayStage(stage.id, stage.kind == "story" and "complete" or "challenge", function(response)
        requestPending_ = false
        if response and response.ok then
            Toast(stage.kind == "story" and "记忆已归档，下一段记录已开启" or "战斗胜利，成长奖励已发放", "success")
            if callback then callback(true, response) end
        else
            Toast((response and response.reason) or "服务器未接受本次挑战", "warning")
            if callback then callback(false, response) end
        end
    end)
end

local ShowStage

local function MechanicText(stage)
    local mechanic = stage.mechanic
    if mechanic == "clear_minions" or mechanic == "gatekeeper" then
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
    local game = GameStateAdapter.GetViewState()
    local stats = game.stats or {}
    local playerHp = math.max(40, tonumber(stats.hp) or tonumber(game.hp) or 40)
    local enemy = stage.enemy or { name = "记忆回响", hp = 120, atk = 10 }
    local enemyHp = math.max(40, tonumber(enemy.hp) or 120)
    battleState_ = {
        stage = stage,
        elapsed = 0,
        limit = math.max(20, tonumber(stage.timeLimit) or 90),
        playerHp = playerHp,
        playerMaxHp = playerHp,
        enemyHp = enemyHp,
        enemyMaxHp = enemyHp,
        finished = false,
        refs = {},
    }
    local hpLabel = Kit.CompactTxt("生命 " .. tostring(playerHp) .. " / " .. tostring(playerHp), 18, C.hp, { width = "100%", height = 28, textAlign = "center" })
    local enemyLabel = Kit.CompactTxt((enemy.name or "记忆回响") .. "  " .. tostring(enemyHp) .. " / " .. tostring(enemyHp), 20, C.gold, { width = "100%", height = 32, textAlign = "center" })
    local timeLabel = Kit.CompactTxt("剩余 90 秒", 18, C.focus, { width = "100%", height = 28, textAlign = "center" })
    local logLabel = Kit.MultiTxt("战斗开始", 17, C.textSecondary, { width = "100%", height = 80, textAlign = "center" })
    battleState_.refs.hp = hpLabel
    battleState_.refs.enemy = enemyLabel
    battleState_.refs.time = timeLabel
    battleState_.refs.log = logLabel
    battleLayer_ = UI.Panel {
        position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        zIndex = LAYER_Z + 160,
        clickable = true,
        backgroundColor = { 4, 8, 18, 248 },
        children = {
            UILayout.SafeContent({
                UI.Panel {
                    width = "100%", height = "100%", padding = 36, gap = 16, justifyContent = "space-between",
                    children = {
                        UI.Panel { width = "100%", flexShrink = 0, gap = 8, children = {
                            Kit.Txt(stage.title, 26, C.gold, { width = "100%", height = 42, textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
                            Kit.CompactTxt(MechanicText(stage), 17, C.textSecondary, { width = "100%", height = 28, textAlign = "center" }),
                            timeLabel,
                        } },
                        UI.Panel { width = "100%", flexGrow = 1, justifyContent = "center", alignItems = "center", gap = 12, children = {
                            enemyLabel,
                            UI.Panel { width = 720, height = 18, backgroundColor = { 40, 18, 18, 255 }, borderWidth = 2, borderColor = C.border, children = {
                                UI.Panel { id = "campaignEnemyHpFill", width = "100%", height = "100%", backgroundColor = C.hp },
                            } },
                            hpLabel,
                            logLabel,
                        } },
                        UI.Panel { width = "100%", flexShrink = 0, flexDirection = "row", justifyContent = "center", gap = 18, children = {
                            Kit.ActionButton { variant = "secondary", text = "撤退", width = 220, onClick = function()
                                ClearBattle()
                                Toast("已撤退，可再次挑战", "info")
                            end },
                        } },
                    },
                },
            }, { extraTop = 24 }),
        },
    }
    root_:AddChild(battleLayer_)
    local atk = math.max(8, tonumber(stats.atk) or 8)
    local def = math.max(1, tonumber(stats.def) or 1)
    local enemyAtk = math.max(4, tonumber(enemy.atk) or 8)
    local playerCd, enemyCd = 0, 0.4
    battleTimer_ = true
    local function TickBattle()
        if not battleState_ or battleState_.finished then return end
        local dt = 0.2
        battleState_.elapsed = battleState_.elapsed + dt
        playerCd = playerCd - dt
        enemyCd = enemyCd - dt
        if playerCd <= 0 then
            local damage = math.max(1, math.floor(atk - (enemy.def or 2) * 0.35))
            battleState_.enemyHp = math.max(0, battleState_.enemyHp - damage)
            playerCd = 1 / math.max(0.6, tonumber(stats.atkSpeed) or 1)
            if battleState_.refs.log then battleState_.refs.log:SetText("你造成 " .. tostring(damage) .. " 伤害") end
        end
        if battleState_.enemyHp > 0 and enemyCd <= 0 then
            local damage = math.max(1, math.floor(enemyAtk - def * 0.4))
            battleState_.playerHp = math.max(0, battleState_.playerHp - damage)
            enemyCd = 1.15
            if battleState_.refs.log then battleState_.refs.log:SetText((enemy.name or "敌人") .. "反击 " .. tostring(damage)) end
        end
        local remain = math.max(0, math.ceil(battleState_.limit - battleState_.elapsed))
        if battleState_.refs.time then battleState_.refs.time:SetText("剩余 " .. tostring(remain) .. " 秒") end
        if battleState_.refs.hp then battleState_.refs.hp:SetText("生命 " .. tostring(battleState_.playerHp) .. " / " .. tostring(battleState_.playerMaxHp)) end
        if battleState_.refs.enemy then
            battleState_.refs.enemy:SetText((enemy.name or "记忆回响") .. "  " .. tostring(battleState_.enemyHp) .. " / " .. tostring(battleState_.enemyMaxHp))
        end
        if battleState_.enemyHp <= 0 then
            battleState_.finished = true
            FinishStage(stage, function(ok)
                ClearBattle()
                if ok then ShowStage(stage) end
            end)
            return
        end
        if battleState_.playerHp <= 0 or battleState_.elapsed >= battleState_.limit then
            battleState_.finished = true
            ClearBattle()
            Toast("挑战失败，可再次挑战", "warning")
            ShowStage(stage)
        end
    end
    battleState_.tick = TickBattle
end

ShowStage = function(stage)
    if not root_ or not stage then return end
    ClearDetail()
    local game = GameStateAdapter.GetViewState()
    local available = IsAvailable(game, stage)
    local complete = IsComplete(game, stage.id)
    local record = game.campaign and game.campaign.completedStages and game.campaign.completedStages[stage.id]
    local bestStars = record and record.bestStars or 0
    ---@type any[]
    local body = {
        Kit.MultiTxt(table.concat(stage.lines or {}, "\n"), 20, C.textSecondary, { width = "100%", textAlign = "center" }),
    }
    if stage.illustration then
        body[#body + 1] = UI.Panel { width = 250, height = 300, flexShrink = 0, backgroundImage = stage.illustration.src, backgroundFit = "contain" }
        body[#body + 1] = Kit.MultiTxt(stage.illustration.narration or "", 17, C.textSecondary, { width = "100%", textAlign = "center" })
    end
    for _, line in ipairs(stage.dialogue or {}) do
        body[#body + 1] = Kit.MultiTxt(tostring(line.speaker or "") .. "：" .. tostring(line.text or ""), 18, line.speaker == "你" and C.focus or C.text, { width = "100%", textAlign = "center" })
    end
    body[#body + 1] = Kit.CompactTxt(MechanicText(stage), 17, C.focus, { width = "100%", textAlign = "center" })
    body[#body + 1] = Kit.CompactTxt("三星：" .. table.concat({
        (stage.stars and stage.stars[1] and stage.stars[1].desc) or "90 秒内通关",
        (stage.stars and stage.stars[2] and stage.stars[2].desc) or "生命值不低于 30%",
        (stage.stars and stage.stars[3] and stage.stars[3].desc) or "不使用塔灵援助",
    }, " / "), 16, C.textSecondary, { width = "100%", textAlign = "center" })
    body[#body + 1] = Kit.CompactTxt("首通奖励：EXP " .. tostring(stage.exp) .. " · 金币 " .. tostring(stage.gold) .. " · 碎片 " .. tostring(stage.fragments) .. "    最佳 " .. tostring(bestStars) .. " 星", 17, C.gold, { width = "100%", textAlign = "center" })
    local actionText = complete and (stage.kind == "story" and "再次阅读" or "再次挑战") or (stage.kind == "story" and "归档记忆" or "开始挑战")
    local header = UI.Panel {
        width = "100%", flexShrink = 0, height = 72, justifyContent = "center",
        children = {
            Kit.Txt(stage.title, 30, C.gold, { width = "100%", height = 48, textAlign = "center", textStroke = { width = 2, color = "#000000" } }),
        },
    }
    local footer = UI.Panel {
        width = "100%", flexShrink = 0, flexDirection = "row", justifyContent = "center", gap = 18, paddingTop = 12,
        children = {
            Kit.ActionButton {
                variant = "primary",
                text = actionText,
                width = 300,
                disabled = not available or requestPending_,
                onClick = function()
                    if not available then Toast("请先完成前置剧情", "warning"); return end
                    local afterVideo = function()
                        if stage.kind == "story" then
                            FinishStage(stage, function() ShowStage(stage) end)
                        else
                            StartBattle(stage)
                        end
                    end
                    if stage.video then PlayVideo(stage, afterVideo) else afterVideo() end
                end,
            },
            Kit.ActionButton { variant = "secondary", text = "返回章节", width = 220, onClick = ClearDetail },
            complete and Kit.ActionButton {
                variant = "reward",
                text = "扫荡",
                width = 180,
                onClick = function()
                    ServerClient.CampaignPlayStage(stage.id, "sweep", function(response)
                        if response and response.ok then
                            Toast("扫荡完成，基础材料已发放", "success")
                            ShowStage(stage)
                        else
                            Toast((response and response.reason) or "今日扫荡次数已用完", "warning")
                        end
                    end)
                end,
            } or nil,
            Kit.ActionButton {
                variant = "secondary",
                text = "回响",
                width = 180,
                onClick = function()
                    ServerClient.CampaignPlayStage(stage.id, "echo", function(response)
                        if response and response.ok then
                            Toast("每日回响奖励已领取", "success")
                            ShowStage(stage)
                        else
                            Toast((response and response.reason) or "今日回响未开放此关", "warning")
                        end
                    end)
                end,
            },
        },
    }
    detailLayer_ = UI.Panel {
        position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
        zIndex = LAYER_Z + 100,
        clickable = true,
        backgroundColor = { 5, 12, 28, 248 },
        children = {
            UILayout.SafeContent({
                UI.Panel {
                    width = "92%",
                    maxWidth = 980,
                    height = "100%",
                    padding = 28,
                    gap = 12,
                    backgroundImage = ASSETS.ui.panelLarge,
                    backgroundFit = "sliced",
                    backgroundSlice = { 12, 12, 12, 12 },
                    children = {
                        header,
                        UI.ScrollView {
                            width = "100%", flexGrow = 1, flexBasis = 0,
                            scrollY = true, scrollX = false, showScrollbar = false,
                            children = { UI.Panel { width = "100%", gap = 12, paddingBottom = 16, children = body } },
                        },
                        footer,
                    },
                },
            }, { extraTop = 12 }),
        },
    }
    root_:AddChild(detailLayer_)
end

local function StageCard(game, stage)
    local complete = IsComplete(game, stage.id)
    local available = IsAvailable(game, stage)
    local color = complete and C.success or (available and C.focus or C.textDim)
    return UI.Panel {
        width = 300, height = 112, flexShrink = 0,
        padding = 14, gap = 5, clickable = true,
        backgroundImage = ASSETS.ui.panelCompact, backgroundFit = "sliced", backgroundSlice = { 12, 12, 12, 12 },
        backgroundColor = available and { 20, 64, 135, 245 } or { 12, 24, 52, 230 },
        borderWidth = 2, borderColor = color, opacity = available and 1 or 0.65,
        onClick = function() ShowStage(stage) end,
        children = {
            Kit.Txt((complete and "✓ " or (available and "○ " or "锁 ")) .. stage.title, 19, color, { width = "100%", height = 30 }),
            Kit.CompactTxt(stage.kind == "story" and "剧情 · 插图 · 台词" or "战斗 · 快速挑战", 14, C.textSecondary, { width = "100%", height = 22 }),
            Kit.CompactTxt("推荐 Lv." .. tostring(stage.recommendedLevel) .. "  EXP " .. tostring(stage.exp), 13, C.textDim, { width = "100%", height = 20 }),
        },
    }
end

function CampaignView.UpdateBattle(dt)
    if battleState_ and battleState_.tick then
        battleState_._acc = (battleState_._acc or 0) + (dt or 0)
        while battleState_ and battleState_._acc >= 0.2 do
            battleState_._acc = battleState_._acc - 0.2
            battleState_.tick()
        end
    end
end

function CampaignView.BuildPage()
    local game = GameStateAdapter.GetViewState()
    local highest = math.max(1, math.floor(tonumber(game.campaign and game.campaign.highestUnlockedChapter) or 1))
    local rows = {}
    for index, chapter in ipairs(CampaignCatalog.GetAllChapters()) do
        local unlocked = index <= highest
        local cards = {}
        for _, stage in ipairs(chapter.stages) do cards[#cards + 1] = StageCard(game, stage) end
        rows[#rows + 1] = UI.Panel {
            width = "100%", height = 220, flexShrink = 0, padding = 18, gap = 10,
            backgroundImage = ASSETS.ui.panelLarge, backgroundFit = "sliced", backgroundSlice = { 12, 12, 12, 12 },
            backgroundColor = unlocked and { 16, 48, 105, 245 } or { 10, 20, 42, 235 },
            borderWidth = 2, borderColor = unlocked and C.primary or C.border, opacity = unlocked and 1 or 0.68,
            children = {
                UI.Panel { width = "100%", height = 38, flexShrink = 0, flexDirection = "row", justifyContent = "space-between", children = {
                    Kit.Txt(string.format("第 %02d 章 · %s", index, chapter.title), 23, unlocked and C.gold or C.textDim, { width = 650, height = 34 }),
                    Kit.CompactTxt(unlocked and "已开放" or "未开放", 15, unlocked and C.success or C.textDim, { width = 180, height = 28, textAlign = "right" }),
                } },
                Kit.MultiTxt(chapter.summary, 16, unlocked and C.textSecondary or C.textDim, { width = "100%", height = 38 }),
                UI.Panel { width = "100%", height = 112, flexShrink = 0, flexDirection = "row", gap = 12, children = cards },
            },
        }
    end
    pageRoot_ = UI.Panel {
        width = "100%", height = "100%", backgroundImage = ASSETS.ui.bg, backgroundFit = "cover", backgroundColor = { 7, 18, 42, 255 },
        children = { UI.Panel { width = "100%", height = "100%", padding = 30, gap = 14, children = {
            UI.Panel { width = "100%", height = 72, flexShrink = 0, flexDirection = "row", alignItems = "center", children = {
                Kit.BackButton { onClick = function() NavigationController.SwitchPage("home") end },
                Kit.Txt("万灵记忆", 32, C.gold, { width = 340, height = 48 }),
                Kit.CompactTxt("剧情独立于登塔 · 完成章节可获得经验与成长奖励", 16, C.textSecondary, { flexGrow = 1, height = 30, textAlign = "center" }),
                Kit.CompactTxt("已开放至第 " .. tostring(highest) .. " 章", 16, C.focus, { width = 240, height = 30, textAlign = "right" }),
            } },
            UI.ScrollView { width = "100%", flexGrow = 1, flexBasis = 0, scrollY = true, scrollX = false, showScrollbar = false, children = { UI.Panel { width = "100%", gap = 14, paddingBottom = 30, children = rows } } },
        } } },
    }
    return {
        GetRoot = function() return pageRoot_ end,
        Update = function()
            CampaignView.UpdateBattle(0)
            return true
        end,
        Destroy = function()
            ClearDetail()
            pageRoot_ = nil
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

function CampaignView.IsOpen() return detailLayer_ ~= nil or GameStateAdapter.GetViewState().page == "campaign" end
function CampaignView.AttachRoot(root) root_ = root end
function CampaignView.Reset() ClearDetail(); root_ = nil; pageRoot_ = nil; requestPending_ = false end

return CampaignView
