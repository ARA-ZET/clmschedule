#!/usr/bin/env python3
"""
Pass 2: Convert remaining `as Map<String, dynamic>` (incl. nullable) sites
to WASM-safe `Map<String, dynamic>.from(... as Map)` form.

Targets nested maps from Firestore (lists of maps, sub-map fields), which
fail strict casts on dart2wasm because Firestore web SDK returns
Map<Object?, Object?>.

Skips lines where the source is clearly a jsonDecode (those are real
Map<String, dynamic>) — but wrapping is harmless, so we do NOT skip.

Patterns handled (in order):
  1. `EXPR as Map<String, dynamic>?`  ->  `(EXPR == null ? null : Map<String, dynamic>.from(EXPR as Map))`
     where EXPR is a simple identifier or indexed expression (no balanced complexity needed).
  2. `EXPR as Map<String, dynamic>`   ->  `Map<String, dynamic>.from(EXPR as Map)`

We use a regex that captures the immediately-preceding expression token. We
preserve the leading whitespace/indent.

For nullable variant, we duplicate EXPR; this is safe because we only match
simple expressions (identifier optional . chain or [..] index, no parens
function calls — those will require manual review).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'lib')

# Match an expression that ends right before " as Map<String, dynamic>".
# Allow identifiers, dots, ?., [..] indexing, ! suffix. No parens.
EXPR = r"(?P<expr>[A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*|\[[^\[\]\n]+\]|!)*)"

PAT_NULLABLE = re.compile(EXPR + r"\s+as\s+Map<String,\s*dynamic>\?")
PAT_NONNULL  = re.compile(EXPR + r"\s+as\s+Map<String,\s*dynamic>(?!\?)")

# Also handle `X as List<dynamic>` -> `X as List` (safer on WASM); usually
# not the failure, but cheap and consistent.
PAT_LIST = re.compile(EXPR + r"\s+as\s+List<dynamic>(?!\?)")

def patch(text: str) -> tuple[str, int]:
    n = 0
    def rep_nullable(m: re.Match) -> str:
        nonlocal n
        n += 1
        e = m.group('expr')
        return f"({e} == null ? null : Map<String, dynamic>.from({e} as Map))"
    def rep_nonnull(m: re.Match) -> str:
        nonlocal n
        n += 1
        e = m.group('expr')
        return f"Map<String, dynamic>.from({e} as Map)"
    text = PAT_NULLABLE.sub(rep_nullable, text)
    text = PAT_NONNULL.sub(rep_nonnull, text)
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
                rel = os.path.relpath(p, ROOT)
                print(f"patched: {rel} (+{n})")
                total += n
    print(f"Total replacements: {total}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
