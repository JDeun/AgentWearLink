#!/usr/bin/env python3
"""Offline documentation checker: links, fences, and Mermaid structure.

This is a structural check, not a full Mermaid rendering engine.
"""

import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SKIP = {".git", ".build", "node_modules", ".awl-hermetic-upstream"}
FENCE = re.compile(r"^\s*([`~]{3,})([A-Za-z0-9_-]*)\s*$")
LINK = re.compile(r"(?<!!)\[[^\]\n]+\]\(([^)\n]+)\)")
DIAGRAM_HEAD = re.compile(
    r"^(?:flowchart[ \t]+(?:LR|RL|TB|TD|BT)|"
    r"graph[ \t]+(?:LR|RL|TB|TD|BT)|"
    r"sequenceDiagram|stateDiagram-v2|classDiagram|erDiagram|gantt|pie|journey|gitGraph|mindmap|timeline)"
)
ASCII = re.compile(r"[┌┐└┘├┤│▼↓]")

def check(path):
    errors = []
    lines = path.read_text(encoding="utf-8").splitlines()
    active = None
    source = []
    diagrams = 0
    for lineno, line in enumerate(lines, 1):
        match = FENCE.fullmatch(line)
        if active is None and match:
            active = (match.group(1), match.group(2))
            source = []
        elif active and re.fullmatch(
            rf"\s*{re.escape(active[0][0])}{{{len(active[0])},}}\s*", line
        ):
            if active[1] == "mermaid":
                diagrams += 1
                meaningful = [x.strip() for x in source if x.strip() and not x.lstrip().startswith("%%")]
                if not meaningful or not DIAGRAM_HEAD.match(meaningful[0]):
                    errors.append(f"{path.relative_to(ROOT)}:{lineno}: invalid Mermaid opening")
                if meaningful and meaningful[0].startswith(("flowchart ", "graph ")):
                    groups = sum(x.startswith("subgraph ") for x in meaningful)
                    ends = sum(x == "end" for x in meaningful)
                    if groups != ends:
                        errors.append(f"{path.relative_to(ROOT)}:{lineno}: subgraph/end mismatch")
            if active[1] == "text" and ASCII.search("\n".join(source)):
                errors.append(f"{path.relative_to(ROOT)}:{lineno}: ASCII diagram should be Mermaid")
            active = None
        elif active:
            source.append(line)
    if active:
        errors.append(f"{path.relative_to(ROOT)}: unclosed code fence")

    contents = "\n".join(lines)
    for match in LINK.finditer(contents):
        target = match.group(1).strip()
        if not target or target.startswith("#"):
            continue
        if target.startswith("<") and ">" in target:
            target = target[1:target.index(">")]
        else:
            target = target.split(' "')[0].split(" '")[0]
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or target.startswith("//"):
            continue
        fragmentless = unquote(parsed.path)
        if not fragmentless or "{" in fragmentless or "}" in fragmentless:
            continue
        absolute = (path.parent / fragmentless).resolve()
        if not absolute.is_relative_to(ROOT) or not absolute.exists():
            errors.append(f"{path.relative_to(ROOT)}: invalid local link: {target}")
    return errors, diagrams

def main():
    files = sorted(
        path for path in ROOT.rglob("*.md")
        if not SKIP.intersection(path.relative_to(ROOT).parts)
    )
    errors = []
    total = 0
    for path in files:
        failures, diagrams = check(path)
        errors.extend(failures)
        total += diagrams
    if total < 14:
        errors.append(f"expected at least 14 Mermaid diagrams; found {total}")
    if errors:
        for issue in errors:
            print("DOCS ERROR:", issue, file=sys.stderr)
        return 1
    print(f"Docs OK: {len(files)} Markdown files, {total} Mermaid diagrams; links/fences checked.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
