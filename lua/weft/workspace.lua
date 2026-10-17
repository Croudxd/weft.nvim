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

local function validate(name, options)
  assert(name and name:match("^[a-zA-Z0-9][a-zA-Z0-9_-]*$"), "Use a task name like fix-login-timeout")
  assert(not store.tasks[name] and not M.creating[name], "Task already exists: " .. name)
  local root = options.worktree_root .. "/" .. name
  assert(not vim.uv.fs_stat(root), "Directory already exists: " .. root)
  local repositories = {}
  for repository_name, source in pairs(store.repositories) do
    source = util.path(source)
    assert(not util.inside(options.worktree_root, source), "Worktree storage must be outside " .. source)
    assert(not util.inside(source, options.worktree_root), "Register original repos, not task worktrees")
    local base = vim.trim(util.git(source, { "rev-parse", "HEAD" }))
    local branch = options.branch_prefix .. name
    local exists =
      vim.system({ "git", "-C", source, "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }):wait()
    assert(exists.code == 1, "Branch already exists or cannot be checked: " .. branch .. " in " .. source)
    -- Submodules need their own lifecycle before they can satisfy task isolation.
    assert(not util.read(source .. "/.gitmodules"), "Submodules are not supported yet: " .. source)
    table.insert(
      repositories,
      {
        name = repository_name,
        source = source,
        path = root .. "/" .. repository_name,
        base = base,
        branch = branch,
      }
    )
  end
  assert(#repositories > 0, "Add a repository first: :Weft repo add /path/to/repository")
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

function M.create(name, options, callback)
  local task = validate(name, options)
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
