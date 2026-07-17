local GameView = nil

function Start()
    GameView = require("client.GameView")
    GameView.Start()
end

function Stop()
    if GameView then GameView.Stop() end
end
