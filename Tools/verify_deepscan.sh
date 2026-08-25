#!/bin/bash
# verify_deepscan.sh — Deep Scan fix verification for macOS (Apple Silicon).
#
# Runs the exact build/test commands and the Deep Scan regression suite that
# covers the "Items scanned: 1" defect. Then prints the manual GUI
# verification checklist for a real user-selected folder scan.
set -euo pipefail

PROJECT="SalmanMacCleaner.xcodeproj"
SCHEME="SalmanMacCleaner"
DESTINATION="platform=macOS,arch=arm64"

echo "==> 1/4 Structural validation"
python3 Tools/validate_project.py

echo "==> 2/4 Debug build (unsigned)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO build

echo "==> 3/4 Release build (unsigned)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO build

echo "==> 4/4 Unit tests (includes DeepScanRegressionTests)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -destination "$DESTINATION" CODE_SIGNING_ALLOWED=NO test \
  -only-testing:SalmanMacCleanerTests/DeepScanRegressionTests \
  -only-testing:SalmanMacCleanerTests/FixtureEndToEndTests

cat <<'GUIDE'

Manual GUI verification checklist
---------------------------------
1. Build & launch the app (⌘R in Xcode, or open the Debug product).
2. Create a test folder with at least 20 files, including:
   - Library/Caches/…/cache-*.bin files (older than 1 day)
   - Library/Logs/…/*.log files
   - a large file (>200 MB) and two identical duplicate files
3. In Deep Scan, use "Choose Folder…" to authorize that folder, then
   Start Deep Scan.
4. Verify in the results:
   - Items scanned matches the real file count (not 1)
   - Bytes indexed matches the real total
   - Scan Coverage lists the folder as "Scanned" (or the reason otherwise)
   - Safe to Clean / Needs Review tabs show the real cache/log candidates
   - Without Full Disk Access, volume roots show "Not granted — Full Disk
     Access not granted" and the summary says "Limited coverage"
GUIDE
