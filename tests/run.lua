vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.hidden = true
vim.o.swapfile = false
local util = require("weft.util")
local sandbox = vim.fn.stdpath("cache") .. "/weft-tests/" .. vim.uv.hrtime()
local passed = 0
vim.fn.mkdir(sandbox, "p")

local function equal(actual, expected)
  assert(
    vim.deep_equal(actual, expected),
    "Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end

local function rejects(callback, pattern)
  local ok, message = pcall(callback)
  assert(
    not ok and tostring(message):find(pattern, 1, true),
    "Expected error containing " .. pattern .. ", got " .. tostring(message)
  )
end

local function test(name, callback)
  local ok, message = xpcall(callback, debug.traceback)
  if not ok then
    error(name .. "\n" .. message)
  end
  passed = passed + 1
  print("PASS " .. name)
end

local function repository(name)
  local path = sandbox .. "/originals/" .. name
  vim.fn.mkdir(path, "p")
  util.git(path, { "init", "-b", "main" })
  util.git(path, { "config", "user.name", "Weft Test" })
  util.git(path, { "config", "user.email", "weft@example.invalid" })
  util.write(path .. "/source.lua", "local value = 1\nreturn value\n")
  util.write(path .. "/.gitignore", "ignored.txt\n")
  util.git(path, { "add", "." })
  util.git(path, { "commit", "-m", "Initial" })
  return path
end

local function create(name)
  local done, task, failure
  require("weft.workspace").create(name, require("weft").config, function(result, message)
    task, failure, done = result, message, true
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 10),
    "Timed out creating task"
  )
  assert(task, failure)
  return task
end

local function scan(task)
  assert(vim.wait(10000, function()
    return not require("weft.changes").state(task).scanning
  end, 10))
  local done = false
  require("weft.changes").scan(task, function()
    done = true
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 10),
    "Timed out scanning task"
  )
end

