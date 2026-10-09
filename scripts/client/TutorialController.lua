-- TutorialController.lua
-- 新手剧情引导：全屏演出层（CG 视频 + 插画对话 + 引导提示条）。
-- 序章期间玩家不能自由操作：只能按引导步骤点击高亮目标（穿戴/分解/强化），
-- 其余任何 UI（页签切换/其他按钮/弹窗）全部被引导层拦截。
-- 服务端权威推进步骤（TutorialEngine），客户端负责演出与引导点击。
-- 流程：CG → 对话 → 引导操作（杀怪/穿戴/分解/强化）→ 功能介绍（纯告知）→ 完成。
-- 正式：玩家终身完成一次；已完成后登录不再重播。

local UI = require("urhox-libs/UI")
local Video = require("urhox-libs/Video")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local UILayout = require("client.UI.UILayout")
local ServerClient = require("client.ServerClient")
local GameStateAdapter = require("client.GameStateAdapter")
local DialogCoordinator = require("client.DialogCoordinator")
local CommonPromptDialog = require("client.CommonPromptDialog")
local LoadingController = require("client.LoadingController")
local Input = require("urhox-libs/UI/Core/Input")
local PointerEvent = require("urhox-libs/UI/Core/PointerEvent")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS

local TutorialController = {}

-- 引导层必须高于分解/强化确认弹窗（3850），否则弹窗一开：
-- 1) 顶部引导条文案被盖住；2) 蓝色高亮框画在弹窗后面，看起来像“没引导”。
-- 层本身 pointerEvents=box-none，真正可点目标仍由输入白名单控制。
local LAYER_Z = 3900
local CG_VIDEO = "video/cgt-20260813181414-jfc79_video.mp4"
-- 塔灵立绘（新手序章对话插画）
local PORTRAIT = "image/tower_spirit_portrait_20260813123852.png"

local root_ = nil
local layer_ = nil
local videoPlayer_ = nil
local active_ = false
local phase_ = "idle"  -- cg / dialog / guide / done
local step_ = 1
local guideHint_ = nil
-- 引导子步骤状态
local guideIndex_ = 0
local guideTarget_ = nil
local guideHighlight_ = nil
local guidePointerListener_ = nil
local guideLockPanels_ = {}
-- 切页后 Yoga 布局尚未计算完成时，延迟到下一帧重试高亮（避免误判为全屏锁定）
local guideRetryPending_ = false
local guideRetryCount_ = 0
-- 点击目标推进子步骤后，延迟一帧重建拦截面板。
-- 若立即重建，pointer-up 时目标已被新面板盖住，UI 判定 down/up 命中不一致，
-- 会吞掉目标自身的 onClick（穿戴/分解/强化等引导操作）。
local guideRebuildPending_ = false
-- 分解教学必须先亲自勾选指定护具，之后才开放确认按钮。
local tutorialDispositionSelected_ = false
-- 首杀后服务端会立刻推 step=2；客户端需等掉落飞入表现结束再进入第二步对话。
local pendingStepIntro_ = nil
local pendingStepIntroWait_ = 0
local pendingStepIntroSawLoot_ = false
-- 至少等一帧给 PlayPresentation 处理同帧 loot 事件；最长兜底避免永久卡住。
local STEP_INTRO_MIN_WAIT = 0.35
-- 首杀掉落表现等待上限：宁可快进下一步，也不能卡死在 step1。
local STEP_INTRO_MAX_WAIT = 2.2

-- 输入硬锁：不能只依赖视觉遮罩。UI 页面重建、zIndex 或弹窗叠层都不能绕过它。
-- 序章 active_ 期间，只有 allowedWidgets_ 命中的控件能进入 UI.HandlePointerEvent。
local allowedWidgets_ = {}
local lockedPointers_ = {}
local originalHandlePointerEvent_ = nil
local wrappedHandlePointerEvent_ = nil
local inputGateListeners_ = {}
local inputLockInstalled_ = false
-- 拦截点击时的 toast 节流，避免玩家连点刷屏。
local blockedToastAt_ = 0
local BLOCKED_TOAST_COOLDOWN = 1.2
local ShowStepIntro = nil
-- 前向声明：引导提示条（ShowGuideSubStep 使用）。
local ShowGuide = nil
-- 前向声明：子步骤推进（ShowGuide 的“下一步”兜底按钮使用）。
local AdvanceGuideSubStep = nil
-- 前向声明：子步骤显示（ShowStepIntro / AdvanceGuideSubStep 使用）。
local ShowGuideSubStep = nil

local function ClearPendingStepIntro()
    pendingStepIntro_ = nil
    pendingStepIntroWait_ = 0
    pendingStepIntroSawLoot_ = false
end

-- 各步骤引导文案（服务端 step：1 首杀 2 穿戴 3 分解 4 强化 5 功能介绍）
-- 台词权威文本见 docs/story/01-新手序章剧情.md，修改需同步
local STEP_LINES = {
    [1] = {
        title = "塔灵的低语",
        lines = {
            "欢迎来到万灵塔，后来者。",
            "我叫不出你的名字——不是不愿，是你自己把它弄丢了。",
            "如果你想知道自己是谁，就向上走。塔会把你失去的，一层一层还给你。",
        },
        guide = "塔灵将替你演示战斗：击杀第一只怪物",
        page = "play",
        autoRunStart = true,
        -- 演示战斗：全屏锁定，禁止任何操作（含登塔按钮）
        lockInput = true,
    },
    [2] = {
        title = "战斗的馈赠",
        lines = {
            "很好。你听见了——那是力量落进掌心时的声音。",
            "看看你的行囊：一件武器，一件护具。",
            "按塔灵的指引，把武器穿戴起来。",
        },
        guide = "在装备页选中武器，点击【快捷穿戴】",
        page = "equip",
        -- 操作教学：只允许点击高亮目标，其余全部拦截
        lockInput = false,
    },
    [3] = {
        title = "物尽其用",
        lines = {
            "武器已经就位。但行囊里那件多余的白装，留着只会蒙尘。",
            "深渊不会因为你的慷慨而手下留情——每一分资源都要变成力量。",
            "按塔灵的指引，分解掉多余的护具。",
        },
        guide = "在背包页点击【一键分解】，勾选白装护具后确认",
        page = "bag",
        lockInput = false,
    },
    [4] = {
        title = "百炼成钢",
        lines = {
            "分解得到的碎片可用于强化。这次教学武器的首次强化，由塔灵免费助你完成。",
            "记住：你的名字可以被忘记，但你的锋芒不会。",
            "按塔灵的指引，完成一次强化。",
        },
        guide = "在装备页点击【强化】，确认强化武器",
        page = "equip",
        lockInput = false,
    },
    [5] = {
        title = "万灵塔的诸面",
        lines = {
            "你已经学会生存：战斗、拾取、取舍、打磨。",
            "塔里还有许多入口——补给、任务、活动、许愿与记忆。",
            "接下来塔灵只作介绍，不必操作；看完即可继续旅程。",
        },
        guide = "浏览各功能入口，点击「下一步」继续",
        page = "home",
        -- 纯告知：只允许点引导条的“下一步”，不要求操作业务按钮
        lockInput = false,
        featureTour = true,
    },
}

