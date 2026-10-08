local CampaignDefinitions = {}

CampaignDefinitions.VERSION = 1
CampaignDefinitions.ID = "main"
CampaignDefinitions.MAX_CHAPTER = 40
CampaignDefinitions.MAX_COMPLETED_STAGES = 240
CampaignDefinitions.MAX_CLAIMED_REWARDS = 300

local function SafeId(value, fallback)
    if type(value) ~= "string" then return fallback end
    if #value < 1 or #value > 96 then return fallback end
    if not string.match(value, "^[%w%._:%-]+$") then return fallback end
    return value
end

function CampaignDefinitions.NewState()
    return {
        contentVersion = CampaignDefinitions.VERSION,
        highestUnlockedChapter = 1,
        currentStageId = "main:c01:a",
        completedStages = {},
        completedChapters = {},
        claimedRewardKeys = {},
        choices = {},
        sweepDayKey = 0,
        sweepUsed = 0,
        echoDayKey = 0,
        echoStageIds = {},
        echoClaimed = {},
    }
end

function CampaignDefinitions.Sanitize(value)
    local raw = type(value) == "table" and value or {}
    local result = CampaignDefinitions.NewState()
    result.contentVersion = math.max(1, math.min(
        CampaignDefinitions.VERSION,
        math.floor(tonumber(raw.contentVersion) or CampaignDefinitions.VERSION)
    ))
    result.highestUnlockedChapter = math.max(1, math.min(
        CampaignDefinitions.MAX_CHAPTER,
        math.floor(tonumber(raw.highestUnlockedChapter) or 1)
    ))
    result.currentStageId = SafeId(raw.currentStageId, result.currentStageId)

    local completedStages = {}
    local count = 0
    for stageId, record in pairs(type(raw.completedStages) == "table" and raw.completedStages or {}) do
        local safeStageId = SafeId(stageId, nil)
        if safeStageId and type(record) == "table" and count < CampaignDefinitions.MAX_COMPLETED_STAGES then
            completedStages[safeStageId] = {
                clearCount = math.max(1, math.min(1000000, math.floor(tonumber(record.clearCount) or 1))),
                bestStars = math.max(0, math.min(3, math.floor(tonumber(record.bestStars) or 1))),
                firstClearClaimed = record.firstClearClaimed == true,
                clearedAt = math.max(0, math.floor(tonumber(record.clearedAt) or 0)),
            }
            count = count + 1
        end
    end
    result.completedStages = completedStages

    local completedChapters = {}
    for chapterId, record in pairs(type(raw.completedChapters) == "table" and raw.completedChapters or {}) do
        local safeChapterId = SafeId(chapterId, nil)
        local chapterNumber = tonumber(string.match(safeChapterId or "", "c(%d+)$"))
        if safeChapterId and chapterNumber and chapterNumber >= 1 and chapterNumber <= CampaignDefinitions.MAX_CHAPTER then
            completedChapters[safeChapterId] = {
                rewardClaimed = type(record) == "table" and record.rewardClaimed == true,
                clearedAt = type(record) == "table" and math.max(0, math.floor(tonumber(record.clearedAt) or 0)) or 0,
            }
        end
    end
    result.completedChapters = completedChapters

    local claimedRewardKeys = {}
    count = 0
    for rewardKey, claimed in pairs(type(raw.claimedRewardKeys) == "table" and raw.claimedRewardKeys or {}) do
        local safeKey = SafeId(rewardKey, nil)
        if safeKey and claimed == true and count < CampaignDefinitions.MAX_CLAIMED_REWARDS then
            claimedRewardKeys[safeKey] = true
            count = count + 1
        end
    end
    result.claimedRewardKeys = claimedRewardKeys

    local choices = {}
    for choiceId, choice in pairs(type(raw.choices) == "table" and raw.choices or {}) do
        local safeChoiceId = SafeId(choiceId, nil)
        if safeChoiceId and type(choice) == "table" then
            choices[safeChoiceId] = {
                selected = SafeId(choice.selected, ""),
                selectedAt = math.max(0, math.floor(tonumber(choice.selectedAt) or 0)),
            }
        end
    end
    result.choices = choices
    result.sweepDayKey = math.max(0, math.floor(tonumber(raw.sweepDayKey) or 0))
    result.sweepUsed = math.max(0, math.min(3, math.floor(tonumber(raw.sweepUsed) or 0)))
    result.echoDayKey = math.max(0, math.floor(tonumber(raw.echoDayKey) or 0))
    local echoStageIds = {}
    for _, stageId in ipairs(type(raw.echoStageIds) == "table" and raw.echoStageIds or {}) do
        local safeStageId = SafeId(stageId, nil)
        if safeStageId and #echoStageIds < 3 then echoStageIds[#echoStageIds + 1] = safeStageId end
    end
    result.echoStageIds = echoStageIds
    local echoClaimed = {}
    for stageId, claimed in pairs(type(raw.echoClaimed) == "table" and raw.echoClaimed or {}) do
        local safeStageId = SafeId(stageId, nil)
        if safeStageId and claimed == true then echoClaimed[safeStageId] = true end
    end
    result.echoClaimed = echoClaimed
    return result
end

function CampaignDefinitions.ChapterFromId(stageId)
    local chapter = tonumber(string.match(tostring(stageId or ""), "main:c(%d+):"))
    if not chapter then return nil end
    return math.floor(chapter)
end

return CampaignDefinitions
