local util = require("weft.util")
local store = require("weft.store")
local M = { creating = {} }

function M.add_repository(path, name)
  path = util.path(path)
  local root = util.path(vim.trim(util.git(path, { "rev-parse", "--show-toplevel" })))
  assert(root == path, "Choose the repository root: " .. root)
  name = name or vim.fs.basename(root)
  assert(name:match("^[%w][%w._-]*$"), "Repository names must be simple directory names")
  for existing_name, existing in pairs(store.repositories) do
    assert(existing_name == name or existing ~= path, "Repository already registered as " .. existing_name)
  end
  assert(not store.repositories[name] or store.repositories[name] == path, "Repository name already in use")
  store.repositories[name] = path
  store.save()
  return name
end

local function repository_task(name, root, repository_name, source, options)
  source = util.path(source)
  assert(not util.inside(options.worktree_root, source), "Worktree storage must be outside " .. source)
  assert(not util.inside(source, options.worktree_root), "Register original repos, not task worktrees")
  local base = vim.trim(util.git(source, { "rev-parse", "HEAD" }))
  local branch = options.branch_prefix .. name
  local exists = vim.system({ "git", "-C", source, "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }):wait()
  assert(exists.code == 1, "Branch already exists or cannot be checked: " .. branch .. " in " .. source)
  assert(not util.read(source .. "/.gitmodules"), "Submodules are not supported yet: " .. source)
  return { name = repository_name, source = source, path = root .. "/" .. repository_name, base = base, branch = branch }
end

local function validate(name, options, selected)
  assert(name and name:match("^[a-zA-Z0-9][a-zA-Z0-9_-]*$"), "Use a task name like fix-login-timeout")
  assert(not store.tasks[name] and not M.creating[name], "Task already exists: " .. name)
  local root = options.worktree_root .. "/" .. name
  assert(not vim.uv.fs_stat(root), "Directory already exists: " .. root)
  assert(type(selected) == "table" and #selected > 0, "Choose a repository for this task")
  local repositories = {}
  for _, repository_name in ipairs(selected) do
    local source = assert(store.repositories[repository_name], "Unknown repository: " .. repository_name)
    table.insert(repositories, repository_task(name, root, repository_name, source, options))
  end
  table.sort(repositories, function(a, b)
    return a.name < b.name
  end)
  return { id = name, name = name, root = root, repositories = repositories, created_at = os.time() }
end

local function rollback(task, created, message, callback)
  for _, repository in ipairs(created) do
    local ok = pcall(util.git, repository.source, { "worktree", "remove", repository.path })
    if ok then
      pcall(util.git, repository.source, { "branch", "-d", repository.branch })
    else
      message = message .. "\nPreserved partial worktree: " .. repository.path
    end
  end
  pcall(vim.uv.fs_rmdir, task.root)
  M.creating[task.id] = nil
  callback(nil, message)
end

function M.create(name, options, selected, callback)
  if type(selected) == "function" then
    callback, selected = selected, nil
  end
  selected = selected or vim.tbl_keys(store.repositories)
  local task = validate(name, options, selected)
  M.creating[name] = true
  vim.fn.mkdir(task.root, "p")
  local created = {}
  local function advance(index)
    local repository = task.repositories[index]
    if not repository then
      M.creating[name] = nil
      store.tasks[name] = task
      store.save()
      return callback(task)
    end
    vim.system(
      {
        "git",
        "-C",
        repository.source,
        "worktree",
        "add",
        "-b",
        repository.branch,
        repository.path,
        repository.base,
      },
      { text = true },
      vim.schedule_wrap(function(result)
        if result.code ~= 0 then
          return rollback(task, created, result.stderr, callback)
        end
        table.insert(created, repository)
        advance(index + 1)
      end)
    )
  end
  advance(1)
end

function M.add_to_task(task, repository_name, options, callback)
  assert(task and store.tasks[task.id], "Choose a Weft task first")
  local source = assert(store.repositories[repository_name], "Unknown repository: " .. repository_name)
  for _, repository in ipairs(task.repositories) do
    assert(repository.name ~= repository_name, "Repository is already in this task: " .. repository_name)
  end
  local repository = repository_task(task.name, task.root, repository_name, source, options)
  M.creating[task.id] = true
  vim.system(
    { "git", "-C", repository.source, "worktree", "add", "-b", repository.branch, repository.path, repository.base },
    { text = true },
    vim.schedule_wrap(function(result)
      M.creating[task.id] = nil
      if result.code ~= 0 then
        return callback(nil, result.stderr)
      end
      table.insert(task.repositories, repository)
      table.sort(task.repositories, function(a, b)
        return a.name < b.name
      end)
      store.save()
      callback(repository)
    end)
  )
end

function M.delete(task, callback)
  assert(task and store.tasks[task.id], "Choose a Weft task first")
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buffer].weft_task == task.id and vim.bo[buffer].modified then
      return callback(nil, "Save or discard unsaved task buffers before deleting the task")
    end
  end

  -- Preflight every repository before removing any worktree. This avoids a
  -- partially deleted task when one worktree contains ordinary uncommitted work.
  for _, repository in ipairs(task.repositories) do
    local status = vim.system({ "git", "-C", repository.path, "status", "--porcelain" }, { text = true }):wait()
    if status.code ~= 0 then
      return callback(nil, "Task worktree is missing or invalid: " .. repository.name)
    end
    if vim.trim(status.stdout) ~= "" then
      return callback(nil, "Commit, discard, or move changes in " .. repository.name .. " before deleting the task")
    end
  end

  local function remove(index)
    local repository = task.repositories[index]
    if not repository then
      store.tasks[task.id] = nil
      store.save()
      vim.fn.delete(store.task_directory(task), "rf")
      pcall(vim.uv.fs_rmdir, task.root)
      return callback(true)
    end
    vim.system(
      { "git", "-C", repository.source, "worktree", "remove", repository.path },
      { text = true },
      vim.schedule_wrap(function(result)
        if result.code ~= 0 then
          return callback(nil, "Could not remove " .. repository.name .. ": " .. result.stderr)
        end
        local branch = vim.system({ "git", "-C", repository.source, "branch", "-D", repository.branch }, { text = true }):wait()
        if branch.code ~= 0 then
          return callback(nil, "Removed worktree but could not remove branch " .. repository.branch .. ": " .. branch.stderr)
        end
        remove(index + 1)
      end)
    )
  end
  remove(1)
end

function M.current()
  local id = vim.t.weft_task
  return id and store.tasks[id] or nil
end

function M.switch(task)
  assert(vim.uv.fs_stat(task.root), "Task directory is missing: " .. task.root)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local ok, id = pcall(vim.api.nvim_tabpage_get_var, tab, "weft_task")
    if ok and id == task.id then
      vim.api.nvim_set_current_tabpage(tab)
      return task
    end
  end
  vim.cmd("tabnew")
  vim.t.weft_task = task.id
  vim.cmd("tcd " .. vim.fn.fnameescape(task.root))
  require("weft.ui").home(task)
  return task
end

return M
