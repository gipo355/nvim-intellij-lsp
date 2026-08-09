# HANDOFF

Everything learned building this, written so a fresh session can continue
without re-deriving anything. Read §2 and §6 first; §6 is where the time went.

**Status: working.** Verified 2026-08-06 against Netflix/zuul (Gradle, 32
modules): `BUILD SUCCESSFUL`, 202 libraries imported, client initialized with
the full capability set. Also verified against a small Jakarta/Gradle project.

---

## 1. What this is

A Neovim client for the language server behind JetBrains' *"Java and Kotlin by
IntelliJ IDEA"* VS Code extension (`JetBrains.intellij-server`). The server is a
standalone process speaking LSP over stdio via `bin/intellij-server`, which
carries its own bundled JBR. Nothing about it is VS Code-specific — the
extension is just one client, and this is another.

Related: [kotlin-lsp](https://github.com/Kotlin/kotlin-lsp) is the Apache-2.0
Kotlin-only server using the *same* launcher, wrapped by
[kotlin.nvim](https://github.com/AlexandrosAlexiou/kotlin.nvim). Cross-checking
against it was how several behaviours were first identified.

---

## 2. Read this before debugging anything

**Almost every "the LSP is bare / nothing works" report so far has been a failed
project import, not a missing feature.** Three distinct causes produced
identical symptoms in one evening:

| Cause | What the log said |
| --- | --- |
| `jdk` pointed at a nonexistent path | `Configured Java home does not exist or is not a directory` |
| Private artifact repository unreachable (VPN/proxy down) | `UnknownHostException: …` → `0 libraries to load` |
| Project needs a toolchain Gradle can't find | `ToolchainProvisioningException: … matching {languageVersion=21}` |

When the import fails the server keeps serving an **empty workspace model**, so
every request correctly returns nothing.

**The first diagnostic is always:**

```vim
:IntellijLog
```

and look for `BUILD SUCCESSFUL` followed by `There are N libraries to load` with
**N > 0**. If N is 0, stop — no client-side work will help. Neovim's `:LspLog`
is far less useful; the server's own log carries the build-tool output.

**A failed import is cached.** The log ends `Workspace model cache saved (0 K)`
and a restart happily reloads "0 libraries" without retrying. After fixing the
underlying cause you must `:IntellijCleanWorkspace`, then restart.

---

## 3. Quick start from zero

```vim
:IntellijInstall        " download + sha256-verify the server (~1 GB)
:IntellijAcceptEula     " the server refuses to initialize without this
```

Open a `.java` file in a Gradle/Maven/Bazel project, then
`:checkhealth intellij-lsp`.

Manual install if preferred — the plugin auto-discovers anything under
`stdpath('data')/intellij-lsp/servers/*`, newest first:

```bash
curl -fL -o /tmp/ij.tar.gz \
  https://download.jetbrains.com/language-server/intellij-server/263.2689.0/intellij-server-263.2689.0.tar.gz
sha256sum /tmp/ij.tar.gz   # bf4aa474a87499cc3bf7086e64d05f9c4140f5464956fbd574adcc2d4c3e4162
mkdir -p ~/.local/share/nvim/intellij-lsp/servers/263.2689.0
tar -xzf /tmp/ij.tar.gz -C ~/.local/share/nvim/intellij-lsp/servers/263.2689.0
```

---

## 4. The launch contract

Read from the extension's compiled `extension.js` (see `recon/`) and the
launcher's `--help`. None of it is guessed.

| Thing | Value |
| --- | --- |
| launcher | `<root>/bin/intellij-server` (bundled JBR; no JDK needed to *run* it) |
| transport | `--stdio` |
| workspace | `--system-path <dir>` — **two argv entries** in the real client |
| JVM flags | `IJ_JAVA_OPTIONS` env, space-separated, read *before* the JVM starts |
| build JVM | `JAVA_HOME` env — see §6.4, this is ours, not the client's |
| telemetry | `INTELLIJ_DATA_SHARING` env (`full`/`anonymous`/`test`/`none`) |
| region | `INTELLIJ_REGION` env |
| init options | `eulaHash`, `defaultSdk`, `defaultJdk`, `buildTools[rootUri]` |
| settings | pulled via `workspace/configuration`, two namespaces (§6.6) |

Launcher flags we don't use yet: `--client`,
`--log-category=<cat:LEVEL>`, `--version`, `--data-sharing=`, `--region=`.
`--log-level` is now the `log_level` option.

**`--socket` probed 2026-08-07:** `--socket=127.0.0.1:<port> --multi-client`
works — a TCP client (`vim.lsp.rpc.connect`) initializes and serves
requests. BUT a second `initialize` against the same project fails with
`lock hold by current process … No locks available`: multi-client means one
process hosting *different* projects, not two editors sharing one project
session. Two Neovims on one project remains impossible without a
multiplexing proxy. The useful daemon idea that remains: a per-project
socket server that outlives the editor, so nvim restarts skip the JVM cold
start.

Note `--help` documents `--system-path=<path>` while the VS Code client passes
two arguments. Both parse (it's Clikt). We match the client.

---

## 5. Server capabilities — confirmed, not assumed

From the server's own `initialize` response, found in its log:

```
references  rename  codeAction  codeLens  signatureHelp  hover  definition
typeDefinition  implementation  declaration  callHierarchy  typeHierarchy
semanticTokens  inlayHint  documentSymbol  workspaceSymbol  foldingRange
documentFormatting  diagnostic  color  executeCommand
```

`executeCommand` commands (re-dumped 2026-08-07 from a live `initialize`
against zuul — note the drift from the first log-scraped list):

```
decompile                     applyModCommand           exportWorkspace
java.organize.imports         kotlin.organize.imports   interpolateFileTemplate
start_debug_server
jetbrains.java.completion.apply
jetbrains.kotlin.completion.apply
refactor.extract.variable     refactor.extract.function
refactor.extract.field        refactor.extract.constant
intellij.java.resolveClasspath          intellij.java.resolveClassDocument
intellij.java.resolveJavaExecutable     intellij.java.resolveWorkingDirectory
```

`codeActionProvider.codeActionKinds` (same dump): `quickfix`, `refactor`,
`source.organizeImports`, `refactor.extract.{variable,function,field,constant}`,
`refactor.inline.variable`.

**`start_debug_server` (no args) returns a port number** — and the port
**speaks DAP** (verified 2026-08-07): Content-Length framing, well-formed
responses. `initialize` succeeds with `adapterID: "intellij_debugger"`
(found in `plugins/java-base.lsp/lib/modules/language-server.dap.jvm.jar`,
class `com.jetbrains.dap.jvm.JvmDebuggerAdapter`, registered via
`<ls.debuggerAdapter>`; wrong IDs get "No debugger adapter found").
It's IntelliJ's XDebugger bridged over DAP
(`lib/language-server.dap.platform.jar`), with function/exception
breakpoints, log points, hit conditions and completion support classes
visible, plus `RemoteConfigurationType` (JDWP attach). No VSIX needed.
Request shapes (verified by error-guided probing):

- `attach { hostName, port }` — attaches to any JDWP process; breakpoint
  came back `verified: true`, events showed "Connected to the target VM".
- `launch { javaExec, mainClass }` — the ONLY required fields. The server
  spawns the JVM under JDWP itself and attaches internally; classpath and
  working directory come from its workspace model (which is why they are
  not arguments — and why launch on an unimported project dies with
  ClassNotFoundException).

`lua/intellij-lsp/dap.lua` registers the nvim-dap adapter (`adapter.id`
carries the mandatory `adapterID = "intellij_debugger"`); `:IntellijDebug`
native-launches the current buffer's main class. Dump the full capability
set with the DAP probe in `scripts/probe.lua`.

Argument shapes learned by probing (wrong-args errors name the params):
`resolveClasspath {uri}` → `{classpath: string[]}`;
`resolveWorkingDirectory {uri}` → `{workingDirectory: string}`;
`resolveJavaExecutable` → errors "No JDK configured for the project" even
with `defaultSdk` sent (open question); `exportWorkspace` wants 1 argument;
`interpolateFileTemplate` wants 2; `applyModCommand` ≥ 1 — postfix items
reveal ModCommand payloads look like
`{kind: '…ModCommandData.Navigate', fileUrl, selectionStart, selectionEnd, caret}`.

Not advertised: `documentRangeFormatting`, `documentOnTypeFormatting`,
`documentHighlight`, `selectionRange` — and, in the live dump, no
`declarationProvider`/`colorProvider` either (both appeared in the earlier
log-scraped list; per-build or per-project drift).

**Implication: there are no missing features to add.** Remaining work is
client-side wiring and ergonomics, not capability gaps.

### Bundled plugins (`<server root>/plugins/`, inventoried 2026-08-07)

```
java  java-base.lsp  java.lsp  java-aetherDependencyResolver-plugin
kotlin  kotlin.lsp
lombok                ← lombok support is a bundled PLUGIN, zero client wiring
spring  spring.lsp    ← Spring ships, LSP-facing; untested (zuul is Guice)
bazel  bazel.lsp  editorconfig  properties
```

No mechanism is known for installing further IntelliJ plugins into the
server. JSpecify nullability lives in the `java` plugin's inspection engine
(verified live via dataflow diagnostics), so it is expected to work when
`org.jspecify` is on the project classpath — unverified.

To re-dump after a server update:

```bash
grep -n "executeCommandProvider" ~/.cache/nvim/intellij-lsp/workspaces/*/system/log/intellij-server.log
```

---

## 6. Gotchas

### 6.1 lazy.nvim: no trigger ⇒ silent no-op

**Symptom:** nothing whatsoever. No error, no client, no log lines.

**Cause:** with `defaults = { lazy = true }`, a spec with no `ft`/`event`/`cmd`
never loads, so the plugin's `lsp/` directory never reaches the runtimepath and
`vim.lsp.enable('intellij')` is never called.

**Fix:** `ft = { 'java', 'kotlin' }`. Sufficient — `vim.lsp.enable()` ends with
`vim.cmd.doautoall('nvim.lsp.enable FileType')`, so the buffer that triggered
the load still attaches. (`lazy = false` works too but costs every startup.)

### 6.2 The JDK is load-bearing and fails silently

`jdk` is the JDK the server analyses your code **against** — not what it runs
on (that's the bundled JBR). A wrong path doesn't degrade gracefully: **Gradle
import aborts entirely**, so you get an empty model.

Confusingly, go-to-definition inside your own code may still work, which makes
it look like a partial feature gap rather than a total import failure.

`jdk.lua` now auto-detects across `$JAVA_HOME`, mise, sdkman, asdf, jenv and
system paths, requires `bin/javac` (never accepts a JRE), reads the feature
version from the `release` file, and warns loudly on a bad configured path.
`jdk_version = 21` pins to what a project compiles against — **rarely the newest
installed**.

### 6.3 A failed import is cached

See §2. `:IntellijCleanWorkspace` then restart, or you keep reloading the
failure.

### 6.4 Gradle toolchains need `JAVA_HOME`

`defaultSdk` covers symbol resolution but says nothing about which JVM the
server runs the **build tool** on — Gradle takes that from the environment. A
project declaring `languageVersion = 21` fails to configure even with that JDK
installed, because version-manager layouts (mise/sdkman/asdf) are not part of
Gradle's auto-detection.

We set `JAVA_HOME` to the resolved JDK, and Gradle counts the JVM running the
build as an available toolchain, which covers the single-toolchain case.

**The JAVA_HOME version must match the project's pinned toolchain.** Verified
the hard way (2026-08-07): auto-detect picked Java 25, zuul pins
`languageVersion = 21` → `ToolchainProvisioningException` even though 21 was
installed (in mise, invisible to Gradle). `jdk_version = 21` fixes it. The
plugin now parses the wanted version out of the failure and names the exact
remedy in the error notification and `:checkhealth`.

**Dead end, tested:** `GRADLE_OPTS="-Dorg.gradle.java.installations.paths=…"`
is NOT forwarded by the Gradle Tooling API the server uses. Env-only
multi-JDK is not possible.

**For projects needing several toolchains at once**, this user-level file is the
answer (not applied — it affects all their Gradle builds, so it needs consent):

```properties
# ~/.gradle/gradle.properties
org.gradle.java.installations.paths=/path/to/jdk21,/path/to/jdk25,/path/to/jdk17
```

### 6.5 EULA is enforced **server-side**

```
RequestFailed: Bundled license agreement (EULA.txt) is not accepted:
expected hash 34d850193ee04897, got <none>. Pass the accepted EULA hash as
`eulaHash` in LSP initializationOptions.
```

An early reading of the extension suggested this was client-side only (it keeps
`jetbrains.intellij.eulaAcceptedHash` in VS Code's `globalState`). **That was
wrong** — the server checks independently.

`eulaHash` = first 16 hex chars of `sha256(EULA.txt)`, from the server root.
Verified exactly. `eula.lua` computes it from the file rather than hardcoding,
so a new agreement in a future build must be accepted again instead of silently
inheriting old consent. `root_dir` refuses to start until accepted, turning an
RPC traceback into one line.

**Deliberate:** nothing auto-accepts. `:IntellijAcceptEula` shows the text and
takes a confirmation; `accept_eula = true` is the declarative equivalent. Both
are explicit acts by the user. **A server update likely means re-accepting.**

### 6.6 Settings are *pulled*, in two namespaces

The server never reads what you push at initialize; it requests sections via
`workspace/configuration`. Answer wrongly and features go quiet with no error.

- `intellij.*` — runtime: `jdkForSymbolResolution`, `buildTool`, `projects`,
  `bazel.projectview`, `bazel.build`, `trace.server`, `region`, `dataSharing`
- `jetbrains.*` — language features: inlay hints, file templates

Stored flat, reassembled into nested objects on request by `section_value()` in
`config.lua`, so new keys need no code.

**The Java hint keys contain literal spaces.** Correct, not typos:

```
jetbrains.java.hints.collapse complex types
jetbrains.java.hints.settings.method parameter
jetbrains.java.hints.types.local variable
jetbrains.java.settings.types.lambda parameter
jetbrains.java.hints.types.call chain
```

### 6.7 The index is shared — one nvim per project

```
RequestFailed: While lock file: ~/.cache/JetBrains/analyzer/workspaces/<md5>/
index/intellij-server/rocks/v258/LOCK: Resource temporarily unavailable
```

`--system-path` does **not** relocate the index. It holds only `.app.lock` and a
small `system/` directory. The RocksDB index lives in
`~/.cache/JetBrains/analyzer/workspaces/<md5-of-project-path>/`, shared across
instances and keyed by project — so two servers on one project always contend.

Practically: **one Neovim per Java project**, and headless probing while the
user has that project open will fail. A second instance also logs
`The specified workspace data path is already in use` and falls back to `/tmp`.

**RESOLVED 2026-08-07:** `initializationOptions.indexDir` relocates the
index — found in the server's own `bin/warmup.py`, which passes it alongside
`--system-path`. The plugin now sends the per-project workspace dir by
default (`isolate_index = true`): verified headless — `rocks/` lands in our
dir and no shared analyzer entry is created, so two projects (or editors on
different projects) no longer contend. First start after upgrading discards
the shared warm index for that project (a one-time re-index).
`isolate_index = false` restores the old shared behavior.

`bin/warmup.py` also documents: the server notifies
**`intellij/ready-for-test`** when the index is built and flushed (we turn
it into a `User IntellijReady` autocmd + notification);
`buildTools[rootUri]` accepts `'*'` (try all importers) and `''` (skip
import); `exportWorkspace` takes the project path and writes
`<root>/workspace.json`.

### 6.8 `jar://` / `jrt://` need a BufReadCmd

Go-to-definition outside your own sources returns a URI Neovim can't read.
Untreated, Neovim makes an **empty buffer** named after the URI, so the jump
lands nowhere — and with a picker involved it surfaces bizarrely as
`snacks/picker/actions.lua: Invalid cursor line: out of range`, because the
target line doesn't exist in a zero-line buffer.

`decompiler.lua` intercepts those schemes and fills the buffer from the server's
`decompile` command (`{ code, language }`) — real sources when available (a
JDK's `lib/src.zip`, an attached `-sources.jar`), decompiled bytecode otherwise.
It blocks up to `uri_timeout_ms` because the caller sets the cursor as soon as
the read returns.

### 6.9 Completion is command-driven

Items arrive with an **empty** `textEdit` plus a `jetbrains.*.completion.apply`
command; the server does the real insertion via `workspace/applyEdit` and places
the caret with `window/showDocument`. VS Code's client inserts nothing and just
runs the command, so it works there for free.

Neovim frontends insert the `label` first, *then* run the command — so the
server's diff is computed against a document that no longer matches and the
caret lands mid-identifier (`Ap|p`).

`completion.lua` neutralises the client-side insertion into a no-op. Frontends
bypass the `handlers` table for completion, so the hook is the client's
`request` method. Disable with `completion_fix = false` if upstream ever ships
real `textEdit`s.

**Update 2026-08-07: upstream now ships real `textEdit`s.** In build
263.2689.0, plain member items carry full textEdits and *no* apply command;
live templates (`sout*`) likewise. The workaround's guard (`is_command_driven`)
correctly leaves them untouched, so it is dormant, not harmful — keep it for
older builds. Postfix items (`.var`) are standard too
(`textEdit` + `additionalTextEdits` + snippet format), with one VS Code-ism:
a client-side `runCommands` chain (caret ModCommand +
`editor.action.rename`) that `completion.run_commands` translates
(rename → `vim.lsp.buf.rename()`).

### 6.10 Completion matching is first-letter case-sensitive — server-side, no knob

Probed 2026-08-07 (headless, tiny Gradle project, warm index): `Str` → 25
items incl. `String` (~600 ms); `str` and `string` → **0 items**,
`isIncomplete=false`. The filter is the server's — client fuzzy matchers
(blink's frizbee is case-insensitive) never see the items, so they can't help.

Dead ends, tested:

- The extension's `contributes.configuration` (42 properties) has **no**
  completion/case setting.
- `-Didea.config.path=<dir>` with `options/editor.codeinsight.xml`
  (`COMPLETION_CASE_SENSITIVE = 2`/NONE) changes nothing. The server never
  creates or reads an IDE config dir at all (nothing under `--system-path`
  either) — the LSP completion path doesn't consult `CodeInsightSettings`.

Workaround: type the capital (`Str`). A client-side fix would need a
"shadow capitalization" retry (didChange a capitalized prefix → re-request →
restore) — not implemented. Worth reporting upstream.

The broader IntelliJ completion mode is also not hidden behind an LSP client
capability. In build 263.2689.0, the Java completion request implementation
calls `LightModCompletionServiceImpl.getItems(...)` with invocation count `1`
and `CompletionType.BASIC` hardcoded. LSP has no standard request field for
IntelliJ's second invocation or SMART completion.

Probed 2026-08-08 against a warm, minimal Java project (raw LSP responses,
before any completion UI filtering):

| Expression prefix | Raw result |
| --- | --- |
| `A` where the expected type is an enum | `State.ACTIVE`, `State.ARCHIVED`, etc. |
| `A` where the enum type is in another package | same, plus an `additionalTextEdits` import for the enum type |
| `A` for static fields declared in the current class | fields are returned unqualified |
| `fi` for a static method declared in the current class | method is returned unqualified |
| `fi` for a static method declared in another class | absent |
| `StaticCatalog.fi` | method is returned |

Expected-type enum completion is therefore present, including automatic import:
the item uses `filterText = "ACTIVE"`, a text edit such as
`ExternalState.ACTIVE`, and an additional edit adding
`import external.ExternalState`. A frontend must match on `filterText`, not only
the qualified display label. The user's current blink.cmp build does use
`filterText`, so a failure in a concrete enum site needs that site's raw item
and expected-type context rather than another advertised capability.

Unqualified static members from arbitrary other classes are different: the
server never emits them in its one BASIC pass. The registered LSP providers
cover current-scope references, expected-type members, and non-imported classes,
but not IntelliJ desktop's broader second-invocation static-member search. There
is consequently no auto-static-import edit for the client to apply. This is an
upstream server feature gap, not an omitted Neovim capability.

Typing the unresolved static field/method name by hand does not recover the
feature through `textDocument/codeAction`, either: the same fixture offered no
static-import quick fix (the field only got “create local variable”; the method
only got organize imports). The desktop classes for global/static-member lookup
exist in the bundled Java plugin, but the LSP completion provider set does not
expose that flow.

### 6.11 Server heap defaults to 2 GB

`bin/intellij-server.vmoptions` hardcodes `-Xmx2048m` (plus
`-XX:ReservedCodeCacheSize=512m`). On a 130-library project completion takes
seconds; the tiny-probe baseline is ~600 ms per request, so heavy projects are
mostly heap/GC. `jvm_args = { '-Xmx4g' }` → `IJ_JAVA_OPTIONS` is the lever
(the xplat launcher reads that env var; strings in the binary confirm it).
Note the vmoptions defaults come *before* user options, so `-Xmx4g` wins.

### 6.12 jdtls conflicts

Both index the whole project and both publish diagnostics. Switching away from
jdtls also disables everything riding on it: **neotest-java**, the
java-debug/java-test DAP bundles, and lombok javaagent wiring.

### 6.13 Preview builds expire

Each build stops working ~30 days after release; new builds roughly every 2
weeks. Run `:IntellijUpdate`, then re-accept the EULA if it changed. Free during
preview; Ultimate required from 1.0 (§8).

`:IntellijUpdate` now discovers the latest platform extension through Open VSX,
reads its authoritative `server-bundle.json`, verifies the bundle's published
SHA-256, installs it side-by-side, and restarts attached clients. A newer build
gets its own expiry window; downloading the same build again would not, so an
already-installed latest build is left alone. A changed agreement is prompted
for and the restart follows acceptance. There is no local compilation step:
JetBrains distributes a prebuilt server archive. Explicit `server_dir`,
`$INTELLIJ_SERVER_DIR`, and `version` pins remain authoritative and the command
names whichever one (or a newer local install) prevents the new managed install
from becoming active.

### 6.14 The server never compiles — launch needs prebuilt classes

DAP `launch` (and any `java -cp` run) dies with `ClassNotFoundException`
when the module output dirs are empty: the IDE's before-run build step does
not exist in the language server, and `resolveClasspath` returns *declared*
paths, not verified ones. `run.ensure_compiled()` detects missing
`build/classes` entries and offers `./gradlew classes` / `mvn compile`
before both `:IntellijRun` and `:IntellijDebug`.

### 6.15 Definition on import lines returns `[]`

`textDocument/definition` with the cursor on an `import` statement answers an
empty array (confirmed twice, different imports). Jump from a *usage* in
code. Anything that probes readiness or tests navigation must not anchor on
import lines.

### 6.16 Headless probing etiquette

A headless nvim that dies without `client:stop(true)` leaves the server
child running, and the orphan squats on the shared index lock (§6.7) —
every later start fails with `Resource temporarily unavailable`. The probe
harness (scratchpad `probe.lua`) stops the client on exit and carries a
watchdog timer; check `pgrep -af 'system-path'` for orphans when anything
hangs.

### 6.17 Two servers, similar names

`intellij-server` is also kotlin-lsp's launcher name. With kotlin.nvim
installed, `kotlin = 'auto'` (default) yields Kotlin buffers to it. `kotlin =
true` forces one server for both.

---

## 7. Where things live

| Path | What |
| --- | --- |
| `~/.local/share/nvim/intellij-lsp/servers/<ver>/intellij-server-<ver>/` | the server |
| `~/.local/share/nvim/intellij-lsp/eula-accepted.json` | `{hash: date}` |
| `~/.cache/nvim/intellij-lsp/workspaces/<name>-<hash8>/` | `--system-path` |
| `…/<name>-<hash8>/system/log/intellij-server.log` | **the useful log** (`:IntellijLog`) |
| `~/.cache/JetBrains/analyzer/workspaces/<md5>/` | the real index — shared |
| `<server root>/EULA.txt` | agreement whose hash the server demands |

---

## 8. Open questions

1. **Licensing beyond preview.** Activation UI (JetBrains Account, activation
   code, license server, trial) lives entirely in the VS Code extension.
   Unknown whether the server validates independently — in which case
   activating anywhere covers us — or whether the client mints a token, which
   would need an official path from JetBrains, **not a reimplementation**. The
   EULA turned out to be server-enforced, so licensing may well be too.
2. ~~`jetbrains.intellij.indexDir`~~ — **answered**, see §6.7: it's
   `initializationOptions.indexDir`, implemented and verified.
3. **`intellij.projects`** (array) — purpose unknown; possibly multi-root.
4. **Non-linux-x64 archive names** inferred from kotlin-server's scheme
   (`-aarch64`, `.sit`, `.win.zip`), unconfirmed.
5. **`applyModCommand`** — IntelliJ's ModCommand refactoring API over LSP. No
   idea what it needs; potentially the richest untapped feature here.

---

## 9. What's next

Verified done: native `lsp/` config, server discovery, downloader + checksum,
EULA gate, workspace isolation, `workspace/configuration`, inlay-hint defaults,
completion fix, launch env, JDK detection, error surfacing, `:IntellijLog`,
decompiler.

**Unverified:** the decompiler has never been seen round-tripping a real
`jar://` buffer — autocmds register and the command exists on the server, but
the index lock made headless testing impossible while the editor was open. Test
this first.

Then, roughly in value order:

- **Inlay hints** — keys already answered; needs `vim.lsp.inlay_hint.enable`
  wiring and per-key options
- **Performance** — zuul: 1m15s import + indexing, cached after. Measure a warm
  start; `jvm_args = { '-Xmx4g' }` is the lever (see 6.11 — default heap is a
  hard 2 GB and the launcher reads `IJ_JAVA_OPTIONS`), effect on a large
  project not yet measured
- **Install ergonomics** — auto-install on first attach instead of manual
  `:IntellijInstall`; Mason registry PR (**no package exists** for this server —
  checked, only `kotlin-lsp` does)
- **Organize imports** on save via `java.organize.imports`
- **File templates** — `jetbrains.templates.{java,kotlin}.*` are full Velocity
  templates in `recon/package.json`, plus `interpolateFileTemplate`
- **Server commands** — `exportWorkspace` (build-system-agnostic import escape
  hatch), `applyModCommand`
- **`--log-level=DEBUG`** as an option
- **Per-project `.intellij-lsp.lua`** overrides
- **DAP** via the extension's `bin/debugjava`
- **Upstream a bare config to nvim-lspconfig** once stable

---

## 10. Re-deriving anything

```bash
./scripts/recon.sh          # downloads the VSIX, writes reports to recon/
~/.local/share/nvim/intellij-lsp/servers/*/*/bin/intellij-server --help
```

`recon/` is generated locally and **deliberately not committed** — the
reports embed JetBrains' own files (the extension's `package.json`, string
dumps), which are theirs to distribute, not ours:

| File | Contains |
| --- | --- |
| `vsix-layout.txt` | proves the VSIX is a 1.4 MB shim with no server in it |
| `extension-strings.txt` | CDN URL, launch argv, every `jetbrains.*` key |
| `package.json` | contributed settings, defaults, file templates |
| `cdn-probe.txt` | which CDN hosts 404 (`download-cdn.` is wrong for this product) |

---

## 11. File map

| File | Role |
| --- | --- |
| `lsp/intellij.lua` | native runtimepath entry; `vim.lsp.config('intellij', …)` works |
| `lua/intellij-lsp/init.lua` | options + `setup()` |
| `lua/intellij-lsp/config.lua` | client config; `cmd` is a function so `--system-path` follows the resolved root |
| `lua/intellij-lsp/server.lua` | launcher discovery (option → env → managed → `$PATH`) |
| `lua/intellij-lsp/install.lua` | download + sha256 + unpack |
| `lua/intellij-lsp/eula.lua` | hash, acceptance store, prompt |
| `lua/intellij-lsp/jdk.lua` | JDK detection and validation |
| `lua/intellij-lsp/settings.lua` | both namespaces, VS Code defaults |
| `lua/intellij-lsp/env.lua` | mirrors `buildLaunchEnvironment`, plus `JAVA_HOME` |
| `lua/intellij-lsp/completion.lua` | the no-op `textEdit` workaround |
| `lua/intellij-lsp/decompiler.lua` | `jar://` / `jrt://` via the `decompile` command |
| `lua/intellij-lsp/workspace.lua` | `--system-path` dirs, log path, cache cleaning |
| `lua/intellij-lsp/commands.lua` | user commands |
| `lua/intellij-lsp/health.lua` | `:checkhealth intellij-lsp` |
| `scripts/recon.sh` | regenerates `recon/` |
