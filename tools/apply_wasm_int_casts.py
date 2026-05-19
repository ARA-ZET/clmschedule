#!/usr/bin/env python3
"""
Pass 3: Convert `as int` and `as int?` to num-then-toInt on Firestore reads.

WASM strictly enforces numeric type casts. Firestore web SDK returns all
numeric fields as double on WASM, breaking `as int` / `as int?` casts.

Replacements (regex):
  EXPR as int?   ->  (EXPR as num?)?.toInt()
  EXPR as int    ->  (EXPR as num).toInt()

Where EXPR is a simple identifier or indexed/member expression, no parens.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'lib')

EXPR = r"(?P<expr>[A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*|\[[^\[\]\n]+\]|!)*)"

PAT_NULLABLE = re.compile(EXPR + r"\s+as\s+int\?")
PAT_NONNULL  = re.compile(EXPR + r"\s+as\s+int\b(?!\?)")

def patch(text: str) -> tuple[str, int]:
    n = 0
    def rn(m: re.Match) -> str:
        nonlocal n
        n += 1
        return f"({m.group('expr')} as num?)?.toInt()"
    def rnn(m: re.Match) -> str:
        nonlocal n
        n += 1
        return f"({m.group('expr')} as num).toInt()"
    text = PAT_NULLABLE.sub(rn, text)
    text = PAT_NONNULL.sub(rnn, text)
    return text, n

def main() -> int:
    total = 0
    for dirpath, _, files in os.walk(LIB):
        for f in files:
            if not f.endswith('.dart'):
                continue
            p = os.path.join(dirpath, f)
            with open(p, 'r', encoding='utf-8') as fh:
                src = fh.read()
            new, n = patch(src)
            if n and new != src:
                with open(p, 'w', encoding='utf-8') as fh:
                    fh.write(new)
                print(f"patched: {os.path.relpath(p, ROOT)} (+{n})")
                total += n
    print(f"Total: {total}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
