-- Растровая тема для проверок: та же форма, что у настоящей, но без графики.
--
-- Размещения приходят БЕЗ растра — поверхность это разрешает («картинка уже
-- на экране, оставь как есть»), и именно поэтому пиксельный путь композитора
-- проверяется на рантайме, где модуля gfx нет вовсе. Проверяется при этом всё,
-- что принадлежит композитору: пробелы под картинками, содержимое окон
-- символами и разметка попаданий.

local chrome = {}

chrome.pixel = true

function chrome.layout(width, height)
    return {top = 1, bottom = 1}
end

function chrome.window_insets()
    return {top = 1, bottom = 1, left = 1, right = 1}
end

function chrome.icon_grid()
    return {w = 12, h = 4, left = 2}
end

-- Кнопок заголовка у этой темы нет: щелчки по заголовку в проверках не нужны,
-- а молчаливый nil честнее выдуманной таблицы.
function chrome.title_button_at(window, x: any, y: any)
    return nil
end

-- Один кусок на заголовок каждого окна и один на панель задач — так же, как
-- будет у настоящей: резать по строкам, чтобы набор текста в окне не
-- переотправлял весь хром.
function chrome.paint(state: any, cell_w, cell_h)
    local placements, slots = {}, {}

    for index, window in ipairs(state.windows) do
        placements[#placements + 1] = {
            id = "win:" .. tostring(window.id) .. ":title",
            x = window.x, y = window.y, cols = window.w, rows = 1,
        }
        -- Кнопка окна на панели задач: десять ячеек на окно.
        slots[#slots + 1] = {
            row = state.height, from = index * 10 - 9, to = index * 10,
            id = window.id,
        }
    end

    placements[#placements + 1] = {
        id = "taskbar", x = 1, y = state.height, cols = state.width, rows = 1,
    }

    return {
        placements = placements,
        hits = {desktop = {}, bars = slots, menu = {}},
    }
end

return chrome
