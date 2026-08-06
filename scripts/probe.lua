-- Headless probe harness for nvim-intellij-lsp against a real project.
-- Run: nvim --headless --clean -l probe.lua <probe> [<probe>...]
-- Probes: ready caps def_jrt def_jar completion codeactions exec rename diags reimport
-- Results land in results-<probe>.json next to this file.

local REPO = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
local HERE = vim.env.PROBE_OUT or vim.uv.cwd()
local TARGET = vim.env.PROBE_FILE
  or error('set $PROBE_FILE to a Java file in the test project')

local function say(msg)
  io.stdout:write('[probe] ' .. msg .. '\n')
  io.stdout:flush()
end

local function dump(name, tbl)
  local path = HERE .. '/results-' .. name .. '.json'
  local f = assert(io.open(path, 'w'))
  f:write(vim.json.encode(tbl))
  f:close()
  say('wrote ' .. path)
end

-- Watchdog: a wedged run must not squat on the shared index lock.
local watchdog = vim.uv.new_timer()
watchdog:start(12 * 60 * 1000, 0, function()
  io.stdout:write('[probe] WATCHDOG: force quit\n')
  os.exit(3)
end)

vim.opt.rtp:prepend(REPO)
require('intellij-lsp').setup({
  jdk_version = tonumber(vim.env.PROBE_JDK_VERSION) or 21,
})

vim.cmd.edit(TARGET)
local bufnr = vim.api.nvim_get_current_buf()
if vim.bo[bufnr].filetype ~= 'java' then
  vim.bo[bufnr].filetype = 'java'
end

say('waiting for client attach...')
local ok = vim.wait(60000, function()
  return #vim.lsp.get_clients({ bufnr = bufnr, name = 'intellij' }) > 0
end, 200)
if not ok then
  say('FAIL: client never attached')
  dump('attach', { attached = false })
  os.exit(1)
end
local client = vim.lsp.get_clients({ bufnr = bufnr, name = 'intellij' })[1]
say('attached, client id ' .. client.id)

-- 0.11+ method form with fallback to the legacy dot form.
local function req(method, params, timeout)
  timeout = timeout or 15000
  local res, err
  if client.request_sync then
    if vim.startswith(tostring(client.request_sync), 'function') then
    end
  end
  local call_ok, r = pcall(function()
    return client:request_sync(method, params, timeout, bufnr)
  end)
  if not call_ok then
    r = client.request_sync(method, params, timeout, bufnr)
  end
  if r == nil then
    return nil, 'timeout'
  end
  return r.result, r.err
end

-- 0-indexed LSP position of the first match of `pat` (lua pattern) in the
-- buffer, offset to land inside the capture/occurrence.
local function pos_of(pat, which)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local n = 0
  for i, line in ipairs(lines) do
    local s = line:find(pat)
    if s then
      n = n + 1
      if not which or n == which then
        return { line = i - 1, character = s - 1 + (which and 0 or 0) }, line
      end
    end
  end
  return nil
end

local function tdid()
  return { uri = vim.uri_from_bufnr(bufnr) }
end

-- Import readiness: definition on a library (jar) symbol only resolves once
-- the workspace model is loaded. Probe a *usage* in code — definition on
-- import lines is not answered by this server (verified).
local function wait_ready(seconds)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local pos
  for i, line in ipairs(lines) do
    if not line:match('^import') then
      local s = line:find('SslContextBuilder')
      if s then
        pos = { line = i - 1, character = s + 2 }
        break
      end
    end
  end
  assert(pos, 'no library-symbol usage found in target file')
  local deadline = vim.uv.now() + seconds * 1000
  while vim.uv.now() < deadline do
    local result = req('textDocument/definition', { textDocument = tdid(), position = pos }, 5000)
    if result and (result.uri or result.targetUri or (result[1] and (result[1].uri or result[1].targetUri))) then
      return true, result
    end
    vim.wait(3000)
  end
  return false
end

local probes = {}

function probes.ready()
  say('waiting for import readiness (up to 240s)...')
  local ready, result = wait_ready(240)
  dump('ready', { ready = ready, sample = result })
  say('ready=' .. tostring(ready))
