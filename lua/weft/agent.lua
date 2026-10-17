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
  local adapters = require("codecompanion.adapters")
  local definition = vim.deepcopy(M.adapter)
  for _, name in ipairs(require("weft.models").names()) do
    definition.schema.model.choices[name] = definition.schema.model.choices[name] or {}
  end
  definition.type = "http"
  local adapter = adapters.extend(definition, {})
  -- The upstream OAuth adapter has no context-window metadata. Supplying the
  -- documented Codex window lets CodeCompanion compact before prompts grow slow
  -- or hit the provider limit.
  for _, model in pairs(adapter.schema.model.choices) do
    model.meta = model.meta or { context_window = 272000 }
  end
  local config = require("weft").config
  return adapters.set_model({ adapter = adapter, model = config and config.model or "gpt-5.3-codex" })
end

function M.codecompanion_options()
  local context = require("weft").config.context
  return {
    adapters = { http = { weft_codex = M.codex_adapter } },
    interactions = {
      chat = {
        adapter = "weft_codex",
        opts = {
          context_management = {
            enabled = context.compact,
            editing = {
              trigger = context.edit_threshold,
              exclude_tools = {},
              keep_cycles = context.keep_tool_cycles,
            },
            compaction = {
              trigger = context.compact_threshold,
              min_token_savings = 10000,
              adapter = nil,
              fallback_to_chat_adapter = true,
            },
          },
          completion_provider = "default",
        },
        tools = { weft_workspace = { path = "weft.tools", description = "Operate in this task's workspace" } },
        keymaps = {
          send = { modes = { n = "<C-s>", i = "<C-s>" } },
          close = false,
        },
      },
    },
    display = {
      chat = {
        show_settings = false,
        show_context = false,
        show_token_count = false,
        auto_scroll = true,
        intro_message = "Write your message below · Ctrl-S to send · <leader>wk to stop",
        window = {
          layout = "vertical",
          width = 0.35,
          pertab = true,
          opts = {
            number = false,
            relativenumber = false,
            signcolumn = "no",
            foldcolumn = "0",
            wrap = true,
            linebreak = true,
            breakindent = true,
            conceallevel = 2,
          },
        },
      },
    },
  }
end

