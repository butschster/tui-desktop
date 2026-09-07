-- Композитор: механика оконного десктопа, вызываемая как библиотека.
--
-- Вида здесь нет. Всё, что рисуется, приходит темой в options.chrome, и
-- геометрию хрома — сколько строк занято сверху и снизу — тоже объявляет
-- она. Поэтому вторая оболочка приносит свою тему и получает другой вид,
-- не копируя ни хостинг окон, ни PTY, ни командный канал.
--
-- Он держит список окон в z-порядке, кладёт их кадры на общий холст,
-- раздаёт ввод и принимает команды снаружи. Окна о нём не знают: каждое
-- пишет в свой viewport через обычный `tty` и считает, что владеет
-- терминалом целиком.
--
-- Три правила, нарушение которых даёт молчаливую поломку:
--   * ни один yield-вызов не заканчивает функцию голым `return` — в
--     go-lua v1.5.18 такой хвостовой вызов не выполняется вовсе;
--   * `snapshot().rows` — общий неизменяемый массив брокера, его нельзя
--     править на месте;
--   * `viewport:send` до `tty.start()` окна — ошибка, а не потеря, поэтому
--     ввод придерживается до первого кадра.

local channel = require("channel")
local process = require("process")
local registry = require("registry")
local time = require("time")
local tty = require("tty")

local logger = require("logger")

local repo = require("repo")
local apps = require("apps")

local WINDOW_HOST = "butschster.tui_desktop:workers"

-- Окно — это любая запись процесса, которая умеет писать в свой tty-порт.
-- Модуль знает ровно одну свою (программа под PTY); всё остальное приносит
-- приложение и называет записью — иначе каждое новое окно требовало бы
-- правки этого модуля.
local PTY_WINDOW = "butschster.tui_desktop.desktop:window_pty"

-- Каталог окон приложения: записи, помеченные этим meta.type, композитор
-- находит сам и показывает в меню по alt+o.
local WINDOW_META_TYPE = "tui_desktop.window"
local REPLY_TOPIC = "desktop.reply"

local DEFAULT_COMMAND = "/bin/bash --noprofile --norc"
local CLOSE_GRACE = "3s"

local MIN_W, MIN_H = 12, 5

-- Часы на панели задач должны идти и тогда, когда никто ничего не нажимает.
-- Без этого тика кадр обновляется только на событии, и время на экране
-- останавливается — вид «оболочка зависла» при исправной оболочке.
local CLOCK_TICK = "15s"

-- Печатаемый текст, который агент шлёт в окно, отправляется по одной
-- клавише: у окна нет «вставки», а `paste` доезжает до программы только
-- если та включила bracketed paste.
local function runes(text)
    local out = {}
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = char
    end
    return out
end

-- Сообщение процесса приезжает обёрнутым: payload — userdata, а внутри
-- бывает ещё и массив из одного элемента. Прочитать поле напрямую значит
-- получить nil без всякой ошибки.
local function unwrap(value)
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        if ok and type(decoded) == "table" then return decoded end
        return {}
    end
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil and #value > 0 then return unwrap(value[1]) end
    return value
end

-- clamp принимает что угодно и всегда возвращает целое: значения приходят
-- и от мыши, и из JSON команды, где числом может оказаться что угодно.
local function clamp(value, low, high)
    local lo = math.floor(low)
    local hi = math.floor(high)
    if lo > hi then lo = hi end
    local number = tonumber(value)
    if not number then return lo end
    number = math.floor(number)
    if number < lo then return lo end
    if number > hi then return hi end
    return number
end

