local util = require("weft.util")
local store = require("weft.store")
local workspace = require("weft.workspace")
local M = {}

local defaults = {
  worktree_root = "~/dev/worktrees",
  state_dir = vim.fn.stdpath("data") .. "/weft",
  repositories = {},
  branch_prefix = "weft/",
  poll_interval = 2000,
  max_file_bytes = 1024 * 1024,
  command_timeout = 120000,
  model = "gpt-5.3-codex",
  mappings = true,
  open_changed_files = false,
}

local function current()
  local task = assert(workspace.current(), "Choose a Weft task first: :Weft tasks")
  return task
end

function M.new(name)
  if not name or name == "" then
    return vim.ui.input(
      { prompt = "New Weft task: " },
      util.guard(function(value)
        if value and value ~= "" then
          M.new(value)
        end
      end)
    )
  end
  workspace.create(name, M.config, function(task, error_message)
    if not task then
      return util.notify(error_message, vim.log.levels.ERROR)
    end
    workspace.switch(task)
    require("weft.changes").scan(task)
    util.notify("Created task " .. task.name .. " · " .. #task.repositories .. " repositories")
    util.guard(M.open)(task)
  end)
end

function M.select(items, options, callback)
  if M.config.picker then
    return M.config.picker(items, options, callback)
  end
  local ok = pcall(require, "telescope")
  if not ok then
    return vim.ui.select(items, options, callback)
  end
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local config = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  return pickers
    .new({}, {
      prompt_title = options.prompt or "Weft",
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          local display = options.format_item and options.format_item(item) or tostring(item)
          return { value = item, display = display, ordinal = display }
        end,
      }),
      sorter = config.generic_sorter({}),
      attach_mappings = function(prompt_buffer)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_buffer)
          callback(selection and selection.value)
        end)
        return true
      end,
    })
    :find()
end

function M.tasks(on_selected)
  local tasks = vim.tbl_values(store.tasks)
  table.sort(tasks, function(a, b)
    return a.name < b.name
  end)
  if #tasks == 0 then
    return util.notify("No tasks yet. Add repos with :Weft repo add <path>, then :Weft new <name>")
  end
  M.select(
    tasks,
    {
      prompt = "Weft tasks",
      format_item = function(task)
        return task.name .. " · " .. (require("weft.agent").status[task.id] or "idle")
      end,
    },
    util.guard(function(task)
      if task then
        workspace.switch(task)
        if on_selected then
          on_selected(task)
        else
          M.open(task)
        end
      end
    end)
  )
end

function M.open(task)
  task = task or workspace.current()
  if not task then
    return M.tasks(function(selected)
      M.open(selected)
    end)
  end
  M.config.load_chat()
  require("weft.ui").open(task)
end

-- The command centre is deliberately optional-Telescope: Weft should remain
-- usable with a configured vim.ui.select implementation, while Telescope users
-- get a proper searchable picker instead of a scratch-buffer landing page.
function M.menu()
  local task = workspace.current()
  local actions = {}
  local function add(label, description, callback)
    table.insert(actions, { label = label, description = description, callback = callback })
  end

  if task then
    add("Open workspace", "Chat, changes, and source files for " .. task.name, function()
      M.open(task)
    end)
    add("Open chat", "Talk to the agent for " .. task.name, function()
      M.config.load_chat()
      require("weft.agent").toggle(task, { open = true })
    end)
    add("Review changes", "Browse files changed in " .. task.name, function()
      require("weft.ui").changes(task, { open = true })
    end)
    add("Task buffers", "Switch between source buffers", function()
      require("weft.buffers").pick(task)
    end)
    add("Browse workspace", "Open the task root in your file browser", function()
      M.browse()
    end)
    add("Choose model", "Change the model for this task", function()
      M.config.load_chat()
      require("weft.agent").pick_model(task)
    end)
  end
  add("Switch task", "Choose another Weft task", function()
    M.tasks()
  end)
  add("New task", "Create an isolated worktree and agent", function()
    M.new()
  end)

  local function select(action)
    if action then
      action.callback()
    end
  end
  return M.select(actions, {
    prompt = task and "Weft · " .. task.name or "Weft",
    format_item = function(action)
      return action.label .. "  " .. action.description
    end,
  }, select)
