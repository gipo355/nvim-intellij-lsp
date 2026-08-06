---@mod intellij-lsp Neovim client for JetBrains' IntelliJ language server
---
--- Drives the `bin/intellij-server` launcher shipped with the "Java and Kotlin
--- by IntelliJ IDEA" extension, over plain stdio.
---
--- The actual client config lives in `lsp/intellij.lua` (a native Neovim 0.11+
--- `lsp/` runtimepath entry), so everything is overridable the standard way:
---
--- ```lua
--- vim.lsp.config('intellij', { init_options = { defaultSdk = '/opt/jdk-21' } })
--- ```
---
--- `setup()` is only needed to change options this plugin owns (server
--- location, workspace isolation, Kotlin coexistence) and to register commands.

local M = {}

---@class intellij.Opts
---@field server_dir? string Install root containing `bin/intellij-server`. Falls back to $INTELLIJ_SERVER_DIR, then $PATH.
---@field jvm_args? string[] Extra JVM flags, forwarded via `IJ_JAVA_OPTIONS`.
---@field jdk? string|false JDK used to resolve symbols in your code (not to run the server). Auto-detected when unset; `false` disables.
---@field jdk_version? integer Preferred JDK feature version for auto-detection, e.g. 21.
---@field kotlin? 'auto'|boolean Attach for Kotlin too. 'auto' yields to kotlin.nvim when installed.
---@field filetypes? string[] Override the computed filetype list entirely.
---@field root_markers? (string|string[])[] Priority-grouped root markers.
---@field build_tool? 'gradle'|'maven'|'bazel' Pinned per-root build system.
---@field workspace_dir? string Base directory for per-project `--system-path` isolation.
---@field inlay_hints? boolean Answer the server's hint settings with the VS Code defaults. Default true.
---@field bazel_projectview? string Path to a Bazel projectview file.
---@field bazel_build? boolean Let the server run Bazel builds.
---@field version? string Server build to install and prefer.
---@field accept_eula? boolean Declares acceptance of the bundled JetBrains agreement. Default false.
---@field data_sharing? 'none'|'anonymous'|'full' Telemetry level. Default 'none'.
---@field region? string Value for `INTELLIJ_REGION`. Unset by default.
---@field settings? table Merged over the default `settings` table.
---@field init_options? table Merged over the computed `init_options`.
---@field cmd_extra? string[] Extra arguments appended to the server argv.
---@field log_level? 'TRACE'|'DEBUG'|'INFO'|'WARN'|'ERROR' Server-side log verbosity (`--log-level`). Unset uses the server default.
---@field completion_fix? boolean Make command-driven completion behave like VS Code. Default true.
---@field uri_timeout_ms? integer How long to block while fetching jar://jrt:// sources. Default 5000.
---@field organize_imports_on_save? boolean Run the server's organize-imports action on :write. Default false.
---@field import_notify? boolean Notify when the project import finishes (the server sends no $/progress). Default true.
---@field isolate_index? boolean Keep the RocksDB index per project (init_options.indexDir) instead of the shared JetBrains cache. Default true.
---@field codelens? boolean Refresh code lenses on attach and after edits. Default true.

---@type intellij.Opts
local defaults = {
  server_dir = nil,
  jvm_args = {},
  jdk = nil,
  kotlin = 'auto',
  filetypes = nil,
  root_markers = nil,
  build_tool = nil,
  workspace_dir = nil,
  inlay_hints = true,
  bazel_projectview = nil,
  bazel_build = nil,
  version = nil,
  accept_eula = false,
  data_sharing = 'none',
  region = nil,
  settings = {},
  init_options = {},
  cmd_extra = {},
  log_level = nil,
  completion_fix = true,
  uri_timeout_ms = 5000,
  organize_imports_on_save = false,
  import_notify = true,
  isolate_index = true,
  codelens = true,
}

local options = vim.deepcopy(defaults)

---@return intellij.Opts
function M.options()
  return options
end

--- Configure and enable the IntelliJ language server.
---@param opts? intellij.Opts
function M.setup(opts)
  options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})

  require('intellij-lsp.commands').setup()

  -- Registers the nvim-dap adapter when nvim-dap is present; harmless no-op
  -- otherwise.
  require('intellij-lsp.dap').setup()

  -- Registered eagerly: a jar:// buffer can be opened by a jump from any
  -- buffer, including before the client has attached anywhere.
  require('intellij-lsp.decompiler').setup()

  -- Options must be stored before enabling: `lsp/intellij.lua` reads them the
  -- first time Neovim resolves the config, which enable() can trigger at once.
  vim.lsp.enable('intellij')
end

return M