-- run(options) — поднять композитор на текущем терминале.
--
--   options.chrome        — тема (контракт в README). Обязательна.
--   options.service_name  — имя, под которым композитор виден процессам.
--   options.hint          — подсказка на пустом рабочем столе.
local function run(options: any)
    options = type(options) == "table" and options or {}

    -- Тема обязательна и не подставляется молча: композитор без вида — это
    -- пустой экран, в котором нечего искать. Пусть отказ назовёт причину.
    local chrome: any = options.chrome
    if type(chrome) ~= "table" then
        return nil, "композитору не передана тема (options.chrome)"
    end

    local SERVICE_NAME = type(options.service_name) == "string"
        and options.service_name ~= "" and options.service_name
        or "butschster.tui_desktop.desktop"

    local HINT = type(options.hint) == "string" and options.hint
        or "alt+n — окно с bash · alt+o — приложения · ctrl+q — выход"

    -- Каталог программ. Внутренний отдаёт плоский список: механике окон
    -- незачем знать про папки меню и значки. Оболочка, которой это нужно,
    -- приносит свой — и отвечает за форму сама.
    local read_catalog: any = type(options.catalog) == "function" and options.catalog or nil

    -- Раскладка рабочего стола — ярлыки и папки. Механика их не хранит и
    -- не создаёт: это состояние оболочки, которое двигает пользователь.
    -- Она только показывает то, что дали, и говорит, куда кликнули.
    local read_desktop: any = type(options.desktop_items) == "function" and options.desktop_items or nil

    -- Восстановление окон мастерской требует права менять реестр. Оболочке
    -- под другим актором его может не быть, и тогда важно, чтобы отказ был
    -- назван, а не проглочен: он уезжает в restore_report.
    local RESTORE = options.restore ~= false

    -- Записать новое место значка. Раскладку хранит оболочка, поэтому
    -- композитор не пишет её сам, а просит — и откатывает значок, если
    -- запись не удалась. Отказ, после которого значок остался на новом
    -- месте, соврал бы: до перезапуска он там, после — нет.
    local move_item: any = type(options.move_desktop_item) == "function"
        and options.move_desktop_item or nil

    local events = assert(tty.events())
    assert(tty.start())
    assert(tty.mouse(true))

    local lifecycle = assert(process.events())
    local inbox = process.inbox()
    process.registry.register(SERVICE_NAME)

    -- Окна, собранные в рантайме, возвращаются в реестр здесь, а не фоновым
    -- сервисом: платформа намеренно запрещает процессам в группе
    -- `wippy.security:process` менять реестр, и такой сервис молча не сделал
    -- бы ничего. Композитор работает под собственным актором, и права у него
    -- свои — а нужны эти окна ровно тогда, когда десктоп запущен.
    local log = logger:named("tui_desktop.desktop")

    -- Итог восстановления держится в состоянии и отдаётся командным каналом:
    -- лог терминального хоста заглушён (иначе он разъедет кадр), и отказ,
    -- рассказанный только в лог, не расскажут никому.
    local restore_report: any = {restored = 0, failed = 0, error = nil, names = {}}

    local stored: any = nil
    local store_err: any = nil
    if RESTORE then stored, store_err = repo.list() end

    if not RESTORE then
        restore_report.skipped = true
    elseif store_err then
        restore_report.error = tostring(store_err)
        log:error("хранилище окон недоступно", {error = tostring(store_err)})
    else
        local restored, failed = 0, {}
        for _, window in ipairs(stored or {}) do
            local ok, aerr = apps.apply(window)
            if ok then
                restored = restored + 1
            else
                failed[#failed + 1] = window.name .. ": " .. tostring(aerr)
                log:error("окно не поднялось", {window = window.name, error = tostring(aerr)})
            end
        end
        restore_report.restored = restored
        restore_report.failed = #failed
        restore_report.names = failed
        if restored > 0 or #failed > 0 then
            log:info("окна восстановлены",
                {restored = restored, failed = #failed, names = table.concat(failed, ", ")})
        end
    end

    local out = assert(tty.surface({
        alternate_screen = true,
        hide_cursor = true,
        synchronized_output = true,
    }))

    -- Размера может не быть вовсе: запуск не из терминала (скрипт, CI,
    -- пайп) отвечает нулями, и холст такую ширину отвергает — процесс падал
    -- на первой же строке с «canvas width must be positive».
    local FALLBACK_W, FALLBACK_H = 80, 24
    local MIN_SCREEN_W, MIN_SCREEN_H = 8, 6

    local function screen_geometry()
        local w, h = tty.screen_size()
        w = math.floor(tonumber(w) or 0)
        h = math.floor(tonumber(h) or 0)
        if w < MIN_SCREEN_W then w = FALLBACK_W end
        if h < MIN_SCREEN_H then h = FALLBACK_H end
        return w, h
    end

    local width, height = screen_geometry()
    local canvas = tty.canvas(width, height)

    -- Первая и последняя строка, свободные под окна. Считаются по теме, а
    -- не по константе: у одной полоса окон сверху, у другой панель задач
    -- снизу.
    -- math.floor, а не литерал: линтер различает integer и number, а дальше
    -- эти границы уезжают в clamp, где ждут number.
    local desktop_top = math.floor(2)
    local desktop_last = math.floor(height - 1)

    local function apply_layout()
        local spec: any = chrome.layout(width, height)
        if type(spec) ~= "table" then spec = {} end
        local top = math.tointeger(tonumber(spec.top) or 1) or 1
        local bottom = math.tointeger(tonumber(spec.bottom) or 1) or 1
        if top < 0 then top = 0 end
        if bottom < 0 then bottom = 0 end
        -- Тема, попросившая больше экрана, чем есть, не должна ронять
        -- композитор: окна уехали бы за край молча.
        if top + bottom >= height then
            top = 0
            if bottom >= height then bottom = math.tointeger(height - 1) or 0 end
            if bottom < 0 then bottom = 0 end
        end
        desktop_top = top + 1
        desktop_last = height - bottom
        if desktop_last < desktop_top then desktop_last = desktop_top end
    end

    apply_layout()

    -- windows — z-порядок: последний рисуется поверх и держит фокус.
    local windows = {}
    local next_id = 0
    -- Перетаскивание: одна структура вместо «либо nil, либо таблица» —
    -- во второй форме поля смещения для проверяющего не существуют.
    local drag: any = {active = false, id = "", mode = "move", dx = 0, dy = 0}
    -- Меню открыто — весь ввод принадлежит ему, включая цифры: иначе выбор
    -- пункта уехал бы в окно под меню.
    local menu: any = nil
    -- Разметка попаданий, которую вернула тема при последней отрисовке. И
    -- рисование, и клик считаются по ней одной.
    local catalog: any
    local bar_hits: any = {}
    local desk_hits: any = {}
    -- Ярлыки стола держатся в состоянии, а не читаются на каждый кадр:
    -- кадр рисуется десятки раз в секунду, а раскладка меняется руками.
    local desk: any = {items = {}, failure = nil}
    -- Двойной щелчок: как в оболочке, откуда взят вид. Одиночный щелчок,
    -- запускающий программу, — ловушка: по значку кликают, чтобы выбрать.
    local last_click: any = {x = 0, y = 0, at = 0}
    -- Выделение живёт здесь, а не в раскладке: его меняет каждый щелчок, а
    -- раскладка — то, что переживает перезапуск.
    local selected_id: any = nil
    -- Причина последнего отказа. Показывается вместо статуса: у оболочки
    -- терминала нет ни лога, ни всплывающих окон, и рассказать иначе негде.
    local notice = ""
    local menu_hits: any = {}
    local clock = ""

    local quitting = false

    local function desktop_height() return math.max(1, desktop_last - desktop_top + 1) end

    local function index_of(id)
        for index, window in ipairs(windows) do
            if window.id == id then return index end
        end
        return 0
    end

    local function find(id)
        local index = index_of(id)
        if index == 0 then return nil end
        return windows[index]
    end

    -- Фокус — верхнее развёрнутое окно. Отдельного поля нет нарочно: два
    -- источника истины про фокус разъезжаются на первом же закрытии.
    local function focused()
        for index = #windows, 1, -1 do
            if not windows[index].minimized and not windows[index].closing then
                return windows[index]
            end
        end
        return nil
    end

    local function raise(window)
        local index = index_of(window.id)
        if index == 0 or index == #windows then return end
        table.remove(windows, index)
        windows[#windows + 1] = window
    end

    -- Раскладка перечитывается по команде, а не по таймеру: её меняют
    -- ручки оболочки, и они же говорят композитору, что пора обновиться.
    local function reload_desktop()
        if not read_desktop then
            desk = {items = {}, failure = nil}
            return
        end
        local items, failure = read_desktop()
        desk = {
            items = type(items) == "table" and items or {},
            failure = failure and tostring(failure) or nil,
        }
    end

    -- Шаг сетки значков объявляет тема: она рисует значок и знает, сколько
    -- он занимает. Композитор только выравнивает по нему брошенный значок —
    -- иначе значок встаёт между шагами и перекрывается попаданием соседа.
    local function icon_grid()
        local grid: any = nil
        if type(chrome.icon_grid) == "function" then grid = chrome.icon_grid() end
        if type(grid) ~= "table" then grid = {w = chrome.ICON_W, h = chrome.ICON_H} end
        local gw = math.tointeger(tonumber(grid.w) or 14) or 14
        local gh = math.tointeger(tonumber(grid.h) or 3) or 3
        if gw < 1 then gw = 1 end
        if gh < 1 then gh = 1 end
        return gw, gh
    end

    local function snap(value: any, step: any, base: any)
        local origin = math.tointeger(tonumber(base) or 1) or 1
        local size = math.tointeger(tonumber(step) or 1) or 1
        if size < 1 then size = 1 end
        local point = math.tointeger(tonumber(value) or origin) or origin
        local offset = point - origin
        if offset < 0 then offset = 0 end
        local cell = math.tointeger((offset + size // 2) // size) or 0
        return origin + cell * size
    end

    local function desktop_item(id)
        for _, item in ipairs(desk.items) do
            if item.id == id then return item end
        end
        return nil
    end

    local function desktop_spot(x, y)
        for _, spot in ipairs(desk_hits) do
            if y == spot.row and x >= spot.from and x <= spot.to then return spot end
        end
        return nil
    end

    local function draw()
        canvas:clear(" ")

        -- Фон рисует и значки стола, если тема умеет: композитор отдаёт ей
        -- раскладку и границы свободного места, а обратно берёт разметку
        -- попаданий — по ней же считается щелчок.
        desk_hits = {}
        local painted = chrome.fill(canvas, width, height, {
            top = desktop_top,
            bottom = desktop_last,
            items = desk.items,
            failure = desk.failure,
            selected = selected_id,
        })
        if type(painted) == "table" then desk_hits = painted end

        if #windows == 0 then
            chrome.empty_desktop(canvas, width, height, HINT)
        end

        local top = focused()
        for _, window in ipairs(windows) do
            if not window.minimized then
                chrome.window(canvas, window, top ~= nil and window.id == top.id)
            end
        end

        -- Считается до ветвления по `top`: после if/else линтер держит его
        -- сужённым и поле `id` для него уже не существует.
        local focused_id = top and top.id or nil

        local status
        if top then
            status = string.format("%s · %dx%d · окон: %d · alt+n bash · alt+o приложения · alt+w закрыть · ctrl+q выход",
                top.title, math.max(0, top.w - 2), math.max(0, top.h - 2), #windows)
        else
            status = "нет окон · alt+n окно с bash · alt+o приложения · ctrl+q выход"
        end
        if notice ~= "" then status = notice end

        bar_hits = chrome.bars(canvas, width, height, {
            windows = windows,
            focused_id = focused_id,
            menu_open = menu ~= nil,
            status = status,
            clock = clock,
        })
        if type(bar_hits) ~= "table" then bar_hits = {} end

        menu_hits = {}
        if menu then
            local hits = chrome.menu(canvas, width, height, menu.items, menu.failure)
            if type(hits) == "table" then menu_hits = hits end
        end

        -- Аппаратный курсор один на экран, поэтому его получает только
        -- фокусное окно — и со смещением на свою рамку, иначе он встанет
        -- строкой выше собственного текста.
        local cursor = nil
        if top and top.cursor then
            cursor = {
                x = clamp(top.x + top.cursor.x, 1, width),
                y = clamp(top.y + top.cursor.y, 1, height),
                visible = top.cursor.visible,
            }
        end

        assert(out:present(canvas:rows(), {cursor = cursor}))
    end

    local function open_window(spec)
        spec = type(spec) == "table" and spec or {}

        local entry = type(spec.entry) == "string" and spec.entry ~= "" and spec.entry or PTY_WINDOW

        local w = clamp(spec.w or math.floor(width * 0.6), MIN_W, width)
        local h = clamp(spec.h or math.floor(desktop_height() * 0.7), MIN_H, desktop_height())
        -- Каскад, чтобы новое окно не легло ровно на предыдущее и не
        -- выглядело как отсутствие результата.
        local step = (#windows % 6) * 2
        local x = clamp(spec.x or (2 + step), 1, math.max(1, width - w + 1))
        local y = clamp(spec.y or (desktop_top + step), desktop_top, math.max(desktop_top, height - h))

        local view, verr = tty.viewport({width = w - 2, height = h - 2})
        if not view then return nil, tostring(verr) end

        local updates, uerr = view:updates()
        if not updates then return nil, tostring(uerr) end

        local grant, gerr = view:grant()
        if not grant then return nil, tostring(gerr) end

        local command = type(spec.command) == "string" and spec.command ~= ""
            and spec.command or DEFAULT_COMMAND

        -- Окно-приложение получает свой параметр (`args`), окно с программой —
        -- команду. Одно поле на оба смысла читалось бы как «команда», и окно
        -- подробностей открывали бы строкой «/bin/bash».
        local argument = type(spec.args) == "string" and spec.args ~= ""
            and spec.args or command

        local pid, perr = process.with_options({terminal = grant})
            :spawn_monitored(entry, WINDOW_HOST, argument)
        if not pid then
            view:close()
            return nil, tostring(perr)
        end

        next_id = next_id + 1
        local window = {
            id = "w" .. next_id,
            entry = entry,
            title = type(spec.title) == "string" and spec.title ~= "" and spec.title
                or (entry == PTY_WINDOW and command or entry),
            command = command,
            x = x, y = y, w = w, h = h,
            view = view, updates = updates, pid = pid,
            rows = {}, cursor = nil, revision = -1,
            ready = false, minimized = false, maximized = false,
            closing = false, deadline = nil,
            saved = {x = x, y = y, w = w, h = h},
        }
        windows[#windows + 1] = window
        return window, nil
    end

    -- Закрытие: сначала вежливо, потом по сроку. Окно, ещё не позвавшее
    -- tty.start(), ввод не принимает — его гасим сразу.
    local function close_window(window)
        if window.closing then return end
        window.closing = true
        if window.ready then
            window.view:send({type = "close"})
            window.deadline = time.after(CLOSE_GRACE)
        else
            process.terminate(tostring(window.pid))
        end
    end

    local function forget(window)
        local index = index_of(window.id)
        if index > 0 then table.remove(windows, index) end
        window.view:close()
    end

    local function resize_window(window, w: any, h: any)
        window.w = clamp(tonumber(w) or window.w, MIN_W, width)
        window.h = clamp(tonumber(h) or window.h, MIN_H, desktop_height())
        window.x = clamp(window.x, 1, math.max(1, width - window.w + 1))
        window.y = clamp(window.y, desktop_top, math.max(desktop_top, height - window.h))
        window.view:resize(window.w - 2, window.h - 2)
    end

    local function toggle_maximize(window)
        if window.maximized then
            local saved = window.saved
            window.maximized = false
            window.x = saved.x
            window.y = saved.y
            resize_window(window, saved.w, saved.h)
        else
            window.saved = {x = window.x, y = window.y, w = window.w, h = window.h}
            window.maximized = true
            window.x, window.y = 1, desktop_top
            resize_window(window, width, desktop_height())
        end
    end

    local function send_to(window, event)
        if not window or not window.ready or window.closing then return false end
        local ok = window.view:send(event)
        return ok and true or false
    end

    -- ─── ввод ────────────────────────────────────────────────────────────

    local function hit(x, y)
        for index = #windows, 1, -1 do
            local window = windows[index]
            if not window.minimized and not window.closing
                and x >= window.x and x <= window.x + window.w - 1
                and y >= window.y and y <= window.y + window.h - 1 then
                return window
            end
        end
        return nil
    end

    -- Кнопка под точкой заголовка. Считается по той же таблице, по которой
    -- заголовок рисуется, — иначе кнопка «закрыть» однажды окажется на
    -- символ левее, чем выглядит.
    local function button_at(window, x)
        if window.w < chrome.BUTTONS_WIDTH + 6 then return nil end
        local from = window.x + window.w - 1 - chrome.BUTTONS_WIDTH
        if x < from or x > from + chrome.BUTTONS_WIDTH - 1 then return nil end
        local slot = math.floor((x - from) / 3) + 1
        local button = chrome.BUTTONS[slot]
        return button and button.id or nil
    end

    local function handle_mouse(event)
        if event.action == "motion" and drag.active and drag.mode == "icon" then
            local item = desktop_item(drag.id)
            if not item then drag.active = false; return end
            item.x = clamp(event.x - drag.dx, 1, width)
            item.y = clamp(event.y - drag.dy, desktop_top, desktop_last)
            draw()
            return
        end

        if event.action == "motion" and drag.active then
            local window = find(drag.id)
            if not window then drag.active = false; return end
            if drag.mode == "move" then
                window.x = clamp(event.x - drag.dx, 1, math.max(1, width - window.w + 1))
                window.y = clamp(event.y - drag.dy, desktop_top, math.max(desktop_top, height - window.h))
            else
                resize_window(window, event.x - window.x + 1, event.y - window.y + 1)
            end
            draw()
            return
        end

        if event.action == "release" then
            if drag.active and drag.mode == "icon" then
                drag.active = false
                local item = desktop_item(drag.id)
                if item then
                    local gw, gh = icon_grid()
                    item.x = snap(item.x, gw, 1)
                    item.y = snap(item.y, gh, desktop_top)
                    if move_item then
                        local ok, err = move_item(drag.id, item.x, item.y)
                        if not ok then
                            -- Значок обязан вернуться туда, откуда взят:
                            -- иначе до перезапуска он на новом месте, а
                            -- после — на старом, и человек решит, что
                            -- перезапуск его потерял.
                            item.x, item.y = drag.from_x, drag.from_y
                            notice = "значок не переехал: " .. tostring(err)
                        end
                    end
                end
                draw()
                return
            end
            if drag.active then drag.active = false; draw() end
            return
        end

        if event.action ~= "press" then return end

        -- Открытое меню забирает клик целиком: попал в пункт — открываем,
        -- мимо — закрываем. Иначе клик «мимо меню» уходил бы в окно под ним,
        -- и меню оставалось бы висеть поверх результата.
        if menu then
            for _, spot in ipairs(menu_hits) do
                if event.y == spot.row and event.x >= spot.from and event.x <= spot.to then
                    local item = menu.items[spot.index]
                    if item then
                        local window = open_window({
                            entry = item.entry, title = item.title, w = item.w, h = item.h,
                        })
                        if window then raise(window) end
                    end
                    menu = nil
                    draw()
                    return
                end
            end
            menu = nil
            draw()
            return
        end

        -- Полосы хрома: кнопка окна поднимает и разворачивает его, кнопка
        -- меню открывает и закрывает каталог.
        for _, spot in ipairs(bar_hits) do
            if event.y == spot.row and event.x >= spot.from and event.x <= spot.to then
                if spot.id then
                    local window = find(spot.id)
                    if window then
                        window.minimized = false
                        raise(window)
                        draw()
                    end
                elseif spot.action == "menu" then
                    if menu then
                        menu = nil
                    else
                        local items, failure = catalog()
                        menu = {items = items, failure = failure}
                    end
                    draw()
                end
                return
            end
        end

        local window = hit(event.x, event.y)
        if not window then
            -- Пустое место: под окнами лежит стол со значками. Одиночный
            -- щелчок выделяет и берёт значок, двойной открывает.
            notice = ""
            local moment = time.now():unix_nano()
            local repeated = last_click.x == event.x and last_click.y == event.y
                and (moment - last_click.at) < 500000000
            last_click = {x = event.x, y = event.y, at = moment}

            local spot = desktop_spot(event.x, event.y)
            if not spot then
                if selected_id then selected_id = nil; draw() end
                return
            end

            if spot.id then selected_id = spot.id end

            if repeated then
                if type(spot.entry) == "string" and spot.entry ~= "" then
                    local opened = open_window({
                        entry = spot.entry, title = spot.title,
                        w = spot.w, h = spot.h, args = spot.args,
                    })
                    if opened then raise(opened) end
                end
                draw()
                return
            end

            local item = spot.id and desktop_item(spot.id) or nil
            if item then
                local at_x = math.tointeger(tonumber(item.x) or event.x) or event.x
                local at_y = math.tointeger(tonumber(item.y) or event.y) or event.y
                drag = {active = true, id = spot.id, mode = "icon",
                    dx = event.x - at_x, dy = event.y - at_y,
                    from_x = at_x, from_y = at_y}
            end
            draw()
            return
        end
        raise(window)

        if event.y == window.y then
            local button = button_at(window, event.x)
            if button == "close" then close_window(window)
            elseif button == "minimize" then window.minimized = true
            elseif button == "maximize" then toggle_maximize(window)
            else
                drag = {active = true, id = window.id, mode = "move",
                    dx = event.x - window.x, dy = event.y - window.y}
            end
            draw()
            return
        end

        -- Правый нижний угол рамки тянет размер.
        if event.x == window.x + window.w - 1 and event.y == window.y + window.h - 1 then
            drag = {active = true, id = window.id, mode = "resize", dx = 0, dy = 0}
            draw()
            return
        end

        -- Тело окна: клик уходит внутрь, в координатах самого окна.
        send_to(window, {
            type = "mouse", action = event.action, button = event.button,
            x = event.x - window.x, y = event.y - window.y,
            alt = event.alt, ctrl = event.ctrl, shift = event.shift,
        })
        draw()
    end

    -- Акселераторы держатся на alt: ctrl и tab слишком часто нужны самим
    -- программам в окнах, и красть их — значит ломать редактор внутри.
    -- Каталог окон приложения. Читается в момент открытия меню, а не при
    -- старте: приложение может объявить окно и без перезапуска десктопа.
    catalog = function()
        if read_catalog then
            local items, failure = read_catalog()
            return type(items) == "table" and items or {}, failure
        end
        local found, err = registry.find({["meta.type"] = WINDOW_META_TYPE})
        if err then return {}, tostring(err) end
        if type(found) ~= "table" then return {}, "реестр ответил не списком" end
        local items = {}
        for _, entry in ipairs(found :: {any}) do
            local record = entry :: any
            local meta = type(record.meta) == "table" and record.meta or {}
            local id = record.id
            if type(id) == "string" then
                items[#items + 1] = {
                    entry = id,
                    title = type(meta.title) == "string" and meta.title or id,
                    w = tonumber(meta.width),
                    h = tonumber(meta.height),
                }
            end
        end
        table.sort(items, function(left, right) return left.title < right.title end)
        return items, nil
    end

    local function handle_key(event)
        if menu then
            if event.key_type == "esc" or (event.ctrl and event.key == "q") then
                menu = nil
                draw()
                return "handled"
            end
            local choice = type(event.key) == "string" and tonumber(event.key) or nil
            local item = choice and menu.items[choice] or nil
            if item then
                local window, err = open_window({
                    entry = item.entry, title = item.title, w = item.w, h = item.h,
                })
                if window then raise(window) end
                menu = nil
                draw()
            end
            return "handled"
        end

        if event.ctrl and event.key == "q" then
            quitting = true
            for index = #windows, 1, -1 do close_window(windows[index]) end
            if #windows == 0 then return "quit" end
            draw()
            return "handled"
        end

        if event.alt then
            local top = focused()
            if event.key == "n" then
                local window, err = open_window({})
                if window then raise(window) end
                if err then log:error("окно не открылось", {error = tostring(err)}) end
                draw()
                return "handled"
            elseif event.key == "w" and top then
                close_window(top); draw(); return "handled"
            elseif event.key == "m" and top then
                top.minimized = true; draw(); return "handled"
            elseif event.key == "o" then
                local items, failure = catalog()
                menu = {items = items, failure = failure}
                draw()
                return "handled"
            elseif event.key_type == "tab" and #windows > 1 then
                local bottom = windows[1]
                bottom.minimized = false
                raise(bottom); draw(); return "handled"
            elseif event.key and event.key:match("^[1-9]$") then
                local window = windows[tonumber(event.key)]
                if window then window.minimized = false; raise(window); draw() end
                return "handled"
            end
        end

        return "forward"
    end

    -- ─── команды снаружи ─────────────────────────────────────────────────

    local function describe(window)
        return {
            id = window.id, entry = window.entry, title = window.title, command = window.command,
            x = window.x, y = window.y, width = window.w, height = window.h,
            ready = window.ready, minimized = window.minimized,
            maximized = window.maximized, closing = window.closing,
        }
    end

    local function reply(body, to)
        if to == "" then return end
        process.send(to, REPLY_TOPIC, body)
    end

    local function handle_command(topic, body)
        local to = ""
        if type(body.reply_to) == "string" then to = body.reply_to end
        local window = find(type(body.id) == "string" and body.id or "")

        if topic == "desktop.list" then
            local list = {}
            for _, item in ipairs(windows) do list[#list + 1] = describe(item) end
            local top = focused()
            reply({ok = true, windows = list, focused = top and top.id or nil,
                screen = {width = width, height = height},
                restore = restore_report}, to)
            return false
        end

        if topic == "desktop.open" then
            local opened, err = open_window(body)
            if not opened then reply({ok = false, error = err}, to); return false end
            raise(opened)
            reply({ok = true, window = describe(opened)}, to)
            return true
        end

        -- Всё, что ниже, адресовано конкретному окну: молчаливое «нет
        -- такого» превратило бы опечатку в id в успешную команду.
        if not window then
            reply({ok = false, error = "нет окна " .. tostring(body.id)}, to)
            return false
        end

        if topic == "desktop.close" then
            close_window(window); reply({ok = true}, to); return true
        elseif topic == "desktop.focus" then
            window.minimized = false; raise(window); reply({ok = true}, to); return true
        elseif topic == "desktop.move" then
            window.x = clamp(body.x, 1, math.max(1, width - window.w + 1))
            window.y = clamp(body.y, desktop_top, math.max(desktop_top, height - window.h))
            reply({ok = true, window = describe(window)}, to)
            return true
        elseif topic == "desktop.resize" then
            resize_window(window, body.w, body.h)
            reply({ok = true, window = describe(window)}, to)
            return true
        elseif topic == "desktop.minimize" then
            window.minimized = not not body.value
            reply({ok = true, window = describe(window)}, to)
            return true
        elseif topic == "desktop.screen" then
            -- Копия, а не сам массив: строки снимка — общая память брокера.
            local rows = {}
            for index, row in ipairs(window.rows) do rows[index] = row end
            reply({ok = true, id = window.id, rows = rows, ready = window.ready}, to)
            return false
        elseif topic == "desktop.type" then
            if not window.ready then
                reply({ok = false, error = "окно ещё не приняло ввод"}, to)
                return false
            end
            local sent = 0
            for _, char in ipairs(runes(type(body.text) == "string" and body.text or "")) do
                if send_to(window, {type = "key", key = char, key_type = "runes", action = "press"}) then
                    sent = sent + 1
                end
            end
            if body.enter then
                send_to(window, {type = "key", key = "enter", key_type = "enter", action = "press"})
            end
            reply({ok = true, sent = sent}, to)
            return false
        elseif topic == "desktop.key" then
            local key = type(body.key) == "string" and body.key or ""
            if key == "" then reply({ok = false, error = "клавиша не названа"}, to); return false end
            local ok = send_to(window, {
                type = "key", key = key, key_type = body.key_type or key,
                action = "press", ctrl = not not body.ctrl,
                alt = not not body.alt, shift = not not body.shift,
            })
            reply({ok = ok, error = ok and nil or "окно не приняло ввод"}, to)
            return false
        end

        if topic == "desktop.refresh" then
            reload_desktop()
            reply({ok = true, items = #desk.items, failure = desk.failure}, to)
            return true
        end

        reply({ok = false, error = "неизвестная команда " .. tostring(topic)}, to)
        return false
    end

    -- ─── цикл ────────────────────────────────────────────────────────────

    local function tick_clock()
        local now = time.now()
        local text = now and now:format("15:04") or ""
        if text == clock then return false end
        clock = text
        return true
    end

    tick_clock()
    reload_desktop()
    draw()

    local ticker = time.after(CLOCK_TICK)

    while true do
        local cases = {
            events:case_receive(),
            lifecycle:case_receive(),
            inbox:case_receive(),
            ticker:case_receive(),
        }
        local watched = {}
        for _, window in ipairs(windows) do
            cases[#cases + 1] = window.updates:case_receive()
            watched[#watched + 1] = window
            if window.deadline then
                cases[#cases + 1] = window.deadline:case_receive()
            end
        end

        local selected = channel.select(cases)
        if not selected.ok then break end

        -- Тик часов не событие окна: он ничего не пересылает, только
        -- обновляет кадр, если минута сменилась.
        local handled = false
        if selected.channel == ticker then
            ticker = time.after(CLOCK_TICK)
            if tick_clock() then draw() end
            handled = true
        end

        -- Кадр окна. Уведомление — водяной знак, а не кадр: состояние
        -- всегда берётся снимком.
        for _, window in ipairs(watched) do
            if selected.channel == window.updates then
                local snapshot = window.view:snapshot(window.revision)
                if snapshot then
                    window.rows = snapshot.rows
                    window.cursor = snapshot.cursor
                    window.revision = snapshot.revision
                    window.ready = true
                    if not window.minimized then draw() end
                end
                handled = true
                break
            end
            if window.deadline and selected.channel == window.deadline then
                process.terminate(tostring(window.pid))
                window.deadline = nil
                handled = true
                break
            end
        end

        if not handled then
            if selected.channel == inbox then
                local message = selected.value
                if message then
                    local body = unwrap(message:payload())
                    if handle_command(message:topic(), body) then draw() end
                end
            elseif selected.channel == lifecycle then
                local event = selected.value
                if event.kind == process.event.EXIT then
                    for index = #windows, 1, -1 do
                        if windows[index].pid == event.from then
                            forget(windows[index])
                            break
                        end
                    end
                    draw()
                    if quitting and #windows == 0 then break end
                end
            else
                local event = selected.value
                if event.type == "resize" then
                    -- Ресайз тоже приходит с нулями, когда терминал исчез;
                    -- нулевой холст уронил бы композитор вместе со всеми окнами.
                    local w = math.floor(tonumber(event.width) or 0)
                    local h = math.floor(tonumber(event.height) or 0)
                    if w >= MIN_SCREEN_W then width = w end
                    if h >= MIN_SCREEN_H then height = h end
                    canvas = tty.canvas(width, height)
                    apply_layout()
                    for _, window in ipairs(windows) do
                        if window.maximized then
                            window.x, window.y = 1, desktop_top
                            resize_window(window, width, desktop_height())
                        else
                            resize_window(window, window.w, window.h)
                        end
                    end
                    out:invalidate()
                    draw()
                elseif event.type == "mouse" then
                    handle_mouse(event)
                elseif event.type == "key" then
                    local verdict = handle_key(event)
                    if verdict == "quit" then break end
                    if verdict == "forward" and not quitting then
                        send_to(focused(), event)
                    end
                elseif event.type ~= "start" then
                    if not quitting then send_to(focused(), event) end
                end
            end
        end
    end

    for _, window in ipairs(windows) do
        window.view:close()
    end
    process.registry.unregister(SERVICE_NAME)
    assert(tty.mouse(false))
    assert(out:close())
    assert(tty.stop())
end

return {run = run}
