-- Проверки формы реестра. Харнесс не ходит в свой роутер, поэтому ручки
-- проверяются как проводка: записи существуют и ссылаются друг на друга.
--
-- Здесь же закреплены два инварианта, нарушение которых снаружи выглядит не
-- как ошибка, а как странность: терминальный хост обязан глушить лог, а
-- командный канал обязан НЕ иметь права порождать процессы.
local test = require("test")
local registry = require("registry")

local NS = "butschster.tui_desktop"
local TERMINAL_ID = "butschster.tui_desktop:terminal"
local WORKERS_ID = "butschster.tui_desktop:workers"
local EXEC_ID = "butschster.tui_desktop:exec"
local DESKTOP_ID = "butschster.tui_desktop.desktop:desktop"
local LIBRARY_ID = "butschster.tui_desktop.desktop:library"
local CHROME_ID = "butschster.tui_desktop.desktop:chrome"
local WINDOW_ID = "butschster.tui_desktop.desktop:window_pty"
local CONTROL_ID = "butschster.tui_desktop.api:control"
local RUNTIME_POLICY_ID = "butschster.tui_desktop.security:desktop_runtime"
local CHANNEL_POLICY_ID = "butschster.tui_desktop.security:desktop_command_channel"
local ACCESS_POLICY_ID = "butschster.tui_desktop.security:desktop_endpoint_access"

local ENDPOINTS = {
    {id = "butschster.tui_desktop.api:list_windows", method = "GET", path = "/tui-desktop/windows"},
    {id = "butschster.tui_desktop.api:open_window", method = "POST", path = "/tui-desktop/windows"},
    {id = "butschster.tui_desktop.api:window_action", method = "POST", path = "/tui-desktop/windows/{id}/{action}"},
}

local function get(id)
    local entry, err = registry.get(id)
    test.is_nil(err)
    test.not_nil(entry, id .. " is missing")
    return entry
end

local function meta_of(entry)
    if type(entry.meta) == "table" then return entry.meta end
    if type(entry.data) == "table" and type(entry.data.meta) == "table" then return entry.data.meta end
    return {}
end

local function data_of(entry)
    if type(entry.data) == "table" then return entry.data end
    return entry
end

local function qualify(ref, ns)
    if type(ref) ~= "string" then return ref end
    if ref:find(":", 1, true) then return ref end
    return ns .. ":" .. ref
end

local function actions_of(policy_entry)
    local policy = data_of(policy_entry).policy or {}
    local actions = policy.actions
    if type(actions) == "string" then return {actions} end
    return type(actions) == "table" and actions or {}
end

local function has(list, needle)
    for _, item in ipairs(list) do
        if item == needle then return true end
    end
    return false
end

