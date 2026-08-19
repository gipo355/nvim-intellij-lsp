---@mod intellij-lsp.workspace Per-project server state
---
--- The server keeps indexes, caches and lock files under the directory given by
--- `--system-path`. Sharing one such directory across projects produces stale
--- index locks that make subsequent starts hang, so every project root gets its
--- own. The server *additionally* writes to a JetBrains analyzer cache outside
--- that directory, which has to be cleaned separately or the same locks come
--- back from the other side.

local M = {}

local is_windows = vim.fn.has('win32') == 1
local sep = is_windows and '\\' or '/'

--- Base directory holding every per-project system path.
---@return string
function M.base()
  local opts = require('intellij-lsp').options()
  if opts.workspace_dir then
    return vim.fn.expand(opts.workspace_dir)
  end
  return table.concat({ vim.fn.stdpath('cache'), 'intellij-lsp', 'workspaces' }, sep)
end

--- Resolved system paths, keyed by root.
---
--- `on_exit` releases the claim from a fast event context, where `vim.fn` is
--- forbidden (`E5560`). The path is the same for the life of the client, so
--- the claim taken in `on_init` warms this and the release reads it back.
local dirs = {}

--- System path for a project root.
---
--- Named `<basename>-<hash>` so it stays readable when you go looking, while
--- the hash keeps same-named projects in different checkouts apart.
---@param root string
---@return string
function M.for_root(root)
  local dir = dirs[root]
  if not dir then
    local name = vim.fn.fnamemodify(root, ':p:h:t')
    if name == '' then
      name = 'root'
    end
    local hash = vim.fn.sha256(vim.fn.fnamemodify(root, ':p')):sub(1, 8)
    dir = M.base() .. sep .. name .. '-' .. hash
    dirs[root] = dir
  end

  -- The directory has to exist for the pidfile; `:IntellijCleanWorkspace`
  -- deletes it out from under a cached path, so re-create it whenever we are
  -- somewhere `vim.fn` is allowed.
  if not vim.in_fast_event() then
    vim.fn.mkdir(dir, 'p')
  end
  return dir
end

--- The server's own log for a project root. Far more informative than
--- Neovim's LSP log: Gradle/Maven import output, dependency resolution
--- failures and indexing timings all land here.
---@param root string
---@return string path
function M.log_file(root)
  return M.for_root(root) .. '/system/log/intellij-server.log'
end

--- JetBrains analyzer cache, which the server writes to regardless of
--- `--system-path`.
---@return string?
function M.analyzer_cache()
  if is_windows then
    local localappdata = vim.env.LOCALAPPDATA
    return localappdata and (localappdata .. '\\JetBrains\\analyzer') or nil
  end
  if vim.fn.has('mac') == 1 then
    return vim.env.HOME .. '/Library/Caches/JetBrains/analyzer'
  end
  local xdg = vim.env.XDG_CACHE_HOME
  if not xdg or xdg == '' then
    xdg = vim.env.HOME .. '/.cache'
  end
  return xdg .. '/JetBrains/analyzer'
end

--- What the last import attempt in this project's server log actually did.
--- The single most diagnostic fact about this server: when import fails it
--- keeps serving an empty workspace model, and every feature "works" by
--- returning nothing.
---@param root string
---@return { libraries: integer?, build: 'successful'|'failed'|nil }?
function M.import_status(root)
  local path = M.log_file(root)
  local f = io.open(path, 'r')
  if not f then
    return nil
  end

  -- Only the tail matters (the latest import); logs grow to many MB.
  local size = f:seek('end')
  f:seek('set', math.max(0, size - 512 * 1024))
  local tail = f:read('*a') or ''
  f:close()

  local status = {}
  for n in tail:gmatch('There are (%d+) libraries to load') do
    status.libraries = tonumber(n)
  end
  for line in tail:gmatch('[^\n]+') do
    if line:find('BUILD SUCCESSFUL', 1, true) then
      status.build = 'successful'
    elseif line:find('BUILD FAILED', 1, true) or line:find('ToolchainProvisioningException', 1, true) then
      status.build = 'failed'
    end
  end
  -- Which Java the build actually asked for. When the project pins a
  -- toolchain (languageVersion = N) and JAVA_HOME points elsewhere, Gradle
  -- fails to configure even though N is installed — because version-manager
  -- layouts (mise, …) are invisible to its auto-detection, and the Tooling
  -- API forwards no GRADLE_OPTS to pass extra installation paths through.
  local want = tail:match('matching: {languageVersion=(%d+)')
  if want then
    status.wanted_toolchain = tonumber(want)
  end
  if not status.libraries and not status.build then
    return nil
  end
  return status
