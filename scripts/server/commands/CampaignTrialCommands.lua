local Router = require("server.core.CommandRouter")
local Engine = require("server.domain.CampaignEngine")
local Transition = require("server.domain.PlayerTransition")
local DungeonCatalog = require("shared.DungeonCatalog")
local DungeonEngine = require("server.domain.DungeonEngine")
local Commands = {}
local PAGE_SIZE = 80 -- Bounded below the 60 KiB command envelope, even at maximum attack speed.

local function Metadata(trial)
    return { trialId = trial.id, stageId = trial.stageId, duration = trial.report.duration,
        limit = trial.report.limit, waves = trial.report.waves, playerMaxHp = trial.report.playerMaxHp,
        pages = math.ceil(#trial.report.frames / PAGE_SIZE) }
end

function Commands.Register(router, services)
    router:Register({
        name = "Game.CampaignTrial", async = true,
        rate = { refillRate = 80, burst = 240 },
        schema = { type = "object", allowUnknown = false, required = { "action", "stageId" }, fields = {
            action = { type = "string", enum = { "prepare", "frames", "finish", "abort" } },
            stageId = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" },
            trialId = { type = "string", minLength = 1, maxLength = 96, pattern = "^[%w%._:%-]+$" },
            page = { type = "integer", min = 1, max = 64 },
        } },
        handler = function(context, payload, done)
            local session = services.profileService:GetSession(context.uid)
            if not session then return false, { code = "PROFILE_NOT_LOADED", reason = "角色尚未加载" } end
            local function Reply(data) done(true, { ok = true, data = data }); return Router.PENDING end
            local function Fail(code, reason) done(false, { ok = false, code = code, reason = reason }); return Router.PENDING end
            if payload.action == "prepare" then
                local trial
                services.profileService:Apply(context.uid, "prepare campaign trial", function(state, now)
                    if session.campaignTrial and session.campaignTrial.stageId == payload.stageId
                        and now <= session.campaignTrial.expiresAt then
                        trial = session.campaignTrial
                        return Transition.NoCommit(state, now, "campaign_trial_prepared")
                    end
                    if session.campaignTrial and DungeonCatalog.GetStage(session.campaignTrial.stageId)
                        and now <= session.campaignTrial.expiresAt then
                        return Transition.Failure(state, now, "DUNGEON_ACTIVE", "请先结束当前副本")
                    end
                    local report, outcome = Engine.PrepareTrial(state, payload.stageId)
                    if not report then return Transition.Failure(state, now, "CAMPAIGN_STAGE_LOCKED", outcome) end
                    local serial = (session.campaignTrialSerial or 0) + 1
                    trial = { id = "trial:" .. tostring(session.generation or 0) .. ":" .. tostring(now) .. ":" .. tostring(serial),
                        serial = serial, stageId = payload.stageId, report = report, outcome = outcome,
                        finishAt = now + math.ceil(report.duration), expiresAt = now + 900 }
                    local stage = DungeonCatalog.GetStage(payload.stageId)
                    if stage then
                        local proposal = DungeonEngine.Reserve(state, stage, now)
                        if proposal.ok then trial.dungeonRunId = proposal.state.activities[stage.activityId].session.dungeonRunId end
                        return proposal
                    end
                    return Transition.NoCommit(state, now, "campaign_trial_prepared")
                end, function(result)
                    if not result.ok then Fail(result.code, result.reason); return end
                    if services.profileService:GetSession(context.uid) ~= session then Fail("SESSION_CHANGED", "连接已改变，请重新进入试炼"); return end
                    session.campaignTrial, session.campaignTrialSerial = trial, trial.serial
                    if result.data.delta then services.sendDelta(context.uid, result.data.delta) end
                    Reply(Metadata(trial))
                end)
                return Router.PENDING
            end
            local trial = session.campaignTrial
            if payload.action == "finish" and session.lastCampaignTrial
                and session.lastCampaignTrial.id == payload.trialId and session.lastCampaignTrial.stageId == payload.stageId then
                return Reply(session.lastCampaignTrial.result)
            end
            if not trial or trial.id ~= payload.trialId or trial.stageId ~= payload.stageId then
                return Fail("CAMPAIGN_TRIAL_EXPIRED", "本次试炼已结束或连接已改变，请重新挑战")
            end
            if payload.action == "abort" then
                services.profileService:Apply(context.uid, "abort trial", function(state, now)
                    if services.profileService:GetSession(context.uid) ~= session or session.campaignTrial ~= trial then
                        return Transition.Failure(state, now, "CAMPAIGN_TRIAL_EXPIRED", "试炼已改变")
                    end
                    return Engine.SettleTrial(state, trial.stageId, { won = false }, now, trial.dungeonRunId)
                end, function(result)
                    if not result.ok then Fail(result.code, result.reason); return end
                    if session.campaignTrial == trial then session.campaignTrial = nil end
                    if result.data.delta then services.sendDelta(context.uid, result.data.delta) end
                    Reply({ aborted = true })
                end)
                return Router.PENDING
            end
            if payload.action == "frames" then
                local page = payload.page or 1
                if page > math.ceil(#trial.report.frames / PAGE_SIZE) then return Fail("INVALID_PAGE", "战斗数据页不存在") end
                local frames = {}
                for i = (page - 1) * PAGE_SIZE + 1, math.min(page * PAGE_SIZE, #trial.report.frames) do
                    frames[#frames + 1] = trial.report.frames[i]
                end
                return Reply({ trialId = trial.id, page = page, frames = frames })
            end
            services.profileService:Apply(context.uid, "settle campaign trial", function(state, now)
                if services.profileService:GetSession(context.uid) ~= session or session.campaignTrial ~= trial then
                    return Transition.Failure(state, now, "CAMPAIGN_TRIAL_EXPIRED", "试炼已改变")
                end
                if now < trial.finishAt then return Transition.Failure(state, now, "CAMPAIGN_BATTLE_RUNNING", "战斗尚未结束，请稍后领取") end
                if now > trial.expiresAt then return Transition.Failure(state, now, "CAMPAIGN_TRIAL_EXPIRED", "试炼已过期，请重新挑战") end
                return Engine.SettleTrial(state, trial.stageId, trial.outcome, now, trial.dungeonRunId)
            end, function(result)
                if not result.ok then Fail(result.code, result.reason); return end
                if result.data.delta then services.sendDelta(context.uid, result.data.delta) end
                local receipt = { won = trial.outcome.won, stars = trial.outcome.stars, stageId = trial.stageId }
                session.lastCampaignTrial = { id = trial.id, stageId = trial.stageId, result = receipt }
                if session.campaignTrial == trial then session.campaignTrial = nil end
                Reply(receipt)
            end)
            return Router.PENDING
        end,
    })
end

return Commands