function M.save(task)
  local chat = M.chats[task.id]
  if not chat or not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return
  end
  M.repair_display(chat)
  util.save_json(store.task_directory(task) .. "/chat.json", {
    messages = chat.messages,
    lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false),
    header_line = chat.header_line,
    last_role = chat._last_role,
    cycle = chat.cycle,
    builder_state = chat.builder.state,
    display_version = 2,
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

local function clean_saved_display(chat, saved)
  local lines = saved.lines or {}
  local blank = vim.trim(table.concat(lines, "\n")) == ""
  if saved.display_version == 2 and not blank then
    return
  end
  local header = saved.header_line or 1
  local draft
  if blank then
    draft = {}
  elseif lines[header] and lines[header]:match("^## ") and saved.last_role == "user" then
    draft = vim.list_slice(lines, header + 1)
  elseif #saved.messages <= 2 then
    -- A fresh chat whose heading was overwritten by a paste.
    draft = vim.deepcopy(lines)
  else
    return -- Preserve edited transcripts if the draft cannot be identified safely.
  end
  local first = 1
  while draft[first] == "" do
    first = first + 1
  end
  if draft[first] == "> Context:" then
    while draft[first] and draft[first]:sub(1, 1) == ">" do
      table.remove(draft, first)
    end
  end
  local display = {}
  for _, message in ipairs(saved.messages) do
    if
      (message.role == "user" or message.role == "llm")
      and not (message.opts and message.opts.visible == false)
      and message.content
      and vim.trim(message.content) ~= ""
    then
      table.insert(display, vim.deepcopy(message))
    end
  end
  table.insert(display, { role = "user", content = table.concat(draft, "\n") })
  -- Render a display-only copy: full tool results remain in chat.messages.
  chat.ui:render(nil, display, { stop_context_insertion = true })
  local row = require("codecompanion.interactions.chat.parser").headers(chat) or 0
  chat.header_line = row + 1
  chat._last_role = "user"
  chat.builder.state = { last_role = "user", current_header_line = row }
end

function M.repair_display(chat)
  local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
  if chat.current_request or vim.trim(table.concat(lines, "\n")) ~= "" then
    return
  end
  clean_saved_display(chat, { lines = lines, messages = chat.messages })
end

local function ensure_workspace_tool(chat)
  local registry = chat.tool_registry
  local name = "weft_workspace"
  local id = require("codecompanion.interactions.chat.tool_registry").tool_id(name)
  if registry.in_use[name] and registry.schemas[id] then
    return
  end
  registry.in_use[name] = nil
  registry:add_single_tool(name, {
    config = { path = "weft.tools", description = "Operate in this task's workspace" },
    visible = false,
  })
  assert(registry.schemas[id], "Could not attach Weft workspace tools to this chat")
end

function M.get(task)
  local chat = M.chats[task.id]
  if chat and vim.api.nvim_buf_is_valid(chat.bufnr) then
    M.repair_display(chat)
    return chat
  end
  require("codecompanion")
  local saved = util.load_json(store.task_directory(task) .. "/chat.json", nil)
  chat = require("codecompanion.interactions.chat").new({
    adapter = require("codecompanion.adapters").resolve("weft_codex", {
      model = task.model or require("weft").config.model,
    }),
    title = "Weft · " .. task.name,
    hidden = true,
    buffer_context = require("codecompanion.utils.context").get(),
    stop_context_insertion = true,
    messages = saved and vim.deepcopy(saved.messages) or nil,
    tools = { "weft_workspace" },
    callbacks = {
      on_before_submit = function(current)
        ensure_workspace_tool(current)
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
    chat.builder.state = saved.builder_state
      or {
        last_role = saved.last_role,
        current_header_line = math.max(0, (saved.header_line or 1) - 1),
      }
    clean_saved_display(chat, saved)
  end
  -- Hidden context has no buffer markers to reconcile. Upstream otherwise
  -- interprets their absence as deletion and removes tools from restored chats.
  local check_context = chat.check_context
  chat.check_context = function(self)
    if require("codecompanion.config").display.chat.show_context then
      return check_context(self)
    end
  end
  ensure_workspace_tool(chat)
  -- CodeCompanion's normal send key and :Weft send must repair the same draft.
  local submit = chat.submit
  chat.submit = function(self, options)
    if not self.current_request and not (options and (options.auto_submit or options.regenerate)) then
      local parser = require("codecompanion.interactions.chat.parser")
      local header = parser.headers(self)
      if header == nil then
        local has_history = false
        for _, message in ipairs(self.messages) do
          if message.role ~= "system" and not (message.opts and message.opts.visible == false) then
            has_history = true
            break
          end
        end
        if has_history then
          return util.notify(
            "Chat input heading is missing. Undo the heading edit before sending; your text is still here.",
            vim.log.levels.WARN
          )
        end
        -- A fresh chat may have been replaced with a pasted, headerless prompt.
        local lines = {}
        self.ui:set_header(lines, require("codecompanion.config").interactions.chat.roles.user)
        vim.api.nvim_buf_set_lines(self.bufnr, 0, 0, false, lines)
        header = 0
      end
      self.header_line = header + 1
      self.builder.state.last_role = "user"
      self.builder.state.current_header_line = header
      local message = parser.messages(self, self.header_line)
      if not message or vim.trim(message.content or "") == "" then
        return util.notify(
          "Write your message below the last Me heading, then press Ctrl-S. Your text has not been sent.",
          vim.log.levels.INFO
        )
      end
    end
    if not self.current_request then
      ensure_workspace_tool(self)
    end
    return submit(self, options)
  end
  vim.treesitter.language.register("markdown", "codecompanion")
  pcall(vim.treesitter.start, chat.bufnr, "markdown")
  chat:set_system_prompt(prompt(task))
  vim.keymap.set("n", "q", function()
    M.toggle(task)
  end, { buffer = chat.bufnr, desc = "Hide task chat" })
  return chat
end

function M.toggle(task, options)
  local chat = M.get(task)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == chat.bufnr then
      if options and options.open then
        vim.api.nvim_set_current_win(win)
        return
      end
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
  local found
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == chat.bufnr then
      found = win
    end
  end
  if not found then
    M.toggle(task)
  else
    vim.api.nvim_set_current_win(found)
  end
  chat:submit()
end

function M.stop(task)
  local chat = M.chats[task.id]
  if chat then
    chat:stop()
  end
end

function M.set_model(task, model)
  local chat = M.get(task)
  assert(not chat.current_request, "Stop the current request before switching models")
  chat:change_model({ model = model })
  task.model = model
  store.save()
  M.save(task)
  util.notify("Model for " .. task.name .. ": " .. model)
end

function M.model_names()
  local adapter = M.codex_adapter()
  local choices = adapter.schema.model.choices
  if type(choices) == "function" then
    choices = choices(adapter)
  end
  local names = {}
  for name in pairs(choices or {}) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

function M.pick_model(task)
  local config = require("weft").config
  local chat = M.chats[task.id]
  local current = chat and chat.settings.model or task.model or config.model
  local names = M.model_names()
  if not vim.tbl_contains(names, current) then
    table.insert(names, current)
  end
  table.sort(names, function(a, b)
    if a == b then
      return false
    end
    if a == current then
      return true
    end
    if b == current then
      return false
    end
    return a > b
  end)
  require("weft").select(
    names,
    {
      prompt = "Weft · " .. task.name .. " · model",
      format_item = function(name)
        return name .. (name == current and "  (current)" or "")
      end,
    },
    util.guard(function(model)
      if model then
        M.set_model(task, model)
      end
    end)
  )
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
