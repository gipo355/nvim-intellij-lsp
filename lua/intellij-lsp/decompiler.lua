---@mod intellij-lsp.decompiler Opening library and JDK sources
---
--- Go-to-definition on anything outside your own source tree resolves to a URI
--- Neovim cannot read: `jar://…` for a dependency, `jrt://…` for a JDK class
--- from the runtime image. Left alone, Neovim creates an empty buffer with that
--- URI as its name, which is what "can't see decompiled classes" looks like.
---
--- The server exposes a `decompile` executeCommand that takes the URI and
--- returns `{ code, language }` — real sources when it can find them (a JDK's
--- `lib/src.zip`, an attached `-sources.jar`), decompiled bytecode otherwise.
--- We intercept the read with `BufReadCmd` and fill the buffer ourselves.

local M = {}

--- URI schemes the server hands back for non-file locations.
M.SCHEMES = { 'jar', 'jrt' }

---@param uri string
---@return boolean
local function is_handled(uri)
  for _, scheme in ipairs(M.SCHEMES) do
    if vim.startswith(uri, scheme .. ':') then
      return true
    end
  end
  return false
end

--- Ask the server for the contents behind a URI and write them into `bufnr`.
---@param bufnr integer
---@param uri string
function M.open(bufnr, uri)
  if not is_handled(uri) then
    return
  end

  local client = vim.lsp.get_clients({ name = 'intellij' })[1]
  if not client then
    vim.notify(
      'intellij-lsp: no client to decompile ' .. uri .. '\nOpen a project file first.',
      vim.log.levels.WARN
    )
    return
  end

  -- Scratch buffer: there is no file on disk behind this, and writing must not
  -- be offered.
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buftype = 'nofile'

  local done = false

  client:request('workspace/executeCommand', {
    command = 'decompile',
    arguments = { uri },
  }, function(err, result)
    done = true

    if err or type(result) ~= 'table' or type(result.code) ~= 'string' then
      vim.schedule(function()
        vim.notify(
          'intellij-lsp: could not decompile ' .. uri .. '\n' .. vim.inspect(err or result),
          vim.log.levels.ERROR
        )
      end)
      return
    end

    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end

      local text = result.code:gsub('\r\n', '\n')
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, '\n', { plain = true }))

      -- The server names the language; fall back to java rather than leaving
      -- the buffer unhighlighted.
      vim.bo[bufnr].filetype = (result.language and result.language:lower()) or 'java'
      vim.bo[bufnr].modifiable = false
      vim.bo[bufnr].modified = false
    end)
  end, bufnr)

  -- Block briefly: whatever triggered the jump (go-to-definition) sets the
  -- cursor right after this returns, and doing that against an empty buffer
  -- puts it at line 1 instead of the symbol.
  local timeout = require('intellij-lsp').options().uri_timeout_ms or 5000
  vim.wait(timeout, function()
    return done
  end, 25)
end

--- Register the `BufReadCmd` interception. Idempotent.
function M.setup()
  local patterns = {}
  for _, scheme in ipairs(M.SCHEMES) do
    -- Both forms show up depending on how the URI reaches the editor.
    table.insert(patterns, scheme .. '://*')
    table.insert(patterns, scheme .. ':/*')
  end

  vim.api.nvim_create_autocmd('BufReadCmd', {
    group = vim.api.nvim_create_augroup('intellij_lsp_decompiler', { clear = true }),
    pattern = patterns,
    callback = function(ev)
      M.open(ev.buf, ev.match)
    end,
  })
end

return M
