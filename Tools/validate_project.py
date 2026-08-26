#!/usr/bin/env python3
"""
Structural validator for the Salman Mac Cleaner repository.

Checks (no Xcode required):
  1. Every Swift file referenced by project.pbxproj exists on disk and is
     non-empty.
  2. The Xcode project declares an app target and a unit-test target.
  3. Assets.xcassets, Info.plist, entitlements, Localizable.strings and the
     docs exist.
  4. No zero-byte Swift sources anywhere.
  5. No placeholder code (TODO/FIXME/fatalError/placeholder/empty actions).
  6. Forbidden APIs are absent from app sources (rm/sudo/Process/NSTask/
     system()/popen()/network calls).

Exit code 0 means all checks passed.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "SalmanMacCleaner.xcodeproj", "project.pbxproj")
APP_DIR = os.path.join(ROOT, "SalmanMacCleaner")
TEST_DIR = os.path.join(ROOT, "SalmanMacCleanerTests")

ERRORS: list[str] = []
WARNINGS: list[str] = []


def error(msg: str) -> None:
    ERRORS.append(msg)


def warning(msg: str) -> None:
    WARNINGS.append(msg)


def check(condition: bool, ok: str, fail: str) -> None:
    if condition:
        print(f"  ✓ {ok}")
    else:
        error(fail)
        print(f"  ✗ {fail}")


def swift_files(root: str) -> list[str]:
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".swift"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def strip_comments_and_strings(content: str) -> str:
    """Remove Swift comments and string literals so structural scans only see
    real code (documentation legitimately mentions forbidden words)."""
    out: list[str] = []
    i = 0
    n = len(content)
    while i < n:
        c = content[i]
        if c == "/" and i + 1 < n and content[i + 1] == "/":
            while i < n and content[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and content[i + 1] == "*":
            end = content.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        if c == '"':
            i += 1
            while i < n:
                if content[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                if content[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def pbxproj_file_refs() -> set[str]:
    with open(PROJECT, "r", encoding="utf-8") as handle:
        content = handle.read()
    refs: set[str] = set()
    for match in re.finditer(r"path = ([^;]+);", content):
        path = match.group(1).strip('"')
        if path.endswith(".swift"):
            refs.add(path)
    return refs


def main() -> int:
    print("== Salman Mac Cleaner structural validation ==\n")

    # 1. Project file exists
    print("[1] Xcode project")
    check(os.path.isfile(PROJECT), "project.pbxproj exists", "project.pbxproj is missing")
    if not os.path.isfile(PROJECT):
        return 1

    with open(PROJECT, "r", encoding="utf-8") as handle:
        pbx = handle.read()

    check("com.apple.product-type.application" in pbx, "app target declared", "app target missing")
    check("com.apple.product-type.bundle.unit-test" in pbx, "unit-test target declared", "unit-test target missing")
    check("PBXNativeTarget" in pbx and pbx.count("isa = PBXNativeTarget") >= 2, "two native targets present", "native targets missing")
    check("MACOSX_DEPLOYMENT_TARGET = 13.0" in pbx, "macOS 13.0 deployment target", "deployment target not 13.0")
    check("SWIFT_VERSION = 5.9" in pbx, "Swift 5.9 language version", "Swift version not 5.9")
    check("ENABLE_APP_SANDBOX = YES" not in pbx, "app sandbox disabled for Full Disk Access build", "app sandbox still enabled")

    # 2. Project references resolve to real, non-empty files
    print("\n[2] Project references")
    refs = pbxproj_file_refs()
    all_swift_rel = [os.path.relpath(f, ROOT) for f in swift_files(APP_DIR) + swift_files(TEST_DIR)]
    # References in the pbxproj are group-relative (e.g. "PathSafety.swift"
    # for SalmanMacCleaner/Core/PathSafety.swift), so resolve by suffix match
    # and require a unique hit.
    missing: list[str] = []
    for ref in refs:
        hits = [f for f in all_swift_rel if os.path.basename(f) == ref]
        if len(hits) != 1:
            missing.append(ref)
    check(not missing, f"{len(refs)} Swift file reference(s) checked", f"references to missing/ambiguous files: {missing}")
    empty = [r for r in refs if any(os.path.getsize(os.path.join(ROOT, f)) == 0 for f in all_swift_rel if os.path.basename(f) == r)]
    check(not empty, "no zero-byte referenced files", f"zero-byte referenced files: {empty}")

    # 3. All Swift files on disk are non-empty
    print("\n[3] Swift sources")
    all_swift = swift_files(APP_DIR) + swift_files(TEST_DIR)
    check(len(all_swift) >= 30, f"{len(all_swift)} Swift file(s) found", "suspiciously few Swift files")
    zero = [f for f in all_swift if os.path.getsize(f) == 0]
    check(not zero, "no zero-byte Swift source", f"zero-byte Swift files: {zero}")
    all_swift_rel = [os.path.relpath(f, ROOT) for f in all_swift]
    unreferenced = [f for f in all_swift_rel if not any(os.path.basename(f) == ref for ref in refs)]
    if unreferenced:
        warning(f"Swift files not referenced by pbxproj: {unreferenced}")
    else:
        print("  ✓ every Swift file is referenced by the project")

    # 4. Required artifacts
    print("\n[4] Required artifacts")
    artifacts = [
        (os.path.join(APP_DIR, "Assets.xcassets", "AppIcon.appiconset", "Contents.json"), "App icon set"),
        (os.path.join(APP_DIR, "Assets.xcassets", "AccentColor.colorset", "Contents.json"), "Accent color"),
        (os.path.join(APP_DIR, "Info.plist"), "Info.plist"),
        (os.path.join(APP_DIR, "SalmanMacCleaner.entitlements"), "Entitlements"),
        (os.path.join(APP_DIR, "en.lproj", "Localizable.strings"), "Localizable.strings"),
        (os.path.join(ROOT, "README.md"), "README.md"),
        (os.path.join(ROOT, "SECURITY.md"), "SECURITY.md"),
        (os.path.join(ROOT, "LICENSE"), "LICENSE"),
        (os.path.join(ROOT, "CHANGELOG.md"), "CHANGELOG.md"),
        (os.path.join(ROOT, "FILE_MANIFEST.md"), "FILE_MANIFEST.md"),
    ]
    for path, label in artifacts:
        check(os.path.isfile(path) and os.path.getsize(path) > 0, f"{label} present", f"{label} missing or empty: {path}")

    # 5. No placeholders
    print("\n[5] Placeholder scan")
    placeholder_patterns = [
        (r"\bTODO\b", "TODO"),
        (r"\bFIXME\b", "FIXME"),
        (r"\bfatalError\s*\(", "fatalError"),
        (r"placeholder\s*implementation", "placeholder implementation"),
        (r"//\s*not\s+implemented", "not implemented"),
        # Empty button actions (role-carrying buttons are legitimate).
        (r"Button\((?![^)]*\brole\b)[^)]*\)\s*\{\s*\}", "empty button action"),
        (r"\.onTapGesture\s*\{\s*\}", "empty tap gesture"),
    ]
    scanned = 0
    section_errors: list[str] = []
    for path in all_swift:
        with open(path, "r", encoding="utf-8") as handle:
            content = strip_comments_and_strings(handle.read())
        scanned += 1
        for pattern, label in placeholder_patterns:
            if re.search(pattern, content):
                section_errors.append(f"{os.path.relpath(path, ROOT)} contains {label!r}")
    for item in section_errors:
        error(item)
    check(not section_errors, f"{scanned} file(s) scanned for placeholders", "placeholder code found (see above)")

    # 6. Forbidden APIs
    print("\n[6] Forbidden API scan")
    forbidden = [
        (r"\bsudo\b", "sudo"),
        (r"\brm\s+-", "rm flags"),
        (r"\brm\s+\"", "rm command"),
        (r"\brmdir\b", "rmdir"),
        (r"\bunlink\s*\(", "unlink()"),
        (r"\bProcess\s*\(", "Process()"),
        (r"\bNSTask\b", "NSTask"),
        (r"\bsystem\s*\(\s*\"", "system() shell call"),
        (r"\bpopen\s*\(", "popen()"),
        (r"\b/bin/(ba|z|k|c)?sh\b", "shell path"),
        (r"URLSession", "URLSession (network)"),
        (r"NWConnection", "Network framework"),
        (r"\bcurl\b", "curl"),
        (r"\bwget\b", "wget"),
        (r"removeItem\(at.*permanent", "permanent removal"),
        (r"emptyTrash", "emptyTrash"),
    ]
    section_errors = []
    for path in all_swift:
        if TEST_DIR in path:
            continue  # tests may reference forbidden APIs to assert their absence/behavior
        with open(path, "r", encoding="utf-8") as handle:
            content = strip_comments_and_strings(handle.read())
        for pattern, label in forbidden:
            if re.search(pattern, content):
                section_errors.append(f"{os.path.relpath(path, ROOT)} contains forbidden API {label!r}")
    for item in section_errors:
        error(item)
    check(not section_errors, "app sources free of forbidden APIs", "forbidden APIs found (see above)")

    # 7. Localization keys referenced by views exist in the strings file
    print("\n[7] Localization coverage")
    strings_path = os.path.join(APP_DIR, "en.lproj", "Localizable.strings")
    with open(strings_path, "r", encoding="utf-8") as handle:
        strings = handle.read()
    defined_keys = set(re.findall(r'^"([^"]+)"\s*=', strings, flags=re.MULTILINE))
    used_keys: set[str] = set()
    for path in all_swift:
        if TEST_DIR in path:
            continue
        with open(path, "r", encoding="utf-8") as handle:
            content = handle.read()
        used_keys.update(re.findall(r'NSLocalizedString\("([^"]+)"', content))
        used_keys.update(re.findall(r'Text\("([a-z][a-z0-9_.]+)"\)', content))
        used_keys.update(re.findall(r'LocalizedStringKey\("([a-z][a-z0-9_.]+)"\)', content))
    missing = sorted(k for k in used_keys if k not in defined_keys and not k.startswith(("%", "@")))
    if missing:
        warning(f"localization keys used but not defined: {missing}")
    else:
        print(f"  ✓ all {len(used_keys)} used key(s) defined in Localizable.strings")

    # Summary
    print()
    if ERRORS:
        print(f"FAILED — {len(ERRORS)} error(s), {len(WARNINGS)} warning(s)")
        for item in ERRORS:
            print(f"  ERROR: {item}")
        return 1
    print(f"PASSED — all checks passed ({len(WARNINGS)} warning(s))")
    for item in WARNINGS:
        print(f"  warning: {item}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
