# weft.nvim

AI writes the code. You stay in Neovim and follow what changed.

Weft gives each coding task its own agent chat, Git worktrees, source buffers,
and change navigator. Inspect the actual editable files, jump through every
changed region, and open the previous code when you need it. No Git patch view
or Vim diff mode is required.

**Status: first working prototype.** Workspace isolation and the chat/tool loop
have integration tests; the interaction design is ready for hands-on iteration.

## Workspace layout

Register your original repositories once:

```text
~/dev/
├── app/
├── service/
├── infrastructure/
└── worktrees/
    ├── fix-timeouts/
    │   ├── app/              # branch weft/fix-timeouts
    │   ├── service/          # branch weft/fix-timeouts
    │   └── infrastructure/   # branch weft/fix-timeouts
    └── improve-retries/
        ├── app/
        ├── service/
        └── infrastructure/
```

Each task is a normal directory. Browse it with Yazi, a tree browser, or a
terminal. Every repository gets a worktree up front, starting at its original
checkout's current committed `HEAD`. Dirty original files stay in the original
checkout. Creating and switching tasks never commits or stashes your work.

## Requirements

- Neovim 0.12+
- Git, curl, OpenSSL, ripgrep, and bash
- Tree-sitter `markdown` and `markdown_inline` parsers
- A ChatGPT subscription supported by the community Codex OAuth adapter
- CodeCompanion and the OAuth adapter, pinned in the installation example

