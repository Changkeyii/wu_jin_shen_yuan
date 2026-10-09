-- Cold/warm startup contracts with the real staged loader and a controllable SDK.
local function widget(props)
    local w = {props = props or {}, children = {}, node = true}
    function w:AddChild(c) self.children[#self.children + 1] = c; c.parent = self end
    function w:Remove()
        if self.parent then
            for i, c in ipairs(self.parent.children) do if c == self then table.remove(self.parent.children, i); break end end
        end
        self.parent = nil
    end
    function w:Destroy() self:Remove(); self.node = nil end
    function w:Hide() self.props.visible = false end
    function w:Show() self.props.visible = true end
    function w:SetText(text) self.props.text = text end
    function w:SetStyle(props) for k,v in pairs(props) do self.props[k] = v end end
    for _, child in ipairs(w.props.children or {}) do w:AddChild(child) end
    return w
end
local UI = {Panel = widget}
package.loaded['urhox-libs/UI'] = UI
package.loaded['client.Theme'] = {Colors = {primary = 'gold'}}
local A = require('client.ViewAssets')
local S = require('client.ResourceStages')
local D = require('client.ResourceDownloads')
local L = require('client.LoadingController')
local pending, calls, peak, inFlight = {}, {}, 0, 0
cache = {
    DownloadResource = function(_, path, callback)
        assert(not pending[path], 'same path must not have concurrent requests')
        calls[#calls + 1] = path
        pending[path] = callback
        inFlight = inFlight + 1; peak = math.max(peak, inFlight)
    end,
    CancelDownload = function(_, path)
        if pending[path] then pending[path] = nil; inFlight = inFlight - 1 end
    end,
    GetMemoryBudget = function() error('startup must not depend on native budget APIs') end,
    SetMemoryBudget = function() error('must preserve engine memory management') end,
    GetResourceAsync = function() error('prefetch must download without decoding/pinning textures') end,
}
local function complete(path, ok)
    local callback = assert(pending[path]); pending[path] = nil; inFlight = inFlight - 1
    callback(ok); callback(not ok) -- duplicate response must not change the first outcome
end
local function drain(except)
    for _ = 1, 1000 do
        L.Update(0.05)
        local finished = {}
        for path in pairs(pending) do if path ~= except then finished[#finished + 1] = path end end
        for _, path in ipairs(finished) do complete(path, true) end
    end
end
local function text(value, _, _, props) props = props or {}; props.text = value; return widget(props) end
L.Configure({assets = A.ASSETS, title = 'test', txt = text, multiTxt = text,
    pixelPanel = widget, imageProgress = function() return widget(), widget() end,
    setImageProgress = function() end})
local root = widget()
L.Start(root)
assert(#calls == 0 and #root.children == 1, 'spinner must exist before dispatching downloads')
local panel = root.children[1].children[1]
local dots = panel.children[3]
assert(#dots.children == 12 and dots.props.width == 240 and panel.props.height == 760)
L.Update(0.1)
assert(dots.children[1].props.left ~= nil and peak <= 2)
local entered = 0
L.MarkSnapshotReceived({tutorial = {completed = true}}, function() entered = entered + 1 end)
for _ = 1, 500 do
    L.Update(0.05)
    if entered == 1 then break end
    local paths = {}; for path in pairs(pending) do paths[#paths + 1] = path end
    for _, path in ipairs(paths) do complete(path, true) end
end
assert(entered == 1, 'homepage must become usable before background battle download finishes')
for _, path in ipairs(calls) do assert(path ~= S.CG and not path:find('wishpool_hex'), 'old account does not load CG/optional pages') end
assert(not D.IsReady(S.Page('play')), 'background combat must not be a startup gate')
L.Update(1); assert(not L.IsActive(), 'background preparation cannot keep spinner active')
L.Stop()
local old = {}; for path in pairs(pending) do old[#old + 1] = path end
for _, path in ipairs(old) do complete(path, true) end
L.Start(root)
local tutorialReady = 0
L.MarkSnapshotReceived({tutorial = {completed = false, step = 1}}, function() tutorialReady = tutorialReady + 1 end)
-- Reach the CG, fail it, and verify no fake-ready timeout.
for _ = 1, 500 do
    L.Update(0.05)
    local done = {}; for path in pairs(pending) do done[#done + 1] = path end
    for _, path in ipairs(done) do complete(path, path ~= S.CG) end
end
assert(tutorialReady == 0 and L.IsActive())
local retry = root.children[#root.children].children[2]
assert(retry.props.id == 'stageLoadingRetry' and retry.props.visible == true)
retry.props.onClick(); drain()
assert(tutorialReady == 1 and D.IsReady(S.Intro(1)))
L.PrefetchTutorial(1)
assert(not L.IsActive(), 'background prefetch never shows a foreground spinner')
local battle = 0
L.EnsurePlayAssetsReady(function() battle = battle + 1 end)
drain()
assert(battle == 1 and D.IsReady(S.Page('play')) and peak <= 2)
local frames = {}; for _, path in ipairs(S.Page('play')) do frames[path] = true end
for _, set in ipairs(A.CurrentPlayer().attackFrameSets) do
    assert(#set == 48)
    for _, path in ipairs(set) do assert(frames[path], 'full attack sequences are required') end
end
L.EnsureMediaReady('missing-callback', {'test/missing.png'}, function() error('failed media must not enter') end)
L.Update(0.1)
local late = pending['test/missing.png']
L.Update(31)
assert(L.IsActive() and not pending['test/missing.png'])
late(true); L.Update(0.1); assert(L.IsActive(), 'late callback cannot override timed-out attempt')
L.DismissForRecovery()
local restored = 0
L.EnsureMediaReady('retry-media', {'test/missing.png'}, function() restored = restored + 1 end)
drain(); assert(restored == 1)
L.EnsureMediaReady('cancelled', {'test/cancelled.png'}, function() error('stale navigation') end)
L.Update(0.1); L.DismissForRecovery()
complete('test/cancelled.png', true); L.Update(1); assert(not L.IsActive())
-- Foreground requests jump ahead of queued optional resources.
local bg = D.Request({'test/bg1.png', 'test/bg2.png'}, 0)
local fg = D.Request({'test/foreground.png'}, 100)
L.Update(0.1)
assert(calls[#calls - 1] == 'test/foreground.png')
D.Cancel(bg); D.Cancel(fg)
for path in pairs(pending) do complete(path, true) end
-- Page lifecycle still bounds native UI trees without intercepting the image cache.
local Pages = require('client.UI.PageCache')
local entries, recency = {}, {}
for i = 1, 200 do
    Pages.Trim(entries, recency, i)
    local page = widget()
    entries[i] = {GetRoot = function() return page end, Destroy = function() end}
    recency[i] = i
    local count = 0; for _ in pairs(entries) do count = count + 1 end
    assert(count <= 2)
end
for _, page in pairs(entries) do local r = page:GetRoot(); Pages.Destroy(page); assert(not r.node) end
local released = {}
local originalGet = function() return 1 end
package.loaded['urhox-libs/UI/Core/ImageCache'] = {
    Get = originalGet, GetContext = function() return true end,
    Release = function(path) released[path] = true end,
}
S.ReleasePageLater('wish')
S.ReleaseDepartedPages(widget({backgroundImage = A.ASSETS.ui.wishJarMyth}), 'home')
assert(released[A.ASSETS.ui.wishPoolHexBackground])
assert(not released[A.ASSETS.ui.wishJarMyth] and not released[A.ASSETS.ui.topFrame])
assert(package.loaded['urhox-libs/UI/Core/ImageCache'].Get == originalGet)
released = {}
S.ReleasePageLater('play')
S.ReleaseDepartedPages(widget({backgroundImage = A.CurrentPlayer().run[1]}), 'campaign')
assert(not released[A.CurrentPlayer().attackFrameSets[1][1]], 'isolated active battle protects complete animations')
print('startup_memory: PASS (cold/warm startup, original spinner, staged priority, complete frames, failure/retry/timeout/recovery)')