end

function probes.caps()
  local progress_seen = {}
  for _, item in ipairs(client.progress and client.progress:pop() and {} or {}) do
    table.insert(progress_seen, item)
  end
  -- The ring buffer pops destructively; peek at pending instead.
  local pending = {}
  if client.progress then
    for _, v in ipairs(client.progress.pending or {}) do
      table.insert(pending, v)
    end
  end
  dump('caps', {
    capabilities = client.server_capabilities,
    completion_trigger = (client.server_capabilities.completionProvider or {}).triggerCharacters,
    resolve_provider = (client.server_capabilities.codeActionProvider or {}),
    progress_pending = pending,
  })
end

-- Does the server answer for Gradle build files? (.kts arrives as filetype
-- kotlin; groovy build.gradle would need explicit wiring.)
function probes.buildfile()
  local root = vim.fs.root(TARGET, { 'settings.gradle', 'settings.gradle.kts', 'build.gradle' })
  if not root then
    dump('buildfile', { error = 'no gradle root above $PROBE_FILE' })
    return
  end
  local kts = vim.fn.glob(root .. '/*.gradle')
  local path = root .. '/build.gradle'
  vim.cmd.edit(path)
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].filetype = 'java' -- force-attach to see if the server accepts it
  vim.wait(3000)
  local attached = #vim.lsp.get_clients({ bufnr = b, name = 'intellij' }) > 0
  local hover
  if attached then
    local pos = { line = 5, character = 4 }
    local r = client:request_sync('textDocument/hover', { textDocument = { uri = vim.uri_from_bufnr(b) }, position = pos }, 10000, b)
    hover = r and r.result
  end
  dump('buildfile', { file = kts, attached = attached, hover = hover })
  vim.api.nvim_set_current_buf(bufnr)
end

local function goto_and_inspect(name, pat, char_offset)
  local pos, line = pos_of(pat)
  if not pos then
    dump(name, { error = 'pattern not found: ' .. pat })
    return
  end
  pos.character = pos.character + (char_offset or 0)
  local result, err = req('textDocument/definition', { textDocument = tdid(), position = pos }, 20000)
  local loc = result and (result[1] or result)
  local out = { pattern = pat, line = line, result_err = err, raw = result }
  if loc and (loc.uri or loc.targetUri) then
    local uri = loc.uri or loc.targetUri
    out.uri = uri
    -- Exercise the real decompiler path.
    local shown = vim.lsp.util.show_document(loc, client.offset_encoding or 'utf-16', { focus = true })
    out.show_document_ok = shown
    local b = vim.api.nvim_get_current_buf()
    out.opened_buf_name = vim.api.nvim_buf_get_name(b)
    out.line_count = vim.api.nvim_buf_line_count(b)
    out.cursor = vim.api.nvim_win_get_cursor(0)
    out.first_lines = vim.api.nvim_buf_get_lines(b, 0, 12, false)
    local at = vim.api.nvim_buf_get_lines(b, out.cursor[1] - 1, out.cursor[1], false)
    out.line_at_cursor = at[1]
    vim.api.nvim_set_current_buf(bufnr)
  end
  dump(name, out)
end

function probes.def_jrt()
  -- Definition on import lines returns [] (server behavior, confirmed);
  -- anchor on a usage in code instead.
  goto_and_inspect('def_jrt', 'List<X509Certificate> trustedCerts', 1)
end

