#!/usr/bin/env python3
"""Fail on a relative link that points at nothing.

Cheap insurance for the wiki mirror: a broken relative link in docs/ becomes a
broken wiki page, and the mirror is generated so nobody would notice by editing
it. Also catches the ordinary case of a doc renamed without its inbound links.

Checks paths, and anchors within the repository's own markdown. Does not touch
the network, so external URLs are not verified.

    scripts/check-doc-links.py
"""

from __future__ import annotations

import posixpath
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN = ["README.md", "CONTRIBUTING.md", "CLAUDE.md", "CHANGELOG.md",
        "Kit/README.md", "Kit/components/README.md",
        "Kit/packs/pip/README.md", "Kit/packs/caret/README.md",
        "Apps/README.md"]

LINK = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*$", re.MULTILINE)


def slug(heading: str) -> str:
    """GitHub's anchor rules: lowercase, strip punctuation, spaces to dashes."""
    text = re.sub(r"`([^`]*)`", r"\1", heading)          # inline code
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links
    text = re.sub(r"[*_]", "", text)                      # emphasis
    text = text.strip().lower()
    text = re.sub(r"[^\w\s-]", "", text)
    return re.sub(r"\s+", "-", text)


def anchors(path: Path) -> set[str]:
    return {slug(h) for h in HEADING.findall(path.read_text())}


def main() -> int:
    files = [ROOT / name for name in SCAN if (ROOT / name).exists()]
    files += sorted((ROOT / "docs").rglob("*.md"))

    anchor_cache: dict[Path, set[str]] = {}
    problems: list[str] = []

    for source in files:
        rel = source.relative_to(ROOT).as_posix()
        for target in LINK.findall(source.read_text()):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue

            path, _, anchor = target.partition("#")
            if not path:
                continue

            resolved = ROOT / posixpath.normpath(
                posixpath.join(posixpath.dirname(rel), path)
            )
            if not resolved.exists():
                problems.append(f"{rel}: no such file -> {target}")
                continue

            if anchor and resolved.suffix == ".md":
                if resolved not in anchor_cache:
                    anchor_cache[resolved] = anchors(resolved)
                if anchor.lower() not in anchor_cache[resolved]:
                    problems.append(f"{rel}: no such heading -> {target}")

    if problems:
        print("Broken documentation links:\n", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"\n{len(problems)} problem(s) in {len(files)} files.", file=sys.stderr)
        return 1

    print(f"check-doc-links: {len(files)} files, all relative links resolve")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
