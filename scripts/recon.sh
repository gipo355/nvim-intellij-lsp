#!/usr/bin/env bash
# Recon for the "Java and Kotlin by IntelliJ IDEA" extension (JetBrains.intellij-server).
#
# Answers the questions we cannot answer from a sandbox: is the language server
# bundled inside the VSIX or downloaded from JetBrains' CDN on first launch, and
# what exactly does the VS Code client pass to it?
#
# Writes text reports to recon/ and keeps the large binaries in .recon-tmp/.
# Both are gitignored on purpose: the reports embed JetBrains' own files
# (package.json, string dumps), which are theirs to distribute — keep them local.
#
#   ./scripts/recon.sh            # auto-detect platform
#   ./scripts/recon.sh linux-x64  # or force a target

set -uo pipefail

NAMESPACE=JetBrains
EXTENSION=intellij-server
API=https://open-vsx.org/api

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/recon"
TMP="$REPO_ROOT/.recon-tmp"
mkdir -p "$OUT" "$TMP"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

# --- 0. platform target ------------------------------------------------------

detect_target() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    MINGW* | MSYS* | CYGWIN*) os=win32 ;;
    *) os=unknown ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) arch=unknown ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

TARGET="${1:-$(detect_target)}"
log "target platform: $TARGET"

# --- 1. registry metadata ----------------------------------------------------
# The unversioned endpoint lists every published target; the per-target endpoint
# gives us the actual download URL. Both are small, so keep both verbatim.

log "fetching Open VSX metadata"
curl -fsSL "$API/$NAMESPACE/$EXTENSION" -o "$OUT/openvsx-metadata.json" \
  || warn "unversioned metadata fetch failed"
curl -fsSL "$API/$NAMESPACE/$EXTENSION/$TARGET/latest" -o "$OUT/openvsx-$TARGET.json" \
  || warn "per-target metadata fetch failed (is '$TARGET' a published target?)"

# Pull the .vsix URL out without assuming jq is installed.
extract_download() {
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
print(data.get("files", {}).get("download", ""))
PY
}

VSIX_URL="$(extract_download "$OUT/openvsx-$TARGET.json")"
if [ -z "${VSIX_URL:-}" ]; then
  VSIX_URL="$(extract_download "$OUT/openvsx-metadata.json")"
fi

if [ -z "${VSIX_URL:-}" ]; then
  warn "could not determine a .vsix download URL — inspect recon/openvsx-*.json by hand"
  exit 1
fi
log "vsix: $VSIX_URL"

# --- 2. download + unpack ----------------------------------------------------
# A VSIX is a zip. If the server is bundled this will be large (hundreds of MB);
# if it is a downloader shim it will be a couple of MB. That size alone is the
# headline answer.

VSIX="$TMP/$EXTENSION-$TARGET.vsix"
if [ ! -f "$VSIX" ]; then
  log "downloading (this may be large)"
  curl -fL --progress-bar "$VSIX_URL" -o "$VSIX" || { warn "download failed"; exit 1; }
fi

EXTRACT="$TMP/extracted"
rm -rf "$EXTRACT"
mkdir -p "$EXTRACT"
log "unzipping"
unzip -qo "$VSIX" -d "$EXTRACT" || { warn "unzip failed"; exit 1; }

{
  echo "# VSIX size"
  du -h "$VSIX"
  echo
  echo "# extracted size"
  du -sh "$EXTRACT"
  echo
  echo "# top-level tree (depth 4)"
  find "$EXTRACT" -maxdepth 4 | sed "s|$EXTRACT|.|" | sort | head -300
  echo
  echo "# largest 30 files"
  find "$EXTRACT" -type f -printf '%s\t%p\n' 2>/dev/null \
    | sort -rn | head -30 | sed "s|$EXTRACT|.|"
} > "$OUT/vsix-layout.txt" 2>&1
log "wrote recon/vsix-layout.txt"

# --- 3. the manifest ---------------------------------------------------------
# package.json tells us the contributed settings namespace (what we must answer
# on workspace/configuration), activation events, and any declared binaries.

if [ -f "$EXTRACT/extension/package.json" ]; then
  cp "$EXTRACT/extension/package.json" "$OUT/package.json"
  log "wrote recon/package.json"
else
  warn "no extension/package.json found"
fi

