"""WER / CER / hallucination / key-term scoring shared by the Python tools.

Mirrors app/lib/core/wer.dart. The numbers are cross-checked against jiwer in
tools/tests/test_scoring.py when jiwer is installed.
"""
from __future__ import annotations

from dataclasses import dataclass

from .normalization import normalize, normalize_words


@dataclass
class EditCounts:
    substitutions: int = 0
    deletions: int = 0
    insertions: int = 0
    hits: int = 0

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def ref_len(self) -> int:
        return self.substitutions + self.deletions + self.hits

    def __add__(self, other: "EditCounts") -> "EditCounts":
        return EditCounts(
            self.substitutions + other.substitutions,
            self.deletions + other.deletions,
            self.insertions + other.insertions,
            self.hits + other.hits,
        )

    def rate(self) -> float | None:
        """Error rate, or None when the reference is empty."""
        return self.errors / self.ref_len if self.ref_len else None


def align(ref: list[str], hyp: list[str]) -> list[tuple[str, str | None, str | None]]:
    """Levenshtein alignment. Returns ops: ('ok'|'sub'|'del'|'ins', ref_item, hyp_item)."""
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        d[i][0] = i
    for j in range(1, m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        ri = ref[i - 1]
        for j in range(1, m + 1):
            cost = 0 if ri == hyp[j - 1] else 1
            d[i][j] = min(d[i - 1][j - 1] + cost, d[i - 1][j] + 1, d[i][j - 1] + 1)
    ops: list[tuple[str, str | None, str | None]] = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and ref[i - 1] == hyp[j - 1] and d[i][j] == d[i - 1][j - 1]:
            ops.append(("ok", ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and j > 0 and d[i][j] == d[i - 1][j - 1] + 1:
            ops.append(("sub", ref[i - 1], hyp[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and d[i][j] == d[i - 1][j] + 1:
            ops.append(("del", ref[i - 1], None))
            i -= 1
        else:
            ops.append(("ins", None, hyp[j - 1]))
            j -= 1
    ops.reverse()
    return ops


def count(ref: list[str], hyp: list[str]) -> EditCounts:
    c = EditCounts()
    for op, _, _ in align(ref, hyp):
        if op == "ok":
            c.hits += 1
        elif op == "sub":
            c.substitutions += 1
        elif op == "del":
            c.deletions += 1
        else:
            c.insertions += 1
    return c


def word_counts(reference: str, hypothesis: str) -> EditCounts:
    return count(normalize_words(reference), normalize_words(hypothesis))


def char_counts(reference: str, hypothesis: str) -> EditCounts:
    return count(list(normalize(reference)), list(normalize(hypothesis)))


def is_no_speech(reference: str) -> bool:
    return normalize(reference) == ""


def key_term_hits(reference: str, hypothesis: str, terms: list[str]) -> tuple[int, int]:
    """(found, expected): for each term occurring in the reference, is it in the hypothesis?"""
    ref = f" {normalize(reference)} "
    hyp = f" {normalize(hypothesis)} "
    found = expected = 0
    for term in terms:
        t = normalize(term)
        if not t:
            continue
        needle = f" {t} "
        if needle in ref:
            expected += 1
            if needle in hyp:
                found += 1
    return found, expected
