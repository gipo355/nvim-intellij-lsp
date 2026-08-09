---@mod intellij-lsp.eula The bundled EAP agreement
---
--- The server refuses to initialize until the client passes the hash of the
--- agreement it ships:
---
---   Bundled license agreement (EULA.txt) is not accepted: expected hash
---   34d850193ee04897, got <none>. Pass the accepted EULA hash as `eulaHash`
---   in LSP initializationOptions.
---
--- The hash is the first 16 hex characters of the SHA-256 of `EULA.txt`, which
--- sits next to the launcher. Computing it from the file means acceptance stays
--- correct across server updates — and, more importantly, that a new agreement
--- produces a new hash and has to be accepted again rather than silently
--- inheriting the old consent.
---
--- Nothing here accepts on your behalf. `:IntellijAcceptEula` shows the text
--- and takes an explicit confirmation; `accept_eula = true` in your config is
--- the declarative equivalent. Until one of those happens we do not start the
--- server at all.

local M = {}

--- Path to the agreement shipped with an install.
---@param launcher string Path to bin/intellij-server
---@return string? path
function M.path(launcher)
  -- <root>/bin/intellij-server -> <root>/EULA.txt
  local root = vim.fs.dirname(vim.fs.dirname(launcher))
  local eula = root .. '/EULA.txt'
  if vim.fn.filereadable(eula) == 1 then
    return eula
  end
  return nil
end

--- Hash of the agreement, in the form the server expects.
---@param launcher string
---@return string? hash
---@return string? path
function M.hash(launcher)
  local path = M.path(launcher)
  if not path then
    return nil, nil
  end
  local content = table.concat(vim.fn.readfile(path, 'b'), '\n')
  return vim.fn.sha256(content):sub(1, 16), path
end

---@return string
local function store_path()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'intellij-lsp', 'eula-accepted.json')
end

---@return table<string, string> hash -> ISO date accepted
local function read_store()
  local path = store_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  return (ok and type(decoded) == 'table') and decoded or {}
end

--- Record acceptance of a specific agreement hash.
---@param hash string
function M.record(hash)
  local store = read_store()
  store[hash] = os.date('%Y-%m-%dT%H:%M:%S')

  local path = store_path()
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile({ vim.json.encode(store) }, path)
end

--- Whether the agreement for this install has been accepted, either previously
--- recorded or declared in the user's config.
---@param launcher string
---@return boolean accepted
---@return string? hash
function M.accepted(launcher)
  local hash = M.hash(launcher)
  if not hash then
    -- No bundled agreement means nothing to accept — older builds, or a
    -- layout we do not recognise. Let the server decide.
    return true, nil
  end

  if require('intellij-lsp').options().accept_eula == true then
    return true, hash
  end

  return read_store()[hash] ~= nil, hash
end

--- Show the agreement and ask for an explicit yes.
---@param launcher? string
---@param on_accept? fun() Called after acceptance is recorded, in place of the
--- "run :IntellijRestart" hint.
function M.prompt(launcher, on_accept)
  launcher = launcher or require('intellij-lsp.server').find_or_notify()
  if not launcher then
    return
  end

  local hash, path = M.hash(launcher)
  if not hash or not path then
    vim.notify('intellij-lsp: no EULA.txt found next to ' .. launcher, vim.log.levels.WARN)
    return
  end

  if read_store()[hash] then
    vim.notify('intellij-lsp: this agreement (' .. hash .. ') is already accepted', vim.log.levels.INFO)
    return
  end

  -- Show the actual text. Accepting terms you have not been shown is not
  -- consent, so this is not skippable.
  vim.cmd('botright split ' .. vim.fn.fnameescape(path))
  vim.bo.modifiable = false
  vim.bo.readonly = true

  vim.schedule(function()
    local choice = vim.fn.confirm(
      'Accept this JetBrains agreement (' .. hash .. ')?\n' .. path,
      '&Yes, I accept\n&No',
      2, -- default to No
      'Question'
    )

    if choice ~= 1 then
      vim.notify('intellij-lsp: not accepted — the server will not start', vim.log.levels.WARN)
      return
    end

    M.record(hash)
    if on_accept then
      vim.notify('intellij-lsp: accepted ' .. hash, vim.log.levels.INFO)
      on_accept()
      return
    end
    vim.notify(
      'intellij-lsp: accepted ' .. hash .. '\nRun :IntellijRestart or reopen the file.',
      vim.log.levels.INFO
    )
  end)
end

return M
