"""Build benchmark test sets in the folder format the app and evaluate.py read:

    <set>/<clip>.wav   16 kHz mono PCM16
    <set>/<clip>.txt   reference transcript (empty file = no-speech clip)

Subcommands (run from the repo root):

  fleurs       Google FLEURS Slovak test split (CC-BY-4.0), straight from Hugging Face.
               Needs nothing but the standard library.
                   python tools/datasets/download_testsets.py fleurs --limit 100

  commonvoice  Mozilla Common Voice Slovak test split (CC0) from an archive you
               downloaded yourself. Since October 2025 Common Voice is only
               distributed by Mozilla Data Collective, which needs an account,
               an API key and acceptance of the dataset terms:
                   https://mozilladatacollective.com/datasets/cmu62gcol00ohnq0758656ndx
               (or `pip install datacollective` and its download_dataset()).
               Needs: pip install numpy soundfile soxr
                   python tools/datasets/download_testsets.py commonvoice --archive cv-corpus-27.0-sk.tar.gz --limit 100

  nospeech     Synthetic silence / noise clips with empty references, for
               measuring hallucination. Standard library only.
                   python tools/datasets/download_testsets.py nospeech --count 20

Add --zip to also write <set>.zip for the app's "Import zip" button.
"""
from __future__ import annotations

import argparse
import csv
import io
import math
import random
import shutil
import struct
import sys
import tarfile
import urllib.request
import wave
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "testsets"

FLEURS_BASE = "https://huggingface.co/datasets/google/fleurs/resolve/main/data/sk_sk"
RATE = 16000


def _finish(out: Path, count: int, make_zip: bool) -> None:
    print(f"{count} clips in {out}")
    if make_zip:
        archive = shutil.make_archive(str(out), "zip", root_dir=out.parent, base_dir=out.name)
        print(f"zip for the app: {archive}")


def _write_pair(out: Path, name: str, wav_bytes: bytes, text: str) -> None:
    (out / f"{name}.wav").write_bytes(wav_bytes)
    (out / f"{name}.txt").write_text(text.strip() + ("\n" if text.strip() else ""), encoding="utf-8")


def _pcm16_wav(samples: list[int]) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    return buf.getvalue()


