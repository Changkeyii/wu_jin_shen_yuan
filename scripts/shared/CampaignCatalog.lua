local CampaignCatalog = {}

CampaignCatalog.ID = "main"
CampaignCatalog.VERSION = 1
CampaignCatalog.MAX_CHAPTER = 40

local VIDEO = "video/"
local IMAGE = "image/"
local HERO = "image/brawlforge_punk_hero_fullbody_v2_20260720090901.png"
local SPIRIT = "image/ui/story/tower_spirit_portrait.png"

local chapterMeta = {
    { "残刃苏醒", "残刃与塔灵的第一次回应", 1 },
    { "名字之外", "第一次追问失落的名字", 3 },
    { "灰墙余烬", "尘乡的灯正在变暗", 6 },
    { "门后残响", "门的另一侧有人等待", 10 },
    { "旧约裂痕", "一次自愿能否代表永恒", 14 },
    { "万灵审判", "旧约需要被重新询问", 18 },
    { "众证之路", "让记住成为互相约束", 22 },
    { "黎明之门", "你会留下谁，又让谁等待", 27 },
}

local function storyStage(chapter, stage, title, lines, options)
    options = options or {}
    return {
        id = string.format("main:c%02d:%s", chapter, stage),
        chapter = chapter,
        stage = stage,
        title = title,
        kind = options.kind or "story",
        recommendedLevel = options.recommendedLevel or math.max(1, chapter * 2),
        exp = options.exp or (stage == "a" and 75 or (stage == "b" and 180 or 240)),
        gold = options.gold or (stage == "a" and 1200 or (stage == "b" and 2600 or 4200)),
        fragments = options.fragments or (stage == "a" and 4 or (stage == "b" and 8 or 14)),
        enemy = options.enemy,
        video = options.video,
        illustration = options.illustration,
        dialogue = options.dialogue,
        lines = lines,
        mechanic = options.mechanic,
        stars = options.stars or {
            { id = "time", desc = "90 秒内通关" },
            { id = "hp", desc = "生命值不低于 30%" },
            { id = "no_aid", desc = "不使用塔灵援助" },
        },
        waves = options.waves,
        timeLimit = options.timeLimit or 90,
    }
end

local function buildChapter(chapter, title, summary, recommendedLevel, stages)
    return {
        id = string.format("main:c%02d", chapter),
        chapter = chapter,
        title = title,
        summary = summary,
        recommendedLevel = recommendedLevel,
        stages = stages,
    }
end

local chapters = {}

chapters[1] = buildChapter(1, "残刃苏醒", "你醒在一座记得所有人、却叫不出你名字的塔里。", 1, {
    storyStage(1, "a", "第一声回应", { "塔灵：你醒了。", "你：这里是哪？", "塔灵：一座还没有忘记你的塔。" }, {
        video = { src = VIDEO .. "cgt-20260826181818-phjgb_video.mp4", captions = { "有些记录不在塔的高处。", "它们只是被封存在无人再问起的地方。" }, skipAfter = 2 },
        illustration = { src = IMAGE .. "story_c01_illus_spear_1_20260826121505.png", narration = "封存的门，像一页被合上的档案。" },
        dialogue = { { speaker = "塔灵", text = "塔记得这柄残刃。它记得的，比它肯说的多。" }, { speaker = "你", text = "那就让我看看，它不肯说的是什么。" } },
    }),
    storyStage(1, "b", "门厅试炼", { "门后的影子没有名字，只有守门的职责。", "击败它，证明你仍能为自己的选择挥刀。" }, { kind = "battle", enemy = { name = "无名影卒", hp = 80, atk = 8, def = 2 }, mechanic = "clear_minions", waves = 3, timeLimit = 90 }),
    storyStage(1, "c", "缄默守门人", { "守门人：我忘了自己的名字。", "守门人：但我还记得，不能让影子越过这扇门。", "你：那就让我替你记住今晚。" }, { kind = "boss", enemy = { name = "缄默守门人", hp = 170, atk = 15, def = 5 }, mechanic = "gatekeeper", waves = 3, timeLimit = 90 }),
})

