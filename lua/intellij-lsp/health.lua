---@mod intellij-lsp.health `:checkhealth intellij-lsp`

local M = {}

local function check_neovim()
  vim.health.start('Neovim')
  if vim.fn.has('nvim-0.11') == 1 then
    vim.health.ok('Neovim ' .. tostring(vim.version()))
  else
    vim.health.error('Neovim 0.11+ required (vim.lsp.config / lsp/ runtimepath entries)')
  end
end

local function check_server()
  vim.health.start('Server')

  local server = require('intellij-lsp.server')
  local path, reason = server.find()

  if not path then
    vim.health.error(reason or 'intellij-server not found', {
      'Point at an install root with the `server_dir` option or $INTELLIJ_SERVER_DIR',
      'The root should contain bin/intellij-server',
      'See scripts/recon.sh for extracting one from the VSIX',
    })
    return
  end

  vim.health.ok('launcher: ' .. path)

  local eula = require('intellij-lsp.eula')
  local accepted, hash = eula.accepted(path)
  if not hash then
    vim.health.info('no bundled EULA.txt found (older build?)')
  elseif accepted then
    vim.health.ok('agreement accepted: ' .. hash)
  else
    vim.health.error('bundled JetBrains agreement not accepted (' .. hash .. ')', {
      'The server refuses to initialize without it',
      'Run :IntellijAcceptEula, or set accept_eula = true',
    })
  end

  -- The launcher bundles its own JBR, so a missing system JDK is not fatal —
  -- but the server still needs one to resolve symbols in your code.
  local out = vim.system({ path, '--version' }, { text = true }):wait(10000)
  if out.code == 0 and out.stdout and out.stdout ~= '' then
    vim.health.info('version: ' .. vim.trim(out.stdout))
  else
    vim.health.info('`--version` not supported by this build (harmless)')
  end

  -- Preview builds stop working ~30 days after release; the failure mode is
  -- indistinguishable from every other "the LSP is bare" mystery.
  local install = require('intellij-lsp.install')
  local age = install.build_age_days(vim.fs.dirname(vim.fs.dirname(path)))
  if age then
    if age >= 30 then
      vim.health.error(('build is %d days old — preview builds expire around 30 days'):format(age), {
        'Run :IntellijInstall <newer-version> and re-accept the agreement',
      })
    elseif age >= 25 then
      vim.health.warn(('build is %d days old — preview builds expire around 30 days'):format(age), {
        'A newer build likely exists; plan to :IntellijInstall soon',
      })
    else
      vim.health.ok(('build age: %d days (previews expire ~30 days after release)'):format(age))
    end
  end
end

