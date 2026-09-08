-- Растровая тема для проверок: та же форма, что у настоящей, но без графики.
--
-- Размещения приходят БЕЗ растра — поверхность это разрешает («картинка уже
-- на экране, оставь как есть»), и именно поэтому пиксельный путь композитора
-- проверяется на рантайме, где модуля gfx нет вовсе. Проверяется при этом всё,
-- что принадлежит композитору: пробелы под картинками, содержимое окон
-- символами и разметка попаданий.

local chrome = {}

chrome.pixel = true
local custom_insets = false
local zoom_cell: any = nil
function chrome.configure_cell_size(w, h)
    zoom_cell = {w = w, h = h}
end
function chrome.configure_insets()
    custom_insets = true
end

function chrome.window_background(canvas, window)
    if custom_insets then canvas:put(window.x + 2, window.y + 3, "BACKGROUND", 10) end
end

function chrome.layout(width, height)
    if zoom_cell then return {top = 1, bottom = math.ceil(28 / zoom_cell.h)} end
    return {top = 1, bottom = 1}
end

function chrome.window_insets()
    if zoom_cell then return {top = math.ceil(20 / zoom_cell.h), bottom = 1, left = 1, right = 1} end
    if custom_insets then return {top = 3, bottom = 1, left = 2, right = 1} end
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
chrome.FOLDER = "Программы"

-- Один кусок на заголовок каждого окна и один на панель задач — так же, как
-- будет у настоящей: резать по строкам, чтобы набор текста в окне не
-- переотправлял весь хром.
function chrome.paint(state: any, cell_w, cell_h)
    if zoom_cell then
        assert(cell_w == zoom_cell.w and cell_h == zoom_cell.h,
            "paint received stale cell dimensions after font zoom")
    end
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

    if chrome.clock_entry then
        slots[#slots + 1] = {row = state.height, from = 73, to = 80, entry = chrome.clock_entry}
    end

    -- Меню рисуется, только когда композитор говорит, что оно открыто: его
    -- состояние держит механика, а тема лишь показывает.
    if state.menu then
        local items: any = state.menu.items or {}
        local open: any = state.menu.open or {}
        local at = math.tointeger(state.menu.cursor) or 1
        placements[#placements + 1] = {
            id = "menu", x = 2, y = chrome.MENU_ROW,
            cols = 30, rows = math.max(1, #items + 1),
        }

        if type(state.menu.anchor) == "table" then
            -- Контекстное меню значка: плоский список у якоря, без папки.
            placements[#placements].x = math.tointeger(state.menu.anchor.x) or 2
            placements[#placements].y = math.tointeger(state.menu.anchor.y) or chrome.MENU_ROW
            for index in ipairs(items) do
                choices[#choices + 1] = {
                    row = chrome.MENU_ROW + index - 1, from = 2, to = 31, index = index,
                    level = 1, slot = index, cursor = at == index,
                }
            end
        elseif #open == 0 then
            -- Корневая панель: сначала ПАПКА, потом программы. Папка несёт
            -- путь целиком — композитор дерева не помнит и раскрывает то, что
            -- ему дали.
            choices[#choices + 1] = {
                row = chrome.MENU_ROW, from = 2, to = 31,
                open = {chrome.FOLDER}, level = 1, slot = 1, cursor = at == 1,
            }
            for index in ipairs(items) do
                choices[#choices + 1] = {
                    row = chrome.MENU_ROW + index, from = 2, to = 31, index = index,
                    level = 1, slot = index + 1, cursor = at == index + 1,
                }
            end
        else
            -- Раскрытая папка — вторая панель: курсор ходит по ней, потому что
            -- её `level` больше. Корневая панель при этом НЕ исчезает — как
            -- у настоящей темы: её строки остаются попаданиями без курсора,
            -- и наведение на них закрывает подменю.
            choices[#choices + 1] = {
                row = chrome.MENU_ROW, from = 2, to = 31,
                open = {chrome.FOLDER}, level = 1, slot = 1,
            }
            for index in ipairs(items) do
                choices[#choices + 1] = {
                    row = chrome.MENU_ROW + index, from = 2, to = 31, index = index,
                    level = 1, slot = index + 1,
                }
            end
            for index in ipairs(items) do
                choices[#choices + 1] = {
                    row = chrome.MENU_ROW + index - 1, from = 34, to = 63, index = index,
                    level = 2, slot = index, cursor = at == index,
                }
            end
        end
    end

    -- Two cell rows per target, but one keyboard choice per item.
    for _, hit in ipairs(slots) do
        hit.row = state.height - 1
        hit.bottom_row = state.height
    end
    for _, hit in ipairs(choices) do
        hit.row = chrome.MENU_ROW + (hit.row - chrome.MENU_ROW) * 2
        hit.bottom_row = hit.row + 1
    end

    return {
        placements = placements,
        hits = {desktop = {}, bars = slots, menu = choices},
    }
end

return chrome
