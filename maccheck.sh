#!/usr/bin/env bash
# maccheck.sh
set -euo pipefail

# Color output functions
red() { printf "\033[31m%s\033[0m\n" "$*" >&2; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }

# Check for required command-line tools
require_cmds=(codesign spctl shasum xattr awk sed grep find) #PlistBuddy
missing=()
for c in "${require_cmds[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
if ((${#missing[@]})); then
  red "Missing required tools: ${missing[*]}"
  red "Please install Xcode Command Line Tools: xcode-select --install"
  exit 1
fi

# Input validation
INPUT="${1:-}"
if [[ -z "$INPUT" ]]; then
  red "Usage: $0 <path_to.dmg_or.app>"
  exit 1
fi

ABS_INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
WORKDIR="$(mktemp -d)"
MOUNTPOINT=""
APP_PATH=""

# Cleanup function to unmount DMG and remove temp directory on exit
cleanup() {
  [[ -n "$MOUNTPOINT" && -d "$MOUNTPOINT" ]] && hdiutil detach "$MOUNTPOINT" -quiet || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Report file setup
TS="$(date +%Y%m%d_%H%M%S)"
BASE="$(basename "$ABS_INPUT")"
REPORT="report_${BASE}_${TS}.txt"

write() { printf "%s\n" "$*" | tee -a "$REPORT" >/dev/null; }
section() { write ""; write "===== $* ====="; }

write "macOS App/Disk Image Security Report"
write "Target: $ABS_INPUT"
write "Generated: $(date)"
write "----------------------------------------------"

# 1) If input is a DMG, mount it and find the .app bundle
if [[ "$ABS_INPUT" == *.dmg ]]; then
  section "Mounting DMG"
  MOUNTPOINT="$(mktemp -d /tmp/mnt.XXXXXX)"
  if hdiutil attach -nobrowse -readonly -mountpoint "$MOUNTPOINT" "$ABS_INPUT" >/dev/null 2>&1; then
    write "Mounted at: $MOUNTPOINT"
    APP_PATH="$(find "$MOUNTPOINT" -maxdepth 2 -name "*.app" -type d | head -n 1 || true)"
    if [[ -z "$APP_PATH" ]]; then
      write "No .app found in DMG. Contents:"
      find "$MOUNTPOINT" -maxdepth 2 -print | tee -a "$REPORT" >/dev/null
      red "No .app found in DMG, nothing to check."
      exit 1
    fi
  else
    red "Failed to mount DMG."
    exit 1
  fi
elif [[ "$ABS_INPUT" == *.app || -d "$ABS_INPUT"/Contents ]]; then
  APP_PATH="$ABS_INPUT"
else
  red "Expected a .dmg or .app file."
  exit 1
fi

write "App path: $APP_PATH"

# 2) Get basic app info from Info.plist
section "Basic Info"
INFO="$APP_PATH/Contents/Info.plist"
if [[ -f "$INFO" ]]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO" 2>/dev/null || echo '-')"
    BUNDLE_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null || echo '-')"
    BUNDLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO" 2>/dev/null || echo '-')"
    MAIN_BIN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO" 2>/dev/null || echo "")"
    write "Bundle Name: $BUNDLE_NAME"
    write "Bundle ID:   $BUNDLE_ID"
    write "Version:     $BUNDLE_VER"
else
    write "Info.plist not found."
    MAIN_BIN=""
fi

# 3) Check for quarantine attribute (indicates downloaded from internet)
section "Quarantine Attribute"
if xattr -p com.apple.quarantine "$APP_PATH" >/dev/null 2>&1; then
  QUAR="$(xattr -p com.apple.quarantine "$APP_PATH" 2>/dev/null || true)"
  write "com.apple.quarantine: $QUAR"
else
  write "Quarantine attribute not found."
fi

# 4) Check code signature and notarization
section "Code Signature (codesign)"
# Execute codesign once and capture all output (stdout & stderr)
CODESIGN_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
EXIT_CODE=$?
printf "%s\n" "$CODESIGN_DETAILS" >> "$REPORT"

# Parse details if the signature is valid
if [[ $EXIT_CODE -eq 0 ]]; then
  SIG_STATUS="SIGNED"
  # Make parsing robust against non-standard signatures and prevent script exit on grep failure
  SIGNER_INFO=$(printf "%s" "$CODESIGN_DETAILS" | grep "^Authority=" | sed 's/^Authority=//' || true)
  TEAM_ID=$(printf "%s" "$CODESIGN_DETAILS" | grep "^TeamIdentifier=" | sed 's/^TeamIdentifier=//' || true)
  TIMESTAMP_INFO=$(printf "%s" "$CODESIGN_DETAILS" | grep "^Timestamp=" | sed 's/^Timestamp=//' || true)

  # If parsing fails, provide a default value
  : "${SIGNER_INFO:=-}"
  : "${TEAM_ID:=-}"
  : "${TIMESTAMP_INFO:=-}"
else
  SIG_STATUS="NO_SIGN_OR_INVALID"
  SIGNER_INFO="-"
  TEAM_ID="-"
  TIMESTAMP_INFO="-"
fi

section "Gatekeeper Assessment (spctl)"
if spctl --assess --type execute --verbose=4 "$APP_PATH" >>"$REPORT" 2>&1; then
  SPCTL_STATUS="ACCEPTED"
  write "spctl: accepted"
else
  SPCTL_STATUS="REJECTED"
  write "spctl: rejected"
fi

# 5) Perform a deep and strict signature verification
section "Deep/Strict Verify"
if codesign -vvv --deep --strict "$APP_PATH" >>"$REPORT" 2>&1; then
  write "codesign strict: OK"
else
  write "codesign strict: FAIL"
fi

# 6) Calculate SHA256 hashes
section "SHA256 Hashes"
if [[ "$ABS_INPUT" == *.dmg ]]; then
  write "DMG SHA256:"
  shasum -a 256 "$ABS_INPUT" | tee -a "$REPORT" >/dev/null
fi
if [[ -d "$APP_PATH" && -n "$MAIN_BIN" && -f "$APP_PATH/Contents/MacOS/$MAIN_BIN" ]]; then
    write "Main binary SHA256:"
    shasum -a 256 "$APP_PATH/Contents/MacOS/$MAIN_BIN" | tee -a "$REPORT" >/dev/null
fi

# 7) Find embedded scripts and suspicious commands
section "Embedded Scripts & Suspicious Artifacts"
find "$APP_PATH" -type f \( -name "*.sh" -o -name "*.py" -o -name "*.js" -o -name "*.command" -o -name "*.pkg" -o -name "*.postinstall" -o -name "*.preinstall" \) | tee -a "$REPORT" >/dev/null
write "--- Occurrences of potentially dangerous commands ---"
grep -I -R -n -E 'curl|wget|nc |ncat|osascript|python3?|ruby|bash -c|eval ' "$APP_PATH" 2>/dev/null | head -n 200 | tee -a "$REPORT" >/dev/null

# 8) List privacy-related usage descriptions from Info.plist
section "Privacy Usage Descriptions (Info.plist)"
for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSContactsUsageDescription NSCalendarsUsageDescription NSPhotoLibraryUsageDescription NSFileProviderPresenceUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Print :$key" "$INFO" >/dev/null 2>&1; then
    val="$(/usr/libexec/PlistBuddy -c "Print :$key" "$INFO" 2>/dev/null || echo "")"
    write "$key: $val"
  fi
done

# 9) Snapshot of LaunchAgents/Daemons directories
section "LaunchAgents & Daemons Snapshot"
for p in "$HOME/Library/LaunchAgents" "/Library/LaunchAgents" "/Library/LaunchDaemons"; do
  if [[ -d "$p" ]]; then
    write "--- $p ---"
    ls -1 "$p" | tee -a "$REPORT" >/dev/null || true
  fi
done

# 10) List linked libraries of the main executable
if command -v otool >/dev/null 2>&1; then
  section "Linked Libraries (otool -L)"
  if [[ -n "$MAIN_BIN" && -f "$APP_PATH/Contents/MacOS/$MAIN_BIN" ]]; then
    otool -L "$APP_PATH/Contents/MacOS/$MAIN_BIN" | tee -a "$REPORT" >/dev/null
  else
    write "Main binary not found for otool."
  fi
fi

# --- Final Summary ---
section "Result Summary"
QUAR_STATUS="NO"
xattr -p com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 && QUAR_STATUS="YES"

write "Signature: $SIG_STATUS"
write "  -> Signer: $SIGNER_INFO"
write "  -> Team ID: $TEAM_ID"
write "  -> Timestamp: $TIMESTAMP_INFO"
write "Gatekeeper: $SPCTL_STATUS"
write "Quarantine attr: $QUAR_STATUS"


# --- Final colored output to console ---
echo ""
echo "===== Quick Summary ====="

if [[ "$SIG_STATUS" == "SIGNED" ]]; then
  green "  Signature:     ✔ SIGNED"
  printf "    Signer:      %s\n" "$SIGNER_INFO"
  printf "    Team ID:     %s\n" "$TEAM_ID"
  printf "    Timestamp:   %s\n" "$TIMESTAMP_INFO"
else
  red   "  Signature:     ✘ NO_SIGN_OR_INVALID"
fi

if [[ "$SPCTL_STATUS" == "ACCEPTED" ]]; then
  green "  Gatekeeper:    ✔ ACCEPTED"
else
  red   "  Gatekeeper:    ✘ REJECTED"
fi

if [[ "$QUAR_STATUS" == "YES" ]]; then
  yellow "  Quarantine:    ! YES (Downloaded from internet)"
else
  green "  Quarantine:    - NO"
fi

echo "======================="
echo ""
green "✔ Full report saved to: $(pwd)/$REPORT"
