# Releasing AIUsageBar on GitHub

GitHub Releases is the distribution channel; App Store and Microsoft Store submission are not required.

## One-time signing setup

For a release that opens without Gatekeeper or SmartScreen warnings, configure repository secrets before pushing a version tag.

### macOS

Join the Apple Developer Program, create a **Developer ID Application** certificate, export it as a password-protected `.p12`, and add:

- `APPLE_CERTIFICATE`: base64-encoded `.p12`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `KEYCHAIN_PASSWORD`: an arbitrary CI keychain password
- `APPLE_ID`
- `APPLE_PASSWORD`: an app-specific password
- `APPLE_TEAM_ID`

The release workflow builds a Universal app, signs it, submits it for notarization, and staples the ticket through Tauri's release tooling.

### Windows

Acquire a trusted Windows code-signing certificate and add:

- `WINDOWS_CERTIFICATE`: base64-encoded `.pfx`
- `WINDOWS_CERTIFICATE_PASSWORD`

The workflow imports the certificate into the runner's current-user store and passes its thumbprint to Tauri. Without these secrets, CI can still create an installer for testing, but browsers and Windows SmartScreen may warn users.

## Create a release

1. Update the version in `desktop/src-tauri/tauri.conf.json`, `desktop/src-tauri/Cargo.toml`, and `desktop/package.json`.
2. Run `cargo test --tests`, `cargo clippy --all-targets -- -D warnings`, and a local macOS build.
3. Commit the version change.
4. Create and push a tag such as `v0.2.0`.
5. Review the draft GitHub Release and its macOS and Windows artifacts before publishing it.

The repository still needs an explicit open-source license selected by the owner before the first public release.
