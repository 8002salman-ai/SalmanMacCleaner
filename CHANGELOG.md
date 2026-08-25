# Changelog

All notable changes to Salman Mac Cleaner are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-08-25

### Fixed

- **Cleanup workflow (Preview Mode wording, real Trash moves, exact counts).**
  - Preview Mode no longer offers "Move to Trash": the action is
    "Preview Selected" and the dialog confirms with "Confirm Preview".
    Preview never reaches the Trash API (asserted by a mock mover test).
  - A real run is labelled "Move Selected to Trash", revalidates every
    item and moves it with `FileManager.trashItem(at:resultingItemURL:)`.
    Nothing is permanently deleted and the Trash is never emptied.
  - The uninstaller's confirmation dialog was never attached, so its
    `performCleanup()` was unreachable; it is now wired, and a selected
    removable app moves through a narrow authorized-root grant (the
    bundle path itself) while system apps, running apps, other users'
    files and preferences are refused with an exact reason.
  - Counts, bytes, banners and history are now exact and self-reconciling:
    `selected == moved + previewed + failed + skipped + notProcessed`,
    with per-item skip/failure reasons and a "Reveal in Trash" action.
  - Moved items are removed from the results, evicted from the scan index
    and subtracted from the header totals; a cancelled run always ends the
    activity banner and records what actually ran.

### Fixed

