#!/usr/bin/env python3
"""Render docs/ as a GitHub wiki tree.

The wiki is a mirror, never a source: docs/ in the repository is the truth and
this script is what makes the wiki agree with it. Run by
.github/workflows/docs.yml on every merge to main.

GitHub wikis are flat — every page is one file at the root, and directories in
the source tree have to become part of the page name. So `docs/concepts/QUEUE.md`
becomes the page `Concepts-Queue`, and every relative link that pointed at it has
to be rewritten to match. Links out of docs/ (to source files, to CONTRIBUTING)
become absolute URLs, because the wiki has no view of the repository.

    scripts/sync-wiki.py --out build/wiki [--repo Salable/motive] [--ref main]
"""

from __future__ import annotations

import argparse
import posixpath
import re
import shutil
import sys
from pathlib import Path

# Words that read wrong title-cased. "API.md" is the page API, not Api.
ACRONYMS = {"API", "CLI", "MCP", "HTTP", "UI", "REST", "DOCC", "URL", "JSON"}

LINK = re.compile(r"(!?)\[([^\]]*)\]\(([^)\s]+)(\s+\"[^\"]*\")?\)")


def page_name(rel: str) -> str:
    """docs-relative path -> wiki page name. `README.md` is the wiki's Home."""
    if rel == "README.md":
        return "Home"
    parts = Path(rel).with_suffix("").parts
    out = []
    for part in parts:
        out.append("-".join(w if w.upper() in ACRONYMS else w.capitalize()
                            for w in part.split("-")))
    return "-".join(out)


def collect(docs: Path) -> dict[str, str]:
    """repo-relative markdown path -> wiki page name."""
    return {
        f"docs/{p.relative_to(docs).as_posix()}": page_name(p.relative_to(docs).as_posix())
        for p in sorted(docs.rglob("*.md"))
    }


def rewrite(text: str, source: str, pages: dict[str, str], repo: str, ref: str) -> str:
    """Repoint every relative link in one file at its wiki equivalent."""
    blob = f"https://github.com/{repo}/blob/{ref}"
    raw = f"https://raw.githubusercontent.com/{repo}/{ref}"
    source_dir = posixpath.dirname(source)

    def sub(m: re.Match[str]) -> str:
        bang, label, target, title = m.group(1), m.group(2), m.group(3), m.group(4) or ""
        if target.startswith(("http://", "https://", "mailto:", "#")):
            return m.group(0)

        path, _, anchor = target.partition("#")
        anchor = f"#{anchor}" if anchor else ""
        if not path:  # bare in-page anchor
            return m.group(0)

        resolved = posixpath.normpath(posixpath.join(source_dir, path))
        if bang:  # images have no wiki equivalent; serve them from the repo
            return f"![{label}]({raw}/{resolved}{title})"
        if resolved in pages:
            return f"[{label}]({pages[resolved]}{anchor}{title})"
        return f"[{label}]({blob}/{resolved}{anchor}{title})"

    return LINK.sub(sub, text)


def sidebar(pages: dict[str, str]) -> str:
    """Group pages by their source directory, in reading order."""
    order = ["", "guides", "concepts", "components", "reference", "proposals"]
    titles = {
        "": "Motive", "guides": "Guides", "concepts": "Concepts",
        "components": "Components", "reference": "Reference",
        "proposals": "Proposals",
    }
    groups: dict[str, list[tuple[str, str]]] = {k: [] for k in order}
    for path, name in pages.items():
        folder = posixpath.dirname(path[len("docs/"):])
        groups.setdefault(folder, []).append((path, name))

    lines = ["### Motive", ""]
    for folder in order:
        # Home leads the root group; everything else is alphabetical.
        entries = sorted(groups.get(folder, []), key=lambda e: (e[1] != "Home", e[1]))
        if not entries:
            continue
        if folder:
            lines += [f"**{titles[folder]}**", ""]
        for _, name in entries:
            label = "Home" if name == "Home" else name.split("-", 1)[-1].replace("-", " ")
            lines.append(f"- [[{label}|{name}]]")
        lines.append("")
    lines += ["---", "", "[API reference](https://salable.github.io/motive/documentation/motivecore)",
              "", "_Mirrored from `docs/`. Edits here are overwritten._"]
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--docs", default="docs")
    ap.add_argument("--out", required=True)
    ap.add_argument("--repo", default="Salable/motive")
    ap.add_argument("--ref", default="main")
    args = ap.parse_args()

    docs = Path(args.docs)
    if not docs.is_dir():
        print(f"sync-wiki: no such directory: {docs}", file=sys.stderr)
        return 1

    out = Path(args.out)
    if out.exists():
        for stale in out.glob("*.md"):
            stale.unlink()
    out.mkdir(parents=True, exist_ok=True)

    pages = collect(docs)
    for path, name in pages.items():
        source = docs / path[len("docs/"):]
        body = rewrite(source.read_text(), path, pages, args.repo, args.ref)
        (out / f"{name}.md").write_text(body)

    (out / "_Sidebar.md").write_text(sidebar(pages))
    print(f"sync-wiki: {len(pages)} pages -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
