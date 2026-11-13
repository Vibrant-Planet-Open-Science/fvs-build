#!/usr/bin/env python3
"""Fail unless every copy of the default FVS and Interface refs agrees.

Groups: source_ref+image_tag (FVS), interface_ref (Interface); skips `${{…}}`,
`...` and `ci-` tags.
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

GROUPS = {"source_ref": "FVS", "image_tag": "FVS", "interface_ref": "Interface"}
KEYS = "|".join(GROUPS)
LITERAL = re.compile(rf"\b({KEYS})[:=]\s*\"?([\w.-]+)")
BARE_KEY = re.compile(r"^\s*(\w+):\s*$")
DEFAULT = re.compile(r"^\s*default:\s*\"?([\w.-]+)\"?\s*$")


def main() -> int:
    """Print each group whose copies disagree; return 1 if any do."""
    root = Path(__file__).resolve().parents[2]
    found: dict[str, list[tuple[str, str]]] = defaultdict(list)
    files = [
        *sorted(root.glob(".github/workflows/*.yml")),
        root / "README.md",
        *sorted(root.glob("docs/*.md")),
    ]
    for path in files:
        block = None
        for n, line in enumerate(path.read_text().splitlines(), 1):
            where = f"{path.relative_to(root)}:{n}"
            if m := BARE_KEY.match(line):
                block = m[1]
            elif (m := DEFAULT.match(line)) and block in GROUPS:
                found[GROUPS[block]].append((m[1], where))
            for key, value in LITERAL.findall(line):
                if not value.startswith(("ci-", ".")):
                    found[GROUPS[key]].append((value, where))
    bad = [g for g, hits in found.items() if len({v for v, _ in hits}) > 1]
    for group in bad:
        print(f"{group} default refs disagree:")
        for value, where in found[group]:
            print(f"  {where}: {value}")
    return int(bool(bad))


if __name__ == "__main__":
    sys.exit(main())
