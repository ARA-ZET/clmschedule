#!/usr/bin/env python3
"""Apply WASM-safe Firestore data extraction across the codebase."""
import re
import os
from pathlib import Path

ROOT = Path(__file__).parent.parent / "lib"

# Order matters: nullable-with-default first, then nullable, then non-null.
PATTERNS = [
    # `xxx.data() as Map<String, dynamic>? ?? {}`
    (re.compile(r"(\b[\w\.\[\]]+)\.data\(\)\s+as\s+Map<String,\s*dynamic>\?\s*\?\?\s*\{\}"),
     r"Map<String, dynamic>.from((\1.data() as Map?) ?? <String, dynamic>{})"),
    # `xxx.data() as Map<String, dynamic>?`
    (re.compile(r"(\b[\w\.\[\]]+)\.data\(\)\s+as\s+Map<String,\s*dynamic>\?"),
     r"(\1.data() == null ? null : Map<String, dynamic>.from(\1.data() as Map))"),
    # `xxx.data() as Map<String, dynamic>`
    (re.compile(r"(\b[\w\.\[\]]+)\.data\(\)\s+as\s+Map<String,\s*dynamic>"),
     r"Map<String, dynamic>.from(\1.data() as Map)"),
]

total = 0
for dart_file in ROOT.rglob("*.dart"):
    if "firestore_wasm_compat.dart" in str(dart_file):
        continue
    text = dart_file.read_text()
    original = text
    for pat, repl in PATTERNS:
        text = pat.sub(repl, text)
    if text != original:
        count = sum(1 for _ in re.finditer(r"Map<String, dynamic>\.from", text)) - \
                sum(1 for _ in re.finditer(r"Map<String, dynamic>\.from", original))
        total += count
        dart_file.write_text(text)
        print(f"  patched: {dart_file.relative_to(ROOT.parent)} (+{count})")

print(f"\nTotal replacements: {total}")
