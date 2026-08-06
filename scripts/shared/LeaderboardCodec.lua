-- LeaderboardCodec.lua
-- 装备权威数据二进制编解码（排行榜只存权威实例数据，静态配表由客户端凭 equipmentId 查表）
-- 服务端 Pack 打包 / 客户端 Unpack 还原，两端共用同一套格式。
-- 二进制 blob 在 JSON 通道中统一编码为 hex 字符串。

local LeaderboardCodec = {}

local VERSION = 2
local MAX_ITEMS = 12
local SCALE = 1e6

-- ============================================================================
-- 底层二进制原语
-- ============================================================================

local function writeVarint(out, value)
    value = math.max(0, math.floor(tonumber(value) or 0))
    while value >= 0x80 do
        out[#out + 1] = string.char((value % 0x80) + 0x80)
        value = math.floor(value / 0x80)
    end
    out[#out + 1] = string.char(value)
end

local function readVarint(data, pos)
    local value = 0
    local shift = 0
    local length = #data
    while true do
        if pos > length then return nil, pos end
        local byte = data:byte(pos)
        pos = pos + 1
        value = value + (byte % 0x80) * (2 ^ shift)
        if byte < 0x80 then break end
        shift = shift + 7
        if shift > 49 then return nil, pos end
    end
    return value, pos
end

-- zigzag 编码有符号整数（用于 BigNumber 的 exponent，可为负）
local function writeZigzag(out, value)
    value = math.floor(tonumber(value) or 0)
    writeVarint(out, value >= 0 and (value * 2) or (value * -2 - 1))
end

local function readZigzag(data, pos)
    local encoded, next = readVarint(data, pos)
    if encoded == nil then return nil, next end
    if encoded % 2 == 0 then
        return math.floor(encoded / 2), next
    end
    return -math.floor((encoded + 1) / 2), next
end

local function writeString(out, value)
    value = tostring(value or "")
    writeVarint(out, #value)
    out[#out + 1] = value
end

local function readString(data, pos)
    local length, next = readVarint(data, pos)
    if length == nil then return nil, next end
    if next + length - 1 > #data then return nil, next end
    local value = data:sub(next, next + length - 1)
    return value, next + length
end

-- 归一化为 { mantissa, exponent }（兼容纯数字与 BigNumber 表）
local function toMagnitude(value)
    if type(value) == "table" then
        return {
            mantissa = tonumber(value.mantissa or value.m) or 0,
            exponent = tonumber(value.exponent or value.e) or 0,
        }
    end
    value = tonumber(value) or 0
    if value == 0 then return { mantissa = 0, exponent = 0 } end
    local exponent = math.floor(math.log(math.abs(value)) / math.log(10))
    local mantissa = value / (10 ^ exponent)
    if mantissa >= 10 then mantissa = mantissa / 10; exponent = exponent + 1 end
    if mantissa < 1 then mantissa = mantissa * 10; exponent = exponent - 1 end
    return { mantissa = mantissa, exponent = exponent }
end

local function writeBig(out, value)
    local magnitude = toMagnitude(value)
    writeVarint(out, math.floor((magnitude.mantissa or 0) * SCALE))
    writeZigzag(out, magnitude.exponent)
end

local function readBig(data, pos)
    local mantissaInt, next = readVarint(data, pos)
    local exponent, after = readZigzag(data, next)
    if mantissaInt == nil or exponent == nil then return nil, after end
    return { mantissa = mantissaInt / SCALE, exponent = exponent }, after
end

local function writeFraction(out, value)
    writeVarint(out, math.floor((tonumber(value) or 0) * SCALE))
end

local function readFraction(data, pos)
    local scaled, next = readVarint(data, pos)
    if scaled == nil then return nil, next end
    return scaled / SCALE, next
end

local function writeStringList(out, list)
    list = type(list) == "table" and list or {}
    writeVarint(out, #list)
    for _, entry in ipairs(list) do
        writeString(out, type(entry) == "table" and (entry.id or entry.key or "") or entry)
    end
end

local function readStringList(data, pos)
    local count, next = readVarint(data, pos)
    if count == nil then return nil, next end
    local list = {}
    for _ = 1, count do
        local entry, after = readString(data, next)
        if entry == nil then return nil, after end
        list[#list + 1] = entry
        next = after
    end
    return list, next
end

-- ============================================================================
-- 单件装备编码 / 解码
-- ============================================================================

-- 打包一件装备的权威字段
local function packItem(out, item)
    item = item or {}
    writeString(out, item.slot or "")
    writeString(out, item.equipmentId or "")
    writeString(out, item.rarity or "common")
    writeVarint(out, math.floor(tonumber(item.level) or 1))
    writeVarint(out, math.floor(tonumber(item.enhance) or 0))
    writeVarint(out, math.floor(tonumber(item.star) or 0))
    writeVarint(out, math.floor(tonumber(item.quantity) or 1))

    local hasSetId = item.setId ~= nil and tostring(item.setId) ~= ""
    local hasSource = item.source ~= nil and tostring(item.source) ~= ""
    local flags = 0
    if hasSetId then flags = flags + 1 end
    if hasSource then flags = flags + 2 end
    if type(item.coreAffixes) == "table" and #item.coreAffixes > 0 then flags = flags + 4 end
    if type(item.uniqueEffects) == "table" and #item.uniqueEffects > 0 then flags = flags + 8 end
    writeVarint(out, flags)

    if hasSetId then
        writeString(out, tostring(item.setId))
        writeVarint(out, item.setEnabled == false and 0 or 1)
    end
    if hasSource then writeString(out, tostring(item.source)) end

    writeBig(out, item.atkBig or item.atk or 0)
    writeBig(out, item.defBig or item.def or 0)
    writeBig(out, item.hpBig or item.hp or 0)
    writeFraction(out, item.crit)
    writeFraction(out, item.critDmg)
    writeFraction(out, item.atkSpeed)
    writeFraction(out, item.lifeSteal)
    writeFraction(out, item.damageReduction)
    writeFraction(out, item.bossDamage)

    if (flags % 8) >= 4 then writeStringList(out, item.coreAffixes) end
    if (flags % 16) >= 8 then writeStringList(out, item.uniqueEffects) end
end

local function unpackItem(data, pos)
    local slot, next = readString(data, pos)
    if slot == nil then return nil, next end
    pos = next
    local equipmentId, after = readString(data, pos)
    if equipmentId == nil then return nil, after end
    pos = after
    local rarity, after2 = readString(data, pos)
    if rarity == nil then return nil, after2 end
    pos = after2
    local level, after3 = readVarint(data, pos)
    local enhance, after4 = readVarint(data, after3)
    local star, after5 = readVarint(data, after4)
    local quantity, after6 = readVarint(data, after5)
    if level == nil or enhance == nil or star == nil or quantity == nil then return nil, after6 end
    local flags, after7 = readVarint(data, after6)
    if flags == nil then return nil, after7 end
    pos = after7

    local item = {
        slot = slot,
        equipmentId = equipmentId,
        rarity = rarity,
        level = level,
        enhance = enhance,
        star = star,
        quantity = quantity,
    }

    if flags % 2 >= 1 then
        local setId, setIdPos = readString(data, pos)
        if setId == nil then return nil, setIdPos end
        local setEnabled, setPos = readVarint(data, setIdPos)
        if setEnabled == nil then return nil, setPos end
        item.setId = setId
        item.setEnabled = setEnabled == 1
        pos = setPos
    end
    if (flags % 4) >= 2 then
        local source, sourcePos = readString(data, pos)
        if source == nil then return nil, sourcePos end
        item.source = source
        pos = sourcePos
    end

    local atk, atkPos = readBig(data, pos)
    local def, defPos = readBig(data, atkPos)
    local hp, hpPos = readBig(data, defPos)
    local crit, critPos = readFraction(data, hpPos)
    local critDmg, cdPos = readFraction(data, critPos)
    local atkSpeed, asPos = readFraction(data, cdPos)
    local lifeSteal, lsPos = readFraction(data, asPos)
    local damageReduction, drPos = readFraction(data, lsPos)
    local bossDamage, bdPos = readFraction(data, drPos)
    if atk == nil or def == nil or hp == nil or crit == nil or critDmg == nil
        or atkSpeed == nil or lifeSteal == nil or damageReduction == nil or bossDamage == nil
    then
        return nil, bdPos
    end
    item.atkBig = atk
    item.defBig = def
    item.hpBig = hp
    item.crit = crit
    item.critDmg = critDmg
    item.atkSpeed = atkSpeed
    item.lifeSteal = lifeSteal
    item.damageReduction = damageReduction
    item.bossDamage = bossDamage
    pos = bdPos

    if (flags % 8) >= 4 then
        local coreAffixes, affixPos = readStringList(data, pos)
        if coreAffixes == nil then return nil, affixPos end
        item.coreAffixes = coreAffixes
        pos = affixPos
    end
    if (flags % 16) >= 8 then
        local uniqueEffects, effectPos = readStringList(data, pos)
        if uniqueEffects == nil then return nil, effectPos end
        item.uniqueEffects = uniqueEffects
        pos = effectPos
    end

    return item, pos
end

-- ============================================================================
-- 公共 API
-- ============================================================================

--- 将装备数组 + 个性签名 index 打包为二进制 blob（hex 字符串由调用方另行编码）
---@param items table[] 装备权威数据数组
---@param trashTalkIndex number|nil 个性展示垃圾话索引（0 起）
---@return string|nil
function LeaderboardCodec.Pack(items, trashTalkIndex)
    items = type(items) == "table" and items or {}
    local count = math.min(MAX_ITEMS, #items)
    local out = {}
    writeVarint(out, VERSION)
    writeVarint(out, math.max(0, math.floor(tonumber(trashTalkIndex) or 0)))
    writeVarint(out, count)
    for index = 1, count do
        packItem(out, items[index])
    end
    return table.concat(out, "")
end

--- 将二进制 blob 解码为装备权威数据数组
---@param blob string 二进制字符串（未 hex 编码）
---@return table[]|nil, string|nil, integer
function LeaderboardCodec.Unpack(blob)
    if type(blob) ~= "string" or blob == "" then return nil, "empty blob", 0 end
    local version, pos = readVarint(blob, 1)
    if version == nil then return nil, "bad version", 0 end
    if version > VERSION then return nil, "unsupported version", 0 end
    local trashTalkIndex = 0
    if version >= 2 then
        trashTalkIndex, pos = readVarint(blob, pos)
        if trashTalkIndex == nil then return nil, "bad trash index", 0 end
    end
    local count, after = readVarint(blob, pos)
    if count == nil then return nil, "bad count", 0 end
    pos = after
    local items = {}
    for _ = 1, math.min(MAX_ITEMS, count) do
        local item, next = unpackItem(blob, pos)
        if item == nil then return nil, "corrupt item", 0 end
        items[#items + 1] = item
        pos = next
    end
    return items, nil, trashTalkIndex
end

-- ============================================================================
-- hex 编码（JSON 通道安全）
-- ============================================================================

local HEX_CHARS = "0123456789abcdef"

function LeaderboardCodec.ToHex(blob)
    if type(blob) ~= "string" then return "" end
    local out = {}
    for index = 1, #blob do
        local byte = blob:byte(index)
        out[#out + 1] = HEX_CHARS:sub(math.floor(byte / 16) + 1, math.floor(byte / 16) + 1)
        out[#out + 1] = HEX_CHARS:sub((byte % 16) + 1, (byte % 16) + 1)
    end
    return table.concat(out, "")
end

function LeaderboardCodec.FromHex(hex)
    if type(hex) ~= "string" or hex == "" then return "" end
    if #hex % 2 ~= 0 then return "" end
    local out = {}
    for index = 1, #hex, 2 do
        local high = tonumber(hex:sub(index, index), 16) or 0
        local low = tonumber(hex:sub(index + 1, index + 1), 16) or 0
        out[#out + 1] = string.char(high * 16 + low)
    end
    return table.concat(out, "")
end

LeaderboardCodec.VERSION = VERSION
LeaderboardCodec.MAX_ITEMS = MAX_ITEMS

return LeaderboardCodec
