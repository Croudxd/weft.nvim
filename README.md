# weft.nvim

**Let an agent change code without losing track of what it touched.**

Weft is a Neovim workflow for agent-assisted coding. It gives a coding job its
own Git worktree, chat, changed-file list, and source windows. You work with
ordinary editable files, normal LSP navigation, your usual terminal, and your
usual Git commands—not a patch-only review screen.

## Why use Weft?

Most coding agents can edit whichever directory you point them at. That is fast,
but it is easy to lose your place or accidentally mix agent work with the branch
you were already using.

Weft makes the safe thing convenient:

- Your original checkout is left alone.
- Agent edits happen in a separate Git worktree on a separate branch.
- Every task has its own Neovim tab, chat, changed-file list, and working
  directory.
- You can open and edit the actual resulting files in the centre pane.
- If work later crosses into another repository, add it to the same task without
  restarting the conversation.
- The agent never creates worktrees or expands task scope by itself. Those are
  explicit actions you confirm in Neovim.

It is useful when you want the convenience of an agent without giving up a clean
working tree or the ability to inspect every change as it happens.

## What a task looks like

A task is a folder containing the worktrees it is allowed to use. Most tasks
start with one repository:

```text
~/dev/worktrees/fix-chat-scroll/       # one Weft task
└── weft.nvim/                         # an isolated Git worktree
```

If the task later needs another repository, add it explicitly:

```text
~/dev/worktrees/fix-chat-scroll/
├── weft.nvim/                         # first repository
└── quantum/                           # added later to the same task
```

The chat can then work across both repositories. It still cannot touch your
original checkouts or another task's worktrees:

```text
~/dev/weft.nvim/                       # original checkout: untouched
~/dev/quantum/                         # original checkout: untouched
~/dev/worktrees/another-task/          # another task: inaccessible
```

Git shares object storage with the original checkout, so a worktree is not a
second copy of repository history. Extra disk usage is mainly checked-out files
and anything created inside the worktree such as build artefacts or dependencies.

## Requirements

- Neovim 0.12+
- Git
- [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim)
- Tree-sitter parsers for `markdown` and `markdown_inline`
- A configured CodeCompanion provider for chat

Weft does **not** manage API keys or provider login. Configure providers exactly
as CodeCompanion documents. The bundled Lazy example includes Codex OAuth as a
convenient ChatGPT default, but Weft can use any CodeCompanion adapter you have
configured.

## Install

Copy [`examples/lazy.lua`](examples/lazy.lua) into your Lazy configuration.
Then run `:Lazy sync`.

If you already configure CodeCompanion, merge
`require("weft.agent").codecompanion_options()` into its options. Additional
providers belong in that existing CodeCompanion configuration; Weft discovers
and offers them in its provider/model picker.

## First task

### 1. Register a repository

Open the Weft command centre with **`<leader>wW`** and choose:

```text
Repositories → Add repository
```

Enter the path to the repository root. This only records the original checkout
as an available source for future tasks; it does not create a worktree or change
the repository.

The command-line equivalent is:

```vim
:Weft repo add ~/dev/weft.nvim
```

### 2. Create a task

Press **`<leader>wn`**:

```text
New task name: fix-chat-scroll
Choose repository: weft.nvim
```

Weft creates a branch named `weft/fix-chat-scroll` and its isolated worktree
under your configured `worktree_root`, then opens a new tab with:

```text
┌──────────────┬────────────────────────────┬─────────────────────┐
│ Changes      │ Source file                │ Weft chat           │
│              │ normal editable buffer     │ write below “Me”    │
│ Enter = open │ normal LSP and navigation  │ Ctrl-S = send       │
└──────────────┴────────────────────────────┴─────────────────────┘
```

### 3. Work normally

Write a request below the final **Me** heading in chat and press **Ctrl-S**.
The agent updates the worktree; Weft updates the changed-file list and marks
agent-written lines green. The chat winbar shows `● working` while it is active.

Open any changed file with **Enter** in the changes pane. You are looking at a
normal source buffer, so use your usual motions, LSP commands, search, terminal,
and Git tooling.

## When a task needs another repository

