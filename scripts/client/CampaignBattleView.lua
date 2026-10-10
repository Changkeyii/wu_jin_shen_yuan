local UI = require("urhox-libs/UI")
local Kit = require("client.ViewKit")
local Theme = require("client.Theme")
local Assets = require("client.ViewAssets")
local Adapter = require("client.GameStateAdapter")
local Server = require("client.ServerClient")
local Loading = require("client.LoadingController")
local Presentation = require("client.PlayPresentation")
local C = Theme.Colors
local View = {}

function View.Create(stage, onBack, onSettled)
    local view = { disposed = false, elapsed = 0, cursor = 1, frames = {}, ready = false }
    local root = UI.Panel { width = "100%", height = "100%", position = "relative", overflow = "hidden" }
    local status = Kit.CompactTxt(stage.dungeon and "正在准备每日副本…" or "正在准备关卡试炼…", 22, C.gold,
        { position = "absolute", left = 36, top = 20, width = 700, height = 52 })
    local exitLabel = Kit.CompactTxt("撤退", 20, C.text, { width = "100%", height = 72, textAlign = "center" })
    local exitButton = UI.Panel {
        position = "absolute", right = 26, top = 12, width = 230, height = 72, clickable = true,
        backgroundImage = Assets.ASSETS.ui.playAutoRunButton, backgroundFit = "contain",
        children = { exitLabel }, onClick = function() if onBack then onBack() end end,
    }
    local retryButton = Kit.ActionButton { text = "重试结算", width = 260, onClick = function() if view.Settle then view:Settle() end end }
    local resultBar = UI.Panel {
        position = "absolute", left = 36, right = 36, bottom = 24, height = 100,
        alignItems = "center", justifyContent = "center", visible = false, children = { retryButton },
    }
    local function SetStatus(text) status:SetText(text) end
    local function Request(action, page, callback)
        Server.CampaignTrial(stage.id, action, view.trialId, page, function(response)
            if view.disposed then
                -- Preparing may finish after the user has left. Release that exact server trial.
                if action == "prepare" and response and response.ok and response.data then
                    Server.CampaignTrial(stage.id, "abort", response.data.trialId, nil, function() end)
                end
                return
            end
            callback(response)
        end)
    end
    function view:Settle()
        if self.settling or self.settled then return end
        self.settling = true
        resultBar:SetVisible(false)
        SetStatus("战斗结束，正在结算…")
        Request("finish", nil, function(response)
            self.settling = false
            if not response or not response.ok then
                SetStatus((response and response.reason) or "结算暂未完成，请重试")
                resultBar:SetVisible(true)
                return
            end
            self.settled = true
            exitLabel:SetText(stage.dungeon and "返回副本" or "返回关卡")
            local result = response.data or {}
            SetStatus(result.won and (stage.dungeon and "副本胜利 · 奖励已结算" or "试炼胜利 · " .. tostring(result.stars) .. " 星 · 奖励已结算")
                or (stage.dungeon and "副本失败 · 本次次数已消耗，奖励未发放" or "试炼失败 · 提升装备后可再次挑战"))
            if onSettled then onSettled(result) end
        end)
    end
    local function SetWave(room)
        local layout = Assets.LAYOUT
        local trigger = layout.EVENT_TRIGGER_DISTANCE
        local distance = trigger + layout.PRESENTATION_SPEED * 1.2
        view.game.position = room
        view.game.floorRoute = {
            routeId = view.trialId .. ":" .. tostring(room), floor = stage.recommendedLevel,
            triggerDistance = trigger, moveSpeed = layout.PRESENTATION_SPEED,
            encounters = { { room = room, distance = distance, encounterId = "trial:" .. tostring(room), eventType = "monster" } },
        }
        view.game.trial.wave = room
    end
    local function ApplyFrame(frame)
        local game = view.game
        if frame.kind == "battle_started" then
            SetWave(frame.room or 1)
            game.currentMonster = { name = frame.name, hpBig = frame.monsterHpBig, maxHpBig = frame.monsterMaxHpBig,
                eventType = frame.eventType, id = frame.monsterId }
            game.floorRoute.encounters[1].eventType = frame.eventType
        elseif frame.kind == "battle_hit" and game.currentMonster then
            game.currentMonster.hpBig = frame.monsterHpBig
        elseif frame.kind == "player_damaged" or frame.kind == "player_healed" then
            game.hpBig = frame.playerHpBig or game.hpBig
        elseif frame.kind == "battle_won" then
            game.currentMonster = nil
            if game.trial.wave == game.trial.waves then game.autoRun = false end
        elseif frame.kind == "player_died" then
            game.autoRun = false
        end
        view.scene.HandleDelta({ events = { frame } })
    end
    local function Begin()
        local live = Adapter.GetViewState()
        view.game = { page = "campaignTrial", floor = stage.recommendedLevel, position = 0, room = 1,
            stats = live.stats, hpBig = view.meta.playerMaxHp, playerMaxHp = view.meta.playerMaxHp,
            autoRun = true, lootStash = {}, trial = { title = stage.title, wave = 1, waves = view.meta.waves, remaining = view.meta.limit } }
        SetWave(1)
        view.game.position = 0
        view.scene = Presentation.CreateIsolated({ getGame = function() return view.game end })
        local sceneRoot = view.scene.BuildPage()
        root:AddChild(sceneRoot)
        root:AddChild(status); root:AddChild(exitButton); root:AddChild(resultBar)
        view.ready = true
        SetStatus(stage.title .. " · 推荐 Lv." .. tostring(stage.recommendedLevel))
    end
    local function ReadPage(page)
        Request("frames", page, function(response)
            if not response or not response.ok or not response.data or response.data.trialId ~= view.trialId then
                SetStatus((response and response.reason) or "战斗数据加载失败，请返回重试")
                exitLabel:SetText(stage.dungeon and "返回副本" or "返回关卡")
                return
            end
            for _, frame in ipairs(response.data.frames or {}) do view.frames[#view.frames + 1] = frame end
            if page < view.meta.pages then ReadPage(page + 1) else Begin() end
        end)
    end
    root:AddChild(status); root:AddChild(exitButton)
    Loading.EnsurePlayAssetsReady(function()
        if view.disposed then return end
        Request("prepare", nil, function(response)
            if not response or not response.ok or not response.data then
                SetStatus((response and response.reason) or "试炼准备失败，请返回重试")
                exitLabel:SetText(stage.dungeon and "返回副本" or "返回关卡")
                return
            end
            view.meta, view.trialId = response.data, response.data.trialId
            ReadPage(1)
        end)
    end)
    function view:Update(dt)
        if self.disposed or not self.ready then return end
        -- Bound catch-up work; animations and authority frames advance on the same clock.
        local remaining = math.min(math.max(0, dt or 0), 0.25)
        while remaining > 0 and not self.disposed do
            local step = math.min(0.025, remaining)
            remaining = remaining - step
            self.elapsed = self.elapsed + step
            local combatTime = math.max(0, self.elapsed - 1.2)
            self.game.trial.remaining = math.max(0, self.meta.limit - combatTime)
            self.scene.Update(step)
            if self.elapsed >= 1.2 then
                while self.frames[self.cursor] and self.frames[self.cursor].t <= combatTime do
                    ApplyFrame(self.frames[self.cursor]); self.cursor = self.cursor + 1
                end
            end
            if combatTime >= self.meta.duration and not self.playbackFinished then
                self.playbackFinished = true
                self.game.autoRun = false
                self.scene.ClearCombatPresentation(false)
            end
            if self.cursor > #self.frames and self.elapsed >= self.meta.duration + 2.2 then
                if not self.finishRequested then self.finishRequested = true; self:Settle() end
            end
        end
    end
    function view:Destroy()
        if self.disposed then return end
        self.disposed = true
        if self.trialId and not self.settled and not self.settling then
            Server.CampaignTrial(stage.id, "abort", self.trialId, nil, function() end)
        end
        if self.scene then self.scene.Reset() end
        if self.root.parent then self.root.parent:RemoveChild(self.root) end
        self.root:Destroy()
    end
    view.root = root
    return view
end

return View
