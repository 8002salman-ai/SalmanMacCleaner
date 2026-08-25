#!/usr/bin/env python3
"""
xref_check.py — coarse cross-reference sanity check.

For each Swift file, extract `TypeName.memberName` reference pairs (heuristic:
capitalized identifier followed by `.` and a lowercase identifier) and verify
the member is *declared* somewhere in the file that declares the type.
Catches typos like `vm.fooBar` where the property is `fooBaz`.

This is a heuristic complement to the tree-sitter parse check, not a
type checker.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REF_RE = re.compile(r"\b([A-Z][A-Za-z0-9]*)\.([a-z][A-Za-z0-9_]*)\b")
DECL_RE = re.compile(r"\b(?:func|var|let|static func|static var|static let|case|init)\s+([A-Za-z0-9_]+)")

# Known SwiftUI / Foundation / AppKit member access that our heuristic will
# flag spuriously because the "type" is actually a framework type.
EXTERNAL_TYPES = {
    "FileManager", "URL", "NSHomeDirectory", "NSWorkspace", "Data", "Date",
    "UUID", "Bundle", "Scanner", "Task", "MainActor", "ISO8601DateFormatter",
    "ByteCountFormatter", "JSONEncoder", "JSONDecoder", "UserDefaults",
    "PathSafety",  # special-cased below anyway (declared in its own file)
}


def main() -> int:
    files = {}
    for dirpath, _dirnames, filenames in os.walk(ROOT):
        if "xcodeproj" in dirpath:
            continue
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            with open(path, "r", encoding="utf-8") as handle:
                files[os.path.relpath(path, ROOT)] = handle.read()

    # index of declared members per type per file, plus the full type stack
    # at every declaration position (handles nested types).
    declared: dict[tuple[str, str], set[str]] = {}
    type_positions: dict[str, list[tuple[int, str]]] = {}
    for rel, content in files.items():
        type_positions[rel] = []
        for type_match in re.finditer(r"\b(?:public |private |internal |final |@MainActor\s*)*(?:struct|class|enum|actor)\s+([A-Z][A-Za-z0-9_]*)\b", content):
            type_positions[rel].append((type_match.start(), type_match.group(1)))
        for decl in DECL_RE.finditer(content):
            member = decl.group(1)
            prefix = content[: decl.start()]
            type_matches = re.findall(r"\b(?:public |private |internal |final |@MainActor\s*)*(?:struct|class|enum|actor)\s+([A-Z][A-Za-z0-9_]*)\b", prefix)
            if not type_matches:
                continue
            owner = type_matches[-1]
            declared.setdefault((rel, owner), set()).add(member)

    SYNTHESIZED = {"allCases", "init", "rawValue", "self", "id", "title"}
    problems: list[str] = []
    for rel, content in files.items():
        line_starts = [0]
        for m in re.finditer(r"\n", content):
            line_starts.append(m.end())
        for match in REF_RE.finditer(content):
            type_name, member = match.group(1), match.group(2)
            # skip references inside comments
            line_index = 0
            for i, start in enumerate(line_starts):
                if start > match.start(0):
                    line_index = i - 1
                    break
            line_end = line_starts[line_index + 1] if line_index + 1 < len(line_starts) else len(content)
            line = content[line_starts[line_index]:line_end]
            if line.lstrip().startswith("//"):
                continue
            if type_name in EXTERNAL_TYPES:
                continue
            if member in SYNTHESIZED:
                continue
            # ignore Swift builtins and common names
            if type_name in {"CGFloat", "Double", "Int", "String", "Bool", "URLSession", "LocalizedStringKey", "Text", "Color"}:
                continue
            # where is this type declared?
            locations = [(r, o) for (r, o) in declared if o == type_name]
            if not locations:
                continue  # framework type or cross-module; can't verify
            if any(member in declared[(r, o)] for (r, o) in locations):
                continue
            # Nested-type tolerance: the member may be attributed to a nested
            # type by the heuristic while belonging to an enclosing one.
            declaring_files = {r for (r, o) in locations}
            if any(member in members for (r, o), members in declared.items() if r in declaring_files):
                continue
            problems.append(f"{rel}:{match.start(0)} — {type_name}.{member} not found in declaration of {type_name}")

    print(f"Checked {len(files)} files for member references.")
    if problems:
        for problem in problems[:60]:
            print("  ?", problem)
        print(f"{len(problems)} suspicious reference(s)")
        return 1
    print("No suspicious member references found (heuristic).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