local function check_jdk()
  vim.health.start('JDK for symbol resolution')

  local opts = require('intellij-lsp').options()
  local jdklib = require('intellij-lsp.jdk')

  if opts.jdk and vim.fn.executable(vim.fn.expand(opts.jdk) .. '/bin/javac') ~= 1 then
    vim.health.error('configured `jdk` is not a JDK: ' .. tostring(opts.jdk), {
      'Hover, references and completion on JDK symbols will be silently empty',
      'Remove the option to auto-detect, or point it at a directory with bin/javac',
    })
  end

  local resolved = jdklib.resolve(opts)
  if resolved then
    local version = jdklib.version(resolved)
    vim.health.ok(('using jdk: %s%s'):format(resolved, version and (' (java ' .. version .. ')') or ''))
  else
    vim.health.warn('no JDK found', {
      'Set `jdk` to the JDK your project compiles against',
      'The server runs on its own bundled JBR regardless',
    })
  end

  local all = jdklib.list()
  if #all > 0 then
    vim.health.info(('%d JDK(s) discovered:'):format(#all))
    for _, c in ipairs(all) do
      vim.health.info(('  java %-3s %s'):format(tostring(c.version or '?'), c.path))
    end
  end
end

local function check_workspace()
  vim.health.start('Workspace')

  local workspace = require('intellij-lsp.workspace')
  local base = workspace.base()

  if vim.fn.isdirectory(base) == 1 or vim.fn.mkdir(base, 'p') == 1 then
    vim.health.ok('system path base: ' .. base)
  else
    vim.health.error('cannot create system path base: ' .. base)
  end

  local cache = workspace.analyzer_cache()
  if cache then
    vim.health.info(('analyzer cache: %s (%s)'):format(
      cache,
      vim.fn.isdirectory(cache) == 1 and 'present' or 'not yet created'
    ))
  end

  -- Disk footprint: a ~1 GB server every couple of weeks adds up quietly.
  local install = require('intellij-lsp.install')
  local function gb(bytes)
    return bytes and ('%.1f GB'):format(bytes / 2 ^ 30) or '?'
  end
  local servers = install.installed()
  local servers_size = install.disk_usage(install.root())
  vim.health.info(('managed servers: %d (%s)'):format(#servers, gb(servers_size)))
  if #servers > 1 then
    vim.health.warn(('%d old install(s) — :IntellijPrune reclaims the space'):format(#servers - 1))
  end
  vim.health.info(('workspaces: %s'):format(gb(install.disk_usage(base))))
  if cache and vim.fn.isdirectory(cache) == 1 then
    vim.health.info(('analyzer cache size: %s'):format(gb(install.disk_usage(cache))))
  end
end

--- The state of the last project import, per running client. This is the #1
--- support question: an LSP that "works but answers nothing" is a failed
--- import serving an empty workspace model.
local function check_import()
  vim.health.start('Project import')

  local workspace = require('intellij-lsp.workspace')
  local clients = vim.lsp.get_clients({ name = 'intellij' })
  local roots = {}
  for _, client in ipairs(clients) do
    if client.root_dir then
      roots[client.root_dir] = true
    end
  end
  if vim.tbl_isempty(roots) then
    vim.health.info('no running client — open a Java file first for an import report')
    return
  end

  for root in pairs(roots) do
    local status = workspace.import_status(root)
    if not status then
      vim.health.warn(root .. ': no import evidence in the server log yet')
    elseif status.build == 'failed' then
      local advice = workspace.toolchain_advice(root)
      vim.health.error(root .. ': build-tool import FAILED — the server is serving an empty model', {
        advice or 'Every request will correctly return nothing until this is fixed',
        ':IntellijLog and look above the failure for the cause:',
        '  bad `jdk` path → "Configured Java home does not exist"',
        '  unreachable artifact repository (VPN?) → UnknownHostException',
        '  missing Gradle toolchain → ToolchainProvisioningException',
        'After fixing: :IntellijCleanWorkspace, then restart — failed imports are cached',
      })
    elseif status.libraries == 0 then
      vim.health.error(root .. ': import loaded 0 libraries — effectively an empty model', {
        ':IntellijLog for the cause; then :IntellijCleanWorkspace and restart',
      })
    elseif status.libraries then
      vim.health.ok(('%s: %d libraries loaded%s'):format(
        root,
        status.libraries,
        status.build == 'successful' and ', build successful' or ''
      ))
    else
      vim.health.ok(root .. ': build successful (library count not seen in log tail)')
    end
  end
end

local function check_conflicts()
  vim.health.start('Conflicts')

  local opts = require('intellij-lsp').options()
  local kotlin_nvim = #vim.api.nvim_get_runtime_file('lua/kotlin.lua', false) > 0
    or #vim.api.nvim_get_runtime_file('lua/kotlin/init.lua', false) > 0

  local fts = require('intellij-lsp.config')
  local ok, config = pcall(fts.build)
  local attached = ok and table.concat(config.filetypes or {}, ', ') or '?'

  if kotlin_nvim then
    if opts.kotlin == true then
      vim.health.warn('kotlin.nvim is installed and `kotlin = true` forces us to attach anyway', {
        'Two IntelliJ servers may index the same project',
        'Exclude kotlin from one of them',
      })
    else
      vim.health.ok('kotlin.nvim installed — yielding Kotlin buffers to it')
    end
  else
    vim.health.ok('no kotlin.nvim install detected')
  end

  vim.health.info('filetypes: ' .. attached)

  local running = vim.lsp.get_clients({ name = 'intellij' })
  vim.health.info(('running clients: %d'):format(#running))
  for _, client in ipairs(running) do
    vim.health.info(('  id=%d root=%s'):format(client.id, client.root_dir or '?'))
  end
end

function M.check()
  check_neovim()
  check_server()
  check_jdk()
  check_workspace()
  check_import()
  check_conflicts()
end

return M