chapters[2] = buildChapter(2, "名字之外", "残刃指向一面姓名墙；其中有一道空痕，像你亲手留下的伤口。", 3, {
    storyStage(2, "a", "姓名墙", { "满墙名字里，只有一行没有归属。", "塔灵：空白不是没有记录。它是被主动删去的记录。" }, { dialogue = { { speaker = "塔灵", text = "空白不是没有记录。" }, { speaker = "你", text = "那它为什么不肯发出声音。" } } }),
    storyStage(2, "b", "无面回声", { "无面影子借用你的动作，却没有你的迟疑。", "它只会重复已经发生过的事。" }, { kind = "battle", enemy = { name = "无面回声", hp = 260, atk = 22, def = 8 }, mechanic = "mirror", timeLimit = 90 }),
    storyStage(2, "c", "镜中旧我", { "旧影：没有过去，就没有责任。", "你：没有过去，也没有理由相信自己的下一步。" }, { kind = "boss", enemy = { name = "镜中旧我", hp = 430, atk = 30, def = 12 }, mechanic = "mirror", timeLimit = 90 }),
})

chapters[3] = buildChapter(3, "灰墙余烬", "尘乡的灯火传来微弱回声：塔外并不比塔内更安全。", 6, {
    storyStage(3, "a", "墙外来信", { "弥娅：如果你能收到这封信，说明高墙还亮着。", "弥娅：别急着找名字，先记住还有人在等灯亮。" }, { dialogue = { { speaker = "弥娅", text = "别急着找名字，先记住还有人在等灯亮。" } } }),
    storyStage(3, "b", "灰墙守卫", { "守卫不是敌人，它们只是把所有靠近者都识别成了影子。", "你要击败的，是一条错误的判断。" }, { kind = "battle", enemy = { name = "灰墙守卫", hp = 520, atk = 38, def = 15 }, mechanic = "lamps", timeLimit = 90 }),
    storyStage(3, "c", "守灯人弥娅", { "弥娅：你们在塔里讨论世界的答案。", "弥娅：可尘乡的人，今晚只想知道灯会不会灭。", "你：所以我要带着答案回来，而不是只带着名字。" }, { kind = "boss", enemy = { name = "灰墙灾影", hp = 760, atk = 48, def = 20 }, mechanic = "lamps", timeLimit = 90 }),
})

chapters[4] = buildChapter(4, "门后残响", "你终于听见门的另一侧：那里不是怪物，是一群仍在等待抵达的人。", 10, {
    storyStage(4, "a", "黑潮祭书", { "每翻一页，读者就少记得一个称谓。", "深渊窥视者：别把听不清的声音，急着叫成敌人。" }, { kind = "story", enemy = nil, dialogue = { { speaker = "深渊窥视者", text = "别把听不清的声音，急着叫成敌人。" } } }),
    storyStage(4, "b", "迁界列车", { "所有车票都写着同一个目的地：明天。", "但车票上没有任何人的名字。" }, { kind = "battle", enemy = { name = "迁界总控", hp = 980, atk = 60, def = 25 }, mechanic = "true_voice", timeLimit = 90 }),
    storyStage(4, "c", "避难所之门", { "你：封门那天，我替所有人做了决定。", "初代：你替世界守住了时间。可时间不会替你回答。", "塔灵：门的两侧，都有人在等你下一次选择。" }, { kind = "boss", enemy = { name = "门中初影", hp = 1500, atk = 78, def = 32 }, mechanic = "true_voice", timeLimit = 90, video = { src = VIDEO .. "cgt-20260826202232-8jvgh_video.mp4", captions = { "门不是怪物。", "而‘所有人’，已经听不见每一个人。" } }, illustration = { src = IMAGE .. "story_c10_illus_gate_1_20260826121408.png", narration = "门后不是怪物，是尚未抵达的人。" } }),
})