end

function M.browse()
  local task = current()
  if M.config.browser then
    return M.config.browser(task.root)
  end
  local ok, yazi = pcall(require, "yazi")
  if ok then
    return yazi.yazi(nil, task.root)
  end
  vim.cmd("edit " .. vim.fn.fnameescape(task.root))
end

function M.hide()
  local task = current()
  local buffer = vim.api.nvim_get_current_buf()
  local kind = vim.b[buffer].weft_view
  if kind == "chat" then
    return require("weft.agent").toggle(task)
  end
  if kind then
    return require("weft.ui").hide(task, kind)
  end
  assert(vim.b[buffer].weft_task == task.id, "Current buffer does not belong to this task")
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(0, true)
  else
    require("weft.ui").home(task)
  end
end

M.bindings = {
  {
    "<leader>wm",
    function()
      M.config.load_chat()
      require("weft.agent").pick_model(current())
    end,
    "Pick task model",
  },
  {
    "<leader>ww",
    function()
      M.tasks()
    end,
    "Pick task / open workspace",
  },
  {
    "<leader>wW",
    function()
      M.menu()
    end,
    "Open Weft command centre",
  },
  {
    "<leader>wa",
    function()
      M.tasks()
    end,
    "Pick task / agent",
  },
  {
    "<leader>wn",
    function()
      M.new()
    end,
    "New task / agent",
  },
  {
    "<leader>wc",
    function()
      require("weft.agent").toggle(current())
    end,
    "Toggle task chat",
  },
  {
    "<leader>wl",
    function()
      require("weft.ui").changes(current())
    end,
    "Toggle task changes",
  },
  {
    "<leader>wb",
    function()
      require("weft.buffers").pick(current())
    end,
    "Pick task source buffer",
  },
  {
    "<leader>wo",
    function()
      require("weft.ui").before(current())
    end,
    "Toggle previous code",
  },
  {
    "<leader>we",
    function()
      M.browse()
    end,
    "Browse task workspace",
  },
  {
    "<leader>ws",
    function()
      require("weft.agent").send(current())
    end,
    "Send task prompt",
  },
  {
    "<leader>wk",
    function()
      require("weft.agent").stop(current())
    end,
    "Stop task agent",
  },
  {
    "<leader>wi",
    function()
      require("weft.agent").attach(current())
    end,
    "Attach current task buffer",
  },
  {
    "<leader>wr",
    function()
      require("weft.changes").scan(current())
    end,
    "Refresh task changes",
  },
  {
    "<leader>wx",
    function()
      M.hide()
    end,
    "Hide current task view",
  },
  {
    "<leader>wp",
    function()
      local task = current()
      local location = require("weft.ui").last[task.id]
      if location then
        require("weft.ui").open_change(task, location.entry, location.index)
      end
    end,
    "Return to last inspected change",
  },
  {
    "<leader>w?",
    function()
      require("weft.ui").help(workspace.current() or { id = "global", name = "Weft" })
    end,
    "Toggle Weft shortcuts",
  },
  {
    "]a",
    function()
      require("weft.changes").jump(current(), 1)
    end,
    "Next task change",
  },
  {
    "[a",
    function()
      require("weft.changes").jump(current(), -1)
    end,
    "Previous task change",
  },
  {
    "]b",
    function()
      require("weft.buffers").cycle(current(), 1)
    end,
    "Next task source buffer",
  },
  {
    "[b",
    function()
      require("weft.buffers").cycle(current(), -1)
    end,
    "Previous task source buffer",
  },
}

local function highlights()
  vim.api.nvim_set_hl(0, "WeftAI", { default = true, bg = "#20352e" })
  vim.api.nvim_set_hl(0, "WeftEdited", { default = true, bg = "#302f40" })
  vim.api.nvim_set_hl(0, "WeftRemoved", { default = true, link = "DiagnosticWarn" })
end

