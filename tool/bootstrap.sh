#!/usr/bin/env bash
#
# bootstrap.sh — the deterministic half of setting this project up.
#
# It checks the toolchain, pins Flutter, fetches dependencies and creates the
# config files from their examples. It deliberately does NOT build or install:
# those need decisions (which device, which bundle id, whether you want the AI
# coach) that a script should not be guessing at.
#
# Safe to re-run. It never overwrites an existing .env or Signing.xcconfig.
#
#   ./tool/bootstrap.sh            check everything and set up
#   ./tool/bootstrap.sh --check    report only, change nothing

set -euo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# Colour only when attached to a terminal, so logs and CI stay readable.
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=''; RED=''; GREEN=''; YELLOW=''; DIM=''; RESET=''
fi

ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }
head() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$RESET"; }

PROBLEMS=0
fail() { bad "$1"; PROBLEMS=$((PROBLEMS + 1)); }

# The pinned version, read from .fvmrc so this script cannot drift from it.
PINNED="$(sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .fvmrc 2>/dev/null || true)"
[[ -z "$PINNED" ]] && PINNED="3.41.6"

printf '%sWhoop — setup%s\n' "$BOLD" "$RESET"
note "Flutter is pinned to $PINNED. This is not optional; see README."

# ── toolchain ───────────────────────────────────────────────────────────────
head "Toolchain"

if command -v git >/dev/null 2>&1; then ok "git"; else fail "git is missing"; fi

if command -v fvm >/dev/null 2>&1; then
  ok "fvm"
else
  fail "fvm is missing"
  note "macOS:  brew tap leoafarias/fvm && brew install fvm"
  note "other:  https://fvm.app/documentation/getting-started/installation"
fi

# A bare `flutter` on PATH is not a problem in itself, but running it by
# accident is: this project does not compile on current stable.
if command -v flutter >/dev/null 2>&1; then
  BARE="$(flutter --version 2>/dev/null | sed -n '1s/.*Flutter \([0-9.]*\).*/\1/p' || true)"
  if [[ -n "$BARE" && "$BARE" != "$PINNED" ]]; then
    warn "a system flutter $BARE is on your PATH"
    note "Always type 'fvm flutter'. Bare 'flutter' will fail to compile this project."
  fi
fi

case "$(uname -s)" in
  Darwin)
    if xcode-select -p >/dev/null 2>&1; then ok "Xcode command line tools"
    else warn "Xcode not detected (only needed for iOS builds)"; fi
    ;;
esac

if command -v java >/dev/null 2>&1; then
  # Version string layout differs across JDK vendors, so this is best-effort
  # and the check never fails on a parse miss.
  JAVA_V="$(java -version 2>&1 | head -1 | sed -n 's/.*[version|openjdk][[:space:]]*"\{0,1\}\([0-9][0-9.]*\).*/\1/p')"
  ok "java${JAVA_V:+ $JAVA_V}"
else
  warn "java not found (only needed for Android builds)"
fi

if [[ -n "${ANDROID_HOME:-}" || -d "$HOME/Library/Android/sdk" || -d "$HOME/Android/Sdk" ]]; then
  ok "Android SDK"
else
  warn "Android SDK not found (only needed for Android builds)"
  note "Install Android Studio; it sets the SDK up on first launch."
fi

if (( PROBLEMS > 0 )); then
  printf '\n%s%d required tool(s) missing.%s Install them and re-run.\n' "$RED" "$PROBLEMS" "$RESET"
  exit 1
fi

if (( CHECK_ONLY )); then
  printf '\n%sCheck only — nothing changed.%s\n' "$DIM" "$RESET"
  exit 0
fi

# ── flutter ─────────────────────────────────────────────────────────────────
head "Flutter $PINNED"
fvm install
fvm flutter pub get
ok "dependencies resolved"

# ── config ──────────────────────────────────────────────────────────────────
# Created from examples, never overwritten. Both are gitignored, which is the
# whole point: nobody's key or team id should reach the repository.
head "Config files"

if [[ -f .env ]]; then
  ok ".env exists (left alone)"
else
  cp .env.example .env
  echo "ENABLE_HEALTH_DATA_CONTRIBUTION=false" >> .env
  ok ".env created from example"
  note "Add a Gemini key if you want the AI coach. Create it in a project"
  note "with NO BILLING enabled, or it will not be on the free tier."
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  if [[ -f ios/Config/Signing.xcconfig ]]; then
    ok "Signing.xcconfig exists (left alone)"
  else
    cp ios/Config/Signing.xcconfig.example ios/Config/Signing.xcconfig
    ok "Signing.xcconfig created from example"
    note "Add your Apple Team ID and a bundle id unique to you."
    note "Xcode > Settings > Accounts > Manage Certificates"
  fi
fi

# ── verify ──────────────────────────────────────────────────────────────────
head "Verifying"
if fvm flutter test >/dev/null 2>&1; then
  ok "tests pass"
else
  fail "tests failed"
  note "Check the Flutter version FIRST. The known failure mode is ~22 test"
  note "files failing at LOAD on a too-new Flutter, which looks like a test"
  note "bug and is not:  fvm flutter --version"
  exit 1
fi

# ── next ────────────────────────────────────────────────────────────────────
head "Next"
cat <<EOF
  Android:
    fvm flutter build apk --release --dart-define-from-file=.env

  iPhone (needs your Team ID in ios/Config/Signing.xcconfig first):
    fvm flutter build ios --release --dart-define-from-file=.env
    xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app

  ${BOLD}Never use 'fvm flutter install' on iOS${RESET} — it wipes the database.
  On Android it is fine; there it is a normal package upgrade.

  Full guides:  docs/SETUP.md  ·  docs/ANDROID.md  ·  docs/SETUP_WITH_CLAUDE.md
EOF
