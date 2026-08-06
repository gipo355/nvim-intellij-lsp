---@mod intellij-lsp.dap Debugging via the server's own DAP bridge
---
--- The server hosts IntelliJ's XDebugger behind a DAP endpoint: the
--- `start_debug_server` executeCommand returns a TCP port, and a DAP
--- `initialize` with `adapterID = "intellij_debugger"` succeeds (verified —
--- attach, breakpoint verification and a live "Connected to the target VM"
--- all round-tripped). No VS Code extension pieces are involved.
---
--- Wire-up is automatic when nvim-dap is installed: an `intellij` adapter
--- plus an attach configuration. `M.debug_main()` (`:IntellijDebug`) runs
--- the current main class under JDWP (suspended) and attaches to it.

local M = {}

---@return vim.lsp.Client?
local function lsp_client()
  return vim.lsp.get_clients({ name = 'intellij', bufnr = 0 })[1]
    or vim.lsp.get_clients({ name = 'intellij' })[1]
end

--- nvim-dap adapter: ask the language server for a fresh DAP port.
---@param cb fun(adapter: table)
local function adapter(cb)
  local client = lsp_client()
  if not client then
    vim.notify('intellij-lsp: no running IntelliJ client to start a debug server', vim.log.levels.ERROR)
    return
  end
  client:request('workspace/executeCommand', {
    command = 'start_debug_server',
    arguments = {},
  }, function(err, port)
    if err or type(port) ~= 'number' then
      vim.notify('intellij-lsp: start_debug_server failed\n' .. vim.inspect(err or port), vim.log.levels.ERROR)
      return
    end
    cb({
      type = 'server',
      host = '127.0.0.1',
      port = port,
      -- Sent as the DAP adapterID; anything else gets
      -- "No debugger adapter found for given adapter id".
      id = 'intellij_debugger',
    })
  end)
end

--- Register with nvim-dap. No-op (returning false) when it isn't installed.
---@return boolean
function M.setup()
  local ok, dap = pcall(require, 'dap')
  if not ok then
    return false
  end
  if dap.adapters.intellij then
    return true
  end

  dap.adapters.intellij = function(cb, _)
    adapter(cb)
  end

  local function java_exec()
    local jdk = require('intellij-lsp.jdk').resolve(require('intellij-lsp').options())
    return jdk and (jdk .. '/bin/java') or vim.fn.exepath('java')
  end

  for _, ft in ipairs({ 'java', 'kotlin' }) do
    dap.configurations[ft] = dap.configurations[ft] or {}
    -- Native launch (verified): the server spawns the JVM under JDWP and
    -- attaches internally; classpath and cwd come from its own workspace
    -- model, which is why only these two fields are required.
    table.insert(dap.configurations[ft], {
      type = 'intellij',
      request = 'launch',
      name = 'IntelliJ: launch main class',
      javaExec = java_exec,
      mainClass = function()
        return require('intellij-lsp.run').main_class_of(0)
          or vim.fn.input('Main class (fully qualified): ')
      end,
    })
    table.insert(dap.configurations[ft], {
      type = 'intellij',
      request = 'attach',
      name = 'IntelliJ: attach to JDWP process',
      hostName = '127.0.0.1',
      port = function()
        return tonumber(vim.fn.input('JDWP port: ', '5005'))
      end,
    })
  end
  return true
end

--- Debug the current buffer's main class via the server's native DAP
--- launch. The server does not compile first, so verify the module output
--- exists (offering a build when it doesn't) before launching.
function M.debug_main()
  if not M.setup() then
    vim.notify('intellij-lsp: nvim-dap is not installed', vim.log.levels.ERROR)
    return
  end
  local run = require('intellij-lsp.run')

  run.build_invocation(function(inv, err)
    if not inv then
      vim.notify('intellij-lsp: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local client = lsp_client()
    run.ensure_compiled(client and client.root_dir or inv.cwd, inv.classpath, function(ok)
      if not ok then
        return
      end
      require('dap').run({
        type = 'intellij',
        request = 'launch',
        name = 'IntelliJ: ' .. inv.main_class,
        javaExec = inv.java,
        mainClass = inv.main_class,
      })
    end)
  end)
end

return M
