-- Окно-заглушка: сообщает, к какому композитору оно обращается.
--
-- Настоящее окно рисует себя и зовёт desktop.open; здесь нужна только та его
-- половина, которую нельзя проверить формой реестра — имя композитора,
-- пришедшее (или не пришедшее) при запуске.
local process = require("process")
local desktop = require("desktop")

local function main(reply_to)
    local name, source = desktop.service()
    -- Голым `return process.send(...)` это писать нельзя: хвостовой вызов
    -- yield-функции в go-lua v1.5.18 не выполняется вовсе.
    local sent, serr = process.send(tostring(reply_to), "probe.service",
        {name = name, source = source})
    return sent, serr
end

return {main = main}
