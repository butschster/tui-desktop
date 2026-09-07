-- Окно, собранное в рантайме, как запись реестра.
--
-- Одно место, где решается, во что превращается присланный код: им пользуются
-- и мастерская (когда окно собирают), и загрузчик (когда его поднимают после
-- перезапуска). Разойдись эти две сборки — окно вело бы себя по-разному до и
-- после рестарта, а это худший вид расхождения: он проявляется через сутки.

local registry = require("registry")

local apps = {}

apps.NAMESPACE = "butschster.tui_desktop.apps"
apps.WINDOW_TYPE = "tui_desktop.window"
apps.POLICY = "butschster.tui_desktop.security:app_window_scope"

-- Что окну можно требовать. Список узкий нарочно: окно рисует себя и читает
-- данные, но не порождает процессов и не ходит наружу.
apps.ALLOWED_MODULES = {
    channel = true,
    time = true,
    tty = true,
    json = true,
    sql = true,
    env = true,
}

apps.DEFAULT_MODULES = {"channel", "time", "tty"}

function apps.entry_id(name)
    return apps.NAMESPACE .. ":" .. name
end

-- Собранное окно всегда несёт tty и channel: без них оно не сможет ни
-- нарисоваться, ни дождаться события, и упадёт на первой же строке — уже
-- после того, как человек решит, что окно создано.
function apps.normalize_modules(requested)
    local seen, out = {}, {}
    local function add(name: any)
        if type(name) == "string" and apps.ALLOWED_MODULES[name] and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    for _, name in ipairs(type(requested) == "table" and requested or {}) do add(name) end
    add("channel")
    add("tty")
    table.sort(out)
    return out
end

-- Модули, которые запрошены, но не разрешены. Отказ обязан называть их:
-- «окно не работает» без имени модуля отправляет искать ошибку в коде окна.
function apps.rejected_modules(requested)
    local out = {}
    for _, name in ipairs(type(requested) == "table" and requested or {}) do
        if type(name) ~= "string" or not apps.ALLOWED_MODULES[name] then
            out[#out + 1] = tostring(name)
        end
    end
    return out
end

function apps.build_entry(window)
    return {
        id = apps.entry_id(window.name),
        kind = "process.lua",
        meta = {
            type = apps.WINDOW_TYPE,
            title = window.title,
            width = window.width,
            height = window.height,
            comment = "Собрано в рантайме; исходник хранится в butschster_tui_desktop_windows.",
        },
        data = {
            source = window.source,
            method = "main",
            modules = apps.normalize_modules(window.modules),
            security = {policies = {apps.POLICY}},
        },
    }
end

-- apply(window) -> (true, nil) | (nil, причина)
--
-- Повторное имя — обновление: `create` поверх занятого id отказывается, и
-- правка окна выглядела бы как «имя занято навсегда».
function apps.apply(window)
    local snapshot, serr = registry.snapshot()
    if not snapshot then return nil, "снимок реестра: " .. tostring(serr) end

    local entry = apps.build_entry(window)
    local changes = snapshot:changes()
    if registry.get(entry.id) then
        changes:update(entry)
    else
        changes:create(entry)
    end

    local version, aerr = changes:apply()
    if not version then return nil, "применение версии: " .. tostring(aerr) end
    return true, nil
end

-- remove(name) -> (true, nil) | (nil, причина)
--
-- Запись, которой нет, — это успех: удаление должно приводить к отсутствию,
-- а не спорить о том, как отсутствие возникло.
function apps.remove(name)
    local id = apps.entry_id(name)
    if not registry.get(id) then return true, nil end

    local snapshot, serr = registry.snapshot()
    if not snapshot then return nil, "снимок реестра: " .. tostring(serr) end

    local changes = snapshot:changes()
    changes:delete(id)
    local version, aerr = changes:apply()
    if not version then return nil, "применение версии: " .. tostring(aerr) end
    return true, nil
end

return apps
