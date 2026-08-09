---@mod intellij-lsp.config The client config consumed by `lsp/intellij.lua`

local M = {}

--- root_dir per client id, for releasing the instance claim on exit.
local claimed_roots = {}

--- Roots whose readiness the server has announced (`intellij/ready-for-test`),
--- so the log watcher doesn't produce a second toast for the same import.
local announced = {}

--- Workspace markers win over per-module build files so multi-module projects
--- resolve to a single root and start one server instead of one per module.
local DEFAULT_ROOT_MARKERS = {
  { 'settings.gradle', 'settings.gradle.kts', 'MODULE.bazel', 'WORKSPACE', 'WORKSPACE.bazel', 'mvnw', 'mvnw.cmd' },
  { 'build.gradle', 'build.gradle.kts', 'pom.xml', 'BUILD.bazel', 'BUILD' },
  { '.git' },
}

--- True when something else already owns Kotlin buffers: kotlin.nvim on the
--- runtimepath, or lspconfig's `kotlin_lsp` enabled. Either way it is an
--- IntelliJ server of its own, and two of those is ~2 GB of duplicate index.
---@return boolean
local function kotlin_server_claimed()
  if
    #vim.api.nvim_get_runtime_file('lua/kotlin.lua', false) > 0
    or #vim.api.nvim_get_runtime_file('lua/kotlin/init.lua', false) > 0
  then
    return true
  end
  -- vim.lsp.is_enabled is newer than the 0.11 floor this plugin supports.
  return type(vim.lsp.is_enabled) == 'function' and vim.lsp.is_enabled('kotlin_lsp')
end

---@param opts intellij.Opts
---@return string[]
local function filetypes(opts)
  if opts.filetypes then
    return opts.filetypes
  end

  local want_kotlin = opts.kotlin
  if want_kotlin == 'auto' then
    want_kotlin = not kotlin_server_claimed()
  end

  return want_kotlin and { 'java', 'kotlin' } or { 'java' }
end

--- Honour `root_markers`' priority grouping when resolving a root by hand.
---@param bufnr integer
---@param markers (string|string[])[]
---@return string?
local function resolve_root(bufnr, markers)
  local groups = type(markers[1]) == 'string' and { markers } or markers
  for _, group in ipairs(groups) do
    local root = vim.fs.root(bufnr, group --[[@as string[] ]])
    if root then
      return root
    end
  end
  return nil
end

