-- Text in cells: UTF-8 runes, cell counts and clipping. One splitter for
-- every window: seven copies of the same gmatch pattern diverged on the
-- first edit, and a caret that counts bytes lands inside a Cyrillic letter.
local text = {}
local RUNE = "[%z\1-\127\194-\244][\128-\191]*"
text.RUNE = RUNE
-- runes(value) -> array of UTF-8 characters
function text.runes(value: any): {string}
    local out: {string} = {}
    for char in tostring(value or ""):gmatch(RUNE) do out[#out + 1] = char end
    return out
end
-- cells(value) -> how many terminal cells the text takes (one per rune)
function text.cells(value: any): integer
    return #text.runes(value)
end
-- clip(value, room) -> the first `room` runes
function text.clip(value: any, room: any): string
    local limit = math.tointeger(math.floor(tonumber(room) or 0)) or 0
    if limit <= 0 then return "" end
    local chars = text.runes(value)
    if #chars <= limit then return tostring(value or "") end
    return table.concat(chars, "", 1, limit)
end
return text