-- 引导子步骤：每一步详细的点击指引。
-- targetId / targetPrefix 用于高亮目标控件；waitEvent 表示等待服务端事件推进；
-- informOnly=true 纯告知（高亮入口 + 点下一步即可，不强制操作入口本身）。
local GUIDE_SUBSTEPS = {
    [1] = {
        { text = "塔灵正在替你演示战斗：击杀第一只怪物", lockInput = true, waitEvent = "tutorial_step" },
    },
    [2] = {
        { text = "点击【可穿戴装备】列表中的一件装备（蓝色框标记），选中它", targetPrefix = "tutorialCandidate" },
        { text = "点击下方【快捷穿戴】按钮，把装备穿上", targetId = "tutorialEquipNow" },
    },
    -- 分解教学与穿戴一致：先点主按钮，再在确认弹窗里完成操作。
    [3] = {
        { text = "点击【一键分解】（蓝色框标记），打开分解界面", targetId = "tutorialDecompose" },
        { text = "勾选一件多余的白装护具（蓝色框标记），再点【确认分解】", targetPrefix = "tutorialDispositionCandidate", waitEvent = "equipment_decomposed" },
    },
    [4] = {
        { text = "点击下方【强化】按钮（蓝色框标记），打开强化", targetId = "tutorialStrengthen" },
        { text = "在强化确认中点击【确认强化】（蓝色框标记），完成强化", targetId = "tutorialStrengthenConfirm", waitEvent = "equipment_strengthened" },
    },
    -- 功能介绍：只告知入口位置，点「下一步」推进；看完后服务端完成序章。
    [5] = {
        { text = "右上角【VIP】：每日补给与特权加成入口", targetId = "tutorialFeatureVip", informOnly = true },
        { text = "左侧【任务】：新手/日常/成就奖励在这里领取", targetId = "tutorialFeatureQuest", informOnly = true },
        { text = "左侧【活动】：签到与限时玩法集中在此", targetId = "tutorialFeatureActivity", informOnly = true },
        { text = "首页【许愿池】：许愿券抽取装备，十连更优惠", targetId = "tutorialFeatureWish", informOnly = true },
        { text = "底部导航：背包 / 装备 / 登塔 / 市场随时切换", targetId = "tutorialFeatureNav:bag", informOnly = true },
        { text = "左上【邮件】收奖励，右上【剧情】可回顾万灵记忆", targetId = "tutorialFeatureMail", informOnly = true },
        { text = "介绍完成。点击「完成序章」领取塔灵赠礼", completeTutorial = true, informOnly = true },
    },
}

-- 递归查找控件：兼容 instance.id 与 props.id 两种设置方式。
-- 注意：UI.FindById 只认构造时写入的 instance.id；页面代码通过
-- `widget.props.id = "..."` 动态打标的目标必须在这里兜底匹配。
local function FindWidgetById(widget, id)
    if not widget or type(widget) ~= "table" or not id then return nil end
    if widget.id == id or (widget.props and widget.props.id == id) then
        return widget
    end
    for _, child in ipairs(widget.children or {}) do
        local found = FindWidgetById(child, id)
        if found then return found end
    end
    return nil
end

local function FindGuideWidgetById(id)
    local found = FindWidgetById(root_, id)
    if found then return found end
    -- 兜底：从 UI 根再搜一次，避免 root_ 与当前页面树短暂不一致。
    if UI.GetRoot then
        local uiRoot = UI.GetRoot()
        if uiRoot and uiRoot ~= root_ then
            return FindWidgetById(uiRoot, id)
        end
    end
    return nil
end

local function IsWidgetWithinAllowedTree(widget)
    local current = widget
    while current do
        if allowedWidgets_[current] then return true end
        current = current.parent
    end
    return false
end

local function NowSeconds()
    if time and time.GetElapsedTime then
        return time:GetElapsedTime()
    end
    if time and time.elapsedTime then
        return time.elapsedTime
    end
    return 0
end

local function NotifyBlockedInput()
    local now = NowSeconds()
    if now > 0 and now - blockedToastAt_ < BLOCKED_TOAST_COOLDOWN then
        return
    end
    blockedToastAt_ = now
    if UI.Toast and UI.Toast.Show then
        UI.Toast.Show("请等待下一步指引", {
            duration = 1.4,
            variant = "info",
            position = "bottom",
        })
    end
end

-- 输入硬锁的第一道门：在 UI/手势处理前记录该 pointer 是否获准。
-- 即使覆盖层因页面重建暂时不存在，未命中白名单的输入仍会被拒绝。
local function HandleInputGate(event)
    if not active_ then return end
    local pointerId = event.pointerId or 0
    if event.type == PointerEvent.Types.PointerDown then
        local scale = UI.GetScale and UI.GetScale() or 1
        local x = (event.x or 0) / math.max(scale, 0.001)
        local y = (event.y or 0) / math.max(scale, 0.001)
        local hit = UI.FindWidgetAt and UI.FindWidgetAt(x, y) or nil
        local allowed = hit ~= nil and IsWidgetWithinAllowedTree(hit)
        lockedPointers_[pointerId] = not allowed
        if not allowed then
            NotifyBlockedInput()
            event:StopPropagation()
        end
    elseif lockedPointers_[pointerId] == false then
        -- 本次 pointer-down 已命中白名单，后续 move/up 保持放行。
        return
    else
        -- 没有获准 down 的悬停、游离 move/up 也不得进入控件树。
        lockedPointers_[pointerId] = true
        event:StopPropagation()
    end
end

local function InstallInputLock()
    if inputLockInstalled_ then return end
    inputLockInstalled_ = true
    originalHandlePointerEvent_ = UI.HandlePointerEvent
    -- InputAdapter 的回调动态读取 UI.HandlePointerEvent；在这里建立最终安全边界。
    wrappedHandlePointerEvent_ = function(event)
        local pointerId = event.pointerId or 0
        local blocked = active_ and lockedPointers_[pointerId] == true
        if not blocked and originalHandlePointerEvent_ then
            originalHandlePointerEvent_(event)
        end
        if event.type == PointerEvent.Types.PointerUp
            or event.type == PointerEvent.Types.PointerCancel
        then
            lockedPointers_[pointerId] = nil
        end
    end
    UI.HandlePointerEvent = wrappedHandlePointerEvent_
    -- 必须最高优先级：先于 Gesture 与引导推进监听确定本次输入是否合法。
    inputGateListeners_ = {
        [PointerEvent.Types.PointerDown] = Input.On(
            PointerEvent.Types.PointerDown, HandleInputGate, 1000000
        ),
        [PointerEvent.Types.PointerMove] = Input.On(
            PointerEvent.Types.PointerMove, HandleInputGate, 1000000
        ),
        [PointerEvent.Types.PointerUp] = Input.On(
            PointerEvent.Types.PointerUp, HandleInputGate, 1000000
        ),
        [PointerEvent.Types.PointerCancel] = Input.On(
            PointerEvent.Types.PointerCancel, HandleInputGate, 1000000
        ),
    }
end

local function UninstallInputLock()
    if not inputLockInstalled_ then return end
    for eventType, listenerId in pairs(inputGateListeners_) do
        Input.Off(eventType, listenerId)
    end
    inputGateListeners_ = {}
    if UI.HandlePointerEvent == wrappedHandlePointerEvent_ then
        UI.HandlePointerEvent = originalHandlePointerEvent_
    end
    originalHandlePointerEvent_ = nil
    wrappedHandlePointerEvent_ = nil
    inputLockInstalled_ = false
    lockedPointers_ = {}
end

local function ClearAllowedWidgets()
    allowedWidgets_ = {}
end

local function ClearInputState()
    ClearAllowedWidgets()
    lockedPointers_ = {}
end

local function ConfigureTutorialDialogs()
    DialogCoordinator.SetBlocked(true)
    DialogCoordinator.SetAllowedPrefixes {
        "equipment-disposition:",
        "equipment-strengthen",
        "equipment-filter:",
        "decompose-preview",
        "tutorial-reset",
    }
end

local function RestoreDialogs()
    DialogCoordinator.SetBlocked(false)
    DialogCoordinator.SetAllowedPrefixes {}
end

local loadoutResetDone_ = false

local function NeedsLoadoutReset(game)
    -- 本会话已清过一次后不再拦截，避免穿戴后再次被判定为老号而卡死。
    if loadoutResetDone_ then return false end
    game = game or GameStateAdapter.GetViewState()
    -- 仅在进入第二步穿戴教学前拦截；第三步及之后不应再弹清档。
    if step_ ~= 2 then return false end
    if #(game.overflowLoot or {}) > 0 then return true end
    local equippedCount = 0
    for _, itemId in pairs(game.equippedSlots or game.equipped or {}) do
        if itemId then equippedCount = equippedCount + 1 end
    end
    local equipmentCount = 0
    local hasTutorialWeapon = false
    local hasTutorialArmor = false
    for _, item in ipairs(game.inventory or {}) do
        if item and item.equipmentId then
            equipmentCount = equipmentCount + 1
            if item.source == "tutorial_drop" and item.slot == "weapon" then
                hasTutorialWeapon = true
            end
            if item.source == "tutorial_drop" and item.slot ~= "weapon" then
                hasTutorialArmor = true
            end
        end
    end
    -- 老号特征：已有穿戴，或装备明显多于教学保底，或缺少教学掉落。
    if equippedCount > 0 then return true end
    if equipmentCount > 2 then return true end
    if not hasTutorialWeapon or not hasTutorialArmor then return true end
    return false
