#!/bin/bash
# Builds, signs, notarises, verifies and publishes a GitHub release of VPN Time.
# Everything runs on this Mac; there is no hosted release workflow.
#
# See RELEASING.md for the one-time machine setup and troubleshooting.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="VPN Time"
TEAM_ID_EXPECTED="H2X8YGN869"
LOCAL_RELEASE_ENV="${LOCAL_RELEASE_ENV:-$HOME/.config/local-release/apple.env}"
MIN_FREE_GB=2

log() { printf '\n== %s ==\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf 'release: warning: %s\n' "$*" >&2; }
die() { printf 'release: error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh [--dry-run] [--draft] [--skip-ci] [--notes FILE] [--tag vX.Y.Z]

Releases the version in bundle/Info.plist as tag vX.Y.Z.

  --dry-run     do everything up to and including notarisation, stapling,
                verification and dist/release/vX.Y.Z/, but do not tag, push or
                touch GitHub. Branch/clean-tree checks only warn.
  --draft       publish the GitHub release as a draft. The in-app updater
                ignores drafts, so users are not offered it until it is published.
  --skip-ci     do not run scripts/ci.sh first.
  --notes FILE  release notes file (default: GitHub generated notes).
  --tag vX.Y.Z  assert the tag; it must equal v + CFBundleShortVersionString.
  -h, --help    this help.

Environment (defaults come from ~/.config/local-release/apple.env):
  APPLE_SIGNING_IDENTITY  SHA-1 of the Developer ID Application certificate
  NOTARY_PROFILE          notarytool keychain profile (local-release, falls back to vpn-time)
  VPNTIME_SIGN_IDENTITY   overrides APPLE_SIGNING_IDENTITY for build.sh

Steps: preflight -> ci.sh -> build.sh (sign) -> notarise -> staple -> verify ->
zip (VPN-Time-vX.Y.Z.zip, the asset name the updater expects) -> dist/release/vX.Y.Z/
-> tag + push tag -> gh release create, upload, publish as latest.
Re-running for a tag whose GitHub release is still a draft re-uploads the
asset and publishes it.
USAGE
}

DRY_RUN=0
DRAFT=0
SKIP_CI=0
NOTES=""
TAG_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --draft) DRAFT=1 ;;
    --skip-ci) SKIP_CI=1 ;;
    --notes) NOTES="${2:?--notes needs a file}"; shift ;;
    --tag) TAG_ARG="${2:?--tag needs vX.Y.Z}"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

cd "$ROOT"

# ---------------------------------------------------------------- environment
# Keep values the caller exported; fill the rest from apple.env.
if [ -f "$LOCAL_RELEASE_ENV" ]; then
  _identity="${APPLE_SIGNING_IDENTITY:-}"
  _profile="${NOTARY_PROFILE:-}"
  _team="${APPLE_TEAM_ID:-}"
  # shellcheck disable=SC1090
  . "$LOCAL_RELEASE_ENV"
  APPLE_SIGNING_IDENTITY="${_identity:-${APPLE_SIGNING_IDENTITY:-}}"
  NOTARY_PROFILE="${_profile:-${NOTARY_PROFILE:-}}"
  APPLE_TEAM_ID="${_team:-${APPLE_TEAM_ID:-}}"
fi
export APPLE_SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
TEAM_ID="${APPLE_TEAM_ID:-$TEAM_ID_EXPECTED}"
[ "$TEAM_ID" = "$TEAM_ID_EXPECTED" ] \
  || die "APPLE_TEAM_ID=$TEAM_ID, but the updater only accepts team $TEAM_ID_EXPECTED"

# ---------------------------------------------------------------- preflight
log "preflight"

for tool in swift codesign xcrun ditto spctl git shasum plutil /usr/libexec/PlistBuddy; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool missing: $tool"
done
[ "$DRY_RUN" -eq 1 ] || command -v gh >/dev/null 2>&1 || die "required tool missing: gh"

