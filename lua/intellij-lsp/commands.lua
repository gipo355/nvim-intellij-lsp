---@mod intellij-lsp.commands User commands

local M = {}

---@param clients vim.lsp.Client[]
local function restart_clients(clients)
  if #clients == 0 then
    vim.notify('intellij-lsp: no running client', vim.log.levels.INFO)
    return
  end

  -- Graceful first: a SIGTERM'd server exits 143 mid-flush and Neovim warns
  -- about it. Force only what refuses to go.
  for _, client in ipairs(clients) do
    client:stop()
  end
  vim.defer_fn(function()
    for _, client in ipairs(clients) do
      if not client:is_stopped() then
        client:stop(true)
      end
    end
    -- Neovim restarts the client on the next attach; nudge it for the buffers
    -- that are already open after the server releases its index lock.
    local waited = 0
    local function reattach()
      local all_stopped = true
      for _, client in ipairs(clients) do
        if not client:is_stopped() then
          all_stopped = false
        end
      end
      if all_stopped or waited > 20000 then
        vim.cmd('doautoall FileType')
      else
        waited = waited + 500
        vim.defer_fn(reattach, 500)
      end
    end
    reattach()
  end, 3000)
end

--- Why `launcher` won resolution over a freshly installed build. Reproduces
--- the precedence in `server.find()` rather than guessing from what is set,
--- since an override that resolves to nothing is not what shadowed anything.
---@param launcher string? whatever `server.find()` returned instead
---@return string reason
local function shadow_reason(launcher)
  local server = require('intellij-lsp.server')
  local opts = require('intellij-lsp').options()

  if opts.server_dir and server.resolve_dir(opts.server_dir) == launcher then
    return 'the server_dir option'
  end
  local env = vim.env.INTELLIJ_SERVER_DIR
  if env and env ~= '' and server.resolve_dir(env) == launcher then
    return '$INTELLIJ_SERVER_DIR'
  end
  if opts.version then
    return ('the version pin (%s)'):format(opts.version)
  end
  return 'a newer managed install'
end

--- Root of the running client for the current buffer, falling back to cwd.
---@return string
local function current_root()
  local clients = vim.lsp.get_clients({ name = 'intellij', bufnr = 0 })
  if clients[1] and clients[1].root_dir then
    return clients[1].root_dir
  end
  return vim.uv.cwd()
end