- **Deep Scan "Items scanned: 1" defect.** Root causes, all fixed:
  - The directory enumerator yields the scan root itself first; it was
    recorded as a file (nil-defaulted `isDirectory`) and the first failed
    root validation pruned the whole subtree via `skipDescendants()`.
    Roots are now never counted and never prune the scan; `isDirectory`
    comes from `lstat` ground truth.
  - `PathSafety.validate` rejected every non-home path and every data-
    volume path (APFS system/data device split) as cross-volume. A root
    grant model now distinguishes granted roots (home, user Library,
    security-scoped authorized folders) from not-granted roots (volume
    roots without Full Disk Access), and the granted system+data volume
    pair is one device group.
  - Coverage outcomes were optimistically set to "scanned" before the
    scan ran. Coverage is now built exclusively from the real per-root
    scanner results; not-granted/denied roots are listed with exact
    reasons and force "Limited coverage" in the UI — "complete" is only
    ever reported after genuine traversal.
  - Junk classification treated any path containing "Library"/"Caches"/
    "Logs" as protected, so all cache candidates were PROTECTED ("Zero KB
    candidates"). Classification is now driven by the scan's actual
    root tables (library/review roots), with protected-component checks
    limited to top-level personal folders and VCS trees.
- Quick/Balanced/Deep roots redesigned: Quick keeps high-value junk
  locations; Balanced adds the full home; Deep adds home + volume roots
  (FDA-gated) + /Applications (readable, FDA-gated) + authorized folders.
- Incremental scans now respect the user setting; opportunity roots that
  don't exist are dropped instead of reported as denied.

### Added

- **"Choose folders for Deep Scan"**: `NSOpenPanel` + persisted
  security-scoped bookmarks (`FolderAuthorizationsStore`), managed in the
  Deep Scan hero and Settings → Permissions; scopes stay active for the
  scan duration.
- Root-by-root coverage details with state, reason and per-root denied
  counts in the results workspace; "Limited coverage" pill + Full Disk
  Access deep-link; honest zero-candidates explanation.
- `Tools/verify_deepscan.sh` — build + regression-suite + manual GUI
  verification checklist.
- `DeepScanRegressionTests` (10 tests): multi-file fixture inventories,
  root-never-counted regression, fixture cache/log SAFE classification,
  protected-file skipping, unreadable/missing roots never "scanned",
  limited-vs-complete coverage, root grant matrix.

## [1.1.0] - 2026-08-25

### Added

- **Aurora Glass design system**: semantic color tokens, immersive midnight/
  indigo/violet gradient, animated aurora illumination (static under Reduce
  Motion), glass surfaces, native Liquid Glass on macOS 26 behind
  `#available` + `#if compiler(>=6.2)` guards, `.ultraThinMaterial` fallback.
- **Premium sidebar** with all 20 modules (MAIN/CLEANUP/STORAGE/
  APPLICATIONS/HEALTH/OTHER), capsule selection, distinct hover/pressed/
  focus states, original Canvas artwork per module.
- **Hero screens** for every module: benefit, three capabilities, scope and
  scan-mode selectors, anchored primary action, last-scan and permission
  warnings.
- **Four genuine scan modes**: Quick, Balanced, Deep and Custom via
  `ScanPolicy`, with 13-phase `DeepScanCoordinator`, pause/resume/cancel,
  thermal auto-pause, battery-aware hashing and honest coverage reports.
- **Deep scan engine** (`Engine/`): `VolumeDiscoveryService`,
  `FileInventoryScanner`, `TraversalPolicy`, `MetadataCollector`,
  `JunkClassifier` (SAFE/REVIEW/PROTECTED), `ApplicationInventoryService`
  (fixes the previous ~2-app discovery bug), `ResidualCorrelationEngine`,
  `DuplicatePipeline`, `ScanProgressAggregator`, `ScanCoverageReport`,
  `ScanIndexStore` (SQLite, migrations, checkpoints, resume),
  `IncrementalScanSupport` (public FSEvents), `CleanupPlanBuilder`,
  `CleanupSafetyValidator`, `CleanupExecutor`, `IgnoreListStore`, `ScanGate`.
- **Results workspace**: summary ring, tiles, category navigation,
  virtualized item list, coverage inspector, sticky action bar with a
  deliberate Preview-Mode control and second confirmation.
- **Space Lens**: real hierarchical bubble visualization (Canvas circle
  packing), hover-synchronized list, drill-in, breadcrumbs, back/forward,
  "Other" aggregation for huge folders.
- **Applications + Uninstaller**: inventory from /Applications,
  ~/Applications, /System/Applications (read-only) and nested folders;
  Mach-O architecture reading; signing and quarantine state; exact-ID
  component matching; running-app protection.
- **App Leftovers**, **Trash Bins**, **My Clutter**, **Large & Old Files**,
  **System Junk**, **Smart Care**, **Deep Scan** modules.
- **Security Audit** (FDA probe, quarantine flags, unsigned/broken agents —
  no fake malware claims), **Performance** (thermal, memory/storage
  pressure, sampled per-app CPU), **Permissions** (FDA onboarding with
  likely/limited/not-determined/denied wording).
- **Activity & History** with search, filter, JSON/CSV export, path
  redaction and clear-with-confirmation.
- **Sparkle 2** via Swift Package Manager with a configuration gate
  (updates disabled in unsigned/placeholder builds), plus CI and release
  workflows (Developer ID, notarization, stapling, `spctl` verification,
  EdDSA-signed appcast) that fail loudly without secrets.
- 60+ tests including a fixture end-to-end inventory→plan→preview→execute
  flow, engine classification, residuals, SQLite index, Space Lens
  aggregation and Mach-O parsing.

### Changed

- Startup Manager rewritten on SMAppService + supported locations (no
  deprecated LSSharedFileList), with broken-reference detection.
- Settings reorganized into General/Scanning/Safety/Permissions/Updates/
  Advanced/About.
- `Tools/generate_pbxproj.py` now generates the project deterministically.

## [1.0.0] - 2026-08-24

### Added

- Native SwiftUI app for macOS 13+, Swift 5.9, Apple Silicon (arm64).
- Premium SwiftUI interface: sidebar navigation, dashboard, search, filters,
  sort controls, progress indicators, cancellation, light/dark/system
  appearance, VoiceOver-friendly labels.
- Dashboard with storage overview: volume ring chart, per-folder usage bars,
  purgeable space, safety posture summary and quick actions.
- Preview-first Safe Cleanup: dry-run mode ON by default, explicit item
  selection, second confirmation dialog, trash-only removal.
- Large File Finder: scans user-selected folders only, depth-limited,
  threshold from Settings, sortable and searchable results.
- Developer cache scanner: Xcode DerivedData/Archives/Simulator data, SwiftPM,
  CocoaPods, npm, Yarn, pnpm, Gradle, Maven, Cargo, pip and Homebrew caches.
- Read-only Startup Manager: login items, launch agents and launch daemons are
  listed but never modified in version 1.
- Streaming SHA-256 Duplicate Finder for explicitly selected folders, with
  size pre-filtering, hard-link awareness and a kept copy per group.
- Cautious Application Uninstaller with High/Medium/Caution confidence labels,
  support-file matching, and a hard block on running apps.
- Non-sensitive browser/application cache cleaning (cookies, history,
  sessions, saved passwords and personal data are always protected).
- Local cleanup history with JSON and CSV export; corrupt history files are
  tolerated gracefully.
- Settings: large-file threshold, exclusions, scan depth, dev-cache categories,
  dev-cache age, appearance mode and master dry-run toggle.
- Central path-safety policy (`Core/PathSafety.swift`): canonicalization,
  symlink containment, ownership checks, device boundaries, protected-root
  and protected-name classification.
- Immediate revalidation before every filesystem mutation (TOCTOU protection).
- Cancellable cooperative scans via structured concurrency.
- Unit test suite (`SalmanMacCleanerTests`) covering protected paths, personal
  paths, traversal, symlinks, ownership, preview-only mode, revalidation,
  selected-items-only cleanup, trash-only behavior, duplicate grouping,
  streaming hashes, hard links, cancellation, history and permission failures.
- Structural project validator (`Tools/validate_project.py`) for CI.

### Security

- No Full Disk Access or admin/root requirement for the core app.
- No shell execution, no `sudo`, no `rm`, no `Process`/`NSTask`, no `system()`,
  no `popen()`, no network calls — enforced by design and by the validator.
- Never permanently deletes files and never empties the Trash.
- `/System`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/Applications`,
  `/Volumes`, `/Network`, `/dev`, `/cores` and other root locations are
  hard-blocked; Desktop/Documents/Downloads/Pictures/Music/Movies are never
  scanned by default; other-user files, keychains, browser privacy data,
  personal documents, source repositories, cloud databases, Time Machine
  backups and VM disks are protected.
- Recursive scans never follow symlinks, never cross mounted volumes, and
  never follow symlink loops.
- Running applications are never removed.

### Known limitations

- Startup Manager is intentionally read-only in version 1.
- Cleanup moves items to the Trash; the user (or Finder) empties the Trash.
- Uninstaller only offers apps from `~/Applications`; system-wide apps are
  never offered.

## [Unreleased]

- Startup item management (safe, explicit toggle-only) — planned.
- App Store distribution pipeline — planned.
- More developer cache locations (uv, Bun, RubyGems) — planned.
