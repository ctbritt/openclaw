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
#   BUILD_CONFIG               packager build config (default release)
#   BUILD_ARCHS                packager architectures (default arm64; use "all" for universal)
#   RELEASE_ALLOW_UNCLEAN=1    publish from a non-main, out-of-date, or dirty checkout

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Must live on the internal disk: TCC denies launchd background processes (the static
# server behind `tailscale serve`) access to external volumes such as /Volumes/foundrydisk.
PUBLISH_DIR="${PUBLISH_DIR:-$HOME/.local/share/openclaw-updates}"
RETAIN_RELEASES="${RETAIN_RELEASES:-5}"
APP="$ROOT_DIR/dist/OpenClaw.app"
STAGE_DIR="$ROOT_DIR/dist/notarize"

TOOL="mac-private-feed-release"
PUBLISHED_OK=0
PRUNE_STAGE=""

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

# A run that dies under `set -e` inside a child script never reaches fail(), so without this
# the last line an operator sees is a progress banner and truncated output reads as success.
# Restoring staged archives here is what keeps prune+regenerate atomic (see the prune block).
on_exit() {
  local code=$?
  if [[ -n "$PRUNE_STAGE" && -d "$PRUNE_STAGE" ]]; then
    if (( code != 0 || PUBLISHED_OK != 1 )); then
      mv -f "$PRUNE_STAGE"/* "$PUBLISH_DIR"/ 2>/dev/null || true
      echo "    restored pruned archives after a failed run" >&2
    fi
    rm -rf "$PRUNE_STAGE"
  fi
  if (( code != 0 )); then
    echo "[$TOOL] FAILED (exit $code)" >&2
  fi
}
trap on_exit EXIT

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
  # Untracked files DO reach the built app: Package.swift declares whole-directory .copy()
  # resources, package-mac-app.sh cp -R's those directories, and the JS build compiles the
  # working tree rather than the commit. So any dirt at all, tracked or not, can produce a
  # build that OpenClawGitCommit stamps with a commit whose source does not reproduce it.
  # Ignored paths (build output, node_modules) stay excluded by porcelain's own rules.
  DIRT="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)"
  [[ -z "$DIRT" ]] || fail "checkout is not clean (RELEASE_ALLOW_UNCLEAN=1 to override):
$DIRT"
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

# A number at or below one already published makes Sparkle treat the release as a downgrade
# and offer nothing, with no error anywhere. Deliberately not overridable — a silently dead
# feed is worse than a refused release.
#
# The floor comes from the ARCHIVES, not just appcast.xml: generate_appcast rebuilds the feed
# from whatever zips are in the directory, so a leftover higher-numbered zip from an
# interrupted run would become the newest item while an appcast-only check saw a stale, lower
# maximum and passed. Both sources are unioned, and an unreadable feed fails closed.
highest_published_build() {
  {
    sed -n 's/.*<sparkle:version>\([0-9]\{1,\}\)<\/sparkle:version>.*/\1/p' \
      "$PUBLISH_DIR/appcast.xml" 2>/dev/null || true
    { ls -1 "$PUBLISH_DIR"/OpenClaw-*.zip 2>/dev/null || true; } \
      | sed -n 's/.*-\([0-9]\{1,\}\)\.zip$/\1/p'
  } | sort -n | tail -1
}

if [[ -f "$PUBLISH_DIR/appcast.xml" ]] || compgen -G "$PUBLISH_DIR/OpenClaw-*.zip" >/dev/null; then
  HIGHEST_PUBLISHED="$(highest_published_build)"
  [[ -n "$HIGHEST_PUBLISHED" ]] \
    || fail "$PUBLISH_DIR has a feed or archives but no parsable build number; refusing to publish blind"
  ((APP_BUILD > HIGHEST_PUBLISHED)) \
    || fail "build $APP_BUILD does not exceed published build $HIGHEST_PUBLISHED; Sparkle would ignore it"
fi

# The private scheme (commit count, ~76k) sits far below the canonical one (~2.6e9, derived
# from the version string). An officially-numbered build already installed therefore outranks
# every private release forever, and Sparkle reports "up to date" with nothing to show for it.
INSTALLED_APP="/Applications/OpenClaw.app"
if [[ -d "$INSTALLED_APP" ]]; then
  INSTALLED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$INSTALLED_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$INSTALLED_BUILD" =~ ^[0-9]+$ ]] && ((INSTALLED_BUILD >= APP_BUILD)); then
    fail "installed app is build $INSTALLED_BUILD, at or above this release's $APP_BUILD;
this Mac would never take the update. Baseline it onto the private scheme with one manual
install first, or the machine is stranded on the higher number."
  fi
fi

# Pin the packager's config rather than inheriting its default. BUILD_CONFIG defaults to
# `debug`, where package-mac-app.sh downgrades the missing-Swift-runtime check to a warning
# and skips apple-release-source-check.sh entirely — a published build could then fail to
# launch on the receiving Mac with nothing wrong on the build machine.
#
# arm64 only. The feed has no architecture filtering, so the published slice must run on every
# consumer — and every consumer here is Apple silicon (proven: an arm64-only build launched on
# the MacBook Air, which an Intel Mac could not do; Rosetta only translates x86_64 toward arm).
# Universal doubles build time for a slice nothing on this tailnet would ever execute. Set
# BUILD_ARCHS=all before publishing if an Intel Mac ever joins the feed.
BUILD_CONFIG="${BUILD_CONFIG:-release}"
BUILD_ARCHS="${BUILD_ARCHS:-arm64}"

