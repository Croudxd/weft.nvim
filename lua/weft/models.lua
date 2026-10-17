local M = {}
local url = "https://raw.githubusercontent.com/openai/codex/main/codex-rs/models-manager/models.json"
local bundled = {
  "gpt-6-astra",
  "gpt-6.1-sol",
  "gpt-6-sol",
  "gpt-6-luna",
  "gpt-5.6-sol",
  "gpt-5.6-terra",
  "gpt-5.6-luna",
  "gpt-5.5",
}

local function cache_path()
  return require("weft").config.state_dir .. "/models.json"
end

function M.parse(data)
  assert(type(data) == "table" and type(data.models) == "table", "Invalid model catalogue")
  local names, seen = {}, {}
  for _, model in ipairs(data.models) do
    if
      type(model.slug) == "string"
      and model.slug:match("^[%w._-]+$")
      and model.visibility == "list"
      and not seen[model.slug]
    then
      seen[model.slug] = true
      table.insert(names, model.slug)
    end
  end
  assert(#names > 0, "Empty model catalogue")
  table.sort(names)
  return names
end

function M.names()
  if not M.catalogue then
    local loaded, data = pcall(require("weft.util").load_json, cache_path())
    local ok, names = pcall(M.parse, loaded and data or nil)
    M.catalogue = ok and names or vim.deepcopy(bundled)
  end
  return vim.deepcopy(M.catalogue)
end

function M.refresh(callback)
  vim.system(
    { "curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "15", url },
    { text = true },
    function(result)
      vim.schedule(function()
        local ok, data = pcall(vim.json.decode, result.stdout or "")
        local valid, names = pcall(M.parse, ok and data or nil)
        if result.code ~= 0 or not valid then
          require("weft.util").notify("Could not refresh models; using saved catalogue", vim.log.levels.WARN)
        else
          M.catalogue = names
          require("weft.util").save_json(cache_path(), data)
        end
        if callback then
          callback()
        end
      end)
    end
  )
end

return M
