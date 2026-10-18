vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/after")
vim.opt.hidden = true
vim.o.swapfile = false
local dependencies = vim.env.WEFT_DEPENDENCIES or vim.fn.stdpath("data") .. "/lazy"
for _, name in ipairs({ "plenary.nvim", "cc-adapter-codex.nvim", "codecompanion.nvim" }) do
  local path = dependencies .. "/" .. name
  assert(vim.uv.fs_stat(path), "Install chat test dependency: " .. path)
  vim.opt.runtimepath:append(path)
end

local util = require("weft.util")
local sandbox = vim.fn.stdpath("cache") .. "/weft-chat-tests/" .. vim.uv.hrtime()
local original = sandbox .. "/original"
vim.fn.mkdir(original, "p")
local function equal(actual, expected)
  assert(
    vim.deep_equal(actual, expected),
    "Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end

local function run()
  local startup = require("weft.agent").codecompanion_options()
  assert(startup.interactions.chat.opts.context_management.enabled, "Pre-setup context defaults missing")
  require("codecompanion").setup(startup)
  assert(
    require("codecompanion.config").adapters.http.weft_codex,
    "Adapter missing after dependency-first setup"
  )
  print("PASS CodeCompanion can initialize before Weft setup, as it does under lazy.nvim")
  util.git(original, { "init", "-b", "main" })
  util.git(original, { "config", "user.name", "Weft Test" })
  util.git(original, { "config", "user.email", "weft@example.invalid" })
  util.write(original .. "/source.lua", "return 1\n")
  util.write(original .. "/settings.yaml", "service:\n  enabled: false\n")
  util.git(original, { "add", "." })
  util.git(original, { "commit", "-m", "Initial" })
  require("weft").setup({
    state_dir = sandbox .. "/state",
    worktree_root = sandbox .. "/tasks",
    repositories = { app = original },
    poll_interval = 0,
    mappings = false,
  })
  local tasks = {}
  for _, name in ipairs({ "alpha", "beta", "cancelled" }) do
    local ready = false
    require("weft.workspace").create(name, require("weft").config, function(task, failure)
      assert(task, failure)
      tasks[name], ready = task, true
    end)
    assert(vim.wait(10000, function()
      return ready
    end, 10))
  end
  local agent = require("weft.agent")
  agent.codex_adapter()
  agent.adapter.handlers.resolve = nil
  agent.adapter.handlers.lifecycle.setup = function()
    return true
  end
  require("codecompanion").setup(agent.codecompanion_options())
  local adapters = require("codecompanion.adapters")
  local adapter = adapters.resolve("weft_codex")
  equal(require("codecompanion.adapters.utils").model(adapter), "gpt-5.3-codex")
  local parameters = adapters.call_handler(
    adapter,
    "build_parameters",
    { params = { model = "gpt-5.3-codex" }, messages = {} }
  )
  equal(parameters.model, "gpt-5.3-codex")
  equal(parameters.store, false)
  local messages = adapters.call_handler(
    adapter,
    "build_messages",
    { messages = { { role = "system", content = "instructions" }, { role = "user", content = "hello" } } }
  )
  equal(messages.instructions, "instructions")
  equal(messages.input[1].content[1].text, "hello")
  local schema =
    adapters.call_handler(adapter, "build_tools", { tools = { { require("weft.tools").schema } } })
  equal(schema.tools[1].name, "weft_workspace")
  print("PASS real Codex adapter request builders match CodeCompanion's handler contract")
  equal(vim.fn.getcompletion("Weft model gpt-5.3", "cmdline"), {})
  equal(vim.fn.getcompletion("Weft model def", "cmdline"), { "default" })
  equal(vim.fn.getcompletion("Weft model gpt-6-as", "cmdline"), {})
  local models = require("weft.models")
  equal(
    models.parse({
      models = {
        { slug = "gpt-6-astra", visibility = "list" },
        { slug = "internal", visibility = "hide" },
        { slug = "gpt-6-astra", visibility = "list" },
      },
    }),
    { "gpt-6-astra" }
  )
  local system = vim.system
  local refreshed = false
  vim.system = function(_, _, callback)
    callback({
      code = 0,
      stdout = vim.json.encode({ models = {
        { slug = "future-model", visibility = "list" },
      } }),
    })
  end
  models.refresh(function()
    refreshed = true
  end)
  assert(vim.wait(1000, function()
    return refreshed
  end))
  equal(models.names(), { "future-model" })
  equal(vim.fn.getcompletion("Weft model future-", "cmdline"), {})
  models.catalogue = nil
  equal(models.names(), { "future-model" })
  vim.fn.delete(require("weft").config.state_dir .. "/models.json")
  models.catalogue = nil
  vim.system = system
  equal(vim.fn.getcompletion("Weft mo", "cmdline"), { "model" })
  print("PASS model command completion returns adapter models filtered by the typed prefix")

  local requests = {}
  local http = require("codecompanion.http")
  local real_new = http.new
  http.new = function(options)
    return {
      send = function(_, payload, callbacks)
        local sent_parameters = adapters.call_handler(options.adapter, "build_parameters", {
          params = options.adapter.parameters,
          messages = payload.messages,
        })
        equal(sent_parameters.model, options.adapter.schema.model.default)
        local request_tools = adapters.call_handler(adapter, "build_tools", { tools = payload.tools })
        assert(request_tools and request_tools.tools, "Request has no workspace tools")
        local workspace_tool = false
        for _, schema in ipairs(request_tools.tools) do
          if schema.name == "weft_workspace" then
            workspace_tool = true
          end
        end
        assert(workspace_tool, "Workspace tool missing from outgoing request")
        local id = vim.b[callbacks.bufnr].weft_task
        local task = tasks[id]
        assert(task, "Request not associated with a task")
        requests[id] = (requests[id] or 0) + 1
        local number = requests[id]
        local cancelled = false
        vim.defer_fn(function()
          if cancelled then
            return
          end
          local event
          if number == 1 then
            local content = assert(util.read(task.root .. "/app/source.lua"))
            event = {
              type = "response.output_item.done",
              item = {
                type = "function_call",
                call_id = "call-" .. id,
                name = "weft_workspace",
                arguments = vim.json.encode({
                  action = "write",
                  path = "app/source.lua",
                  content = "return '" .. id .. "'\n",
                  expected_hash = vim.fn.sha256(content),
                  old_text = vim.NIL,
                }),
              },
            }
          else
            event = { type = "response.output_text.delta", delta = "Finished " .. id }
          end
          callbacks.on_chunk("data: " .. vim.json.encode(event) .. "\n\n")
          callbacks.on_done()
        end, 30)
        return {
          cancel = function()
            cancelled = true
          end,
        }
      end,
    }
  end

  local reading_window
  for _, name in ipairs({ "alpha", "beta" }) do
    require("weft.workspace").switch(tasks[name])
    require("weft").open(tasks[name])
    local windows = #vim.api.nvim_tabpage_list_wins(0)
    equal(windows, 3)
    require("weft").open(tasks[name])
    equal(#vim.api.nvim_tabpage_list_wins(0), windows)
    local chat = agent.get(tasks[name])
    equal(chat.settings.model, "gpt-5.3-codex")
    local last = vim.api.nvim_buf_line_count(chat.bufnr)
    if name == "alpha" then
      -- Paste over the initial heading, as in an ordinary editable buffer.
      vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, {
        "Change the return value to my task name.",
        "",
        "Keep the surrounding code intact.",
      })
    else
      vim.api.nvim_buf_set_lines(
        chat.bufnr,
        last - 1,
        last,
        false,
        { "Change the return value to my task name." }
      )
    end
    vim.api.nvim_win_set_cursor(chat.ui.winnr, { 1, 0 })
    chat.ui.cursor.moved_by_user = true
    agent.send(tasks[name])
    equal(vim.api.nvim_win_get_cursor(chat.ui.winnr)[1], vim.api.nvim_buf_line_count(chat.bufnr))
    if name == "beta" then
      require("weft.ui").source(
        tasks.beta,
        require("weft.buffers").load(tasks.beta, tasks.beta.root .. "/app/source.lua")
      )
      reading_window = vim.api.nvim_get_current_win()
    end
  end
  assert(
    vim.wait(10000, function()
      return agent.status.alpha == "ready" and agent.status.beta == "ready"
    end, 10),
    "Agents did not finish: " .. vim.inspect(agent.status)
  )
  for _, name in ipairs({ "alpha", "beta" }) do
    equal(util.read(tasks[name].root .. "/app/source.lua"), "return '" .. name .. "'\n")
    assert(requests[name] >= 2, "Agent did not continue after its tool call")
    equal(#require("weft.changes").list(tasks[name]), 1)
    local text = table.concat(vim.api.nvim_buf_get_lines(agent.get(tasks[name]).bufnr, 0, -1, false), "\n")
    assert(not text:find('"hash"', 1, true), "Tool hashes leaked into chat display")
    assert(not text:find('"path":', 1, true), "Raw tool JSON leaked into chat display")
    assert(text:find("Updated `app/source.lua`", 1, true), "Tool activity summary is missing")
  end
  equal(util.read(original .. "/source.lua"), "return 1\n")
  equal(vim.api.nvim_get_current_win(), reading_window)
  local beta = agent.get(tasks.beta)
  equal(vim.api.nvim_win_get_cursor(beta.ui.winnr)[1], vim.api.nvim_buf_line_count(beta.bufnr))
  print("PASS sending resumes scrolling and streamed responses follow without taking focus from source")
  print(
    "PASS two concurrent real CodeCompanion chats apply tool edits to their bound tasks after switching tabs"
  )

  require("weft.workspace").switch(tasks.cancelled)
  local cancelled_chat = agent.get(tasks.cancelled)
  vim.api.nvim_buf_set_lines(cancelled_chat.bufnr, 0, -1, false, {})
  agent.get(tasks.cancelled)
  assert(
    require("codecompanion.interactions.chat.parser").headers(cancelled_chat) ~= nil,
    "Fresh blank chat did not recover its input heading"
  )
  local last_line = vim.api.nvim_buf_line_count(cancelled_chat.bufnr)
  vim.api.nvim_buf_set_lines(cancelled_chat.bufnr, last_line - 1, last_line, false, { "Edit the file." })
  agent.send(tasks.cancelled)
  agent.stop(tasks.cancelled)
  vim.wait(100, function()
    return false
  end, 10)
  equal(util.read(tasks.cancelled.root .. "/app/source.lua"), "return 1\n")
  equal(agent.status.cancelled, "stopped")
  print("PASS stopping a request prevents its pending tool edits without stopping other task agents")

  local tool = require("weft.tools")
  local chat = agent.get(tasks.alpha)
  local output, job
  tool.cmds[1]({ chat = chat }, { action = "command", path = "app", content = "pwd" }, {
    output_cb = function(result)
      output = result
    end,
    register_job = function(value)
      job = value
    end,
  })
  assert(job, "Shell command did not register a cancellable job")
  assert(vim.wait(10000, function()
    return output ~= nil
  end, 10))
  equal(output.status, "success")
  assert(output.data:find(tasks.alpha.root .. "/app", 1, true))
  print("PASS background commands use their chat's task directory rather than the active tab")

  require("weft.workspace").switch(tasks.alpha)
  local select = vim.ui.select
  local selection
  vim.ui.select = function(items, options, callback)
    equal(items[1], "weft_codex")
    assert(options.format_item(items[1]):find("current", 1, true))
    selection = callback
  end
  vim.cmd("Weft model")
  assert(selection, "Model command did not open a provider picker")
  selection(nil)
  equal(chat.settings.model, "gpt-5.3-codex")
  agent.pick_model(tasks.alpha)
  selection(nil)
  vim.ui.select = select
  equal(chat.settings.model, "gpt-5.3-codex")
  equal(agent.get(tasks.beta).settings.model, "gpt-5.3-codex")
  print("PASS model picker labels the current choice, preserves cancellation, and changes only its task")
  agent.save(tasks.alpha)
  local function conversation(current)
    local result = {}
    for _, message in ipairs(current.messages) do
      if message.role ~= "system" then
        table.insert(result, { role = message.role, content = message.content, tools = message.tools })
      end
    end
    return result
  end
  local original_messages = conversation(chat)
  -- Simulate an older persisted UI with raw tool JSON and an unsent draft.
  local legacy = util.load_json(require("weft.store").task_directory(tasks.alpha) .. "/chat.json")
  legacy.display_version, legacy.builder_state = nil, nil
  legacy.context_items =
    { { source = "tool", id = "<tool>weft_workspace</tool>", opts = { visible = true } } }
  table.insert(legacy.lines, legacy.header_line, '{"hash":"internal-version","content":"raw tool data"}')
  legacy.header_line = legacy.header_line + 1
  legacy.lines[#legacy.lines] = "Keep my unsent draft."
  util.save_json(require("weft.store").task_directory(tasks.alpha) .. "/chat.json", legacy)
  chat:close()
  agent.chats.alpha = nil
  local restored = agent.get(tasks.alpha)
  equal(restored.settings.model, "gpt-5.3-codex")
  equal(conversation(restored), original_messages)
  equal(vim.b[restored.bufnr].weft_task, "alpha")
  local restored_text = table.concat(vim.api.nvim_buf_get_lines(restored.bufnr, 0, -1, false), "\n")
  assert(not restored_text:find('"hash"', 1, true), "Legacy tool JSON was not removed from the display")
  assert(restored_text:find("Keep my unsent draft.", 1, true), "Legacy cleanup lost an unsent draft")
  require("weft.ui").source(tasks.alpha, vim.fn.bufnr(tasks.alpha.root .. "/app/source.lua"))
  agent.attach(tasks.alpha)
  vim.cmd("Weft before")
  local preview = require("weft.ui").views[tasks.alpha.id].before
  assert(
    preview and vim.api.nvim_win_is_valid(preview.window),
    "Previous-code command did not open a preview"
  )
  assert(vim.api.nvim_buf_get_lines(preview.buffer, 0, -1, false)[1], "Previous-code preview is empty")
  vim.cmd("Weft before")
  assert(
    not require("weft.ui").views[tasks.alpha.id].before.window,
    "Previous-code command did not hide its preview"
  )
  print("PASS previous-code command opens and toggles the source file preview")
  print("PASS task chats persist outside repositories and restore with buffer attachments")

  -- Native Ctrl-S invokes chat:submit directly, so test that route after restore.
  local followup = "Please explain the change.\n\nInclude a YAML example."
  local last = vim.api.nvim_buf_line_count(restored.bufnr)
  vim.api.nvim_buf_set_lines(
    restored.bufnr,
    last - 1,
    last,
    false,
    vim.split(followup, "\n", { plain = true })
  )
  restored.header_line = last + 100 -- stale saved/parser position must not lose the draft
  restored.tool_registry.schemas = {} -- recover tools lost by an earlier broken session
  restored:submit()
  assert(vim.wait(10000, function()
    return agent.status.alpha == "ready"
  end, 10))
  local found_followup = false
  for _, message in ipairs(restored.messages) do
    if message.role == "user" and message.content:gsub("%s+", " ") == followup:gsub("%s+", " ") then
      found_followup = true
    end
  end
  assert(found_followup, "Restored chat failed to send the complete draft")
  assert(restored.tool_registry.in_use.weft_workspace, "Restored workspace tool was lost")
  print("PASS hidden legacy context and missing schemas retain workspace tools on outgoing requests")
  local sent = requests.alpha
  restored:submit()
  equal(requests.alpha, sent) -- blank sends must not repeat an earlier message
  print("PASS pasted prompts and restored multiline drafts send without repeating empty messages")

  local ui, changes = require("weft.ui"), require("weft.changes")
  local yaml_path = tasks.alpha.root .. "/app/settings.yaml"
  require("weft.files").write(tasks.alpha, {
    action = "write",
    path = "app/settings.yaml",
    expected_hash = vim.fn.sha256(util.read(yaml_path)),
    content = "service:\n  enabled: true\n",
  })
  changes.refresh_file(tasks.alpha, changes.state(tasks.alpha).entries[yaml_path])
  ui.refresh_changes(tasks.alpha)
  local panel = ui.views[tasks.alpha.id].changes
  local row
  for line, entry in pairs(panel.rows) do
    if entry.path == yaml_path and (not row or line < row) then
      row = line
    end
  end
  assert(row, "YAML file missing from changes panel")
  vim.api.nvim_set_current_win(panel.window)
  vim.api.nvim_win_set_cursor(panel.window, { row, 0 })
  ui.refresh_changes(tasks.alpha)
  equal(panel.rows[vim.api.nvim_win_get_cursor(panel.window)[1]].path, yaml_path)
  vim.fn.maparg("<CR>", "n", false, true).callback()
  equal(vim.api.nvim_buf_get_name(0), yaml_path)
  assert(vim.api.nvim_get_current_win() ~= panel.window, "Enter did not focus the source window")
  ui.before(tasks.alpha)
  equal(vim.bo[ui.views[tasks.alpha.id].before.buffer].filetype, "yaml")
  equal(
    vim.api.nvim_buf_get_lines(ui.views[tasks.alpha.id].before.buffer, 0, -1, false),
    { "service:", "  enabled: false" }
  )
  ui.hide(tasks.alpha, "before")
  print("PASS changes selection survives refresh, Enter opens the file, and YAML previews resolve correctly")
  local history = conversation(restored)
  vim.api.nvim_buf_set_lines(restored.bufnr, 0, -1, false, {})
  agent.save(tasks.alpha)
  local chat_path = require("weft.store").task_directory(tasks.alpha) .. "/chat.json"
  local snapshot = util.load_json(chat_path)
  assert(vim.trim(table.concat(snapshot.lines, "\n")) ~= "", "Save persisted an empty chat display")
  snapshot.lines = { "" }
  snapshot.header_line = 999
  util.save_json(chat_path, snapshot)
  restored:close()
  agent.chats.alpha = nil
  local recovered = agent.get(tasks.alpha)
  equal(conversation(recovered), history)
  assert(
    require("codecompanion.interactions.chat.parser").headers(recovered) ~= nil,
    "Saved blank chat did not recover its Me heading"
  )
  local recovered_text = table.concat(vim.api.nvim_buf_get_lines(recovered.bufnr, 0, -1, false), "\n")
  assert(
    recovered_text:find("Finished alpha", 1, true),
    "Saved blank chat did not recover assistant responses"
  )
  assert(not recovered_text:find('"hash"', 1, true), "Display recovery exposed raw tool JSON")
  print("PASS blank fresh, live, and saved chat displays recover without losing message history")
  recovered:change_model({ model = "gpt-5.4" })
  agent.save(tasks.alpha)
  equal(tasks.alpha.model, "gpt-5.4")
  equal(util.load_json(chat_path).model, "gpt-5.4")
  recovered:close()
  agent.chats.alpha = nil
  tasks.alpha.model = nil -- the conversation must retain its model independently
  local model_restored = agent.get(tasks.alpha)
  equal(model_restored.settings.model, "gpt-5.4")
  equal(model_restored.adapter.schema.model.default, "gpt-5.4")
  print(
    "PASS native model selections persist in the task and chat snapshot rather than reverting to the default"
  )
  http.new = real_new
end

local ok, message = xpcall(run, debug.traceback)
vim.fn.delete(sandbox, "rf")
if not ok then
  io.stderr:write(message .. "\n")
  vim.cmd("cquit 1")
else
  print("Chat integration tests passed")
  vim.cmd("qa!")
end