local function run()
  local first = repository("app")
  local second = repository("engine")
  util.write(first .. "/source.lua", "unfinished original work\n")
  require("weft").setup({
    state_dir = sandbox .. "/state",
    worktree_root = sandbox .. "/worktrees",
    repositories = { app = first, engine = second },
    poll_interval = 0,
    mappings = false,
  })
  local task_a, task_b
  test("two tasks isolate every repository and leave original dirty work alone", function()
    task_a, task_b = create("task-a"), create("task-b")
    equal(util.read(task_a.root .. "/app/source.lua"), "local value = 1\nreturn value\n")
    equal(util.read(first .. "/source.lua"), "unfinished original work\n")
    equal(#task_a.repositories, 2)
    assert(vim.uv.fs_stat(task_a.root .. "/engine/.git"))
    equal(vim.trim(util.git(first, { "branch", "--show-current" })), "main")
  end)
  local files = require("weft.files")
  local changes = require("weft.changes")
  local path_a = task_a.root .. "/app/source.lua"
  local path_b = task_b.root .. "/app/source.lua"
  test("agent writes open unseen files without changing focus or other tasks", function()
    local current = vim.api.nvim_get_current_buf()
    files.write(
      task_a,
      {
        action = "write",
        path = "app/source.lua",
        expected_hash = vim.fn.sha256(util.read(path_a)),
        content = "local value = 2\nreturn value\n",
      }
    )
    equal(vim.api.nvim_get_current_buf(), current)
    assert(vim.api.nvim_buf_is_loaded(vim.fn.bufnr(path_a)))
    equal(vim.b[vim.fn.bufnr(path_a)].weft_task, task_a.id)
    equal(util.read(path_b), "local value = 1\nreturn value\n")
    equal(#changes.list(task_a), 1)
    equal(changes.list(task_a)[1].before, "local value = 1\nreturn value\n")
  end)
  test("buffers opened outside Weft are owned by their path and scoped to their task", function()
    vim.cmd("edit " .. vim.fn.fnameescape(path_b))
    equal(vim.b.weft_task, task_b.id)
    local list = require("weft.buffers").list(task_b)
    equal(#list, 1)
    equal(vim.api.nvim_buf_get_name(list[1]), path_b)
  end)
  test("edits preserve unsaved user text and reject stale AI reads", function()
    local buffer = vim.fn.bufnr(path_a)
    local read = files.read(task_a, "app/source.lua")
    vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "local value = 20 -- my edit" })
    rejects(function()
      files.write(
        task_a,
        {
          action = "write",
          path = "app/source.lua",
          expected_hash = vim.fn.sha256(read),
          content = "lost user work\n",
        }
      )
    end, "File changed since it was read")
    local current = files.read(task_a, "app/source.lua")
    local result = files.write(
      task_a,
      {
        action = "replace",
        path = "app/source.lua",
        expected_hash = vim.fn.sha256(current),
        old_text = "return value",
        content = "return value * 2",
      }
    )
    assert(result.unsaved)
    equal(util.read(path_a), "local value = 2\nreturn value\n")
    equal(util.buffer_text(buffer), "local value = 20 -- my edit\nreturn value * 2\n")
    equal(changes.state(task_a).entries[path_a].authorship, { "user", "ai" })
    rejects(function()
      files.write(task_a, { action = "delete", path = "app/source.lua", expected_hash = result.hash })
    end, "unsaved edits")
  end)
  test("external commands discover and load unseen files across repositories", function()
    util.write(task_a.root .. "/engine/added.lua", "return 'new'\n")
    util.write(task_a.root .. "/engine/source.lua", "return 'external'\n")
    scan(task_a)
    equal(#changes.list(task_a), 3)
    assert(vim.api.nvim_buf_is_loaded(vim.fn.bufnr(task_a.root .. "/engine/added.lua")))
    assert(vim.api.nvim_buf_is_loaded(vim.fn.bufnr(task_a.root .. "/engine/source.lua")))
  end)
  test("task baselines survive follow-up edits and Git commits", function()
    local path = task_a.root .. "/engine/source.lua"
    util.git(task_a.root .. "/engine", { "add", "." })
    util.git(task_a.root .. "/engine", { "commit", "-m", "Task progress" })
    local before = files.read(task_a, "engine/source.lua")
    files.write(
      task_a,
      {
        action = "write",
        path = "engine/source.lua",
        expected_hash = vim.fn.sha256(before),
        content = "return 'follow-up'\n",
      }
    )
    scan(task_a)
    equal(changes.state(task_a).entries[path].before, "local value = 1\nreturn value\n")
    assert(#changes.state(task_a).history >= 3)
  end)
  test("ignored files explicitly edited by the AI are included in change tracking", function()
    files.write(
      task_a,
      {
        action = "write",
        path = "engine/ignored.txt",
        expected_hash = "missing",
        content = "tracked by Weft\n",
      }
    )
    scan(task_a)
    assert(changes.state(task_a).entries[task_a.root .. "/engine/ignored.txt"].changed)
    assert(vim.api.nvim_buf_is_loaded(vim.fn.bufnr(task_a.root .. "/engine/ignored.txt")))
  end)
  test("deleted files retain original text without opening a fake empty source buffer", function()
    local before = files.read(task_b, "engine/source.lua")
    files.write(
      task_b,
      { action = "delete", path = "engine/source.lua", expected_hash = vim.fn.sha256(before) }
    )
    scan(task_b)
    local entry = changes.list(task_b)[1]
    assert(entry.deleted)
    equal(entry.before, before)
    equal(vim.fn.bufnr(task_b.root .. "/engine/source.lua"), -1)
  end)
  test("external disk edits cannot overwrite a dirty buffer", function()
    local buffer = vim.fn.bufnr(path_a)
    local before = util.buffer_text(buffer)
    util.write(path_a, "external writer\n")
    scan(task_a)
    equal(util.buffer_text(buffer), before)
    assert(changes.state(task_a).entries[path_a].disk_conflict)
    rejects(function()
      files.read(task_a, "app/source.lua")
    end, "Disk changed underneath")
  end)
  test("clean stale buffers cannot overwrite newer disk contents", function()
    local before = files.read(task_b, "app/source.lua")
    util.write(path_b, "new disk contents\n")
    rejects(function()
      files.write(
        task_b,
        {
          action = "write",
          path = "app/source.lua",
          expected_hash = vim.fn.sha256(before),
          content = "stale\n",
        }
      )
    end, "File changed since it was read")
    equal(util.read(path_b), "new disk contents\n")
  end)
  test("file tools reject path traversal, Git metadata, and escaping symlinks", function()
    assert(vim.uv.fs_symlink(first, task_a.root .. "/escape"))
    rejects(function()
      files.resolve(task_a, "../task-b/app/source.lua")
    end, "escapes")
    rejects(function()
      files.resolve(task_a, "escape/source.lua")
    end, "Symlink escapes")
    rejects(function()
      files.resolve(task_a, "app/.git")
    end, "Git metadata")
    equal(files.resolve(task_a, "."), task_a.root)
  end)
  test("source view leaves unrelated note buffers alone and shows line numbers", function()
    local notes = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(notes, sandbox .. "/notes.md")
    vim.api.nvim_win_set_buf(0, notes)
    require("weft.ui").source(task_a, vim.fn.bufnr(path_a))
    assert(vim.api.nvim_win_get_buf(0) ~= notes)
    equal(vim.api.nvim_win_get_buf(0), vim.fn.bufnr(path_a))
    assert(vim.wo.number)
    assert(not vim.wo.relativenumber)
    local note_found = false
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      note_found = note_found or buffer == notes
    end
    assert(note_found, "Weft replaced the note buffer")
  end)
  test("switching tasks preserves dirty buffers and independent tab-local roots", function()
    local workspace = require("weft.workspace")
    workspace.switch(task_a)
    local tab_a = vim.api.nvim_get_current_tabpage()
    require("weft.ui").source(task_a, vim.fn.bufnr(path_a))
    workspace.switch(task_b)
    equal(vim.fn.getcwd(), task_b.root)
    workspace.switch(task_a)
    equal(vim.api.nvim_get_current_tabpage(), tab_a)
    equal(vim.fn.getcwd(), task_a.root)
    assert(vim.bo[vim.fn.bufnr(path_a)].modified)
  end)
  test("task and snapshot persistence lives outside the source repositories", function()
    changes.save(task_a)
    changes.states = {}
    equal(changes.state(task_a).entries[path_a].before, "local value = 1\nreturn value\n")
    local saved = util.load_json(sandbox .. "/state/state.json")
    equal(saved.tasks[task_a.id].root, task_a.root)
    assert(not vim.uv.fs_stat(task_a.root .. "/chat.md"))
  end)
end

local ok, message = xpcall(run, debug.traceback)
vim.fn.delete(sandbox, "rf")
if not ok then
  io.stderr:write(message .. "\n")
  vim.cmd("cquit 1")
else
  print(string.format("\n%d integration tests passed", passed))
  vim.cmd("qa!")
end
