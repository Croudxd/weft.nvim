local M = {}

function M.notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Weft" })
end

function M.path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p")):gsub("/$", "")
end

function M.inside(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

function M.git(directory, args)
  local command = { "git", "-C", directory }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = false }):wait()
  if result.code ~= 0 then
    error(vim.trim(result.stderr ~= "" and result.stderr or result.stdout), 0)
  end
  return result.stdout
end

function M.read(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  assert(file:write(content))
  assert(file:close())
end

function M.save_json(path, value)
  local temporary = path .. ".tmp"
  M.write(temporary, vim.json.encode(value))
  assert(vim.uv.fs_rename(temporary, path))
end

function M.load_json(path, default)
  local content = M.read(path)
  if not content then
    return default
  end
  local ok, value = pcall(vim.json.decode, content)
  if not ok then
    error("Cannot read Weft state at " .. path .. ": " .. tostring(value), 0)
  end
  return value
end

function M.lines(content)
  if content == "" then
    return {}
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function M.buffer_text(buffer)
  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local separator = vim.bo[buffer].fileformat == "dos" and "\r\n" or "\n"
  local content = table.concat(lines, separator)
  return content .. (vim.bo[buffer].endofline and separator or "")
end

function M.set_text(buffer, content)
  local dos = content:find("\r\n", 1, true) ~= nil
  local lines = M.lines(dos and content:gsub("\r\n", "\n") or content)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buffer].fileformat = dos and "dos" or "unix"
  vim.bo[buffer].endofline = content:sub(-1) == "\n"
end

function M.guard(callback)
  return function(...)
    local ok, result = pcall(callback, ...)
    if not ok then
      M.notify(tostring(result), vim.log.levels.ERROR)
    end
    return ok and result or nil
  end
end

return M
