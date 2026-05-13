#!/bin/sh
# logicstar — first-time installer.
#
# Detects the current platform, downloads the latest release binary, verifies
# its SHA-256 against the published `checksums.txt`, places it at
# ~/.local/bin/logicstar (mode 0755), and runs `logicstar install` to wire up
# Claude Code / Cursor integrations.
#
# After the first install, `logicstar update` handles future upgrades. That
# path additionally verifies an ed25519 signature against the pinned public
# key in the binary; this script only verifies the SHA-256 (trust on first
# use — the user has to manually re-curl this script to bootstrap, which is
# the natural moment to verify our publisher claim).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/logic-star-ai/logicstar-cli-releases/main/install.sh | sh
#
# Idempotent: re-running upgrades the binary in place. Refuses to overwrite
# an existing dev-symlink (`logicstar install --env dev` symlinks the bin
# into a source checkout; clobbering that would silently nuke the source
# pointer).

set -eu

REPO="logic-star-ai/logicstar-cli-releases"
BIN_DIR="${HOME}/.local/bin"
BIN_PATH="${BIN_DIR}/logicstar"

# ---- UX helpers --------------------------------------------------------
# Colors only when stderr is a tty AND $NO_COLOR is unset. Detect once.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_DIM='\033[2m'
  C_GREEN='\033[32m'
  C_RED='\033[31m'
  C_CYAN='\033[36m'
  C_RESET='\033[0m'
else
  C_DIM=''
  C_GREEN=''
  C_RED=''
  C_CYAN=''
  C_RESET=''
fi

die() {
  # End any in-flight spinner before printing the error.
  spin_stop ''
  printf '%blogicstar install:%b %s\n' "$C_RED" "$C_RESET" "$1" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

# Spinner. POSIX shell, runs in background, killed on stop. When stderr isn't
# a tty (CI logs, piped output) we emit a single message and skip the
# animation entirely — there's no terminal to repaint.
SPIN_PID=''

spin_start() {
  msg=$1
  if [ ! -t 2 ]; then
    printf '%b…%b %s\n' "$C_DIM" "$C_RESET" "$msg" >&2
    return
  fi
  (
    i=0
    while :; do
      case $((i % 4)) in
        0) c='|' ;;
        1) c='/' ;;
        2) c='-' ;;
        3) c='\' ;;
      esac
      printf '\r%b%s%b %s' "$C_CYAN" "$c" "$C_RESET" "$msg" >&2
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPIN_PID=$!
}

# Stop spinner and emit a final status line. `done_msg` is the resolved
# replacement (e.g. "✓ Downloading…"); pass '' to clear without a final line.
spin_stop() {
  done_msg=${1:-}
  if [ -n "$SPIN_PID" ]; then
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=''
    # Clear the spinner line if stderr is a tty.
    if [ -t 2 ]; then
      printf '\r\033[2K' >&2
    fi
  fi
  if [ -n "$done_msg" ]; then
    printf '%b✓%b %s\n' "$C_GREEN" "$C_RESET" "$done_msg" >&2
  fi
}

need curl
need uname
need mkdir
need mv
need chmod
need awk

# Stop spinner on any abnormal exit. set -e + die() handle the user-visible
# error; this just ensures a stray background spinner can't keep running.
trap 'spin_stop ""' EXIT INT TERM

# ---- Platform detection -------------------------------------------------
uname_s=$(uname -s)
case "$uname_s" in
  Darwin) os="darwin" ;;
  Linux)  os="linux" ;;
  *)      die "unsupported OS: $uname_s (logicstar ships for macOS and Linux)" ;;
esac

uname_m=$(uname -m)
case "$uname_m" in
  arm64|aarch64)   arch="arm64" ;;
  x86_64|amd64)    arch="x64" ;;
  *)               die "unsupported architecture: $uname_m" ;;
esac

ASSET="logicstar-${os}-${arch}"

# ---- SHA-256 tool detection ---------------------------------------------
# macOS ships `shasum`; most Linux distros ship `sha256sum`. We accept either.
if command -v sha256sum >/dev/null 2>&1; then
  sha_cmd="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  sha_cmd="shasum -a 256"
else
  die "missing SHA-256 tool (need sha256sum or shasum)"
fi

# ---- Resolve latest release --------------------------------------------
api_url="https://api.github.com/repos/${REPO}/releases/latest"
spin_start "Resolving latest release"
release_json=$(curl -fsSL -H "accept: application/vnd.github+json" "$api_url") \
  || die "could not reach $api_url"