chapters[5] = buildChapter(5, "旧约裂痕", "你在一份旧约上看见自己的签名：一次自愿，能否代表永恒？", 14, {
    storyStage(5, "a", "自愿者名册", { "每一个名字都是本人写下的，没有一笔完全相同。", "可名册从未再问过他们，现在是否仍愿意。" }, { illustration = { src = IMAGE .. "story_c28_illus_seat_1_20260826121432.png", narration = "空着的座位，等待一个愿意只记不决的人。" } }),
    storyStage(5, "b", "退约之门", { "阿妲：不能退出的自愿，只是写得更好看的囚禁。", "你：那谁来承担退出之后的风险？" }, { kind = "battle", enemy = { name = "永恒契约回声", hp = 1200, atk = 66, def = 28 }, mechanic = "oathbreak", timeLimit = 90 }),
    storyStage(5, "c", "旧约裁定者", { "初代：你尊重他们当年的牺牲。", "初代：所以更不能假装他们永远不需要被询问。", "你：从今天起，选择必须能够被重新确认。" }, { kind = "boss", enemy = { name = "旧约裁定者", hp = 1800, atk = 82, def = 36 }, mechanic = "oathbreak", timeLimit = 90, video = { src = VIDEO .. "cgt-20260826201522-8f9p6_video.mp4", captions = { "空着的不是王位，是未被回答的问题。" } } }),
})

local laterTitles = {
    [2] = { "名字之外", "继续追问：如果旧名不是答案，什么才是？", 3 },
    [3] = { "灰墙余烬", "尘乡的灯正在变暗，活着的人需要一个明天。", 6 },
    [4] = { "门后残响", "门的另一侧有人等待，封闭同时保护与抛弃。", 10 },
    [5] = { "旧约裂痕", "一次自愿，能否代表永恒。", 14 },
    [6] = { "万灵审判", "被保护的人，是否有权拒绝保护。", 18 },
    [7] = { "众证之路", "让记住成为互相约束，而不是新的控制。", 22 },
    [8] = { "黎明之门", "你会留下谁，又让谁等待。", 27 },
}

local function FillLaterChapter(chapter, meta, offset)
    local level = meta[3] + offset - 1
    local stageA = storyStage(chapter, "a", "记忆节点", { "一段新的记录等待被看见。", "你没有得到答案，只得到一个必须亲自确认的问题。" }, { kind = "story", recommendedLevel = level })
    local stageB = storyStage(chapter, "b", "回响战斗", { "回响复制了旧日的选择。", "它不会理解改变，只会阻止改变发生。" }, { kind = "battle", recommendedLevel = level, enemy = { name = "记忆回响", hp = 1200 + chapter * 90, atk = 70 + chapter * 4, def = 30 + chapter } })
    local stageC = storyStage(chapter, "c", "章节决断", { "守塔人：你已经看见代价。", "守塔人：现在，别把我的选择偷走，替我继续选择。" }, { kind = "boss", recommendedLevel = level, enemy = { name = "章节守望者", hp = 1900 + chapter * 120, atk = 90 + chapter * 5, def = 40 + chapter } })
    return buildChapter(chapter, string.format("%s·%d", meta[1], offset), meta[2], level, { stageA, stageB, stageC })
end

for chapter = 6, CampaignCatalog.MAX_CHAPTER do
    local volume = math.floor((chapter - 1) / 5) + 1
    local offset = ((chapter - 1) % 5) + 1
    chapters[chapter] = FillLaterChapter(chapter, laterTitles[volume], offset)
end

local function AttachVideo(stage, src, captions)
    stage.video = { src = VIDEO .. src, captions = captions or {} }
end

local function AttachIllustration(stage, src, narration)
    stage.illustration = { src = IMAGE .. src, narration = narration }
end

AttachVideo(chapters[6].stages[1], "cgt-20260826201922-84sbv_video.mp4", {
    "旧名可以被封锁。",
    "做过的选择，不会因此消失。",
})
AttachIllustration(chapters[6].stages[1], "story_c06_illus_wall_1_20260826121408.png", "满墙名字里，只有一行空痕没有归属。")
chapters[6].stages[1].dialogue = {
    { speaker = "塔灵", text = "这一行，是你亲手划去的。" },
    { speaker = "你", text = "我那时……不想被认出吗。" },
}

