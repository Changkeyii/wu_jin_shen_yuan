-- TrashTalk.lua
-- 个性展示「垃圾话」静态词库：20 条不带脏字、贴合本游戏、能激发玩家超越心理的挑衅语。
-- 词条存于游戏本地（客户端静态表），排行榜只上传所选 index，展示时凭 index 本地查表。

local TrashTalk = {}

TrashTalk.Phrases = {
    "战力榜第一，不过如此。",
    "你变强的速度，还没我掉装备快。",
    "听说你在追我的排名？",
    "我的装备随便一件，够你打一个月。",
    "深渊之下的风景，你还没资格看。",
    "挂机也能甩你十条街。",
    "别急，等你到我这楼层再说话。",
    "你这套装备，摆摊都嫌占格子。",
    "超越我？梦里什么都有。",
    "我把Boss打哭了，你还在新手村。",
    "战力这数字，我随便敲个零都比你高。",
    "你拼的命，不如我随手点一下。",
    "排行榜前面的位置，冷得很。",
    "你的极限，只是我的起点。",
    "我不针对谁，我是说在座各位都追不上。",
    "变强路上，我给你留个背影。",
    "这游戏最难的挑战，是追上我。",
    "我掉的一件紫装，够你玩半年。",
    "躺着别动，看我冲榜就好。",
    "等你能看到我的时候，我已经下一层了。",
}

TrashTalk.MAX = #TrashTalk.Phrases

--- 按 index 查词条（本地查询语句）
---@param index number|nil
---@return string|nil
function TrashTalk.Get(index)
    index = math.floor(tonumber(index) or 0)
    return TrashTalk.Phrases[index + 1]
end

return TrashTalk
