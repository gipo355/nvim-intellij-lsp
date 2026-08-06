---@mod intellij-lsp.settings Server settings, mirrored from the VS Code client
---
--- Every key and default below is taken from the extension's own
--- `contributes.configuration` (see `recon/package.json`). The server pulls
--- these through `workspace/configuration`, so if we do not answer with them it
--- falls back to its own internals and features like inlay hints go quiet.
---
--- Two namespaces are in play, and they are not interchangeable:
---   `intellij.*`  — client/runtime concerns (JDK, build tool, Bazel, tracing)
---   `jetbrains.*` — language features (inlay hints, file templates)
---
--- Note the literal spaces in the Java hint keys. They are correct.

local M = {}

--- `jetbrains.java.hints.*` and friends, with the extension's defaults.
M.java_hints = {
  ['jetbrains.java.hints.collapse complex types'] = true,
  ['jetbrains.java.hints.settings.method parameter'] = true,
  ['jetbrains.java.hints.types.local variable'] = true,
  ['jetbrains.java.settings.types.lambda parameter'] = true,
  ['jetbrains.java.hints.types.call chain'] = true,
}

--- `jetbrains.kotlin.hints.*`, with the extension's defaults.
M.kotlin_hints = {
  ['jetbrains.kotlin.hints.settings.types.property'] = true,
  ['jetbrains.kotlin.hints.settings.types.variable'] = true,
  ['jetbrains.kotlin.hints.type.function.return'] = true,
  ['jetbrains.kotlin.hints.type.function.parameter'] = true,
  ['jetbrains.kotlin.hints.settings.lambda.return'] = true,
  ['jetbrains.kotlin.hints.lambda.receivers.parameters'] = true,
  ['jetbrains.kotlin.hints.settings.value.ranges'] = true,
  ['jetbrains.kotlin.hints.value.kotlin.time'] = true,
  ['jetbrains.kotlin.hints.parameters'] = true,
  ['jetbrains.kotlin.hints.parameters.compiled'] = true,
  ['jetbrains.kotlin.hints.parameters.excluded'] = false,
  ['jetbrains.kotlin.hints.call.chains'] = false,
}

--- Assemble the settings table for the current options.
---@param opts intellij.Opts
---@param jdk? string Resolved JDK path, from `intellij-lsp.jdk`.
---@return table
function M.build(opts, jdk)
  local settings = {
    -- The server resolves URIs (decompiled sources, library roots) on demand
    -- and the default client timeout is too tight for cold indexes.
    uri_timeout_ms = 5000,
  }

  if opts.inlay_hints ~= false then
    settings = vim.tbl_extend('force', settings, M.java_hints, M.kotlin_hints)
  end

  -- Runtime namespace. The extension reads jdkForSymbolResolution into
  -- initializationOptions.defaultSdk as well; we do both, since the server
  -- may ask for either.
  if jdk then
    settings['intellij.jdkForSymbolResolution'] = jdk
  end
  if opts.build_tool then
    settings['intellij.buildTool'] = opts.build_tool
  end
  if opts.jvm_args and #opts.jvm_args > 0 then
    settings['intellij.additionalJvmArgs'] = opts.jvm_args
  end
  if opts.bazel_projectview then
    settings['intellij.bazel.projectview'] = opts.bazel_projectview
  end
  if opts.bazel_build ~= nil then
    settings['intellij.bazel.build'] = opts.bazel_build
  end

  return vim.tbl_deep_extend('force', settings, opts.settings or {})
end

return M
