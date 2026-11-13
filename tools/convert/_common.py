"""Shared helpers for the model conversion scripts."""
from __future__ import annotations

import hashlib
import json
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = ROOT / "app" / "assets" / "models.json"
DEFAULT_OUT = ROOT / "models_out"

# k2-fsa/sherpa-onnx commit whose export scripts we run (master on 2026-11-12).
SHERPA_ONNX_COMMIT = "29b735c823c7cdfb69c846dd86ff1d4f2e325598"
SHERPA_RAW = f"https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/{SHERPA_ONNX_COMMIT}"


def load_catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def model_spec(model_id: str) -> dict:
    for m in load_catalog()["models"]:
        if m["id"] == model_id:
            return m
    known = ", ".join(m["id"] for m in load_catalog()["models"])
    raise SystemExit(f"Unknown model id {model_id!r}. Known ids: {known}")


def fetch_upstream(repo_path: str, dest: Path) -> Path:
    """Download one file of the pinned sherpa-onnx commit (cached)."""
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        url = f"{SHERPA_RAW}/{repo_path}"
        print(f"fetching {url}")
        with urllib.request.urlopen(url) as r:
            dest.write_bytes(r.read())
    return dest


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def write_manifest(out_dir: Path, spec: dict, files: dict[str, str], extra: dict | None = None) -> None:
    """Write manifest.json: what the app's Model Manager downloads and verifies.

    `files` maps role (encoder/decoder/joiner/tokens) to a file name in out_dir.
    """
    manifest = {
        "id": spec["id"],
        "sourceRepo": spec["sourceRepo"],
        "sourceRevision": spec.get("sourceRevision"),
        "license": spec["license"],
        "quantization": spec["quantization"],
        "convertedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sherpaOnnxExportCommit": SHERPA_ONNX_COMMIT,
        "files": [
            {
                "role": role,
                "name": name,
                "size": (out_dir / name).stat().st_size,
                "sha256": sha256_of(out_dir / name),
            }
            for role, name in files.items()
        ],
        **(extra or {}),
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    total = sum(f["size"] for f in manifest["files"])
    print(f"wrote {out_dir / 'manifest.json'}  ({total / 1e6:.1f} MB in {len(files)} files)")