# --- 4. how the client spawns the server ------------------------------------
# The real argv lives in the compiled extension JS. We want: the launcher path,
# --stdio vs socket, --system-path, initializationOptions, and any CDN URL used
# to fetch the server when it is not bundled.

log "grepping extension sources for launch + download details"
{
  echo "# https URLs referenced by the extension"
  grep -rhoE 'https://[^"'"'"' `)]+' "$EXTRACT/extension" \
    --include='*.js' --include='*.json' --include='*.cjs' --include='*.mjs' 2>/dev/null \
    | sort -u | head -60
  echo
  echo "# launcher / flag mentions"
  grep -rhoE '.{80}(intellij-server|--stdio|--system-path|IJ_JAVA_OPTIONS|defaultSdk|defaultJdk|buildTools).{80}' \
    "$EXTRACT/extension" --include='*.js' --include='*.cjs' --include='*.mjs' 2>/dev/null \
    | head -60
  echo
  echo "# jetbrains.* configuration keys"
  grep -rhoE '"jetbrains\.[a-zA-Z0-9._]+"' "$EXTRACT/extension" 2>/dev/null \
    | sort -u | head -80
  echo
  echo "# command ids ending in .apply (completion workaround depends on this)"
  grep -rhoE '"[a-zA-Z0-9._]+\.apply"' "$EXTRACT/extension" 2>/dev/null \
    | sort -u | head -20
} > "$OUT/extension-strings.txt" 2>&1
log "wrote recon/extension-strings.txt"

# --- 5. the launcher itself --------------------------------------------------

log "looking for a bundled launcher"
SERVER_BIN="$(find "$EXTRACT" -type f \( -name 'intellij-server' -o -name 'intellij-server.exe' \) 2>/dev/null | head -1)"

{
  echo "# candidate launchers"
  find "$EXTRACT" -type f \( -name 'intellij-server*' -o -name '*.sh' -o -name 'kotlin-lsp*' \) 2>/dev/null \
    | sed "s|$EXTRACT|.|" | head -40
  echo
  if [ -n "${SERVER_BIN:-}" ]; then
    echo "# BUNDLED: $(echo "$SERVER_BIN" | sed "s|$EXTRACT|.|")"
    echo
    echo "# sibling layout (bin/ and lib/ present?)"
    ls -la "$(dirname "$SERVER_BIN")/.." 2>/dev/null | head -30
    echo
    echo "# --help output"
    chmod +x "$SERVER_BIN" 2>/dev/null
    "$SERVER_BIN" --help 2>&1 | head -80 || echo "(--help exited non-zero)"
  else
    echo "# NOT BUNDLED — this is a downloader shim."
    echo "# The CCDN URL should appear in recon/extension-strings.txt above."
  fi
} > "$OUT/launcher.txt" 2>&1
log "wrote recon/launcher.txt"

# --- 6. CDN probe ------------------------------------------------------------
# Mason fetches kotlin-lsp straight from JetBrains' CDN rather than Open VSX:
#   https://download-cdn.jetbrains.com/language-server/kotlin-server/<v>/kotlin-server-<v>.tar.gz
# If the Java+Kotlin server sits at an analogous path we can skip the VSIX
# entirely. Probe the obvious product names.

log "probing JetBrains CDN for an analogous server tarball"
{
  for product in intellij-server idea-server java-server intellij-lsp; do
    url="https://download-cdn.jetbrains.com/language-server/$product/"
    printf '%s -> %s\n' "$url" "$(curl -o /dev/null -s -w '%{http_code}' -I "$url")"
  done
  echo
  echo "# for reference, the known-good kotlin-server path:"
  kurl="https://download-cdn.jetbrains.com/language-server/kotlin-server/262.9593.0/kotlin-server-262.9593.0.tar.gz"
  printf '%s -> %s\n' "$kurl" "$(curl -o /dev/null -s -w '%{http_code}' -I "$kurl")"
} > "$OUT/cdn-probe.txt" 2>&1
log "wrote recon/cdn-probe.txt"

cat <<EOF

Done. Reports in recon/:
  openvsx-metadata.json   every published platform target + version
  openvsx-$TARGET.json
  vsix-layout.txt         sizes + tree  <- answers bundled vs shim
  package.json            contributed settings namespace
  extension-strings.txt   launch argv, CDN URLs, jetbrains.* config keys
  launcher.txt            bundled launcher + its --help
  cdn-probe.txt           whether a direct tarball path exists

These stay local (gitignored): they embed JetBrains' own files.
EOF
