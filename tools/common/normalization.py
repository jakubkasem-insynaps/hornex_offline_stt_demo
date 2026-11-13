"""Slovak transcript normalization for scoring.

This is the Python twin of app/lib/core/normalization.dart. Both read the same
rule data (shared/normalization/sk_rules.json) and must pass the same test
vectors (shared/normalization/test_vectors.json). Keep the two in step.

Steps, in order:
  1. lowercase
  2. compose base letter + combining mark into one code point (rule table)
  3. join thousands groups written with a space / NBSP / dot ("10 000" -> "10000")
  4. replace everything that is not a Unicode letter or number with a space
  5. split on whitespace
  6. spell out pure-digit tokens in Slovak ("21" -> "dvadsať jeden")
  7. split compound numerals into the same atoms ("dvadsaťjeden" -> "dvadsať jeden")
  8. map gender/plural variants of numerals to one form ("dve" -> "dva")
  9. join with single spaces

Slovak diacritics are kept. Not handled: ordinals ("1." vs "prvý"), decimals,
dates, times and declined numerals ("dvoch", "troch").
"""
from __future__ import annotations

import json
import re
import unicodedata
from pathlib import Path

_RULES_PATH = Path(__file__).resolve().parents[2] / "shared" / "normalization" / "sk_rules.json"
_RULES = json.loads(_RULES_PATH.read_text(encoding="utf-8"))

_COMPOSE: dict[str, str] = _RULES["compose"]
_UNITS: list[str] = _RULES["units"]
_TEENS: list[str] = _RULES["teens"]
_TENS: list[str] = _RULES["tens"]
_HUNDRED: str = _RULES["hundred"]
_THOUSAND: str = _RULES["thousand"]
_MILLION: str = _RULES["million"]
_VARIANTS: dict[str, str] = _RULES["variants"]
_MAX_DIGITS: int = _RULES["max_spelled_digits"]

# Words a compound numeral may be built from. "nula" is excluded on purpose.
_ATOMS: list[str] = sorted(
    set(_UNITS[1:]) | set(_TEENS) | {t for t in _TENS if t} | {_HUNDRED, _THOUSAND}
    | {v for v in _VARIANTS if v not in ("milióny", "miliónov")},
    key=lambda w: (-len(w), w),
)

_THOUSANDS_GROUP = re.compile(r"(?<![0-9])[0-9]{1,3}(?:[  .][0-9]{3})+(?![0-9])")
_ASCII_DIGITS = re.compile(r"[0-9]+")


def _compose(text: str) -> str:
    for pair, single in _COMPOSE.items():
        if pair in text:
            text = text.replace(pair, single)
    return text


def _below_1000(n: int) -> list[str]:
    out: list[str] = []
    h, r = divmod(n, 100)
    if h == 1:
        out.append(_HUNDRED)
    elif h > 1:
        out += [_UNITS[h], _HUNDRED]
    if r == 0:
        return out
    if r < 10:
        out.append(_UNITS[r])
    elif r < 20:
        out.append(_TEENS[r - 10])
    else:
        out.append(_TENS[r // 10])
        if r % 10:
            out.append(_UNITS[r % 10])
    return out


def spell_number(digits: str) -> list[str]:
    """Spell a string of ASCII digits as canonical Slovak numeral atoms."""
    if len(digits) > _MAX_DIGITS or (len(digits) > 1 and digits[0] == "0"):
        return [_UNITS[int(d)] for d in digits]
    n = int(digits)
    if n == 0:
        return [_UNITS[0]]
    out: list[str] = []
    millions, rest = divmod(n, 1_000_000)
    thousands, rest = divmod(rest, 1000)
    if millions == 1:
        out.append(_MILLION)
    elif millions > 1:
        out += _below_1000(millions) + [_MILLION]
    if thousands == 1:
        out.append(_THOUSAND)
    elif thousands > 1:
        out += _below_1000(thousands) + [_THOUSAND]
    out += _below_1000(rest)
    return out


def _split_compound(word: str) -> list[str] | None:
    """Split `word` into numeral atoms if it consists of two or more of them."""
    n = len(word)
    # best[i] = fewest atoms covering word[i:], or None if impossible
    best: list[list[str] | None] = [None] * (n + 1)
    best[n] = []
    for i in range(n - 1, -1, -1):
        for atom in _ATOMS:
            if word.startswith(atom, i):
                tail = best[i + len(atom)]
                if tail is not None and (best[i] is None or len(tail) + 1 < len(best[i])):
                    best[i] = [atom] + tail
    result = best[0]
    if result is None or len(result) < 2:
        return None
    return result


def _is_letter_or_number(ch: str) -> bool:
    return unicodedata.category(ch)[0] in ("L", "N")


def normalize(text: str) -> str:
    text = text.lower()
    text = _compose(text)
    text = _THOUSANDS_GROUP.sub(lambda m: re.sub(r"[  .]", "", m.group(0)), text)
    text = "".join(ch if _is_letter_or_number(ch) else " " for ch in text)
    out: list[str] = []
    for token in text.split():
        if _ASCII_DIGITS.fullmatch(token):
            out += spell_number(token)
            continue
        parts = _split_compound(token) or [token]
        out += [_VARIANTS.get(p, p) for p in parts]
    return " ".join(out)


def normalize_words(text: str) -> list[str]:
    n = normalize(text)
    return n.split(" ") if n else []
