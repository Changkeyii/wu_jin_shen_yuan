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
    title = "序章·无尽万灵塔",
    lines = {
        "这里没有真正的出口，只有被万灵记住的每一次战斗。",
        "塔灵会保留你夺得的战利品；死亡只会把你送回本层起点。",
        "继续向上。失落的名字与守塔人的记忆，都在更高处等你。",
    },
}

local CHAPTERS = {
    {
        id = "chapter_01_gatekeeper", floor = 10, title = "第一章·缄默守门人",
        opening = { "铁门没有锁，门前的人却已经守了太久。", "他忘记了姓名，只记得不许任何灵魂登塔。" },
        boss = { "守门人举起残刃：证明你不是又一个被深渊吞没的影子。" },
        memory = { "碎片中传来一句低语：塔并非囚笼，它曾是一座避难所。" },
    },
    {
        id = "chapter_02_oath", floor = 20, title = "第二章·断誓将军",
        opening = { "军旗在无风处猎猎作响，誓言早已比盔甲更沉重。" },
        boss = { "将军拒绝退让：若誓言注定破碎，就让它碎在真正的强者手中。" },
        memory = { "万灵曾自愿进入塔中，以自己的记忆封住塔底之物。" },
    },
    {
        id = "chapter_03_mirror", floor = 30, title = "第三章·镜中旧我",
        opening = { "镜面映出的不是现在，而是每一次失败后想要放弃的你。" },
        boss = { "旧影与你同时起手：想越过这里，先承认那些软弱也属于你。" },
        memory = { "你看见自己曾在很久以前来过，并亲手抹去了这段记忆。" },
    },
    {
        id = "chapter_04_smith", floor = 40, title = "第四章·万灵铸魂者",
        opening = { "熔炉以记忆为火，铸出的每件兵器都在呼喊主人的名字。" },
        boss = { "铸魂者敲响铁砧：力量不是馈赠，是你愿意承担的重量。" },
        memory = { "塔的核心正在衰弱，守塔者只能用后来者的战意继续加固封印。" },
    },
    {
        id = "chapter_05_first_keeper", floor = 50, title = "第五章·初代守塔人",
        opening = { "最高的王座上没有王，只有第一个决定留下的人。" },
        boss = { "初代守塔人睁开眼：若你要继续，就替我回答塔存在的意义。" },
        memory = { "答案仍在更高处。所谓塔顶，只是下一段深渊的入口。" },
    },
}

StoryCatalog.RULES = {
    id = StoryCatalog.RULE_ID,
    title = "无尽万灵塔规则",
    paragraphs = {
        "每层共 10 场：7 场普通、2 场精英、1 场守层 Boss；每 10 层为章节 Boss。",
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
        title = string.format("第%d章·无名回廊", chapter),
        opening = { "更高一层的回廊亮起，陌生的记忆正在苏醒。" },
        boss = { "这一章的守护者拦住了通往下一段记忆的道路。" },
        memory = { "记忆碎片已经收录。塔仍在向上延伸。" },
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