function probes.postfix_raw()
  local pos = pos_of('serverSslConfig%.getSessionTimeout')
  local row = pos.line + 1
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { '        serverSslConfig.var' })
  vim.wait(1500)
  local result = req('textDocument/completion', {
    textDocument = tdid(),
    position = { line = row, character = #'        serverSslConfig.var' },
    context = { triggerKind = 1 },
  }, 30000)
  local items = result and (result.items or result) or {}
  local raw = {}
  for i = 1, math.min(#items, 3) do
    raw[i] = items[i]
  end
  -- Also resolve the first one: the full edit may only arrive on resolve.
  local resolved
  if items[1] then
    resolved = req('completionItem/resolve', items[1], 15000)
  end
  dump('postfix_raw', { count = #items, raw = raw, resolved = resolved })
  vim.cmd('silent! edit!')
  vim.wait(500)
end

function probes.def_jar()
  goto_and_inspect('def_jar', 'import io%.netty%.handler%.ssl', 30)
end

-- Insert text after an anchor line, run completion at end of inserted text,
-- capture items, then reload buffer from disk.
local function completion_at(name, anchor_pat, insert_text)
  local pos = pos_of(anchor_pat)
  if not pos then
    dump(name, { error = 'anchor not found: ' .. anchor_pat })
    return
  end
  local row = pos.line + 1 -- insert AFTER anchor line, 0-indexed row for set_lines
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { insert_text })
  vim.wait(1500) -- let didChange land + server reanalyze
  local cpos = { line = row, character = #insert_text }
  local result, err = req('textDocument/completion', {
    textDocument = tdid(),
    position = cpos,
    context = { triggerKind = 1 },
  }, 30000)
  local items = result and (result.items or result) or {}
  local sample = {}
  for i = 1, math.min(#items, 40) do
    local it = items[i]
    sample[i] = {
      label = it.label,
      kind = it.kind,
      textEdit_newText = it.textEdit and it.textEdit.newText,
      has_command = it.command ~= nil,
      command = it.command and it.command.command,
      insertText = it.insertText,
      detail = it.detail,
    }
  end
  local function find(label_pat)
    for _, it in ipairs(items) do
      if tostring(it.label):find(label_pat) then
        return it.label
      end
    end
  end
  dump(name, {
    err = err,
    count = #items,
    isIncomplete = result and result.isIncomplete,
    sample = sample,
    hit_var = find('%.var') or find('^var'),
    hit_sout = find('sout'),
    hit_fori = find('fori'),
    hit_lombok_getter = find('getSessionTimeout'),
  })
  vim.cmd('silent! edit!')
  vim.wait(500)
end

function probes.completion()
  -- Inside newSslContextBuilder-ish method body: anchor on the LOG.debug line.
  completion_at('completion_member', 'serverSslConfig%.getSessionTimeout', '        serverSslConfig.')
  completion_at('completion_postfix', 'serverSslConfig%.getSessionTimeout', '        serverSslConfig.var')
  completion_at('completion_template', 'serverSslConfig%.getSessionTimeout', '        sout')
end

function probes.codeactions()
  -- 1. Clean-code actions on the lombok getter line.
  local pos = pos_of('serverSslConfig%.getSessionTimeout')
  local range = { start = pos, ['end'] = { line = pos.line, character = pos.character + 10 } }
  local clean, cerr = req('textDocument/codeAction', {
    textDocument = tdid(),
    range = range,
    context = { diagnostics = {}, triggerKind = 1 },
  }, 30000)

  -- 2. Introduce an error, pull diagnostics, actions on the diagnostic.
  local row = pos.line + 1
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { '        int probeBad = "not an int";' })
  vim.wait(2000)
  local pulled, perr = req('textDocument/diagnostic', { textDocument = tdid() }, 30000)
  local diags = pulled and pulled.items or {}
  local bad_diag
  for _, d in ipairs(diags) do
    if d.range.start.line == row then
      bad_diag = d
      break
    end
  end
  local fix, ferr
  if bad_diag then
    fix, ferr = req('textDocument/codeAction', {
      textDocument = tdid(),
      range = bad_diag.range,
      context = { diagnostics = { bad_diag }, triggerKind = 1 },
    }, 30000)
  end

  -- 3. Range selection over whole method-ish block for extract refactors.
  local mstart = pos_of('protected SslContextBuilder') or pos_of('SslContextBuilder newBuilder') or pos
  local sel, serr = req('textDocument/codeAction', {
    textDocument = tdid(),
    range = { start = { line = mstart.line + 1, character = 8 }, ['end'] = { line = mstart.line + 3, character = 20 } },
    context = { diagnostics = {}, triggerKind = 1, only = nil },
  }, 30000)

  local function summarize(actions)
    local out = {}
    for _, a in ipairs(actions or {}) do
      table.insert(out, { title = a.title, kind = a.kind, has_edit = a.edit ~= nil, has_command = a.command ~= nil, has_data = a.data ~= nil })
    end
    return out
  end
  dump('codeactions', {
    clean = summarize(clean), clean_err = cerr,
    diag_count = #diags,
    sample_diags = vim.list_slice(diags, 1, 10),
    on_error = summarize(fix), on_error_err = ferr,
    range_sel = summarize(sel), range_err = serr,
  })
  vim.cmd('silent! edit!')
  vim.wait(500)
end

function probes.exec()
  local uri = vim.uri_from_bufnr(bufnr)
  local trials = {
    { cmd = 'intellij.java.resolveJavaExecutable', args = { { projectUri = uri } } },
    { cmd = 'intellij.java.resolveJavaExecutable', args = {} },
    { cmd = 'intellij.java.resolveClasspath', args = {} },
    { cmd = 'intellij.java.resolveClasspath', args = { { uri = uri } } },
    { cmd = 'intellij.java.resolveWorkingDirectory', args = {} },
    { cmd = 'exportWorkspace', args = {} },
    { cmd = 'interpolateFileTemplate', args = {} },
    { cmd = 'applyModCommand', args = {} },
    { cmd = 'start_debug_server', args = {} },
  }
  local out = {}
  for i, t in ipairs(trials) do
    local result, err = req('workspace/executeCommand', { command = t.cmd, arguments = t.args }, 20000)
    out[i] = { cmd = t.cmd, args = t.args, result = result, err = err and { code = err.code, message = err.message } or nil }
    say(t.cmd .. ' -> ' .. (err and ('ERR: ' .. tostring(err.message)) or 'ok'))
  end
  dump('exec', out)
end

function probes.rename()
  -- Rename the serverSslConfig FIELD (multi-file impact unlikely) — better:
  -- rename the class ServerSslConfig from a usage here.
  local pos = pos_of('ServerSslConfig serverSslConfig')
  if not pos then
    pos = pos_of('ServerSslConfig')
  end
  local result, err = req('textDocument/rename', {
    textDocument = tdid(),
    position = pos,
    newName = 'ServerSslConfigRenamed',
  }, 60000)
  local files, edits = 0, 0
  if result then
    for _, c in pairs(result.changes or {}) do
      files = files + 1
      edits = edits + #c
    end
    for _, dc in ipairs(result.documentChanges or {}) do
      files = files + 1
      edits = edits + #(dc.edits or {})
    end
  end
  dump('rename', { err = err, files = files, edits = edits, has_documentChanges = result and result.documentChanges ~= nil })
end

function probes.diags()
  -- Dataflow bug: guaranteed NPE + always-true condition, unsaved didChange.
  local pos = pos_of('serverSslConfig%.getSessionTimeout')
  local row = pos.line + 1
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, {
    '        String probeNull = null;',
    '        if (probeNull == null && probeNull.length() > 0) { LOG.debug("x"); }',
    '        int probeUnused = 42;',
  })
  vim.wait(3000)
  local pulled, err = req('textDocument/diagnostic', { textDocument = tdid() }, 45000)
  local items = pulled and pulled.items or {}
  local ours = {}
  for _, d in ipairs(items) do
    if d.range.start.line >= row and d.range.start.line <= row + 3 then
      table.insert(ours, { line = d.range.start.line, severity = d.severity, message = d.message, code = d.code, source = d.source })
    end
  end
  dump('diags', { kind = pulled and pulled.kind, total = #items, planted_region = ours, err = err })
  vim.cmd('silent! edit!')
  vim.wait(500)
end

function probes.runhelpers()
  local uri = vim.uri_from_bufnr(bufnr)
  local wd, wderr = req('workspace/executeCommand', {
    command = 'intellij.java.resolveWorkingDirectory',
    arguments = { { uri = uri } },
  }, 20000)

  -- Organize imports end-to-end: plant an unused import, run the action
  -- helper, see whether it disappears.
  vim.api.nvim_buf_set_lines(bufnr, 30, 30, false, { 'import java.util.Vector;' })
  vim.wait(2000)
  local before = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, 60, false), '\n')
  require('intellij-lsp.actions').organize_imports_sync(client, bufnr, 8000)
  vim.wait(3000)
  local after = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, 60, false), '\n')
  dump('runhelpers', {
    working_dir = wd,
    working_dir_err = wderr and wderr.message,
    had_vector_before = before:find('Vector') ~= nil,
    has_vector_after = after:find('Vector') ~= nil,
  })
  vim.cmd('silent! edit!')
  vim.wait(500)
end

-- Navigation family: implementation, typeDefinition, references,
-- typeHierarchy (super/sub), callHierarchy. BaseSslContextFactory extends
-- SslContextFactory (an interface), so its name is a good anchor.
function probes.nav()
  local pos = pos_of('class BaseSslContextFactory')
  pos = { line = pos.line, character = pos.character + #'class B' + 10 }
  -- Find the exact class-name column instead.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local s = line:find('class BaseSslContextFactory')
    if s then
      pos = { line = i - 1, character = s - 1 + 6 + 1 } -- inside the name
      break
    end
  end

  local out = {}
  local function try(name, method, params, timeout)
    local result, err = req(method, params, timeout or 20000)
    local n
    if type(result) == 'table' then
      n = result.uri and 1 or #result
    end
    out[name] = { count = n, err = err and (err.message or true) or nil, sample = result and (result[1] or result) }
  end

  local base = { textDocument = tdid(), position = pos }
  try('implementation', 'textDocument/implementation', base)
  try('typeDefinition', 'textDocument/typeDefinition', base)
  try('references', 'textDocument/references', vim.tbl_extend('force', base, { context = { includeDeclaration = false } }))
  try('declaration', 'textDocument/declaration', base)

  local prep, perr = req('textDocument/prepareTypeHierarchy', base, 20000)
  out.prepareTypeHierarchy = { ok = prep ~= nil, err = perr and perr.message, name = prep and prep[1] and prep[1].name }
  if prep and prep[1] then
    local supers, serr = req('typeHierarchy/supertypes', { item = prep[1] }, 20000)
    local subs, suberr = req('typeHierarchy/subtypes', { item = prep[1] }, 20000)
    local function names(list)
      local acc = {}
      for _, it in ipairs(list or {}) do
        table.insert(acc, it.name)
      end
      return acc
    end
    out.supertypes = { names = names(supers), err = serr and serr.message }
    out.subtypes = { names = names(subs), err = suberr and suberr.message }
  end

  -- Call hierarchy on a method: newBuilderForServer / getSessionTimeout site.
  local mpos = pos_of('public SslContext') or pos_of('protected ')
  if mpos then
    local cprep = req('textDocument/prepareCallHierarchy', { textDocument = tdid(), position = { line = mpos.line, character = mpos.character + 20 } }, 20000)
    out.prepareCallHierarchy = { ok = cprep ~= nil and #(cprep or {}) > 0, name = cprep and cprep[1] and cprep[1].name }
    if cprep and cprep[1] then
      local incoming = req('callHierarchy/incomingCalls', { item = cprep[1] }, 20000)
      out.incomingCalls = incoming and #incoming or 0
    end
  end

  dump('nav', out)
end

local requested = {}
for i = 1, #_G.arg do
  requested[#requested + 1] = _G.arg[i]
end
if #requested == 0 then
  requested = { 'ready', 'caps' }
end

-- Always ensure readiness before any probe other than 'ready' itself.
if requested[1] ~= 'ready' then
  say('ensuring readiness first...')
  local r = wait_ready(240)
  say('ready=' .. tostring(r))
  if not r then
    dump('notready', { ready = false })
    os.exit(2)
  end
end

for _, name in ipairs(requested) do
  if probes[name] then
    say('=== probe: ' .. name)
    local pok, perr = pcall(probes[name])
    if not pok then
      say('probe ' .. name .. ' CRASHED: ' .. tostring(perr))
      dump(name .. '-crash', { error = tostring(perr) })
    end
  else
    say('unknown probe: ' .. name)
  end
end

say('done')
-- Stop the client properly or the server child outlives us and squats on the
-- shared index lock.
client:stop(true)
vim.wait(5000, function()
  return client.is_stopped()
end, 100)
vim.cmd('silent! qall!')
