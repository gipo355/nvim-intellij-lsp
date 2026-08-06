---@mod intellij-lsp.completion Making command-driven completion work in Neovim
---
--- The server does not put the inserted text in its completion items. Items
--- arrive with an *empty* `textEdit` plus a `jetbrains.*.completion.apply`
--- command; the real work happens server-side once the client runs that
--- command, which comes back as `workspace/applyEdit` (text and imports) and
--- `window/showDocument` (caret placement).
---
--- VS Code's client inserts nothing on accept and simply runs the command, so
--- it gets all of that for free. Neovim's completion frontends instead insert
--- the item's own text — the `label`, since `newText` is empty — and *then* run
--- the command, so the server's edit is computed against a document that no
--- longer matches and the caret lands mid-identifier.
---
--- The fix is to make the client's own insertion a no-op: replace the typed
--- prefix with itself. The buffer is then unchanged when the command runs, the
--- server's diff applies cleanly, and imports and caret come along with it.
---
--- Frontends issue completion requests with an inline callback rather than
--- going through the config's `handlers` table, so the only universal hook is
--- the client's `request` method.
---
--- Prior art: the same problem and approach appear in kotlin.nvim, which
--- covers kotlin-lsp. This is an independent implementation, generalised over
--- the command and data-key names so it also covers the Java side.

local M = {}

--- e.g. `jetbrains.kotlin.completion.apply`, `jetbrains.java.completion.apply`
local APPLY_PATTERN = '^jetbrains%.[%w_]+%.completion%.apply$'

--- Items carry their server-side identity under a language-specific key
--- (`KotlinCompletionItemKey` and friends), so match on the suffix.
local ID_KEY_PATTERN = 'CompletionItemKey$'

--- No-op edits from the most recent completion list, keyed by server item id.
--- `completionItem/resolve` re-sends the empty edit, so we restore ours.
local noop_edits = {}

---@param item table
---@return boolean
local function is_command_driven(item)
  return type(item) == 'table'
    and type(item.command) == 'table'
    and type(item.command.command) == 'string'
    and item.command.command:match(APPLY_PATTERN) ~= nil
end

---@param item table
---@return any?
local function item_id(item)
  if type(item.data) ~= 'table' then
    return nil
  end
  for key, value in pairs(item.data) do
    if type(key) == 'string' and key:match(ID_KEY_PATTERN) then
      return value
    end
  end
  return nil
end

--- An edit replacing the identifier prefix ending at the completion position
--- with itself. Offsets are byte-based, which matches LSP character offsets for
--- the ASCII identifiers that make up essentially all Java and Kotlin symbols.
---@param params table textDocument/completion params
---@return table? edit
local function noop_prefix_edit(params)
  if not (params and params.position and params.textDocument) then
    return nil
  end

  local pos = params.position
  local ok, bufnr = pcall(vim.uri_to_bufnr, params.textDocument.uri)
  if not ok then
    return nil
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ''

  local start = pos.character
  while start > 0 and line:sub(start, start):match('[%w_$]') do
    start = start - 1
  end

  return {
    range = {
      start = { line = pos.line, character = start },
      ['end'] = { line = pos.line, character = pos.character },
    },
    newText = line:sub(start + 1, pos.character),
  }
end

---@param result table completion list or item array
---@param params table
local function patch_list(result, params)
  local items = result.items or result
  if type(items) ~= 'table' then
    return
  end

  local edit
  noop_edits = {}

  for _, item in ipairs(items) do
    if is_command_driven(item) then
      edit = edit or noop_prefix_edit(params)
      if not edit then
        return
      end
      item.textEdit = { range = edit.range, newText = edit.newText }
      item.insertTextFormat = 1 -- PlainText: never snippet-expand a no-op
      local id = item_id(item)
      if id ~= nil then
        noop_edits[id] = item.textEdit
      end
    end
  end
end

---@param result table resolved completion item
local function patch_resolved(result)
  if not is_command_driven(result) then
    return
  end
  local id = item_id(result)
  local edit = id ~= nil and noop_edits[id] or nil
  if edit then
    result.textEdit = { range = edit.range, newText = edit.newText }
    result.insertTextFormat = 1
  end
end

--- Wrap a client's `request` so every frontend sees normalised items.
--- Idempotent.
---@param client vim.lsp.Client
function M.attach(client)
  if not require('intellij-lsp').options().completion_fix then
    return
  end
  if rawget(client, '_intellij_completion_wrapped') then
    return
  end
  client._intellij_completion_wrapped = true

  local original = client.request
  client.request = function(self, method, params, handler, bufnr)
    local wants_patch = handler
      and (method == 'textDocument/completion' or method == 'completionItem/resolve')

    if wants_patch then
      local inner = handler
      handler = function(err, result, ctx, cfg)
        if not err and type(result) == 'table' then
          local ok, patch_err = pcall(function()
            if method == 'textDocument/completion' then
              patch_list(result, params)
            else
              patch_resolved(result)
            end
          end)
          if not ok then
            vim.notify_once(
              'intellij-lsp: completion patch failed: ' .. tostring(patch_err),
              vim.log.levels.WARN
            )
          end
        end
        return inner(err, result, ctx, cfg)
      end
    end

    return original(self, method, params, handler, bufnr)
  end
end

--- Client-side handler for the VS Code `runCommands` chain some completion
--- items carry (postfix templates: caret placement + a rename prompt). The
--- text itself arrives as standard textEdit/additionalTextEdits and needs no
--- help; this only translates the follow-up UX. Wired into the client config
--- as `commands.runCommands`.
---@param cmd table LSP Command
---@param ctx table
function M.run_commands(cmd, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  local spec = cmd.arguments and cmd.arguments[1]
  if not (client and spec and type(spec.commands) == 'table') then
    return
  end

  for _, sub in ipairs(spec.commands) do
    if type(sub) == 'table' and type(sub.command) == 'string' then
      -- Server-side member of the chain (caret placement via ModCommand).
      client:request('workspace/executeCommand', {
        command = sub.command,
        arguments = { sub.args },
      }, function() end)
    elseif sub == 'editor.action.rename' then
      -- The postfix template just introduced a variable and VS Code would
      -- open its rename box; ours is vim.lsp.buf.rename, after the edits
      -- and caret placement have settled.
      vim.defer_fn(function()
        vim.lsp.buf.rename()
      end, 150)
    end
  end
end

--- Handler for the server-initiated `window/showDocument` the apply command
--- uses to place the caret. Doing it in the current buffer directly avoids the
--- default handler's window switching and scrolling; anything else falls
--- through to the default.
---@param result lsp.ShowDocumentParams
---@param ctx table
function M.show_document(result, ctx)
  local ok, bufnr = pcall(vim.uri_to_bufnr, result.uri)
  if ok and not result.external and result.selection and bufnr == vim.api.nvim_get_current_buf() then
    local s = result.selection.start
    pcall(vim.api.nvim_win_set_cursor, 0, { s.line + 1, s.character })
    return { success = true }
  end
  return vim.lsp.handlers['window/showDocument'](nil, result, ctx)
end

return M
