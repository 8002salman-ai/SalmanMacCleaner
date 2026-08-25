# Security Policy

Salman Mac Cleaner is built to be the *safest* cleaner on your Mac. This document describes the security model, what the app will never do, and how to report issues.

## Design guarantees

1. **Preview-first.** Preview Mode is ON by default. Every cleanup can be previewed without touching the filesystem, and exiting Preview Mode is a deliberate, confirmed user action.
2. **Trash-only removal.** The only destructive API used anywhere in the codebase is `FileManager.trashItem`. The app never permanently deletes files and never empties the Trash.
3. **Three-layer cleanup.** Inventory scanning → `CleanupPlanBuilder` (immutable plan with expected identity) → `CleanupSafetyValidator` (TOCTOU revalidation immediately before every action) → `CleanupExecutor` (trash-only). Changed symlinks, changed inodes, changed owners and changed volumes are all rejected.
4. **No shell, no root.** The app never uses `sudo`, `rm`, `unlink`, shell commands, `Process`, `NSTask`, `system()`, `popen()`, `bash`, `zsh`, `curl` or `wget`. A CI validator asserts this on every run.
5. **No network.** The app performs no network requests of any kind — no analytics, no telemetry, no phoning home. (Sparkle is the sole exception and only when a real signed feed is configured.)
6. **No Full Disk Access / admin required.** The core app runs in a sandbox with only user-selected file access; Full Disk Access is granted by the user in System Settings and probed honestly (likely/limited/not determined/denied).
7. **Explicit selection + second confirmation.** Only user-ticked items are ever passed to the cleanup engine, after a confirmation dialog.
8. **Double validation.** Every path is validated when discovered and revalidated immediately before any mutation (TOCTOU protection).
9. **Read-only Startup Manager.** Version 1 never modifies login items, launch agents or launch daemons.
10. **Honest coverage.** Scans report scanned/partial/denied/SIP-protected/skipped roots with precise wording; "Entire Mac scanned" is never displayed unless true.

## Engine safety layers

| Layer | Protection |
| --- | --- |
| `TraversalPolicy` | FSEvents internals (`.fseventsd`, `.Spotlight-V100`), Time Machine, packages, hidden files, cross-volume descent (except the granted APFS system+data volume pair), symlinks; the scan root itself is never counted as a file and never prunes the scan |
| `JunkClassifier` | Three-level classification — SAFE (allowlist + regenerable + not in use), REVIEW (never auto-selected), PROTECTED (hard-blocked) |
| `ScanIndexStore` | SQLite persistence with schema migrations, checkpoints, root-granularity resume |
| `IncrementalScanSupport` | Public FSEvents APIs only; event history invalidation forces full rescan; `.fseventsd` is never read |
| `ResidualCorrelationEngine` | Exact bundle/container/preference/saved-state identifiers; loose substring matching forbidden |
| `DuplicatePipeline` | Size → sample → streaming SHA-256 → inode identity; hard links never counted as reclaimable |
| `VolumeDiscoveryService` | Network/cloud/read-only/external volumes require explicit opt-in; never descends into a second mounted volume |
| `ScanPolicy` | Root grant model: home/library roots always granted; volume roots only with Full Disk Access/opt-in; `NSOpenPanel` + security-scoped bookmarks for user-authorized folders; opportunity roots that don't exist are dropped, not faked |
| `ScanCoverageReport` | Per-root outcomes from real scanner results; not-granted/denied roots force "Limited coverage" with exact reasons; complete only after every intended accessible root was genuinely scanned |

## Protected data

The safety layer (`Core/PathSafety.swift`) hard-blocks:

| Category | Protection |
| --- | --- |
| System locations | `/System`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/Applications`, `/Volumes`, `/Network`, `/dev`, `/cores`, `/opt`, `/srv`, `/var`, `/etc`, `/tmp`, `/net`, `/home` |
| Personal folders | Desktop, Documents, Downloads, Pictures, Music, Movies (never scanned by default; explicit subfolder selection required) |
| Other users' files | Ownership (`st_uid`) checked on every path; root-owned files are rejected |
| Credentials | Keychains, `Login Data`, password stores, `.netrc`, `.git-credentials`, `.aws`, `.azure`, `.kube`, SSH keys, GNUPG |
| Browsing privacy data | Cookies, History, sessions, bookmarks, Local State, IndexedDB |
| Personal content | Photos, email, messages, documents (via personal-folder protection) |
| Source repositories | `.git`, `.svn`, `.hg`, source trees, `node_modules`, `Pods`, `.build` (via component/suffix protection) |
| Cloud databases | `*.sqlite*`, `*.db`, `*.leveldb`, LevelDB/WAL/journal files |
| Time Machine & VM disks | `Backups.backupdb`, `*.sparsebundle`, `*.vmdk`, `*.vhdx`, `*.qcow2`, `*.img`, `*.iso`, Parallels/VMware bundles |
| Executables & scripts | `.app`, `.exe`, `.sh`, `.command`, `.applescript`, `.scpt`, `.ipsw` |

Symlinks are never followed during traversal; explicitly allowed symlinks must resolve inside the selected root. Scans never cross mounted volumes (`st_dev` boundaries) and never follow recursive symlink loops.

## Reporting a vulnerability

If you find a way to bypass any of these protections:

1. **Do not** open a public issue with exploit details.
2. Send a report to the repository maintainer via GitHub's **Report a vulnerability** flow (Security tab → Advisories) or a private message describing:
   - the affected feature,
   - steps to reproduce,
   - the impact (what could be deleted or modified).

We aim to acknowledge reports within 7 days and resolve confirmed issues within 30 days.

## Out of scope

- The Trash itself: the app moves items to the user's Trash; the user (or Finder) empties it.
- Third-party modifications of the source that re-enable permanent deletion.
- Social-engineering: the app cannot protect users from manually emptying the Trash themselves.

## Compliance checklist

The repo ships `Tools/validate_project.py` (structure, references, forbidden
APIs, placeholders), `Tools/parse_check.py` (tree-sitter syntax parse of every
Swift file) and `Tools/xref_check.py` (heuristic cross-reference check). CI
runs them together with the unit-test suite:

```bash
python3 Tools/validate_project.py
pip install tree-sitter tree-sitter-swift && python3 Tools/parse_check.py
python3 Tools/xref_check.py
```

CI also runs the unit tests (`SalmanMacCleanerTests`) on macOS runners —
including the fixture-based end-to-end inventory → plan → preview → execute
flow that proves unselected and protected files remain untouched.