echo "==> Building (APP_BUILD=$APP_BUILD, $BUILD_CONFIG/${BUILD_ARCHS:-universal}, feed=$SPARKLE_FEED_URL)"
# CODESIGN_TIMESTAMP=on is mandatory: codesign-mac-app.sh only auto-enables the trusted
# timestamp when SIGN_IDENTITY is a cert *name*, so a SHA-1-pinned identity would sign
# without one and Apple would reject notarization. SKIP_* and the app-root override are
# forced off: a publish must never inherit a shell that was set up for fast local iteration.
APP_BUILD="$APP_BUILD" \
CODESIGN_TIMESTAMP=on \
BUILD_CONFIG="$BUILD_CONFIG" \
BUILD_ARCHS="$BUILD_ARCHS" \
SPARKLE_ALLOW_DEBUG_FEED=1 \
SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
SKIP_TSC=0 \
SKIP_PNPM_INSTALL=0 \
  env -u OPENCLAW_PACKAGE_APP_ROOT bash "$ROOT_DIR/scripts/package-mac-app.sh"

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
# package-mac-app.sh embeds Sparkle only when the built framework exists and skips silently
# otherwise, so a partially cleaned .build ships an app that passes every signing and
# notarization gate and then dies at launch on a missing @rpath/Sparkle.framework/Sparkle —
# stranding the receiving Mac on a build that can neither run nor update itself.
[[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]] \
  || fail "Sparkle.framework is not embedded in $APP; the published app could not self-update"

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
#
# PUBLISH_DIR is served live for the whole run, so pruned archives are MOVED to a staging dir
# rather than deleted. If anything below fails, the EXIT trap moves them back, leaving the
# still-current appcast pointing at files that are still there. Deleting outright would leave
# clients resolving enclosure URLs to a 404 until the next successful run.
echo "==> Pruning to $RETAIN_RELEASES release(s)"
PRUNE_STAGE="$(mktemp -d "$PUBLISH_DIR/.prune.XXXXXX")"
# Collect first: an unmatched glob or an early `tail` exit would otherwise trip `pipefail`
# and abort a release that has nothing to prune.
OLD_ZIPS="$( { ls -t "$PUBLISH_DIR"/OpenClaw-*.zip 2>/dev/null || true; } | tail -n "+$((RETAIN_RELEASES + 1))" )"
if [[ -n "$OLD_ZIPS" ]]; then
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    echo "    retiring $(basename "$old")"
    mv -f "$old" "$PRUNE_STAGE"/
  done <<< "$OLD_ZIPS"
else
  echo "    no archives to retire"
fi
# generate_appcast writes binary .delta files alongside the zips and RETAIN_RELEASES never
# bounded them, so they accumulated forever on the internal disk TCC confines this feed to.
# Clearing them makes the directory a pure function of the retained zips; generate_appcast
# rebuilds the deltas it still wants on this run.
DELTAS="$( { ls -1 "$PUBLISH_DIR"/*.delta 2>/dev/null || true; } )"
if [[ -n "$DELTAS" ]]; then
  echo "    clearing $(wc -l <<< "$DELTAS" | tr -d ' ') stale delta file(s)"
  rm -f "$PUBLISH_DIR"/*.delta
fi

echo "==> Signing appcast"
"$GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$SPARKLE_FEED_URL" \
  "$PUBLISH_DIR"

[[ -f "$PUBLISH_DIR/appcast.xml" ]] || fail "no appcast.xml produced in $PUBLISH_DIR"

# Bind every assertion to THIS release's <item>. A file-wide grep for sparkle:edSignature=
# passes as long as any retained older item is signed, so an unsigned new item would publish
# and every client would reject it silently. Splitting on </item> keeps this correct whether
# generate_appcast pretty-prints or minifies.
awk -v build="$APP_BUILD" -v zip="$RELEASE_ZIP" '
  BEGIN { RS = "</item>" }
  $0 ~ ("<sparkle:version>" build "</sparkle:version>") {
    seen = 1
    if ($0 ~ /sparkle:edSignature="/) signed = 1
    if (index($0, zip)) enclosed = 1
  }
  END {
    if (!seen)     { print "missing";   exit 1 }
    if (!signed)   { print "unsigned";  exit 2 }
    if (!enclosed) { print "unenclosed"; exit 3 }
  }
' "$PUBLISH_DIR/appcast.xml" > /dev/null || case $? in
  1) fail "appcast.xml has no item for build $APP_BUILD" ;;
  2) fail "the item for build $APP_BUILD carries no EdDSA signature; clients would reject it" ;;
  3) fail "the item for build $APP_BUILD does not enclose $RELEASE_ZIP" ;;
  *) fail "could not verify the appcast item for build $APP_BUILD" ;;
esac

# Nothing below may fail: the trap treats an unset flag as a reason to restore staged archives.
PUBLISHED_OK=1

echo "==> Published"
echo "    version:  $APP_VERSION (build $APP_BUILD)"
echo "    feed:     $SPARKLE_FEED_URL"
echo "    dir:      $PUBLISH_DIR"
ls -1 "$PUBLISH_DIR"
