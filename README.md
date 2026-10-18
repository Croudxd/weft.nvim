# weft.nvim

Weft gives coding tasks an isolated Git worktree, an agent chat, a source view,
and a focused change list—all inside Neovim.

The agent edits ordinary files in a task worktree. You keep normal buffers, LSP,
search, terminals, and Git tooling; Weft tracks what changed and makes it easy
to review it.

## What it does

- Creates a Git worktree for every registered repository in a task.
- Keeps each task in its own Neovim tabpage and working directory.
- Provides an agent chat backed by any CodeCompanion adapter you configure.
- Shows changed files on the left, editable source in the centre, and chat on
the right.
- Marks AI-written and subsequently user-edited lines separately.
- Keeps task chats, snapshots, and change history outside source repositories.
- Compacts large chats before they become slow or reach provider context limits.

## Requirements

- Neovim 0.12+
- Git
- [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim)
- Tree-sitter `markdown` and `markdown_inline`
- An authenticated/configured CodeCompanion adapter for chat

Weft deliberately does **not** manage API keys or authentication. Configure
providers exactly as CodeCompanion documents. The included Lazy example uses the
community Codex OAuth adapter as a convenient ChatGPT default, but Weft can use
any configured CodeCompanion provider.

## Install

Copy [`examples/lazy.lua`](examples/lazy.lua) into your Lazy configuration. For
local development, point `dir` at your checkout.

If you already configure CodeCompanion, merge
`require("weft.agent").codecompanion_options()` into its options. Configure any
additional providers there; Weft discovers them from CodeCompanion.

## Start a task

Register each original repository once:

```vim
:Weft repo add ~/dev/app
:Weft repo add ~/dev/service
```

Create and open a task:

```vim
:Weft new fix-login
```

This creates sibling worktrees:

```text
~/dev/worktrees/
└── fix-login/             # task name
    ├── app/               # Git worktree for ~/dev/app
    └── service/           # Git worktree for ~/dev/service
```

Git shares object storage between a worktree and its original repository. The
extra disk use is primarily the checked-out files plus any dependencies/build
artefacts created inside the task. The AI does not create worktrees: Weft only
runs normal Git worktree commands after you explicitly create a task.

## Daily use

| Binding | Action |
| --- | --- |
| `<leader>ww` | Pick a task and open its workspace |
| `<leader>wW` | Open the Weft command centre |
| `<leader>wm` | Pick provider and model for this task |
| `<leader>wc` | Toggle chat |
| `<leader>wl` | Toggle changes |
| `<leader>wb` | Pick a task source buffer |
| `<leader>ws` | Send chat prompt |
| `<leader>wk` | Stop the agent |
| `<leader>wo` | Toggle previous-code preview |
| `<leader>wr` | Refresh changes |
| `]a` / `[a` | Next / previous changed hunk |

In chat, write below the final **Me** heading and press **Ctrl-S** to send.
The chat winbar shows when Weft is working or stopped. Chat displays concise
tool activity rather than raw hashes, tool JSON, or token bookkeeping.

`<leader>wm` (or `:Weft model`) first selects a configured CodeCompanion
provider, then one of that provider's models. The choice persists per task.
Provider authentication and model availability remain CodeCompanion's concern.

In the changes panel, **Enter** opens the selected file, `o` opens its previous
contents, `s` marks it reviewed, and `r` refreshes. Green line markers indicate
AI-written lines; purple markers identify later user edits. A deletion is shown
with a removal marker and can be inspected with `<leader>wo`.

## Configuration

```lua
require("weft").setup({
  worktree_root = "~/dev/worktrees",
  repositories = {},

  -- Default CodeCompanion provider/model for new task chats.
  adapter = "weft_codex",
  model = "gpt-5.3-codex",

  mappings = true,
  poll_interval = 2000, -- Set 0 to disable periodic Git reconciliation.

  -- Follow saved agent edits in the centre source view.
  open_changed_files = false,

  -- Do not override another tabline/bufferline plugin by default.
  tabline = false,

  context = {
    compact = true,
    compact_threshold = 0.75,
    edit_threshold = 0.6,
    keep_tool_cycles = 3,
  },

  -- Optional integration points:
  -- picker = function(items, options, callback) ... end,
  -- browser = function(root) ... end,
})
```

Weft uses, in order: a configured `picker`, Telescope when installed, then
`vim.ui.select`. Set `mappings = false` to define your own mappings with the
public Lua functions such as `require("weft").tasks()`, `.open()`, and `.menu()`.

When `open_changed_files = true`, a saved agent write opens its source buffer,
puts the cursor at the start of the write, and centres that line. It is disabled
by default so agents never steal focus unless you ask them to.

## Storage and performance

Task metadata, snapshots, and chat history live under
`vim.fn.stdpath("data") .. "/weft"`, not in your repositories.

The default `poll_interval` performs Git reconciliation every two seconds for
known tasks. For very large repositories or many historical tasks, set it to
`0`; agent writes and `<leader>wr` still refresh changes.

## Development and CI

The `tests/` directory is only development/CI code. Plugin managers load
`lua/weft/` at runtime; they do **not** load or run the test suite for users.
No test dependencies are included in a user's installed plugin.

```text
make test        # workspace/change integration tests
make test-chat   # CodeCompanion integration tests with a fake transport
make format      # requires stylua
```

GitHub Actions runs both test suites on pushes to `main` and pull requests.