AttachVideo(chapters[10].stages[3], "cgt-20260826202232-8jvgh_video.mp4", {
    "门不是怪物。",
    "而‘所有人’，已经听不见每一个人。",
})
AttachIllustration(chapters[10].stages[3], "story_c10_illus_gate_1_20260826121408.png", "门后不是怪物，是尚未抵达的人。")
chapters[10].stages[3].dialogue = {
    { speaker = "门中初影", text = "一起走，就不用有人被留在黑暗里。" },
    { speaker = "你", text = "一起走，也会让谁都认不出谁。" },
}

AttachVideo(chapters[17].stages[1], "cgt-20260826202621-dzqcb_video.mp4", {
    "他们要去一个名叫明天的地方。",
    "车票上没有谁的名字。",
})
AttachIllustration(chapters[17].stages[1], "story_c17_illus_train_1_20260826121431.png", "通往明天的列车，等所有乘客到齐。")
chapters[17].stages[1].dialogue = {
    { speaker = "车长残响", text = "请上车，目的地是明天。" },
    { speaker = "你", text = "明天在哪里。" },
    { speaker = "车长残响", text = "所有人到齐……才发车。" },
}

AttachVideo(chapters[20].stages[3], "cgt-20260826203227-9hgh4_video.mp4", {
    "关闭，是为了保住这边的灯。",
    "关闭，也会让那边的人再没有归期。",
})
AttachIllustration(chapters[20].stages[3], "story_c20_illus_hand_2_20260826121506.png", "一道封条，隔开两盏不同的灯。")
chapters[20].stages[3].dialogue = {
    { speaker = "你", text = "封门那天，我替所有人做了决定。" },
    { speaker = "初代守塔人", text = "你替世界守住了时间。可时间不会替你回答。" },
    { speaker = "塔灵", text = "门的两侧，都有人在等你下一次选择。" },
}

AttachVideo(chapters[28].stages[3], "cgt-20260826203449-x7bl7_video.mp4", {
    "零号席从来不属于领袖。",
    "它属于不能替任何人选择的人。",
})
AttachIllustration(chapters[28].stages[3], "story_c28_illus_seat_1_20260826121432.png", "空着的座位，等待一个愿意只记不决的人。")
chapters[28].stages[3].dialogue = {
    { speaker = "第零见证者映像", text = "你没有资格否定我的决定，因为你来自我的决定。" },
    { speaker = "你", text = "可今天的我，还没替任何人做过决定。" },
}

AttachVideo(chapters[40].stages[3], "cgt-20260826203736-8hxwj_video.mp4", {
    "被记住不是永不改变。",
    "选之前先看清：你会留下谁，又让谁等待。",
})
AttachIllustration(chapters[40].stages[3], "story_c40_illus_choice_1_20260826121431.png", "门、灯、空痕，都在等你最后一次点名。")
chapters[40].stages[3].dialogue = {
    { speaker = "塔灵", text = "塔会记住你的答案。它不会替你承担答案。" },
    { speaker = "你", text = "我知道。这一次，换我来签。" },
    { speaker = "弥娅", text = "无论你选哪条路，尘乡的灯都会记得你。" },
}

function CampaignCatalog.GetChapter(chapter)
    return chapters[math.max(1, math.min(CampaignCatalog.MAX_CHAPTER, math.floor(tonumber(chapter) or 1)))]
end

function CampaignCatalog.GetStage(stageId)
    for _, chapter in pairs(chapters) do
        for _, stage in ipairs(chapter.stages) do
            if stage.id == stageId then return stage end
        end
    end
    return nil
end

function CampaignCatalog.GetAllChapters()
    local result = {}
    for index = 1, CampaignCatalog.MAX_CHAPTER do result[#result + 1] = chapters[index] end
    return result
end

function CampaignCatalog.GetChapterMeta(volume)
    return chapterMeta[volume]
end

return CampaignCatalog
