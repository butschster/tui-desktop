-- POST /tui-desktop/apps — собрать окно в работающем рантайме и сохранить его.
--
-- Запись процесса собирается и применяется через changes API реестра, поэтому
-- окно появляется в меню десктопа сразу: ни файла на диске, ни перезапуска.
-- Исходник при этом ложится в таблицу, и загрузчик поднимет окно обратно
-- после рестарта.
--
-- Порядок здесь важен: сперва строка, потом реестр. Если применение не
-- удалось, строка убирается — иначе хранилище копило бы окна, которые никогда
-- не поднимутся, и каждый старт молча жаловался бы на них.

local http = require("http")
local json = require("json")
local security = require("security")
local repo = require("repo")
local apps = require("apps")

local function bad(res, message)
    res:set_status(http.STATUS.BAD_REQUEST)
    res:write_json({success = false, error = message})
end

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then return nil, "no http context" end
    res:set_content_type(http.CONTENT.JSON)

    if not security.actor() then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({success = false, error = "authentication required"})
        return
    end

    local body = json.decode(req:body() or "") or {}
    if type(body) ~= "table" then body = {} end

    local name = type(body.name) == "string" and body.name or ""
    if not name:match("^[a-z][a-z0-9_]*$") then
        return bad(res, "name: строчные латинские буквы, цифры и подчёркивание, начиная с буквы")
    end

    local source = type(body.source) == "string" and body.source or ""
    if source == "" then
        return bad(res, "source: код окна обязателен")
    end
    -- Процесс запускается методом main. Запись без него применится молча и
    -- умрёт при первом открытии, уже без объяснения причины.
    if not source:find("main", 1, true) then
        return bad(res, "source: код обязан возвращать таблицу с функцией main")
    end

    local refused = apps.rejected_modules(body.modules)
    if #refused > 0 then
        return bad(res, "modules: недоступны — " .. table.concat(refused, ", "))
    end

    local window = {
        name = name,
        title = type(body.title) == "string" and body.title ~= "" and body.title or name,
        width = tonumber(body.width) or 40,
        height = tonumber(body.height) or 12,
        source = source,
        modules = apps.normalize_modules(body.modules),
    }

    local existing = repo.get(name)

    local _, serr = repo.save(window)
    if serr then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "сохранение: " .. tostring(serr)})
        return
    end

    local ok, aerr = apps.apply(window)
    if not ok then
        repo.delete(name)
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = aerr})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        entry = apps.entry_id(name),
        name = name,
        title = window.title,
        modules = window.modules,
        replaced = existing ~= nil,
    })
end

return {handler = handler}
