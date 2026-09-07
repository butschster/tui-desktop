-- GET /tui-desktop/windows — что сейчас открыто на экране.
--
-- Аутентификацию обеспечивает роутер (token_auth + endpoint_firewall);
-- проверка актора держит честными прямые вызовы.
local http = require("http")
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

    local answer, err = control.call("desktop.list", {})
    if not answer then
        res:set_status(http.STATUS.SERVICE_UNAVAILABLE)
        res:write_json({success = false, error = err})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        windows = answer.windows or {},
        focused = answer.focused,
        screen = answer.screen,
    })
end

return {handler = handler}
