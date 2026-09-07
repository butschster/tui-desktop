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

-- Лог здесь не роскошь: `open` ответа не ждёт намеренно, и окно, которое не
-- проверило второе возвращаемое значение, иначе не расскажет об отказе никак.
-- Терминальный хост уводит лог в события, поэтому кадр он не разъезжает.
local logger = require("logger")
local log = logger:named("tui_desktop.window")

-- Имя композитора приезжает в контексте процесса: композитор кладёт его туда,
-- когда запускает окно. Ключ один на обе стороны — механика композитора
-- берёт его отсюда же, чтобы имя ключа не разошлось молча.
local CONTEXT_KEY = "tui_desktop.service"

-- Запасное имя — штатная оболочка. Окно, запущенное старым композитором или
-- чужим запуском, ведёт себя как раньше, а не падает.
local DEFAULT_SERVICE = "butschster.tui_desktop.desktop"

-- Модуль объявляет ЭТА библиотека, а не запись окна: библиотека получает свои
-- модули, поэтому окно, написанное до появления имени в контексте, работает
-- без единой правки. `require` недоступного модуля бросает, а окно не должно
-- умирать на первой строке из-за диагностики — отсюда pcall.
local has_ctx, ctx = pcall(require, "ctx")

local api = {}

api.CONTEXT_KEY = CONTEXT_KEY
api.DEFAULT_SERVICE = DEFAULT_SERVICE

-- service() -> имя композитора, откуда оно взято ("context" | "default")
--
-- Окну это знать незачем — оно зовёт open/close/focus. Наружу отдано ради
-- проверок и диагностики: «к кому обращается это окно» иначе не спросить.
function api.service()
    if has_ctx and type(ctx) == "table" then
        local name = ctx.get(CONTEXT_KEY)
        if type(name) == "string" and name ~= "" then return name, "context" end
    end
    return DEFAULT_SERVICE, "default"
end

-- Почему композитора не нашли. Отказ обязан назвать и имя, и то, откуда оно
-- взялось: молчание здесь и было исходным дефектом — под второй оболочкой
-- окно обращалось к несуществующему процессу, а `api.open` ответа не ждёт,
-- так что «успех» выглядел неотличимо от настоящего открытия.
local function unreachable(name, source, lerr)
    local reason = "десктоп «" .. name .. "» не отвечает (" .. tostring(lerr) .. ")"
    if source ~= "default" then return reason end
    if has_ctx then
        return reason .. "; имя композитора не пришло при запуске — в контексте нет ключа "
            .. CONTEXT_KEY .. ", поэтому взято запасное"
    end
    return reason .. "; имя композитора прочитать нечем — модуль ctx недоступен, "
        .. "поэтому взято запасное"
end

local function call(topic, body)
    local name, source = api.service()
    local pid, lerr = process.registry.lookup(name)
    if not pid then
        local reason = unreachable(name, source, lerr)
        log:error("окно не нашло свой десктоп",
            {service = name, source = source, topic = topic, error = reason})
        return nil, reason
    end
    local sent, serr = process.send(pid, topic, body or {})
    if not sent then
        return nil, "команда не дошла до «" .. name .. "»: " .. tostring(serr)
    end
    return true, nil
end

-- open{entry=…, title=…, args=…, x=…, y=…, w=…, h=…}
--
-- Ответа не ждём намеренно: окно рисует себя, и ожидание чужого ответа
-- заморозило бы кадр. Что окно открылось, видно на экране; что композитора не
-- нашли — видно во втором возвращаемом значении, и его стоит проверять.
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
