local UI = require("urhox-libs/UI")
local GameTheme = require("client.Theme")
local ViewAssets = require("client.ViewAssets")
local Kit = require("client.ViewKit")
local MailController = require("client.MailController")

local C = GameTheme.Colors
local ASSETS = ViewAssets.ASSETS
local LAYOUT = ViewAssets.LAYOUT

local TopBarView = {}

function TopBarView.Build(game, refs)
    refs = refs or {}
    refs.floor = Kit.Txt("层  第" .. tostring(game.floor or 1) .. "层", 22, C.focus, {
        whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center",
        textStroke = { width = 2, color = "#000000" },
    })
    refs.level = Kit.Txt("Lv." .. tostring(game.level or 1), 22, C.focus, {
        whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center",
        textStroke = { width = 2, color = "#000000" },
    })
    refs.gold = Kit.Txt("金币  " .. Kit.FormatInt(game.gold), 22, C.gold, {
        whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center",
        textStroke = { width = 2, color = "#000000" },
    })
    refs.fragments = Kit.Txt("碎片  " .. Kit.FormatInt(game.fragments), 22, C.secondary, {
        whiteSpace = "nowrap", width = 210, height = 42, textAlign = "center",
        textStroke = { width = 2, color = "#000000" },
    })

    refs.resourceGame = game
    local function ResourceText(x, valueRef, kind)
        valueRef:SetStyle({ pointerEvents = "none" })
        return UI.Panel {
            id = "resourceTip_" .. kind, clickable = true,
            onClick = function() require("client.ResourceTips").Show(kind, refs.resourceGame) end,
            position = "absolute", left = x, top = 222,
            width = 210, height = 42,
            alignItems = "center", justifyContent = "center", overflow = "hidden",
            children = { valueRef },
        }
    end

    return UI.Panel {
        width = "100%", height = LAYOUT.TOP_ZONE_HEIGHT,
        flexShrink = 0, position = "relative",
        children = {
            UI.Panel {
                position = "absolute", left = 0, top = 0,
                width = 1080, height = 288,
                backgroundImage = ASSETS.ui.topFrame, backgroundFit = "contain",
            },
            UI.Panel {
                id = "homeTitleGmAccess",
                position = "absolute", left = 80, top = 58,
                width = 270, height = 72, clickable = true,
                onClick = MailController.OnHomeTitleClick,
                children = {
                    Kit.Txt("无尽深渊", 28, C.text, {
                        width = "100%", height = 72, whiteSpace = "nowrap", textAlign = "center",
                        textStroke = { width = 3, color = "#000000" }, pointerEvents = "none",
                    }),
                },
            },
            Kit.Txt("解放双手，自动推进探索", 21, C.textSecondary, {
                position = "absolute", left = 458, top = 74,
                width = 520, height = 48, whiteSpace = "nowrap", textAlign = "center",
                textStroke = { width = 1, color = "#000000" },
            }),
            ResourceText(86, refs.floor, "floor"),
            ResourceText(316, refs.level, "level"),
            ResourceText(546, refs.gold, "gold"),
            ResourceText(776, refs.fragments, "fragments"),
        },
    }
end

function TopBarView.Update(game, refs)
    refs = refs or {}
    refs.resourceGame = game
    if refs.floor then refs.floor:SetText("层  第" .. tostring(game.floor or 1) .. "层") end
    if refs.level then refs.level:SetText("Lv." .. tostring(game.level or 1)) end
    if refs.gold then refs.gold:SetText("金币  " .. Kit.FormatInt(game.gold)) end
    if refs.fragments then refs.fragments:SetText("碎片  " .. Kit.FormatInt(game.fragments)) end
end

return TopBarView
