-- Что запись реестра говорит о своей программе.
--
-- Одно место, где `meta` окна превращается в поля, которыми пользуются
-- механика и тема: тип окна, признак «показывать в меню», размер и заголовок.
-- Разойдись эти чтения по местам вызова — умолчание однажды посчиталось бы
-- по-разному в меню и при открытии, и одно и то же окно выглядело бы
-- диалогом из «Пуска» и обычным окном с рабочего стола.
--
-- Чистые таблицы: ни одного вызова в рантайм, поэтому проверяется прямо.

local programs = {}

-- Пометка, по которой композитор находит окна приложения в реестре.
programs.WINDOW_META_TYPE = "tui_desktop.window"

-- Тип окна выбирает теме состав кнопок заголовка. Значения объявлены
-- списком, а не выведены из вида записи: вид принадлежит реестру, тип —
-- оболочке.
programs.DEFAULT_TYPE = "app"
programs.TYPES = {app = true, dialog = true, tool = true}

-- Чем рисуется содержимое окна. Объявляет ЗАПИСЬ, а не вывод из того, кто
-- написал программу внутри: вывод следующий читатель сделает иначе.
--
-- Умолчание — `cells`, и это не вкус. Чужая программа (bash, htop) умеет
-- выдавать только ячейки; окно, чья запись про это поле молчит, обязано вести
-- себя как раньше. Ошибиться в сторону `cells` — потерять красоту; ошибиться в
-- сторону `pixels` — потерять bash.
programs.DEFAULT_CONTENT = "cells"
programs.CONTENTS = {cells = true, pixels = true}

local function meta_of(record: any)
    local entry: any = type(record) == "table" and record or {}
    if type(entry.meta) == "table" then return entry.meta end
    if type(entry.data) == "table" and type(entry.data.meta) == "table" then return entry.data.meta end
    return {}
end

-- window_type(meta) -> тип, неизвестное значение или nil
--
-- Неизвестный тип — это `app` и предупреждение, а не отказ показать
-- программу: запись объявлена кем-то другим, и опечатка в одном поле не
-- повод спрятать окно, которое в остальном исправно.
function programs.window_type(meta: any)
    if type(meta) ~= "table" then return programs.DEFAULT_TYPE, nil end
    local given: any = meta.window_type
    if type(given) ~= "string" or given == "" then return programs.DEFAULT_TYPE, nil end
    if programs.TYPES[given] then return given, nil end
    return programs.DEFAULT_TYPE, given
end

-- in_menu(meta) -> показывать ли программу в меню
--
-- По умолчанию да: спрятанной должна быть та программа, которая об этом
-- попросила. Строка "false" считается отказом наравне с булевым: запись
-- приезжает и из YAML, и из JSON, и молчаливое «строка — это правда»
-- показало бы в меню ровно те окна, которые просили спрятать.
-- Читается полем, а не через `and … or`: у `false` эта конструкция даёт
-- ветку «значения нет», то есть ровно противоположный ответ — скрытая
-- программа оказалась бы в меню.
function programs.in_menu(meta: any)
    if type(meta) ~= "table" then return true end
    local given: any = meta.in_menu
    if given == nil then return true end
    if given == false or given == "false" then return false end
    return true
end

-- content(meta) -> "cells" | "pixels", неизвестное значение или nil
--
-- Неизвестное значение — это `cells` и предупреждение: окно, объявившее
-- опечатку, обязано открыться как обычное, а не пропасть.
function programs.content(meta: any)
    if type(meta) ~= "table" then return programs.DEFAULT_CONTENT, nil end
    local given: any = meta.window_content
    if type(given) ~= "string" or given == "" then return programs.DEFAULT_CONTENT, nil end
    if programs.CONTENTS[given] then return given, nil end
    return programs.DEFAULT_CONTENT, given
end

-- resizable(meta) -> можно ли менять размер окна
--
-- По умолчанию да: окно с фиксированным размером — то, которое об этом
-- попросило. Калькулятор и диалог свойств в Windows 95 не тянутся за угол и
-- не разворачиваются: их раскладка посчитана под один размер, и растянутое
-- окно показало бы серое поле вокруг кнопок. Строка "false" считается
-- отказом наравне с булевым — запись приезжает и из YAML, и из JSON.
function programs.resizable(meta: any)
    if type(meta) ~= "table" then return true end
    local given: any = meta.resizable
    if given == nil then return true end
    if given == false or given == "false" then return false end
    return true
end

local function reference(meta: any, field)
    if type(meta) ~= "table" then return nil end
    local given: any = meta[field]
    if type(given) ~= "string" or given == "" then return nil end
    return given
end

-- item(record) -> пункт каталога или nil
--
-- nil означает «это не программа»: запись без идентификатора открыть нечем.
function programs.item(record: any)
    local entry: any = type(record) == "table" and record or {}
    local id = entry.id
    if type(id) ~= "string" or id == "" then return nil, nil end

    local meta = meta_of(entry)
    local window_type, unknown = programs.window_type(meta)
    local content, odd_content = programs.content(meta)
    return {
        entry = id,
        title = type(meta.title) == "string" and meta.title ~= "" and meta.title or id,
        w = tonumber(meta.width),
        h = tonumber(meta.height),
        window_type = window_type,
        in_menu = programs.in_menu(meta),
        -- Чем рисуется содержимое и чем оно живёт. `render` — чистая
        -- библиотека отрисовки, `state` — процесс-поставщик со своим актором:
        -- рисование в композиторе, права снаружи.
        content = content,
        render = reference(meta, "render"),
        state = reference(meta, "state"),
        pixel_render = reference(meta, "pixel_render"),
        pixel_state = reference(meta, "pixel_state"),
        image = reference(meta, "image"),
        -- Фиксированный размер объявляет запись, а не тот, кто открывает:
        -- иначе один и тот же калькулятор тянулся бы из меню и не тянулся
        -- бы с ярлыка.
        resizable = programs.resizable(meta),
        -- Какие расширения программа открывает (`meta.opens: [txt, png]`).
        -- Доезжает до пункта как есть: реестр типов собирает оболочка, и
        -- пункт, потерявший это поле, оставил бы проводник без ассоциаций.
        opens = type(meta.opens) == "table" and meta.opens or nil,
    }, unknown or odd_content
end

-- menu(records) -> пункты меню, предупреждения
--
-- Пункты отсортированы по заголовку, скрытые отброшены. Предупреждения —
-- список {entry, window_type} с неизвестными типами: они не мешают показать
-- программу, но должны быть названы, иначе опечатка в объявлении живёт
-- вечно.
function programs.menu(records: any)
    local items, warnings = {}, {}
    for _, record in ipairs(type(records) == "table" and records or {}) do
        local item, unknown = programs.item(record)
        if item then
            if unknown then
                warnings[#warnings + 1] = {entry = item.entry, window_type = unknown}
            end
            if item.in_menu then items[#items + 1] = item end
        end
    end
    table.sort(items, function(left, right) return left.title < right.title end)
    return items, warnings
end

return programs
