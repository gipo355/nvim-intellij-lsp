---@mod intellij-lsp.install Downloading the language server
---
--- The VSIX is a 1.4 MB shim — it contains no server at all. The extension
--- fetches a tarball from JetBrains on first launch:
---
---   https://download.jetbrains.com/language-server/intellij-server/263.2689.0/intellij-server-263.2689.0.tar.gz
---
--- so we can skip the VSIX entirely and fetch the same archive. Note the host
--- is `download.jetbrains.com`, not the `download-cdn.` host Mason uses for
--- kotlin-server; that one 404s for this product.
---
--- Only the linux-x64 URL is confirmed (it is the one embedded in the linux-x64
--- VSIX). The other platform suffixes follow kotlin-server's scheme and are
--- marked accordingly — a failed download reports the URL it tried so the guess
--- is easy to correct.

local M = {}

local BASE = 'https://download.jetbrains.com/language-server/intellij-server'

--- Server build shipped with extension 0.0.8.
M.DEFAULT_VERSION = '263.2689.0'

--- Checksums published in the extension's own `server-bundle.json`. Archives we
--- have no hash for are still installed, with a warning — a missing hash is a
--- gap in our table, not evidence of a bad download.
M.CHECKSUMS = {
  ['intellij-server-263.2689.0.tar.gz'] = 'bf4aa474a87499cc3bf7086e64d05f9c4140f5464956fbd574adcc2d4c3e4162',
}

--- Shell out for the digest: the archives are far too large to read into memory
--- for `vim.fn.sha256`.
---@param path string
---@return string? digest
local function sha256(path)
  local cmds = {
    { 'sha256sum', path },
    { 'shasum', '-a', '256', path },
  }
  for _, cmd in ipairs(cmds) do
    if vim.fn.executable(cmd[1]) == 1 then
      local out = vim.system(cmd, { text = true }):wait(120000)
      if out.code == 0 and out.stdout then
        return out.stdout:match('^(%x+)')
      end
    end
  end
  return nil
end

--- Verify a downloaded archive.
---@param path string
---@return boolean ok
---@return string? message
function M.verify(path)
  local expected = M.CHECKSUMS[vim.fs.basename(path)]
  if not expected then
    return true, 'no published checksum for this build — skipping verification'
  end

  local actual = sha256(path)
  if not actual then
    return true, 'no sha256 tool found — skipping verification'
  end
  if actual:lower() ~= expected:lower() then
    return false, ('checksum mismatch\n  expected %s\n  got      %s'):format(expected, actual)
  end
  return true, nil
end

---@return string? target
---@return boolean confirmed Whether this URL shape is verified rather than inferred
local function archive_suffix()
  local arm = vim.uv.os_uname().machine:match('^arm') or vim.uv.os_uname().machine:match('aarch64')

  if vim.fn.has('win32') == 1 then
    return arm and '-aarch64.win.zip' or '.win.zip', false
  end
  if vim.fn.has('mac') == 1 then
    -- .sit archives are plain zips, as Mason's kotlin-lsp package relies on.
    return arm and '-aarch64.sit' or '.sit', false
  end
  return arm and '-aarch64.tar.gz' or '.tar.gz', not arm
end

--- Download URL for a version on this platform.
---@param version? string
---@return string url
---@return boolean confirmed
function M.url(version)
  version = version or M.DEFAULT_VERSION
  local suffix, confirmed = archive_suffix()
  return ('%s/%s/intellij-server-%s%s'):format(BASE, version, version, suffix), confirmed
end

--- Where servers get installed.
---@return string
function M.root()
  return table.concat({ vim.fn.stdpath('data'), 'intellij-lsp', 'servers' }, '/')
end

---@param version string
---@return string
function M.install_dir(version)
  return M.root() .. '/' .. version
end

--- Managed installs, newest version first.
---@return { version: string, dir: string }[]
function M.installed()
  local out = {}
  for _, dir in ipairs(vim.fn.glob(M.root() .. '/*', false, true)) do
    if vim.fn.isdirectory(dir) == 1 then
      table.insert(out, { version = vim.fs.basename(dir), dir = dir })
    end
  end
  table.sort(out, function(a, b)
    return a.version > b.version
  end)
  return out
end

--- Disk usage of a directory in bytes, or nil when `du` is unavailable.
---@param dir string
---@return integer?
function M.disk_usage(dir)
  if vim.fn.executable('du') ~= 1 or vim.fn.isdirectory(dir) ~= 1 then
    return nil
  end
  local out = vim.system({ 'du', '-sb', dir }, { text = true }):wait(30000)
  if out.code == 0 and out.stdout then
    return tonumber(out.stdout:match('^(%d+)'))
  end
  return nil
