# File Manifest

Generated structure of the Salman Mac Cleaner repository.

## Xcode project

```
SalmanMacCleaner.xcodeproj/
  project.pbxproj
  project.xcworkspace/contents.xcworkspacedata
  xcshareddata/xcschemes/SalmanMacCleaner.xcscheme
```

## App target — SalmanMacCleaner

```
SalmanMacCleaner/
  SalmanMacCleanerApp.swift
  Info.plist
  SalmanMacCleaner.entitlements
  Assets.xcassets/
    AppIcon.appiconset/
      Contents.json
      icon_16.png … icon_512@2x.png   (10 rendered PNGs)
    AccentColor.colorset/Contents.json
  en.lproj/Localizable.strings
  Core/
    PathSafety.swift
    Crypto.swift
    FileUtilities.swift
    AppState.swift
    SettingsStore.swift
    HistoryStore.swift
    CleanupEngine.swift
  Features/
    Models.swift
    FolderPicker.swift
    ScanCoordinator.swift
    Dashboard/
      StorageOverview.swift
      DashboardView.swift
    LargeFiles/
      LargeFileScanner.swift
      LargeFilesView.swift
      LargeFilesViewModel.swift
    Duplicates/
      DuplicateFinder.swift
      DuplicatesView.swift
      DuplicatesViewModel.swift
    DeveloperCaches/
      DeveloperCacheScanner.swift
      DeveloperCachesView.swift
      DeveloperCachesViewModel.swift
    StartupItems/
      StartupManager.swift
      StartupItemsView.swift
    Uninstaller/
      Uninstaller.swift
      UninstallerView.swift
      UninstallerViewModel.swift
  UI/
    ContentView.swift
    SidebarView.swift
    SharedComponents.swift
    SettingsView.swift
    HistoryView.swift
  Utilities/                  (reserved)
```

## Unit test target — SalmanMacCleanerTests

```
SalmanMacCleanerTests/
  PathSafetyTests.swift
  CleanupEngineTests.swift
  DuplicateFinderTests.swift
  SettingsHistoryTests.swift
  ScanLifecycleTests.swift
  StartupManagerTests.swift
```

## Tooling & documentation

```
Tools/
  validate_project.py    structural validation (no Xcode required)
  parse_check.py         tree-sitter Swift syntax parse of every source file
  xref_check.py          heuristic cross-reference check
  generate_icon.py       renders the AppIcon PNGs (stdlib only)
README.md
SECURITY.md
LICENSE
CHANGELOG.md
FILE_MANIFEST.md
.gitignore
```
