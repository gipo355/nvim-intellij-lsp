# nvim-intellij-lsp

> [!WARNING]
> Experimental. The jb server is in preview, and the plugin is a first attempt. Can have breaking changes.
>
> Please provide feedback upstream to JB.
>
> Made with ai.

Neovim client for JetBrains' IntelliJ language server — the one behind the
["Java and Kotlin by IntelliJ IDEA"](https://open-vsx.org/extension/JetBrains/intellij-server)
extension (`JetBrains.intellij-server`).

The server is a standalone process that speaks LSP over stdio via a
`bin/intellij-server` launcher with its own bundled JBR, so nothing about it is
VS Code-specific. This plugin is the Neovim side of that conversation.

> **Status: working.** Verified against a real Gradle project — initialized with
> completion, hover and diagnostics. See [HANDOFF.md](HANDOFF.md) for the full
> picture, every gotcha, and what's next.

## Requirements

- Neovim **0.11+** (0.12 recommended)
- `curl` and `tar` (or `unzip`) for `:IntellijInstall`
- A JDK for symbol resolution (the server itself runs on its bundled JBR)

## Install

With `vim.pack` (Neovim 0.12):

```lua
vim.pack.add({ 'https://github.com/gipo355/nvim-intellij-lsp' })
require('intellij-lsp').setup({ server_dir = '~/.local/share/intellij-server' })
```

With lazy.nvim:

```lua
{
  'gipo355/nvim-intellij-lsp',
  opts = { server_dir = '~/.local/share/intellij-server' },
}
```

`setup()` is optional. The plugin ships a native `lsp/intellij.lua`, so this
works too — including every standard override:

```lua
vim.lsp.config('intellij', { init_options = { defaultSdk = '/opt/jdk-21' } })
vim.lsp.enable('intellij')
```

## Getting the server

```vim
:IntellijInstall        " download + verify the server
:IntellijAcceptEula     " the server refuses to initialize without this
```

The VSIX on Open VSX is a 1.4 MB shim containing no server at all — the
extension downloads a tarball from JetBrains on first launch, and so do we:

```
https://download.jetbrains.com/language-server/intellij-server/263.2689.0/intellij-server-263.2689.0.tar.gz
```

Note the host is `download.jetbrains.com`, *not* the `download-cdn.` host Mason
uses for kotlin-server — that one 404s for this product. Only the linux-x64
archive name is confirmed; the other platforms follow kotlin-server's suffix
scheme (`-aarch64`, `.sit`, `.win.zip`) and will report the URL they tried if
the guess is wrong.

Already have one extracted? Point at it instead:

```lua
require('intellij-lsp').setup({ server_dir = '~/.local/share/intellij-server' })
-- or export INTELLIJ_SERVER_DIR=~/.local/share/intellij-server
```

Then `:checkhealth intellij-lsp`. `scripts/recon.sh` regenerates everything in
`recon/` if you want to re-derive this against a newer build.

## Options

```lua
require('intellij-lsp').setup({
  server_dir = nil,        -- install root with bin/intellij-server; else $INTELLIJ_SERVER_DIR, else $PATH
  jdk = nil,               -- JDK used to resolve symbols in your code
  jvm_args = {},           -- e.g. { '-Xmx4g' }, forwarded via IJ_JAVA_OPTIONS
  kotlin = 'auto',         -- 'auto' yields Kotlin buffers to kotlin.nvim; true forces, false disables
  build_tool = nil,        -- 'gradle' | 'maven' | 'bazel'
  inlay_hints = true,      -- answer the server's hint settings with the VS Code defaults
  bazel_projectview = nil, -- path to a Bazel projectview file
  version = nil,           -- server build to install and prefer
  data_sharing = 'none',   -- 'none' | 'anonymous' | 'full', via INTELLIJ_DATA_SHARING
  region = nil,            -- via INTELLIJ_REGION
  root_markers = nil,      -- priority-grouped; workspace files beat per-module build files
  workspace_dir = nil,     -- base dir for per-project --system-path isolation
  settings = {},           -- merged over defaults, flat 'jetbrains.*' keys
  init_options = {},
  cmd_extra = {},
  log_level = nil,         -- 'DEBUG' etc., forwarded as --log-level
  organize_imports_on_save = false,
  import_notify = true,    -- notify when the project import lands (no $/progress exists)
  completion_fix = true,   -- see below
})
```

## Commands

| Command | Effect |
| --- | --- |
| `:IntellijInstall [version]` | Download the server from JetBrains |
| `:IntellijAcceptEula` | Show the bundled agreement and record acceptance |
| `:IntellijRestart` | Stop and re-attach the server |
| `:IntellijCleanWorkspace` | Delete this project's server state |
| `:IntellijCleanWorkspace!` | …and the shared JetBrains analyzer cache |
| `:IntellijStatus` | Show attached clients and roots |
| `:IntellijLog` | Open the server's own log (first stop when debugging) |
| `:IntellijRun [args]` | Run the current buffer's main class (classpath resolved by the server) |
| `:IntellijOrganizeImports` | Organize imports in the current buffer |
| `:IntellijPrune` | Delete all but the newest ~1 GB server install |
| `:checkhealth intellij-lsp` | Diagnose launcher, JDK, workspace, **import state**, disk, conflicts |

## Notes on the server's quirks

Three things are not obvious and are handled for you:

**The index is shared, so run one Neovim per project.** `--system-path` holds
only a lock file and a small `system/` directory; the real RocksDB index lives in
`~/.cache/JetBrains/analyzer/workspaces/<md5-of-project-path>/`, keyed by project
and shared across instances. A second Neovim on the same root fails with
`LOCK: Resource temporarily unavailable`. `:IntellijCleanWorkspace!` clears both
when a stale lock survives a crash.

**The EULA is enforced by the server.** It refuses to initialize until the client
passes `initializationOptions.eulaHash` — the first 16 hex chars of
`sha256(EULA.txt)` from the server root. `:IntellijAcceptEula` shows the text and
records your acceptance; nothing is accepted on your behalf. A new server build
means a new hash and a fresh acceptance.

**Completion is command-driven.** Items come back with an *empty* `textEdit`
plus a `jetbrains.*.completion.apply` command; the server performs the real
insertion through `workspace/applyEdit` and places the caret via
`window/showDocument`. VS Code's client inserts nothing and just runs the
command. Neovim frontends insert the label first, so the server's edit lands on
top of already-inserted text and the caret ends up mid-identifier. We neutralise
the client-side insertion into a no-op so the server's diff applies cleanly.
Disable with `completion_fix = false`.

*Newer builds (263.2689.0+) ship real `textEdit`s for plain items — the
workaround detects that and stays out of the way. Postfix templates
(`.var` & co) additionally carry a VS Code-only `runCommands` follow-up,
which is translated (their rename step becomes `vim.lsp.buf.rename()`).*

**Configuration is pulled, not pushed.** The server requests its settings via
`workspace/configuration` by section; inlay hints do nothing without an answer.
Flat `jetbrains.*` keys in `settings` are reassembled into the nested objects
the server asks for.

## Development

Point your plugin manager at the checkout instead of the GitHub URL and every
edit is live on the next restart:

```lua
-- lazy.nvim
{
  dir = '~/code/nvim-intellij-lsp',  -- your clone
  ft = { 'java', 'kotlin' },         -- required with lazy = true, or nothing loads
  opts = {},
}

-- vim.pack / manual: just put the clone on the runtimepath
vim.opt.rtp:prepend('~/code/nvim-intellij-lsp')
require('intellij-lsp').setup({})
```

Things to know before hacking:

- `:checkhealth intellij-lsp` first, `:IntellijLog` second — nearly every
  "nothing works" is a failed project import, and the health check now says so
  outright.
- **One Neovim per project root** (shared index, see the notes below). For
  scripted testing, run headless nvim against a project your editor does *not*
  have open, and stop the client before exiting or the orphaned server keeps
  the index lock.
- `HANDOFF.md` is the knowledge base — read §2 and §6 before debugging
  anything, and record what you learn there; that's the contract.
- `scripts/recon.sh` re-derives every fact taken from the VS Code extension
  (reports land in `recon/`, kept out of git deliberately — they embed
  JetBrains' own files). `scripts/probe.lua` is a headless LSP probe
  harness: `PROBE_FILE=<java file> nvim --headless --clean -l scripts/probe.lua caps`.

## Relationship to kotlin.nvim

[kotlin.nvim](https://github.com/AlexandrosAlexiou/kotlin.nvim) covers the
Apache-2.0 [kotlin-lsp](https://github.com/Kotlin/kotlin-lsp) through the same
`bin/intellij-server` launcher. If it is installed, `kotlin = 'auto'` (the
default) leaves Kotlin buffers to it and this plugin takes Java only. Set
`kotlin = true` to have one server handle both.

Credit where due: kotlin.nvim documented the completion and workspace pitfalls
above first. The implementations here are our own.

## Licensing

The extension is free during preview, with builds expiring 30 days after
release. JetBrains has said an IntelliJ IDEA Ultimate subscription will be
required from 1.0, covering the desktop IDE and other environments alike. For
pure-Kotlin work, kotlin-lsp is Apache 2.0 and free.

This plugin is MIT. It ships no JetBrains code.

Not affiliated with or endorsed by JetBrains. IntelliJ and JetBrains are
trademarks of JetBrains s.r.o.
