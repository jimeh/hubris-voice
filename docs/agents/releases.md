# Releases

Hubris Voice uses Release Please to maintain one release pull request on
`main`. Merging that pull request creates a `v<version>` tag and a draft GitHub
Release. The outer workflow then dispatches the protected release workflow at
the exact tag. This separate dispatch is required so the release job receives
its GitHub Environment secrets. There is no independent tag trigger.

The release workflow builds an arm64 and x86_64 executable, combines them into
a universal app, embeds the pinned Sparkle framework, signs every retained code
object with Developer ID and hardened runtime, and notarizes and staples the
application. It publishes a ZIP used by Sparkle, a signed and separately
notarized DMG, an SPDX 2.3 SBOM, the signed `appcast.xml`, and `SHA256SUMS`.

GitHub build-provenance and SBOM attestations cover both distributable archives.
Publishing is the final operation. With repository release immutability enabled,
GitHub locks the tag and asset bytes and creates its release attestation when
the draft becomes public.

## Repository configuration

Install the release bot GitHub App on `jimeh/hubris-voice` with read/write
access to Contents, Issues, and Pull requests.

Add these GitHub Actions repository variables:

- `RELEASE_BOT_CLIENT_ID`: client ID of the installed GitHub App.
- `APPLE_TEAM_ID`: ten-character Apple Developer team ID.
- `APPLE_NOTARIZATION_KEY_ID`: ten-character App Store Connect API key ID.
- `APPLE_NOTARIZATION_ISSUER_ID`: App Store Connect API issuer UUID.

Add this repository secret:

- `RELEASE_BOT_PRIVATE_KEY`: PEM private key downloaded for the GitHub App.

Create a protected GitHub Environment named `release`. Initially require a
reviewer and allow deployments only from `main` and tags matching `v*`. Add
these environment secrets:

- `MACOS_DEVELOPER_ID_APPLICATION_P12_BASE64`: base64-encoded Developer ID
  Application PKCS#12 file.
- `MACOS_DEVELOPER_ID_APPLICATION_P12_PASSWORD`: password for the PKCS#12 file.
- `APPLE_NOTARIZATION_KEY_P8_BASE64`: base64-encoded App Store Connect API `.p8`
  file.
- `SPARKLE_EDDSA_PRIVATE_KEY`: exported Sparkle private key used to sign the ZIP
  enclosure and appcast feed.

The Apple credentials and release bot can be shared with Huterm after the bot
is installed on this repository. The Developer ID certificate must belong to
`APPLE_TEAM_ID`. The App Store Connect key must match the configured key and
issuer IDs and have permission to submit notarization requests.

Enable release immutability under the repository's Releases settings before
the first public release. Immutability applies only to releases published after
the setting is enabled.

## Sparkle signing authority

Prepare the pinned Sparkle tools and generate the production key on a trusted
Mac:

```sh
mise run sparkle:prepare
.native/sparkle/distribution/bin/generate_keys --account hubris-voice
.native/sparkle/distribution/bin/generate_keys --account hubris-voice -p
sparkle_key_dir="$(mktemp -d)"
.native/sparkle/distribution/bin/generate_keys --account hubris-voice \
  -x "$sparkle_key_dir/hubris-voice-sparkle-private-key"
```

Save the `-p` output as `Support/SparklePublicKey` and commit it. Store the exact
exported private-key contents as the `SPARKLE_EDDSA_PRIVATE_KEY` environment
secret, then keep an encrypted offline recovery copy and delete the transient
export.

The public key is application identity. The private key grants update
authority. Rotate it only by shipping a replacement public key in an update
signed by the existing key. Losing the private key without a recovery copy
requires manual distribution of a new Developer ID signed application.

Ordinary `mise run bundle` output remains Sparkle-free. The release path fails
closed when the committed production public key is absent or malformed.

## Release path

1. Release Please updates the release PR from Conventional Commits and keeps
   `CHANGELOG.md`, both `Info.plist` versions, and the release manifest aligned.
2. Merging the release PR creates the exact tag and draft GitHub Release.
3. The outer workflow dispatches `release.yml` at the exact release tag. Calling
   it as a reusable workflow does not reliably expose the `release` environment's
   secrets. The self-contained `Release` run reports its outcome independently.
4. The protected macOS job validates the workflow SHA and draft identity before
   exposing release credentials. The Swift release tool validates every signing
   credential before downloading Sparkle or building either architecture.
5. `mise run release:macos` prepares the verified Sparkle distribution, builds
   both architectures, signs and notarizes the app, then produces the final ZIP,
   DMG, SBOM, and preliminary checksums.
6. `mise run release:appcast` supplies the production Sparkle key only to the
   appcast tools. It first proves the private key matches the public key embedded
   in the app, then signs and verifies the ZIP enclosure and feed and rewrites
   the final checksum inventory.
7. The workflow uploads exactly the five expected assets to the draft and
   compares GitHub's SHA-256 asset digests with the local files.
8. GitHub Actions issues and locally verifies build-provenance and SPDX SBOM
   attestations for the ZIP and DMG.
9. The workflow publishes the verified draft and requires GitHub to report the
   resulting release as immutable.

The public asset set is:

```text
Hubris-Voice-<version>-macOS-universal.zip
Hubris-Voice-<version>-macOS-universal.dmg
Hubris-Voice-<version>-macOS-universal.spdx.json
appcast.xml
SHA256SUMS
```

The ZIP is Sparkle's update enclosure. The DMG contains the same stapled app and
an Applications shortcut, but is not included in the appcast.

Any failure before publication leaves the GitHub Release as a mutable draft.
Reruns may replace only the expected draft assets and reject any unexpected
asset. The final ZIP is created after stapling the app. The DMG is signed,
submitted as a separate notarization request, and stapled before publication.

The `release:*` Mise tasks execute the SwiftPM package in `Tools/ReleaseTool`.
It owns release configuration parsing, subprocess execution, packaging, signing,
notarization, appcast validation, and GitHub Release inventory checks. Small
bootstrap and Sparkle acquisition scripts remain in `Scripts`.

## Manual verification

Run the `Release` workflow manually with `publish` unchecked. Select the branch
to verify and enter its exact 40-character HEAD SHA plus the matching version;
leave the tag empty. This performs real Developer ID signing, two notarization
submissions, stapling, Gatekeeper assessment, universal-architecture checks,
SPDX validation, release-bot token creation, and signed Sparkle appcast
generation. A missing tag defaults to `v<version>` for the appcast's hypothetical
release URLs. The workflow uploads all five candidate assets as a seven-day
Actions artifact but does not inspect or modify a GitHub Release or create
GitHub attestations.

Download the candidate and manually verify microphone, Accessibility, Input
Monitoring, global shortcuts, Keychain access, launch at login, update checks,
and dictation before the first public release.

## Manual recovery

To recover an existing draft, run the `Release` workflow with `publish` checked
and select that release's exact `v`-prefixed tag as the workflow ref. Enter the
tag's exact 40-character commit SHA, tag, and version. The workflow rebuilds and
revalidates the artifacts, replaces only the expected draft assets, and refuses
to publish a mismatched or already-public release.

A manual dispatch of the outer `Release Please` workflow runs from a branch and
cannot publish. Use the exact-tag recovery path if such a dispatch creates a tag
and draft release.
