local util = require("weft.util")
local M = { views = {}, last = {} }
local changes_namespace = vim.api.nvim_create_namespace("weft-changes-panel")

local function views(task)
  M.views[task.id] = M.views[task.id] or {}
  return M.views[task.id]
end

local function window(task, kind)
  local view = views(task)[kind]
  if
    view
    and view.window
    and vim.api.nvim_win_is_valid(view.window)
    and vim.api.nvim_win_get_buf(view.window) == view.buffer
  then
    return view.window
  end
end

function M.hide(task, kind)
  local win = window(task, kind)
  if not win then
    return false
  end
  if #vim.api.nvim_tabpage_list_wins(0) == 1 then
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
  else
    vim.api.nvim_win_close(win, true)
  end
  views(task)[kind].window = nil
  return true
end

local function scratch(task, kind, lines)
  local existing = views(task)[kind]
  local buffer = existing and existing.buffer
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buffer, "weft://" .. task.id .. "/" .. kind)
  end
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  vim.b[buffer].weft_task = task.id
  vim.b[buffer].weft_view = kind
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.keymap.set("n", "q", function()
    M.hide(task, kind)
  end, { buffer = buffer, desc = "Hide Weft view" })
  return buffer
end

function M.home(task)
  local lines = {
    "Weft · " .. task.name,
    "",
    "Workspace: " .. task.root,
    "",
    "Repositories:",
  }
  for _, repository in ipairs(task.repositories) do
    table.insert(lines, "  " .. repository.name .. " · " .. repository.branch)
  end
  vim.list_extend(lines, {
    "",
    "Press Enter to open the full workspace.",
    "",
    "<leader>ww  Pick task / open workspace",
    "<leader>wW  Weft command centre",
    "<leader>wc  Chat",
    "<leader>wl  Changes",
    "<leader>wb  Task buffers",
    "<leader>we  Browse workspace",
    "<leader>w?  All shortcuts",
  })
  local buffer = scratch(task, "home", lines)
  vim.api.nvim_win_set_buf(0, buffer)
  views(task).home = { buffer = buffer, window = vim.api.nvim_get_current_win() }
  vim.keymap.set("n", "<CR>", util.guard(function()
    require("weft").open(task)
  end), { buffer = buffer, desc = "Open Weft workspace" })
end

function M.source(task, buffer)
  if vim.t.weft_task ~= task.id then
    require("weft.workspace").switch(task)
  end
  local destination
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local candidate = vim.api.nvim_win_get_buf(win)
    if vim.bo[candidate].buftype == "" or vim.b[candidate].weft_view == "home" then
      destination = win
      break
    end
  end
  if not destination then
    vim.cmd("aboveleft vsplit")
    destination = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(destination)
  vim.api.nvim_win_set_buf(destination, buffer)
  vim.wo[destination].signcolumn = "yes:1"
end

function M.open_change(task, entry, index)
  index = index or 1
  M.last[task.id] = { entry = entry, index = index }
  if entry.deleted or entry.binary then
    return M.before(task, entry, index)
  end
  M.source(task, require("weft.buffers").load(task, entry.path))
  local hunk = entry.hunks and entry.hunks[index]
  local line = hunk and math.max(1, hunk[3]) or 1
  line = math.min(line, vim.api.nvim_buf_line_count(0))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! zz")
end

