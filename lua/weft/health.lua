local M = {}

function M.check()
  vim.health.start("Weft")
  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim 0.12+")
  else
    vim.health.error("Neovim 0.12+ is required")
  end
  for _, executable in ipairs({ "git", "curl", "openssl", "rg", "bash" }) do
    if vim.fn.executable(executable) == 1 then
      vim.health.ok(executable .. " available")
    else
      vim.health.error("Missing " .. executable)
    end
  end
  for _, language in ipairs({ "markdown", "markdown_inline" }) do
    local ok = pcall(vim.treesitter.language.add, language)
    if ok then
      vim.health.ok(language .. " parser")
    else
      vim.health.error("Install Tree-sitter parser: " .. language)
    end
  end
  local config = require("weft").config
  if not config then
    return vim.health.error("Call require('weft').setup() first")
  end
  vim.health.info("Worktrees: " .. config.worktree_root)
  vim.health.info("State: " .. config.state_dir)
  local repositories = require("weft.store").repositories
  if vim.tbl_isempty(repositories) then
    vim.health.warn("No repositories registered. Use :Weft repo add <path>")
  end
  for name, path in pairs(repositories) do
    local ok = pcall(require("weft.util").git, path, { "rev-parse", "--show-toplevel" })
    if ok then
      vim.health.ok(name .. " → " .. path)
    else
      vim.health.error("Cannot open repository " .. path)
    end
  end
end

return M
