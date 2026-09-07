-- Композитор целиком, поднятый в тесте.
--
-- Экран у него настоящий, только не терминал, а viewport, выданный тестом:
-- поэтому проверка родства окон идёт через живой композитор, а не через форму
-- реестра. Имя приезжает аргументом, чтобы прогоны не спорили за одно.
local library = require("library")
local chrome = require("chrome")

local function main(service)
    local ok, err = library.run({
        chrome = chrome,
        service_name = tostring(service),
        restore = false,
    })
    return ok, err
end

return {main = main}
