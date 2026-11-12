local util = require("weft.util")
local store = require("weft.store")
local buffers = require("weft.buffers")
local M = { states = {}, namespace = vim.api.nvim_create_namespace("weft.changes") }

-- Track only lines inserted by the agent. We deliberately do not infer who
-- made every other edit: formatters, external tools, and normal diff alignment
-- make a reliable per-line "user" label impossible.
local function remap_ai_lines(previous, content, old_marks, mark_inserted)
  local next_marks = {}
  local old_row, new_row = 1, 1
  for _, hunk in ipairs(vim.diff(previous, content, { result_type = "indices", algorithm = "histogram" })) do
    local old_start = hunk[1] + (hunk[2] == 0 and 1 or 0)
    local new_start = hunk[3] + (hunk[4] == 0 and 1 or 0)
    while old_row < old_start and new_row < new_start do
      next_marks[new_row] = old_marks[old_row] == true
      old_row, new_row = old_row + 1, new_row + 1
    end
    for row = new_start, new_start + hunk[4] - 1 do
      next_marks[row] = mark_inserted
    end
    old_row, new_row = old_start + hunk[2], new_start + hunk[4]
  end
  local count = #util.lines(content)
  while new_row <= count do
    next_marks[new_row] = old_marks[old_row] == true
    old_row, new_row = old_row + 1, new_row + 1
  end
  return next_marks
end

local function mark_ai_lines(entry, before, after)
  local previous = entry.ai_text or entry.authorship_text or entry.before
  local old_marks = entry.ai_lines or {}
  if not entry.ai_lines and entry.authorship then
    for row, owner in pairs(entry.authorship) do
      old_marks[row] = owner == "ai"
    end
  end
  -- First carry existing AI marks through user/external changes, without
  -- labelling those edits. Then label only this agent write's inserted lines.
  old_marks = remap_ai_lines(previous, before, old_marks, false)
  entry.ai_lines = remap_ai_lines(before, after, old_marks, true)
  entry.ai_text = after
  -- Drop the old best-effort user/AI ownership data when this entry is saved.
  entry.authorship, entry.authorship_text = nil, nil
end

function M.state(task)
  if not M.states[task.id] then
    M.states[task.id] =
      util.load_json(store.task_directory(task) .. "/changes.json", { entries = {} })
  end
  return M.states[task.id]
end

function M.save(task)
  local state = M.state(task)
  local content = vim.json.encode({ entries = state.entries })
  if content ~= state.saved_content then
    local path = store.task_directory(task) .. "/changes.json"
    util.write(path .. ".tmp", content)
    assert(vim.uv.fs_rename(path .. ".tmp", path))
    state.saved_content = content
  end
end

