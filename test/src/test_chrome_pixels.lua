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

-- Заливка стола — ЯЧЕЙКАМИ, и в пиксельном режиме тоже: иначе тело окна
-- просвечивает столом там, где программа внутри ничего не написала, а сам стол
-- держится на цвете терминала, а не на своём.
function chrome.fill(canvas: any, width, height, state: any)
    local row = string.rep("▒", math.tointeger(width) or 0)
    for line = math.tointeger(state.top) or 1, math.tointeger(state.bottom) or 1 do
        canvas:put(1, line, row, width)
    end

    -- Значок даёт ДВЕ строки попаданий — рисунок и подпись, как у настоящей
    -- темы. Композитор обязан свести их в один значок: иначе стрелка вниз
    -- уходила бы с рисунка на его же подпись.
    local hits = {}
    for _, item in ipairs(state.items or {}) do
        local x = math.tointeger(item.x) or 1
        local y = math.tointeger(item.y) or 1
        for line = 0, 1 do
            hits[#hits + 1] = {
                row = y + line, from = x, to = x + 9,
                id = item.id, entry = item.entry, title = item.title,
                w = item.w, h = item.h, args = item.args,
            }
        end
    end
    return hits
end

-- Кнопка «Пуск» на панели задач и строка, с которой начинается меню. Числа
-- вынесены, потому что по ним же щёлкает проверка: разъехавшись, они дали бы
-- «щелчок не сработал» вместо честного отказа.
chrome.MENU_BUTTON = {from = 60, to = 70}
chrome.MENU_ROW = 6

-- Один кусок на заголовок каждого окна и один на панель задач — так же, как
-- будет у настоящей: резать по строкам, чтобы набор текста в окне не
-- переотправлял весь хром.
function chrome.paint(state: any, cell_w, cell_h)
    local placements, slots, choices = {}, {}, {}

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

    -- Кнопка меню — такое же попадание полосы, только с действием вместо
    -- номера окна.
    slots[#slots + 1] = {
        row = state.height, from = chrome.MENU_BUTTON.from,
        to = chrome.MENU_BUTTON.to, action = "menu",
    }

    -- Меню рисуется, только когда композитор говорит, что оно открыто: его
    -- состояние держит механика, а тема лишь показывает.
    if state.menu then
        local items: any = state.menu.items or {}
        placements[#placements + 1] = {
            id = "menu", x = 2, y = chrome.MENU_ROW,
            cols = 30, rows = math.max(1, #items),
        }
        local at = math.tointeger(state.menu.cursor) or 1
        for index in ipairs(items) do
            choices[#choices + 1] = {
                row = chrome.MENU_ROW + index - 1, from = 2, to = 31, index = index,
                -- Уровень и номер — по ним ходит курсор; пометка — по ней
                -- открывают. Считать выбор дважды здесь и там значило бы
                -- завести два мнения о том, что выбрано.
                level = 1, slot = index, cursor = index == at,
            }
        end
    end

    return {
        placements = placements,
        hits = {desktop = {}, bars = slots, menu = choices},
    }
end

return chrome
