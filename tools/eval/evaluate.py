"""Desktop benchmark: run the app's offline models (same ONNX files, same
sherpa-onnx runtime) over a test set and print the same metrics as the app's
Benchmark screen. For fast accuracy runs without phones.

    pip install -r tools/eval/requirements.txt
    python tools/eval/evaluate.py --testset testsets/fleurs-sk-test testsets/no-speech \
        --models whisper-small-stock kinit-whisper-small-sk

  --models   ids from app/assets/models.json, or "all" for everything available.
             Models with download URLs are fetched into models_out/ on first use;
             self-converted ones must already be there (tools/convert/).
  --online   also run cloud engines through the proxy, e.g.
             --proxy http://localhost:8787 --online soniox-async deepgram-nova-3
  --no-vad   feed whole clips to the model instead of Silero VAD chunks
  --no-silence-pad  give Whisper the bare audio (shows the token-limit truncation)
  --terms    key-term list, one per line (default: terms.txt in the test set)

Scoring uses the shared normalization (shared/normalization/sk_rules.json) and
jiwer. Speed numbers are for this computer, not for a phone.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import platform
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

from common import scoring  # noqa: E402
from common.normalization import normalize  # noqa: E402

RATE = 16000
MAX_WINDOW_S = 28  # same cap as the app: Whisper in sherpa-onnx drops audio past 30 s
# Silence appended to each piece given to Whisper, as a fraction of its length
# (same as kWhisperSilencePad in the app). sherpa-onnx caps Whisper at 6 tokens
# per second of input audio, which cuts dense VAD chunks off mid-word.
WHISPER_SILENCE_PAD = 0.5


def load_catalog() -> dict:
    return json.loads((ROOT / "app" / "assets" / "models.json").read_text(encoding="utf-8"))


# ----------------------------------------------------------------------------- models
def _download(url: str, dest: Path, sha256: str | None) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_suffix(dest.suffix + ".part")
    print(f"  downloading {url}")
    h = hashlib.sha256()
    with urllib.request.urlopen(url) as r, part.open("wb") as f:
        total = int(r.headers.get("Content-Length") or 0)
        got = 0
        while block := r.read(1 << 20):
            f.write(block)
            h.update(block)
            got += len(block)
            if total and got % (50 << 20) < (1 << 20):
                print(f"    {got / 1e6:.0f} / {total / 1e6:.0f} MB")
    if sha256 and h.hexdigest() != sha256:
        part.unlink()
        raise SystemExit(f"checksum mismatch for {dest.name}")
    part.replace(dest)


def resolve_model(spec: dict, models_dir: Path) -> dict[str, Path] | None:
    """Return role -> file path, downloading URL-hosted models; None if unavailable."""
    d = models_dir / spec["id"]
    if spec["hosting"] == "self":
        manifest = d / "manifest.json"
        if not manifest.exists():
            return None
        files = json.loads(manifest.read_text(encoding="utf-8"))["files"]
        return {f["role"]: d / f["name"] for f in files}
    out = {}
    for f in spec["files"]:
        path = d / f["name"]
        if not path.exists() or (f.get("size") and path.stat().st_size != f["size"]):
            _download(f["url"], path, f.get("sha256"))
        out[f["role"]] = path
    return out


def ensure_vad(models_dir: Path) -> Path:
    vad = load_catalog()["vad"]
    path = models_dir / "silero-vad" / vad["file"]
    if not path.exists():
        _download(vad["url"], path, None)
    return path


class OfflineEngine:
    is_online = False

    def __init__(self, spec: dict, files: dict[str, Path], threads: int, no_silence_pad: bool = False):
        import sherpa_onnx

        self.id = spec["id"]
        self.name = spec["displayName"]
        self.quantization = spec["quantization"]
        self.silence_pad = WHISPER_SILENCE_PAD if spec["family"] == "whisper" and not no_silence_pad else 0.0
        started = time.perf_counter()
        if spec["family"] == "whisper":
            self.rec = sherpa_onnx.OfflineRecognizer.from_whisper(
                encoder=str(files["encoder"]), decoder=str(files["decoder"]), tokens=str(files["tokens"]),
                language="sk", task="transcribe", num_threads=threads)
        elif spec["family"] == "nemo_transducer":
            self.rec = sherpa_onnx.OfflineRecognizer.from_transducer(
                encoder=str(files["encoder"]), decoder=str(files["decoder"]), joiner=str(files["joiner"]),
                tokens=str(files["tokens"]), model_type="nemo_transducer", num_threads=threads)
        else:
            raise SystemExit(f"unknown family {spec['family']}")
        self.load_ms = round((time.perf_counter() - started) * 1000)

    def transcribe(self, pieces: list) -> tuple[str, int, int | None]:
        """Returns (text, processing ms, network latency ms)."""
        import numpy as np

        started = time.perf_counter()
        parts = []
        for samples in pieces:
            for start in range(0, len(samples), MAX_WINDOW_S * RATE):
                piece = samples[start:start + MAX_WINDOW_S * RATE]
                extra = min(int(len(piece) * self.silence_pad), MAX_WINDOW_S * RATE - len(piece))
                if extra > 0:
                    piece = np.concatenate([piece, np.zeros(extra, dtype="float32")])
                stream = self.rec.create_stream()
                stream.accept_waveform(RATE, piece)
                self.rec.decode_stream(stream)
                text = stream.result.text.strip()
                if text:
                    parts.append(text)
        return " ".join(parts), round((time.perf_counter() - started) * 1000), None


class OnlineEngine:
    is_online = True
    quantization = "n/a (cloud)"
    load_ms = None

    def __init__(self, engine_id: str, proxy: str, token: str | None):
        self.id = self.name = engine_id
        self.proxy = proxy.rstrip("/")
        self.token = token

    def transcribe(self, pieces: list) -> tuple[str, int, int | None]:
        import numpy as np

        samples = np.concatenate(pieces) if len(pieces) > 1 else pieces[0]
        pcm = np.clip(np.round(samples * 32767.0), -32768, 32767).astype("<i2")
        import io
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(pcm.tobytes())
        headers = {"Content-Type": "audio/wav"}
        if self.token:
            headers["x-proxy-token"] = self.token
        req = urllib.request.Request(
            f"{self.proxy}/v1/transcribe?engine={urllib.parse.quote(self.id)}&language=sk",
            data=buf.getvalue(), headers=headers, method="POST")
        started = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=240) as r:
                j = json.loads(r.read())
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"proxy HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}") from e
        ms = round((time.perf_counter() - started) * 1000)
        provider_ms = j.get("providerMs")
        return j.get("text", "").strip(), ms, None if provider_ms is None else max(0, ms - provider_ms)


# ----------------------------------------------------------------------------- audio + VAD
def read_wav(path: Path):
    import numpy as np

    with wave.open(str(path)) as w:
        if (w.getframerate(), w.getsampwidth()) != (RATE, 2):
            raise RuntimeError(f"{path.name}: need 16 kHz PCM16 (got {w.getframerate()} Hz, {8 * w.getsampwidth()} bit)")
        data = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype("float32") / 32768.0
        if w.getnchannels() > 1:
            data = data.reshape(-1, w.getnchannels()).mean(axis=1)
    return data


def vad_pieces(samples, vad_model: Path, a: argparse.Namespace) -> list:
    """Silero VAD chunks with padding; mirrors app/lib/pipeline/vad.dart."""
    import sherpa_onnx

    cfg = sherpa_onnx.VadModelConfig()
    cfg.silero_vad.model = str(vad_model)
    cfg.silero_vad.threshold = a.vad_threshold
    cfg.silero_vad.min_silence_duration = a.vad_min_silence
    cfg.silero_vad.min_speech_duration = a.vad_min_speech
    cfg.silero_vad.max_speech_duration = a.vad_max_speech
    cfg.silero_vad.window_size = 512
    cfg.sample_rate = RATE
    vad = sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=a.vad_max_speech + 30)
    pad = round(a.vad_padding * RATE)
    pieces, last_end = [], 0

    def drain() -> None:
        nonlocal last_end
        while not vad.empty():
            start = vad.front.start
            end = start + len(vad.front.samples)
            vad.pop()
            lo = start - pad
            if lo < last_end:
                lo = last_end if last_end < start else start
            lo = max(lo, 0)
            hi = min(end + pad, len(samples))
            if hi <= lo:
                continue
            last_end = hi
            pieces.append(samples[lo:hi])

    fed = 0
    while len(samples) - fed >= 512:
        vad.accept_waveform(samples[fed:fed + 512])
        fed += 512
        drain()
    if fed < len(samples):
        vad.accept_waveform(samples[fed:])
    vad.flush()
    drain()
    return pieces


def peak_rss() -> int | None:
    try:
        import psutil

        info = psutil.Process().memory_info()
        return getattr(info, "peak_wset", None) or info.rss
    except ImportError:
        return None


# ----------------------------------------------------------------------------- run
def load_testset(dirs: list[Path], limit: int) -> tuple[list[tuple[str, Path, str]], list[str]]:
    clips, terms = [], []
    for d in dirs:
        if not d.is_dir():
            raise SystemExit(f"test set folder not found: {d}")
        found = []
        for wav in sorted(d.rglob("*.wav")):
            txt = wav.with_suffix(".txt")
            if txt.exists():
                found.append((f"{d.name}/{wav.stem}", wav, txt.read_text(encoding="utf-8").strip()))
        clips += found[:limit] if limit else found
        t = d / "terms.txt"
        if t.exists():
            terms += [line.strip() for line in t.read_text(encoding="utf-8").splitlines() if line.strip()]
    return clips, terms


def summarize(engine, rows: list[dict]) -> dict:
    import jiwer

    ok = [r for r in rows if not r["error"]]
    speech = [r for r in ok if not r["no_speech"]]
    silent = [r for r in ok if r["no_speech"]]
    refs = [normalize(r["reference"]) for r in speech]
    hyps = [normalize(r["hypothesis"]) for r in speech]
    wer = jiwer.wer(refs, hyps) if refs else None
    cer = jiwer.cer(refs, hyps) if refs else None
    # Our own edit counts must agree with jiwer.
    own = scoring.EditCounts()
    for r, h in zip(refs, hyps):
        own = own + scoring.count(r.split(), h.split())
    if wer is not None and abs(own.rate() - wer) > 1e-9:
        raise AssertionError(f"scoring mismatch: own {own.rate()} vs jiwer {wer}")
    proc = sum(r["processing_ms"] for r in ok)
    speech_ms = sum(r["speech_ms"] for r in ok)
    net = [r["network_latency_ms"] for r in ok if r["network_latency_ms"] is not None]
    key_expected = sum(r["key_terms_expected"] for r in ok)
    return {
        "engine_id": engine.id,
        "engine_name": engine.name,
        "quantization": engine.quantization,
        "clips": len(ok),
        "errors": len(rows) - len(ok),
        "wer": wer,
        "cer": cer,
        "no_speech_clips": len(silent),
        "hallucination_rate": (sum(r["hallucinated"] for r in silent) / len(silent)) if silent else None,
        "key_term_accuracy": (sum(r["key_terms_found"] for r in ok) / key_expected) if key_expected else None,
        "rtf": (proc / speech_ms) if speech_ms else None,
        "avg_latency_ms": (proc / len(ok)) if ok else None,
        "avg_network_latency_ms": (sum(net) / len(net)) if net else None,
        "model_load_ms": engine.load_ms,
        "peak_rss_bytes": peak_rss(),
    }


def fmt(v, pct=False) -> str:
    if v is None:
        return "n/a"
    return f"{v * 100:.1f}%" if pct else (f"{v:.3f}" if isinstance(v, float) else str(v))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--testset", type=Path, nargs="+", required=True)
    p.add_argument("--models", nargs="*", default=[], help='catalog ids, or "all"')
    p.add_argument("--online", nargs="*", default=[], help="proxy engine ids")
    p.add_argument("--proxy", default="http://localhost:8787")
    p.add_argument("--proxy-token", default=None)
    p.add_argument("--models-dir", type=Path, default=ROOT / "models_out")
    p.add_argument("--out", type=Path, default=ROOT / "results")
    p.add_argument("--limit", type=int, default=0, help="clips per test set (0 = all)")
    p.add_argument("--threads", type=int, default=4)
    p.add_argument("--terms", type=Path, default=None)
    p.add_argument("--no-vad", action="store_true")
    p.add_argument("--no-silence-pad", action="store_true",
                   help="do not append silence to Whisper input (reproduces the truncation)")
    p.add_argument("--vad-threshold", type=float, default=0.5)
    p.add_argument("--vad-min-silence", type=float, default=0.7)
    p.add_argument("--vad-min-speech", type=float, default=0.25)
    p.add_argument("--vad-max-speech", type=float, default=25.0)
    p.add_argument("--vad-padding", type=float, default=0.2)
    a = p.parse_args()

    clips, terms = load_testset(a.testset, a.limit)
    if a.terms:
        terms = [line.strip() for line in a.terms.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not clips:
        raise SystemExit("no .wav + .txt pairs found")
    print(f"{len(clips)} clips, {len(terms)} key terms, VAD {'off' if a.no_vad else 'on'}")

    catalog = load_catalog()
    wanted = [m["id"] for m in catalog["models"]] if a.models == ["all"] else a.models
    vad_model = None if a.no_vad else ensure_vad(a.models_dir)

    audio_cache: dict[Path, tuple] = {}

    def pieces_for(path: Path):
        if path not in audio_cache:
            samples = read_wav(path)
            audio_cache[path] = (samples, [samples] if a.no_vad else vad_pieces(samples, vad_model, a))
        return audio_cache[path]

    all_rows, summaries, engines = [], [], []
    for model_id in wanted:
        spec = next((m for m in catalog["models"] if m["id"] == model_id), None)
        if spec is None:
            raise SystemExit(f"unknown model id {model_id}")
        files = resolve_model(spec, a.models_dir)
        if files is None:
            print(f"SKIPPED {model_id}: not converted yet (run {spec.get('conversion')})")
            continue
        print(f"loading {model_id}")
        engines.append(OfflineEngine(spec, files, a.threads, a.no_silence_pad))
    engines += [OnlineEngine(e, a.proxy, a.proxy_token) for e in a.online]
    if not engines:
        raise SystemExit("no engines to run")

    for engine in engines:
        rows = []
        for i, (name, path, reference) in enumerate(clips, 1):
            row = {
                "engine_id": engine.id, "clip": name, "no_speech": scoring.is_no_speech(reference),
                "hallucinated": False, "wer": None, "cer": None, "substitutions": 0, "deletions": 0, "insertions": 0,
                "reference_words": 0, "audio_ms": 0, "speech_ms": 0, "processing_ms": 0, "rtf": None,
                "network_latency_ms": None, "key_terms_found": 0, "key_terms_expected": 0,
                "reference": reference, "hypothesis": "", "error": "",
            }
            try:
                samples, pieces = pieces_for(path)
                row["audio_ms"] = round(len(samples) * 1000 / RATE)
                row["speech_ms"] = round(sum(len(x) for x in pieces) * 1000 / RATE)
                if pieces:
                    text, ms, net = engine.transcribe(pieces)
                else:
                    text, ms, net = "", 0, None  # VAD found no speech: the engine is not called
                w = scoring.word_counts(reference, text)
                c = scoring.char_counts(reference, text)
                found, expected = scoring.key_term_hits(reference, text, terms)
                row.update(
                    hypothesis=text, processing_ms=ms, network_latency_ms=net,
                    rtf=(ms / row["speech_ms"]) if row["speech_ms"] else None,
                    wer=w.rate(), cer=c.rate(), substitutions=w.substitutions, deletions=w.deletions,
                    insertions=w.insertions, reference_words=w.ref_len,
                    hallucinated=row["no_speech"] and normalize(text) != "",
                    key_terms_found=found, key_terms_expected=expected)
            except Exception as e:  # keep going; the failure is reported per clip
                row["error"] = f"{type(e).__name__}: {e}"
            rows.append(row)
            if i % 20 == 0 or i == len(clips):
                print(f"  {engine.id}: {i}/{len(clips)}")
        all_rows += rows
        summaries.append(summarize(engine, rows))

    # Offline vs online: WER of each offline engine with the online transcript as reference.
    cross = []
    by_engine = {e.id: {r["clip"]: r for r in all_rows if r["engine_id"] == e.id and not r["error"]} for e in engines}
    for off in (e for e in engines if not e.is_online):
        for on in (e for e in engines if e.is_online):
            total, n = scoring.EditCounts(), 0
            for clip, r in by_engine[off.id].items():
                ref = by_engine[on.id].get(clip)
                if ref is None or ref["no_speech"]:
                    continue
                total = total + scoring.word_counts(ref["hypothesis"], r["hypothesis"])
                n += 1
            cross.append({"offline": off.id, "onlineAsReference": on.id, "wer": total.rate(), "clips": n})

    a.out.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    with (a.out / f"summary-{stamp}.csv").open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(summaries[0]))
        w.writeheader()
        w.writerows(summaries)
    with (a.out / f"clips-{stamp}.csv").open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(all_rows[0]))
        w.writeheader()
        w.writerows(all_rows)
    (a.out / f"results-{stamp}.json").write_text(json.dumps({
        "run": {
            "testSets": [str(d) for d in a.testset], "clips": len(clips), "useVad": not a.no_vad,
            "vad": None if a.no_vad else {"threshold": a.vad_threshold, "minSilenceS": a.vad_min_silence,
                                           "minSpeechS": a.vad_min_speech, "maxSpeechS": a.vad_max_speech,
                                           "paddingS": a.vad_padding},
            "threads": a.threads, "whisperSilencePad": 0.0 if a.no_silence_pad else WHISPER_SILENCE_PAD, "deviceModel": platform.node(), "osVersion": platform.platform(),
            "processor": platform.processor(), "normalization": "shared/normalization/sk_rules.json",
        },
        "summary": summaries, "offlineVsOnline": cross, "clips": all_rows,
    }, indent=2, ensure_ascii=False), encoding="utf-8")

    print()
    header = f"{'engine':38} {'WER':>7} {'CER':>7} {'halluc':>7} {'terms':>7} {'RTF':>7} {'lat ms':>8} {'load ms':>8} {'err':>4}"
    print(header)
    print("-" * len(header))
    for s in summaries:
        print(f"{s['engine_id'][:38]:38} {fmt(s['wer'], True):>7} {fmt(s['cer'], True):>7} "
              f"{fmt(s['hallucination_rate'], True):>7} {fmt(s['key_term_accuracy'], True):>7} {fmt(s['rtf']):>7} "
              f"{fmt(round(s['avg_latency_ms']) if s['avg_latency_ms'] is not None else None):>8} "
              f"{fmt(s['model_load_ms']):>8} {s['errors']:>4}")
    for c in cross:
        print(f"offline {c['offline']} vs online {c['onlineAsReference']} as reference: WER {fmt(c['wer'], True)} ({c['clips']} clips)")
    print(f"\nwrote {a.out / f'summary-{stamp}.csv'}, clips-{stamp}.csv, results-{stamp}.json")


if __name__ == "__main__":
    main()
