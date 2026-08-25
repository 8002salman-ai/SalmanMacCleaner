# Sparkle 2 Update Setup

Salman Mac Cleaner integrates **Sparkle 2** via Swift Package Manager for the
direct-distribution edition. This document explains exactly how to configure
production updates, which secrets are required, and what stays disabled until
they exist.

## How the integration works

- Package: `https://github.com/sparkle-project/Sparkle` (upToNextMajor 2.6.0),
  referenced in `SalmanMacCleaner.xcodeproj/project.pbxproj` (regenerate with
  `Tools/generate_pbxproj.py` after adding files).
- Controller: `Core/SparkleUpdaterController.swift`.
- Feed URL (`SUFeedURL` in `Info.plist`):
  `https://raw.githubusercontent.com/8002salman-ai/SalmanMacCleaner/main/Support/appcast.xml`
- Public EdDSA key (`SUPublicEDKey` in `Info.plist`): placeholder until you
  run the key generation below.
- Menu command: **Salman Mac Cleaner → Check for Updates…** (⌘U).

## Configuration gate

`SparkleUpdaterController.isConfigured` requires:

1. `SUFeedURL` starts with `https://`
2. `SUPublicEDKey` is present and does not contain `REPLACE`
3. The running binary passes the Developer ID signature check
   (`anchor apple generic` requirement)

Until all three hold, the app honestly reports
**"Development build — updates are disabled."** No unsigned update can ever
be installed.

## One-time key generation (local, private key never committed)

```bash
# 1. Download Sparkle (or use the one cached by the release workflow)
curl -fsSL -o sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz
tar -xJf sparkle.tar.xz

# 2. Generate the EdDSA key pair — KEEP THE PRIVATE KEY OFFLINE
./bin/generate_keys
#   private key → Sparkle_private_ed25519.key   (store in GitHub secret)
#   public key  → printed; paste into Info.plist SUPublicEDKey

# 3. Set the public key in SalmanMacCleaner/Info.plist
#    <key>SUPublicEDKey</key><string>PASTE_PUBLIC_KEY_HERE</string>
```

## GitHub Actions secrets (Release workflow)

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_CERTIFICATE` | base64 of the Developer ID Application `.p12` |
| `CERTIFICATE_PASSWORD` | `.p12` password |
| `APPLE_ID` | Apple ID for `notarytool` |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool` |
| `APPLE_TEAM_ID` | Team ID for `notarytool` |
| `SPARKLE_ED25519_PRIVATE_KEY` | base64 of `Sparkle_private_ed25519.key` |

The workflow **fails** (never silently passes) when any secret is missing or
when signing, notarization, stapling, Gatekeeper assessment or appcast
generation fails.

## Releasing a version

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in
   `Tools/generate_pbxproj.py`, regenerate, bump the CHANGELOG.
2. Push a tag: `git tag v1.2.0 && git push origin v1.2.0`.
3. The release workflow builds arm64, signs with hardened runtime, verifies
   nested signatures, notarizes with `notarytool`, staples, runs `spctl`
   verification, generates the signed appcast and pushes it to `main` so the
   stable feed URL updates.

## What must never be committed

- `Sparkle_private_ed25519.key`
- Developer ID `.p12` files or their passwords
- Apple ID passwords / app-specific passwords
- App Store Connect API keys
- GitHub tokens
- Notarization credentials
