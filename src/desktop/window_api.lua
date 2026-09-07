-- Что окно может попросить у десктопа.
--
-- Окно рисует себя и получает ввод, но соседями не распоряжается: чтобы
-- открыть, закрыть или поднять окно, оно просит об этом композитор — тот же
-- путь, которым ходит командный канал снаружи. Своего доступа к процессам и
-- программам у окна нет.
--
-- Библиотека существует, чтобы каждый виджет не переписывал протокол
-- сообщений заново: разойдись эти реализации, и половина окон однажды начала
-- бы слать команды, которых композитор уже не понимает.

local process = require("process")

local SERVICE_NAME = "butschster.tui_desktop.desktop"

local api = {}

local function call(topic, body)
    local pid, lerr = process.registry.lookup(SERVICE_NAME)
    if not pid then
        return nil, "десктоп не отвечает (" .. tostring(lerr) .. ")"
    end
    local sent, serr = process.send(pid, topic, body or {})
    if not sent then
        return nil, "команда не дошла: " .. tostring(serr)
    end
    return true, nil
end

-- open{entry=…, title=…, args=…, x=…, y=…, w=…, h=…}
--
-- Ответа не ждём намеренно: окно рисует себя, и ожидание чужого ответа
-- заморозило бы кадр. Что окно открылось, видно на экране.
function api.open(spec)
    spec = type(spec) == "table" and spec or {}
    return call("desktop.open", spec)
end

function api.close(id)
    return call("desktop.close", {id = id})
end

function api.focus(id)
    return call("desktop.focus", {id = id})
end

return api
