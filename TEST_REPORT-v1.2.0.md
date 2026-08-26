# 8002CleanUp v1.2.0 Verification Report

Date: 2026-08-26
Product rename: **Salman Mac Cleaner → 8002CleanUp**
Version: **1.2.0 (build 8)** — next release after the previously installed 1.1.7 (7)

---

## 1. Scope

This pass continued from the latest remote code on `arena/01a03a86-salmanmaccleaner`
(commit `226b9da`, "fix: populate duplicate finder roots", which already contains
the v1.1.4–v1.1.7 module repairs: duplicate pipeline, large-file picker,
developer caches, Space Lens, health check, cleanup reconciliation, tests).
All work was performed on the session branch
`arena/01a03de8-salmanmaccleaner`, which was fast-forwarded to `226b9da`
(latest remote work) before editing, so **no older baseline** was used.

## 2. Product rename + version (done)

- `Info.plist`: `CFBundleName` and `CFBundleDisplayName` → **8002CleanUp**.
- `project.pbxproj`: `MARKETING_VERSION = 1.2.0`, `CURRENT_PROJECT_VERSION = 8`
  (app + test configs). `Tools/generate_pbxproj.py` constants synced to 1.2.0/8.
- New `Core/AppIdentity.swift` — single source of truth for
  `displayName`, `shortVersion`, `buildNumber`, `versionBadge`, `helpText`;
  used by the toolbar version badge, the new sidebar identity header and the
  About screen.
- Sidebar now shows **8002CleanUp + v1.2.0 (8)** in a compact glass header at
  the top (icon, name, badge, Reduce Motion-aware glow).
- About screen, updater copy, menu help title, security/health copy and all
  localization keys updated to 8002CleanUp; README, CHANGELOG, Docs, SECURITY,
  FILE_MANIFEST updated.
- Internal identifiers intentionally unchanged: repository name, Xcode target
  `SalmanMacCleaner`, bundle id `com.salman.SalmanMacCleaner`, Sparkle feed URL,
  support paths — so signed feeds, saved bookmarks and historical data keep
  working. Restarting/reinstalling via the existing distribution flow shows the
  new visible name.

## 3. Duplicate Finder audit — remaining gaps fixed

Verified from code (all pre-existing requirements intact):
- Roots: Desktop/Documents/Downloads/Pictures/Movies/Music (existing only) +
  Choose Folder + Choose External Folder; **no auto-scan** (Scan button only).
- Exact-content hashing (size group → sample → full streaming SHA-256),
  hard-link identity groups, symlink-safe bounded traversal, no automatic
  keeper selection, preview → confirmation → Trash-only move.

Fixed in this pass:
- **Modified dates**: the scanner now collects `.contentModificationDateKey`;
  every reported copy and the keeper show the measured modified date.
- **Files/bytes scanned + elapsed + cancelling**: live throttled counters
  (files, bytes, elapsed `m:ss`), current phase, Cancel Scan button; Retry
  button on error/partial coverage.
- **Sorting**: sort menu (reclaimable space, file size, copies, path).
- **Select All / Deselect All**: functional; Select All never selects keepers
  (tested).
- Coverage summary now includes considered bytes.

## 4. Large & Old Files audit — remaining gaps fixed

Verified from code: explicit folder picker (dismiss on Cancel/selection),
custom folders, real size/date rows, checkbox selection, preview-first Trash.

Fixed in this pass:
- Live progress: entries visited, bytes found, elapsed time.
- Sort menu: largest, smallest, newest modified, oldest modified, name
  (deterministic, unit-tested).
- "Scan This Folder" retry action.

## 5. Other module audit (static, against the requirement list)

| Module | Status |
| --- | --- |
| Deep Scan / Smart Care | Real traversal, coverage/denied counters, bounded tasks, read-only Health Check (no auto clean/uninstall/update/disable). No changes needed. |
| System Junk / Developer Caches | Real paths/sizes; category chooser with only detected categories; not-scanned/empty/denied states. No changes needed. |
| App Leftovers / Applications / Uninstaller | /Applications, /System/Applications, ~/Applications; bundle metadata, classification, protected Apple/running/self; preview+confirmation. No changes needed. |
| App Updater | Sparkle-only for self, honest unconfigured state, signature/notarization gates, no fabricated third-party data. No changes needed. |
| Space Lens | Explicit Not Scanned/Scanning/Partial/Denied/Measured states, measured sizes, bounded compact layout (fixed in earlier commits). No changes needed. |
| Startup/Trash/History/Permissions | Read-only by default, real items, Trash-only, exact history, FDA states + inaccessible list. No changes needed. |

## 6. Regression tests added

- `AppIdentityTests.swift` — visible name constant, bundle/display name,
  version == 1.2.0/build 8, badge format, strict version bump over 1.1.7
  (bundle assertions skip cleanly when not hosted in the app).
- `DuplicateFinderTests.swift` (extended) — modified dates + considered bytes,
  live stats callback, symlinks never followed/reported, default roots are the
  six visible user folders, no auto-selection/no auto-scan, sorting +
  Select All/Deselect All (keeper never selected).
- `LargeOldFilesRegressionTests.swift` — all five sort orders, tie stability,
  elapsed formatting.

## 7. Verification run — honest status

Executed in this sandbox (Linux, no macOS GUI):
- ✅ `git status` / branch / latest commit inspection.
- ✅ `git diff --check` — clean.
- ✅ `plistlib` parse of `Info.plist` — `8002CleanUp`, `$(MARKETING_VERSION)`.
- ✅ `Localizable.strings` — no duplicate keys (1033 keys).
- ✅ Balance/integrity checks on `project.pbxproj` and every changed Swift file.
- ✅ Static review of all 20 modules for blank/stuck/zero-KB states.

**Blockers (exact):**
- This sandbox has no Xcode, no Swift toolchain and no macOS (`xcodebuild`
  and `swift` are not installed; host is Linux x86_64). The full XCTest suite,
  `swift build` / `xcodebuild` and manual per-module UI checks **could not be
  executed here**.
- The last verified suite run on macOS (per repo reports) was 147 tests, 0
  failures at v1.1.6; the v1.1.7 report states a passing suite on Apple Silicon.
  The new tests (3 files, ~16 new test methods) must be run on a macOS host
  before release — command:
  `xcodebuild test -project SalmanMacCleaner.xcodeproj -scheme SalmanMacCleaner -destination 'platform=macOS'`

No cleanup, no Trash move, no sudo and no system modification was performed
during this pass by the tooling (no macOS available); all destructive paths
remain preview-first and Trash-only in code.

## 8. Files changed

```
CHANGELOG.md, README.md, SECURITY.md, Docs/{Distribution,SparkleSetup}.md,
FILE_MANIFEST.md
SalmanMacCleaner.xcodeproj/project.pbxproj (version + 3 new source refs)
SalmanMacCleaner/Info.plist
SalmanMacCleaner/Core/AppIdentity.swift (new)
SalmanMacCleaner/UI/{ContentView,SidebarView,SettingsView}.swift
SalmanMacCleaner/Features/Duplicates/{DuplicateFinder,DuplicatesView,DuplicatesViewModel}.swift
SalmanMacCleaner/Features/LargeOldFilesView.swift
SalmanMacCleaner/en.lproj/Localizable.strings
SalmanMacCleanerTests/{AppIdentityTests,LargeOldFilesRegressionTests}.swift (new)
SalmanMacCleanerTests/DuplicateFinderTests.swift
Tools/generate_pbxproj.py
```
