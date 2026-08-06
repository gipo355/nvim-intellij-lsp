---@mod intellij-lsp.server Locating the intellij-server launcher
---
--- `bin/intellij-server` is a native launcher that manages its own bundled JBR,
--- so there is no JRE or classpath to configure — we only need its path.
---
--- Resolution order: explicit `server_dir` option, then `$INTELLIJ_SERVER_DIR`,
--- then a bare `intellij-server` on `$PATH`.

local M = {}

local is_windows = vim.fn.has('win32') == 1
local sep = is_windows and '\\' or '/'
local exe_name = is_windows and 'intellij-server.exe' or 'intellij-server'

--- Resolve the launcher inside an install root.
---
--- Two layouts exist in the wild: the launcher directly under `<root>/bin/`,
--- and a versioned subdirectory (`<root>/kotlin-server-262.4739.0/bin/`) as
--- produced by the newer archives. Probe both.
---@param dir string
---@return string? path
function M.resolve_dir(dir)
  dir = vim.fn.expand(dir)

  local direct = table.concat({ dir, 'bin', exe_name }, sep)
  if vim.fn.executable(direct) == 1 then
    return direct
  end

  for _, sub in ipairs(vim.fn.glob(dir .. sep .. '*-server-*', false, true)) do
    local nested = table.concat({ sub, 'bin', exe_name }, sep)
    if vim.fn.executable(nested) == 1 then
      return nested
    end
  end

  -- Someone may point directly at the bin/ directory, or at the launcher.
  local as_bin = dir .. sep .. exe_name
  if vim.fn.executable(as_bin) == 1 then
    return as_bin
  end
  if vim.fn.executable(dir) == 1 and vim.fn.isdirectory(dir) == 0 then
    return dir
  end

  return nil
end

--- Path to the launcher, or nil with a reason.
---@return string? path
---@return string? reason
function M.find()
  local opts = require('intellij-lsp').options()

  local candidates = {}
  if opts.server_dir then
    table.insert(candidates, opts.server_dir)
  end
  local env = vim.env.INTELLIJ_SERVER_DIR
  if env and env ~= '' then
    table.insert(candidates, env)
  end

  -- Anything :IntellijInstall put in place, newest version first.
  local install = require('intellij-lsp.install')
  local managed = vim.fn.glob(install.root() .. '/*', false, true)
  table.sort(managed, function(a, b)
    return a > b
  end)
  vim.list_extend(candidates, managed)

  for _, dir in ipairs(candidates) do
    local found = M.resolve_dir(dir)
    if found then
      return found
    end
  end

  if vim.fn.executable(exe_name) == 1 then
    return vim.fn.exepath(exe_name)
  end

  if #candidates == 0 then
    return nil, 'no server installed — run :IntellijInstall (or set server_dir / $INTELLIJ_SERVER_DIR)'
  end
  return nil, ('no %s found under: %s'):format(exe_name, table.concat(candidates, ', '))
end

local notified = false

--- Like `find()`, but on failure offers to install instead of only
--- complaining — a fresh setup's first attach should lead somewhere. Asked
--- once per session; declining leaves the usual pointers.
---@return string?
function M.find_or_notify()
  local path, reason = M.find()
  if path then
    notified = false
    return path
  end
  if not notified then
    notified = true
    vim.schedule(function()
      vim.ui.select({ 'Install now', 'Not now' }, {
        prompt = 'intellij-lsp: no server installed (~1 GB download). Install?',
      }, function(choice)
        if choice == 'Install now' then
          require('intellij-lsp.install').install(require('intellij-lsp').options().version, function(installed, err)
            if not installed then
              vim.notify('intellij-lsp: install failed\n' .. tostring(err), vim.log.levels.ERROR)
              return
            end
            vim.notify(
              'intellij-lsp: installed. Run :IntellijAcceptEula, then reopen your Java file.',
              vim.log.levels.INFO
            )
          end)
        else
          vim.notify(
            ('intellij-lsp: %s\nSet `server_dir` or $INTELLIJ_SERVER_DIR, then :checkhealth intellij-lsp'):format(
              reason or 'server not found'
            ),
            vim.log.levels.WARN
          )
        end
      end)
    end)
  end
  return nil
end

return M
