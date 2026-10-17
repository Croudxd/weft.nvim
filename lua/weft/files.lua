local util = require("weft.util")
local store = require("weft.store")
local M = {}

function M.resolve(task, relative)
  assert(type(relative) == "string" and relative ~= "", "A workspace-relative path is required")
  assert(not relative:find("\0", 1, true) and relative:sub(1, 1) ~= "/", "Use a workspace-relative path")
  local path = util.path(task.root .. "/" .. relative)
  assert(util.inside(path, task.root), "Path escapes this task")
  local probe = path
  while not vim.uv.fs_lstat(probe) do
    local parent = vim.fs.dirname(probe)
    assert(parent ~= probe, "Cannot resolve path")
    probe = parent
  end
  local real = assert(vim.uv.fs_realpath(probe))
  assert(util.inside(real, assert(vim.uv.fs_realpath(task.root))), "Symlink escapes this task")
  for part in path:sub(#task.root + 2):gmatch("[^/]+") do
    assert(part ~= ".git", "Git metadata is not a source file")
  end
  return path
end

function M.read(task, relative)
  local path = M.resolve(task, relative)
  assert(store.repository(task, path), "Choose a file inside one of this task's repositories")
  local stat = vim.uv.fs_stat(path)
  assert(not stat or stat.type == "file", "Not a regular file")
  assert(not stat or stat.size <= require("weft").config.max_file_bytes, "File is too large for a text tool")
  local buffer = vim.fn.bufnr(path)
  local disk = util.read(path)
  local loaded = buffer >= 0 and vim.api.nvim_buf_is_loaded(buffer)
  if loaded then
    local disk_hash = disk and vim.fn.sha256(disk) or "missing"
    local previous = vim.b[buffer].weft_disk_hash
    assert(
      not (vim.bo[buffer].modified and previous and previous ~= disk_hash),
      "Disk changed underneath unsaved buffer; resolve that change before the agent edits it"
    )
    if not vim.bo[buffer].modified and disk and util.buffer_text(buffer) ~= disk then
      util.set_text(buffer, disk)
      vim.bo[buffer].modified = false
    end
    vim.b[buffer].weft_disk_hash = disk_hash
  end
  local content = loaded and (vim.bo[buffer].modified or disk ~= nil) and util.buffer_text(buffer) or disk
  assert(not content or not content:find("\0", 1, true), "Binary files are not supported by text tools")
  return content, path, buffer
end

function M.write(task, args)
  local before, path, buffer = M.read(task, args.path)
  assert(
    type(args.expected_hash) == "string",
    "Read the file first and supply its hash, or 'missing' for a new file"
  )
  local hash = before and vim.fn.sha256(before) or "missing"
  assert(hash == args.expected_hash, "File changed since it was read. Read it again before editing.")
  local changes = require("weft.changes")
  local entry = changes.capture(task, path, before)
  assert(not entry.disk_conflict, "Disk and unsaved buffer have diverged; resolve the external edit first")
  local after = args.content
  if args.action == "replace" then
    assert(type(args.old_text) == "string" and args.old_text ~= "", "old_text must not be empty")
    assert(before, "Cannot replace text in a missing file")
    local first, last = before:find(args.old_text, 1, true)
    assert(first and not before:find(args.old_text, last + 1, true), "old_text must match exactly once")
    assert(type(after) == "string", "content must contain the replacement text")
    after = before:sub(1, first - 1) .. after .. before:sub(last + 1)
  end
  if args.action == "delete" then
    assert(before, "File is already missing")
    assert(
      buffer < 0 or not vim.bo[buffer].modified,
      "Save or resolve your unsaved edits before deleting this file"
    )
    if vim.uv.fs_stat(path) then
      assert(vim.uv.fs_unlink(path))
    end
    if buffer >= 0 and vim.api.nvim_buf_is_loaded(buffer) then
      util.set_text(buffer, "")
      vim.bo[buffer].modified = false
    end
    after = nil
  else
    assert(type(after) == "string" and not after:find("\0", 1, true), "content must be text")
    assert(#after <= require("weft").config.max_file_bytes, "Result exceeds the text file size limit")
    local dirty = buffer >= 0 and vim.bo[buffer].modified
    buffer = require("weft.buffers").load(task, path)
    util.set_text(buffer, after)
    if not dirty then
      util.write(path, after)
      vim.bo[buffer].modified = false
      vim.b[buffer].weft_disk_hash = vim.fn.sha256(after)
    end
  end
  changes.record(task, path, before, after)
  require("weft.ui").refresh_changes(task)
  return {
    path = args.path,
    hash = after and vim.fn.sha256(after) or "missing",
    unsaved = buffer >= 0 and vim.bo[buffer].modified or false,
  }
end

return M
