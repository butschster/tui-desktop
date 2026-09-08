-- Offsets count hidden logical rows (zero based). Selection stays app-owned.
local scroll = {}
local geometry = require("geometry")
local whole = geometry.whole
function scroll.limit(total: any, page: any): integer
    return whole(math.max(0, whole(total) - math.max(1, whole(page))))
end
function scroll.clamp(offset: any, total: any, page: any): integer
    return whole(math.max(0, math.min(whole(offset), scroll.limit(total, page))))
end
function scroll.reveal(offset: any, index: any, total: any, page: any): integer
    page = math.max(1, whole(page))
    if index <= offset then offset = index - 1
    elseif index > offset + page then offset = index - page end
    return scroll.clamp(offset, total, page)
end
function scroll.key(offset: any, key: any, total: any, page: any): integer
    if key == "home" then return 0 end
    if key == "end" then return scroll.limit(total, page) end
    local step = ({up = -1, down = 1, pgup = -math.max(1, page), pgdown = math.max(1, page)})[key] or 0
    return scroll.clamp(offset + step, total, page)
end
function scroll.wheel(offset: any, button: any, total: any, page: any, step: any): integer
    local direction = button == "wheel_up" and -1 or (button == "wheel_down" and 1 or 0)
    return scroll.clamp(offset + direction * math.max(1, whole(step or 3)), total, page)
end
-- Track is between arrow cells; thumb geometry is shared by paint and input.
function scroll.bar(offset: any, total: any, page: any, height: any, arrow_rows: any?): any
    local arrow = whole(math.min(math.max(1, whole(arrow_rows or 1)), math.max(1, whole(height) // 2)))
    local track = whole(math.max(0, whole(height) - 2 * arrow))
    local size = track == 0 and 0 or whole(math.max(1, math.min(track, math.floor(track * math.max(1, page) / math.max(1, total)))))
    local limit = scroll.limit(total, page)
    local travel = track - size
    local start = limit == 0 and 0 or whole(math.floor(scroll.clamp(offset, total, page) * travel / limit + 0.5))
    return {start = start + arrow, size = size, travel = travel, limit = limit, arrow = arrow}
end
function scroll.drag(position: any, grab: any, bar: any): integer
    if bar.travel <= 0 then return 0 end
    return whole(math.max(0, math.min(bar.limit, math.floor((position - (bar.arrow or 1) - grab) * bar.limit / bar.travel + 0.5))))
end
-- Pure pointer adapter. rect is the entire bar in client cells; capture is
-- retained by the app until release. Painting uses scroll.bar with these sizes.
function scroll.pointer(offset: any, total: any, page: any, rect: any, capture: any, event: any): (any, any, boolean)
    local bar = scroll.bar(offset, total, page, rect.h, rect.arrow_rows)
    local row = (tonumber(event.y) or rect.y) - rect.y
    if capture and (event.action == "motion" or event.action == "release") then
        local next_capture = capture
        if event.action == "release" then next_capture = nil end
        return scroll.drag(row, capture.grab, bar), next_capture, true
    end
    if event.type ~= "mouse" or event.action ~= "press" or event.button ~= "left"
        or type(event.x) ~= "number" or type(event.y) ~= "number"
        or event.x < rect.x or event.x >= rect.x + rect.w or row < 0 or row >= rect.h or bar.limit == 0 then
        return scroll.clamp(offset, total, page), capture, false
    end
    if row < bar.arrow then offset = offset - 1
    elseif row >= rect.h - bar.arrow then offset = offset + 1
    elseif row >= bar.start and row < bar.start + bar.size then capture = {grab = row - bar.start}
    else offset = offset + (row < bar.start and -page or page) end
    return scroll.clamp(offset, total, page), capture, true
end
return scroll