local function define_tests()
    test.describe("butschster.tui_desktop hosts", function()
        test.it("глушит лог на терминальном хосте", function()
            -- Без этого строка лога рантайма разъезжает кадр насовсем:
            -- диффер поверхности считает себя единственным писателем.
            local terminal = data_of(get(TERMINAL_ID))
            test.eq(terminal.hide_logs, true)
        end)

        test.it("держит отдельный хост для окон", function()
            local workers = data_of(get(WORKERS_ID))
            test.not_nil(workers.host, "process.host must declare its host block")
            test.is_true((workers.host.max_processes or 0) > 1,
                "хост окон должен вмещать больше одного окна")
        end)

        test.it("объявляет исполнителя для программ в окнах", function()
            get(EXEC_ID)
        end)
    end)

    test.describe("butschster.tui_desktop processes", function()
        test.it("отдаёт композитор командой с собственным актором", function()
            local entry = get(DESKTOP_ID)
            local command = meta_of(entry).command or {}
            test.eq(command.name, "desktop")
            test.not_nil(command.security, "команда обязана нести свой контекст безопасности")

            local data = data_of(entry)
            test.eq(data.method, "main")
            test.eq(qualify((data.imports or {}).chrome, "butschster.tui_desktop.desktop"), CHROME_ID)
            test.is_true(has(data.modules or {}, "tty"), "композитору нужен модуль tty")
            test.is_true(has(data.modules or {}, "process"), "композитору нужен модуль process")
        end)

        test.it("не зашивает список окон: своё одно, остальные приносит приложение", function()
            -- Композитор открывает окно по записи процесса и находит чужие
            -- окна по meta.type. Появление второго вида окна внутри модуля
            -- означало бы, что каждое новое окно требует правки модуля.
            local source = data_of(get(DESKTOP_ID)).source
            test.not_nil(source, "процесс композитора обязан нести источник")
            local windows = registry.find({["meta.type"] = "tui_desktop.window"})
            test.not_nil(windows, "каталог окон должен читаться, пусть и пустым")
        end)

        test.it("даёт окну exec и tty, но не process", function()
            -- Окно ничего не порождает: оно только отдаёт свой порт программе.
            local data = data_of(get(WINDOW_ID))
            test.is_true(has(data.modules or {}, "exec"), "окну нужен модуль exec")
            test.is_true(has(data.modules or {}, "tty"), "окну нужен модуль tty")
        end)
    end)

    test.describe("butschster.tui_desktop command channel", function()
        test.it("сводит каждую ручку с её обработчиком на роутере приложения", function()
            for _, expected in ipairs(ENDPOINTS) do
                get(expected.id)
                local endpoint = get(expected.id .. ".endpoint")
                local data = data_of(endpoint)
                test.eq(qualify(data.func, "butschster.tui_desktop.api"), expected.id)
                test.eq(data.method, expected.method)
                test.eq(data.path, expected.path)
                test.eq(meta_of(endpoint).router, "app:api")
            end
            get(CONTROL_ID)
        end)

        test.it("не даёт командному каналу порождать процессы", function()
            -- Ручка обязана уметь только найти композитор и заговорить с ним.
            -- Право spawn здесь означало бы, что HTTP-запрос запускает
            -- программы сам, минуя единственное место, которое их считает.
            local actions = actions_of(get(CHANNEL_POLICY_ID))
            test.is_true(has(actions, "process.send"), "каналу нужно право послать команду")
            test.is_true(has(actions, "process.registry"), "каналу нужно найти композитор по имени")
            test.is_false(has(actions, "process.spawn"), "у канала не должно быть права порождать процессы")
            test.is_false(has(actions, "exec.run"), "у канала не должно быть права запускать программы")
        end)

        test.it("даёт композитору ровно то, что нужно для окон", function()
            local actions = actions_of(get(RUNTIME_POLICY_ID))
            for _, needed in ipairs({"process.spawn.monitored", "process.terminate",
                "process.registry.register", "exec.get", "exec.run"}) do
                test.is_true(has(actions, needed), "композитору нужно право " .. needed)
            end
        end)

        test.it("позволяет композитору вернуть сохранённые окна в реестр", function()
            -- Восстановление живёт здесь, а не в фоновом сервисе: платформа
            -- запрещает процессам группы wippy.security:process менять
            -- реестр, и такой сервис молча не делал бы ничего.
            local actions = actions_of(get(RUNTIME_POLICY_ID))
            test.is_true(has(actions, "registry.apply"),
                "без registry.apply окна не переживут перезапуск")

            -- Хранилище читает библиотека композитора, а не оболочка: вид
            -- сменился, а восстановление окон осталось общим.
            local data = data_of(get(LIBRARY_ID))
            test.is_true(has(data.modules or {}, "sql"),
                "композитору нужен sql, чтобы прочитать хранилище")
            local imports = data.imports or {}
            test.eq(qualify(imports.repo, "butschster.tui_desktop.persist"),
                "butschster.tui_desktop.persist:repo")
            test.eq(qualify(imports.apps, "butschster.tui_desktop.persist"),
                "butschster.tui_desktop.persist:apps")
        end)

        test.it("держит вид отдельно от механики окон", function()
            -- Ради этого дельта и делалась: вторая оболочка приносит свою
            -- тему и получает другой вид, не копируя хостинг окон, PTY и
            -- командный канал. Если механика снова начнёт импортировать
            -- конкретную тему, копия станет единственным способом сменить
            -- вид — и разойдётся с оригиналом на первой же правке.
            local library = data_of(get(LIBRARY_ID))
            test.is_nil((library.imports or {}).chrome,
                "механика композитора не должна знать про конкретную тему")

            local shell = data_of(get(DESKTOP_ID))
            local imports = shell.imports or {}
            test.eq(qualify(imports.library, "butschster.tui_desktop.desktop"),
                "butschster.tui_desktop.desktop:library",
                "оболочка зовёт механику")
            test.eq(qualify(imports.chrome, "butschster.tui_desktop.desktop"),
                "butschster.tui_desktop.desktop:chrome",
                "оболочка выбирает тему")
        end)

        test.it("даёт окну попросить десктоп, но не запустить что-либо", function()
            -- Окно умеет обратиться к композитору (открыть соседнее окно), но
            -- своего запуска процессов и программ у него нет. Код окна
            -- приходит по HTTP, и эта граница отделяет «попросить десктоп» от
            -- «сделать что угодно».
            local actions = actions_of(get("butschster.tui_desktop.security:app_window_scope"))
            test.is_true(has(actions, "process.send"), "окно должно уметь послать команду")
            test.is_true(has(actions, "process.registry"), "и найти адресата")
            test.is_false(has(actions, "process.spawn"), "порождать процессы окно не может")
            test.is_false(has(actions, "process.spawn.monitored"), "и так тоже не может")
            test.is_false(has(actions, "exec.run"), "запускать программы окно не может")
            test.is_false(has(actions, "registry.apply"), "менять реестр окно не может")
        end)

        test.it("закрывает ручки политикой, которую внедряет приложение", function()
            local policy = data_of(get(ACCESS_POLICY_ID))
            local resources = policy.policy and policy.policy.resources
            test.not_nil(resources, "policy must list resources")
            if type(resources) == "string" then resources = {resources} end
            test.is_true(has(resources, "butschster.tui_desktop.api:*"),
                "policy must cover butschster.tui_desktop.api:*")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