end

local function EnsureTutorialLoadoutThen(onReady)
    if not NeedsLoadoutReset() then
        if onReady then onReady() end
        return
    end
    local clearing = false
    CommonPromptDialog.Show {
        kind = "confirm",
        priority = 500,
        queueKey = "tutorial-reset-loadout",
        title = "检测到老号装备数据",
        message = "你当前已有穿戴/大量装备。继续序章教学前需要清空全部装备数据。",
        lines = {
            "将清除：背包装备、已穿戴、临时战利品箱。",
            "清理后会自动补发教学武器与护具。",
            "该操作仅用于测试号/老号序章兜底。",
        },
        showClose = false,
        cancelText = nil,
        confirmText = "清除全部装备数据",
        closeOnOverlay = false,
        zIndex = 3920,
        tutorialConfirmId = "tutorialResetLoadoutConfirm",
        onConfirm = function()
            if clearing then return false end
            clearing = true
            ServerClient.ResetTutorialLoadout(function(response)
                clearing = false
                if not (response and response.ok) then
                    if UI.Toast and UI.Toast.Show then
                        UI.Toast.Show(
                            (response and (response.reason or response.code)) or "清理失败，请重试",
                            { duration = 2.0, variant = "error", position = "bottom" }
                        )
                    end
                    -- 失败后再次弹出，避免卡死
                    EnsureTutorialLoadoutThen(onReady)
                    return
                end
                loadoutResetDone_ = true
                if UI.Toast and UI.Toast.Show then
                    UI.Toast.Show("装备数据已清空，继续序章教学", {
                        duration = 1.8, variant = "success", position = "bottom",
                    })
                end
                if onReady then onReady() end
            end)
            return true
        end,
    }
end

local function AllowWidget(widget)
    if widget then allowedWidgets_[widget] = true end
end

local function IsEquippedItem(game, item)
    if not item or item.id == nil then return false end
    local equipped = game.equippedSlots or game.equipped or {}
    for _, equippedItem in pairs(equipped) do
        if type(equippedItem) == "table" and equippedItem.id == item.id then
            return true
        end
        if equippedItem == item.id then return true end
    end
    return false
end

local function FindTutorialDispositionCandidate()
    if not root_ then return nil end
    local game = GameStateAdapter.GetViewState()
    -- 优先教程护具；老号满包时允许任意未穿戴非武器装备兜底。
    local fallback = nil
    for _, item in ipairs(game.inventory or {}) do
        if not IsEquippedItem(game, item) and item.equipmentId and not item.locked and not item.aidLocked then
            local widget = FindGuideWidgetById("tutorialDispositionCandidate:" .. tostring(item.id))
            if widget then
                if item.source == "tutorial_drop" and item.slot ~= "weapon" then
                    return widget
                end
                if not fallback and item.slot ~= "weapon" then
                    fallback = widget
                elseif not fallback then
                    fallback = widget
                end
            end
        end
    end
    return fallback
end

