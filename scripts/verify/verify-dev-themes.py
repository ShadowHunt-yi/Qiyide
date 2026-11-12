#!/usr/bin/env python3
"""Validate real bundle resources, not only source compilation. Read-only."""
import hashlib
import json
import sys
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
app = Path(sys.argv[1]).resolve()
source = repo / "DefaultThemes"
bundled = app / "Contents/Resources/DefaultThemes"
expected = sorted(source.glob("*.cetheme"))
if not expected or not bundled.is_dir():
    raise SystemExit(f"❌ Missing bundled DefaultThemes: {bundled}")
appearances = set()
for path in expected:
    target = bundled / path.name
    if not target.is_file() or hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(target.read_bytes()).digest():
        raise SystemExit(f"❌ Missing or stale bundled theme: {path.name}")
    data = json.loads(target.read_text())
    if not data.get("name") or data.get("type") not in {"light", "dark"} or not data.get("editor") or not data.get("terminal"):
        raise SystemExit(f"❌ Invalid bundled theme: {path.name}")
    appearances.add(data["type"])
if appearances != {"light", "dark"}:
    raise SystemExit("❌ Both light and dark bundled themes are required")
print(f"✅ DefaultThemes verified: {len(expected)} exact resource files, light and dark")
