vim.opt.runtimepath:prepend(vim.fn.getcwd())
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
  util.git(original, { "init", "-b", "main" })
  util.git(original, { "config", "user.name", "Weft Test" })
  util.git(original, { "config", "user.email", "weft@example.invalid" })
  util.write(original .. "/source.lua", "return 1\n")
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
  equal(vim.fn.getcompletion("Weft model gpt-5.3", "cmdline"), { "gpt-5.3-codex" })
  equal(vim.fn.getcompletion("Weft model def", "cmdline"), { "default" })
  equal(vim.fn.getcompletion("Weft mo", "cmdline"), { "model" })
  print("PASS model command completion returns adapter models filtered by the typed prefix")

  local requests = {}
  local http = require("codecompanion.http")
  local real_new = http.new
  http.new = function()
    return {
      send = function(_, payload, callbacks)
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
    vim.api.nvim_buf_set_lines(
      chat.bufnr,
      last - 1,
      last,
      false,
      { "Change the return value to my task name." }
    )
    agent.send(tasks[name])
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
  end
  equal(util.read(original .. "/source.lua"), "return 1\n")
  print(
    "PASS two concurrent real CodeCompanion chats apply tool edits to their bound tasks after switching tabs"
  )

  require("weft.workspace").switch(tasks.cancelled)
  local cancelled_chat = agent.get(tasks.cancelled)
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
    equal(items[1], "gpt-5.3-codex")
    assert(options.format_item(items[1]):find("current", 1, true))
    selection = callback
  end
  vim.cmd("Weft model")
  assert(selection, "Model command did not open a picker")
  selection(nil)
  equal(chat.settings.model, "gpt-5.3-codex")
  agent.pick_model(tasks.alpha)
  selection("gpt-5.4")
  vim.ui.select = select
  equal(chat.settings.model, "gpt-5.4")
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
  chat:close()
  agent.chats.alpha = nil
  local restored = agent.get(tasks.alpha)
  equal(restored.settings.model, "gpt-5.4")
  equal(conversation(restored), original_messages)
  equal(vim.b[restored.bufnr].weft_task, "alpha")
  require("weft.ui").source(tasks.alpha, vim.fn.bufnr(tasks.alpha.root .. "/app/source.lua"))
  agent.attach(tasks.alpha)
  print("PASS task chats persist outside repositories and restore with buffer attachments")
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
