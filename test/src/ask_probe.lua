-- Окно, которое задаёт композитору вопрос и продолжает жить.
--
-- Два режима, и разница между ними — весь смысл проверки:
--   naive — ждать ответ, забирая всё из inbox (так делали до починки);
--   ask   — ждать ответ каналом топика, не трогая inbox.
--
-- Отчитывается тем, что дошло ПОСЛЕ ответа: команда, посланная композитором,
-- пока окно ждало, обязана дождаться цикла окна.
local process = require("process")
local channel = require("channel")
local time = require("time")
local desktop = require("desktop")

-- Что ещё лежит в inbox. Срок короткий: всё, что должно было дойти, уже
-- отправлено к этому моменту.
local function drain(inbox, budget)
    local got = {}
    while true do
        local expiry = time.after(budget)
        local picked = channel.select({inbox:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then break end
        got[#got + 1] = picked.value:topic()
    end
    return table.concat(got, ",")
end

local function main(mode)
    local inbox = process.inbox()
    local answered, eaten = "нет", {}

    if mode == "naive" then
        -- Ровно тот цикл, который здесь и чинится: чужое сообщение прочитано
        -- и выброшено, вернуть его некуда.
        local name = desktop.service()
        local pid = process.registry.lookup(name)
        process.send(pid, "desktop.list", {reply_to = tostring(process.pid())})

        local expiry = time.after("5s")
        while true do
            local picked = channel.select({inbox:case_receive(), expiry:case_receive()})
            if picked.channel == expiry or not picked.ok then break end
            local topic = picked.value:topic()
            if topic == desktop.REPLY_TOPIC then answered = "да" break end
            eaten[#eaten + 1] = topic
        end
    else
        local answer, err = desktop.ask("desktop.list", {})
        answered = answer and tostring(answer.marker) or ("ошибка: " .. tostring(err))
    end

    local sent, serr = process.send(tostring(desktop.service()), "probe.result", {
        answered = answered,
        eaten = table.concat(eaten, ","),
        handled = drain(inbox, "700ms"),
    })
    return sent, serr
end

return {main = main}