Weft uses CodeCompanion for chat and the agent loop, and
[cc-adapter-codex.nvim](https://github.com/viespejo/cc-adapter-codex.nvim) for
subscription authentication. No Codex CLI or OpenCode process is needed.

## Install with lazy.nvim

Copy the spec in [`examples/lazy.lua`](examples/lazy.lua) into your Neovim
configuration. It installs both chat dependencies and configures the Codex
adapter and Weft tools. For local development, set:

```lua
dir = vim.fn.expand("~/dev/weft.nvim"),
```

Keep the dependency pins while the integration is young. Weft's adapter loader
bridges the upstream adapter's older helper paths and positional handler
arguments to the pinned CodeCompanion version.

If you already configure CodeCompanion, merge
`require("weft.agent").codecompanion_options()` into that configuration once.
Weft's workspace layer can be used without chat dependencies.

## First task

```vim
:checkhealth weft
:Weft repo add ~/dev/app
:Weft repo add ~/dev/service
:Weft repo add ~/dev/infrastructure
:Weft auth
:Weft new fix-timeouts
:Weft open
```

Authenticate in your browser when prompted. Write an instruction below the last
**Me** heading in the chat and press **Ctrl-S** or **`<leader>ws`** to send it.
Saving a file does not submit
a prompt. Use **`<leader>wk`** to stop the current task's agent.

Chat shows short file/command activity summaries instead of raw tool JSON,
hashes, attachment bookkeeping, or token counts. Full tool results still reach
the agent. Markdown code blocks use Tree-sitter highlighting, including YAML
(install the `yaml` parser for YAML highlighting). Restoring an older chat cleans
its display while preserving the conversation and its unsent draft.

Sending a message resumes automatic scrolling to the newest response. Streaming
continues to scroll the chat when you switch to a source window, without taking
focus away from your code. Scrolling up to read earlier messages pauses following;
the next send resumes it.

Workspace tools are attached automatically to every task chat, including restored
chats. You do not need to enable workspace access or create another task to use
them; hiding context details does not detach the tools.

The default model is `gpt-5.3-codex`. Use **Space → W → M** (with a space
leader) or **`:Weft model`** to open the model picker. The current model is
labelled. You can also type **`:Weft model gpt-`** and press **Tab** to complete
the name, then Enter to switch. The choice persists for that task;
`:Weft model default` resets it to the configured default. The list combines
the adapter's catalogue with current public Codex models, including Astra
(`gpt-6-astra`), Sol, and Luna. Use **`:Weft model refresh`** to download the
latest official Codex catalogue and reopen the picker. The catalogue is cached
outside your repositories and is available offline. This is a public catalogue,
not an account-entitlement list; availability depends on your ChatGPT account.

Creating a task opens its full workspace automatically and focuses chat. If
you reach a task home buffer, press **Enter** to open the workspace.

**`<leader>ww`** opens a searchable task picker; choosing a task switches to it
and opens the full workspace (source/home in the centre, changes on the left,
and chat on the right). **`<leader>wW`** opens the searchable command centre.
With Telescope installed, all Weft pickers (tasks, buffers, models, and commands)
use Telescope; otherwise they use your configured `vim.ui.select` picker. Set
`picker` to provide any picker implementation you prefer. Previous-code previews
remain available on demand with `<leader>wo`.

Repository registration persists outside your project. `:Weft repo` lists the
configured originals; `:Weft repo remove NAME` removes a repository from future
tasks. Existing tasks keep their own repository sets.

## Inspecting changes

- **`<leader>wl`** opens a task-wide changed-file list, labelled by repository.
  Files show `A` (added), `M` (modified), `D` (deleted), `✓` (reviewed), or `!`
  (disk conflict), plus their directory and added/removed line counts. The cursor
  starts on the first file and stays on the selected file during refreshes.
- Every changed text file is loaded as a normal source buffer in the background.
  Your focus stays where it is.
- Press **Enter** on a file or its detail row to open and focus it; use
  **`]a` / `[a`** to move between changed regions across repositories.
- AI-written lines have the `WeftAI` tint. Lines you edit have the `WeftEdited`
  tint; unchanged AI lines keep their ownership as surrounding lines move.
- **`<leader>wo`** opens the code from before the task, with surrounding context.
  The source buffer remains a full, editable file with normal LSP navigation.
- Deletions get a small marker and an entry in the list. Deleted files keep
  their original text in the previous-code view.
- Press **s** in the changes list to mark a file's current revision as seen.
  Further edits make it unseen again. **o** opens previous code; **r** refreshes.

Snapshots use the task's starting commit, so follow-up prompts and commits made
inside the task don't erase earlier changes. AI file edits also record their
individual before/after contents in the task's history on disk.

### Working alongside the agent

File reads use the current buffer, including unsaved text. Writes require a
hash from the agent's read, so a stale edit is rejected rather than overwriting
your intervening changes. Changes to an already-dirty buffer remain unsaved;
changes to clean buffers are written to their task files. Commands wait for you
to save dirty source buffers before running, so they don't test stale disk code.

External disk edits reload clean buffers. When disk and an unsaved buffer
diverge, Weft preserves the buffer and marks the file with **!**. Reconcile the
versions and save before continuing agent edits.

## Task-local navigation

Each task has its own Neovim tabpage and tab-local working directory. Switching
to another task preserves its windows, buffers, cursor positions, and unsaved
edits during the editor session. Agents bind operations to their own workspace
paths, independently of the active tab.

Files opened through Yazi, a tree, `:edit`, or an LSP jump are associated by
their absolute task path. Opening another task's file from a task tab redirects
it into the owning task. **`<leader>wb`** lists only the current task's source
buffers. **Shift-H / Shift-L** cycle task-local source buffers when in one of
those buffers. Other plugins' global buffer pickers remain global unless you
configure their filters to use `vim.b[bufnr].weft_task`.

## Shortcuts

The default leader is whatever your Neovim configuration uses. All Weft leader
bindings are grouped under **w**, leaving existing AI plugin bindings alone.

| Binding | Action |
| --- | --- |
| `<leader>ww` | Pick task and open its full workspace |
| `<leader>wW` | Open searchable Weft command centre |
| `<leader>wm` | Pick task model |
| `<leader>wa` | Pick task / agent |
| `<leader>wn` | Create task / agent |
| `<leader>wc` | Toggle task chat |
| `<leader>wl` | Toggle changes list |
| `<leader>wb` | Pick task source buffer |
| `<leader>wo` | Toggle previous code |
| `<leader>we` | Browse workspace root with Yazi, or the default directory browser |
| `<leader>ws` | Send prompt |
| `<leader>wk` | Stop current agent |
| `<leader>wi` | Attach current task buffer to chat |
| `<leader>wr` | Refresh changes |
| `<leader>wx` | Hide current task view, preserving its buffer |
| `<leader>wp` | Return to last inspected change |
| `<leader>w?` | Toggle shortcut help |
| `]a` / `[a` | Next / previous changed region |
| `]b` / `[b` | Next / previous task source buffer |

`q` hides a Weft panel or chat. Hiding a view does not stop the agent or discard
its contents. Source files retain normal Neovim editing and close commands.

Set `mappings = false` and map the Lua functions yourself for a custom scheme.
Command equivalents include `:Weft tasks`, `chat`, `changes`, `buffers`,
`before`, `refresh`, `browse`, `send`, `stop`, `hide`, and `help`.

## Configuration

```lua
require("weft").setup({
  worktree_root = "~/dev/worktrees",
  state_dir = vim.fn.stdpath("data") .. "/weft",
  repositories = {}, -- Name -> absolute original repository path
  branch_prefix = "weft/",
  poll_interval = 2000, -- Milliseconds; 0 disables background reconciliation
  max_file_bytes = 1024 * 1024,
  command_timeout = 120000,
  model = "gpt-5.3-codex",
  mappings = true,
  open_changed_files = false, -- Set true to focus each agent-written file as it is saved
  tabline = false, -- Set true for Weft's task-named built-in tabline
  context = {
    compact = true, -- Summarize safely before long chats slow down or overflow
    compact_threshold = 0.75, -- Fraction of the model context window
    edit_threshold = 0.6, -- Trim old tool outputs before compacting
    keep_tool_cycles = 3,
  },
  -- picker = function(items, options, callback) ... end, -- Optional picker integration
  -- browser = function(root) ... end, -- Override workspace-root browsing
})
```

Chats, baseline snapshots, and edit history live under `state_dir`. The OAuth
adapter maintains its own authentication storage. Weft does not store tokens
inside task repositories.

## Prototype boundaries

- Configured repositories are assembled as **siblings**. Independent nested
  repositories aren't discovered or recreated automatically yet. Submodules are
  rejected during task preflight rather than starting an incomplete workspace.
- Changes from shell commands are reconciled through Git, including untracked
  files. Ignored files are tracked when edited through Weft's file tool;
  arbitrary shell-created ignored files aren't automatically discovered.
- Task and chat history persist across restarts. Exact window layouts and
  unsaved source contents currently survive task switches within one Neovim
  process, not editor restarts.
- Binary files, symlinks, and files above the text-size limit get list entries
  rather than editable text previews.
- Previous-code previews currently show the **task baseline**. The edit history
  is recorded, but a per-turn history picker isn't implemented yet.
- Bringing tasks back to original branches, conflict resolution, task removal,
  and turn-level undo are still to build. Ordinary Git commands work in every
  task repository in the meantime.
- File tools enforce workspace-relative paths. Shell commands have an explicit
  task working directory but are ordinary host processes, not a filesystem
  sandbox. Worktrees isolate checkouts, not external services or absolute paths.

## Development

```sh
make test        # Real temporary repositories; workspace and change invariants
make test-chat   # Real CodeCompanion and adapter, with a fake model transport
make format     # Requires stylua
```

Chat tests look for dependencies under Neovim's lazy.nvim data directory. Set
`WEFT_DEPENDENCIES` to another directory containing those plugin checkouts.
Tests exercise concurrent tool loops and cancellation without making model
requests or opening OAuth. A live ChatGPT session still needs manual sign-in
and end-to-end testing.
