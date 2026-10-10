-- ChallengeDefinitions.lua
-- 限时打桩伤害榜 + 深渊 Boss 挑战的共享规则。
-- 战力榜仍由 LeaderboardService 独立维护，本模块不改战力分。

local AbyssDefinitions = require("shared.AbyssDefinitions")
local LargeNumber = require("shared.LargeNumber")

---@class ChallengeDefinitions
local ChallengeDefinitions = {}

ChallengeDefinitions.VERSION = 1
ChallengeDefinitions.BOARDS = { "power", "damage", "boss" }

ChallengeDefinitions.BOSS = {
    DURATION = 20,
    INTERVAL = 0.3,
    FAIL_FRAGMENT_RATE = 0.25,
}

ChallengeDefinitions.BOSS_HP_MUL = {
    rift = 0.80,
    mutated = 1.00,
    calamity = 1.20,
}

local function clampScore(value)
    return math.max(0, math.min(
        LargeNumber.MAX_CLOUD_INTEGER,
        math.floor(tonumber(value) or 0)
    ))
end

function ChallengeDefinitions.ClampScore(value)
    return clampScore(value)
end

function ChallengeDefinitions.IsKnownBoard(board)
    return board == "power" or board == "damage" or board == "boss"
end

function ChallengeDefinitions.NewState()
    return {
        bestStrikeDamage = 0,
        lastStrikeDamage = 0,
        lastStrikeAt = 0,
        bestBossDamage = 0,
        lastBossDamage = 0,
        lastBossAt = 0,
        lastBossGrade = "rift",
        lastBossKilled = false,
        bossRuns = 0,
        bossKills = 0,
        bossSession = nil,
    }
end

function ChallengeDefinitions.BossHpMul(gradeId)
    return ChallengeDefinitions.BOSS_HP_MUL[gradeId] or 1.0
end

function ChallengeDefinitions.BuildView(state, now)
    state = type(state) == "table" and state or {}
    now = math.max(0, math.floor(tonumber(now) or os.time()))
    local challenges = type(state.challenges) == "table" and state.challenges
        or ChallengeDefinitions.NewState()
    local session = type(challenges.bossSession) == "table"
        and challenges.bossSession.finished ~= true
        and challenges.bossSession or nil
    local gradeId = session and session.gradeId or "rift"
    local grade = AbyssDefinitions.Get(gradeId)
    local remaining = ChallengeDefinitions.BOSS.DURATION
    if session then
        remaining = math.max(
            0,
            ChallengeDefinitions.BOSS.DURATION - (now - (session.startedAt or now))
        )
    end
    return {
        bestStrikeDamage = clampScore(challenges.bestStrikeDamage),
        lastStrikeDamage = clampScore(challenges.lastStrikeDamage),
        bestBossDamage = clampScore(challenges.bestBossDamage),
        lastBossDamage = clampScore(challenges.lastBossDamage),
        lastBossGrade = AbyssDefinitions.IsKnownGrade(challenges.lastBossGrade)
            and challenges.lastBossGrade or "rift",
        lastBossKilled = challenges.lastBossKilled == true,
        bossRuns = math.max(0, math.floor(tonumber(challenges.bossRuns) or 0)),
        bossKills = math.max(0, math.floor(tonumber(challenges.bossKills) or 0)),
        sessionActive = session ~= nil,
        sessionGradeId = session and session.gradeId or nil,
        sessionStartedAt = session and session.startedAt or nil,
        sessionRunId = session and session.runId or nil,
        sessionGradeName = grade and grade.name or "裂隙深渊",
        sessionDamage = session and clampScore(session.damage) or 0,
        sessionHp = session and clampScore(session.hp) or 0,
        sessionMaxHp = session and clampScore(session.maxHp) or 0,
        duration = ChallengeDefinitions.BOSS.DURATION,
        remaining = remaining,
    }
end

return ChallengeDefinitions