--- Answer a `workspace/configuration` item from the flat settings table.
---
--- The server asks for whole sections (`jetbrains.kotlin`) but settings are
--- stored flat (`jetbrains.kotlin.hints.parameters`), matching how the VS Code
--- client declares them. Rebuild the nested object the server expects by
--- collecting every key under the requested prefix.
---@param settings table
---@param section string?
---@return any
local function section_value(settings, section)
  if not section then
    return vim.NIL
  end
  if settings[section] ~= nil then
    return settings[section]
  end

  local prefix = section .. '.'
  local nested, found = {}, false

  for key, value in pairs(settings) do
    if type(key) == 'string' and key:sub(1, #prefix) == prefix then
      found = true
      local node = nested
      local parts = vim.split(key:sub(#prefix + 1), '.', { plain = true })
      for i = 1, #parts - 1 do
        if type(node[parts[i]]) ~= 'table' then
          node[parts[i]] = {}
        end
        node = node[parts[i]]
      end
      node[parts[#parts]] = value
    end
  end

  if not found then
    return vim.NIL
  end
  return nested
end

--- Build the `vim.lsp.ClientConfig` for the IntelliJ server.
---@return vim.lsp.Config
function M.build()
  local opts = require('intellij-lsp').options()
  local server = require('intellij-lsp.server')
  local workspace = require('intellij-lsp.workspace')
  local completion = require('intellij-lsp.completion')

  local markers = opts.root_markers or DEFAULT_ROOT_MARKERS

  -- Validated once here so a bad path warns loudly instead of silently
  -- emptying hover and references on every JDK symbol.
  local jdk = require('intellij-lsp.jdk').resolve(opts)

  local settings = require('intellij-lsp.settings').build(opts, jdk)

  local init_options = vim.tbl_deep_extend('force', {}, opts.init_options or {})
  if jdk then
    -- Renamed defaultJdk -> defaultSdk in newer builds; send both so one
    -- config works across the versions people actually have installed.
    init_options.defaultSdk = jdk
    init_options.defaultJdk = jdk
  end

  return {
    --- Function form so `--system-path` can be derived from the *resolved*
    --- root: Neovim passes the finished config, and per-project isolation is
    --- what keeps stale index locks from wedging later starts.
    cmd = function(dispatchers, config)
      local exe = server.find_or_notify()
      if not exe then
        error('intellij-lsp: intellij-server not found', 0)
      end

      local root = (config and config.root_dir) or vim.uv.cwd()
      -- Two separate argv entries, matching the VS Code client exactly:
      --   r.push("--stdio"), storageUri && r.push("--system-path", fsPath)
      local argv = { exe, '--stdio', '--system-path', workspace.for_root(root) }
      if opts.log_level then
        table.insert(argv, '--log-level=' .. opts.log_level)
      end
      vim.list_extend(argv, opts.cmd_extra or {})

      -- JVM flags, telemetry and region all travel through the environment
      -- rather than argv.
      local env = require('intellij-lsp.env').build(opts, jdk)

      return vim.lsp.rpc.start(argv, dispatchers, { cwd = root, env = env })
    end,

    filetypes = filetypes(opts),
    root_markers = markers,

    --- Authoritative start gate. Not calling `on_dir` tells Neovim to skip
    --- this buffer, which is how we stay out of kotlin.nvim's way even when
    --- its client got there first.
    root_dir = function(bufnr, on_dir)
      local exe = server.find_or_notify()
      if not exe then
        return
      end

      -- Refuse to start rather than let the server reject `initialize` with a
      -- RequestFailed that surfaces as a Lua stack traceback.
      local eula = require('intellij-lsp.eula')
      if not eula.accepted(exe) then
        vim.notify_once(
          'intellij-lsp: the bundled JetBrains agreement has not been accepted.\n'
            .. 'Run :IntellijAcceptEula (or set accept_eula = true) to proceed.',
          vim.log.levels.WARN
        )
        return
      end

      local root = resolve_root(bufnr, markers)
      if not root then
        return
      end

      -- The index admits exactly one server per project. When another live
      -- Neovim already owns this root, skip attaching instead of failing
      -- with a cryptic RocksDB LOCK error — this instance still edits
      -- normally, just without IntelliJ.
      local owner = workspace.owner_pid(root)
      if owner then
        vim.notify_once(
          ('intellij-lsp: Neovim (pid %d) already runs the IntelliJ server for %s.\n'
            .. 'This instance attaches no second server (the index is exclusive). '
            .. 'Close the other instance and reopen this file to take over.'):format(owner, root),
          vim.log.levels.WARN
        )
        return
      end

      if vim.bo[bufnr].filetype == 'kotlin' and opts.kotlin ~= true then
        for _, client in ipairs(vim.lsp.get_clients({ name = 'kotlin_lsp' })) do
          if client.root_dir == root then
            return
          end
        end
      end

      on_dir(root)
    end,

    settings = settings,
    init_options = init_options,

    --- `buildTools` is keyed by the resolved workspace root, which only exists
    --- once Neovim has computed `rootUri`. The EULA hash is resolved here too,
    --- since it depends on which install actually got launched.
    before_init = function(params, config)
      config.init_options = config.init_options or {}

      local exe = server.find()
      if exe then
        local accepted, hash = require('intellij-lsp.eula').accepted(exe)
        if accepted and hash then
          config.init_options.eulaHash = hash
        end
      end

      if opts.build_tool and params.rootUri then
        config.init_options.buildTools = config.init_options.buildTools or {}
        config.init_options.buildTools[params.rootUri] = opts.build_tool
      end

      -- Per-project index. Without this the RocksDB index lands in the
      -- SHARED ~/.cache/JetBrains/analyzer/workspaces/<md5>/ and two Neovims
      -- on one project deadlock on its LOCK (HANDOFF §6.7). The server's own
      -- bin/warmup.py passes indexDir alongside --system-path; doing the
      -- same moves the index into our per-project workspace dir.
      if opts.isolate_index ~= false and config.root_dir then
        config.init_options.indexDir = workspace.for_root(config.root_dir)
      end

      params.initializationOptions = config.init_options
    end,

    capabilities = {
      textDocument = {
        inlayHint = { dynamicRegistration = true },
        foldingRange = { dynamicRegistration = false, lineFoldingOnly = true },
        callHierarchy = { dynamicRegistration = false },
      },
    },

    handlers = {
      --- The server pulls its configuration dynamically rather than reading
      --- what we send up front; inlay hints silently do nothing without this.
      ['workspace/configuration'] = function(_, params, _)
        local result = {}
        for _, item in ipairs((params or {}).items or {}) do
          table.insert(result, section_value(settings, item.section))
        end
        return result
      end,

      ['window/showDocument'] = function(_, params, ctx)
        return completion.show_document(params, ctx)
      end,

      --- The server's own readiness signal: "index built + flushed" (its
      --- bin/warmup.py waits for exactly this). Much better than guessing
      --- from the log.
      ['intellij/ready-for-test'] = function(_, _, ctx)
        local client = vim.lsp.get_client_by_id(ctx.client_id)
        if client and client.root_dir then
          announced[client.root_dir] = true
        end
        vim.api.nvim_exec_autocmds('User', {
          pattern = 'IntellijReady',
          data = { client_id = ctx.client_id, root_dir = client and client.root_dir },
        })
        if opts.import_notify ~= false then
          vim.notify('intellij-lsp: ready — project imported and indexed', vim.log.levels.INFO)
        end
      end,

      --- Surface server-side errors instead of burying them in the log.
      --- Project import can fail completely — unreachable artifact repo,
      --- bad JDK, broken build script — and the only symptom the user sees
      --- otherwise is an LSP that answers everything with nothing.
      ['window/logMessage'] = function(err, params, ctx)
        if params and params.type == vim.lsp.protocol.MessageType.Error then
          local text = tostring(params.message or '')
          -- Stack traces are long; lead with the line that names the cause.
          local headline = text:match('^[^\n]*') or text
          local cause = text:match('Caused by: ([^\n]*)')

          -- A toolchain mismatch has a one-line fix; say it instead of
          -- pointing at a 300-line Gradle stack trace.
          local advice
          local client = vim.lsp.get_client_by_id(ctx.client_id)
          if client and client.root_dir then
            advice = require('intellij-lsp.workspace').toolchain_advice(client.root_dir)
          end

          vim.notify(
            'intellij-lsp: '
              .. headline
              .. (cause and ('\n  ' .. cause) or '')
              .. (advice and ('\n  → ' .. advice) or '')
              .. '\n:IntellijLog for detail',
            vim.log.levels.ERROR
          )
        end
        return vim.lsp.handlers['window/logMessage'](err, params, ctx)
      end,
    },

    on_exit = function(_, _, client_id)
      -- The client object may already be unreachable here; use the root we
      -- recorded at init.
      local root = claimed_roots[client_id]
      claimed_roots[client_id] = nil
      if root then
        workspace.release(root)
      end
    end,

    on_init = function(client)
      completion.attach(client)
      if client.root_dir then
        workspace.claim(client.root_dir)
        claimed_roots[client.id] = client.root_dir
      end

      -- The server sends no $/progress for the import (verified), and a cold
      -- import is minutes of silence that reads as a dead server.
      if opts.import_notify ~= false and client.root_dir then
        local ws = require('intellij-lsp.workspace')
        local cold = vim.fn.filereadable(ws.log_file(client.root_dir)) ~= 1
        if cold then
          vim.notify('intellij-lsp: importing project — a first import can take minutes', vim.log.levels.INFO)
        end
        local root = client.root_dir
        announced[root] = nil
        ws.watch_import(root, function(status)
          -- The ready-for-test notification is the nicer signal; only speak
          -- up here when it hasn't already (it arrives after indexing, this
          -- one right after the build).
          if status.build == 'successful' and not announced[root] then
            announced[root] = true
            vim.notify(
              ('intellij-lsp: project imported (%d libraries), indexing…'):format(status.libraries or 0),
              vim.log.levels.INFO
            )
          end
          -- Failures are already surfaced loudly by the logMessage handler.
        end)
      end
    end,

    --- VS Code-isms the server sends as client-side commands.
    commands = {
      ['runCommands'] = function(cmd, ctx)
        completion.run_commands(cmd, ctx)
      end,
    },

    on_attach = function(client, bufnr)
      -- The settings side (which hint kinds, their options) is answered via
      -- workspace/configuration; this is the display side. Default-on to
      -- match what the VS Code client shows out of the box. 'manual' answers
      -- the settings but leaves the display to the user's own config.
      if opts.inlay_hints == true and client.server_capabilities.inlayHintProvider then
        vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
      end

      -- Lenses render nothing unless enabled; 0.12's enable() owns the
      -- refresh lifecycle (the manual refresh-on-autocmd dance is the
      -- deprecated pre-0.12 way).
      if opts.codelens ~= false and client.server_capabilities.codeLensProvider then
        if vim.lsp.codelens.enable then
          vim.lsp.codelens.enable(true, { bufnr = bufnr })
        else
          vim.lsp.codelens.refresh({ bufnr = bufnr })
        end
      end

      if opts.organize_imports_on_save then
        vim.api.nvim_create_autocmd('BufWritePre', {
          group = vim.api.nvim_create_augroup('intellij_lsp_organize_' .. bufnr, { clear = true }),
          buffer = bufnr,
          callback = function()
            require('intellij-lsp.actions').organize_imports_sync(client, bufnr, 1500)
          end,
        })
      end
    end,
  }
end

return M
