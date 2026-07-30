local UI = require("urhox-libs/UI")

local AudioController = {}

local MUSIC_PATHS = {
    home = "audio/music_1785119105392.ogg",
    battle = "audio/music_1785119227932.ogg",
}
local CLICK_PATH = "audio/sfx/cyber_ui_click.mp3"
local FEEDBACK_PATHS = {
    reward = "audio/sfx/reward_claim.mp3",
    levelUp = "audio/sfx/level_up.mp3",
    combatAttack = "audio/sfx/combat_attack_release.mp3",
    lootDrop = "audio/sfx/loot_drop_pop.mp3",
}

---@type Scene
local audioScene_ = nil
---@type Node
local audioNode_ = nil
---@type SoundSource
local musicSource_ = nil
---@type SoundSource
local clickSource_ = nil
---@type Sound
local clickSound_ = nil
---@type SoundSource[]
local feedbackSources_ = {}
local feedbackSourceIndex_ = 0
local musicSounds_ = {}
local feedbackSounds_ = {}
local currentMusic_ = nil
local musicVolume_ = 0.42
local sfxVolume_ = 0.7
local started_ = false

local function ClampVolume(value)
    value = tonumber(value) or 0
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

local function LoadSound(path, looped)
    local sound = cache:GetResource("Sound", path)
    if not sound then
        print("[AudioController] sound resource missing: " .. tostring(path))
        return nil
    end
    sound:SetLooped(looped == true)
    print(string.format("[AudioController] loaded sound: %s, length=%.2f", path, sound:GetLength()))
    return sound
end

local function IsActionable(widget)
    local current = widget
    while current do
        local props = current.props
        if props then
            if props.disabled == true then return false end
            if props.onClick or props.clickable == true then return true end
        end
        current = current.parent
    end
    return false
end

function AudioController.PlaySoundEffect(sound)
    if not clickSource_ or not sound or sfxVolume_ <= 0 then return end
    clickSource_:Play(sound)
end

function AudioController.PlayFeedback(name)
    local sound = feedbackSounds_[name]
    if not sound then
        print("[AudioController] feedback sound unavailable: " .. tostring(name))
        return false
    end
    if #feedbackSources_ == 0 or sfxVolume_ <= 0 then return false end
    feedbackSourceIndex_ = (feedbackSourceIndex_ % #feedbackSources_) + 1
    local source = feedbackSources_[feedbackSourceIndex_]
    source:SetGain(sfxVolume_)
    source:Play(sound)
    return true
end

local function PlayClickAtPhysicalPosition(x, y)
    if not clickSource_ or not clickSound_ then return end
    local scale = UI.GetScale()
    local widget = UI.FindWidgetAt((x or 0) / scale, (y or 0) / scale)
    if IsActionable(widget) then
        AudioController.PlaySoundEffect(clickSound_)
    end
end

---@param eventType StringHash|string
---@param eventData MouseButtonDownEventData
local function HandleMouseButtonDown(eventType, eventData)
    if eventData:GetInt("Button") ~= MOUSEB_LEFT then return end
    PlayClickAtPhysicalPosition(eventData:GetInt("X"), eventData:GetInt("Y"))
end

---@param eventType StringHash|string
---@param eventData TouchBeginEventData
local function HandleTouchBegin(eventType, eventData)
    PlayClickAtPhysicalPosition(eventData:GetInt("X"), eventData:GetInt("Y"))
end

local function PlayCurrentMusic()
    local sound = currentMusic_ and musicSounds_[currentMusic_] or nil
    if not musicSource_ or not sound then return false end
    sound:SetLooped(true)
    musicSource_:SetGain(musicVolume_)
    musicSource_:Play(sound)
    return true
end

---@param eventType StringHash|string
---@param eventData SoundFinishedEventData
local function HandleSoundFinished(eventType, eventData)
    local source = eventData:GetPtr("SoundSource")
    if source ~= musicSource_ or not started_ then return end
    if PlayCurrentMusic() then
        print("[AudioController] music loop restarted: " .. tostring(currentMusic_))
    end
end

function AudioController.Start()
    if started_ then return end
    started_ = true

    -- SoundSource must belong to a live Scene. Keep the Scene at module scope so
    -- it cannot be collected while the game is running.
    audioScene_ = Scene()
    audioNode_ = audioScene_:CreateChild("Audio")
    musicSource_ = audioNode_:CreateComponent("SoundSource")
    clickSource_ = audioNode_:CreateComponent("SoundSource")
    musicSource_:SetSoundType(SOUND_MUSIC)
    musicSource_:SetGain(musicVolume_)
    musicSource_:SetDeclickEnabled(true)
    clickSource_:SetSoundType(SOUND_EFFECT)
    clickSource_:SetGain(sfxVolume_)
    clickSource_:SetDeclickEnabled(true)
    feedbackSources_ = {}
    feedbackSourceIndex_ = 0
    for index = 1, 8 do
        local source = audioNode_:CreateComponent("SoundSource")
        source:SetSoundType(SOUND_EFFECT)
        source:SetGain(sfxVolume_)
        source:SetDeclickEnabled(true)
        feedbackSources_[index] = source
    end

    clickSound_ = LoadSound(CLICK_PATH, false)
    for name, path in pairs(FEEDBACK_PATHS) do
        feedbackSounds_[name] = LoadSound(path, false)
    end
    musicSounds_.home = LoadSound(MUSIC_PATHS.home, true)
    musicSounds_.battle = LoadSound(MUSIC_PATHS.battle, true)

    SubscribeToEvent("MouseButtonDown", HandleMouseButtonDown)
    SubscribeToEvent("TouchBegin", HandleTouchBegin)
    SubscribeToEvent("SoundFinished", HandleSoundFinished)
    print("[AudioController] audio scene ready")
end

function AudioController.SetPage(pageId)
    local wanted = pageId == "play" and "battle" or "home"
    local sound = musicSounds_[wanted]
    if currentMusic_ == wanted and musicSource_ and musicSource_:IsPlaying() then return end
    if not musicSource_ or not sound then
        print("[AudioController] music unavailable: " .. wanted)
        return
    end
    currentMusic_ = nil
    musicSource_:Stop()
    currentMusic_ = wanted
    if PlayCurrentMusic() then
        print("[AudioController] music switched: " .. wanted)
    end
end

function AudioController.SetMusicVolume(value)
    musicVolume_ = ClampVolume(value)
    if musicSource_ then musicSource_:SetGain(musicVolume_) end
end

function AudioController.GetMusicVolume()
    return musicVolume_
end

function AudioController.SetSfxVolume(value)
    sfxVolume_ = ClampVolume(value)
    if clickSource_ then clickSource_:SetGain(sfxVolume_) end
    for _, source in ipairs(feedbackSources_) do source:SetGain(sfxVolume_) end
end

function AudioController.GetSfxVolume()
    return sfxVolume_
end

function AudioController.Stop()
    if not started_ then return end
    started_ = false
    UnsubscribeFromEvent("MouseButtonDown")
    UnsubscribeFromEvent("TouchBegin")
    UnsubscribeFromEvent("SoundFinished")
    if musicSource_ then musicSource_:StopImmediate() end
    if clickSource_ then clickSource_:StopImmediate() end
    if audioScene_ then audioScene_:Dispose() end
    audioScene_ = nil
    audioNode_ = nil
    musicSource_ = nil
    clickSource_ = nil
    feedbackSources_ = {}
    feedbackSourceIndex_ = 0
    clickSound_ = nil
    feedbackSounds_ = {}
    musicSounds_ = {}
    currentMusic_ = nil
end

return AudioController
