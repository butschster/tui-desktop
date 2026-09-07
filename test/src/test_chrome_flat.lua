-- Та же растровая тема, но отдающая попадания ПЛОСКИМ списком.
--
-- Ровно та ошибка, которую спецификация допускает прочитать: «hits — как
-- сейчас». «Как сейчас» — это три разных списка от трёх вызовов, и `id` в них
-- значит разное. Тема существует затем, чтобы проверить, что механика такой
-- список не угадывает, а называет причину там, где её увидит человек.
local base = require("pixel_chrome")

local chrome = {}
for key, value in pairs(base) do chrome[key] = value end

function chrome.paint(state: any, cell_w, cell_h)
    local painted: any = base.paint(state, cell_w, cell_h)
    local flat = {}
    for _, hit in ipairs(painted.hits.bars) do flat[#flat + 1] = hit end
    return {placements = painted.placements, hits = flat}
end

return chrome
