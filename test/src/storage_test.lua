-- Хранилище окон, собранных в рантайме.
--
-- Проверяется то, из-за чего дефект был бы незаметен: круг «сохранил —
-- прочитал — удалил» на живой базе и правила сборки записи реестра, которые
-- решают, что окну можно.
local test = require("test")
local repo = require("repo")
local apps = require("apps")

local NAME = "storage_probe"

local SOURCE = [[
local tty = require("tty")
local function main() end
return {main = main}
]]

local function define_tests()
    test.describe("butschster.tui_desktop storage", function()
        test.it("переживает круг сохранил — прочитал — удалил", function()
            repo.delete(NAME)

            local saved, serr = repo.save({
                name = NAME, title = "Проба", width = 30, height = 8,
                source = SOURCE, modules = {"tty", "channel"},
            })
            test.is_nil(serr)
            test.eq(saved, NAME)

            local window, gerr = repo.get(NAME)
            test.is_nil(gerr)
            test.not_nil(window, "сохранённое окно должно читаться обратно")
            test.eq(window.title, "Проба")
            test.eq(window.width, 30)
            test.eq(window.source, SOURCE)

            local listed, lerr = repo.list()
            test.is_nil(lerr)
            local found = false
            for _, item in ipairs(listed or {}) do
                if item.name == NAME then found = true end
            end
            test.is_true(found, "окно должно быть в списке")

            -- Удаление отвечает, БЫЛА ли строка: иначе опечатка в имени
            -- выглядит успешным удалением.
            local existed = repo.delete(NAME)
            test.is_true(existed, "удаление существующего окна возвращает true")
            test.is_false(repo.delete(NAME), "повторное удаление возвращает false")
            test.is_nil(repo.get(NAME), "удалённое окно не читается")
        end)

        test.it("повторное имя перезаписывает, а не задваивает", function()
            repo.delete(NAME)
            repo.save({name = NAME, title = "Первый", width = 10, height = 4,
                source = SOURCE, modules = {}})
            repo.save({name = NAME, title = "Второй", width = 20, height = 6,
                source = SOURCE, modules = {}})

            local window = repo.get(NAME)
            test.not_nil(window)
            test.eq(window.title, "Второй")

            local listed = repo.list()
            local count = 0
            for _, item in ipairs(listed or {}) do
                if item.name == NAME then count = count + 1 end
            end
            test.eq(count, 1, "имя — ключ, второй строки быть не должно")
            repo.delete(NAME)
        end)
    end)

    test.describe("butschster.tui_desktop app entries", function()
        test.it("не пускает окну чужие модули", function()
            -- Окно рисует себя и читает данные; порождать процессы и ходить
            -- наружу ему нечем, и отказ обязан называть модуль по имени.
            local refused = apps.rejected_modules({"tty", "process", "exec", "httpclient"})
            test.eq(#refused, 3)

            local allowed = apps.normalize_modules({"sql", "process", "json"})
            local names = {}
            for _, name in ipairs(allowed) do names[name] = true end
            test.is_true(names.sql, "sql разрешён — без него не будет виджетов с данными")
            test.is_true(names.json, "json разрешён")
            test.is_nil(names.process, "process окну не выдаётся")
        end)

        test.it("всегда добавляет tty и channel", function()
            -- Без них окно не нарисуется и не дождётся события: упадёт уже
            -- после того, как человек решит, что оно создано.
            local names = {}
            for _, name in ipairs(apps.normalize_modules({})) do names[name] = true end
            test.is_true(names.tty, "tty обязателен")
            test.is_true(names.channel, "channel обязателен")
        end)

        test.it("собирает запись окна под своей политикой", function()
            local entry = apps.build_entry({
                name = "probe", title = "Проба", width = 30, height = 8,
                source = SOURCE, modules = {"tty"},
            })
            test.eq(entry.id, "butschster.tui_desktop.apps:probe")
            test.eq(entry.kind, "process.lua")
            test.eq(entry.meta.type, "tui_desktop.window")
            test.eq(entry.meta.title, "Проба")
            test.eq(entry.data.method, "main")
            test.eq(entry.data.security.policies[1],
                "butschster.tui_desktop.security:app_window_scope")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
