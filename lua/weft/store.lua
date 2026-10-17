local util = require("weft.util")
local M = { tasks = {}, repositories = {} }

function M.setup(options)
  M.directory = options.state_dir
  vim.fn.mkdir(M.directory, "p")
  local saved = util.load_json(M.directory .. "/state.json", { tasks = {}, repositories = {} })
  M.tasks = saved.tasks
  M.repositories = vim.tbl_extend("force", saved.repositories, options.repositories)
end

function M.save()
  util.save_json(
    M.directory .. "/state.json",
    { version = 1, tasks = M.tasks, repositories = M.repositories }
  )
end

function M.task_directory(task)
  return M.directory .. "/tasks/" .. task.id
end

function M.owner(path)
  if path == "" or path:match("^%w+://") then
    return nil
  end
  path = util.path(path)
  local owner
  -- Task roots can be nested by a user's chosen names/storage layout. Always
  -- use the most-specific match instead of Lua table iteration order.
  for _, task in pairs(M.tasks) do
    if util.inside(path, task.root) and (not owner or #task.root > #owner.root) then
      owner = task
    end
  end
  return owner
end

function M.repository(task, path)
  local found
  for _, repository in ipairs(task.repositories) do
    if util.inside(path, repository.path) and (not found or #repository.path > #found.path) then
      found = repository
    end
  end
  return found
end

return M