local function original(task, path)
  local repository = assert(store.repository(task, path), "File is outside configured repositories")
  local relative = path:sub(#repository.path + 2)
  local ok, content = pcall(util.git, repository.path, { "show", repository.base .. ":" .. relative })
  return ok and content or "", ok
end

function M.capture(task, path, before)
  local state = M.state(task)
  local entry = state.entries[path]
  if not entry then
    local content, existed = original(task, path)
    -- Ignored files explicitly touched by a tool still need their original contents.
    if not existed and before ~= nil then
      content, existed = before, true
    end
    entry = { path = path, before = content, existed = existed }
    state.entries[path] = entry
  end
  return entry
end

function M.record(task, path, before, after)
  local entry = M.capture(task, path, before)
  mark_ai_lines(entry, before or "", after or "")
  entry.seen_hash = nil
  M.refresh_file(task, entry)
  M.save(task)
end

function M.refresh_file(task, entry)
  local stat = vim.uv.fs_lstat(entry.path)
  local disk = stat and stat.type == "file" and util.read(entry.path) or nil
  entry.deleted = disk == nil
  entry.binary = (stat and stat.type ~= "file")
    or (disk and (disk:find("\0", 1, true) ~= nil or #disk > require("weft").config.max_file_bytes))
    or false
  local current = disk or ""
  local buffer = vim.fn.bufexists(entry.path) == 1 and vim.fn.bufadd(entry.path) or -1
  if disk and stat and stat.type == "file" and not entry.binary then
    -- Do not load every changed file during a scan. Loading hundreds of source
    -- buffers is expensive; only an already-open buffer needs reconciliation.
    local disk_hash = vim.fn.sha256(disk)
    if buffer >= 0 and vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified then
      current = util.buffer_text(buffer)
      if entry.disk_hash and entry.disk_hash ~= disk_hash and current ~= disk then
        entry.disk_conflict = true
      end
    elseif buffer >= 0 and vim.api.nvim_buf_is_loaded(buffer) then
      entry.disk_conflict = nil
      if util.buffer_text(buffer) ~= disk then
        util.set_text(buffer, disk)
        vim.bo[buffer].modified = false
      end
    end
    entry.disk_hash = disk_hash
    if buffer >= 0 and vim.api.nvim_buf_is_loaded(buffer) and not entry.disk_conflict then
      vim.b[buffer].weft_disk_hash = disk_hash
    end
  elseif buffer >= 0 and vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified then
    entry.disk_conflict = true
    current = util.buffer_text(buffer)
  end
  -- Preserve AI marks as user edits, formatters, and disk updates move lines.
  -- New non-agent lines deliberately receive no marker.
  if not entry.binary and entry.ai_text and entry.ai_text ~= current then
    entry.ai_lines = remap_ai_lines(entry.ai_text, current, entry.ai_lines or {}, false)
    entry.ai_text = current
  end
  entry.current_hash = vim.fn.sha256(current)
  entry.changed = current ~= entry.before or entry.deleted == entry.existed
  entry.hunks = entry.binary and {}
    or vim.diff(entry.before, current, { result_type = "indices", algorithm = "histogram" })

  if buffer >= 0 and vim.api.nvim_buf_is_loaded(buffer) then
    vim.api.nvim_buf_clear_namespace(buffer, M.namespace, 0, -1)
    local count = vim.api.nvim_buf_line_count(buffer)
    for _, hunk in ipairs(entry.hunks) do
      local row = math.max(0, math.min(count - 1, hunk[3] - (hunk[4] > 0 and 1 or 0)))
      if hunk[4] > 0 then
        for current_row = row, math.min(count - 1, row + hunk[4] - 1) do
          if entry.ai_lines and entry.ai_lines[current_row + 1] then
            vim.api.nvim_buf_set_extmark(buffer, M.namespace, current_row, 0, {
              sign_text = "▎",
              sign_hl_group = "WeftAI",
              line_hl_group = "WeftAI",
              priority = 15,
            })
          end
        end
      else
        vim.api.nvim_buf_set_extmark(buffer, M.namespace, row, 0, {
          sign_text = "▾",
          sign_hl_group = "WeftRemoved",
          priority = 15,
          virt_text = { { "  " .. hunk[2] .. " removed · <leader>wo to inspect", "WeftRemoved" } },
        })
      end
    end
  end
end

function M.list(task)
  local entries = {}
  for _, entry in pairs(M.state(task).entries) do
    if entry.changed then
      table.insert(entries, entry)
    end
  end
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries
end

local function run_git(repository, args, callback)
  local command = { "git", "-C", repository.path }
  vim.list_extend(command, args)
  vim.system(command, { text = false }, vim.schedule_wrap(callback))
end

function M.scan(task, callback)
  local state = M.state(task)
  if state.scanning then
    return
  end
  state.scanning = true
  local candidates = {}
  for path in pairs(state.entries) do
    candidates[path] = true
  end
  for _, buffer in ipairs(buffers.list(task)) do
    if vim.bo[buffer].modified then
      candidates[vim.api.nvim_buf_get_name(buffer)] = true
    end
  end
  local function finish()
    local ok, error_message = pcall(function()
      for path in pairs(candidates) do
        M.refresh_file(task, M.capture(task, path))
      end
      M.save(task)
      require("weft.ui").refresh_changes(task)
    end)
    state.scanning = false
    if not ok then
      util.notify(tostring(error_message), vim.log.levels.ERROR)
    end
    if callback then
      callback()
    end
  end
  local function advance(index)
    local repository = task.repositories[index]
    if not repository then
      return finish()
    end
    run_git(repository, { "diff", "--name-only", "-z", repository.base, "--" }, function(diff)
      if diff.code ~= 0 then
        state.scanning = false
        util.notify("Cannot scan " .. repository.path .. ": " .. diff.stderr, vim.log.levels.ERROR)
        return
      end
      run_git(repository, { "ls-files", "--others", "--exclude-standard", "-z" }, function(untracked)
        for _, relative in
          ipairs(vim.split(diff.stdout .. (untracked.stdout or ""), "\0", { plain = true, trimempty = true }))
        do
          local path = repository.path .. "/" .. relative
          if store.repository(task, path) == repository then
            candidates[path] = true
          end
        end
        advance(index + 1)
      end)
    end)
  end
  advance(1)
end

function M.locations(task)
  local locations = {}
  for _, entry in ipairs(M.list(task)) do
    for index, hunk in ipairs(entry.hunks or {}) do
      table.insert(locations, { entry = entry, index = index, line = math.max(1, hunk[3]) })
    end
  end
  return locations
end

function M.jump(task, direction)
  local locations = M.locations(task)
  if #locations == 0 then
    return util.notify("No text changes in this task")
  end
  local path = vim.api.nvim_buf_get_name(0)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local chosen
  if direction > 0 then
    for _, location in ipairs(locations) do
      if location.entry.path > path or (location.entry.path == path and location.line > line) then
        chosen = location
        break
      end
    end
    chosen = chosen or locations[1]
  else
    for index = #locations, 1, -1 do
      local location = locations[index]
      if location.entry.path < path or (location.entry.path == path and location.line < line) then
        chosen = location
        break
      end
    end
    chosen = chosen or locations[#locations]
  end
  require("weft.ui").open_change(task, chosen.entry, chosen.index)
end

return M
