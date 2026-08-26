# SalmanMacCleaner v1.1.7 Verification

Date: 2026-08-26

## Duplicate Finder fix

- Fixed the blank Duplicate Finder state when cache folders are absent.
- Default scan roots now include existing user folders: Desktop, Documents,
  Downloads, Pictures, Movies, and Music.
- Duplicate scanning remains explicit: the user must press Scan.
- Folder selection and cleanup remain preview-first and confirmation-based.

## Verification

- Full XCTest suite: passed with no test failures.
- Added regression coverage for the visible default duplicate folders.
- Xcode build: passed on Apple Silicon macOS.
- Installed version: 1.1.7 (build 7).
- Ad-hoc code signature: verified locally.

## Safety

- No cleanup or file deletion was executed during verification.
- The previous installed build was moved recoverably to
  `~/.Trash/SalmanMacCleaner-v1.1.7-old.app`.
