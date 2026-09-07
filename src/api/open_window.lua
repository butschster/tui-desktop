-- POST /tui-desktop/windows — открыть окно с программой.
--
-- Тело: {"entry": "…:window_calc", "args": "…", "command": "...",
--         "title": "...", "x": 1, "y": 2, "w": 80, "h": 20}.
-- `args` — параметр окна-приложения, `command` — программа для PTY-окна.
-- Всё необязательно; без записи открывается окно с интерактивным bash, и
-- тогда `command` называет программу.
local http = require("http")
local json = require("json")
local security = require("security")
local control = require("control")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then return nil, "no http context" end
    res:set_content_type(http.CONTENT.JSON)

    if not security.actor() then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({success = false, error = "authentication required"})
        return
    end

    local body = json.decode(req:body() or "") or {}
    if type(body) ~= "table" then body = {} end

    local answer, err = control.call("desktop.open", {
        entry = body.entry, args = body.args, command = body.command, title = body.title,
        x = body.x, y = body.y, w = body.w, h = body.h,
    })
    if not answer then
        res:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        res:write_json({success = false, error = err})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({success = true, window = answer.window})
end

return {handler = handler}