local function command(args)
  local action = args.fargs[1] or "tasks"
  if action == "new" then
    return M.new(args.fargs[2])
  end
  if action == "tasks" then
    return M.tasks()
  end
  if action == "repo" then
    if args.fargs[2] == "add" then
      local path = table.concat(vim.list_slice(args.fargs, 3), " ")
      assert(path ~= "", "Usage: :Weft repo add /path/to/repository")
      local name = workspace.add_repository(path)
      return util.notify("Registered " .. name .. " for new tasks")
    elseif args.fargs[2] == "remove" then
      local name = args.fargs[3]
      assert(name and store.repositories[name], "Specify a registered repository name")
      store.repositories[name] = nil
      store.save()
      return util.notify("Removed " .. name .. " from future tasks")
    end
    return util.notify(vim.inspect(store.repositories))
  end
  local actions = {
    model = function()
      M.config.load_chat()
      local model = args.fargs[2]
      if model == "refresh" then
        local task = current()
        return require("weft.models").refresh(function()
          require("weft.agent").pick_model(task)
        end)
      end
      if not model then
        return require("weft.agent").pick_model(current())
      end
      require("weft.agent").set_model(current(), model == "default" and M.config.model or model)
    end,
    open = M.open,
    chat = function()
      require("weft.agent").toggle(current())
    end,
    changes = function()
      require("weft.ui").changes(current())
    end,
    buffers = function()
      require("weft.buffers").pick(current())
    end,
    before = function()
      require("weft.ui").before(current())
    end,
    refresh = function()
      require("weft.changes").scan(current())
    end,
    browse = M.browse,
    send = function()
      require("weft.agent").send(current())
    end,
    stop = function()
      require("weft.agent").stop(current())
    end,
    hide = M.hide,
    help = function()
      require("weft.ui").help(workspace.current() or { id = "global", name = "Weft" })
    end,
    auth = function()
      M.config.load_chat()
      require("weft.agent").codex_adapter()
      vim.cmd("CodeCompanionCodexAuth")
    end,
  }
  assert(actions[action], "Unknown Weft action: " .. action)
  if action == "chat" or action == "send" then
    M.config.load_chat()
  end
  return actions[action]()
end

function M.complete(lead, line, cursor)
  local before = line:sub(1, cursor)
  local model = before:match("^%s*:?Weft%s+model%s+(.*)$")
  local choices
  if model and not model:find("%s") then
    M.config.load_chat()
    choices = require("weft.agent").model_names()
    table.insert(choices, "default")
    table.insert(choices, "refresh")
  elseif before:match("^%s*:?Weft%s+[^%s]*$") then
    choices = {
      "open",
      "new",
      "tasks",
      "repo",
      "chat",
      "changes",
      "buffers",
      "before",
      "refresh",
      "browse",
      "send",
      "stop",
      "hide",
      "help",
      "auth",
      "model",
    }
  else
    return {}
  end
  return vim.tbl_filter(function(choice)
    return choice:sub(1, #lead) == lead
  end, choices)
end

function M.setup(options)
  if M.timer then
    M.timer:stop()
    M.timer:close()
  end
  M.config = vim.tbl_deep_extend("force", defaults, options or {})
  M.config.worktree_root = util.path(M.config.worktree_root)
  M.config.state_dir = util.path(M.config.state_dir)
  M.config.load_chat = M.config.load_chat or function()
    require("codecompanion")
  end
  store.setup(M.config)
  local group = vim.api.nvim_create_augroup("Weft", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(event)
      require("weft.buffers").claim(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(event)
      require("weft.buffers").enter(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, task in pairs(store.tasks) do
        require("weft.agent").save(task)
        require("weft.changes").save(task)
      end
    end,
  })
  highlights()
  if M.config.mappings then
    for _, binding in ipairs(M.bindings) do
      vim.keymap.set("n", binding[1], util.guard(binding[2]), { desc = "Weft: " .. binding[3] })
    end
  end
  vim.api.nvim_create_user_command("Weft", util.guard(command), {
    nargs = "*",
    complete = M.complete,
    desc = "Weft task workspaces and AI coding",
    force = true,
  })
  if M.config.poll_interval > 0 then
    M.timer = vim.uv.new_timer()
    M.timer:start(
      M.config.poll_interval,
      M.config.poll_interval,
      vim.schedule_wrap(function()
        for _, task in pairs(store.tasks) do
          if vim.uv.fs_stat(task.root) then
            require("weft.changes").scan(task)
          end
        end
      end)
    )
  end
end

return M
