# SalmanMacCleaner v1.1.6 Verification

Date: 2026-08-26

## Fix verified

- Fixed the Large & Old Files folder-picker stuck state.
- The picker now dismisses explicitly from the parent view on both Cancel and folder selection.
- The picker view also dismisses itself after either action, covering both presentation paths.
- No cleanup or deletion was executed during verification.

## Build and tests

- Xcode build: passed
- Full XCTest suite: 147 passed, 0 failed, 0 skipped
- Configuration: Debug, macOS destination, Apple Silicon Mac
- Installed version: 1.1.6 (build 6)
- Code signing: ad-hoc signature applied and verified locally

## Safety

- Existing installed build was moved to `~/.Trash/SalmanMacCleaner-v1.1.6-old.app` so it remains recoverable.
- The app remains preview-first; file removal still requires explicit user selection and confirmation.