Suppose you begin in `etrading`, then discover the change also needs `quantum`.
You do **not** need a new task or chat.

Press **`<leader>wA`** in the task, choose `quantum`, and Weft creates a sibling
worktree inside the current task. The active chat keeps its conversation and is
updated with the new repository scope.

This is intentionally deterministic plugin code. The model can suggest that a
second repository is needed, but it cannot add a repository, create a branch, or
run Git worktree lifecycle operations on its own.

## Daily shortcuts

Your leader key is whatever your Neovim setup uses.

| Binding | Action |
| --- | --- |
| `<leader>wW` | Open the Weft command centre |
| `<leader>ww` | Pick and open an existing task |
| `<leader>wn` | Create a task |
| `<leader>wA` | Add a registered repository to the current task |
| `<leader>wm` | Choose provider and model for the current task |
| `<leader>wc` | Toggle chat |
| `<leader>ws` | Send the task chat prompt |
| `<leader>wk` | Stop the running agent |
| `<leader>wl` | Toggle the changes pane |
| `<leader>wb` | Pick a source buffer belonging to the task |
| `<leader>wo` | Show code from before the task started |
| `<leader>wr` | Re-scan changes from disk/Git |
| `]a` / `[a` | Next / previous changed hunk |

Inside the changes pane:

| Key | Action |
| --- | --- |
| `Enter` | Open the file or hunk under the cursor |
| `o` | Open its previous contents |
| `s` | Mark the current file revision as reviewed |
| `r` | Refresh the list |

Green markers show lines written through the agent. Other changed lines are left
uncoloured rather than being guessed as “user edits.” Removed lines have a small
removal marker; use `<leader>wo` to inspect their previous contents.

## Models and providers

Use **`<leader>wm`** or `:Weft model`:

```text
Choose provider → choose model → continue this task
```

The choice is saved per task. Weft uses your configured CodeCompanion adapters;
provider authentication and available model lists remain CodeCompanion's job.

## Configuration

```lua
require("weft").setup({
  -- Where task folders are created.
  worktree_root = "~/dev/worktrees",

  -- Registered repositories can also be added through the command centre.
  repositories = {},

  -- Default CodeCompanion provider/model for a new task chat.
  adapter = "weft_codex",
  model = "gpt-5.3-codex",

  mappings = true,

  -- Agent writes refresh immediately. Keep this at 0 unless you specifically
  -- want repeated Git scans to notice unrelated external changes.
  poll_interval = 0,

  -- Follow saved agent writes in the source pane. Disabled by default so an
  -- agent does not move your focus unless you ask for it.
  open_changed_files = false,

  -- Use Weft's simple task-named tabline. Off by default so it does not replace
  -- another tabline/bufferline plugin.
  tabline = false,

  context = {
    compact = true,
    compact_threshold = 0.75,
    edit_threshold = 0.6,
    keep_tool_cycles = 3,
  },

  -- Optional integrations:
  -- picker = function(items, options, callback) ... end,
  -- browser = function(root) ... end,
})
```

For selection UIs, Weft uses your `picker` callback when supplied, otherwise
Telescope when installed, otherwise `vim.ui.select`. Set `mappings = false` to
provide your own mappings using public functions such as
`require("weft").tasks()`, `.new()`, `.open()`, and `.menu()`.

When `open_changed_files = true`, a saved agent write opens its source buffer,
places the cursor at the start of the write, and centres that line.

## Storage and performance

Task metadata, baseline snapshots, and chat history are stored outside your
repositories under:

```text
vim.fn.stdpath("data") .. "/weft"
```

Weft does not poll Git by default, so it does not add periodic editor work while
you type. Agent writes refresh immediately. If files change outside Weft—through
a terminal, formatter, or another editor—press `<leader>wr` to reconcile them.

## Development

The `tests/` directory is development and CI code only. Plugin managers load
`lua/weft/` at runtime; users do not run the test suite or install test-only
dependencies.

```text
make test        # workspace/change integration tests
make test-chat   # CodeCompanion integration tests with a fake transport
make format      # requires stylua
```

GitHub Actions runs both test suites on pushes to `main` and pull requests.
