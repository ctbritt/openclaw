#!/usr/bin/env bash
set -euo pipefail

# Build, notarize, staple, and publish a macOS build to a self-hosted Sparkle appcast.
#
# For operator-controlled private feeds (LAN/tailnet). This deliberately does NOT use
# scripts/make_appcast.sh: that tool seeds its working set from the repo's official
# appcast.xml, defaults downloads to the openclaw GitHub releases URL, and overwrites the
# tracked appcast.xml at repo root — all wrong for a private feed. It calls Sparkle's
# generate_appcast directly against the publish directory instead.
#
# Required env:
#   SPARKLE_FEED_URL           feed URL baked into the app and written into the appcast
#   SPARKLE_PUBLIC_ED_KEY      EdDSA public key matching SPARKLE_PRIVATE_KEY_FILE
#   SPARKLE_PRIVATE_KEY_FILE   EdDSA private key used to sign the appcast
#   NOTARYTOOL_PROFILE         notarytool keychain profile
#   SIGN_IDENTITY              Developer ID Application cert (SHA-1 hash or name)
# Optional env:
#   PUBLISH_DIR                served directory (default ~/.local/share/openclaw-updates)
#   RETAIN_RELEASES            zips to keep (default 5)
#   BUNDLE_ID                  passed through to the packager
#   RELEASE_ALLOW_UNCLEAN=1    publish from a non-main, out-of-date, or dirty checkout

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Must live on the internal disk: TCC denies launchd background processes (the static
# server behind `tailscale serve`) access to external volumes such as /Volumes/foundrydisk.
PUBLISH_DIR="${PUBLISH_DIR:-$HOME/.local/share/openclaw-updates}"
RETAIN_RELEASES="${RETAIN_RELEASES:-5}"
APP="$ROOT_DIR/dist/OpenClaw.app"
STAGE_DIR="$ROOT_DIR/dist/notarize"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

for var in SPARKLE_FEED_URL SPARKLE_PUBLIC_ED_KEY SPARKLE_PRIVATE_KEY_FILE NOTARYTOOL_PROFILE SIGN_IDENTITY; do
  [[ -n "${!var:-}" ]] || fail "$var must be set"
done
[[ -f "$SPARKLE_PRIVATE_KEY_FILE" ]] || fail "SPARKLE_PRIVATE_KEY_FILE not found: $SPARKLE_PRIVATE_KEY_FILE"
[[ "$RETAIN_RELEASES" =~ ^[0-9]+$ && "$RETAIN_RELEASES" -ge 1 ]] || fail "RETAIN_RELEASES must be a positive integer"

# Checked before the build so a bad checkout costs seconds, not a full build + notarization.
if [[ "${RELEASE_ALLOW_UNCLEAN:-0}" == "1" ]]; then
  echo "==> RELEASE_ALLOW_UNCLEAN=1: publishing from an unverified checkout"
else
  BRANCH="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)"
  [[ "$BRANCH" == "main" ]] \
    || fail "on branch '$BRANCH'; releases publish from main (RELEASE_ALLOW_UNCLEAN=1 to override)"
  git -C "$ROOT_DIR" fetch origin main --quiet || fail "could not fetch origin/main"
  [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$(git -C "$ROOT_DIR" rev-parse origin/main)" ]] \
    || fail "HEAD is not at origin/main; pull first (RELEASE_ALLOW_UNCLEAN=1 to override)"
  # Modified tracked files reach the built app while OpenClawGitCommit still records HEAD, so
  # the published build would name a commit whose source it does not match. Untracked files
  # never build in, so they must not block a release.
  git -C "$ROOT_DIR" diff --quiet HEAD -- \
    || fail "uncommitted changes to tracked files (RELEASE_ALLOW_UNCLEAN=1 to override)"
fi

DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-${SPARKLE_FEED_URL%/*}/}"

GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$GENERATE_APPCAST" ]]; then
  GENERATE_APPCAST="$(find "$ROOT_DIR/apps/macos/.build" -type f \
    -path "*/artifacts/sparkle/Sparkle/bin/generate_appcast" -print -quit 2>/dev/null || true)"
fi
[[ -n "$GENERATE_APPCAST" && -x "$GENERATE_APPCAST" ]] \
  || fail "generate_appcast not found; build the mac app first so SwiftPM emits Sparkle tooling"

# Monotonic build number. The canonical Sparkle build is derived from the version string,
# so every build of one version collides; commit count keeps successive private builds
# ordered. Machines must be baselined onto this scheme by one manual install.
APP_BUILD="$(cd "$ROOT_DIR" && git rev-list --count HEAD)"
[[ "$APP_BUILD" =~ ^[0-9]+$ ]] || fail "Could not derive numeric APP_BUILD from git"

# The feed itself is the authority on what has shipped. Commit count is branch-relative, so a
# wrong branch, reset, or restored checkout can mint a number at or below one already published;
# Sparkle then treats the release as a downgrade and offers nothing, with no error anywhere.
# Deliberately not overridable — a silently dead feed is worse than a refused release.
if [[ -f "$PUBLISH_DIR/appcast.xml" ]]; then
  HIGHEST_PUBLISHED="$(sed -n 's/.*<sparkle:version>\([0-9]\{1,\}\)<\/sparkle:version>.*/\1/p' \
    "$PUBLISH_DIR/appcast.xml" | sort -n | tail -1)"
  if [[ -n "$HIGHEST_PUBLISHED" ]] && ((APP_BUILD <= HIGHEST_PUBLISHED)); then
    fail "build $APP_BUILD does not exceed published build $HIGHEST_PUBLISHED; Sparkle would ignore it"
  fi
fi

echo "==> Building (APP_BUILD=$APP_BUILD, feed=$SPARKLE_FEED_URL)"
# CODESIGN_TIMESTAMP=on is mandatory: codesign-mac-app.sh only auto-enables the trusted
# timestamp when SIGN_IDENTITY is a cert *name*, so a SHA-1-pinned identity would sign
# without one and Apple would reject notarization.
APP_BUILD="$APP_BUILD" \
CODESIGN_TIMESTAMP=on \
SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  bash "$ROOT_DIR/scripts/package-mac-app.sh"

[[ -d "$APP" ]] || fail "packager produced no bundle at $APP"

echo "==> Verifying build metadata and trusted timestamp"
# Capture first rather than piping into `grep -q`: under `set -o pipefail` an early grep exit
# SIGPIPEs codesign, so the pipeline fails intermittently even when the timestamp is present.
SIG_INFO="$(codesign -dvvv "$APP" 2>&1 || true)"
case "$SIG_INFO" in
  *"Timestamp="*) ;;
  *) fail "no trusted timestamp on $APP; notarization would be rejected" ;;
esac

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
EMBEDDED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$EMBEDDED_BUILD" == "$APP_BUILD" ]] \
  || fail "CFBundleVersion is $EMBEDDED_BUILD, expected $APP_BUILD"
EMBEDDED_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$EMBEDDED_FEED" == "$SPARKLE_FEED_URL" ]] \
  || fail "SUFeedURL is '${EMBEDDED_FEED}', expected '$SPARKLE_FEED_URL'"

echo "==> Notarizing and stapling"
mkdir -p "$STAGE_DIR"
NOTARIZE_ZIP="$STAGE_DIR/OpenClaw-notarize.zip"
rm -f "$NOTARIZE_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
NOTARYTOOL_PROFILE="$NOTARYTOOL_PROFILE" STAPLE_APP_PATH="$APP" \
  bash "$ROOT_DIR/scripts/notarize-mac-artifact.sh" "$NOTARIZE_ZIP"

echo "==> Confirming Gatekeeper acceptance"
# spctl is SILENT on success (exit 0, no output); only -vv prints "accepted". Grepping the
# output therefore fails a perfectly good build, so gate on the exit status and log verbosely.
spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/    /' || true
spctl -a -t exec "$APP" >/dev/null 2>&1 \
  || fail "Gatekeeper did not accept $APP; refusing to publish"
xcrun stapler validate "$APP" >/dev/null 2>&1 || fail "staple ticket missing on $APP"

# Re-zip AFTER stapling. The notarization zip holds an unstapled app; publishing it would
# ship builds with no ticket, which trip Gatekeeper on any machine that did not build them.
RELEASE_ZIP="OpenClaw-${APP_VERSION}-${APP_BUILD}.zip"
echo "==> Packaging stapled release: $RELEASE_ZIP"
mkdir -p "$PUBLISH_DIR"
rm -f "$PUBLISH_DIR/$RELEASE_ZIP"
ditto -c -k --keepParent "$APP" "$PUBLISH_DIR/$RELEASE_ZIP"

# Prune BEFORE regenerating: generate_appcast builds the feed from whatever archives remain,
# so pruning afterwards would leave the feed advertising zips that no longer exist.
echo "==> Pruning to $RETAIN_RELEASES release(s)"
# Collect first: an unmatched glob or an early `tail` exit would otherwise trip `pipefail`
# and abort a release that has nothing to prune.
OLD_ZIPS="$( { ls -t "$PUBLISH_DIR"/OpenClaw-*.zip 2>/dev/null || true; } | tail -n "+$((RETAIN_RELEASES + 1))" )"
if [[ -n "$OLD_ZIPS" ]]; then
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    echo "    removing $(basename "$old")"
    rm -f "$old"
  done <<< "$OLD_ZIPS"
else
  echo "    nothing to prune"
fi

echo "==> Signing appcast"
"$GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$SPARKLE_FEED_URL" \
  "$PUBLISH_DIR"

[[ -f "$PUBLISH_DIR/appcast.xml" ]] || fail "no appcast.xml produced in $PUBLISH_DIR"
grep -q "sparkle:edSignature=" "$PUBLISH_DIR/appcast.xml" \
  || fail "appcast.xml has no EdDSA signature"
grep -q "<sparkle:version>${APP_BUILD}</sparkle:version>" "$PUBLISH_DIR/appcast.xml" \
  || fail "appcast.xml does not advertise build $APP_BUILD"

echo "==> Published"
echo "    version:  $APP_VERSION (build $APP_BUILD)"
echo "    feed:     $SPARKLE_FEED_URL"
echo "    dir:      $PUBLISH_DIR"
ls -1 "$PUBLISH_DIR"
