#!/bin/bash
#
# Build, sign, notarize and staple a Eudora.app that opens on someone else's Mac.
#
# Why each step is here, since skipping any one of them produces an app that
# looks fine locally and is refused on the recipient's machine:
#
#   build      Release, not Debug. project.yml signs with the Developer ID
#              identity and enables the hardened runtime; notarization rejects
#              anything without the latter.
#   verify     Catches a bad signature here rather than after a round trip to
#              Apple.
#   zip        `ditto -c -k --keepParent` — the only zip format notarytool
#              accepts. A Finder-compressed archive or `zip -r` will be
#              rejected, sometimes obscurely.
#   notarize   Apple scans the binary and issues a ticket.
#   staple     Attaches the ticket TO THE APP, so it opens even if the
#              recipient is offline and with no instructions attached. The
#              ticket cannot be stapled to a zip, which is why the app is
#              zipped twice: once to submit, once to hand over.
#   assess     Asks Gatekeeper the same question the recipient's Mac will ask.
#
# One-time setup before this will run — see EudoraDevelopmentNotes.txt:
#   1. An app-specific password from appleid.apple.com.
#   2. xcrun notarytool store-credentials "eudora-notary" \
#        --apple-id <your-apple-id> --team-id S59385AX28 --password <that>
#
# Usage: scripts/release.sh

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/EudoraApp.xcodeproj"
SCHEME="EudoraApp"
PROFILE="eudora-notary"
DIST="$REPO/dist"
DERIVED="$DIST/DerivedData"
APP="$DERIVED/Build/Products/Release/Eudora.app"

say() { printf '\n=== %s ===\n' "$1"; }
die() { printf '\nFAILED: %s\n' "$1" >&2; exit 1; }

# Every check below reads a command's output into a variable and matches with
# `case`, rather than piping to `grep -q`. That is not fastidiousness: `grep -q`
# exits at the first match, the upstream command dies of SIGPIPE, and `pipefail`
# then reports the whole pipeline as failed — so the test fails exactly when it
# should pass. This cost one full release run to find.
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# Every Apple tool below is called by absolute path, because Stephen's PATH puts
# /usr/local/bin/humdrum/bin ahead of /usr/bin and Humdrum ships its own `ditto`
# — a text utility, not an archiver. It accepted none of the flags, produced no
# zip, and the failure surfaced two commands later as "the file doesn't exist".
# Assume any short tool name here may be shadowed.

# ---------------------------------------------------------------- preflight
say "preflight"

IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
contains "$IDENTITIES" "Developer ID Application" \
  || die "No Developer ID Application certificate in the keychain.
       Create one at developer.apple.com under team S59385AX28."

/usr/bin/xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || die "No notarytool keychain profile named '$PROFILE'.
       Create it with:
         xcrun notarytool store-credentials \"$PROFILE\" \\
           --apple-id <your-apple-id> --team-id S59385AX28"

echo "certificate and notary profile both present"

# -------------------------------------------------------------------- build
say "build (Release)"
mkdir -p "$DIST"
BUILD_LOG="$DIST/build.log"
set +e
/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  clean build 2>&1 | tee "$BUILD_LOG" | grep -E "^(\*\* |error:)"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

[ "$BUILD_STATUS" -eq 0 ] || die "build failed — full output in $BUILD_LOG"
[ -d "$APP" ] || die "No app at $APP — the build did not produce one."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "built Eudora $VERSION"

# ------------------------------------------------------------------- verify
say "verify signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

SIGINFO="$(/usr/bin/codesign -dvvv "$APP" 2>&1 || true)"
contains "$SIGINFO" "Authority=Developer ID Application" \
  || die "Not signed with a Developer ID Application certificate. Signature was:
$SIGINFO"
contains "$SIGINFO" "(runtime)" \
  || die "Hardened runtime is not enabled; notarization would reject this.
       Check ENABLE_HARDENED_RUNTIME in project.yml, then rerun xcodegen."

echo "  Developer ID + hardened runtime confirmed"

# ----------------------------------------------------------------- notarize
say "notarize"
SUBMIT_ZIP="$DIST/Eudora-submit.zip"
rm -f "$SUBMIT_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

LOG="$DIST/notarytool.log"
set +e
/usr/bin/xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$LOG"
set -e

if ! grep -q "status: Accepted" "$LOG"; then
  ID="$(awk '/^  *id: /{print $2; exit}' "$LOG")"
  echo
  echo "Notarization was not accepted. Apple's reasons:"
  [ -n "${ID:-}" ] && /usr/bin/xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
  die "notarization rejected"
fi

# ------------------------------------------------------------------- staple
say "staple"
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"

# ------------------------------------------------------------------- assess
say "Gatekeeper assessment"
# This is the question the recipient's Mac asks. "accepted / source=Notarized
# Developer ID" is the answer that means they can just double-click it.
ASSESS="$(/usr/sbin/spctl -a -vvv -t install "$APP" 2>&1 || true)"
echo "$ASSESS" | sed 's/^/  /'
contains "$ASSESS" "accepted" \
  || die "Gatekeeper would refuse this app on the recipient's Mac."

# --------------------------------------------------------------- deliverable
say "package"
OUT="$DIST/Eudora-$VERSION.zip"
rm -f "$OUT"
/usr/bin/ditto -c -k --keepParent "$APP" "$OUT"
rm -f "$SUBMIT_ZIP"

say "done"
echo "Send this file:"
echo "  $OUT"
echo
echo "The recipient drags Eudora.app to /Applications and double-clicks it."
echo "No Gatekeeper override, no instructions, works offline."