def _to_pcm16_mono(data: bytes, name: str) -> bytes:
    """Re-encode a 16 kHz WAV (PCM16 or 32-bit float, as FLEURS ships) as mono PCM16."""
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise SystemExit(f"{name}: not a WAV file")
    fmt = None
    pos = 12
    while pos + 8 <= len(data):
        chunk_id, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
        body = pos + 8
        if chunk_id == b"fmt ":
            tag, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", data, body)
            if tag == 0xFFFE:  # WAVE_FORMAT_EXTENSIBLE: real tag is in the sub-format
                tag = struct.unpack_from("<H", data, body + 24)[0]
            fmt = (tag, channels, rate, bits)
        elif chunk_id == b"data":
            if fmt is None:
                raise SystemExit(f"{name}: data chunk before fmt chunk")
            tag, channels, rate, bits = fmt
            if rate != RATE:
                raise SystemExit(f"{name}: expected {RATE} Hz, got {rate} Hz")
            raw = data[body:body + size]
            if tag == 1 and bits == 16:
                values = array("h")
                values.frombytes(raw[:len(raw) // 2 * 2])
                floats = [v / 32768.0 for v in values]
            elif tag == 3 and bits == 32:
                values = array("f")
                values.frombytes(raw[:len(raw) // 4 * 4])
                floats = values
            else:
                raise SystemExit(f"{name}: unsupported WAV encoding (format {tag}, {bits} bit)")
            if sys.byteorder == "big":
                values.byteswap()
            if channels > 1:
                floats = [sum(floats[i:i + channels]) / channels for i in range(0, len(floats), channels)]
            return _pcm16_wav([max(-32768, min(32767, round(v * 32767.0))) for v in floats])
        pos = body + size + (size & 1)
    raise SystemExit(f"{name}: no data chunk")


# ----------------------------------------------------------------------------- FLEURS
def fleurs(args: argparse.Namespace) -> None:
    out = args.out / "fleurs-sk-test"
    out.mkdir(parents=True, exist_ok=True)
    print("downloading FLEURS sk_sk test.tsv")
    with urllib.request.urlopen(f"{FLEURS_BASE}/test.tsv") as r:
        rows = list(csv.reader(io.TextIOWrapper(r, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE))
    # Columns: id, file name, raw transcription, normalised transcription, chars, num_samples, gender.
    # The raw transcription keeps casing, punctuation and digits; our shared
    # normalization is applied at scoring time, identically for every engine.
    wanted: dict[str, str] = {}
    for row in rows:
        if len(row) >= 3 and row[1] not in wanted:
            wanted[row[1]] = row[2]
        if args.limit and len(wanted) >= args.limit:
            break
    print(f"streaming audio for {len(wanted)} clips (the full archive is about 450 MB; stops early when done)")
    done = 0
    with urllib.request.urlopen(f"{FLEURS_BASE}/audio/test.tar.gz") as r:
        with tarfile.open(fileobj=r, mode="r|gz") as tar:
            for member in tar:
                name = Path(member.name).name
                if not member.isfile() or name not in wanted:
                    continue
                data = _to_pcm16_mono(tar.extractfile(member).read(), name)
                _write_pair(out, Path(name).stem, data, wanted.pop(name))
                done += 1
                if done % 25 == 0:
                    print(f"  {done} clips")
                if not wanted:
                    break
    if wanted:
        print(f"warning: {len(wanted)} listed clips were not found in the archive")
    (out / "SOURCE.txt").write_text(
        "Google FLEURS, sk_sk test split, CC-BY-4.0. https://huggingface.co/datasets/google/fleurs\n", encoding="utf-8")
    _finish(out, done, args.zip)


# ----------------------------------------------------------------------------- Common Voice
def commonvoice(args: argparse.Namespace) -> None:
    try:
        import numpy as np
        import soundfile as sf
        import soxr
    except ImportError as e:
        raise SystemExit(f"commonvoice needs: pip install numpy soundfile soxr   ({e})")

    out = args.out / "commonvoice-sk-test"
    out.mkdir(parents=True, exist_ok=True)
    print(f"reading {args.archive}")
    with tarfile.open(args.archive) as tar:
        tsv = next((m for m in tar.getmembers() if m.name.endswith(f"/{args.split}.tsv")), None)
        if tsv is None:
            raise SystemExit(f"{args.split}.tsv not found in the archive")
        prefix = tsv.name.rsplit("/", 1)[0]
        reader = csv.DictReader(io.TextIOWrapper(tar.extractfile(tsv), encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE)
        wanted: dict[str, str] = {}
        for row in reader:
            wanted[f"{prefix}/clips/{row['path']}"] = row["sentence"]
            if args.limit and len(wanted) >= args.limit:
                break
        done = 0
        for member_name, sentence in wanted.items():
            try:
                member = tar.getmember(member_name)
            except KeyError:
                print(f"  missing in archive: {member_name}")
                continue
            audio, rate = sf.read(io.BytesIO(tar.extractfile(member).read()), dtype="float32", always_2d=True)
            mono = audio.mean(axis=1)
            if rate != RATE:
                mono = soxr.resample(mono, rate, RATE)
            pcm = np.clip(np.round(mono * 32767.0), -32768, 32767).astype("<i2")
            buf = io.BytesIO()
            with wave.open(buf, "wb") as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(RATE)
                w.writeframes(pcm.tobytes())
            _write_pair(out, Path(member_name).stem, buf.getvalue(), sentence)
            done += 1
            if done % 25 == 0:
                print(f"  {done} clips")
    (out / "SOURCE.txt").write_text(
        "Mozilla Common Voice, Slovak, CC0-1.0, via Mozilla Data Collective. Do not re-host or re-share;"
        " do not attempt to identify speakers.\n", encoding="utf-8")
    _finish(out, done, args.zip)


# ----------------------------------------------------------------------------- no-speech
def _noise(kind: str, seconds: float, level: float, rng: random.Random) -> list[int]:
    n = int(seconds * RATE)
    amp = level * 32767
    if kind == "silence":
        return [0] * n
    if kind == "white":
        return [int(rng.uniform(-amp, amp)) for _ in range(n)]
    if kind == "brown":  # low-frequency rumble (random walk, leaky)
        out, v = [], 0.0
        for _ in range(n):
            v = 0.98 * v + rng.uniform(-1, 1) * 0.1
            out.append(int(max(-1.0, min(1.0, v)) * amp))
        return out
    if kind == "hum":  # 50 Hz mains hum with harmonics plus a little hiss
        return [
            int(amp * (0.6 * math.sin(2 * math.pi * 50 * i / RATE) + 0.3 * math.sin(2 * math.pi * 150 * i / RATE))
                + rng.uniform(-amp, amp) * 0.1)
            for i in range(n)
        ]
    if kind == "clicks":  # sparse impulses over faint hiss (keyboard / handling noise)
        out = [int(rng.uniform(-amp, amp) * 0.05) for _ in range(n)]
        for _ in range(int(seconds * 4)):
            at = rng.randrange(n - 200)
            for j in range(200):
                out[at + j] = int(amp * math.exp(-j / 30) * rng.uniform(-1, 1))
        return out
    raise ValueError(kind)


def nospeech(args: argparse.Namespace) -> None:
    out = args.out / "no-speech"
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    kinds = ["silence", "white", "brown", "hum", "clicks"]
    levels = [0.005, 0.02, 0.08]
    for i in range(args.count):
        kind = kinds[i % len(kinds)]
        level = levels[(i // len(kinds)) % len(levels)]
        seconds = rng.choice([3.0, 6.0, 10.0])
        name = f"nospeech-{i:03d}-{kind}-{int(level * 1000):03d}"
        _write_pair(out, name, _pcm16_wav(_noise(kind, seconds, level, rng)), "")
    (out / "SOURCE.txt").write_text(
        f"Synthetic no-speech clips (seed {args.seed}). Empty references: any output is a hallucination.\n", encoding="utf-8")
    _finish(out, args.count, args.zip)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    for name, fn in (("fleurs", fleurs), ("commonvoice", commonvoice), ("nospeech", nospeech)):
        s = sub.add_parser(name)
        s.set_defaults(fn=fn)
        s.add_argument("--out", type=Path, default=DEFAULT_OUT, help="test-set root (default: testsets/)")
        s.add_argument("--zip", action="store_true", help="also write a zip for the app")
        if name != "nospeech":
            s.add_argument("--limit", type=int, default=100, help="number of clips (0 = all)")
        if name == "commonvoice":
            s.add_argument("--archive", type=Path, required=True, help="downloaded Common Voice Slovak .tar.gz")
            s.add_argument("--split", default="test")
        if name == "nospeech":
            s.add_argument("--count", type=int, default=20)
            s.add_argument("--seed", type=int, default=7)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