local function RefreshInputWhitelist()
    ClearAllowedWidgets()
    if not active_ or not root_ then return end
    AllowWidget(FindGuideWidgetById("recoveryAccess"))
    AllowWidget(FindGuideWidgetById("stageLoadingRetry"))
    require("client.UI.DialogSettingsAccess").AllowInTree(root_, AllowWidget)
    AllowWidget(FindGuideWidgetById("recoverySettingsPanel"))
    if phase_ == "cg" then
        AllowWidget(FindGuideWidgetById("tutorialCgSkip"))
        return
    end
    if phase_ == "dialog" then
        AllowWidget(FindGuideWidgetById("tutorialDialogContinue"))
        AllowWidget(FindGuideWidgetById("tutorialResetLoadoutConfirm"))
        return
    end
    if phase_ ~= "guide" then return end
    -- 顶部引导条 / 下一步按钮始终放行。
    AllowWidget(FindGuideWidgetById("tutorialGuideHint"))
    AllowWidget(FindGuideWidgetById("tutorialGuideNext"))
    AllowWidget(guideHint_)
    do
        local subSteps = GUIDE_SUBSTEPS[step_] or {}
        local subStep = subSteps[guideIndex_]
        -- 功能介绍纯告知：只放行“下一步”，不开放业务入口点击。
        if subStep and subStep.informOnly then
            return
        end
        -- 操作教学：放行当前高亮目标。
        AllowWidget(guideTarget_)
        if subStep and subStep.targetId then
            AllowWidget(FindGuideWidgetById(subStep.targetId))
        end
    end
    local function AllowByIdPrefix(widget, prefix)
        if not widget then return end
        local id = widget.id or (widget.props and widget.props.id)
        if type(id) == "string" and string.sub(id, 1, #prefix) == prefix then
            AllowWidget(widget)
        end
        for _, child in ipairs(widget.children or {}) do
            AllowByIdPrefix(child, prefix)
        end
    end
    local searchRoots = { root_ }
    if UI.GetRoot then
        local uiRoot = UI.GetRoot()
        if uiRoot and uiRoot ~= root_ then
            searchRoots[#searchRoots + 1] = uiRoot
        end
    end

    -- 第二步：穿戴候选 + 快捷穿戴整段放行，避免只高亮却点不到。
    if step_ == 2 then
        AllowWidget(FindGuideWidgetById("tutorialEquipNow"))
        for _, root in ipairs(searchRoots) do
            AllowByIdPrefix(root, "tutorialCandidate:")
        end
    -- 第三步：整段分解教学都放行主按钮/候选/确认。
    -- 不能只按 guideIndex 精确放行——若几何命中没推进子步骤，弹窗会全被锁死。
    elseif step_ == 3 then
        AllowWidget(FindGuideWidgetById("tutorialDecompose"))
        local candidate = FindTutorialDispositionCandidate()
        AllowWidget(candidate)
        for _, root in ipairs(searchRoots) do
            AllowByIdPrefix(root, "tutorialDispositionCandidate:")
            AllowByIdPrefix(root, "tutorialDispositionConfirm")
        end
        AllowWidget(FindGuideWidgetById("tutorialDispositionConfirm"))
    -- 强化教学：主按钮 + 确认都放行，避免卡在弹窗。
    elseif step_ == 4 then
        AllowWidget(FindGuideWidgetById("tutorialStrengthen"))
        AllowWidget(FindGuideWidgetById("tutorialStrengthenConfirm"))
        for _, root in ipairs(searchRoots) do
            AllowByIdPrefix(root, "tutorialStrengthenConfirm")
        end
    end
end

-- 根据子步骤查找高亮目标控件
local function FindGuideTarget(subStep)
    if subStep.targetId then
        return FindGuideWidgetById(subStep.targetId)
    end
    if subStep.targetPrefix == "tutorialCandidate" then
        local game = GameStateAdapter.GetViewState()
        local fallback = nil
        for _, item in ipairs(game.inventory or {}) do
            if item.equipmentId and not IsEquippedItem(game, item) then
                local widget = FindGuideWidgetById("tutorialCandidate:" .. tostring(item.id))
                if widget then
                    -- 优先教程武器；没有时任意可穿戴装备兜底，避免老号卡死。
                    if item.source == "tutorial_drop" and item.slot == "weapon" then
                        return widget
                    end
                    if not fallback and item.slot == "weapon" then
                        fallback = widget
                    elseif not fallback then
                        fallback = widget
                    end
                end
            end
        end
        return fallback
    end
    if subStep.targetPrefix == "tutorialRecycleFilterRarity" then
        -- 筛选弹窗：优先高亮普通/白色，找不到再找保存按钮。
        local common = FindGuideWidgetById("tutorialRecycleFilterRarity:common")
        if common then return common end
        return FindGuideWidgetById("tutorialDecomposeFilterConfirm")
    end
    if subStep.targetPrefix == "tutorialDispositionCandidate" then
        -- 已勾选后优先引导【确认分解】；未勾选时引导候选护具。
        if tutorialDispositionSelected_ then
            local confirm = FindGuideWidgetById("tutorialDispositionConfirm")
            if confirm then return confirm end
        end
        -- 分解弹窗异步打开：优先教程护具，否则任意候选。
        local candidate = FindTutorialDispositionCandidate()
        if candidate then return candidate end
        -- 弹窗尚未挂载时，允许重开一键分解，避免目标长时间为空。
        return FindGuideWidgetById("tutorialDecompose")
    end
    return nil
end

local function CurrentGuideText(subStep)
    if not subStep then return "" end
    if step_ == 3 and guideIndex_ == 2 and tutorialDispositionSelected_ then
        return "已勾选多余护具，点击【确认分解】完成操作"
    end
    return subStep.text or ""
end

-- 清理引导拦截面板
local function ClearGuideLocks()
    for _, panel in ipairs(guideLockPanels_) do
        if panel and panel.parent then panel.parent:RemoveChild(panel) end
    end
    guideLockPanels_ = {}
end

-- 全屏单块锁定（演示/等待阶段：完全不可点击）
local function BuildFullLock()
    -- 遮罩绝不参与命中：真正拦截只靠输入白名单。
    -- 若 clickable 遮罩盖在最上层，FindWidgetAt 永远点到遮罩，导致“请等待下一步指引”。
    local panel = UI.Panel {
        position = "absolute",
        left = 0, top = 0, right = 0, bottom = 0,
        clickable = false,
        pointerEvents = "none",
        backgroundColor = { 0, 0, 0, 0 },
    }
    layer_:AddChild(panel)
    guideLockPanels_[#guideLockPanels_ + 1] = panel
end

-- 四块拦截（目标区域镂空）：只能点击高亮目标，其余全部拦截。
-- ⚠️ 每块都必须显式给出 left+width，否则绝对定位下宽度为 0，顶/底区域将失去拦截。
local function BuildTargetLock(bounds)
    local vw, vh = UI.GetViewportSize()
    local x, y, w, h = bounds.x, bounds.y, bounds.w, bounds.h
    local quads = {
        { left = 0, top = 0, width = vw, height = y },
        { left = 0, top = y + h, width = vw, height = math.max(0, vh - y - h) },
        { left = 0, top = y, width = math.max(0, x), height = h },
        { left = x + w, top = y, width = math.max(0, vw - x - w), height = h },
    }
    for _, quad in ipairs(quads) do
        if quad.height > 0 and quad.width > 0 then
            local panel = UI.Panel {
                position = "absolute",
                left = quad.left,
                top = quad.top,
                width = quad.width,
                height = quad.height,
                -- 仅视觉占位/未来可扩展，不参与命中；拦截交给白名单。
                clickable = false,
                pointerEvents = "none",
                backgroundColor = { 0, 0, 0, 0 },
            }
            layer_:AddChild(panel)
            guideLockPanels_[#guideLockPanels_ + 1] = panel
        end
    end
end

-- 第二步完成条件：任意部位已穿戴即可，不依赖 equipment_equipped 事件时序。
local function HasAnyEquippedItem(game)
    game = game or GameStateAdapter.GetViewState()
    local equipped = game.equippedSlots or game.equipped or {}
    for _, value in pairs(equipped) do
        if value ~= nil and value ~= false and value ~= "" then
            return true
        end
    end
    return false
end

local function TryCompleteEquipGuide()
    if not active_ or phase_ ~= "guide" or step_ ~= 2 then return false end
    if not HasAnyEquippedItem() then return false end
    -- 部位已有装备：直接进入第三步对话，避免卡在“请稍候”。
    ClearPendingStepIntro()
    step_ = 3
    tutorialDispositionSelected_ = false
    guideRebuildPending_ = false
    guideRetryPending_ = false
    ShowStepIntro()
    return true
end

-- 显示当前引导子步骤：详细文案 + 全屏锁定（目标镂空）+ 目标高亮框
ShowGuideSubStep = function()
    if not layer_ or not root_ then return end
    if TryCompleteEquipGuide() then return end
    ClearAllowedWidgets()
    ClearGuideLocks()
    if guideHighlight_ and guideHighlight_.parent then guideHighlight_.parent:RemoveChild(guideHighlight_) end
    guideHighlight_ = nil
    guideTarget_ = nil
    local subSteps = GUIDE_SUBSTEPS[step_] or {}
    local subStep = subSteps[guideIndex_]
    if not subStep then return end

    local target = FindGuideTarget(subStep)
    local function ReadBounds(widget)
        if not widget then return nil end
        local ok, bounds = pcall(function()
            if widget.GetAbsoluteLayoutForHitTest then
                return widget:GetAbsoluteLayoutForHitTest()
            end
            if widget.GetAbsoluteLayout then
                return widget:GetAbsoluteLayout()
            end
            return nil
        end)
        if not ok or type(bounds) ~= "table" then return nil end
        local w = tonumber(bounds.w) or 0
        local h = tonumber(bounds.h) or 0
        if w <= 1 or h <= 1 then return nil end
        -- 过滤明显越界的错误坐标，避免高亮画飞。
        local vw, vh = UI.GetViewportSize()
        if bounds.x + w < -20 or bounds.y + h < -20 then return nil end
        if bounds.x > (vw or 0) + 20 or bounds.y > (vh or 0) + 20 then return nil end
        return bounds
    end
    local bounds = ReadBounds(target)
    local lock = subStep.lockInput == true
    local informOnly = subStep.informOnly == true
    local needsTarget = (subStep.targetId ~= nil or subStep.targetPrefix ~= nil) and not lock
    local nextButtonText = subStep.completeTutorial and "完成序章" or "下一步"
    -- 所有引导步骤都显示「下一步」，避免目标点不到时卡死。
    local showNextAlways = true

    -- 目标控件尚未挂载（切页/异步弹窗）或 Yoga 未布局：持续重试，禁止永久全屏锁死。
    if needsTarget and (not target or not bounds) then
        guideRetryPending_ = true
        guideTarget_ = target
        -- 遮罩不抢命中；白名单先放行目标 id，布局好后再画高亮框。
        layer_.props.clickable = false
        layer_.props.pointerEvents = "box-none"
        BuildFullLock()
        ShowGuide(CurrentGuideText(subStep), showNextAlways, nextButtonText)
        RefreshInputWhitelist()
        return
    end
    guideRetryPending_ = false
    guideRetryCount_ = 0

    if lock or not target or not bounds then
        -- 演示 / 纯等待 / 无高亮目标：只靠白名单
        layer_.props.clickable = false
        layer_.props.pointerEvents = "box-none"
        BuildFullLock()
        -- 功能介绍最后一页无目标，仍要显示“完成序章”。
        ShowGuide(CurrentGuideText(subStep), showNextAlways, nextButtonText)
        RefreshInputWhitelist()
    else
        -- 操作步骤 / 功能介绍：高亮框 + 白名单
        layer_.props.clickable = false
        layer_.props.pointerEvents = "box-none"
        -- 纯告知不需要镂空可点；仍画高亮框提示位置。
        if not informOnly then
            BuildTargetLock(bounds)
        else
            BuildFullLock()
        end
        guideTarget_ = target
        -- 引导框使用游戏 focus 蓝，和 UI 选中态一致。
        local guideBlue = C.focus or { 111, 231, 255, 255 }
        guideHighlight_ = UI.Panel {
            position = "absolute",
            left = bounds.x - 10, top = bounds.y - 10,
            width = bounds.w + 20, height = bounds.h + 20,
            zIndex = LAYER_Z + 90,
            pointerEvents = "none",
            borderWidth = 6,
            borderColor = guideBlue,
            borderRadius = 12,
            boxShadow = {
                color = { guideBlue[1] or 111, guideBlue[2] or 231, guideBlue[3] or 255, 180 },
                offsetX = 0, offsetY = 0, blurRadius = 24,
            },
        }
        layer_:AddChild(guideHighlight_)
        -- 操作步骤也给“下一步”兜底；功能介绍主路径就是点下一步。
        ShowGuide(CurrentGuideText(subStep), true, nextButtonText)
        RefreshInputWhitelist()
    end
end

-- 第二步兜底：未穿戴时自动穿上教学武器（优先 tutorial_drop，其次任意可穿戴）。
local autoEquipPending_ = false
local function FindTutorialEquipCandidate(game)
    game = game or GameStateAdapter.GetViewState()
    local fallback = nil
    for _, item in ipairs(game.inventory or {}) do
        if item and item.id and item.equipmentId and not IsEquippedItem(game, item) then
            if item.source == "tutorial_drop" and item.slot == "weapon" then
                return item
            end
            if not fallback and item.slot == "weapon" then
                fallback = item
            elseif not fallback then
                fallback = item
            end
        end
    end
    return fallback
end

local function AutoEquipForTutorial(onDone)
    if autoEquipPending_ then return false end
    local game = GameStateAdapter.GetViewState()
    if HasAnyEquippedItem(game) then
        if onDone then onDone(true) end
        return true
    end
    local item = FindTutorialEquipCandidate(game)
    if not (item and item.id) then
        if UI.Toast and UI.Toast.Show then
            UI.Toast.Show("没有可穿戴的教学装备", {
                duration = 2.0,
                variant = "warning",
                position = "bottom",
            })
        end
        if onDone then onDone(false) end
        return false
    end
    autoEquipPending_ = true
    ServerClient.Equip(item.id, function(response)
        autoEquipPending_ = false
        if not (response and response.ok) then
            if UI.Toast and UI.Toast.Show then
                UI.Toast.Show((response and (response.reason or response.code)) or "自动穿戴失败", {
                    duration = 2.0,
                    variant = "warning",
                    position = "bottom",
                })
            end
            if onDone then onDone(false) end
            return
        end
        if not TryCompleteEquipGuide() and onDone then
            onDone(true)
        end
    end)
    return true
end

-- 推进到下一个子步骤（或完成功能介绍）。
-- 面板重建延迟到下一帧：保证本次点击的 pointer-up 仍能命中目标控件。
local completingTutorial_ = false
AdvanceGuideSubStep = function()
    local subSteps = GUIDE_SUBSTEPS[step_] or {}
    local current = subSteps[guideIndex_]
    -- 穿戴步骤：点「下一步」时若还没穿上，自动帮玩家穿上。
    if step_ == 2 and not HasAnyEquippedItem() then
        AutoEquipForTutorial()
        return
    end
    if current and current.completeTutorial then
        if completingTutorial_ then return end
        completingTutorial_ = true
        ServerClient.CompleteTutorial(function(response)
            completingTutorial_ = false
            if not (response and response.ok) then
                if UI.Toast and UI.Toast.Show then
                    UI.Toast.Show(
                        (response and (response.reason or response.code)) or "完成序章失败，请重试",
                        { duration = 2.0, variant = "error", position = "bottom" }
                    )
                end
                return
            end
            -- 成功后由 tutorial_completed 事件触发 FinishTutorial。
        end)
        return
    end
    if guideIndex_ < #subSteps then
        guideIndex_ = guideIndex_ + 1
        guideRebuildPending_ = true
    end
end

-- 目标点击检测：点击命中高亮目标 → 推进子步骤。
-- 注意：这只是兜底。主推进路径应走 TutorialController.NotifyAction（按钮 onClick），
-- 避免坐标/scale/页面重建导致“点到了但子步骤没推进”。
local function HandleGuidePointerDown(event)
    if not active_ or phase_ ~= "guide" then return end
    local subSteps = GUIDE_SUBSTEPS[step_] or {}
    local subStep = subSteps[guideIndex_]
    -- 功能介绍只靠「下一步」推进，点高亮入口不推进。
    if subStep and subStep.informOnly then return end
    local scale = UI.GetScale and UI.GetScale() or 1
    local x = (event.x or 0) / math.max(scale, 0.001)
    local y = (event.y or 0) / math.max(scale, 0.001)
    local function Hit(target)
        if not (target and target.GetAbsoluteLayoutForHitTest) then return false end
        local ok, bounds = pcall(target.GetAbsoluteLayoutForHitTest, target)
        return ok and bounds
            and (bounds.w or 0) > 0 and (bounds.h or 0) > 0
            and x >= bounds.x and x <= bounds.x + bounds.w
            and y >= bounds.y and y <= bounds.y + bounds.h
    end
    if Hit(guideTarget_) then
        AdvanceGuideSubStep()
        return
    end
    -- 兜底：即使 guideTarget_ 因重建失效，也按当前子步骤 id 再测一次。
    if subStep and subStep.targetId then
        if Hit(FindGuideWidgetById(subStep.targetId)) then
            AdvanceGuideSubStep()
        end
    end
end

local function RegisterGuideListener()
    if guidePointerListener_ then return end
    guidePointerListener_ = Input.On(PointerEvent.Types.PointerDown, HandleGuidePointerDown, -1000)
end

local function UnregisterGuideListener()
    if guidePointerListener_ then
        Input.Off(PointerEvent.Types.PointerDown, guidePointerListener_)
        guidePointerListener_ = nil
    end
end

local function RemoveLayer()
    -- 视频纹理占用大：移除前必须 Destroy，避免 GPU 内存堆积
    if videoPlayer_ and videoPlayer_.Destroy then
        pcall(videoPlayer_.Destroy, videoPlayer_)
    end
    videoPlayer_ = nil
    ClearGuideLocks()
    if layer_ then layer_:Destroy() end
    layer_ = nil
end

local function currentTutorial()
    local game = GameStateAdapter.GetViewState()
    return game.tutorial or {}
end

--- 显示引导提示条（顶部横幅）。
--- showNext: 显示右侧推进按钮；buttonText 可覆盖默认文案。
ShowGuide = function(text, showNext, buttonText)
    if not layer_ or not root_ then return end
    if guideHint_ and guideHint_.parent then guideHint_.parent:RemoveChild(guideHint_) end
    local nextLabel = buttonText or "下一步"
    local nextButton = nil
    if showNext then
        nextButton = UI.Panel {
            id = "tutorialGuideNext",
            width = 240,
            height = 56,
            clickable = true,
            alignItems = "center",
            justifyContent = "center",
            backgroundImage = ASSETS.ui.buttonBlueWide,
            backgroundFit = "sliced",
            backgroundSlice = { 8, 8, 8, 8 },
            onClick = function()
                AdvanceGuideSubStep()
            end,
            children = {
                Kit.CompactTxt(nextLabel, 22, C.text, {
                    width = "100%",
                    height = 56,
                    textAlign = "center",
                    textStroke = { width = 2, color = "#000000" },
                    pointerEvents = "none",
                }),
            },
        }
    end
    local inset = UILayout.OverlayInsets()
    guideHint_ = UI.Panel {
        id = "tutorialGuideHint",
        position = "absolute",
        left = inset.left, top = inset.top, right = inset.right,
        height = 236,
        zIndex = LAYER_Z + 60,
        clickable = true,
        alignItems = "center",
        flexDirection = "column",
        gap = 10,
        paddingTop = 16,
        paddingBottom = 14,
        paddingLeft = 24,
        paddingRight = 24,
        backgroundImage = ASSETS.ui.panelLarge,
        backgroundFit = "sliced",
        backgroundSlice = { 12, 12, 12, 12 },
        borderWidth = 3,
        borderColor = C.focus,
        boxShadow = {
            color = { 0, 0, 0, 180 },
            offsetX = 0, offsetY = 8, blurRadius = 18,
        },
        children = {
            UI.Panel {
                width = "100%",
                flexGrow = 1,
                flexDirection = "row",
                alignItems = "center",
                gap = 16,
                children = {
                    UI.Panel {
                        width = 88, height = 88, flexShrink = 0,
                        backgroundImage = PORTRAIT,
                        backgroundFit = "contain",
                    },
                    UI.Panel { flexGrow = 1, flexBasis = 0, gap = 6, children = {
                        Kit.Txt("新手剧情 · 序章", 24, C.gold, { width = "100%", height = 34, textAlign = "left", textStroke = { width = 2, color = "#000000" } }),
                        Kit.MultiTxt(text or "", 20, C.text, { width = "100%", height = 86, textAlign = "left", maxLines = 4, textStroke = { width = 1, color = "#000000" } }),
                    } },
                },
            },
            showNext and nextButton or nil,
        },
    }
    layer_:AddChild(guideHint_)
end

--- 对话弹层（插画 + 台词 + 确认）。
local function ShowDialog(stepData, onConfirm)
    if not root_ then return end
    RemoveLayer()
    -- 继续按钮构造时写 id，确保对话阶段白名单稳定命中。
    local continueButton = UI.Panel {
        id = "tutorialDialogContinue",
        width = 240,
        height = 72,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = ASSETS.ui.dialogConfirm,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        onClick = function()
            if onConfirm then onConfirm() end
        end,
        children = {
            Kit.CompactTxt("继续", 20, C.text, {
                width = "100%",
                height = 72,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
        },
    }
    layer_ = UI.Panel {
        position = "absolute",
        left = 0, top = 0, right = 0, bottom = 0,
        zIndex = LAYER_Z,
        clickable = true,
        backgroundColor = { 4, 10, 22, 205 },
        children = {
            -- 背景插画（登塔背景）
            UI.Panel {
                position = "absolute", left = 0, top = 0, right = 0, bottom = 0,
                backgroundImage = ASSETS.bg,
                backgroundFit = "cover",
                opacity = 0.35,
                pointerEvents = "none",
            },
            -- 中央对话卡
            UI.Panel {
                position = "absolute",
                left = 110, right = 110,
                top = 300, height = 1050,
                alignItems = "center",
                justifyContent = "flex-start",
                gap = 20,
                paddingTop = 40,
                paddingLeft = 40,
                paddingRight = 40,
                backgroundImage = ASSETS.ui.panelLarge,
                backgroundFit = "sliced",
                backgroundSlice = { 12, 12, 12, 12 },
                borderWidth = 3,
                borderColor = C.border,
                borderRadius = 16,
                boxShadow = { color = { 0, 0, 0, 200 }, offsetX = 0, offsetY = 12, blurRadius = 26 },
                children = {
                    UI.Panel {
                        width = 220, height = 220, flexShrink = 0,
                        backgroundImage = PORTRAIT,
                        backgroundFit = "contain",
                    },
                    Kit.Txt(stepData.title or "塔灵", 30, C.gold, {
                        width = "100%", height = 44, textAlign = "center",
                        textStroke = { width = 2, color = "#000000" },
                    }),
                    UI.Panel { width = "100%", flexGrow = 1, flexBasis = 0, gap = 10, children = (function()
                        ---@type any[]
                        local lines = {}
                        for _, line in ipairs(stepData.lines or {}) do
                            lines[#lines + 1] = Kit.MultiTxt(line, 22, C.text, {
                                width = "100%", textAlign = "center",
                                maxLines = 2, textStroke = { width = 1, color = "#000000" },
                            })
                        end
                        return lines
                    end)() },
                    continueButton,
                },
            },
        },
    }
    require("client.UI.DialogSettingsAccess").Attach(layer_, false, { right = 30, top = 777, marginTop = 0 })
    root_:AddChild(layer_)
    RefreshInputWhitelist()
end

--- 播放开场 CG 视频。
local function PlayCg()
    if not root_ then return end
    RemoveLayer()
    local cgFinished_ = false
    local function FinishCg()
        if cgFinished_ or phase_ ~= "cg" then return end
        cgFinished_ = true
        phase_ = "dialog"
        ShowStepIntro()
    end
    local skipButton = UI.Panel {
        id = "tutorialCgSkip",
        width = 160,
        height = 64,
        clickable = true,
        alignItems = "center",
        justifyContent = "center",
        backgroundImage = ASSETS.ui.buttonBlueWide,
        backgroundFit = "sliced",
        backgroundSlice = { 8, 8, 8, 8 },
        onClick = function()
            FinishCg()
        end,
        children = {
            Kit.CompactTxt("跳过", 20, C.text, {
                width = "100%",
                height = 64,
                textAlign = "center",
                textStroke = { width = 2, color = "#000000" },
                pointerEvents = "none",
            }),
        },
    }
    layer_ = UI.Panel {
        position = "absolute",
        left = 0, top = 0, right = 0, bottom = 0,
        zIndex = LAYER_Z,
        clickable = true,
        backgroundColor = { 0, 0, 0, 255 },
        children = {
            Video.VideoPlayer {
                id = "tutorialCg",
                width = "100%",
                height = "100%",
                src = CG_VIDEO,
                autoPlay = true,
                loop = false,
                muted = false,
                volume = 1.0,
                objectFit = "cover",
                backgroundColor = { 0, 0, 0, 255 },
                -- 视频本体禁止点击暂停；右上角提供跳过入口。
                clickable = false,
                pointerEvents = "none",
                onReady = function(self)
                    videoPlayer_ = self
                end,
                onEnded = function()
                    FinishCg()
                end,
            },
            -- 右上角跳过
            UI.Panel {
                position = "absolute",
                right = 36,
                top = 48,
                width = 180,
                height = 80,
                zIndex = 10,
                alignItems = "center",
                justifyContent = "center",
                children = { skipButton },
            },
            -- 底部字幕提示
            Kit.CompactTxt("《序章·残刃与第一座塔》", 18, C.textSecondary, {
                position = "absolute", left = 0, right = 0, bottom = 60,
                width = "100%", height = 40, textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
                pointerEvents = "none",
            }),
        },
    }
    root_:AddChild(layer_)
    RefreshInputWhitelist()
end

--- 根据当前步骤展示对话与引导。
ShowStepIntro = function()
    if not active_ then return end
    -- 仅第二步穿戴教学前检测老号脏装备；穿戴后（step>=3）禁止再拦截。
    if step_ == 2 and NeedsLoadoutReset() then
        phase_ = "dialog"
        ClearInputState()
        EnsureTutorialLoadoutThen(function()
            if active_ then ShowStepIntro() end
        end)
        return
    end
    phase_ = "dialog"
    ClearInputState()
    -- 进入新步骤对话：作废可能残留的延迟重建/布局重试标记
    guideRebuildPending_ = false
    guideRetryPending_ = false
    guideRetryCount_ = 0
    local stepData = STEP_LINES[step_] or STEP_LINES[1]
    LoadingController.PrefetchTutorial(step_)
    ShowDialog(stepData, function()
        -- 确认后：进入引导子步骤（每一步详细的点击指引 + 目标高亮）
        phase_ = "guide"
        do
            local ok, ItemTips = pcall(require, "client.ItemTips")
            if ok and ItemTips and ItemTips.Hide then
                ItemTips.Hide("tutorial-guide")
            end
        end
        local targetPage = stepData.page
        local expectedStep = step_
        RemoveLayer()
        phase_ = "loading"
        local function BeginGuide()
            if not active_ or step_ ~= expectedStep then return end
            phase_ = "guide"
            layer_ = UI.Panel {
                position = "absolute",
                left = 0, top = 0, right = 0, bottom = 0,
                zIndex = LAYER_Z,
                clickable = false,
                pointerEvents = "box-none",
                children = {},
            }
            root_:AddChild(layer_)
            RegisterGuideListener()
            guideIndex_ = 1
            -- 切页后页面控件要下一帧才有稳定布局：强制重试高亮。
            guideRetryPending_ = true
            guideRetryCount_ = 0
            ShowGuideSubStep()
            -- 教学战斗：自动开启挂机演示（服务端首杀/通关后自动停止，不持续挂机）
            if stepData.autoRunStart then
                LoadingController.PrefetchPage("equip")
                LoadingController.PrefetchPage("bag")
                ServerClient.AutoRun(true)
            end
        end
        if targetPage then
            require("client.NavigationController").SwitchPage(targetPage, { tutorial = true, onReady = BeginGuide })
        else
            BeginGuide()
        end
        RefreshInputWhitelist()
    end)
end

--- 完成剧情：展示奖励并清理演出层。
local function FinishTutorial(payload)
    active_ = false
    phase_ = "done"
    ClearPendingStepIntro()
    -- 序章完成：恢复所有弹窗与点击监听
    RestoreDialogs()
    ClearInputState()
    UnregisterGuideListener()
    UninstallInputLock()
    RemoveLayer()
    guideHint_ = nil
    guideHighlight_ = nil
    guideTarget_ = nil
    local RewardDialogView = require("client.RewardDialogView")
    local cards = {}
    RewardDialogView.AddCard(cards, ASSETS.items.gold, "金币", payload and payload.gold or 5000, "common", nil)
    RewardDialogView.AddCard(cards, ASSETS.items.crystal, "深渊碎片", payload and payload.fragments or 50, "common", nil)
    RewardDialogView.AddCard(cards, ASSETS.ui.wishJarRandom, "全随机罐", payload and payload.jars or 2, "common", nil)
    RewardDialogView.Show {
        title = "序章完成",
        message = "塔灵赠予你第一份厚礼",
        lines = { "首页顶部「万灵记忆」可随时回顾剧情。" },
        cards = cards,
        confirmText = "继续旅程",
        zIndex = 3900,
        onConfirm = function()
            local game = GameStateAdapter.GetViewState()
            if game.page ~= "home" then
                require("client.NavigationController").SwitchPage("home")
            end
        end,
    }
end

--- 事件驱动：服务端推进教程步骤 / 子步骤等待事件。
local function AdvanceGuideByEvent(kind)
    if not active_ or phase_ ~= "guide" then return end
    local subSteps = GUIDE_SUBSTEPS[step_] or {}
    local subStep = subSteps[guideIndex_]
    if subStep and subStep.waitEvent == kind then
        AdvanceGuideSubStep()
    end
end

local function QueueStepIntro(newStep)
    newStep = tonumber(newStep) or 0
    if newStep < 2 or newStep > 5 then return end
    -- 已在同一步对话/引导中：避免 equipment_equipped + tutorial_step 双事件重弹。
    if step_ == newStep and (phase_ == "dialog" or phase_ == "guide") and not pendingStepIntro_ then
        return
    end
    -- step 2 紧接首杀掉落：延后到飞入表现结束；其余步骤仍即时进入。
    if newStep == 2 and step_ < 2 then
        pendingStepIntro_ = 2
        pendingStepIntroWait_ = 0
        pendingStepIntroSawLoot_ = false
        -- 立刻给出反馈，避免玩家以为卡死。
        if phase_ == "guide" and ShowGuide then
            ShowGuide("首杀完成，战利品飞入中…", false)
        end
        return
    end
    ClearPendingStepIntro()
    step_ = newStep
    tutorialDispositionSelected_ = false
    guideIndex_ = 0
    guideRebuildPending_ = false
    guideRetryPending_ = false
    ShowStepIntro()
end

local function TryFlushPendingStepIntro(dt)
    if not pendingStepIntro_ or not active_ then return end
    pendingStepIntroWait_ = pendingStepIntroWait_ + (dt or 0)
    local presenting = false
    local ok, PlayEffects = pcall(require, "client.PlayEffects")
    if ok and PlayEffects and PlayEffects.IsLootPresentationActive then
        local activeOk, active = pcall(PlayEffects.IsLootPresentationActive)
        presenting = activeOk and active == true
    end
    if presenting then
        pendingStepIntroSawLoot_ = true
    end
    local waitedMin = pendingStepIntroWait_ >= STEP_INTRO_MIN_WAIT
    local finishedLoot = pendingStepIntroSawLoot_ and not presenting
    -- 没看到掉落也允许在最短等待后继续，避免首杀后永久卡死。
    local noLootButWaited = (not pendingStepIntroSawLoot_) and waitedMin
    local timedOut = pendingStepIntroWait_ >= STEP_INTRO_MAX_WAIT
    if (waitedMin and (finishedLoot or noLootButWaited)) or timedOut then
        local expected = pendingStepIntro_
        ClearPendingStepIntro()
        -- 首杀完成后无论当前 phase 是否被重建，都强制进入下一步对话。
        step_ = expected
        tutorialDispositionSelected_ = false
        phase_ = "guide"
        ShowStepIntro()
    end
end

local function HandleTutorialEvent(kind, value)
    if kind == "tutorial_step" then
        local newStep = tonumber(value and value.step) or 0
        if newStep >= 2 and newStep <= 5 then
            if active_ then
                -- 不论当前处于 guide/dialog/页面重建，都必须重建新步骤。
                -- 事件可能紧跟 equipment_equipped 到达，不能只更新 step_ 而留下旧层。
                QueueStepIntro(newStep)
            else
                ClearPendingStepIntro()
                step_ = newStep
                tutorialDispositionSelected_ = false
            end
        end
    elseif kind == "tutorial_completed" then
        if active_ then
            FinishTutorial(value)
        end
    elseif kind == "equipment_equipped" then
        if not TryCompleteEquipGuide() then
            AdvanceGuideByEvent(kind)
        end
    elseif kind == "equipment_decomposed"
        or kind == "equipment_strengthened" then
        AdvanceGuideByEvent(kind)
    end
end

ServerClient.On("delta", function(payload)
    for _, event in ipairs((payload and payload.events) or {}) do
        local kind = event.kind or event.type
        if kind == "tutorial_step"
            or kind == "tutorial_completed"
            or kind == "equipment_equipped"
            or kind == "equipment_decomposed"
            or kind == "equipment_strengthened"
        then
            HandleTutorialEvent(kind, event)
        end
    end
end)

--- 评估是否开始新手剧情（登录后调用；已完成则不再触发）。
function TutorialController.Evaluate()
    if require("client.RecoveryState").suppressTutorial then return end
    if active_ then return end
    local tutorial = currentTutorial()
    if not tutorial or tutorial.completed then return end
    loadoutResetDone_ = false
    local game = GameStateAdapter.GetViewState()
    -- 未完成序章：从存档 step 继续；已完成由上方 early return 拦截。
    step_ = math.max(1, math.min(5, tonumber(tutorial.step) or 1))
    tutorialDispositionSelected_ = false
    ClearInputState()
    active_ = true
    phase_ = "cg"
    InstallInputLock()
    -- 快照回调中其他系统可能已抢先弹窗；序章开始时一律清空，避免占住教学弹窗队列。
    DialogCoordinator.Clear(false)
    do
        local ok, UpgradePrompt = pcall(require, "client.EquipmentUpgradePromptController")
        if ok and UpgradePrompt and UpgradePrompt.Close then
            UpgradePrompt.Close()
        end
    end
    do
        local ok, ItemTips = pcall(require, "client.ItemTips")
        if ok and ItemTips and ItemTips.Hide then
            ItemTips.Hide("tutorial-start")
        end
    end
    -- 强引导：屏蔽所有非必要弹窗，只放行当前教程必需弹窗。
    ConfigureTutorialDialogs()
    -- CG/对话期间只在后台下载下一阶段，不抢占前景菊花或解码全部战斗帧。
    LoadingController.PrefetchTutorial(step_)
    if step_ == 1 then PlayCg() else ShowStepIntro() end
    return true
end

function TutorialController.IsActive()
    return active_
end

function TutorialController.SetDispositionSelected(selected)
    if not active_ or step_ ~= 3 then return end
    -- 弹窗内勾选发生时，强制进入分解第 2 子步骤。
    if guideIndex_ < 2 then
        guideIndex_ = 2
    end
    tutorialDispositionSelected_ = selected == true
    -- 勾选后立刻重刷高亮：优先锁定确认按钮，避免玩家不知道下一步点哪里。
    guideRebuildPending_ = true
    RefreshInputWhitelist()
end

--- 业务按钮 onClick 主动推进引导（主路径，不依赖几何命中）。
--- action:
---   equip_select            选中可穿戴候选
---   equip_now               点击快捷穿戴
---   decompose_open          打开一键分解
---   decompose_dialog_ready  分解弹窗已挂载
---   strengthen_open         打开强化确认
---   strengthen_dialog_ready 强化弹窗已挂载
function TutorialController.NotifyAction(action)
    if not active_ or phase_ ~= "guide" then return end
    if action == "equip_select" then
        if step_ ~= 2 then return end
        if guideIndex_ < 2 then
            guideIndex_ = 2
        end
        guideRebuildPending_ = true
        RefreshInputWhitelist()
        return
    end
    if action == "equip_now" then
        if step_ ~= 2 then return end
        -- 点击快捷穿戴后保持在最后子步骤，等待服务端/本地穿戴完成推进。
        if guideIndex_ < 2 then
            guideIndex_ = 2
        end
        guideRebuildPending_ = true
        RefreshInputWhitelist()
        return
    end
    if action == "decompose_open" then
        if step_ ~= 3 then return end
        if guideIndex_ < 2 then
            guideIndex_ = 2
            tutorialDispositionSelected_ = false
            guideRebuildPending_ = true
        end
        RefreshInputWhitelist()
        return
    end
    if action == "decompose_dialog_ready" then
        if step_ ~= 3 then return end
        if guideIndex_ < 2 then
            guideIndex_ = 2
        end
        guideRebuildPending_ = true
        RefreshInputWhitelist()
        return
    end
    if action == "strengthen_open" then
        if step_ ~= 4 then return end
        if guideIndex_ < 2 then
            guideIndex_ = 2
        end
        guideRebuildPending_ = true
        RefreshInputWhitelist()
        return
    end
    if action == "strengthen_dialog_ready" then
        if step_ ~= 4 then return end
        if guideIndex_ < 2 then
            guideIndex_ = 2
        end
        guideRebuildPending_ = true
        RefreshInputWhitelist()
    end
end

function TutorialController.GetStep()
    return step_
end

function TutorialController.Configure(context)
    context = context or {}
    root_ = context.root
end

function TutorialController.AttachRoot(root)
    local rootChanged = root_ ~= root
    if not rootChanged then
        root_ = root
        return
    end
    if active_ then RemoveLayer() end
    root_ = root
    if not active_ then return end
    ClearInputState()
    guideTarget_ = nil
    guideHighlight_ = nil
    guideHint_ = nil
    if phase_ == "cg" then
        PlayCg()
    elseif phase_ == "dialog" then
        ShowStepIntro()
    elseif phase_ == "guide" then
        layer_ = UI.Panel {
            position = "absolute",
            left = 0, top = 0, right = 0, bottom = 0,
            zIndex = LAYER_Z,
            clickable = false,
            pointerEvents = "box-none",
            children = {},
        }
        root_:AddChild(layer_)
        guideRetryPending_ = true
        ShowGuideSubStep()
    end
end

--- 每帧驱动（GameView.HandleUpdate 调用）：
--- 1) 点击目标推进子步骤后延迟一帧重建面板（避免吞掉目标 onClick）；
--- 2) 切页后布局未就绪时的重试。
function TutorialController.Update(dt)
    if not active_ then return end
    if guideHint_ and guideHint_.parent then
        local inset = UILayout.OverlayInsets()
        local props = guideHint_.props
        if props.top ~= inset.top or props.left ~= inset.left or props.right ~= inset.right then
            guideHint_:SetStyle({ top = inset.top, left = inset.left, right = inset.right })
        end
    end
    -- 首杀掉落后延后进入第二步对话，避免盖住飞入表现。
    TryFlushPendingStepIntro(dt)
    -- 状态机兜底：若服务端 tutorial.step 已推进，但客户端仍停在 step1，强制跟上。
    if active_ and not pendingStepIntro_ then
        local tutorial = currentTutorial()
        local serverStep = tonumber(tutorial and tutorial.step) or step_
        if serverStep >= 2 and serverStep <= 5 and serverStep ~= step_ then
            QueueStepIntro(serverStep)
            TryFlushPendingStepIntro(0)
            return
        end
    end
    -- 第二步：部位有穿戴即推进，不依赖服务端事件时序。
    if TryCompleteEquipGuide() then return end
    -- 异步弹窗可能在任意帧挂载；每帧按当前步骤重新建立最小白名单。
    RefreshInputWhitelist()
    if phase_ ~= "guide" then return end
    -- 等待掉落表现时保持首杀锁定层，不切换到下一步引导 UI。
    if pendingStepIntro_ then return end
    -- 高亮目标被页面刷新销毁（旧实例已无父节点）后自动重查：
    -- 页面重建的新实例使用相同 id，重新 ShowGuideSubStep 即可恢复高亮
    if guideTarget_ and not guideTarget_.parent then
        ShowGuideSubStep()
        return
    end
    if guideRebuildPending_ then
        guideRebuildPending_ = false
        ShowGuideSubStep()
        return
    end
    if guideRetryPending_ then
        guideRetryCount_ = guideRetryCount_ + 1
        if guideRetryCount_ > 300 then
            -- 兜底：布局长时间未就绪也按当前状态处理，避免永久卡在重试
            guideRetryPending_ = false
            guideRetryCount_ = 0
        end
        ShowGuideSubStep()
        return
    end
    -- 穿戴：若快捷穿戴按钮已出现，且当前还停在选中子步骤，推进到穿戴子步骤。
    if step_ == 2 and guideIndex_ == 1 then
        local equipNow = FindGuideWidgetById("tutorialEquipNow")
        if equipNow then
            guideIndex_ = 2
            guideRebuildPending_ = true
            ShowGuideSubStep()
            return
        end
    end
    -- 分解/强化弹窗一旦挂载，即使 onClick 通知丢失，也强制进入第 2 子步骤。
    if step_ == 3 and guideIndex_ == 1 then
        local dialogReady = FindGuideWidgetById("tutorialDispositionConfirm")
            or FindTutorialDispositionCandidate()
        if dialogReady then
            guideIndex_ = 2
            guideRebuildPending_ = true
            ShowGuideSubStep()
            return
        end
    end
    if step_ == 4 and guideIndex_ == 1 then
        local strengthenReady = FindGuideWidgetById("tutorialStrengthenConfirm")
        if strengthenReady then
            guideIndex_ = 2
            guideRebuildPending_ = true
            ShowGuideSubStep()
            return
        end
    end
    -- 分解/强化弹窗异步出现后，主动重查高亮目标。
    local subSteps = GUIDE_SUBSTEPS[step_] or {}
    local subStep = subSteps[guideIndex_]
    if subStep and (subStep.targetId or subStep.targetPrefix) and not subStep.lockInput then
        local expected = FindGuideTarget(subStep)
        if not guideTarget_ or not guideTarget_.parent or (expected and expected ~= guideTarget_) then
            ShowGuideSubStep()
            return
        end
        -- 分解第 2 子步：勾选后切到确认高亮。
        if step_ == 3 and guideIndex_ == 2 and tutorialDispositionSelected_ then
            local confirm = FindGuideWidgetById("tutorialDispositionConfirm")
            if confirm and guideTarget_ ~= confirm then
                ShowGuideSubStep()
            end
        end
        -- 强化第 2 子步：确认按钮后挂载时切到确认高亮。
        if step_ == 4 and guideIndex_ == 2 then
            local confirm = FindGuideWidgetById("tutorialStrengthenConfirm")
            if confirm and guideTarget_ ~= confirm then
                ShowGuideSubStep()
            end
        end
    end
end

function TutorialController.Reset()
    TutorialController.Hide()
    active_ = false
    phase_ = "idle"
    step_ = 1
    loadoutResetDone_ = false
    guideHint_ = nil
    guideHighlight_ = nil
    guideTarget_ = nil
    guideIndex_ = 0
    guideRetryPending_ = false
    guideRetryCount_ = 0
    guideRebuildPending_ = false
    tutorialDispositionSelected_ = false
    completingTutorial_ = false
    ClearPendingStepIntro()
    blockedToastAt_ = 0
    ClearInputState()
    UnregisterGuideListener()
    UninstallInputLock()
    -- 恢复所有弹窗
    RestoreDialogs()
end

function TutorialController.Hide()
    UnregisterGuideListener()
    RemoveLayer()
    guideHint_ = nil
    guideHighlight_ = nil
    guideTarget_ = nil
end

return TutorialController
