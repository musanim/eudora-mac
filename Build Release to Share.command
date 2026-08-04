#!/bin/bash
#
# Double-click this to build a Eudora anyone can run, and reveal the zip.
#
# It bumps the version, regenerates the Xcode project, and runs
# scripts/release.sh (build, sign, notarize, staple, package). Nothing to
# remember and nothing to type; the only thing it needs from you is patience
# while Apple notarizes, which is usually a couple of minutes.
#
# A `.command` file is run by Finder with an unpredictable working directory and
# a login shell, so this cds to its own folder and finds its tools by absolute
# path or by searching — see the xcodegen lookup below, and note that
# scripts/release.sh calls every Apple tool absolutely for the same reason
# (Humdrum shadows `ditto` on this machine).
#
# Version: bumps the patch component by default — 0.3.2 becomes 0.3.3. For a
# bigger jump, edit MARKETING_VERSION in project.yml by hand first and this will
# carry on from whatever it finds.
#
# If anything fails, project.yml is put back the way it was, so a failed release
# doesn't quietly leave the version bumped and the next attempt skipping a number.

set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n=== %s ===\n' "$1"; }

PROJECT_YML="project.yml"
BACKUP="$(/usr/bin/mktemp -t eudora-project-yml)"
/bin/cp "$PROJECT_YML" "$BACKUP"

pause_and_exit() {
    printf '\nPress Return to close this window.\n'
    read -r _ || true
    exit "$1"
}

restore_and_fail() {
    /bin/cp "$BACKUP" "$PROJECT_YML"
    /bin/rm -f "$BACKUP"
    printf '\nSomething failed above, so nothing was released.\n'
    printf 'project.yml has been put back the way it was (version NOT bumped).\n'
    pause_and_exit 1
}
trap restore_and_fail ERR

# ------------------------------------------------------------------ xcodegen
# Homebrew lives in different places on Apple Silicon and Intel, and a
# Finder-launched shell may not have either on PATH.
XCODEGEN=""
for candidate in "$(command -v xcodegen 2>/dev/null || true)" \
                 /opt/homebrew/bin/xcodegen \
                 /usr/local/bin/xcodegen; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then XCODEGEN="$candidate"; break; fi
done
if [ -z "$XCODEGEN" ]; then
    printf 'Could not find xcodegen. Install it with:  brew install xcodegen\n' >&2
    restore_and_fail
fi

# -------------------------------------------------------------- bump version
say "version"

CURRENT="$(/usr/bin/sed -n 's/^ *MARKETING_VERSION: *"\(.*\)" *$/\1/p' "$PROJECT_YML" | head -1)"
if [ -z "$CURRENT" ]; then
    printf 'Could not read MARKETING_VERSION from %s\n' "$PROJECT_YML" >&2
    restore_and_fail
fi

MAJOR="${CURRENT%%.*}"
REST="${CURRENT#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"
case "$PATCH" in
    ''|*[!0-9]*) printf 'Version "%s" is not major.minor.patch\n' "$CURRENT" >&2
                 restore_and_fail ;;
esac
NEXT="$MAJOR.$MINOR.$((PATCH + 1))"

/usr/bin/sed "s/^\( *MARKETING_VERSION: *\)\".*\"\( *\)$/\1\"$NEXT\"\2/" \
    "$PROJECT_YML" > "$PROJECT_YML.tmp"
/bin/mv "$PROJECT_YML.tmp" "$PROJECT_YML"

WROTE="$(/usr/bin/sed -n 's/^ *MARKETING_VERSION: *"\(.*\)" *$/\1/p' "$PROJECT_YML" | head -1)"
if [ "$WROTE" != "$NEXT" ]; then
    printf 'Version bump did not take (wanted %s, file says %s)\n' "$NEXT" "$WROTE" >&2
    restore_and_fail
fi
printf '%s  ->  %s\n' "$CURRENT" "$NEXT"

# ------------------------------------------------------------------ generate
say "regenerate Xcode project"
"$XCODEGEN" generate

# ------------------------------------------------------------------- release
scripts/release.sh

# ------------------------------------------------------------------- deliver
trap - ERR
/bin/rm -f "$BACKUP"

ZIP="dist/Eudora-$NEXT.zip"
say "ready"
if [ -f "$ZIP" ]; then
    printf 'Send this file:\n  %s\n' "$(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"
    /usr/bin/open -R "$ZIP"          # reveal it in Finder, selected
    printf '\nIt is now selected in a Finder window. Attach it to a mail, or drag\n'
    printf 'it wherever you like. The recipient unzips it, drags Eudora.app to\n'
    printf 'Applications, and double-clicks. No warnings, no instructions.\n'
else
    printf 'The release finished but %s is not there — look at the output above.\n' "$ZIP"
fi

printf '\nOne loose end for later: project.yml now says %s, and that change is\n' "$NEXT"
printf 'not committed. Commit it whenever you next commit anything.\n'

pause_and_exit 0
