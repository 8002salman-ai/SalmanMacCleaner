# SalmanMacCleaner v1.1.4 Test Report

Date: 2026-08-26
Machine: MacBook Air, Apple Silicon, macOS 26.6.2

## Automated verification

- Xcode test suite: **147 passed, 0 failed, 0 skipped**
- Build: Debug macOS app completed successfully
- Version: `1.1.4` build `4`

## Live application verification

- Installed path: `~/Applications/SalmanMacCleaner.app`
- Full Disk Access: **Granted**
- Smart Care: read-only health check completed
- Storage pressure: 81.83 GB available
- Applications inventoried: 119
- Trash detected: 9,091 items / 5.89 GB (not emptied)
- Developer-cache candidates: 0 currently measured
- Broken background items: 5 (reported only; nothing disabled)
- Scan behavior: no cleanup action is triggered by Health Check

## Safety verification

- Cleanup remains preview-first and moves selected items to Trash only.
- Protected files, app bundles, personal locations, symlinks, and unsafe volumes remain guarded.
- Folder cleanup is blocked when scanned protected descendants are present.
- Old v1.1.3 was moved to Trash as a recoverable backup before installing v1.1.4.

## Notes

The live health report still identifies five broken background items for review. This is a finding on the Mac, not an automatic repair; the app correctly leaves startup items unchanged.
