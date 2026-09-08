-- Canonical input for both viewport events and window.input messages.
local input = {}
local aliases = {pgdn = "pgdown", page_down = "pgdown", pagedown = "pgdown",
    page_up = "pgup", pageup = "pgup", escape = "esc", return_key = "enter"}
function input.normalize(value: any): any
    local event: any = {}
    if type(value) ~= "table" then return event end
    for key, item in pairs(value) do event[key] = item end
    if event.type == "key" then
        local key = tostring(event.key_type or event.key or "")
        key = aliases[key] or key
        event.key_type = key
        if key ~= "runes" then event.key = key end
    end
    return event
end
function input.key(event: any): any
    event = input.normalize(event)
    if event.type ~= "key" or event.action == "release" then return nil end
    return event.key_type
end
function input.pressed(event: any): boolean
    return event.type == "mouse" and event.action == "press" and event.button == "left"
end
return input