function M.refresh_changes(task)
  local view = views(task).changes
  if not view or not vim.api.nvim_buf_is_valid(view.buffer) then
    return
  end
  local win = window(task, "changes")
  local cursor = win and vim.api.nvim_win_get_cursor(win)[1]
  local selected = cursor and view.rows and view.rows[cursor]
  view.entries = require("weft.changes").list(task)
  view.rows = {}
  local count = #view.entries
  local lines = {
    "  Changes",
    "  " .. task.name .. " · " .. count .. (count == 1 and " file" or " files"),
    "",
    "  Enter open  ·  o before",
    "  s reviewed  ·  r refresh",
    "",
  }
  local highlights = { { 0, "Title" }, { 1, "Comment" }, { 3, "Comment" }, { 4, "Comment" } }
  local repository, first_row, selected_row
  for _, entry in ipairs(view.entries) do
    local relative = entry.path:sub(#task.root + 2)
    local repo, path = relative:match("^([^/]+)/(.+)$")
    repo, path = repo or "Files", path or relative
    if repo ~= repository then
      if repository then
        table.insert(lines, "")
      end
      table.insert(lines, "  " .. repo .. "/")
      table.insert(highlights, { #lines - 1, "Directory" })
      repository = repo
    end
    local status = entry.disk_conflict and "!"
      or entry.seen_hash == entry.current_hash and "✓"
      or entry.deleted and "D"
      or not entry.existed and "A"
      or "M"
    local group = entry.disk_conflict and "DiagnosticError"
      or entry.seen_hash == entry.current_hash and "Comment"
      or entry.deleted and "DiffDelete"
      or not entry.existed and "DiffAdd"
      or "DiffChange"
    table.insert(lines, "  " .. status .. " " .. vim.fs.basename(path))
    view.rows[#lines] = entry
    first_row = first_row or #lines
    if selected and selected.path == entry.path then
      selected_row = #lines
    end
    table.insert(highlights, { #lines - 1, group, 2, 3 + (status == "✓" and 2 or 0) })
    local added, removed = 0, 0
    for _, hunk in ipairs(entry.hunks or {}) do
      removed, added = removed + hunk[2], added + hunk[4]
    end
    local directory = vim.fs.dirname(path)
    local detail = entry.disk_conflict and "disk conflict"
      or entry.deleted and "deleted"
      or entry.binary and "binary / large"
      or ("+" .. added .. " −" .. removed)
    if directory ~= "." then
      detail = directory .. "/  ·  " .. detail
    end
    table.insert(lines, "    " .. detail)
    view.rows[#lines] = entry
    table.insert(highlights, { #lines - 1, "Comment" })
  end
  if #view.entries == 0 then
    table.insert(lines, "  No changes yet")
  end
  vim.bo[view.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(view.buffer, 0, -1, false, lines)
  vim.bo[view.buffer].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.buffer, changes_namespace, 0, -1)
  for _, mark in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(view.buffer, changes_namespace, mark[1], mark[3] or 0, {
      end_col = mark[4] or #lines[mark[1] + 1],
      hl_group = mark[2],
    })
  end
  if win and first_row then
    vim.api.nvim_win_set_cursor(
      win,
      { selected_row or (not view.positioned and first_row) or math.min(cursor, #lines), 0 }
    )
    view.positioned = true
  end
end

function M.changes(task, options)
  if options and options.open and window(task, "changes") then
    return
  end
  if M.hide(task, "changes") then
    return
  end
  local buffer = scratch(task, "changes", {})
  local width = math.min(42, math.max(20, math.floor(vim.o.columns * 0.24)))
  vim.cmd("topleft " .. width .. "vsplit")
  vim.api.nvim_win_set_buf(0, buffer)
  views(task).changes = { buffer = buffer, window = vim.api.nvim_get_current_win() }
  for option, value in pairs({
    number = false,
    relativenumber = false,
    wrap = false,
    cursorline = true,
    signcolumn = "no",
    foldcolumn = "0",
    statuscolumn = "",
    winfixwidth = true,
    spell = false,
  }) do
    vim.wo[option] = value
  end
  local function selected()
    return views(task).changes.rows[vim.api.nvim_win_get_cursor(0)[1]]
  end
  local function map(key, callback)
    vim.keymap.set(
      "n",
      key,
      util.guard(function()
        local entry = selected()
        if entry then
          callback(entry)
        end
      end),
      { buffer = buffer, desc = "Weft changes: " .. key, nowait = true }
    )
  end
  map("<CR>", function(entry)
    M.open_change(task, entry)
  end)
  map("o", function(entry)
    M.before(task, entry, 1)
  end)
  map("s", function(entry)
    entry.seen_hash = entry.current_hash
    require("weft.changes").save(task)
    M.refresh_changes(task)
  end)
  vim.keymap.set("n", "r", function()
    require("weft.changes").scan(task)
  end, { buffer = buffer })
  M.refresh_changes(task)
  require("weft.changes").scan(task)
end

function M.open(task)
  require("weft.workspace").switch(task)
  local has_source = false
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buffer = vim.api.nvim_win_get_buf(win)
    if
      vim.b[buffer].weft_task == task.id
      and (vim.bo[buffer].buftype == "" or vim.b[buffer].weft_view == "home")
    then
      has_source = true
      break
    end
  end
  if not has_source then
    local buffer = require("weft.buffers").list(task)[1]
    if buffer then
      M.source(task, buffer)
    else
      vim.cmd("aboveleft vsplit")
      M.home(task)
    end
  end
  M.changes(task, { open = true })
  require("weft.agent").toggle(task, { open = true })
end

function M.before(task, entry, index)
  local was_open = M.hide(task, "before")
  if was_open and not entry then
    return
  end
  if not entry then
    local path = vim.api.nvim_buf_get_name(0)
    entry = require("weft.changes").state(task).entries[path]
    if entry then
      local cursor = vim.api.nvim_win_get_cursor(0)[1]
      index = 1
      for i, hunk in ipairs(entry.hunks or {}) do
        if math.max(1, hunk[3]) <= cursor then
          index = i
        end
      end
    end
  end
  if not entry then
    return util.notify("Put the cursor in a changed file first")
  end
  local hunk = entry.hunks and entry.hunks[index or 1]
  local all = util.lines(entry.before)
  local first = hunk and math.max(1, hunk[1] - 10) or 1
  local last = hunk and math.min(#all, hunk[1] + hunk[2] + 10) or #all
  local lines = entry.binary and { "Binary or large file; text preview unavailable." }
    or not entry.existed and { "New file — no previous contents." }
    or vim.list_slice(all, first, last)
  if #lines == 0 then
    lines = { "Previously empty file." }
  end
  local buffer = scratch(task, "before", lines)
  vim.bo[buffer].filetype = vim.filetype.match({ filename = entry.path }) or ""
  pcall(vim.treesitter.start, buffer)
  local width = math.max(20, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.5)))
  local win = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = 2,
    col = math.max(0, vim.o.columns - width - 3),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Before task · " .. vim.fs.basename(entry.path) .. ":" .. first .. " ",
  })
  views(task).before = { buffer = buffer, window = win }
end

function M.help(task)
  if M.hide(task, "help") then
    return
  end
  local lines = { "Weft shortcuts", "" }
  for _, binding in ipairs(require("weft").bindings) do
    table.insert(lines, string.format("%-16s %s", binding[1], binding[3]))
  end
  local buffer = scratch(task, "help", lines)
  local win = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = 2,
    col = 3,
    width = math.min(76, vim.o.columns - 6),
    height = math.min(#lines, vim.o.lines - 6),
    style = "minimal",
    border = "rounded",
    title = " Weft ",
  })
  views(task).help = { buffer = buffer, window = win }
end

return M