# Extract tag + asset URLs. We avoid jq (not universally installed) and
# fall back to awk-based parsing — fragile but matches the strict shape the
# GitHub API guarantees (one tag_name field, one assets[] array).
tag_name=$(printf '%s' "$release_json" | awk -F'"' '/"tag_name":/ { print $4; exit }')
[ -n "$tag_name" ] || die "could not parse tag_name from release JSON"

# Pick the asset matching ASSET and checksums.txt.
bin_url=$(printf '%s' "$release_json" \
  | awk -v want="\"name\": \"${ASSET}\"" '
      $0 ~ want { found=1 }
      found && /browser_download_url/ {
        match($0, /https:\/\/[^"]+/)
        print substr($0, RSTART, RLENGTH)
        exit
      }')
sums_url=$(printf '%s' "$release_json" \
  | awk '
      /"name": "checksums.txt"/ { found=1 }
      found && /browser_download_url/ {
        match($0, /https:\/\/[^"]+/)
        print substr($0, RSTART, RLENGTH)
        exit
      }')

[ -n "$bin_url" ]  || die "no binary for ${os}-${arch} in ${tag_name}"
[ -n "$sums_url" ] || die "release ${tag_name} is missing checksums.txt — refusing to install unverified binary"

spin_stop "Found ${tag_name} for ${os}-${arch}"

# ---- Download to a staged tmpdir ---------------------------------------
tmp=$(mktemp -d 2>/dev/null || mktemp -d -t logicstar-install)
# Layer the staging-dir cleanup on top of the spinner trap so both fire.
trap 'spin_stop ""; rm -rf "$tmp"' EXIT INT TERM

spin_start "Downloading binary (~70 MB)"
curl -fsSL -H "accept: application/octet-stream" -o "${tmp}/${ASSET}" "$bin_url" \
  || die "binary download failed"
spin_stop "Downloaded binary"

spin_start "Downloading checksums"
curl -fsSL -H "accept: application/octet-stream" -o "${tmp}/checksums.txt" "$sums_url" \
  || die "checksums download failed"
spin_stop "Downloaded checksums.txt"

# ---- Verify SHA-256 ----------------------------------------------------
spin_start "Verifying SHA-256"
expected=$(awk -v target="$ASSET" '$2 == target { print $1 }' "${tmp}/checksums.txt")
[ -n "$expected" ] || die "no checksum entry for ${ASSET} in checksums.txt"

actual=$(cd "$tmp" && $sha_cmd "$ASSET" | awk '{ print $1 }')
[ "$actual" = "$expected" ] \
  || die "checksum mismatch (expected $expected, got $actual) — refusing to install"
spin_stop "Checksum verified"

# ---- Install ------------------------------------------------------------
# Refuse to overwrite a `logicstar install --env dev` symlink, which would
# clobber the source file it points at.
if [ -L "$BIN_PATH" ]; then
  die "$BIN_PATH is a symlink (likely a dev install). Remove it first if you want a binary install."
fi

mkdir -p "$BIN_DIR"
chmod 0755 "${tmp}/${ASSET}"
mv "${tmp}/${ASSET}" "$BIN_PATH"

printf '%b✓%b Installed at %s\n' "$C_GREEN" "$C_RESET" "$BIN_PATH"

# ---- PATH hint ----------------------------------------------------------
case ":${PATH:-}:" in
  *":${BIN_DIR}:"*) ;;
  *)
    printf '\n%bNote:%b %s is not on your PATH.\n' "$C_DIM" "$C_RESET" "$BIN_DIR"
    printf '%bAdd to your shell profile:%b\n' "$C_DIM" "$C_RESET"
    printf '  export PATH="%s:$PATH"\n\n' "$BIN_DIR"
    ;;
esac

# ---- Auto-run `logicstar install` --------------------------------------
# Wires up MCP, hooks, statusline across every detected Claude Code / Cursor
# install. Inherits stdio so the device-code login URL is visible AND the
# user can ^C if they want to defer setup. A non-zero exit doesn't fail the
# overall installer — the binary is already in place and the user can re-run
# `logicstar install` manually.
printf '%b→%b Running %blogicstar install%b...\n\n' "$C_CYAN" "$C_RESET" "$C_CYAN" "$C_RESET"
if "$BIN_PATH" install; then
  printf '\n%b✓%b Done.\n' "$C_GREEN" "$C_RESET"
else
  rc=$?
  printf '\n%b!%b `logicstar install` exited with %s. Re-run it manually to finish setup.\n' "$C_RED" "$C_RESET" "$rc" >&2
fi
