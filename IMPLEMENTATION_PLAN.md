# Implementation Plan — Aurora Glass Upgrade

Status legend: ✅ done · 🔜 this phase

## 1. Existing-code audit (completed 2026-08-25)

| # | Area | Finding |
|---|------|---------|
| 1 | Swift sources | 38 files, all non-empty, tree-sitter parse-clean, referenced by `project.pbxproj`. |
| 2 | Target membership | App target + hosted XCTest target, shared scheme, ad-hoc signing, sandbox + hardened runtime enabled. |
| 3 | Entitlements | App Sandbox + user-selected file R/W + downloads R/W. Suitable for the direct-distribution edition; deep scanning depends on Full Disk Access granted by the user in System Settings. |
| 4 | Path-safety rules | Central `PathSafety` policy: canonicalization, symlink containment, ownership, device boundaries, protected roots/names/suffixes, personal-folder protection. **Kept and extended** — never weakened. |
| 5 | Preview/cleanup | Dry-run ON by default, explicit selection, second confirmation, `trashItem` only, revalidation before every mutation. Preserved; extended with a three-layer plan→validate→execute pipeline. |
| 6 | Uninstaller bug | **Root cause:** `Uninstaller.discoverApplications()` enumerates `~/Applications` only — on typical machines that yields ≈2 apps and never `/Applications`. Fix: new `ApplicationInventoryService` scanning `/Applications`, `~/Applications`, `/System/Applications` (protected/read-only) and nested locations, deduped by canonical path + bundle id. |
| 7 | Updater | None. Sparkle 2 integrated via Swift Package Manager with availability guards; dev builds disable updates honestly until a signed feed exists. |
| 8 | Tests | 6 files / 38 tests exist for safety, cleanup, duplicates, settings/history, scan lifecycle, startup. Extended with engine, classifier, inventory, residuals, plan/executor, index-store, fixture E2E and updater-config tests. |
| 9 | Git | Branch `arena/01a0356d-salmanmaccleaner` at `85468d2`, matches `origin`. No force-push; logical commits per stage. |

## 2. Work stages

1. **Architecture & scan model** — `Engine/` package: ScanModels, TraversalPolicy, VolumeDiscoveryService, MetadataCollector, FileInventoryScanner, ScanPolicy (Quick/Balanced/Deep/Custom), JunkClassifier (SAFE/REVIEW/PROTECTED), ApplicationInventoryService, ResidualCorrelationEngine, DuplicatePipeline, ScanProgressAggregator, ScanCoverageReport, ScanIndexStore (SQLite, schema-migrated, checkpointed), CleanupPlanBuilder, CleanupSafetyValidator, CleanupExecutor, IgnoreListStore, ScanGate (pause/resume), DeepScanCoordinator (actor + AsyncStream), IncrementalScanSupport (public FSEvents), MachOArchitecture, ProcessSampler.
2. **Aurora Glass design system** — semantic tokens (midnight #100025, indigo #1B0648, violet #5F14C7, electric purple #8C35FF, magenta #F02FD0, cyan #5DDCFF, success #41D18A, amber #FFC857, coral #FF5C76), light/dark variants, accessibility environment (Reduce Motion/Transparency, Increase Contrast), aurora background with radial illumination, glass surfaces, native Liquid Glass on macOS 26 behind `#available` + `#if compiler(>=6.2)`.
3. **Sidebar & heroes** — 20-module sidebar (MAIN/CLEANUP/STORAGE/APPLICATIONS/HEALTH/OTHER) with original per-module Canvas artwork, hero screens with scope/scan-mode selectors, capability lists, last-scan info.
4. **Deep scan engine + results workspace** — 13 real phases, honest progress/coverage, summary ring, tiles, category navigation, virtualized item list, sticky action bar with deliberate Preview-Mode control.
5. **Space Lens** — hierarchical allocated-size tree, capped children + "Other" aggregation, Canvas circle packing, hover sync, drill-in, breadcrumbs, back/forward.
6. **Applications/Uninstaller/Leftovers** — inventory from all app roots; exact bundle-id/container/preference-domain matching only; leftover confidence HIGH/MEDIUM/CAUTIOUS; system apps protected.
7. **Health modules** — Performance (thermal, memory/CPU evidence), Security Audit (FDA probe, quarantine xattr, unsigned agents — no fake malware claims), Permissions (FDA onboarding flow, probe wording: likely/limited/not-determined/denied).
8. **Sparkle updater + release workflow** — SPM integration, guarded controller, appcast template, GitHub Actions CI + release (Developer ID, notarization, stapling, Sparkle EdDSA), secrets documented, no secrets committed.
9. **Tests & docs** — fixture-based engine tests, E2E cleanup flow, README/SECURITY/Distribution/Sparkle docs, CHANGELOG.
10. **Final verification** — regenerate `project.pbxproj` with all new files, structural validator, tree-sitter parse of every file, cross-reference checks, commit + push.

## 3. Honesty constraints (never violated)

- No fake scan totals, fake progress, fake malware detection, fake update results, placebo "optimization".
- Unavailable features are shown with a technically accurate reason.
- SIP is never bypassed; FDA is requested via System Settings by the user.
- Coverage reports use precise wording; "Entire Mac scanned" is never displayed unless true.
- Personal data, browser sessions, credentials, Time Machine and VM disks stay PROTECTED.
- Only SAFE items are smart-selected; REVIEW and PROTECTED are never auto-selected.
