-- Окно, которое просто есть.
--
-- Ни кадра, ни ввода: проверяется родство окон, а не рисование. `tty.start()`
-- не зовётся намеренно — такое окно композитор гасит сразу, без вежливого
-- срока, и закрытие в тесте не приходится ждать три секунды.
local channel = require("channel")
local time = require("time")

local function main()
    while true do
        local picked = channel.select({time.after("30s"):case_receive()})
        if not picked.ok then break end
    end
end

return {main = main}
