# Changelog

All notable changes to Salman Mac Cleaner are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