end

--- Age in whole days of an install, from the build's own file timestamps
--- (the tarball preserves them, so this is the build date, not the download
--- date). Preview builds stop working ~30 days after release.
---@param dir string install root (a managed version dir or a server root)
---@return integer? days
function M.build_age_days(dir)
  local launcher = require('intellij-lsp.server').resolve_dir(dir)
  if not launcher then
    return nil
  end
  local root = vim.fs.dirname(vim.fs.dirname(launcher))
  local stat = vim.uv.fs_stat(root .. '/build.txt')
  if not stat then
    return nil
  end
  return math.floor((os.time() - stat.mtime.sec) / 86400)
end

--- Delete every managed install except the newest (and except whatever
--- `server_dir`/$INTELLIJ_SERVER_DIR points at, which is not ours to touch).
---@return string summary
function M.prune()
  local installed = M.installed()
  if #installed <= 1 then
    return 'nothing to prune (' .. #installed .. ' managed install)'
  end

  local active = require('intellij-lsp.server').find()
  local removed, freed = {}, 0
  for i = 2, #installed do
    local entry = installed[i]
    -- Never delete the directory the running/resolved server lives in.
    if not (active and vim.startswith(active, entry.dir)) then
      freed = freed + (M.disk_usage(entry.dir) or 0)
      vim.fn.delete(entry.dir, 'rf')
      table.insert(removed, entry.version)
    end
  end

  if #removed == 0 then
    return 'nothing pruned — older installs are in use'
  end
  return ('removed %s (freed %.1f GB), kept %s'):format(
    table.concat(removed, ', '),
    freed / 2 ^ 30,
    installed[1].version
  )
end

---@param path string
---@param dest string
---@return string[] argv
local function extract_argv(path, dest)
  if path:match('%.tar%.gz$') then
    return { 'tar', '-xzf', path, '-C', dest }
  end
  return { 'unzip', '-qo', path, '-d', dest }
end

--- Download and unpack the server. Runs asynchronously; `on_done(path|nil, err)`
--- fires on the main loop.
---@param version? string
---@param on_done? fun(path: string?, err: string?)
function M.install(version, on_done)
  version = version or M.DEFAULT_VERSION
  on_done = on_done or function() end

  local dest = M.install_dir(version)
  local existing = require('intellij-lsp.server').resolve_dir(dest)
  if existing then
    vim.notify('intellij-lsp: already installed at ' .. dest, vim.log.levels.INFO)
    return on_done(existing, nil)
  end

  local url, confirmed = M.url(version)
  if not confirmed then
    vim.notify(
      'intellij-lsp: this platform\'s archive name is inferred, not confirmed.\nTrying ' .. url,
      vim.log.levels.WARN
    )
  end

  if vim.fn.executable('curl') ~= 1 then
    return on_done(nil, 'curl not found on $PATH')
  end

  vim.fn.mkdir(dest, 'p')
  local archive = dest .. '/' .. vim.fs.basename(url)

  vim.notify('intellij-lsp: downloading ' .. url, vim.log.levels.INFO)

  -- The completion callback fires in a fast event context, where vim.fn and
  -- vim.system():wait() (used by M.verify) are not allowed — hop to the main
  -- loop before doing anything else.
  vim.system({ 'curl', '-fL', '--retry', '3', '-o', archive, url }, { text = true }, function(dl)
    vim.schedule(function()
      if dl.code ~= 0 then
        vim.fn.delete(dest, 'rf')
        on_done(nil, ('download failed (curl %d) for %s\n%s'):format(dl.code, url, dl.stderr or ''))
        return
      end

      local ok, message = M.verify(archive)
      if not ok then
        vim.fn.delete(dest, 'rf')
        on_done(nil, message)
        return
      end
      if message then
        vim.notify('intellij-lsp: ' .. message, vim.log.levels.WARN)
      end

      vim.system(extract_argv(archive, dest), { text = true }, function(ex)
        vim.schedule(function()
          vim.fn.delete(archive)

          if ex.code ~= 0 then
            on_done(nil, ('extract failed (%d)\n%s'):format(ex.code, ex.stderr or ''))
            return
          end

          local launcher = require('intellij-lsp.server').resolve_dir(dest)
          if not launcher then
            on_done(nil, 'archive unpacked but no bin/intellij-server inside ' .. dest)
            return
          end

          -- Archives do not always preserve the executable bit.
          vim.uv.fs_chmod(launcher, 493) -- 0755
          on_done(launcher, nil)
        end)
      end)
    end)
  end)
end

return M
