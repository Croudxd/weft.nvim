local util = require("weft.util")
local store = require("weft.store")
local M = {}

function M.claim(buffer)
  local task = store.owner(vim.api.nvim_buf_get_name(buffer))
  if task then
    vim.b[buffer].weft_task = task.id
    if not vim.b[buffer].weft_mapped then
      vim.b[buffer].weft_mapped = true
      for key, direction in pairs({ ["<S-l>"] = 1, ["<S-h>"] = -1 }) do
        vim.keymap.set("n", key, function()
          M.cycle(task, direction)
        end, { buffer = buffer, desc = "Weft: cycle task source buffers" })
      end
    end
  end
  return task
end

function M.enter(buffer)
  local task = M.claim(buffer)
  local current = require("weft.workspace").current()
  if not task or not current then
    return
  end
  if task.id == current.id then
    vim.t.weft_source = buffer
    return
  end
  local win = vim.api.nvim_get_current_win()
  local tab = vim.api.nvim_get_current_tabpage()
  local previous = vim.t.weft_source
  vim.schedule(function()
    if
      vim.api.nvim_get_current_tabpage() ~= tab
      or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= buffer
    then
      return
    end
    if previous and vim.api.nvim_buf_is_valid(previous) then
      vim.api.nvim_win_set_buf(win, previous)
    else
      require("weft.ui").home(current)
    end
    require("weft.workspace").switch(task)
    require("weft.ui").source(task, buffer)
  end)
end

function M.list(task)
  local result = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].buftype == "" then
      M.claim(buffer)
      if vim.b[buffer].weft_task == task.id then
        table.insert(result, buffer)
      end
    end
  end
  table.sort(result, function(a, b)
    return vim.api.nvim_buf_get_name(a) < vim.api.nvim_buf_get_name(b)
  end)
  return result
end

function M.load(task, path)
  assert(util.inside(util.path(path), task.root), "File is outside this task")
  local buffer = vim.fn.bufadd(path)
  vim.fn.bufload(buffer)
  vim.bo[buffer].buflisted = true
  vim.bo[buffer].bufhidden = "hide"
  vim.b[buffer].weft_task = task.id
  return buffer
end

function M.pick(task)
  require("weft").select(M.list(task), {
    prompt = "Weft · " .. task.name .. " · buffers",
    format_item = function(buffer)
      return (vim.bo[buffer].modified and "● " or "  ")
        .. vim.api.nvim_buf_get_name(buffer):sub(#task.root + 2)
    end,
  }, function(buffer)
    if buffer then
      require("weft.ui").source(task, buffer)
    end
  end)
end

function M.cycle(task, direction)
  local buffers = M.list(task)
  if #buffers == 0 then
    return util.notify("No source buffers in this task yet")
  end
  local index = 0
  for i, buffer in ipairs(buffers) do
    if buffer == vim.api.nvim_get_current_buf() then
      index = i
    end
  end
  require("weft.ui").source(task, buffers[(index - 1 + direction) % #buffers + 1])
end

return M
