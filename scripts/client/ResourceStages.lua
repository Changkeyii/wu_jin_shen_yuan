-- Stage ownership follows the actual homepage/tutorial/navigation dependencies.
local ViewAssets = require("client.ViewAssets")
local Stages = {}
Stages.CG = "video/cgt-20260813181414-jfc79_video.mp4"
Stages.HOME_MUSIC = "audio/music_1785119105392.ogg"
Stages.BATTLE_MUSIC = "audio/music_1785119227932.ogg"
local pendingRelease = {}

local function collect(...)
    local result, seen = {}, {}
    local function add(value)
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true; result[#result + 1] = value
        elseif type(value) == "table" then
            for _, nested in ipairs(value) do add(nested) end
        end
    end
    for i = 1, select("#", ...) do add(select(i, ...)) end
    return result
end

local function uiKeys(keys)
    local result = {}
    for key in keys:gmatch("%S+") do
        local value = ViewAssets.ASSETS.ui[key]
        assert(value, "unknown stage UI asset: " .. key)
        if type(value) == "table" then
            for _, path in pairs(value) do result[#result + 1] = path end
        else result[#result + 1] = value end
    end
    return result
end

local function matchingUI(pattern)
    local keys = {}
    for key in pairs(ViewAssets.ASSETS.ui) do if key:match(pattern) then keys[#keys + 1] = key end end
    table.sort(keys)
    return uiKeys(table.concat(keys, " "))
end

function Stages.Boot()
    return uiKeys("loadingDot screenOverlay panelLarge progressTrackLoad progressFillLoad")
end

function Stages.Common()
    local a = ViewAssets.ASSETS
    return collect(Stages.Boot(), uiKeys([[bg topFrame bottomNav navSelected button buttonBlue buttonBlueWide
        dialogFrame dialogClose dialogConfirm panelCompact inventoryActionBlue inventoryActionGold
        inventoryActionRed inventorySlotCommon inventoryItemCard selectionFrame idleSettings]]),
        a.items.gold, a.items.crystal, a.items.chest, "audio/sfx/cyber_ui_click.mp3", "audio/sfx/reward_claim.mp3")
end

function Stages.Page(page)
    local a, player = ViewAssets.ASSETS, ViewAssets.CurrentPlayer()
    local own = {}
    if page == "home" then
        own = collect(uiKeys([[heroPanel statCard statAtk statDef statCrit statSpeed statHp statPower
            storyMemoryIcon mailIcon vipArt vipDigits wishTicket wishJarRandom activityExpedition activityPvp]]),
            player.icon, Stages.HOME_MUSIC)
    elseif page == "play" then
        own = collect(a.bg, a.bgMirror, player.sprite, player.idle, player.run,
            player.attack, player.attackFrameSets, -- complete 48-frame groups, never first-frame substitutes
            a.enemies.slime, a.enemies.goblin, a.enemies.skeleton, a.enemies.boss,
            uiKeys([[playHpFrame playAutoRunButton progressTrackHp progressFillHp characterShadow
                lootBarGold pickupSpark statusBar floorBadge infoBarBlue infoBarGold]]),
            matchingUI("^chapterProgress"), Stages.BATTLE_MUSIC,
            "audio/sfx/combat_attack_release.mp3", "audio/sfx/loot_drop_pop.mp3")
    elseif page == "bag" or page == "equip" or page == "codex" then
        own = collect(matchingUI("^inventory"), matchingUI("^equip"), matchingUI("^itemTips"),
            uiKeys("progressTrackSet progressFillSet detailRow"),
            require("shared.EquipmentCatalog").ATLAS_PATH)
    elseif page == "market" then
        own = collect(matchingUI("^market"), require("shared.EquipmentCatalog").ATLAS_PATH)
    elseif page == "wish" then
        own = collect(matchingUI("^wish"), require("shared.WishPoolDefinitions").AllIcons())
    elseif page == "activity" then
        own = collect(uiKeys("activityExpedition activityPvp strikeBg"),
            a.enemies.stumpGold, a.enemies.stumpExp, a.enemies.stumpFragments)
    elseif page == "campaign" then
        own = uiKeys("towerSpirit towerKeeper storyMemoryIcon") -- no other chapter videos/images
    elseif page == "frameEditor" then
        own = collect(Stages.Page("play"), matchingUI("^editor"), uiKeys("referenceFrame"))
    end
    return collect(Stages.Common(), own)
end

function Stages.Intro(step)
    local a = ViewAssets.ASSETS
    return collect(Stages.Common(), a.bg, a.ui.towerSpirit,
        (tonumber(step) or 1) == 1 and Stages.CG or nil)
end

function Stages.Merge(...) return collect(...) end

-- Release only known departed-page images, between frames. Never replace ImageCache.Get
-- or change the engine texture budget. Visible overlays and shared assets stay protected.
function Stages.ReleasePageLater(page)
    pendingRelease[page] = true
end

function Stages.ReleaseDepartedPages(root, currentPage)
    if not next(pendingRelease) then return end
    local protected = {}
    for _, path in ipairs(Stages.Page(currentPage)) do protected[path] = true end
    local function visit(widget)
        if not widget then return end
        local props = widget.props or {}
        if props.backgroundImage then protected[props.backgroundImage] = true end
        if props.atlas then protected[props.atlas] = true end
        for _, child in ipairs(widget.children or {}) do visit(child) end
    end
    visit(root)
    -- Any live battle presentation protects all frames, including isolated story battles.
    local liveBattle = false
    for _, path in ipairs(ViewAssets.CurrentPlayer().run) do
        if protected[path] then liveBattle = true end
    end
    for _, frames in ipairs(ViewAssets.CurrentPlayer().attackFrameSets) do
        for _, path in ipairs(frames) do if protected[path] then liveBattle = true end end
    end
    if liveBattle then for _, path in ipairs(Stages.Page("play")) do protected[path] = true end end
    local images = require("urhox-libs/UI/Core/ImageCache")
    if not images.GetContext() then return end
    for page in pairs(pendingRelease) do
        for _, path in ipairs(Stages.Page(page)) do
            if not protected[path] and path:match("%.png$") then images.Release(path) end
        end
    end
    pendingRelease = {}
end

return Stages