end

--- Which live Neovim owns this project's server, going by the pidfile the
--- owning instance drops in the workspace dir. Returns nil when unowned or
--- the recorded process is dead (stale file).
---@param root string
---@return integer? pid
function M.owner_pid(root)
  local f = io.open(M.for_root(root) .. '/nvim.pid', 'r')
  if not f then
    return nil
  end
  local pid = tonumber(f:read('*l') or '')
  f:close()
  if not pid or pid == vim.uv.os_getpid() then
    return nil
  end
  return vim.uv.kill(pid, 0) == 0 and pid or nil
end

---@param root string
function M.claim(root)
  local f = io.open(M.for_root(root) .. '/nvim.pid', 'w')
  if f then
    f:write(tostring(vim.uv.os_getpid()))
    f:close()
  end
end

---@param root string
function M.release(root)
  local path = M.for_root(root) .. '/nvim.pid'
  local f = io.open(path, 'r')
  if f then
    local pid = tonumber(f:read('*l') or '')
    f:close()
    if pid == vim.uv.os_getpid() then
      os.remove(path)
    end
  end
end

--- Watch the server log for the outcome of the import that starts after
--- `now`, and call `on_done({ build, libraries })` once it lands. The server
--- publishes no $/progress for imports (verified), so the log tail is the
--- only signal. Times out silently after 15 minutes.
---@param root string
---@param on_done fun(status: { build: string?, libraries: integer? })
function M.watch_import(root, on_done)
  local path = M.log_file(root)
  local offset = 0
  do
    local f = io.open(path, 'r')
    if f then
      offset = f:seek('end')
      f:close()
    end
  end

  local timer = vim.uv.new_timer()
  local elapsed = 0
  timer:start(
    5000,
    5000,
    vim.schedule_wrap(function()
      elapsed = elapsed + 5
      local f = io.open(path, 'r')
      if f then
        f:seek('set', offset)
        local appended = f:read('*a') or ''
        f:close()

        local build
        if appended:find('BUILD SUCCESSFUL', 1, true) then
          build = 'successful'
        elseif appended:find('BUILD FAILED', 1, true) then
          build = 'failed'
        end
        local libs
        for n in appended:gmatch('There are (%d+) libraries to load') do
          libs = tonumber(n)
        end

        -- The library count trails BUILD SUCCESSFUL by a moment; report once
        -- it shows up (or on failure immediately).
        if build == 'failed' or (build == 'successful' and libs) then
          timer:stop()
          timer:close()
          on_done({ build = build, libraries = libs })
          return
        end
      end
      if elapsed >= 900 then
        timer:stop()
        timer:close()
      end
    end)
  )
end

--- One-line remedy for a toolchain-mismatch import failure, or nil when the
--- failure is something else (or nothing failed).
---@param root string
---@return string?
function M.toolchain_advice(root)
  local status = M.import_status(root)
  if not status or not status.wanted_toolchain or status.build ~= 'failed' then
    return nil
  end
  local want = status.wanted_toolchain
  for _, c in ipairs(require('intellij-lsp.jdk').list()) do
    if c.version == want then
      return ('this project builds with Java %d — set jdk_version = %d (found at %s), then :IntellijCleanWorkspace and restart'):format(
        want,
        want,
        c.path
      )
    end
  end
  return ('this project builds with Java %d, which was not found — install it, then :IntellijCleanWorkspace and restart'):format(
    want
  )
end

local function rmrf(path)
  if vim.fn.isdirectory(path) == 0 then
    return false
  end
  vim.fn.delete(path, 'rf')
  return true
end

--- Stop clients for `root` and delete its server state.
---@param root string
---@param include_analyzer_cache? boolean Also clear the shared JetBrains cache.
function M.clean(root, include_analyzer_cache)
  for _, client in ipairs(vim.lsp.get_clients({ name = 'intellij' })) do
    if not root or client.root_dir == root then
      client:stop(true)
    end
  end

  local dir = M.base() .. sep .. vim.fn.fnamemodify(root, ':p:h:t') .. '-'
    .. vim.fn.sha256(vim.fn.fnamemodify(root, ':p')):sub(1, 8)

  if rmrf(dir) then
    vim.notify('intellij-lsp: removed ' .. dir, vim.log.levels.INFO)
  end

  if include_analyzer_cache then
    local cache = M.analyzer_cache()
    if cache and rmrf(cache) then
      vim.notify('intellij-lsp: removed analyzer cache ' .. cache, vim.log.levels.INFO)
    end
  end
end

return M
