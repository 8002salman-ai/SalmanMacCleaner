# Security Policy

Salman Mac Cleaner is built to be the *safest* cleaner on your Mac. This document describes the security model, what the app will never do, and how to report issues.

## Design guarantees

1. **Preview-first.** Dry-run mode is ON by default. Every cleanup can be previewed without touching the filesystem.
2. **Trash-only removal.** The only destructive API used anywhere in the codebase is `FileManager.trashItem`. The app never permanently deletes files and never empties the Trash.
3. **No shell, no root.** The app never uses `sudo`, `rm`, `unlink`, shell commands, `Process`, `NSTask`, `system()`, `popen()`, `bash`, `zsh`, `curl` or `wget`. Grep the source: there are zero such call sites.
4. **No network.** The app performs no network requests of any kind — no analytics, no telemetry, no phoning home.
5. **No Full Disk Access / admin required.** The core app runs in a sandbox with only user-selected file access. It does not request or require Full Disk Access.
6. **Explicit selection + second confirmation.** Only user-ticked items are ever passed to the cleanup engine, after a confirmation dialog.
7. **Double validation.** Every path is validated when discovered and revalidated immediately before any mutation (TOCTOU protection).
8. **Read-only Startup Manager.** Version 1 never modifies login items, launch agents or launch daemons.

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

The repo ships `Tools/validate_project.py`, which asserts the structural guarantees (no forbidden APIs, all files present and non-empty, project references valid, tests present). Run it in CI:

```bash
python3 Tools/validate_project.py
```

CI should also run the unit tests (`SalmanMacCleanerTests`) on macOS runners.
