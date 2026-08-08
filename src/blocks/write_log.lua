-- Function Block implementation. Receives exactly { input, config } and runs
-- the same persistence path the sink and HTTP API use.
local repo = require("repo")

local function execute(args)
    args = type(args) == "table" and args or {}
    local input = type(args.input) == "table" and args.input or {}
    local config = type(args.config) == "table" and args.config or {}

    local content = input.content
    if type(content) ~= "string" or content == "" then
        return nil, "content is required"
    end
    local label = input.label or config.default_label or "block"

    local id, err = repo.insert(label, content)
    if not id then return nil, tostring(err) end

    local count = repo.count() or 0
    return { entry_id = id, label = label, count = count }, nil
end

return { execute = execute }
