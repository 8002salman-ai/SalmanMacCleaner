# v1.1.4 repair checklist

Baseline verified before edits on `arena/01a03a86-salmanmaccleaner`: `924fd26 fix: prevent Space Lens crashes and show app version`, `MARKETING_VERSION = 1.1.3`, `CURRENT_PROJECT_VERSION = 3`.

## Root causes mapped to the existing code

| Area | Root cause | Targeted files/types |
| --- | --- | --- |
| Safety/accounting | Feature screens still call the legacy `CleanupEngine` directly; expected scan sizes are reused after a move, hard-link and parent/child totals are not uniformly reconciled, and several result screens clear failed/preview items. | `CleanupEngine`, `CleanupPlanBuilder`, `CleanupExecutor`, `ResultsWorkspaceModel`, large/developer/duplicate/leftover views |
| FDA | Global banner state is inferred from a small probe but module coverage failures are not represented separately; refresh/status presentation is duplicated. | `PermissionService`, `ContentView`, `PermissionsView`, `SharedComponents` |
| Smart Care | The primary action is only a Quick Deep Scan and has no aggregate health snapshot, live phase model, cancellation, or factor evidence. | `SmartCareView`, new `HealthCheckService` |
| Space Lens | The scanner recursively rebuilds without canonical identity tracking, depth limits turn measured folders into zero-sized nodes, root state selection hides valid empty scans, and the packer places children while avoiding the root circle itself—so one giant/empty circle results. | `SpaceLensEngine`, `SpaceLensViewModel`, `BubblePacker`, `SpaceLensView` |
| Developer Caches | Only 13 categories exist, all categories are initially selected, detection is absent, directory measurement is shallow, and the view has no detected-state/category filter/cancel/refresh review controls. | `DeveloperCacheCategory`, `DeveloperCacheScanner`, `DeveloperCachesViewModel`, `DeveloperCachesView` |
| App leftovers/inventory | The UI uses the raw bundle ID as the primary name; Apple services and installed/running/ambiguous groups are not modeled as separate classifications. App discovery omits CoreServices and the running app when launched outside an app root; uninstaller matching falls back to loose name substrings. | `AppRecord`, `LeftoverCandidate`, `ApplicationInventoryService`, `ResidualCorrelationEngine`, `AppLeftoversView`, `UninstallerView` |
| Duplicates | Root presets are not offered before the folder picker; hard-link/selection byte accounting is separate from cleanup accounting and rows lack explicit exact-match evidence/actions. | `DuplicateFinder`, `DuplicatesViewModel`, `DuplicatesView` |
| Layout/accessibility | Shared hero screens use page-level scrolling, action typography is inconsistent, and several rows lack consistent glass/hover/focus/tooltip treatment. | `HeroScreenView`, `GlassComponents`, module result views |
| Release/quality | Version is read from the bundle but fallback text is stale; no v1.1.4/build 4 metadata or focused regression tests for the repaired invariants. | `project.pbxproj`, `CHANGELOG.md`, tests |

## Safety invariants kept throughout

- Preview is the default and never calls a Trash mover.
- Real cleanup is selected-item-only and uses `FileManager.trashItem` through the existing executor.
- Canonical containment, ownership, symlink, protected-path, running-app, and category allowlist checks are revalidated immediately before each move.
- Personal data, Apple/system services, the cleaner itself, ambiguous leftovers, active simulator/user data, and failed/unknown items remain protected or review-only.
- All totals distinguish candidate, selected, successfully moved, failed, previewed, and currently remaining bytes; no stale cached total is presented as reclaimed space.
