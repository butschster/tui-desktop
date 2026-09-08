-- Композитор в пиксельном режиме, поднятый проверкой.
--
-- Аргумент — «служба|наблюдатель|вид»: вид выбирает, что именно проверяется —
-- исправный размер ячейки, отсутствие ответа от терминала или тема без
-- chrome.paint. Отказ composer'а уезжает наблюдателю: `run` возвращает причину,
-- и потерять её здесь значило бы проверять молчание молчанием.
local process = require("process")
local library = require("library")
local pixel_chrome = require("pixel_chrome")
local cell_chrome = require("cell_chrome")
local flat_chrome = require("flat_chrome")

local function split(text)
    local out = {}
    for piece in tostring(text):gmatch("[^|]+") do out[#out + 1] = piece end
    return out
end

local function main(args)
    local parts = split(args)
    local service, watcher, kind = parts[1], parts[2], parts[3] or "ok"

    -- Раскладка стола: четыре значка сеткой два на два, координаты названы
    -- явно — по ним же считает проверка, куда должна уехать стрелка.
    local function desktop_items()
        return {
            {id = "i1", title = "Первый", entry = "app:menu_target", x = 2, y = 4, w = 20, h = 6},
            {id = "i2", title = "Второй", entry = "app:menu_target", x = 14, y = 4, w = 20, h = 6},
            {id = "i3", title = "Третий", entry = "app:menu_target", x = 2, y = 8, w = 20, h = 6},
            {id = "i4", title = "Четвёртый", entry = "app:menu_target", x = 14, y = 8, w = 20, h = 6},
        }, nil
    end

    local options: any = {
        chrome = pixel_chrome,
        desktop_properties = "app:menu_target",
        service_name = service,
        pixels = true,
        restore = false,
        desktop_items = desktop_items,
    }

    if kind == "actions" then
        pixel_chrome.clock_entry = "app:view_window"
        options.cell_size = function() return 10, 20 end
        options.catalog = function()
            return {{title = "Завершение работы", action = "quit"}}, nil
        end
    elseif kind == "insets" then
        pixel_chrome.configure_insets()
        options.cell_size = function() return 10, 20 end
    elseif kind == "ok" then
        options.cell_size = function() return 10, 20 end
    elseif kind == "silent" then
        -- Ровно то, чем отвечает gfx.cell_size() на терминале, который
        -- промолчал: nil и причина.
        options.cell_size = function()
            return nil, "the terminal did not say how large a cell is"
        end
    elseif kind == "nothing" then
        options.cell_size = nil
    elseif kind == "flat" then
        options.chrome = flat_chrome
        options.cell_size = function() return 10, 20 end
    elseif kind == "cells_theme" then
        options.chrome = cell_chrome
        options.cell_size = function() return 10, 20 end
    end

    local ok, err = library.run(options)
    if not ok then
        process.send(tostring(watcher), "composer.refused", {error = tostring(err)})
    end
    return ok, err
end

return {main = main}
