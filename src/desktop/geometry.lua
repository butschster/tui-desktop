-- All public rectangles are 1-based cells with exclusive right/bottom bounds.
local geometry = {}
function geometry.whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end
local whole = geometry.whole
function geometry.rect(x: any, y: any, w: any, h: any): any
    return {x = whole(x), y = whole(y), w = whole(math.max(0, whole(w))), h = whole(math.max(0, whole(h)))}
end
function geometry.contains(rect: any, x: any, y: any): boolean
    return type(x) == "number" and type(y) == "number" and x >= rect.x and y >= rect.y
        and x < rect.x + rect.w and y < rect.y + rect.h
end
function geometry.inset(rect: any, padding: any): any
    local n = whole(math.max(0, whole(padding)))
    return geometry.rect(rect.x + math.min(n, rect.w), rect.y + math.min(n, rect.h), rect.w - n * 2, rect.h - n * 2)
end
return geometry
