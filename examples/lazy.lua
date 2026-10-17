return {
  "Croudxd/weft.nvim",
  -- For development, uncomment and point at your checkout:
  -- dir = vim.fn.expand("~/dev/weft.nvim"),
  lazy = false,
  dependencies = {
    {
      "olimorris/codecompanion.nvim",
      commit = "799526fb35548c26e2dd74c3b282537bb8122a3b",
      dependencies = {
        "nvim-lua/plenary.nvim",
        { "viespejo/cc-adapter-codex.nvim", commit = "ce565d3da357e99ecabc9db0558c8bea42158c32" },
      },
      opts = function()
        return require("weft.agent").codecompanion_options()
      end,
    },
  },
  opts = {
    worktree_root = "~/dev/worktrees",
    repositories = {}, -- Or register originals using :Weft repo add /path/to/repo
  },
}
