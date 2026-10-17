local util = require("weft.util")
local files = require("weft.files")
local M = {}

local function task_for(chat)
  local id = vim.b[chat.bufnr].weft_task
  return assert(require("weft.store").tasks[id], "This tool requires a Weft task chat")
end

local function execute(self, args, options)
  local task = task_for(self.chat)
  local path = files.resolve(task, args.path)
  if args.action == "read" then
    local content = files.read(task, args.path)
    return {
      status = "success",
      data = vim.json.encode({
        path = args.path,
        content = content or vim.NIL,
        hash = content and vim.fn.sha256(content) or "missing",
      }),
    }
  elseif args.action == "list" then
    local entries = {}
    for name, kind in vim.fs.dir(path) do
      if name ~= ".git" then
        table.insert(entries, { name = name, type = kind })
      end
    end
    table.sort(entries, function(a, b)
      return a.name < b.name
    end)
    return { status = "success", data = vim.json.encode(entries) }
  elseif args.action == "write" or args.action == "replace" or args.action == "delete" then
    return { status = "success", data = vim.json.encode(files.write(task, args)) }
  elseif args.action == "search" or args.action == "command" then
    local command
    if args.action == "search" then
      assert(type(args.content) == "string", "content must contain a search pattern")
      command = { "rg", "--line-number", "--no-heading", "--color", "never", "--", args.content, "." }
    else
      assert(type(args.content) == "string" and args.content ~= "", "content must contain a shell command")
      for _, buffer in ipairs(require("weft.buffers").list(task)) do
        assert(
          not vim.bo[buffer].modified,
          "Task has unsaved source buffers. Ask the user to save before running commands."
        )
      end
      command = { "bash", "-c", args.content }
    end
    local stat = vim.uv.fs_stat(path)
    assert(stat and stat.type == "directory", "path must be a working directory")
    local job = vim.system(
      command,
      { cwd = path, text = true, timeout = require("weft").config.command_timeout },
      vim.schedule_wrap(function(result)
        require("weft.changes").scan(task)
        local text = "Exit " .. result.code .. "\n" .. (result.stdout or "") .. (result.stderr or "")
        local success = result.code == 0 or (args.action == "search" and result.code == 1)
        options.output_cb({ status = success and "success" or "error", data = text:sub(1, 40000) })
      end)
    )
    options.register_job(job)
    return
  end
  error("Unknown action: " .. tostring(args.action))
end

M.name = "weft_workspace"
M.cmds = {
  function(self, args, options)
    local ok, result = pcall(execute, self, args, options)
    if not ok then
      return { status = "error", data = tostring(result) }
    end
    return result
  end,
}
M.opts = { require_approval_before = false }
M.schema = {
  type = "function",
  ["function"] = {
    name = "weft_workspace",
    description = "Read, list, search, edit, create or delete files in this chat's isolated task workspace, or run commands there. Paths are workspace-relative, including the repository directory. Read returns a hash; all edits require that exact expected_hash. Reads include unsaved buffers. replace requires unique old_text; content is its replacement. write uses complete content. search uses content as a ripgrep pattern and path as directory. command uses content as a shell command and path as explicit working directory. Use '.' to list repositories. File edits are applied directly, not proposed in chat.",
    parameters = {
      type = "object",
      properties = {
        action = {
          type = "string",
          enum = { "list", "read", "search", "write", "replace", "delete", "command" },
        },
        path = { type = "string" },
        content = { type = { "string", "null" } },
        old_text = { type = { "string", "null" } },
        expected_hash = { type = { "string", "null" } },
      },
      required = { "action", "path", "content", "old_text", "expected_hash" },
      additionalProperties = false,
    },
    strict = true,
  },
}
M.output = {
  success = function(self, stdout, meta)
    local labels = {
      read = "Read",
      list = "Listed",
      search = "Searched",
      write = "Updated",
      replace = "Updated",
      delete = "Deleted",
      command = "Ran command in",
    }
    meta.tools.chat:add_tool_output(self, {
      content = tostring(stdout[#stdout]),
      display = (labels[self.args.action] or self.args.action) .. " `" .. self.args.path .. "`",
    })
  end,
  error = function(self, stderr, meta)
    meta.tools.chat:add_tool_output(self, { content = tostring(stderr[#stderr]) })
  end,
}

return M
