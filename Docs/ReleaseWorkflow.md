# CI & Release Workflow Activation

The complete GitHub Actions workflows ship in this repository at:

- `Support/workflows/ci.yml` — build (Debug + Release, unsigned), tests, structural validation
- `Support/workflows/release.yml` — Developer ID signing, hardened runtime, notarization, stapling, Gatekeeper verification, Sparkle EdDSA appcast generation and GitHub Release publishing

## Why they are not active yet

The automated push credential used during development (GitHub App integration)
is **not permitted to write `.github/workflows/`** files — GitHub rejects such
pushes with `403 Resource not accessible by integration`. Rather than silently
dropping CI, the workflows are committed under `Support/workflows/` and a
ready-to-use copy is included in the project ZIP.

## Activation (one step, no content changes)

Copy the two files into the workflows directory and push with an account or
token that has the `workflows` write permission (repository owner or a PAT
with `workflow` scope):

```bash
mkdir -p .github/workflows
cp Support/workflows/ci.yml .github/workflows/ci.yml
cp Support/workflows/release.yml .github/workflows/release.yml
git add .github/workflows
git commit -m "ci: enable GitHub Actions workflows"
git push origin main
```

The `ci.yml` workflow runs on every push/pull request. The `release.yml`
workflow triggers on `v*` tags and **fails loudly** until the signing secrets
listed in `Docs/SparkleSetup.md` are configured.

## Secrets required for releases

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_CERTIFICATE` | base64 of the Developer ID Application `.p12` |
| `CERTIFICATE_PASSWORD` | `.p12` password |
| `APPLE_ID` | Apple ID for `notarytool` |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `notarytool` |
| `APPLE_TEAM_ID` | Team ID for `notarytool` |
| `SPARKLE_ED25519_PRIVATE_KEY` | base64 of the Sparkle Ed25519 private key |