VERSION="$("$ROOT/scripts/bump-version.sh" --check)" || die "version files disagree"
TAG="v$VERSION"
if [ -n "$TAG_ARG" ] && [ "$TAG_ARG" != "$TAG" ]; then
  # The in-app updater compares the release tag with the bundle version; a
  # mismatch would offer the same release forever or never offer it at all.
  die "tag $TAG_ARG does not match CFBundleShortVersionString $VERSION in bundle/Info.plist"
fi
info "version: $VERSION (tag $TAG)"

# strict: fatal for a real release, a warning for --dry-run.
strict() {
  if [ "$DRY_RUN" -eq 1 ]; then warn "$* (ignored for --dry-run)"; else die "$*"; fi
}

[ -z "$(git status --porcelain)" ] || strict "working tree is not clean"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || strict "on branch '$BRANCH', releases are cut from main"
git fetch -q origin main --tags || strict "git fetch origin failed"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main 2>/dev/null || echo none)" ] \
  || strict "HEAD is not equal to origin/main"

RESUME_DRAFT=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  || git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  # The only accepted case: a previous run created the tag and a draft release.
  if [ "$DRY_RUN" -eq 0 ] \
    && [ "$(gh release view "$TAG" --json isDraft --jq .isDraft 2>/dev/null || true)" = "true" ]; then
    RESUME_DRAFT=1
    info "tag $TAG exists with a draft release: re-uploading and publishing it"
    [ "$(git rev-list -n1 "$TAG" 2>/dev/null || true)" = "$(git rev-parse HEAD)" ] \
      || die "tag $TAG does not point at HEAD"
  else
    strict "tag $TAG already exists (bump the version with scripts/bump-version.sh)"
  fi
fi

# Signing identity: must be a valid Developer ID Application certificate.
IDENTITIES="$(security find-identity -v -p codesigning)"
if [ -n "${VPNTIME_SIGN_IDENTITY:-}" ]; then
  SIGN_ID="$VPNTIME_SIGN_IDENTITY"
elif [ -n "$APPLE_SIGNING_IDENTITY" ]; then
  SIGN_ID="$APPLE_SIGNING_IDENTITY"
else
  die "no signing identity: set APPLE_SIGNING_IDENTITY (see RELEASING.md)"
fi
grep -q "$SIGN_ID \"Developer ID Application:.*($TEAM_ID)\"" <<<"$IDENTITIES" \
  || die "signing identity $SIGN_ID is not a valid Developer ID Application certificate of team $TEAM_ID"
export VPNTIME_SIGN_IDENTITY="$SIGN_ID"
info "signing identity: $SIGN_ID"

# Notary profile: the configured one, falling back to the legacy vpn-time profile.
PROFILE=""
for candidate in "${NOTARY_PROFILE:-local-release}" vpn-time; do
  if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
    PROFILE="$candidate"
    break
  fi
done
[ -n "$PROFILE" ] || die "no usable notarytool keychain profile (tried ${NOTARY_PROFILE:-local-release}, vpn-time)"
info "notary profile: $PROFILE"

if [ "$DRY_RUN" -eq 0 ]; then
  gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth login)"
fi
[ -z "$NOTES" ] || [ -f "$NOTES" ] || die "notes file not found: $NOTES"

FREE_GB="$(df -g "$ROOT" | awk 'NR==2 {print $4}')"
[ "${FREE_GB:-0}" -ge "$MIN_FREE_GB" ] || die "only ${FREE_GB} GB free, need $MIN_FREE_GB GB"

# ---------------------------------------------------------------- ci
if [ "$SKIP_CI" -eq 1 ]; then
  log "ci (skipped)"
else
  log "ci"
  "$ROOT/scripts/ci.sh"
fi

# ---------------------------------------------------------------- build + sign
log "build and sign"
"$ROOT/build.sh"

