local StoryCatalog = {}

StoryCatalog.VERSION = 2
StoryCatalog.RULE_ID = "tower_rules_v2"

local LEGACY_RULE_IDS = {
    ["tower-v2"] = StoryCatalog.RULE_ID,
}

function StoryCatalog.NormalizeRuleId(ruleId)
    return LEGACY_RULE_IDS[ruleId] or ruleId
end

function StoryCatalog.IsKnownRuleId(ruleId)
    return StoryCatalog.NormalizeRuleId(ruleId) == StoryCatalog.RULE_ID
end

StoryCatalog.PROLOGUE = {
    id = "prologue_v2",
    chapter = 0,
    phase = "prologue",
    title = "登塔规则·万灵塔残响",
    lines = {
        "这里没有真正的出口，只有被万灵记住的每一次战斗。",
        "塔灵会保留你夺得的战利品；死亡只会把你送回本层起点。",
        "登塔会留下守塔人的可选残响；主线记忆请前往独立的「万灵记忆」模式调查。",
    },
}

local CHAPTERS = {
    {
        id = "chapter_01_gatekeeper", floor = 10, title = "守层残响·缄默守门人",
        opening = { "铁门没有锁，门前的职责记录仍在重复巡查。", "这是一段守门映像，不是独立剧情模式的章节。" },
        boss = { "守门记录举起残刃：越过这里之前，先证明你仍记得为何战斗。" },
        memory = { "残响已经归档：守门人把职责留在这里，让后来者得以继续前行。" },
    },
    {
        id = "chapter_02_oath", floor = 20, title = "守层残响·断誓将军",
        opening = { "无风军旗仍在重复最后一次列阵。" },
        boss = { "将军记录拒绝退让：让这一场旧战得到应有的结束。" },
        memory = { "残响已经归档：有人选择留下，也有人带着被托付的名字继续前行。" },
    },
    {
        id = "chapter_03_mirror", floor = 30, title = "守层残响·镜中旧影",
        opening = { "镜面记录着登塔者每一次想要放弃的瞬间。" },
        boss = { "旧影与你同时起手：软弱也属于你，但它不能替你决定下一步。" },
        memory = { "残响已经归档：塔记住了这次胜利，却不会替你解释失落的过去。" },
    },
    {
        id = "chapter_04_smith", floor = 40, title = "守层残响·铸魂工坊",
        opening = { "旧熔炉仍在整理散落的战斗结构。" },
        boss = { "工坊记录敲响铁砧：力量不是馈赠，是你愿意承担的重量。" },
        memory = { "残响已经归档：战斗结构化作装备，原主的故事仍留待万灵记忆调查。" },
    },
    {
        id = "chapter_05_first_keeper", floor = 50, title = "守层残响·初代试问",
        opening = { "空王座前只留下一道关于职责的提问。" },
        boss = { "初代记录睁开眼：若要继续登塔，就证明你能承担更强的战斗。" },
        memory = { "残响已经归档：这次试问只检验登塔者，不决定主线真相与结局。" },
    },
}

StoryCatalog.RULES = {
    id = StoryCatalog.RULE_ID,
    title = "无尽万灵塔规则",
    paragraphs = {
        "每层共 10 场：7 场普通、2 场精英、1 场守层 Boss；每 10 层会出现更强的残响守卫。",
        "在线战斗收益与掉落概率均为 100%；离线固定奖励和最终掉落概率均为在线的 20%，只折算一次。",
        "死亡后回到本层第 1 场并满血复活，已经获得的奖励不会丢失。",
        "连续失败两次后，重新在线进入战斗页可领取一次塔灵援助装备。",
        "自动挂机可按设置自动换上真正提升整套通关能力的装备；剧情可设置自动跳过。",
    },
}

function StoryCatalog.GetChapter(chapterNumber)
    local chapter = math.max(1, math.floor(tonumber(chapterNumber) or 1))
    local authored = CHAPTERS[chapter]
    if authored then return authored end
    return {
        id = string.format("chapter_%04d", chapter),
        floor = chapter * 10,
        title = string.format("第%d段守层残响·无名回廊", chapter),
        opening = { "更高一段回廊亮起，一份不影响主线进度的守层记录正在启动。" },
        boss = { "残响守卫拦住去路，检验登塔者当前的战斗能力。" },
        memory = { "守层残响已经归档；主线记忆仍需前往「万灵记忆」调查。" },
    }
end

function StoryCatalog.GetChapterForFloor(floor)
    local normalizedFloor = math.max(1, math.floor(tonumber(floor) or 1))
    return StoryCatalog.GetChapter(math.max(1, math.floor(normalizedFloor / 10)))
end

function StoryCatalog.GetGate(chapterNumber, phase)
    local chapter = StoryCatalog.GetChapter(chapterNumber)
    phase = phase or "opening"
    local lines = chapter[phase] or chapter.opening
    return {
        storyId = chapter.id .. ":" .. phase,
        chapter = math.max(1, math.floor((chapter.floor or 10) / 10)),
        floor = chapter.floor,
        phase = phase,
        title = chapter.title,
        lines = lines,
    }
end

function StoryCatalog.GetGateForFloor(floor, phase)
    local chapter = StoryCatalog.GetChapterForFloor(floor)
    return StoryCatalog.GetGate(math.max(1, math.floor((chapter.floor or 10) / 10)), phase)
end

function StoryCatalog.GetAllChapters() return CHAPTERS end
return StoryCatalog
