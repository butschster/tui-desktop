-- Окно, которое открывает свой диалог.
--
-- Открывает ДВА окна: диалог и обычную программу. Второе — контроль: связь
-- обязана менять судьбу диалога и не трогать судьбу программы, иначе
-- «закрылось вместе с родителем» проверяет не связь, а то, что композитор
-- закрывает всё подряд.
local channel = require("channel")
local process = require("process")
local time = require("time")
local desktop = require("desktop")

local function main(watcher)
    local dialog, derr = desktop.dialog({entry = "app:idle_window", title = "Свойства", w = 20, h = 6})
    local plain, perr = desktop.open_wait({entry = "app:idle_window", title = "Просмотр", w = 20, h = 6})

    process.send(tostring(watcher), "probe.opened", {
        dialog = dialog and dialog.id or nil,
        dialog_error = derr and tostring(derr) or nil,
        plain = plain and plain.id or nil,
        plain_error = perr and tostring(perr) or nil,
    })

    -- Окно обязано жить: закрытое, оно унесло бы диалог само по себе, и
    -- проверка каскада ничего бы не значила.
    while true do
        local picked = channel.select({time.after("30s"):case_receive()})
        if not picked.ok then break end
    end
end

return {main = main}
