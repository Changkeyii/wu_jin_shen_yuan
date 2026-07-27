local SOURCES = {
    "image/equipment/icons/equip_nightmare_01_噩梦低语之刃_20260721034747.png",
    "image/equipment/icons/equip_nightmare_02_哀嚎断角肩铠_20260721034733.png",
    "image/equipment/icons/equip_nightmare_03_绝望囚徒的黑袍_20260721034742.png",
    "image/equipment/icons/equip_nightmare_04_地狱行刑者的长裤_20260721034724.png",
    "image/equipment/icons/equip_nightmare_05_血债缚魂腰带_20260721034725.png",
    "image/equipment/icons/equip_nightmare_06_踏碎梦魇的铁靴_20260721034725.png",
    "image/equipment/icons/equip_nightmare_07_痛苦回响手镯_20260721034721.png",
    "image/equipment/icons/equip_nightmare_08_断魂者的黑曜项链_20260721034720.png",
    "image/equipment/icons/equip_nightmare_09_绝境轮回之戒_20260721034719.png",
    "image/equipment/icons/equip_nightmare_10_罪孽记录器_20260721034722.png",
    "image/equipment/icons/equip_nightmare_11_深红灾厄核心_20260721034936.png",
    "image/equipment/icons/equip_nightmare_12_终末的宿命_20260721034936.png",
    "image/equipment/icons/equip_lucky_01_三相偏转的幸运刃_20260721034935.png",
    "image/equipment/icons/equip_lucky_02_摇骰者的星纹肩甲_20260721034904.png",
    "image/equipment/icons/equip_lucky_03_幸运赌徒的金线长衣_20260721034903.png",
    "image/equipment/icons/equip_lucky_04_命运逆行者的赌局长裤_20260721034903.png",
    "image/equipment/icons/equip_lucky_05_七面骰的束带_20260721034916.png",
    "image/equipment/icons/equip_lucky_06_踏上红线的赌徒之靴_20260721034907.png",
    "image/equipment/icons/equip_lucky_07_幸运的第七只手_20260721034909.png",
    "image/equipment/icons/equip_lucky_08_命运筹码项链_20260721034902.png",
    "image/equipment/icons/equip_lucky_09_偏骰之王的指环_20260721035034.png",
    "image/equipment/icons/equip_lucky_10_庄家的秘密账本_20260721035022.png",
    "image/equipment/icons/equip_lucky_11_流星骰盅_20260721035024.png",
    "image/equipment/icons/equip_lucky_12_不存在的第八面_20260721035021.png",
    "image/equipment/icons/equip_voyage_01_远征终点的长枪_20260721035020.png",
    "image/equipment/icons/equip_voyage_02_行军统帅的风暴肩甲_20260721035038.png",
    "image/equipment/icons/equip_voyage_03_不落旗帜的远征军装_20260721035043.png",
    "image/equipment/icons/equip_voyage_04_跨越千里的疾行战裤_20260721035030.png",
    "image/equipment/icons/equip_voyage_05_战术航线束带_20260721035019.png",
    "image/equipment/icons/equip_voyage_06_无尽行军之靴_20260721035019.png",
    "image/equipment/icons/equip_voyage_07_先锋信标手镯_20260721035210.png",
    "image/equipment/icons/equip_voyage_08_军团通讯项链_20260721035210.png",
    "image/equipment/icons/equip_voyage_09_时刻校准之戒_20260721035206.png",
    "image/equipment/icons/equip_voyage_10_军神的远古地图_20260721035234.png",
    "image/equipment/icons/equip_voyage_11_永恒罗盘核心_20260721035209.png",
    "image/equipment/icons/equip_voyage_12_远征者的终点钟_20260721035211.png",
    "image/equipment/icons/equip_abyss_01_饥渴的深渊獠牙_20260721035208.png",
    "image/equipment/icons/equip_abyss_02_窥视者的无光冠冕_20260721035206.png",
    "image/equipment/icons/equip_abyss_03_吞噬深渊的祭袍_20260721035207.png",
    "image/equipment/icons/equip_abyss_04_黑潮浸染的祭裤_20260721035218.png",
    "image/equipment/icons/equip_abyss_05_血祭循环束带_20260721035313.png",
    "image/equipment/icons/equip_abyss_06_行走于黑潮之靴_20260721035316.png",
    "image/equipment/icons/equip_abyss_07_祭血回路手镯_20260721035317.png",
    "image/equipment/icons/equip_abyss_08_深渊喉骨项链_20260721035314.png",
    "image/equipment/icons/equip_abyss_09_亡者回声之戒_20260721035318.png",
    "image/equipment/icons/equip_abyss_10_黑暗祭司的遗书_20260721035316.png",
    "image/equipment/icons/equip_abyss_11_深渊心脏碎片_20260721035319.png",
    "image/equipment/icons/equip_abyss_12_饥饿星骸耳坠_20260721035327.png",
    "image/equipment/icons/equip_prophecy_01_斩断宿命的祭剑_20260721035322.png",
    "image/equipment/icons/equip_prophecy_02_先知的骨文肩饰_20260721035315.png",
    "image/equipment/icons/equip_prophecy_03_古代祭司的圣衣_20260721035409.png",
    "image/equipment/icons/equip_prophecy_04_铭刻万魂的祭礼长裤_20260721035415.png",
    "image/equipment/icons/equip_prophecy_05_预言束缚之带_20260721035408.png",
    "image/equipment/icons/equip_prophecy_06_走过神谕之路的长靴_20260721035906.png",
    "image/equipment/icons/equip_prophecy_07_圣痕回响手镯_20260721035413.png",
    "image/equipment/icons/equip_prophecy_08_先古神谕项链_20260721035411.png",
    "image/equipment/icons/equip_prophecy_09_千魂祭的预言戒指_20260721035414.png",
    "image/equipment/icons/equip_prophecy_10_祭坛遗留的神谕卷轴_20260721035410.png",
    "image/equipment/icons/equip_prophecy_11_万古圣火石_20260721035412.png",
    "image/equipment/icons/equip_prophecy_12_神谕终章耳坠_20260721035412.png",
}

function Start()
    local ok, err = pcall(function()
        local atlas = Image()
        assert(atlas:SetSize(1024, 1024, 4), "atlas SetSize failed")
        atlas:Clear(Color(0, 0, 0, 0))

        for index, path in ipairs(SOURCES) do
            local source = Image()
            assert(source:Load("/workspace/assets/" .. path), "failed to load " .. path)
            assert(source.width == 128 and source.height == 128, "invalid icon dimensions " .. path)
            local zeroIndex = index - 1
            local left = (zeroIndex % 8) * 128
            local top = math.floor(zeroIndex / 8) * 128
            assert(atlas:SetSubimage(source, IntRect(left, top, left + 128, top + 128)), "SetSubimage failed " .. path)
            source:Dispose()
        end

        assert(atlas:SavePNG("/workspace/assets/image/equipment/equipment_atlas.png"), "SavePNG failed")
        atlas:Dispose()
        print("[equipment-atlas] wrote 60 icons to 1024x1024 atlas")
    end)
    if not ok then
        log:Write(LOG_ERROR, "[equipment-atlas] " .. tostring(err))
    end
    engine:Exit()
end
