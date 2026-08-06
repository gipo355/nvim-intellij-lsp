---@mod intellij-lsp.env The server's launch environment
---
--- Mirrors the extension's `buildLaunchEnvironment(env, jvmArgs, sharing, region)`:
---
--- ```js
--- let r = {...env};
--- if (jvmArgs.length > 0) {
---   let k = "IJ_JAVA_OPTIONS", prev = r[k] ?? "";
---   r[k] = prev ? `${prev} ${quoted}` : quoted;
--- }
--- delete r.IJ_LAUNCHER_DEBUG;
--- delete r.INTELLIJ_DATA_SHARING; if (sharing !== "none") r.INTELLIJ_DATA_SHARING = sharing;
--- delete r.INTELLIJ_REGION;      if (region)              r.INTELLIJ_REGION = region;
--- ```
---
--- Note it *appends* to an inherited `IJ_JAVA_OPTIONS` rather than replacing it,
--- and clears the other three so an exported value cannot leak in. Neovim's
--- spawn merges over the inherited environment instead of replacing it, so
--- there is no true delete available — we neutralise instead, using each
--- variable's own "off" value.

local M = {}

--- The client shell-quotes JVM args before joining them into one string.
---@param arg string
---@return string
local function shell_quote(arg)
  if arg:match("^[%w%-%_%=%.%,:/@]+$") then
    return arg
  end
  return "'" .. arg:gsub("'", "'\\''") .. "'"
end

--- Environment overrides for the server process, or nil when there are none.
---@param opts intellij.Opts
---@param jdk? string Resolved JDK, from `intellij-lsp.jdk`.
---@return table<string,string>?
function M.build(opts, jdk)
  local env = {}

  -- The server runs the build tool as a child and Gradle picks its JVM from
  -- the inherited environment, so `defaultSdk` alone is not enough: a project
  -- declaring a toolchain (`languageVersion = 21`) fails to configure with
  --   ToolchainProvisioningException: Cannot find a Java installation ...
  -- when JAVA_HOME points somewhere else, even with that JDK installed.
  -- Gradle counts the JVM running the build as an available toolchain, so
  -- lining JAVA_HOME up with the JDK we resolved satisfies the common case.
  --
  -- For projects needing several toolchains at once, tell Gradle where they
  -- live in ~/.gradle/gradle.properties:
  --   org.gradle.java.installations.paths=/path/to/jdk21,/path/to/jdk17
  -- Version-manager layouts (mise, sdkman, asdf) are not auto-detected.
  if jdk then
    env.JAVA_HOME = jdk
  end

  if opts.jvm_args and #opts.jvm_args > 0 then
    local quoted = table.concat(vim.tbl_map(shell_quote, opts.jvm_args), ' ')
    local inherited = vim.env.IJ_JAVA_OPTIONS
    env.IJ_JAVA_OPTIONS = (inherited and inherited ~= '') and (inherited .. ' ' .. quoted) or quoted
  end

  -- Stripped by the client; only worth overriding if it is actually exported.
  if vim.env.IJ_LAUNCHER_DEBUG then
    env.IJ_LAUNCHER_DEBUG = ''
  end

  -- Telemetry stays off unless asked for. 'none' is a value the client itself
  -- recognises, so it is a safe way to override an inherited setting.
  local sharing = opts.data_sharing or 'none'
  if sharing ~= 'none' then
    env.INTELLIJ_DATA_SHARING = sharing
  elseif vim.env.INTELLIJ_DATA_SHARING then
    env.INTELLIJ_DATA_SHARING = 'none'
  end

  if opts.region and opts.region ~= '' and opts.region ~= 'not_set' then
    env.INTELLIJ_REGION = opts.region
  elseif vim.env.INTELLIJ_REGION then
    env.INTELLIJ_REGION = ''
  end

  return next(env) and env or nil
end

return M
