---@mod intellij-lsp.jdk Finding a JDK for symbol resolution
---
--- This is the JDK the server analyses your code *against* — not the one it
--- runs on, which is the JBR bundled with the launcher. Getting it wrong is
--- quiet and confusing rather than loud: go-to-definition inside your own code
--- keeps working, while hover, references and completion on anything from the
--- JDK return nothing at all, because there is no JDK to resolve them in.
---
--- A configured path that does not exist is therefore worth a loud warning.

local M = {}

--- Directories that look like a JDK root, newest-looking last so callers can
--- prefer later entries.
local SEARCH = {
  -- version managers people actually use
  '~/.local/share/mise/installs/java',
  '~/.sdkman/candidates/java',
  '~/.asdf/installs/java',
  '~/.jenv/versions',
  -- Gradle-provisioned toolchains (auto-downloaded by builds)
  '~/.gradle/jdks',
  -- distro locations
  '/usr/lib/jvm',
  '/usr/local/lib/jvm',
  '/Library/Java/JavaVirtualMachines',
}

--- The JDK the user has actively *selected* through their version manager or
--- distro tooling, as opposed to merely installed. Checked in order; cached
--- because `mise` costs a subprocess.
local selected_cache ---@type string|false|nil
local function selected_jdk()
  if selected_cache ~= nil then
    return selected_cache or nil
  end

  -- mise: the shell's active java, honoring .mise.toml and global config.
  if vim.fn.executable('mise') == 1 then
    local out = vim.system({ 'mise', 'where', 'java' }, { text = true }):wait(3000)
    if out.code == 0 and out.stdout then
      local dir = vim.trim(out.stdout)
      if dir ~= '' and vim.fn.executable(dir .. '/bin/javac') == 1 then
        selected_cache = vim.fn.resolve(dir)
        return selected_cache
      end
    end
  end

  -- sdkman and archlinux-java both express the choice as a symlink.
  for _, link in ipairs({ '~/.sdkman/candidates/java/current', '/usr/lib/jvm/default' }) do
    local dir = vim.fn.resolve(vim.fn.expand(link))
    if vim.fn.executable(dir .. '/bin/javac') == 1 then
      selected_cache = dir
      return selected_cache
    end
  end

  selected_cache = false
  return nil
end

---@param dir string
---@return boolean
local function is_jdk(dir)
  -- javac, not just java: we need a compiler-grade JDK, not a JRE.
  return vim.fn.executable(dir .. '/bin/javac') == 1
    or vim.fn.executable(dir .. '/Contents/Home/bin/javac') == 1
end

--- Normalise macOS bundle layout to the actual home.
---@param dir string
---@return string
local function home_of(dir)
  if vim.fn.executable(dir .. '/Contents/Home/bin/javac') == 1 then
    return dir .. '/Contents/Home'
  end
  return dir
end

--- Feature version of a JDK root, e.g. 21.
---@param dir string
---@return integer?
function M.version(dir)
  local release = dir .. '/release'
  if vim.fn.filereadable(release) == 1 then
    for _, line in ipairs(vim.fn.readfile(release)) do
      local v = line:match('^JAVA_VERSION="(%d+)')
      if v then
        return tonumber(v)
      end
    end
  end
  -- Fall back to the directory name: jdk-21.0.2, java-21-openjdk, 21.0.2, ...
  local name = vim.fs.basename(dir)
  local v = name:match('(%d+)')
  return v and tonumber(v) or nil
end

--- Every JDK we can find, as { path, version }.
---@return { path: string, version: integer? }[]
function M.list()
  local found, seen = {}, {}

  local function add(dir)
    dir = home_of(vim.fn.resolve(dir))
    if not seen[dir] and is_jdk(dir) then
      seen[dir] = true
      found[#found + 1] = { path = dir, version = M.version(dir) }
    end
  end

  if vim.env.JAVA_HOME and vim.env.JAVA_HOME ~= '' then
    add(vim.fn.expand(vim.env.JAVA_HOME))
  end

  for _, base in ipairs(SEARCH) do
    base = vim.fn.expand(base)
    if vim.fn.isdirectory(base) == 1 then
      if is_jdk(base) then
        add(base)
      end
      for _, entry in ipairs(vim.fn.glob(base .. '/*', false, true)) do
        add(entry)
      end
    end
  end

  return found
end

--- Pick a JDK, preferring `want` (a feature version) when we can satisfy it.
---@param want? integer
---@return string? path
---@return integer? version
function M.detect(want)
  local candidates = M.list()
  if #candidates == 0 then
    return nil, nil
  end

  if want then
    for _, c in ipairs(candidates) do
      if c.version == want then
        return c.path, c.version
      end
    end
  end

  -- With no version asked for, $JAVA_HOME is the user's own answer to this
  -- question and beats "newest installed".
  if vim.env.JAVA_HOME and vim.env.JAVA_HOME ~= '' then
    local home = home_of(vim.fn.resolve(vim.fn.expand(vim.env.JAVA_HOME)))
    for _, c in ipairs(candidates) do
      if c.path == home then
        return c.path, c.version
      end
    end
  end

  -- Next best user answer: the version their manager has *selected*
  -- (mise current, sdkman current, archlinux-java default) — installed-but-
  -- not-chosen versions shouldn't win just by being newer.
  local chosen = selected_jdk()
  if chosen then
    for _, c in ipairs(candidates) do
      if c.path == chosen then
        return c.path, c.version
      end
    end
  end

  table.sort(candidates, function(a, b)
    return (a.version or 0) > (b.version or 0)
  end)
  return candidates[1].path, candidates[1].version
end

--- The JDK to hand the server, with the configured value validated first.
---@param opts intellij.Opts
---@return string? path
function M.resolve(opts)
  if opts.jdk then
    local dir = vim.fn.expand(opts.jdk)
    if is_jdk(dir) then
      return home_of(dir)
    end

    -- Loud, because the failure mode downstream is silence.
    local fallback, version = M.detect(opts.jdk_version)
    vim.notify_once(
      ('intellij-lsp: configured jdk is not a JDK: %s\n%s'):format(
        opts.jdk,
        fallback and ('Falling back to ' .. fallback .. (version and (' (java ' .. version .. ')') or ''))
          or 'No other JDK found — hover and references on JDK symbols will be empty.'
      ),
      vim.log.levels.WARN
    )
    return fallback
  end

  if opts.jdk == false then
    return nil
  end

  return (M.detect(opts.jdk_version))
end

return M
