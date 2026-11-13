"""Generate app/lib/core/normalization_rules.g.dart from shared/normalization/sk_rules.json.

Usage:
    python tools/common/gen_dart_rules.py           # write the file
    python tools/common/gen_dart_rules.py --check   # exit 1 if the file is stale
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "shared" / "normalization" / "sk_rules.json"
DST = ROOT / "app" / "lib" / "core" / "normalization_rules.g.dart"


def dart_str(s: str) -> str:
    out = []
    for ch in s:
        if ch in ("\\", "'", "$"):
            out.append("\\" + ch)
        elif ord(ch) < 0x80:
            out.append(ch)
        else:
            out.append("\\u{%x}" % ord(ch))
    return "'" + "".join(out) + "'"


def dart_list(items: list[str]) -> str:
    return "[" + ", ".join(dart_str(i) for i in items) + "]"


def dart_map(items: dict[str, str]) -> str:
    body = "".join(f"  {dart_str(k)}: {dart_str(v)},\n" for k, v in items.items())
    return "{\n" + body + "}"


def render() -> str:
    r = json.loads(SRC.read_text(encoding="utf-8"))
    return f"""// GENERATED FILE - DO NOT EDIT.
// Source: shared/normalization/sk_rules.json
// Regenerate: python tools/common/gen_dart_rules.py

const int kNormRulesVersion = {r["version"]};

const Map<String, String> kNormCompose = {dart_map(r["compose"])};

const List<String> kNormUnits = {dart_list(r["units"])};

const List<String> kNormTeens = {dart_list(r["teens"])};

const List<String> kNormTens = {dart_list(r["tens"])};

const String kNormHundred = {dart_str(r["hundred"])};
const String kNormThousand = {dart_str(r["thousand"])};
const String kNormMillion = {dart_str(r["million"])};

const Map<String, String> kNormVariants = {dart_map(r["variants"])};

const int kNormMaxSpelledDigits = {r["max_spelled_digits"]};
"""


def main() -> int:
    text = render()
    if "--check" in sys.argv:
        current = DST.read_text(encoding="utf-8") if DST.exists() else ""
        if current != text:
            print(f"STALE: {DST} does not match {SRC}. Run this script without --check.")
            return 1
        print("up to date")
        return 0
    DST.parent.mkdir(parents=True, exist_ok=True)
    DST.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {DST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
