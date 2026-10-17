local util = require("weft.util")
local store = require("weft.store")
local M = { chats = {}, status = {} }

-- The upstream OAuth adapter still imports these helpers using their pre-v19 paths.
-- Resolve them only within the adapter's loader, without altering global require().
function M.codex_adapter()
  if not M.adapter then
    local path = vim.api.nvim_get_runtime_file("lua/codecompanion/adapters/http/codex/init.lua", false)[1]
    assert(path, "Install viespejo/cc-adapter-codex.nvim first")
    local loader = assert(loadfile(path))
    local aliases = {
      ["codecompanion.utils.adapters"] = "codecompanion.adapters.utils",
      ["codecompanion.utils.tool_transformers"] = "codecompanion.adapters.utils.tool_transformers",
    }
    setfenv(
      loader,
      setmetatable({
        require = function(name)
          return require(aliases[name] or name)
        end,
      }, { __index = _G })
    )
    M.adapter = loader()
    local signatures = {
      lifecycle = { on_exit = { "data" } },
      request = {
        build_parameters = { "params", "messages" },
        build_messages = { "messages" },
        build_tools = { "tools" },
        build_body = { "payload" },
      },
      response = { parse_chat = { "data", "tools" }, parse_tokens = { "data" } },
      tools = { format_calls = { "tools" }, format_response = { "tool_call", "output" } },
    }
    for category, handlers in pairs(signatures) do
      for name, keys in pairs(handlers) do
        local handler = M.adapter.handlers[category][name]
        if handler then
          M.adapter.handlers[category][name] = function(adapter, args)
            local positional = {}
            for i, key in ipairs(keys) do
              positional[i] = args[key]
            end
            return handler(adapter, unpack(positional, 1, #keys))
          end
        end
      end
    end
  end
  return require("codecompanion.adapters").extend(vim.deepcopy(M.adapter), {})
end

function M.codecompanion_options()
  return {
    adapters = { http = { weft_codex = M.codex_adapter } },
    interactions = {
      chat = {
        adapter = "weft_codex",
        tools = { weft_workspace = { path = "weft.tools", description = "Operate in this task's workspace" } },
        opts = { completion_provider = "default" },
        keymaps = {
          send = { modes = { n = "<C-s>", i = "<C-s>" } },
          close = false,
        },
      },
    },
    display = {
      chat = {
        show_settings = false,
        auto_scroll = false,
        window = { layout = "vertical", width = 0.35, pertab = true },
      },
    },
  }
end

function M.save(task)
  local chat = M.chats[task.id]
  if not chat or not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return
  end
  util.save_json(store.task_directory(task) .. "/chat.json", {
    messages = chat.messages,
    lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false),
    header_line = chat.header_line,
    last_role = chat._last_role,
    cycle = chat.cycle,
    context_items = chat.context_items,
  })
end

local function prompt(task)
  local repositories = {}
  for _, repository in ipairs(task.repositories) do
    table.insert(repositories, repository.name .. "/")
  end
  return table.concat({
    "You are Weft, an AI coding agent in Neovim. Implement the user's requested code changes using weft_workspace.",
    "This chat belongs permanently to task " .. task.name .. ". Its workspace is " .. task.root .. ".",
    "Repositories: " .. table.concat(repositories, ", ") .. ".",
    "Use only weft_workspace for file access and commands. Never use another task or the original checkout.",
    "Read files before editing and supply the returned expected_hash. Re-read if the version has changed.",
    "The user can edit buffers while you work. Keep their edits. Unsaved files are visible to read but not shell commands.",
    "Make changes directly with tools. Keep progress and final responses concise. Do not just output code suggestions.",
    "Do not commit, merge, switch branches, or remove worktrees unless explicitly requested.",
  }, "\n")
end

function M.get(task)
  local chat = M.chats[task.id]
  if chat and vim.api.nvim_buf_is_valid(chat.bufnr) then
    return chat
  end
  require("codecompanion")
  local saved = util.load_json(store.task_directory(task) .. "/chat.json", nil)
  chat = require("codecompanion.interactions.chat").new({
    adapter = "weft_codex",
    title = "Weft · " .. task.name,
    hidden = true,
    buffer_context = require("codecompanion.utils.context").get(),
    stop_context_insertion = true,
    messages = saved and vim.deepcopy(saved.messages) or nil,
    tools = { "weft_workspace" },
    callbacks = {
      on_before_submit = function(current)
        current:set_system_prompt(prompt(task))
        return true
      end,
      on_submitted = function()
        M.status[task.id] = "working"
      end,
      on_completed = function()
        if M.status[task.id] ~= "stopped" then
          M.status[task.id] = "ready"
        end
        M.save(task)
        require("weft.changes").scan(task)
      end,
      on_cancelled = function()
        M.status[task.id] = "stopped"
      end,
    },
  })
  assert(chat, "Cannot create chat; run :checkhealth codecompanion (Markdown parser is required)")
  M.chats[task.id] = chat
  vim.b[chat.bufnr].weft_task = task.id
  vim.b[chat.bufnr].weft_view = "chat"
  if saved then
    -- CodeCompanion's initial renderer removes the last message for prompt re-parsing.
    chat.messages = saved.messages
    chat.context_items = saved.context_items or chat.context_items
    chat.tools.messages = chat.messages
    vim.bo[chat.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, saved.lines)
    chat.header_line = saved.header_line
    chat._last_role = saved.last_role
    chat.cycle = saved.cycle
  end
  chat:set_system_prompt(prompt(task))
  vim.keymap.set("n", "q", function()
    M.toggle(task)
  end, { buffer = chat.bufnr, desc = "Hide task chat" })
  return chat
end

function M.toggle(task)
  local chat = M.get(task)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == chat.bufnr then
      M.save(task)
      if #vim.api.nvim_tabpage_list_wins(0) == 1 then
        require("weft.ui").home(task)
      else
        vim.api.nvim_win_close(win, true)
      end
      return
    end
  end
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, math.max(30, math.floor(vim.o.columns * 0.35)))
  chat.ui:show_in_win({ winnr = win })
end

function M.send(task)
  local chat = M.get(task)
  local found = false
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == chat.bufnr then
      found = true
    end
  end
  if not found then
    M.toggle(task)
  end
  chat:submit()
end

function M.stop(task)
  local chat = M.chats[task.id]
  if chat then
    chat:stop()
  end
end

function M.attach(task)
  local buffer = vim.api.nvim_get_current_buf()
  assert(
    vim.b[buffer].weft_task == task.id and vim.bo[buffer].buftype == "",
    "Choose a source buffer in this task"
  )
  local path = vim.api.nvim_buf_get_name(buffer)
  local chat = M.get(task)
  chat:add_context(
    { role = "user", content = path:sub(#task.root + 2) .. "\n" .. util.buffer_text(buffer) },
    {
      source = "weft",
      id = "weft-buffer-" .. buffer,
      bufnr = buffer,
    }
  )
  util.notify("Attached " .. path:sub(#task.root + 2) .. "; agent reads always use current buffer contents")
end

return M
