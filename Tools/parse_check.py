#!/usr/bin/env python3
"""
parse_check.py — syntax-parse every Swift file in the repository using the
tree-sitter Swift grammar. Reports ERROR or MISSING nodes per file.

Usage: /tmp/tsenv/bin/python Tools/parse_check.py
"""

from __future__ import annotations

import os
import sys

from tree_sitter import Language, Parser
import tree_sitter_swift

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SWIFT_LANGUAGE = Language(tree_sitter_swift.language())
PARSER = Parser(SWIFT_LANGUAGE)


def collect_problems(node, path: str, problems: list[str], depth: int = 0) -> None:
    if node.type == "ERROR" or node.is_missing:
        row, col = node.start_point
        snippet = node.text[:120].decode("utf-8", "replace").replace("\n", "\\n") if node.text else ""
        problems.append(f"  {path}:{row + 1}:{col + 1} [{node.type}] {snippet}")
        if depth > 2:
            return
    for child in node.children:
        collect_problems(child, path, problems, depth + 1)


def main() -> int:
    problems: list[str] = []
    total = 0
    for dirpath, _dirnames, filenames in os.walk(ROOT):
        if "xcodeproj" in dirpath:
            continue
        for name in sorted(filenames):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            total += 1
            with open(path, "r", encoding="utf-8") as handle:
                source = handle.read()
            tree = PARSER.parse(source.encode("utf-8"))
            collect_problems(tree.root_node, os.path.relpath(path, ROOT), problems)

    print(f"Parsed {total} Swift files.")
    if problems:
        print(f"FOUND {len(problems)} syntax problem(s):")
        for problem in problems:
            print(problem)
        return 1
    print("No syntax errors detected by tree-sitter Swift grammar.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
