---@mod intellij-lsp.actions Code-action helpers
---
--- The server exposes organize-imports as a `source.organizeImports` code
--- action (verified against zuul). Requesting the action instead of calling
--- `java.organize.imports` directly means we never have to guess the
--- command's argument shape — the action's own command/edit carries it.

local M = {}

--- Run the organize-imports action for a buffer and wait for it, so it can
--- sit on `BufWritePre` and the write picks up the result.
---@param client vim.lsp.Client
---@param bufnr integer
---@param timeout_ms integer
function M.organize_imports_sync(client, bufnr, timeout_ms)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    range = {
      start = { line = 0, character = 0 },
      ['end'] = { line = 0, character = 0 },
    },
    context = { diagnostics = {}, only = { 'source.organizeImports' } },
  }

  local resp = client:request_sync('textDocument/codeAction', params, timeout_ms, bufnr)
  local action = resp and resp.result and resp.result[1]
  if not action then
    return
  end

  if action.edit then
    vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
  end
  if action.command then
    local cmd = type(action.command) == 'table' and action.command or action
    local done = false
    client:request('workspace/executeCommand', {
      command = cmd.command,
      arguments = cmd.arguments,
    }, function()
      done = true
    end, bufnr)
    -- The edit comes back as workspace/applyEdit; give it a beat to land
    -- before the write proceeds.
    vim.wait(timeout_ms, function()
      return done
    end, 10)
  end
end

return M