APP="$ROOT/build/$APP_NAME.app"
ASSET="VPN-Time-$TAG.zip"   # must match Update.assetName(tag:) in VPNTimeCore
ZIP="$ROOT/build/$ASSET"
DIST="$ROOT/dist/release/$TAG"

# Read the signature into a variable first: with pipefail, `codesign | grep -q`
# can fail when grep exits early and codesign is killed by SIGPIPE.
SIGNATURE="$(codesign -dv "$APP" 2>&1 || true)"
[[ "$SIGNATURE" == *"TeamIdentifier=$TEAM_ID"* ]] \
  || die "bundle is not Developer ID signed by $TEAM_ID, notarisation would be rejected"

# ---------------------------------------------------------------- notarise + staple
log "notarise"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait \
  | tee "$ROOT/build/notarytool.log"
grep -q 'status: Accepted' "$ROOT/build/notarytool.log" \
  || die "notarisation was not accepted (see build/notarytool.log, then: xcrun notarytool log <id> --keychain-profile $PROFILE)"

log "staple"
xcrun stapler staple "$APP"

# ---------------------------------------------------------------- verify
log "verify"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vv -t execute "$APP"
xcrun stapler validate "$APP"
SIGNATURE="$(codesign -dv "$APP" 2>&1 || true)"
[[ "$SIGNATURE" == *"TeamIdentifier=$TEAM_ID"* ]] || die "TeamIdentifier check failed after stapling"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUNDLE_VERSION" = "$VERSION" ] || die "built bundle reports $BUNDLE_VERSION, expected $VERSION"
info "signature, Gatekeeper, staple and team all verified"

# ---------------------------------------------------------------- artifacts
log "artifacts"
# Re-zip so the published archive carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$DIST"
mkdir -p "$DIST"
cp "$ZIP" "$DIST/$ASSET"
(cd "$DIST" && shasum -a 256 "$ASSET" > SHA256SUMS)
cp "$ROOT/build/notarytool.log" "$DIST/"
info "$DIST/$ASSET"
info "sha256 $(cut -d' ' -f1 "$DIST/SHA256SUMS")"

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry run complete: nothing tagged or published"
  exit 0
fi

# ---------------------------------------------------------------- publish
log "publish $TAG"
if [ "$RESUME_DRAFT" -eq 0 ]; then
  git tag -a "$TAG" -m "$APP_NAME $TAG"
  git push origin "refs/tags/$TAG"

  notes_args=(--generate-notes)
  [ -z "$NOTES" ] || notes_args=(--notes-file "$NOTES")
  # Created as a draft first so a failed upload never leaves a published
  # release without its asset; published below.
  gh release create "$TAG" --verify-tag --draft --title "$APP_NAME $TAG" "${notes_args[@]}"
fi

gh release upload "$TAG" "$DIST/$ASSET" --clobber

if [ "$DRAFT" -eq 1 ]; then
  info "left as a draft: the in-app updater ignores it until it is published"
  info "publish later with: gh release edit $TAG --draft=false --latest"
else
  # The in-app updater reads releases/latest, which never returns drafts.
  gh release edit "$TAG" --draft=false --latest
fi

# GitHub computes the asset digest the updater verifies; make sure it matches.
REMOTE_DIGEST="$(gh release view "$TAG" --json assets \
  --jq ".assets[] | select(.name == \"$ASSET\") | .digest" 2>/dev/null || true)"
LOCAL_DIGEST="sha256:$(cut -d' ' -f1 "$DIST/SHA256SUMS")"
if [ -n "$REMOTE_DIGEST" ] && [ "$REMOTE_DIGEST" != "null" ] && [ "$REMOTE_DIGEST" != "$LOCAL_DIGEST" ]; then
  die "uploaded asset digest $REMOTE_DIGEST does not match $LOCAL_DIGEST"
fi

log "released $TAG"
gh release view "$TAG" --json url --jq .url
