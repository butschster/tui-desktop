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

-- item(record) -> пункт каталога или nil
--
-- nil означает «это не программа»: запись без идентификатора открыть нечем.
function programs.item(record: any)
    local entry: any = type(record) == "table" and record or {}
    local id = entry.id
    if type(id) ~= "string" or id == "" then return nil, nil end

    local meta = meta_of(entry)
    local window_type, unknown = programs.window_type(meta)
    return {
        entry = id,
        title = type(meta.title) == "string" and meta.title ~= "" and meta.title or id,
        w = tonumber(meta.width),
        h = tonumber(meta.height),
        window_type = window_type,
        in_menu = programs.in_menu(meta),
    }, unknown
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
