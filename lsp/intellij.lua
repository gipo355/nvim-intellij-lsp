--- Native Neovim LSP config for JetBrains' IntelliJ language server.
---
--- Because this is a plain `lsp/` runtimepath entry, everything here is
--- overridable the standard way, with or without calling `setup()`:
---
--- ```lua
--- vim.lsp.config('intellij', { root_markers = { 'pom.xml' } })
--- vim.lsp.enable('intellij')
--- ```
return require('intellij-lsp.config').build()
