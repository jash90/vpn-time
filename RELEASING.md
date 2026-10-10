# Releasing VPN Time

Releases are built, signed, notarised and published from a Mac with one command.
There is no hosted CI or release workflow for this repo (the only workflow,
`pullfrog.yml`, is the review bot), so nothing here costs GitHub Actions minutes.

```bash
scripts/bump-version.sh 1.5.0      # writes bundle/Info.plist, commits "chore: release 1.5.0"
git push origin main               # via a PR if main is protected
scripts/release.sh --dry-run       # full pipeline without tagging or publishing
scripts/release.sh                 # the real release
```

## One-time machine setup

1. **Xcode command line tools** with Swift 6 (`xcode-select --install`), plus
   `gh` logged in to GitHub (`gh auth login`). Optional: `shellcheck`
   (`brew install shellcheck`), which `scripts/ci.sh` runs when present.
2. **Developer ID Application certificate** of team `H2X8YGN869` in the login
   keychain. Check with `security find-identity -v -p codesigning`.
   Two certificates with the same name exist, so always sign by SHA-1, never by name.
3. **`~/.config/local-release/apple.env`**, sourced by the scripts:

   ```bash
   APPLE_ID=you@example.com
   APPLE_TEAM_ID=H2X8YGN869
   APPLE_SIGNING_IDENTITY=<SHA-1 of the Developer ID Application certificate>
   NOTARY_PROFILE=local-release
   ```

   Variables you export yourself take precedence over the file.
4. **notarytool keychain profile** (stores the app-specific password in the keychain):

   ```bash
   xcrun notarytool store-credentials local-release \
     --apple-id <apple-id> --team-id H2X8YGN869 --password <app-specific-password>
   ```

   The older `vpn-time` profile is still accepted as a fallback.
5. Optional: run the local CI before every push:

   ```bash
   git config core.hooksPath .githooks   # .githooks/pre-push runs scripts/ci.sh
   ```

## The scripts

| Script | What it does |
|---|---|
| `scripts/ci.sh` | `bash -n` and `shellcheck` on every shell script, version consistency check, `test/run-tests.sh` (Swift unit tests + shell tests), `swift build -c release`. |
| `scripts/bump-version.sh X.Y.Z` | Sets `CFBundleShortVersionString` and `CFBundleVersion` in `bundle/Info.plist`, verifies they agree, commits `chore: release X.Y.Z`. Does not tag or push. `--check` only verifies and prints the version. |
| `scripts/release.sh` | The release pipeline below. `--dry-run`, `--draft`, `--skip-ci`, `--notes FILE`, `--tag vX.Y.Z`; see `--help`. |
| `build.sh` | `swift build -c release`, assembles `build/VPN Time.app`, signs it (Developer ID with hardened runtime, or ad-hoc when no certificate is available). Used by `install.sh` for local installs too. |
| `release.sh` (root) | Backward-compatible wrapper: `./release.sh vX.Y.Z [notes-file]` calls `scripts/release.sh --tag vX.Y.Z --notes notes-file`. |

### What `scripts/release.sh` does

1. **Preflight**: required tools present; `bundle/Info.plist` versions agree;
   the working tree is clean; on `main` and equal to `origin/main`; tag `vX.Y.Z`
   exists neither locally nor on `origin`; the signing identity is a valid
   Developer ID Application certificate of team `H2X8YGN869`; a notarytool
   profile works; `gh` is logged in; at least 2 GB of free disk.
   With `--dry-run` the clean-tree, branch and existing-tag checks only warn.
2. **CI**: `scripts/ci.sh` (skip with `--skip-ci`).
3. **Build and sign**: `build.sh` with the identity from `APPLE_SIGNING_IDENTITY`.
4. **Notarise**: zips the bundle with `ditto` and runs
   `xcrun notarytool submit --keychain-profile "$NOTARY_PROFILE" --wait`; the
   log is kept in `build/notarytool.log`.
5. **Staple** the ticket to the app.
6. **Verify**: `codesign --verify --deep --strict`, `spctl -a -vv -t execute`
   (must say `source=Notarized Developer ID`), `xcrun stapler validate`,
   `TeamIdentifier=H2X8YGN869`, and the bundle version equals the tag.
7. **Artifacts**: re-zips the stapled app as `VPN-Time-vX.Y.Z.zip` and copies it
   with `SHA256SUMS` and the notary log into `dist/release/vX.Y.Z/` (gitignored).
8. **Publish** (skipped by `--dry-run`): creates an annotated tag, pushes it,
   creates the GitHub release as a draft, uploads the zip, then publishes it as
   non-draft and latest (`--draft` leaves it a draft). Finally it checks that the
   asset digest GitHub reports matches the local SHA-256.

### Constraints from the in-app updater

The updater (`Sources/VPNTime/Updater.swift`, `Sources/VPNTimeCore/Update.swift`)
polls `api.github.com/repos/jash90/vpn-time/releases/latest`. Therefore:

- The tag must be `v` + `CFBundleShortVersionString`, otherwise the same update
  is offered forever or never.
- The asset must be named exactly `VPN-Time-vX.Y.Z.zip` (`Update.assetName(tag:)`)
  and carry GitHub's `sha256:` digest; releases without it are not installed.
- Drafts are invisible to `releases/latest`; a `--draft` release reaches users
  only after `gh release edit vX.Y.Z --draft=false --latest`.
- The update is rejected unless it is signed by team `H2X8YGN869`.

## Troubleshooting

- **`tag vX.Y.Z already exists`**: bump the version first. If a previous run
  died after creating the tag and a draft release, simply re-run
  `scripts/release.sh`: it re-uploads the asset and publishes the draft.
- **`is not a valid Developer ID Application certificate`**: the SHA-1 in
  `APPLE_SIGNING_IDENTITY` is missing or expired; compare with
  `security find-identity -v -p codesigning`.
- **`no usable notarytool keychain profile`**: recreate it with
  `xcrun notarytool store-credentials` (step 4 above). An expired app-specific
  password also shows up here.
- **Notarisation `Invalid`**: `xcrun notarytool log <submission-id> --keychain-profile local-release`
  shows the offending file. The usual cause is a missing hardened runtime or
  timestamp, which `build.sh` adds when signing with a Developer ID.
- **`spctl` rejects the app**: the ticket is not stapled or the bundle was
  modified after signing; rebuild with `scripts/release.sh --dry-run`.
- **Tunnelblick permission prompt after each local build**: only Developer ID
  signed builds have a stable identity; ad-hoc builds need re-authorising.

## Manual GitHub Actions fallback

There is no release workflow. If this Mac is unavailable, any Mac with the
setup above can run `scripts/release.sh`; the certificate and notary
credentials are the only machine-specific parts.
