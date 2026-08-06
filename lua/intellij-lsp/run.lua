---@mod intellij-lsp.run Running a main class without a debugger
---
--- The server can answer everything needed to build a `java` invocation
--- (shapes verified against zuul):
---
---   intellij.java.resolveClasspath        { uri }  → { classpath: string[] }
---   intellij.java.resolveWorkingDirectory { uri }  → working dir
---   intellij.java.resolveJavaExecutable   { uri }  → may fail with "No JDK
---     configured for the project"; the JDK we resolved ourselves is the
---     fallback, and `java` on $PATH after that.

local M = {}

---@param client vim.lsp.Client
---@param command string
---@param uri string
---@param cb fun(result: any, err: any)
local function exec(client, command, uri, cb)
  client:request('workspace/executeCommand', {
    command = command,
    arguments = { { uri = uri } },
  }, function(err, result)
    cb(result, err)
  end)
end

local main_class

--- Fully-qualified name of the main class in a buffer, or nil.
---@param bufnr integer
---@return string?
function M.main_class_of(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return main_class(bufnr)
end

---@param bufnr integer
---@return string?
function main_class(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local package_name, class_name, has_main
  for _, line in ipairs(lines) do
    package_name = package_name or line:match('^%s*package%s+([%w%.]+)%s*;')
    class_name = class_name or line:match('^%s*public%s+[%w%s]-class%s+([%w_]+)')
    if line:match('public%s+static%s+void%s+main%s*%(') or line:match('static%s+public%s+void%s+main%s*%(') then
      has_main = true
    end
  end
  if not (class_name and has_main) then
    return nil
  end
  return package_name and (package_name .. '.' .. class_name) or class_name
end

--- Resolve everything needed to invoke the current buffer's main class.
--- Calls `cb({ java, classpath, main_class, cwd })`, or `cb(nil, reason)`.
---@param cb fun(inv: { java: string, classpath: string[], main_class: string, cwd: string }?, err: string?)
function M.build_invocation(cb)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'intellij' })[1]
  if not client then
    return cb(nil, 'no client attached to this buffer')
  end

  local fqn = main_class(bufnr)
  if not fqn then
    return cb(nil, 'no `public static void main` in this buffer')
  end

  local uri = vim.uri_from_bufnr(bufnr)

  exec(client, 'intellij.java.resolveClasspath', uri, function(cp_result, cp_err)
    local classpath = cp_result and cp_result.classpath
    if not classpath or #classpath == 0 then
      return cb(
        nil,
        'could not resolve the classpath\n'
          .. vim.inspect(cp_err or cp_result)
          .. '\nHas the project finished importing? (:checkhealth intellij-lsp)'
      )
    end

    exec(client, 'intellij.java.resolveJavaExecutable', uri, function(exe_result)
      local java = type(exe_result) == 'string' and exe_result
        or (type(exe_result) == 'table' and (exe_result.javaExecutable or exe_result.executable))
        or nil
      if not java then
        local jdk = require('intellij-lsp.jdk').resolve(require('intellij-lsp').options())
        java = jdk and (jdk .. '/bin/java') or vim.fn.exepath('java')
      end
      if not java or java == '' then
        return cb(nil, 'no java executable found to run with')
      end

      -- Answer shape verified: { workingDirectory = "/abs/path" }
      exec(client, 'intellij.java.resolveWorkingDirectory', uri, function(wd_result)
        local cwd = (type(wd_result) == 'table' and wd_result.workingDirectory)
          or (type(wd_result) == 'string' and wd_result)
          or client.root_dir
        cb({ java = java, classpath = classpath, main_class = fqn, cwd = cwd })
      end)
    end)
  end)
end

--- The server does NOT compile before launch (verified: launch on an
--- unbuilt project dies with ClassNotFoundException) — the IDE runs a build
--- step first, the language server does not. When every module-output
--- entry on the resolved classpath is missing, offer to build, then
--- continue.
---@param root string
---@param classpath string[]
---@param cb fun(ok: boolean)
function M.ensure_compiled(root, classpath, cb)
  local outputs, missing = 0, 0
  for _, entry in ipairs(classpath) do
    if entry:find('/build/classes', 1, true) or entry:find('/out/production', 1, true) then
      outputs = outputs + 1
      if vim.fn.isdirectory(entry) == 0 then
        missing = missing + 1
      end
    end
  end
  if outputs == 0 or missing == 0 then
    return cb(true)
  end

  local gradlew = root .. '/gradlew'
  local build_cmd = vim.fn.executable(gradlew) == 1 and { gradlew, 'classes', '-q' }
    or (vim.fn.filereadable(root .. '/pom.xml') == 1 and { 'mvn', '-q', 'compile' } or nil)
  if not build_cmd then
    vim.notify(
      ('intellij-lsp: %d/%d module output dirs missing and no build tool found — build the project first'):format(
        missing,
        outputs
      ),
      vim.log.levels.ERROR
    )
    return cb(false)
  end

  local choice = vim.fn.confirm(
    ('Compiled output is missing (%d/%d module dirs). The server does not compile before launch.\nRun `%s` now?'):format(
      missing,
      outputs,
      table.concat(build_cmd, ' ')
    ),
    '&Build and continue\n&Cancel',
    1
  )
  if choice ~= 1 then
    return cb(false)
  end

  vim.notify('intellij-lsp: building… (' .. table.concat(build_cmd, ' ') .. ')', vim.log.levels.INFO)
  vim.fn.jobstart(build_cmd, {
    cwd = root,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          cb(true)
        else
          vim.notify('intellij-lsp: build failed (exit ' .. code .. ') — fix and retry', vim.log.levels.ERROR)
          cb(false)
        end
      end)
    end,
  })
end

--- Resolve everything and run the current buffer's main class in a terminal
--- split.
---@param args? string program arguments, appended verbatim
function M.run(args)
  M.build_invocation(function(inv, err)
    if not inv then
      vim.notify('intellij-lsp: ' .. tostring(err), vim.log.levels.WARN)
      return
    end
    local client = vim.lsp.get_clients({ name = 'intellij' })[1]
    M.ensure_compiled(client and client.root_dir or inv.cwd, inv.classpath, function(ok)
      if ok then
        M.spawn_terminal(inv, args)
      end
    end)
  end)
end

---@param inv table
---@param args? string
function M.spawn_terminal(inv, args)
  do
    -- The classpath easily exceeds ARG_MAX comfort; use an argfile.
    local argfile = vim.fn.tempname()
    vim.fn.writefile({ '-cp', table.concat(inv.classpath, ':') }, argfile)

    local cmd = ('%s @%s %s%s'):format(
      vim.fn.shellescape(inv.java),
      vim.fn.shellescape(argfile),
      inv.main_class,
      (args and args ~= '') and (' ' .. args) or ''
    )

    vim.cmd('botright split | terminal cd ' .. vim.fn.shellescape(inv.cwd) .. ' && ' .. cmd)
  end
end

return M
