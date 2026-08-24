# Salman Mac Cleaner

A safe, privacy-respecting, native macOS cleaner built with **SwiftUI**. Salman Mac Cleaner helps you find large files, duplicate files, developer caches, startup items and old applications — and it does so **preview-first**: nothing is ever deleted automatically, and every removal goes to the Trash (never permanent).

> **macOS 13+ · Swift 5.9+ · Apple Silicon (arm64)**

---

## Why this cleaner is different

Most "cleaner" apps require Full Disk Access, run shell commands as root, and delete aggressively. Salman Mac Cleaner deliberately does the opposite:

- **Dry-run (preview) mode is ON by default.** Every cleanup shows exactly what would happen before anything is moved.
- **Trash-only removal.** The app calls `FileManager.trashItem` exclusively. It never permanently deletes, never empties the Trash, and never uses `rm`, `sudo`, shell commands, `Process`/`NSTask`, `system()`, or `popen()`.
- **No Full Disk Access, no admin/root.** The core app works with zero elevated privileges.
- **Explicit selection + second confirmation.** Cleanup acts only on items you tick, after a confirmation dialog.
- **Protected locations are hard-blocked** in code: `/System`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/Applications`, `/Volumes`, `/Network`, `/dev`, `/cores`, other users' files, app bundles, keychains, passwords, cookies, sessions, browser history, email, photos, personal documents, source repositories, Git metadata, cloud databases, Time Machine backups and VM disks.
- **Personal folders are never scanned by default.** Desktop, Documents, Downloads, Pictures, Music and Movies are only touched if you explicitly pick a specific folder inside them.
- **No network calls, ever.** There is no analytics, no telemetry, no update checker. The app cannot reach the internet.

## Features

| Feature | Description |
| --- | --- |
| **Dashboard & storage overview** | Volume ring chart, per-folder usage bars, safety posture summary, quick actions and local cleanup history. |
| **Preview-first Safe Cleanup** | Every tool supports a "Preview Cleanup" pass that changes nothing, plus a confirmed trash-only pass for selected items. |
| **Large File Finder** | Depth-limited scan of **user-selected folders only**, sortable/filterable results, threshold from Settings. |
| **Developer cache scanner** | Xcode DerivedData, Archives, Simulator data, SwiftPM, CocoaPods, npm, Yarn, pnpm, Gradle, Maven, Cargo, pip and Homebrew caches — grouped by category, preview-first. |
| **Read-only Startup Manager** | Lists login items, launch agents and launch daemons. Version 1 deliberately never modifies them. |
| **Streaming SHA-256 Duplicate Finder** | Exact-content duplicates in explicitly selected folders, with hard-link awareness and a kept copy per group. |
| **Cautious App Uninstaller** | Only your own `~/Applications` apps, with High/Medium/Caution confidence labels, support-file matching, and a hard block on running apps. |
| **Non-sensitive browser/application cache cleaner** | Caches from tools and apps (never cookies, history, sessions, saved passwords or personal data). |
| **Local cleanup history** | Every cleanup is recorded locally with JSON/CSV export. |
| **Settings** | Thresholds, exclusions, scan depth, dev-cache categories, appearance (light/dark/system) and the master dry-run toggle. |

## Safety architecture

1. **Path validation at scan time** — `PathSafety.validate` canonicalizes parents, rejects symlinks by default, enforces user-home containment, protected-root checks, ownership checks and device-boundary checks.
2. **Revalidation immediately before cleanup** — `CleanupEngine.revalidate` runs the exact same validation again right before `trashItem`, closing TOCTOU gaps.
3. **No symlink following during traversal** — recursive scans never follow links, so symlink loops and cross-volume escapes are impossible.
4. **Only selected items** — the engine receives the exact set of user-ticked items; there is no "delete all found".
5. **Running apps are blocked** — the uninstaller refuses to remove a running app.
6. **Cancellable, cooperative scans** — every scanner polls a cancellation closure between files/directories.

## Requirements

- macOS 13 Ventura or later
- Xcode 15 or later (Swift 5.9 toolchain)
- Apple Silicon (arm64)

## Building

```bash
# Clone
git clone https://github.com/8002salman-ai/SalmanMacCleaner.git
cd SalmanMacCleaner

# Build (arm64)
xcodebuild -project SalmanMacCleaner.xcodeproj \
  -scheme SalmanMacCleaner \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  build

# Run tests
xcodebuild -project SalmanMacCleaner.xcodeproj \
  -scheme SalmanMacCleaner \
  -destination 'platform=macOS,arch=arm64' \
  test
```

The app is sandboxed and hardened; ad-hoc signing is enabled by default so it builds without a developer account.

## Project layout

```
SalmanMacCleaner.xcodeproj          Xcode project (app + unit test targets)
SalmanMacCleaner/
  SalmanMacCleanerApp.swift         SwiftUI app entry point
  Info.plist                        App metadata
  SalmanMacCleaner.entitlements     Sandbox + user-selected file entitlements
  Assets.xcassets                   App icon set + accent color
  en.lproj/Localizable.strings      English localization
  Core/                             Safety, crypto, cleanup engine, state
    PathSafety.swift                Central path-safety policy
    Crypto.swift                    Streaming SHA-256 (CommonCrypto)
    CleanupEngine.swift             Trash-only removal + revalidation
    AppState.swift / SettingsStore.swift / HistoryStore.swift / FileUtilities.swift
  Features/
    Dashboard/                      Storage overview + dashboard UI
    LargeFiles/                     Large File Finder
    Duplicates/                     Duplicate Finder
    DeveloperCaches/                Developer cache scanner
    StartupItems/                   Read-only startup manager
    Uninstaller/                    Cautious uninstaller
  UI/                               ContentView, sidebar, settings, shared components
SalmanMacCleanerTests/              XCTest unit tests
Tools/validate_project.py           Structural project validator
CHANGELOG.md · SECURITY.md · LICENSE
```

## Validation without Xcode

On non-macOS hosts you can still validate the project structurally:

```bash
python3 Tools/validate_project.py            # structure, references, forbidden APIs
pip install tree-sitter tree-sitter-swift    # then:
python3 Tools/parse_check.py                 # syntax-parse every Swift file
python3 Tools/xref_check.py                  # heuristic cross-reference check
```

## Contributing

Contributions are welcome. Please keep the safety rules in mind:

- Never introduce permanent deletion, shell execution, sudo, or network calls.
- Keep preview-first behavior and trash-only removal.
- Add tests for any new path handling — see `SalmanMacCleanerTests`.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Apple Inc.