function M.setup()
  vim.api.nvim_create_user_command('IntellijRestart', function()
    local clients = vim.lsp.get_clients({ name = 'intellij' })
    restart_clients(clients)
  end, { desc = 'Restart the IntelliJ language server' })

  vim.api.nvim_create_user_command('IntellijCleanWorkspace', function(cmd)
    -- The analyzer cache is shared across projects, so only clear it when
    -- explicitly asked with a bang.
    require('intellij-lsp.workspace').clean(current_root(), cmd.bang)
  end, {
    bang = true,
    desc = 'Delete this project\'s server state (! also clears the shared analyzer cache)',
  })

  vim.api.nvim_create_user_command('IntellijAcceptEula', function()
    require('intellij-lsp.eula').prompt()
  end, { desc = 'Show the bundled JetBrains agreement and record acceptance' })

  vim.api.nvim_create_user_command('IntellijInstall', function(cmd)
    local install = require('intellij-lsp.install')
    local version = cmd.args ~= '' and cmd.args or require('intellij-lsp').options().version
    install.install(version, function(path, err)
      if not path then
        vim.notify('intellij-lsp: install failed\n' .. tostring(err), vim.log.levels.ERROR)
        return
      end
      vim.notify('intellij-lsp: installed ' .. path, vim.log.levels.INFO)
    end)
  end, {
    nargs = '?',
    desc = 'Download the IntelliJ language server (optionally a specific build)',
  })

  vim.api.nvim_create_user_command('IntellijUpdate', function()
    local install = require('intellij-lsp.install')
    local eula = require('intellij-lsp.eula')
    local server = require('intellij-lsp.server')
    local active_before = server.find()

    -- Only restart what is still running when the download finishes: it can
    -- take minutes, and the client list from before it is stale by then.
    local function restart_now(version)
      local clients = vim.lsp.get_clients({ name = 'intellij' })
      if #clients == 0 then
        vim.notify('intellij-lsp: updated to ' .. version, vim.log.levels.INFO)
        return
      end
      vim.notify('intellij-lsp: updated to ' .. version .. '; restarting…', vim.log.levels.INFO)
      restart_clients(clients)
    end

    vim.notify('intellij-lsp: checking JetBrains for the latest build…', vim.log.levels.INFO)
    install.install_latest(function(path, err, bundle)
      if not path then
        vim.notify('intellij-lsp: update failed\n' .. tostring(err), vim.log.levels.ERROR)
        return
      end

      local active_after = server.find()
      if active_after ~= path then
        vim.notify(
          ('intellij-lsp: installed %s, but %s still selects\n%s'):format(
            bundle.version,
            shadow_reason(active_after),
            active_after or 'no server'
          ),
          vim.log.levels.WARN
        )
        return
      end

      if active_before == path then
        local age = install.build_age_days(install.install_dir(bundle.version))
        local expiry_note = ''
        if age and age >= 25 then
          expiry_note = ('\nThis upstream build is %d days old; reinstalling it '
            .. 'would not reset its preview expiry.'):format(age)
        end
        vim.notify(
          'intellij-lsp: already on the latest build (' .. bundle.version .. ')' .. expiry_note,
          vim.log.levels.INFO
        )
        return
      end

      if not eula.accepted(path) then
        vim.notify(
          ('intellij-lsp: installed %s; accept its agreement to start it'):format(bundle.version),
          vim.log.levels.WARN
        )
        eula.prompt(path, function()
          restart_now(bundle.version)
        end)
        return
      end

      restart_now(bundle.version)
    end)
  end, { desc = 'Install the latest JetBrains server build and restart' })

  vim.api.nvim_create_user_command('IntellijPrune', function()
    local install = require('intellij-lsp.install')
    local installed = install.installed()
    if #installed <= 1 then
      vim.notify('intellij-lsp: nothing to prune', vim.log.levels.INFO)
      return
    end
    local victims = {}
    for i = 2, #installed do
      table.insert(victims, installed[i].version)
    end
    local choice = vim.fn.confirm(
      ('Delete old server install(s): %s?\n(~1 GB each; keeping %s)'):format(
        table.concat(victims, ', '),
        installed[1].version
      ),
      '&Delete\n&Cancel',
      2
    )
    if choice == 1 then
      vim.notify('intellij-lsp: ' .. install.prune(), vim.log.levels.INFO)
    end
  end, { desc = 'Delete all but the newest managed server install' })

  vim.api.nvim_create_user_command('IntellijLog', function()
    local log = require('intellij-lsp.workspace').log_file(current_root())
    if vim.fn.filereadable(log) ~= 1 then
      vim.notify('intellij-lsp: no server log yet at ' .. log, vim.log.levels.WARN)
      return
    end
    vim.cmd('tabnew ' .. vim.fn.fnameescape(log))
    vim.cmd('normal! G')
  end, { desc = "Open the server's own log for this project" })

  vim.api.nvim_create_user_command('IntellijRun', function(cmd)
    require('intellij-lsp.run').run(cmd.args)
  end, {
    nargs = '*',
    desc = "Run the current buffer's main class (classpath resolved by the server)",
  })

  vim.api.nvim_create_user_command('IntellijExportWorkspace', function()
    local client = vim.lsp.get_clients({ name = 'intellij', bufnr = 0 })[1]
      or vim.lsp.get_clients({ name = 'intellij' })[1]
    if not client then
      vim.notify('intellij-lsp: no running client', vim.log.levels.WARN)
      return
    end
    local root = client.root_dir or vim.uv.cwd()
    -- Argument shape from the server's own bin/warmup.py: the project path;
    -- the dump lands in <root>/workspace.json.
    client:request('workspace/executeCommand', {
      command = 'exportWorkspace',
      arguments = { root },
    }, function(err)
      if err then
        vim.notify('intellij-lsp: exportWorkspace failed\n' .. vim.inspect(err), vim.log.levels.ERROR)
      else
        vim.notify('intellij-lsp: workspace model written to ' .. root .. '/workspace.json', vim.log.levels.INFO)
      end
    end)
  end, { desc = "Dump the server's workspace model to <root>/workspace.json" })

  vim.api.nvim_create_user_command('IntellijDebug', function()
    require('intellij-lsp.dap').debug_main()
  end, { desc = "Debug the current buffer's main class (JDWP + the server's DAP bridge)" })

  vim.api.nvim_create_user_command('IntellijOrganizeImports', function()
    local bufnr = vim.api.nvim_get_current_buf()
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'intellij' })[1]
    if not client then
      vim.notify('intellij-lsp: no client attached', vim.log.levels.WARN)
      return
    end
    require('intellij-lsp.actions').organize_imports_sync(client, bufnr, 3000)
  end, { desc = 'Organize imports in the current buffer' })

  vim.api.nvim_create_user_command('IntellijStatus', function()
    local clients = vim.lsp.get_clients({ name = 'intellij' })
    if #clients == 0 then
      vim.notify('intellij-lsp: not attached', vim.log.levels.WARN)
      return
    end
    for _, client in ipairs(clients) do
      vim.notify(
        ('intellij-lsp: id=%d root=%s buffers=%d'):format(
          client.id,
          client.root_dir or '?',
          vim.tbl_count(client.attached_buffers or {})
        ),
        vim.log.levels.INFO
      )
    end
  end, { desc = 'Show IntelliJ language server status' })
end

return M
